import Testing
@testable import WifiDoctorCore

@Suite struct FakesTests {
    @Test func fakeProberEmitsAllInOrder() async {
        let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
        let probes = SyntheticSession.probes(target: gw, startNs: 0, count: 5, lostSeqs: [])
        let p = FakeProber(targets: [gw], results: probes)
        var got: [ProbeResult] = []
        for await r in p.start() { got.append(r) }
        #expect(got == probes)
    }
    @Test func fakePathDiscoveryReturnsConfigured() async {
        let hl = HopList(path: .wifi, run: 0, tMono: 0, hops: [])
        let d = FakePathDiscovery(byPath: [.wifi: hl, .wired: nil])
        #expect(await d.discover(path: .wifi, interface: "en0", run: 0) == hl)
        #expect(await d.discover(path: .wired, interface: "en11", run: 0) == nil)
    }
}
