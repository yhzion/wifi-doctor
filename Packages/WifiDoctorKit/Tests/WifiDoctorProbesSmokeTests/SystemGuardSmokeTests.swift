import Foundation
import Testing
import WifiDoctorCore
import WifiDoctorProbes

@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct SystemGuardSmokeTests {
    @Test func sntpReturnsOffsetOrUnavailable() async {
        let s = await SystemGuard().sntpReport()
        #expect(s == "unavailable" || s.contains("time.apple.com"))
    }
    @Test func awdl0StateIsEmittedFirst() async {
        let g = SystemGuard()
        var first: SystemEvent?
        for await e in g.start() { first = e; break }
        g.stop()
        #expect(first?.kind == .awdl0State)
        #expect(first?.detail?.hasPrefix("up=") == true)      // 예: "up=1,running=1"
    }
    @Test func freeDiskIsPositive() {
        #expect((SystemGuard().freeDiskBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
}
