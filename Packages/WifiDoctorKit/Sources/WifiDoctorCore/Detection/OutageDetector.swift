/// 대상 하나의 연속 손실을 끊김으로 판정한다. 규칙: k ≥ 2 이고 k × interval ≥ 0.2초.
public struct OutageDetector: Sendable {
    private let target: ProbeTarget
    private var runStart: ProbeResult?
    private var runCount = 0
    private var lastLost: ProbeResult?

    public init(target: ProbeTarget) { self.target = target }

    public mutating func feed(_ r: ProbeResult) -> TargetOutage? {
        if r.status.isLost {
            if runStart == nil { runStart = r }
            runCount += 1
            lastLost = r
            return nil
        }
        return closeRun(atEnd: false)
    }

    public mutating func finish() -> TargetOutage? { closeRun(atEnd: true) }

    private mutating func closeRun(atEnd: Bool) -> TargetOutage? {
        defer { runStart = nil; lastLost = nil; runCount = 0 }
        guard let first = runStart, let last = lastLost,
              runCount >= 2, Int64(runCount) * target.intervalNs >= 200_000_000 else { return nil }
        return TargetOutage(targetId: target.id, startMono: first.tSendMono,
                            endMono: last.tSendMono + target.intervalNs, lostCount: runCount,
                            firstSeq: first.seq, lastSeq: last.seq, closedAtEnd: atEnd)
    }
}
