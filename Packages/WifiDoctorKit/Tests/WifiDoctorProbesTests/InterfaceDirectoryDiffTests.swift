import Testing
import WifiDoctorCore
@testable import WifiDoctorProbes

/// InterfaceDirectory.diff의 순수 논리 검증. 주소는 RFC 5737 대역만 쓴다.
@Suite struct InterfaceDirectoryDiffTests {
    private func ni(_ bsd: String, wifi: Bool, ipv4: String?, gateway: String?, link: Bool, display: String? = nil) -> NetInterface {
        NetInterface(bsdName: bsd, index: 1, ipv4: ipv4, gateway: gateway,
                     displayName: display ?? bsd, isWifi: wifi, hasLink: link)
    }

    private func byBsd(_ list: [NetInterface]) -> [String: NetInterface] {
        Dictionary(list.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func renameRebindThenGatewayChangeFiresOnNewName() {
        let watched: Set<String> = ["en0", "en5"]
        // 감시 유선 en5(USB LAN)이 끊겨 복귀를 기다리는 상태. en0는 와이파이.
        let lost = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.1", link: true),
            ni("en5", wifi: false, ipv4: nil, gateway: nil, link: false, display: "USB LAN"),
        ])
        var state = InterfaceDirectory.WiredState()
        state.lostPorts = [.init(bsd: "en5", displayName: "USB LAN")]

        // 재연결: 같은 displayName의 포트가 다른 bsd 이름 en6으로 나타남(8장).
        let rebound = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.1", link: true),
            ni("en5", wifi: false, ipv4: nil, gateway: nil, link: false, display: "USB LAN"),
            ni("en6", wifi: false, ipv4: "192.0.2.21", gateway: "192.0.2.1", link: true, display: "USB LAN"),
        ])
        let (r1, s1) = InterfaceDirectory.diff(prev: lost, wired: state, next: rebound, watched: watched, tMono: 100)
        #expect(r1 == [
            SystemEvent(tMono: 100, kind: .interfaceBack, detail: "en6"),
            SystemEvent(tMono: 100, kind: .gatewayChanged, detail: "en6"),
        ])
        #expect(Set(s1.tracked.keys) == ["en6"])
        #expect(s1.lostPorts.isEmpty)

        // 이후 en6의 게이트웨이 변경 → 새 이름으로 gatewayChanged.
        // 회귀 대상: 감시 집합이 재바인딩된 유선 이름까지 확장되어야 한다.
        let changed = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.1", link: true),
            ni("en5", wifi: false, ipv4: nil, gateway: nil, link: false, display: "USB LAN"),
            ni("en6", wifi: false, ipv4: "192.0.2.21", gateway: "192.0.2.254", link: true, display: "USB LAN"),
        ])
        let (r2, _) = InterfaceDirectory.diff(prev: rebound, wired: s1, next: changed, watched: watched, tMono: 200)
        #expect(r2 == [SystemEvent(tMono: 200, kind: .gatewayChanged, detail: "en6")])
    }

    @Test func gatewayChangeOnWatchedNameFires() {
        let watched: Set<String> = ["en0", "en5"]
        let prev = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.1", link: true),
            ni("en5", wifi: false, ipv4: "192.0.2.20", gateway: "192.0.2.1", link: true),
        ])
        var state = InterfaceDirectory.WiredState()
        state.tracked = ["en5": "en5"]

        // 와이파이(en0)의 게이트웨이만 DHCP로 바뀜.
        let next = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.254", link: true),
            ni("en5", wifi: false, ipv4: "192.0.2.20", gateway: "192.0.2.1", link: true),
        ])
        let (events, nextState) = InterfaceDirectory.diff(prev: prev, wired: state, next: next, watched: watched, tMono: 300)
        #expect(events == [SystemEvent(tMono: 300, kind: .gatewayChanged, detail: "en0")])
        #expect(nextState.tracked == ["en5": "en5"])
    }

    @Test func wifiNeverEmitsInterfaceLostOrBack() {
        let watched: Set<String> = ["en0"]
        let prev = byBsd([
            ni("en0", wifi: true, ipv4: "192.0.2.10", gateway: "192.0.2.1", link: true),
        ])

        // 와이파이가 링크·주소·게이트웨이를 모두 잃음. 유선 사건은 내지 않는다.
        let next = byBsd([
            ni("en0", wifi: true, ipv4: nil, gateway: nil, link: false),
        ])
        let (events, nextState) = InterfaceDirectory.diff(prev: prev, wired: .init(), next: next, watched: watched, tMono: 400)
        #expect(events.filter { $0.kind == .interfaceLost || $0.kind == .interfaceBack }.isEmpty)
        #expect(nextState.tracked.isEmpty)
    }
}
