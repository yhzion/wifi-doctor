import Foundation

/// 6.3절 결정표. 전제 검사(P1~P4) 뒤 첫 일치 행을 씁니다.
public enum Verdict {
    /// `nil` 조건 = `*`. 14행은 전제 검사에서 처리합니다.
    private struct Row: Sendable {
        var gwW: TargetState?
        var inetW: GroupState?
        var gwE: TargetState?
        var inetE: GroupState?
        var topo: @Sendable (PathTopology) -> Bool = { _ in true }
        var segment: Segment
        var confidence: Confidence = .low
        var reasonCode: String? = nil
        var reason: @Sendable (PathTopology) -> String = { _ in "" }
        var secondary: String? = nil
        var classify: Bool = false
    }

    private struct EvidencePayload: Encodable {
        var perTarget: [Int: WindowState]
        var gwW: TargetState
        var inetW: GroupState
        var gwE: TargetState
        var inetE: GroupState
        var apW: TargetState?
        var topology: String
        var secondary: String?
        var hostDelayPartial: Bool
        var maxSendDelayUsByTarget: [Int: Int64]
    }

    private static func isMergedLater(_ t: PathTopology) -> Bool {
        if case .mergedLater = t { return true }
        return false
    }

    private static func mergeHopReason(_ t: PathTopology) -> String {
        guard case .mergedLater(let wifiIndex, _) = t else { return "" }
        return "와이파이 게이트웨이와 유선 게이트웨이는 서로 다른 장비인데 같은 창에서 둘 다 응답하지 않았습니다. "
            + "경로 추적상 두 경로는 홉 \(wifiIndex)에서 만나므로 합류 지점 장애로는 설명되지 않습니다. "
            + "가능한 원인은 (1) 경로 추적에 보이지 않는 공유 L2 장비(예: 두 포트가 같은 액세스 스위치), "
            + "(2) 서로 무관한 두 장애의 우연한 겹침입니다. 이 사건이 반복되면 (1)의 가능성이 커집니다."
    }

    private static let rows: [Row] = [
        // 1
        Row(gwW: .down, gwE: .up, inetE: .up, segment: .wireless, confidence: .high,
            reason: { _ in "와이파이 게이트웨이만 응답 없음. 유선 경로는 정상. 무선 구간 문제" }, classify: true),
        // 2
        Row(gwW: .down, gwE: .up, inetE: .down, segment: .wireless, confidence: .medium,
            reason: { _ in "와이파이 게이트웨이 응답 없음. 무선 구간 문제. 같은 창에서 유선 경로의 인터넷 손실도 관측됨" },
            classify: true),
        // 3
        Row(gwW: .down, gwE: .down, topo: { $0 == .sameFirstHop }, segment: .sharedFirstHop, confidence: .high,
            reason: { _ in "두 경로의 공통 첫 홉(게이트웨이)이 응답 없음. 단일 공유기 구조 또는 동일 VLAN의 게이트웨이 자체 문제" }),
        // 4
        Row(gwW: .down, gwE: .down, topo: { isMergedLater($0) }, segment: .sharedAccess, confidence: .low,
            reason: { mergeHopReason($0) }),
        // 5
        Row(gwW: .down, gwE: .down, topo: { $0 == .noMerge || $0 == .unknown }, segment: .undetermined,
            confidence: .low, reasonCode: "both_gateways_down_no_topology",
            reason: { _ in "두 게이트웨이가 함께 응답 없음. 경로 합류 지점을 알 수 없어 구분 불가" }),
        // 6
        Row(gwW: .down, gwE: .unknown, segment: .undetermined, confidence: .low, reasonCode: "control_insufficient",
            reason: { _ in "와이파이 게이트웨이 응답 없음. 유선 게이트웨이 상태를 알 수 없어 대조 불가" }),
        // 7
        Row(gwW: .up, inetW: .down, gwE: .up, inetE: .up, segment: .wirelessUpstream, confidence: .medium,
            reason: {
                let base = "와이파이 경로만 게이트웨이 이후 구간에서 인터넷 손실. 유선 경로는 정상"
                return $0 == .sameFirstHop ? base + ". 공유기 내부(무선 측 포워딩/NAT) 의심. 추가 확인 필요" : base   // 6.5
            }),
        // 8
        Row(gwW: .up, inetW: .down, gwE: .up, inetE: .down, segment: .sharedUpstream, confidence: .high,
            reason: { _ in "두 경로 모두 게이트웨이는 응답하고 인터넷 손실. 게이트웨이 이후 공유 구간(공유기 WAN/NAT 또는 ISP/인터넷)" }),
        // 9
        Row(gwW: .up, inetW: .down, gwE: .up, inetE: .partial, segment: .internetPartial, confidence: .medium,
            reason: { _ in "와이파이 경로 인터넷 손실. 유선 경로는 일부 인터넷 대상만 손실. 특정 인터넷 대상 문제 가능성" }),
        // 10
        Row(gwW: .up, inetW: .partial, gwE: .up, inetE: .partial, segment: .internetPartial, confidence: .high,
            reason: { _ in "두 경로 모두 일부 인터넷 대상만 손실. 특정 인터넷 대상 문제" }),
        // 11
        Row(gwW: .up, inetW: .partial, gwE: .up, inetE: .up, segment: .wirelessUpstream, confidence: .low,
            reasonCode: "partial_wifi_only",
            reason: { _ in "와이파이 경로에서만 일부 인터넷 대상 손실. 와이파이 게이트웨이 이후 구간 또는 특정 대상 문제" }),
        // 12
        Row(gwW: .up, inetW: .down, gwE: .down, segment: .sharedUpstream, confidence: .low,
            reasonCode: "control_gateway_down",
            reason: { _ in "와이파이 경로 인터넷 손실과 유선 게이트웨이 응답 없음이 겹침. 유선 전용 문제와 게이트웨이 이후 공유 구간 문제를 함께 기록" },
            secondary: Segment.wiredOnly.rawValue),
        // 13
        Row(gwW: .up, gwE: .up, inetE: .unknown, segment: .undetermined, confidence: .low,
            reasonCode: "control_insufficient",
            reason: { _ in "유선 경로의 인터넷 상태를 알 수 없어 대조 불가" }),
        // 15
        Row(gwW: .unknown, inetW: .down, gwE: .up, inetE: .up, segment: .wireless, confidence: .low,
            reasonCode: "gateway_unknown",
            reason: { _ in "와이파이 게이트웨이 상태를 알 수 없음. 와이파이 경로만 인터넷 손실. 무선 구간 또는 와이파이 게이트웨이 이후 구간" },
            classify: true),
        // 16
        Row(gwW: .unknown, inetW: .down, gwE: .up, inetE: .down, segment: .sharedUpstream, confidence: .medium,
            reason: { _ in "와이파이 게이트웨이 상태를 알 수 없음. 두 경로 모두 인터넷 손실. 게이트웨이 이후 공유 구간" }),
    ]

