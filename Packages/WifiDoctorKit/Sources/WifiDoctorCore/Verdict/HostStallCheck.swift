import Foundation

public struct HostStallResult: Sendable, Codable, Equatable {
    public var allTargetsDelayed: Bool
    public var someTargetsDelayed: Bool
    public var maxSendDelayUsByTarget: [Int: Int64]
    public var targetsInWindow: Int
    public init(allTargetsDelayed: Bool, someTargetsDelayed: Bool,
                maxSendDelayUsByTarget: [Int: Int64], targetsInWindow: Int) {
        self.allTargetsDelayed = allTargetsDelayed
        self.someTargetsDelayed = someTargetsDelayed
        self.maxSendDelayUsByTarget = maxSendDelayUsByTarget
        self.targetsInWindow = targetsInWindow
    }
}

public enum HostStallCheck {
    /// 창 [start − 0.5초, end]. 창 소속은 예정 송신 시각(tSendMono − sendDelayUs × 1000)으로 봄(R9). 지연 = sendDelayUs ≥ intervalMs × 1000.
    public static func evaluate(event: OutageEvent, probes: [ProbeResult], targets: [Int: ProbeTarget]) -> HostStallResult {
        let windowStartNs = event.startMono - 500_000_000
        var maxDelayUsByTarget: [Int: Int64] = [:]
        for p in probes where targets[p.targetId] != nil {
            let scheduledNs = p.tSendMono - p.sendDelayUs * 1000
            guard scheduledNs >= windowStartNs, scheduledNs <= event.endMono else { continue }
            maxDelayUsByTarget[p.targetId] = max(maxDelayUsByTarget[p.targetId] ?? 0, p.sendDelayUs)
        }
        let delayedCount = maxDelayUsByTarget.filter { id, maxUs in
            maxUs >= Int64(targets[id]!.intervalMs) * 1000
        }.count
        let inWindow = maxDelayUsByTarget.count
        let all = inWindow > 0 && delayedCount == inWindow
        return HostStallResult(allTargetsDelayed: all,
                               someTargetsDelayed: delayedCount >= 1 && !all,
                               maxSendDelayUsByTarget: maxDelayUsByTarget,
                               targetsInWindow: inWindow)
    }
}
