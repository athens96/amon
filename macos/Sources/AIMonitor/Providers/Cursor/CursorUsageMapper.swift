import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CursorUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageAfterRefreshFailed
    case requestBasedUnavailable(String)
    case totalUsageLimitMissing
    case noActiveSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .usageAfterRefreshFailed:
            return "Usage request failed after refresh. Try again."
        case .requestBasedUnavailable(let message):
            return message
        case .totalUsageLimitMissing:
            return "Total usage limit missing from API response."
        case .noActiveSubscription:
            return "No active Cursor subscription."
        }
    }
}

enum CursorUsageMapper {
    static let billingPeriodMs = MetricPeriod.monthMs

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let hasPlanUsageLimit = ProviderParse.number(planUsage["limit"]) != nil
        let hasTotalUsagePercent = ProviderParse.number(planUsage["totalPercentUsed"]) != nil

        guard hasPlanUsageLimit || hasTotalUsagePercent else {
            throw CursorUsageError.totalUsageLimitMissing
        }

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let planUsedCents = ProviderParse.number(planUsage["totalSpend"])
            ?? ((ProviderParse.number(planUsage["limit"]) ?? 0) - (ProviderParse.number(planUsage["remaining"]) ?? 0))
        let computedPercentUsed = ProviderParse.number(planUsage["limit"]).flatMap { limit -> Double? in
            guard limit > 0 else { return nil }
            return planUsedCents / limit * 100
        } ?? 0
        let totalUsagePercent = ProviderParse.number(planUsage["totalPercentUsed"]) ?? computedPercentUsed

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
        let isTeamAccount = normalizedPlan == "team"
            || (spendLimitUsage?["limitType"] as? String)?.lowercased() == "team"
            || pooledLimit > 0