    // 17
    private static let unmatched = Row(segment: .undetermined, confidence: .low, reasonCode: "unmatched",
                                       reason: { _ in "결정표의 어떤 행과도 맞지 않음. 상태는 evidence 참조" })

    public static func judge(event: OutageEvent, status: EventStatus, stall: HostStallResult,
                             topology: PathTopology, config: SessionConfig,
                             classify: (OutageEvent) -> WirelessCause?) -> JudgeOutcome {
        func result(_ segment: Segment, _ confidence: Confidence, _ reasonCode: String?, _ reason: String,
                    cause: WirelessCause? = nil, secondary: String? = nil) -> JudgeOutcome {
            .verdict(VerdictResult(eventId: event.id, segment: segment, wirelessCause: cause, confidence: confidence,
                                   reasonCode: reasonCode, reason: reason,
                                   evidence: evidence(status, stall, topology, secondary)))
        }

        if event.suppressed { return .suppressedBySleep }                                       // P1
        if event.wiredOnly {
            return result(.wiredOnly, .high, nil, "유선 경로에서만 끊김. 와이파이 경로는 정상")
        }
        if stall.allTargetsDelayed {                                                             // P2
            return result(.hostStall, .high, nil, "창 안의 모든 대상에서 송신 지연. 맥 자체 지연")
        }
        if status.gwW == .up && status.inetW == .up { return .noLossInWindow }                  // 14
        if status.controlForcedUnknown {
            return result(.undetermined, .low, "control_insufficient", "사건 창에서 유선 대조군 측정이 멈춰 대조 불가")
        }
        if config.wiredIf == nil || (status.gwE == .unknown && status.inetE == .unknown) {        // P3
            return result(.undetermined, .low, "no_control", noControlReason(status))
        }
        if status.gwW == .unknown && status.inetW == .unknown {                                  // P4
            return result(.undetermined, .low, "no_wifi_samples", "사건 창에 와이파이 경로 프로브 없음")
        }

        let row = rows.first { matches($0, status, topology) } ?? unmatched
        let segment = row.segment
        var confidence = row.confidence
        if status.hasWeak { confidence = confidence.lowered() }
        if stall.someTargetsDelayed { confidence = confidence.lowered() }
        let cause = row.classify ? classify(event) : nil
        var reason = row.reason(topology)
        if row.classify && cause == nil { reason += ". 무선 샘플 없음" }                           // 6.4
        if config.apMgmtIp != nil, segment == .wireless, let ap = status.apW {
            switch ap {
            case .up: reason += ". AP는 응답함. 무선 링크 또는 AP 무선부 문제"
            case .down: reason += ". AP 자체 또는 그 앞 무선 링크"
            case .unknown: break
            }
        }
        return result(segment, confidence, row.reasonCode, reason, cause: cause, secondary: row.secondary)
    }

    private static func matches(_ row: Row, _ s: EventStatus, _ topology: PathTopology) -> Bool {
        (row.gwW == nil || row.gwW == s.gwW) && (row.inetW == nil || row.inetW == s.inetW)
            && (row.gwE == nil || row.gwE == s.gwE) && (row.inetE == nil || row.inetE == s.inetE)
            && row.topo(topology)
    }

    /// 6.3.1 보조 설명.
    private static func noControlReason(_ s: EventStatus) -> String {
        let base = "유선 대조군 없음"
        switch (s.gwW, s.inetW) {
        case (.down, _):
            return base + ". 무선 구간 또는 게이트웨이 자체. 유선 대조군이 없어 구분 불가"
        case (.up, .down):
            return base + ". 게이트웨이 이후. 상위 장비 또는 ISP/인터넷. 유선 대조군이 없어 무선 VLAN 전용 경로 가능성 배제 불가"
        case (.up, .partial):
            return base + ". 특정 인터넷 대상 문제 가능성"
        default:
            return base
        }
    }

    private static func evidence(_ s: EventStatus, _ stall: HostStallResult, _ topology: PathTopology,
                                 _ secondary: String?) -> String {
        let payload = EvidencePayload(perTarget: s.perTarget, gwW: s.gwW, inetW: s.inetW, gwE: s.gwE, inetE: s.inetE,
                                      apW: s.apW, topology: String(describing: topology), secondary: secondary,
                                      hostDelayPartial: stall.someTargetsDelayed,
                                      maxSendDelayUsByTarget: stall.maxSendDelayUsByTarget)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
