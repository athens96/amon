import Foundation

/// MetricLine 값 표시용 경량 포매터. (openusage MetricFormatter 는 이식하지 않고, 팝오버에
/// 필요한 최소 포맷만 여기서 제공한다.)
enum MetricFormat {
    /// 큰 수를 compact 표기 (1_250_000 → "1.2M", 12_400 → "12.4K").
    static func compact(_ value: Double) -> String {
        let n = abs(value)
        switch n {
        case 1_000_000_000...:
            return trim(value / 1_000_000_000) + "B"
        case 1_000_000...:
            return trim(value / 1_000_000) + "M"
        case 1_000...:
            return trim(value / 1_000) + "K"
        default:
            return String(Int(value.rounded()))
        }
    }

    /// 달러 표기 — 1000 미만은 소수 2자리($4.08), 이상은 compact($1.2K).
    static func dollars(_ value: Double) -> String {
        if abs(value) >= 1000 { return "$" + compact(value) }
        return String(format: "$%.2f", value)
    }

    /// 퍼센트 표기 (정수 반올림, "42%").
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// 한 MetricValue 를 종류에 맞게 포맷.
    static func value(_ v: MetricValue) -> String {
        switch v.kind {
        case .dollars:
            return dollars(v.number)
        case .percent:
            return percent(v.number)
        case .count:
            let num = abs(v.number) >= 1000 ? compact(v.number) : String(Int(v.number.rounded()))
            if let label = v.label, !label.isEmpty { return "\(num) \(label)" }
            return num
        }
    }

    /// `.values` 행의 여러 값을 " · " 로 결합 ("$4.08 · 1.2M tokens").
    static func values(_ vs: [MetricValue]) -> String {
        vs.map(value).joined(separator: " · ")
    }

    /// 전체 자릿수(그룹핑) 표기 — 축약된 행의 호버 툴팁용 (openusage `.full` 스타일).
    /// 예: 1_506_025_363 → "1,506,025,363", 2059.07 → "$2,059.07".
    static func fullValue(_ v: MetricValue) -> String {
        let text: String
        switch v.kind {
        case .dollars:
            text = "$" + grouped(v.number, fractionDigits: 2)
        case .percent:
            text = "\(Int(v.number.rounded()))%"
        case .count:
            text = grouped(v.number, fractionDigits: v.number == v.number.rounded() ? 0 : 1)
        }
        if let label = v.label, !label.isEmpty { return "\(text) \(label)" }
        return text
    }

    /// 여러 값의 전체 자릿수 결합 — 축약이 있을 때만 툴팁으로 쓸 것 (openusage 동일 규칙).
    static func fullValues(_ vs: [MetricValue]) -> String {
        vs.map(fullValue).joined(separator: " · ")
    }

    /// 축약이 실제로 일어나는가 — 1000 이상 값이 하나라도 있으면 툴팁 가치가 있다.
    static func hasAbbreviation(_ vs: [MetricValue]) -> Bool {
        vs.contains { abs($0.number) >= 1000 }
    }

    private static func grouped(_ value: Double, fractionDigits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = fractionDigits
        return f.string(from: value as NSNumber) ?? String(format: "%.\(fractionDigits)f", value)
    }

    /// progress 행의 "사용/한도" 트레일링 텍스트.
    static func progressTrailing(used: Double, limit: Double, format: ProgressFormat) -> String {
        switch format {
        case .percent:
            return percent(used)
        case .dollars:
            return "\(dollars(used)) / \(dollars(limit))"
        case .count(let suffix):
            let u = abs(used) >= 1000 ? compact(used) : String(Int(used.rounded()))
            let l = abs(limit) >= 1000 ? compact(limit) : String(Int(limit.rounded()))
            let s = suffix.isEmpty ? "" : " \(suffix)"
            return "\(u) / \(l)\(s)"
        }
    }

    /// progress 채움 비율 0...1. percent 는 used/100, 그 외는 used/limit.
    static func progressFraction(used: Double, limit: Double, format: ProgressFormat) -> Double {
        switch format {
        case .percent:
            return max(0, min(used / 100, 1))
        default:
            guard limit > 0 else { return 0 }
            return max(0, min(used / limit, 1))
        }
    }

    /// resetsAt 까지 남은 시간 축약 ("3d 4h", "12h 5m", "8m", 지났으면 nil).
    static func countdown(to date: Date, now: Date = Date()) -> String? {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    private static func trim(_ value: Double) -> String {
        // 소수 첫째자리까지, 정수면 소수 제거 (1.0 → "1", 1.25 → "1.2").
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}
