import Testing
@testable import WifiDoctorCore

@Suite struct OutageDetectorTests {
    let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)       // 50ms
    let inet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)   // 200ms

    func run(_ t: ProbeTarget, _ probes: [ProbeResult]) -> [TargetOutage] {
        var d = OutageDetector(target: t); var out: [TargetOutage] = []
        for p in probes { if let o = d.feed(p) { out.append(o) } }
        if let o = d.finish() { out.append(o) }
        return out
    }
    @Test func threeLossesAt20HzIsNotOutage() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [5, 6, 7])
        #expect(run(gw, p).isEmpty)
    }
    @Test func fourLossesAt20HzIs200msOutage() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [5, 6, 7, 8])
        let o = run(gw, p); #expect(o.count == 1)
        #expect(o[0].startMono == 5 * 50_000_000)
        #expect(o[0].endMono == 8 * 50_000_000 + 50_000_000)
        #expect(o[0].lostCount == 4); #expect(o[0].firstSeq == 5); #expect(o[0].lastSeq == 8)
        #expect(o[0].closedAtEnd == false)
    }
    @Test func oneLossAt5HzIsNotOutageTwoIs400ms() {
        #expect(run(inet, SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3])).isEmpty)
        let o = run(inet, SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3, 4]))
        #expect(o.count == 1); #expect(o[0].endMono - o[0].startMono == 400_000_000)
    }
    @Test func lateCountsAsLoss() {
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3], lateSeqs: [4])
        #expect(run(inet, p).count == 1)
    }
    @Test func openOutageIsClosedAtFinish() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 10, lostSeqs: [6, 7, 8, 9])
        let o = run(gw, p); #expect(o.count == 1); #expect(o[0].closedAtEnd)
    }
}
