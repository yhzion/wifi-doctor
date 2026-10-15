public enum Segment: String, Sendable, Codable, CaseIterable {
    case wireless = "WIRELESS", wirelessUpstream = "WIRELESS_UPSTREAM", sharedFirstHop = "SHARED_FIRST_HOP",
         sharedAccess = "SHARED_ACCESS", sharedUpstream = "SHARED_UPSTREAM", internetPartial = "INTERNET_PARTIAL",
         wiredOnly = "WIRED_ONLY", hostStall = "HOST_STALL", undetermined = "UNDETERMINED"
}
public enum Confidence: String, Sendable, Codable {
    case high, medium, low
    public func lowered() -> Confidence { self == .high ? .medium : .low }
}
public enum WirelessCause: String, Sendable, Codable {
    case coverageInterference = "coverage_interference", congestionAp = "congestion_ap", roaming, disconnect
}
public struct VerdictResult: Sendable, Codable, Equatable {
    public var eventId: Int
    public var segment: Segment
    public var wirelessCause: WirelessCause?
    public var confidence: Confidence
    public var reasonCode: String?      // no_control, control_insufficient, partial_wifi_only, ... (6.3절)
    public var reason: String           // 사람이 읽는 근거
    public var evidence: String         // JSON: 대상별 상태·손실률, secondary, host_delay_partial, maxSendDelayUs
    public init(eventId: Int, segment: Segment, wirelessCause: WirelessCause?, confidence: Confidence,
                reasonCode: String?, reason: String, evidence: String) {
        self.eventId = eventId
        self.segment = segment
        self.wirelessCause = wirelessCause
        self.confidence = confidence
        self.reasonCode = reasonCode
        self.reason = reason
        self.evidence = evidence
    }
}
public enum JudgeOutcome: Sendable, Equatable {
    case suppressedBySleep              // P1
    case noLossInWindow                 // 14행. 사건을 suppressed로 표시
    case verdict(VerdictResult)
}
