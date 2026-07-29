import SwiftUI

/// 대시보드 공용 컴포넌트 — 섹션 머리와 토큰 표.
///
/// 이전에는 같은 역할을 세 가지 형태가 나눠 맡고 있었다: 히어로의 틴트 블록,
/// 현재 활동의 아이콘+헤어라인, `summaryRow` 의 맨 텍스트. 그리고 로컬 사용량은
/// 접힘/펼침에서 아예 다른 레이아웃을 썼다. 여기서 각각 하나로 합친다.

// MARK: - 섹션 머리

/// 라벨 + 헤어라인 + (선택) 후행 컨트롤. 섹션 구분과 카드 안 구분선이 모두 이 형태를 쓴다.
///
/// 라벨을 비우면 순수 구분선이 된다.
struct SectionHeader<Trailing: View>: View {
    private let title: String?
    private let systemImage: String?
    private let trailing: Trailing

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.amonMicro)
            }
            if let title {
                Text(title)
            }
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(height: 0.5)
            trailing
        }
        .font(.amonCaption)
        .foregroundStyle(.tertiary)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String? = nil, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - 토큰 표

/// 로컬 사용량의 유일한 형태 — 입력/출력/캐시/합계 4열.
///
/// 접힘은 오늘·누적 두 행, 펼침은 같은 4열 위에 모델별 누적과 최근 7일을 얹는다.
/// 형태가 바뀌지 않으므로 모드를 오갈 때 레이아웃을 다시 익힐 필요가 없다.
struct TokenGrid: View {
    let summary: ToolUsageSummary
    /// 개별 보기 — 모델별 누적·최근 7일까지 펼친다.
    var expanded: Bool = false

    private static let columns = ["입력", "출력", "캐시", "합계"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            columnHeaderRow
            tokenRow(label: "오늘", usage: summary.today, dim: summary.today.total == 0)
            tokenRow(label: "누적", usage: summary.usage)
            metaRow

            if expanded {
                modelListRows
                recentDailyRows
            } else if let modelLine = ModelBreakdown.summaryText(summary) {
                Text(modelLine)
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(ModelBreakdown.helpText(summary))
            }
        }
    }

    // MARK: 4열 골격

    private var columnHeaderRow: some View {
        HStack(spacing: 4) {
            Text("").frame(width: Metrics.labelColumn, alignment: .leading)
            ForEach(Self.columns, id: \.self) { title in
                Text(title)
                    .font(.amonMicro)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 라벨 + 입력/출력/캐시/합계. 캐시 칸은 hover 시 읽기·쓰기로 분해된다.
    private func tokenRow(label: String, usage u: TokenUsage, dim: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Metrics.labelColumn, alignment: .leading)
            numberCell(u.input, dim: dim)
            numberCell(u.output, dim: dim)
            numberCell(u.cacheRead + u.cacheWrite, dim: dim)
                .help("캐시 읽기 \(TokenFormat.compact(u.cacheRead)) · 쓰기 \(TokenFormat.compact(u.cacheWrite))")
            numberCell(u.total, dim: dim, emphasized: true)
        }
    }

    private func numberCell(_ n: Int, dim: Bool, emphasized: Bool = false) -> some View {
        Text(n > 0 ? TokenFormat.compact(n) : "—")
            .font(.system(size: 12, weight: emphasized ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(
                dim || n == 0
                    ? Color.secondary.opacity(0.5)
                    : (emphasized ? Color.primary : Color.secondary)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(n > 0 ? TokenFormat.grouped(n) : "")
    }

    /// 세션 수 · API 비용 · 마지막 활동.
    private var metaRow: some View {
        HStack(spacing: 4) {
            if summary.sessionCount > 0 { Text("\(summary.sessionCount)세션") }
            if summary.costUSD > 0 { Text("· $\(String(format: "%.2f", summary.costUSD))") }
            Spacer()
            if let last = summary.lastActivity {
                Text(last.formatted(date: .numeric, time: .omitted))
            }
        }
        .font(.amonCaption)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    // MARK: 펼침 전용 행

    /// 모델별 누적 전체 목록 (토큰 내림차순, 점유율 병기).
    @ViewBuilder
    private var modelListRows: some View {
        let total = summary.usage.total
        let sorted = summary.models.sorted { $0.value > $1.value }
        if total > 0, !sorted.isEmpty {
            SectionHeader("모델별 누적").padding(.top, 3)
            ForEach(sorted, id: \.key) { model, tokens in
                HStack(spacing: 6) {
                    Text(ModelBreakdown.shortName(model))
                        .font(.amonCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(Int((Double(tokens) / Double(total) * 100).rounded()))%")
                        .font(.amonCaption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Text(TokenFormat.compact(tokens))
                        .font(.amonCaption.weight(.medium))
                        .monospacedDigit()
                }
            }
        }
    }

    /// 최근 7일 소비 — 0 인 날은 생략. daily 는 30일치를 담으므로 보고 창으로 자른다.
    @ViewBuilder
    private var recentDailyRows: some View {
        let key = UsageScanner.reportWindowStartKey()
        let days = summary.daily
            .filter { $0.key >= key && $0.value.total > 0 }
            .sorted { $0.key > $1.key }
        if !days.isEmpty {
            SectionHeader("최근 7일").padding(.top, 3)
            ForEach(days, id: \.key) { day, u in
                // "yyyy-MM-dd" → "MM-dd"
                tokenRow(label: String(day.dropFirst(5)), usage: u)
            }
        }
    }
}
