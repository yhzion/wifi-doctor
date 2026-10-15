import Testing
@testable import WifiDoctorCore

@Suite struct VerdictTests {
    let ev = OutageEvent(id: 1, startMono: 0, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
    let cfg = SessionConfig(wifiIf: "en0", wiredIf: "en11", apMgmtIp: nil)
    let noStall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: false, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
    func st(_ gwW: TargetState, _ inetW: GroupState, _ gwE: TargetState, _ inetE: GroupState, weak: Bool = false, ap: TargetState? = nil) -> EventStatus {
        EventStatus(gwW: gwW, inetW: inetW, gwE: gwE, inetE: inetE, apW: ap, perTarget: [:], hasWeak: weak, controlForcedUnknown: false)
    }
    func judge(_ s: EventStatus, topo: PathTopology = .sameFirstHop, stall: HostStallResult? = nil, cfg: SessionConfig? = nil, cause: WirelessCause? = .congestionAp) -> VerdictResult? {
        if case .verdict(let v) = Verdict.judge(event: ev, status: s, stall: stall ?? noStall, topology: topo, config: cfg ?? self.cfg, classify: { _ in cause }) { return v }
        return nil
    }

    // 전제 검사
    @Test func p1SleepBeforeHostStall() {
        var e = ev; e.suppressed = true
        let stall = HostStallResult(allTargetsDelayed: true, someTargetsDelayed: false, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
        #expect(Verdict.judge(event: e, status: st(.down, .down, .down, .down), stall: stall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .suppressedBySleep)
    }
    @Test func p2HostStall() {
        let stall = HostStallResult(allTargetsDelayed: true, someTargetsDelayed: false, maxSendDelayUsByTarget: [1: 90_000], targetsInWindow: 2)
        let v = judge(st(.down, .down, .down, .down), stall: stall)
        #expect(v?.segment == .hostStall)
    }
    @Test func p3NoControlWhenWiredMissing() {
        let v = judge(st(.down, .up, .unknown, .unknown), cfg: SessionConfig(wifiIf: "en0", wiredIf: nil, apMgmtIp: nil))
        #expect(v?.segment == .undetermined); #expect(v?.reasonCode == "no_control")
        #expect(v?.reason.contains("유선 대조군이 없어") == true)   // 6.3.1 보조 설명
    }
    @Test func p3NoControlWhenBothWiredUnknown() {
        let v = judge(st(.up, .down, .unknown, .unknown))
        #expect(v?.reasonCode == "no_control"); #expect(v?.reason.contains("게이트웨이 이후") == true)
    }
    @Test func controlForcedUnknownBeatsP3() {   // R5
        var s = st(.down, .up, .unknown, .unknown); s.controlForcedUnknown = true
        #expect(judge(s)?.reasonCode == "control_insufficient")
    }
    @Test func p4NoWifiSamples() {
        #expect(judge(st(.unknown, .unknown, .up, .up))?.reasonCode == "no_wifi_samples")
    }

    // 결정표 17행. (GW_w, INET_w, GW_e, INET_e, topo, segment, confidence, reasonCode)
    @Test(arguments: [
        (TargetState.down, GroupState.up, TargetState.up, GroupState.up, PathTopology.sameFirstHop, Segment.wireless, Confidence.high, nil as String?),            // 1
        (.down, .up, .up, .down, .sameFirstHop, .wireless, .medium, nil),                        // 2
        (.down, .down, .down, .down, .sameFirstHop, .sharedFirstHop, .high, nil),                // 3
        (.down, .down, .down, .down, .mergedLater(wifiIndex: 3, wiredIndex: 2), .sharedAccess, .low, nil), // 4
        (.down, .down, .down, .down, .noMerge, .undetermined, .low, "both_gateways_down_no_topology"),     // 5
        (.down, .down, .down, .down, .unknown, .undetermined, .low, "both_gateways_down_no_topology"),     // 5
        (.down, .down, .unknown, .up, .sameFirstHop, .undetermined, .low, "control_insufficient"),          // 6
        (.up, .down, .up, .up, .sameFirstHop, .wirelessUpstream, .medium, nil),                  // 7
        (.up, .down, .up, .down, .sameFirstHop, .sharedUpstream, .high, nil),                    // 8
        (.up, .down, .up, .partial, .sameFirstHop, .internetPartial, .medium, nil),              // 9
        (.up, .partial, .up, .partial, .sameFirstHop, .internetPartial, .high, nil),             // 10
        (.up, .partial, .up, .up, .sameFirstHop, .wirelessUpstream, .low, "partial_wifi_only"), // 11
        (.up, .down, .down, .down, .sameFirstHop, .sharedUpstream, .low, "control_gateway_down"), // 12 (R4)
        (.up, .down, .up, .unknown, .sameFirstHop, .undetermined, .low, "control_insufficient"), // 13
        (.unknown, .down, .up, .up, .sameFirstHop, .wireless, .low, "gateway_unknown"),          // 15
        (.unknown, .down, .up, .down, .sameFirstHop, .sharedUpstream, .medium, nil),             // 16
        (.unknown, .up, .up, .up, .sameFirstHop, .undetermined, .low, "unmatched"),              // 17
    ])
    func decisionTable(row: (TargetState, GroupState, TargetState, GroupState, PathTopology, Segment, Confidence, String?)) {
        let (gwW, inetW, gwE, inetE, topo, seg, conf, code) = row
        let v = judge(st(gwW, inetW, gwE, inetE), topo: topo)
        #expect(v?.segment == seg); #expect(v?.confidence == conf); #expect(v?.reasonCode == code)
    }
    @Test func row14NoLossInWindow() {
        #expect(Verdict.judge(event: ev, status: st(.up, .up, .up, .up), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .noLossInWindow)
    }
    @Test func row2RecordsConcurrentUpstreamLoss() {
        #expect(judge(st(.down, .up, .up, .down))?.reason.contains("유선 경로의 인터넷 손실도 관측됨") == true)
    }
    @Test func row12RecordsSecondaryWiredOnly() {
        #expect(judge(st(.up, .down, .down, .down))?.evidence.contains("\"secondary\":\"WIRED_ONLY\"") == true)
    }
    @Test func row4ReasonMentionsMergeHop() {
        #expect(judge(st(.down, .down, .down, .down), topo: .mergedLater(wifiIndex: 3, wiredIndex: 2))?.reason.contains("홉 3") == true)
    }
    @Test func wirelessRowsCallClassifier() {
        #expect(judge(st(.down, .up, .up, .up), cause: .roaming)?.wirelessCause == .roaming)
        #expect(judge(st(.up, .down, .up, .up), cause: .roaming)?.wirelessCause == nil)   // 7행은 세분 안 함
    }
    @Test func weakLowersConfidence() {
        #expect(judge(st(.down, .up, .up, .up, weak: true))?.confidence == .medium)
    }
    @Test func partialHostDelayLowersConfidenceAndMarksEvidence() {
        let stall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: true, maxSendDelayUsByTarget: [1: 70_000], targetsInWindow: 2)
        let v = judge(st(.down, .up, .up, .up), stall: stall)
        #expect(v?.confidence == .medium); #expect(v?.evidence.contains("\"host_delay_partial\":true") == true)
    }
    @Test func weakAndPartialDelayLowerTwice() {
        let stall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: true, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
        #expect(judge(st(.down, .up, .up, .up, weak: true), stall: stall)?.confidence == .low)
    }
    @Test func apNoteWhenConfigured() {
        let c = SessionConfig(wifiIf: "en0", wiredIf: "en11", apMgmtIp: "192.0.2.10")
        #expect(judge(st(.down, .up, .up, .up, ap: .up), cfg: c)?.reason.contains("AP는 응답함") == true)
        #expect(judge(st(.down, .up, .up, .up, ap: .down), cfg: c)?.reason.contains("AP 자체 또는") == true)
    }
    @Test func wiredOnlyEventSkipsTable() {
        var e = ev; e.wiredOnly = true
        if case .verdict(let v) = Verdict.judge(event: e, status: st(.up, .up, .down, .down), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) {
            #expect(v.segment == .wiredOnly); #expect(v.confidence == .high)
        } else { Issue.record("expected verdict") }
    }
    // 6.5절 가정용 표 4행은 결정표 1, 3, 8, 10행 케이스와 같음(위 arguments에 포함).

    // 수정 1차(컨트롤러 판정)
    @Test func sleepBeatsWiredOnly() {
        var e = ev; e.wiredOnly = true; e.suppressed = true
        #expect(Verdict.judge(event: e, status: st(.up, .up, .down, .down), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .suppressedBySleep)
    }
    @Test func wirelessWithoutSamplesNotesIt() {
        let v = judge(st(.down, .up, .up, .up), cause: nil)
        #expect(v?.wirelessCause == nil); #expect(v?.reason.contains("무선 샘플 없음") == true)
    }
    @Test func row14BeatsNoControl() {
        let noWired = SessionConfig(wifiIf: "en0", wiredIf: nil, apMgmtIp: nil)
        #expect(Verdict.judge(event: ev, status: st(.up, .up, .unknown, .unknown), stall: noStall, topology: .sameFirstHop, config: noWired, classify: { _ in nil }) == .noLossInWindow)
    }
    @Test func row14BeatsRow13() {
        #expect(Verdict.judge(event: ev, status: st(.up, .up, .up, .unknown), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .noLossInWindow)
    }
    @Test func row7SameFirstHopSuspectsRouterInternals() {
        #expect(judge(st(.up, .down, .up, .up))?.reason.contains("공유기 내부(무선 측 포워딩/NAT) 의심. 추가 확인 필요") == true)
        #expect(judge(st(.up, .down, .up, .up), topo: .noMerge)?.reason.contains("공유기 내부") == false)
    }
}
