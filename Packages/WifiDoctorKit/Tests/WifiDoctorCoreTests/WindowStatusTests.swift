import Testing
@testable import WifiDoctorCore

@Suite struct WindowStatusTests {
    let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let inet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)

    @Test func lossRatioAtLeastHalfIsDown() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let w = WindowStatus.targetState(probes: p, start: 4 * 50_000_000, end: 8 * 50_000_000)
        #expect(w.state == .down); #expect(w.probeCount == 5); #expect(w.lostCount == 4); #expect(w.weak == false)
    }
    @Test func noProbesExpandsOnceBy200ms() {
        // 5Hz 대상. 창 [0.21s, 0.39s]에는 프로브 없음(0.2s, 0.4s). 넓힌 창 [0.01, 0.59]에 2개.
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [])
        let w = WindowStatus.targetState(probes: p, start: 210_000_000, end: 390_000_000)
        #expect(w.state == .up); #expect(w.probeCount == 2)
    }
    @Test func stillNoProbesIsUnknown() {
        let w = WindowStatus.targetState(probes: [], start: 0, end: 200_000_000)
        #expect(w.state == .unknown)
    }
    @Test func singleProbeIsWeak() {
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [2])
        let w = WindowStatus.targetState(probes: p, start: 400_000_000, end: 450_000_000)
        #expect(w.state == .down); #expect(w.weak)
    }
    @Test func groupCombination() {
        #expect(WindowStatus.combine([.down, .down, .down]) == .down)
        #expect(WindowStatus.combine([.up, .up, .up]) == .up)
        #expect(WindowStatus.combine([.unknown, .down, .down]) == .down)
        #expect(WindowStatus.combine([.up, .down, .unknown]) == .partial)
        #expect(WindowStatus.combine([.unknown, .unknown, .unknown]) == .unknown)
    }
    @Test func gatewayTargetWithoutProbesIsIgnored() {
        // 게이트웨이 변경: id 1(이전, 창에 프로브 없음), id 9(현재). GW_w는 id 9로 계산.
        let newGw = SyntheticSession.target(id: 9, path: .wifi, role: .gateway)
        let p = SyntheticSession.probes(target: newGw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let ev = OutageEvent(id: 1, startMono: 200_000_000, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
        let s = WindowStatus.evaluate(event: ev, probes: p, targets: [1: gw, 9: newGw], hasWired: false, controlForcedUnknown: false)
        #expect(s.gwW == .down)
    }
    @Test func controlForcedUnknownOverridesWiredStates() {
        let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
        let p = SyntheticSession.probes(target: eGw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let ev = OutageEvent(id: 1, startMono: 200_000_000, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
        let s = WindowStatus.evaluate(event: ev, probes: p, targets: [3: eGw], hasWired: true, controlForcedUnknown: true)
        #expect(s.gwE == .unknown); #expect(s.inetE == .unknown); #expect(s.controlForcedUnknown)
    }
}
