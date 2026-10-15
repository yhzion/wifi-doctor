import Testing
import WifiDoctorProbes

@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct InterfaceDirectorySmokeTests {
    @Test func findsWifiWithGateway() {
        let d = InterfaceDirectory()
        let w = d.wifiInterface()
        #expect(w?.bsdName == Smoke.wifiIf)
        #expect(w?.ipv4 != nil); #expect(w?.gateway != nil); #expect((w?.index ?? 0) > 0)
    }
    @Test func wiredCandidateMatchesEnvWhenCableConnected() {
        guard let wired = Smoke.wiredIf else { return }
        let names = InterfaceDirectory().wiredCandidates().map(\.bsdName)
        #expect(names.contains(wired))      // 케이블 미연결이면 실패가 정상. 결과를 기록만 함
    }
}
