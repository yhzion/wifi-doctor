import Testing
import WifiDoctorCore
import WifiDoctorProbes

@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct DNSProberSmokeTests {
    @Test func resolverReplies() async {
        let wifi = InterfaceDirectory().wifiInterface()!
        let t = ProbeTarget(id: 3, path: .wifi, role: .dns, address: "1.1.1.1", kind: .dns, intervalMs: 200)
        let p = DNSProber(interface: wifi, target: t)
        var first: ProbeResult?
        for await r in p.start() { first = r; break }
        p.stop()
        #expect(first?.status == .ok); #expect((first?.rttUs ?? 0) > 0)
    }
}
