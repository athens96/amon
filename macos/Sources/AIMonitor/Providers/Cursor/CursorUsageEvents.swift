import Foundation

/// Cursor 소비 토큰 — 대시보드 사용-이벤트 CSV 폴백.
///
/// 2026 초 이후 Cursor 는 state.vscdb 버블에 per-request `tokenCount` 를 기록하지
/// 않는다(필드는 남았으나 항상 0 — 2025-12 이후 실측 중단). 로컬 DB 스캔으로는
/// 과거 누적만 남고 최근 창이 비므로, 쿼터 축과 같은 로컬 자격증명으로
/// `export-usage-events-csv?strategy=tokens` 를 받아 최근 창의 일자별 소비를 채운다.
///
/// CSV 헤더(2026-07 실측):
/// `Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,
///  Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost`
enum CursorUsageEvents {
    /// 요청 1건짜리 원본 이벤트 — 일자 집계와 달리 시각을 남긴다.
    /// 세션(composer)별 토큰 추정(`CursorSessionTokens`)의 귀속 입력.
    struct RawEvent: Codable, Sendable {
        let date: Date
        let model: String
        let usage: TokenUsage
    }

    struct Result: Sendable {
        var daily: [String: TokenUsage] = [:]
        /// 일자→모델→사용량 (usage_daily 저장용). CSV 는 Model 컬럼이 있어 채운다.
        var dailyByModel: [String: [String: TokenUsage]] = [:]
        /// 일자→모델→비용(USD).
        var dailyCostByModel: [String: [String: Double]] = [:]
        /// 창 내 모델별 total 합 (Cursor DB 스캔은 모델 정보가 없어 이 축이 유일).
        var models: [String: Int] = [:]
        /// 창 내 비용 합(USD).
        var costUSD: Double = 0
        var events: Int = 0
        var lastActivity: Date? = nil
        /// 시각이 남은 원본 이벤트 전체 — 세션별 토큰 추정용.
        var rawEvents: [RawEvent] = []
    }

    /// 최근 `windowDays`일(오늘 포함) 창의 일자별 사용량.
    /// 자격증명이 없거나 요청/파싱 실패 시 nil — 호출부는 DB 스캔 값을 그대로 둔다.
    /// 토큰 만료 갱신은 쿼터 축(CursorProvider, 5분 주기)이 담당하므로 여기선
    /// 저장된 액세스 토큰을 그대로 쓰고 실패하면 다음 스캔 주기에 재시도한다.
    static func fetchDaily(windowDays: Int = UsageScanner.scanWindowDays) async -> Result? {
        guard let accessToken = CursorAuthStore().loadAuthState()?.accessToken,
              !accessToken.isEmpty
        else { return nil }

        let end = Date()
        let start = Calendar.current.date(
            byAdding: .day, value: -(windowDays - 1),
            to: Calendar.current.startOfDay(for: end)
        ) ?? end.addingTimeInterval(-Double(windowDays) * 86400)

        guard let response = try? await CursorUsageClient()
            .fetchUsageCSV(accessToken: accessToken, start: start, end: end),
              response.statusCode == 200,
              let csv = String(data: response.body, encoding: .utf8)
        else { return nil }

        return parse(csv: csv)
    }

    /// CSV 본문 → 일자별 집계. 헤더 이름으로 컬럼을 찾아 순서 변경에 견딘다.
    static func parse(csv: String) -> Result? {
        var lines = csv.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let headerLine = lines.popFirst() else { return nil }
        let header = splitCSVLine(String(headerLine))
        func col(_ name: String) -> Int? {
            header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let iDate = col("Date"),
              let iOut = col("Output Tokens")
        else { return nil }  // 필수 컬럼이 없으면 포맷 변경 — 폴백 포기
        let iModel = col("Model")
        let iCacheW = col("Input (w/ Cache Write)")
        let iInput = col("Input (w/o Cache Write)")
        let iCacheR = col("Cache Read")
        let iTotal = col("Total Tokens")
        let iCost = col("Cost")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()  // 소수점 없는 변형 대비
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")

        var result = Result()
        for line in lines {
            let fields = splitCSVLine(String(line))
            guard fields.indices.contains(iDate) else { continue }
            guard let date = iso.date(from: fields[iDate]) ?? isoPlain.date(from: fields[iDate])
            else { continue }

            func intAt(_ index: Int?) -> Int {
                guard let index, fields.indices.contains(index) else { return 0 }
                return Int(fields[index]) ?? 0
            }
            var usage = TokenUsage()
            usage.input = intAt(iInput)
            usage.cacheWrite = intAt(iCacheW)
            usage.cacheRead = intAt(iCacheR)
            usage.output = intAt(iOut)
            usage.total = intAt(iTotal)
            if usage.total == 0 {
                usage.total = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
            }
            guard usage.total > 0 else { continue }

            let day = dayFmt.string(from: date)
            result.daily[day, default: TokenUsage()] += usage
            var model = ""
            if let iModel, fields.indices.contains(iModel) { model = fields[iModel] }
            if !model.isEmpty { result.models[model, default: 0] += usage.total }
            result.rawEvents.append(RawEvent(date: date, model: model, usage: usage))
            result.dailyByModel[day, default: [:]][model, default: TokenUsage()] += usage
            if let iCost, fields.indices.contains(iCost) {
                let rowCost = Double(fields[iCost]) ?? 0
                result.costUSD += rowCost
                if rowCost != 0 {
                    result.dailyCostByModel[day, default: [:]][model, default: 0] += rowCost
                }
            }
            result.events += 1
            if result.lastActivity.map({ date > $0 }) ?? true { result.lastActivity = date }
        }
        return result
    }

    /// 스캔 요약의 cursor 항목에 CSV 집계를 병합한다.
    /// - daily/today: CSV 창 데이터로 교체 (DB 버블 데이터는 이 창에서 항상 빈 상태)
    /// - usage(누적): DB 역사 누적 + CSV 창 합 (2025-12~창 시작 구간은 소스가 없어 공백)
    /// - models/cost: CSV 창 기준 (DB 는 원래 미제공)
    static func merge(into summaries: inout [ToolUsageSummary], result: Result) {
        guard result.events > 0,
              let i = summaries.firstIndex(where: { $0.tool == .cursor })
        else { return }
        var s = summaries[i]
        s.daily = result.daily
        s.dailyByModel = result.dailyByModel
        s.dailyCostByModel = result.dailyCostByModel
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        s.today = result.daily[dayFmt.string(from: Date())] ?? TokenUsage()
        s.usage = result.daily.values.reduce(s.usage) { $0 + $1 }
        s.models = result.models
        s.costUSD = result.costUSD
        if let last = result.lastActivity,
           s.lastActivity.map({ last > $0 }) ?? true {
            s.lastActivity = last
        }
        s.note = "소비 토큰은 Cursor 대시보드 API(최근 \(UsageScanner.scanWindowDays)일) 기준"
        summaries[i] = s
    }

    /// 따옴표 감싼 필드를 지원하는 한 줄 CSV 분해 ("" 이스케이프 포함).
    static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line[...].makeIterator()
        while let ch = chars.next() {
            if inQuotes {
                if ch == "\"" {
                    // 닫는 따옴표 또는 "" 이스케이프.
                    if let peeked = chars.next() {
                        if peeked == "\"" { current.append("\"") } else if peeked == "," {
                            fields.append(current); current = ""; inQuotes = false
                        } else {
                            inQuotes = false; current.append(peeked)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                fields.append(current); current = ""
            } else if ch != "\r" {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}
