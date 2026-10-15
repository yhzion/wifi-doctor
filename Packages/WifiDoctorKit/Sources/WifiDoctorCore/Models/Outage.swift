public struct TargetOutage: Sendable, Codable, Equatable {
    public var targetId: Int
    public var startMono: Int64     // 첫 손실 t_send_mono
    public var endMono: Int64       // 마지막 손실 t_send_mono + interval
    public var lostCount: Int
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var closedAtEnd: Bool    // 세션 종료로 닫힘
    public init(targetId: Int, startMono: Int64, endMono: Int64, lostCount: Int,
                firstSeq: Int64, lastSeq: Int64, closedAtEnd: Bool) {
        self.targetId = targetId
        self.startMono = startMono
        self.endMono = endMono
        self.lostCount = lostCount
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.closedAtEnd = closedAtEnd
    }
}

public enum DurationBucket: String, Sendable, Codable, CaseIterable {
    case b02_05 = "0.2-0.5", b05_1 = "0.5-1", b1_25 = "1-2.5", b25_10 = "2.5-10", b10plus = "10+"
    public static func of(durationMs d: Int64) -> DurationBucket {
        if d < 500 { return .b02_05 }; if d < 1000 { return .b05_1 }
        if d < 2500 { return .b1_25 }; if d < 10_000 { return .b25_10 }; return .b10plus
    }
}

public struct OutageEvent: Sendable, Codable, Equatable {
    public var id: Int
    public var startMono: Int64
    public var endMono: Int64
    public var durationMs: Int64 { (endMono - startMono) / 1_000_000 }
    public var bucket: DurationBucket { .of(durationMs: durationMs) }
    public var suppressed: Bool
    public var wiredOnly: Bool              // 5.2절 3항 사건
    public var outages: [TargetOutage]
    public init(id: Int, startMono: Int64, endMono: Int64, suppressed: Bool,
                wiredOnly: Bool, outages: [TargetOutage]) {
        self.id = id
        self.startMono = startMono
        self.endMono = endMono
        self.suppressed = suppressed
        self.wiredOnly = wiredOnly
        self.outages = outages
    }
}
