import Testing
@testable import WifiDoctorCore

@Suite struct HostStallCheckTests {
    let wGw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
    var targets: [Int: ProbeTarget] { [1: wGw, 3: eGw] }
    let ev = OutageEvent(id: 1, startMono: 1_000_000_000, endMono: 1_400_000_000, suppressed: false, wiredOnly: false, outages: [])

    @Test func allTargetsDelayedIsStall() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [20: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [21: 55_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed); #expect(r.targetsInWindow == 2)
    }
    @Test func onlyWifiDelayedIsPartial() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [20: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed)
        #expect(r.maxSendDelayUsByTarget[1] == 60_000)
    }
    @Test func noDelayIsNotStall() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed == false)
    }
    @Test func delayOutsideWindowIsIgnored() {
        // 지연 프로브가 start − 0.6초(seq 8, t=0.4s)에만 있음
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [8: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [8: 60_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed == false)
    }
    @Test func delayedProbeIsCountedByScheduledTime() {   // R9
        // seq 28은 1.4초 예정, 2초 밀려 3.4초에 송신. 창 [0.5, 1.4]에 예정 시각으로 포함.
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [24, 25, 26, 27], delayedSeqs: [28: 2_000_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [28: 2_000_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed)
    }
    @Test func delayBelowIntervalIsNotDelayed() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [20: 49_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w, targets: [1: wGw])
        #expect(r.someTargetsDelayed == false)
    }
}