        if isTeamAccount {
            if let limitCents = ProviderParse.number(planUsage["limit"]) {
                lines.append(.progress(
                    label: "Total usage",
                    used: ProviderParse.centsToDollars(planUsedCents),
                    limit: ProviderParse.centsToDollars(limitCents),
                    format: .dollars,
                    resetsAt: cycle.resetsAt,
                    periodDurationMs: cycle.periodDurationMs
                ))
            } else if hasTotalUsagePercent {
                // 팀 시트인데 per-user 한도 센트(planUsage.limit)가 없는 계정 —
                // totalPercentUsed 는 내려오므로 개인 % 미터로 폴백한다.
                // (에러로 떨어뜨리면 아래 Auto/API/On-demand 팀 풀 라인까지 다 잃는다.)
                lines.append(.progress(
                    label: "Total usage",
                    used: totalUsagePercent,
                    limit: 100,
                    format: .percent,
                    resetsAt: cycle.resetsAt,
                    periodDurationMs: cycle.periodDurationMs
                ))
            } else {
                throw CursorUsageError.requestBasedUnavailable("Cursor request-based usage data unavailable. Try again later.")
            }
        } else {
            lines.append(.progress(
                label: "Total usage",
                used: totalUsagePercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let autoPercentUsed = ProviderParse.number(planUsage["autoPercentUsed"]) {
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercentUsed = ProviderParse.number(planUsage["apiPercentUsed"]) {
            lines.append(.progress(
                label: "API usage",
                used: apiPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let spendLimitUsage {
            let limit = ProviderParse.number(spendLimitUsage["individualLimit"]) ?? ProviderParse.number(spendLimitUsage["pooledLimit"]) ?? 0
            let remaining = ProviderParse.number(spendLimitUsage["individualRemaining"]) ?? ProviderParse.number(spendLimitUsage["pooledRemaining"]) ?? 0
            let spent = onDemandSpendCents(from: spendLimitUsage, limit: limit, remaining: remaining)
            if limit > 0 {
                lines.append(.progress(
                    label: "On-demand",
                    used: ProviderParse.centsToDollars(spent),
                    limit: ProviderParse.centsToDollars(limit),
                    format: .dollars
                ))
            } else if spent > 0 {
                lines.append(.values(
                    label: "On-demand",
                    values: [MetricValue(number: ProviderParse.centsToDollars(spent), kind: .dollars)]
                ))
            }
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    private static func onDemandSpendCents(from spendLimitUsage: [String: Any], limit: Double, remaining: Double) -> Double {
        let reported = [
            ProviderParse.number(spendLimitUsage["individualUsed"]),
            ProviderParse.number(spendLimitUsage["pooledUsed"]),
            ProviderParse.number(spendLimitUsage["totalSpend"])
        ].compactMap { $0 }
        if let positive = reported.first(where: { $0 > 0 }) {
            return positive
        }
        let inferred = max(0, limit - remaining)
        return inferred > 0 ? inferred : (reported.first ?? 0)
    }

    static func mapRequestBasedUsage(
        _ usage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        if let gpt4 = usage?["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(gpt4["maxRequestUsage"]),
           limit > 0 {
            let used = ProviderParse.number(gpt4["numRequests"]) ?? 0
            let cycleStart = (usage?["startOfMonth"] as? String).flatMap(OpenUsageISO8601.date(from:))
            lines.append(.progress(
                label: "Requests",
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycleStart?.addingTimeInterval(TimeInterval(billingPeriodMs) / 1000),
                periodDurationMs: billingPeriodMs
            ))
        }

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    static func shouldUseRequestBasedFallback(
        usage: [String: Any],
        planName: String?,
        planInfoUnavailable: Bool
    ) -> (shouldFallback: Bool, message: String) {
        guard usage["enabled"] as? Bool != false else {
            return (false, "")
        }

        let planUsage = usage["planUsage"] as? [String: Any]
        let hasPlanUsage = planUsage != nil
        let hasPlanUsageLimit = planUsage.flatMap { ProviderParse.number($0["limit"]) } != nil
        let planUsageLimitMissing = hasPlanUsage && !hasPlanUsageLimit
        let hasTotalUsagePercent = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) } != nil
        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // limit(센트 한도)가 없어도 totalPercentUsed 가 있으면 % 미터로 그릴 수 있으므로
        // 사용 가능으로 본다 — 팀 시트(per-user 한도 미제공)가 이 경우에 해당한다.
        // 요청기반 폴백으로 빠지면 mapUsage 의 Auto/API/On-demand(팀 풀) 라인까지 전부 잃는다.
        let planUsageUnusable = !hasPlanUsage || (planUsageLimitMissing && !hasTotalUsagePercent)

        if planUsageUnusable && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if planUsageUnusable && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if planUsageUnusable && !hasTotalUsagePercent && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
        let teamInferred = (spendLimitUsage?["limitType"] as? String)?.lowercased() == "team" || pooledLimit > 0
        if teamInferred && planUsageLimitMissing && !hasTotalUsagePercent {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
    }

    static func stripeBalanceCents(from response: HTTPResponse?) -> Double {
        guard let response,
              (200..<300).contains(response.statusCode),
              let stripe = ProviderParse.jsonObject(response.body),
              let balance = ProviderParse.number(stripe["customerBalance"]),
              balance < 0
        else {
            return 0
        }
        return abs(balance)
    }

    private static func appendCredits(creditGrants: [String: Any]?, stripeBalanceCents: Double, to lines: inout [MetricLine]) {
        let hasCreditGrants = creditGrants?["hasCreditGrants"] as? Bool == true
        let grantTotalCents = hasCreditGrants ? ProviderParse.number(creditGrants?["totalCents"]) ?? 0 : 0
        let grantUsedCents = hasCreditGrants ? ProviderParse.number(creditGrants?["usedCents"]) ?? 0 : 0
        let hasValidGrantData = hasCreditGrants && grantTotalCents > 0
        let combinedTotalCents = (hasValidGrantData ? grantTotalCents : 0) + stripeBalanceCents
        let remainingCents = max(0, combinedTotalCents - (hasValidGrantData ? grantUsedCents : 0))

        guard combinedTotalCents > 0 else { return }
        lines.append(.values(
            label: "Credits",
            values: [MetricValue(number: ProviderParse.centsToDollars(remainingCents), kind: .dollars)]
        ))
    }

    private static func billingCycle(from usage: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let cycleStart = ProviderParse.number(usage["billingCycleStart"])
        let cycleEnd = ProviderParse.number(usage["billingCycleEnd"])
        guard let cycleStart,
              let cycleEnd,
              cycleEnd > cycleStart
        else {
            return (cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }, billingPeriodMs)
        }
        return (
            Date(timeIntervalSince1970: cycleEnd / 1000),
            Int(cycleEnd - cycleStart)
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}
