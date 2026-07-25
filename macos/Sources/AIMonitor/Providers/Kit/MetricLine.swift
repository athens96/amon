import Foundation

// openusage 의 MetricLine 을 이식하되, 스팬드 트렌드 차트(.chart)는 제외한다 —
// A-mon 은 토큰/비용 집계를 이미 UsageScanner 로 하므로 라이브 쿼터 라인만 필요하다.

/// Provider output normalized into a small app-owned vocabulary.
enum ProgressFormat: Hashable, Sendable, Codable {
    case percent
    case dollars
    case count(suffix: String)

    var metricKind: MetricKind {
        switch self {
        case .percent: return .percent
        case .dollars: return .dollars
        case .count: return .count
        }
    }

    var countSuffix: String? {
        if case .count(let suffix) = self { return suffix }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, suffix }
    private enum Kind: String, Codable { case percent, dollars, count }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .percent: self = .percent
        case .dollars: self = .dollars
        case .count: self = .count(suffix: try container.decode(String.self, forKey: .suffix))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .percent: try container.encode(Kind.percent, forKey: .kind)
        case .dollars: try container.encode(Kind.dollars, forKey: .kind)
        case .count(let suffix):
            try container.encode(Kind.count, forKey: .kind)
            try container.encode(suffix, forKey: .suffix)
        }
    }
}

enum MetricLine: Hashable, Sendable, Codable {
    case text(label: String, value: String, colorHex: String? = nil, subtitle: String? = nil)
    /// 상한 없는 원시 숫자 행. `expiriesAt` 는 hover 로 노출할 미래 만료 시각(Codex 리셋 크레딧).
    /// `unknownModels` 는 스팬드 전용(이식 범위 밖)이지만 원본 시그니처를 유지해 매퍼 수정이 없게 둔다.
    case values(label: String, values: [MetricValue], colorHex: String? = nil, expiriesAt: [Date] = [], unknownModels: [String] = [])
    case progress(
        label: String,
        used: Double,
        limit: Double,
        format: ProgressFormat,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil,
        colorHex: String? = nil
    )
    case badge(label: String, text: String, colorHex: String? = nil, subtitle: String? = nil)

    var label: String {
        switch self {
        case .text(let label, _, _, _),
             .progress(let label, _, _, _, _, _, _),
             .values(let label, _, _, _, _),
             .badge(let label, _, _, _):
            return label
        }
    }

    static let errorBadgeLabel = "Error"

    var isError: Bool {
        if case .badge(let label, _, _, _) = self { return label == Self.errorBadgeLabel }
        return false
    }

    static let noUsageData = MetricLine.badge(label: "Status", text: "No usage data", colorHex: Palette.hexStatusNeutral)

    static func appendNoDataIfNeeded(_ lines: inout [MetricLine]) {
        if lines.isEmpty { lines.append(.noUsageData) }
    }

    private enum CodingKeys: String, CodingKey {
        case type, label, value, values, used, limit, format
        case resetsAt, expiriesAt, unknownModels, periodDurationMs, colorHex, subtitle, text
    }

    private enum LineType: String, Codable { case text, values, progress, badge }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decode(String.self, forKey: .label)
        switch try container.decode(LineType.self, forKey: .type) {
        case .text:
            self = .text(
                label: label,
                value: try container.decode(String.self, forKey: .value),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case .values:
            self = .values(
                label: label,
                values: try container.decode([MetricValue].self, forKey: .values),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                expiriesAt: try container.decodeIfPresent([Date].self, forKey: .expiriesAt) ?? [],
                unknownModels: try container.decodeIfPresent([String].self, forKey: .unknownModels) ?? []
            )
        case .progress:
            self = .progress(
                label: label,
                used: try container.decode(Double.self, forKey: .used),
                limit: try container.decode(Double.self, forKey: .limit),
                format: try container.decode(ProgressFormat.self, forKey: .format),
                resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
                periodDurationMs: try container.decodeIfPresent(Int.self, forKey: .periodDurationMs),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex)
            )
        case .badge:
            self = .badge(
                label: label,
                text: try container.decode(String.self, forKey: .text),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let label, let value, let colorHex, let subtitle):
            try container.encode(LineType.text, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        case .values(let label, let values, let colorHex, let expiriesAt, let unknownModels):
            try container.encode(LineType.values, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(values, forKey: .values)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            if !expiriesAt.isEmpty { try container.encode(expiriesAt, forKey: .expiriesAt) }
            if !unknownModels.isEmpty { try container.encode(unknownModels, forKey: .unknownModels) }
        case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, let colorHex):
            try container.encode(LineType.progress, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
            try container.encode(format, forKey: .format)
            try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
            try container.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
        case .badge(let label, let text, let colorHex, let subtitle):
            try container.encode(LineType.badge, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        }
    }
}
