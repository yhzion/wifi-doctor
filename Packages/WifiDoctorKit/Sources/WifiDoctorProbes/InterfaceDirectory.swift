import Darwin
import Foundation
import SystemConfiguration
import WifiDoctorCore

public struct NetInterface: Sendable, Equatable {
    public var bsdName: String
    public var index: UInt32
    public var ipv4: String?
    public var gateway: String?
    public var displayName: String
    public var isWifi: Bool
    public var hasLink: Bool

    public init(bsdName: String, index: UInt32, ipv4: String?, gateway: String?,
                displayName: String, isWifi: Bool, hasLink: Bool) {
        self.bsdName = bsdName
        self.index = index
        self.ipv4 = ipv4
        self.gateway = gateway
        self.displayName = displayName
        self.isWifi = isWifi
        self.hasLink = hasLink
    }
}

/// 인터페이스·게이트웨이 디렉터리.
/// Sendable 확증 방법: 저장 속성이 없다. 조회 메서드는 호출마다 즉석 스냅샷을 만들고,
/// SCDynamicStore는 메서드 호출 안에서 만들어 쓰고 버린다. 공유 가변 상태가 없다.
public final class InterfaceDirectory: Sendable {
    public init() {}

    public func wifiInterface() -> NetInterface? {
        Self.snapshot(store: nil).first(where: \.isWifi)
    }

    /// Ethernet + IPv4 + 링크 있음
    public func wiredCandidates() -> [NetInterface] {
        Self.snapshot(store: nil).filter(Self.isWiredCandidate)
    }

    public func interface(named name: String) -> NetInterface? {
        Self.snapshot(store: nil).first { $0.bsdName == name }
    }

    /// 감시 이름 전체의 게이트웨이 변경(gatewayChanged)과
    /// 유선 후보의 소실·복귀(interfaceLost / interfaceBack, 유선만. 와이파이는 내지 않는다)을 SystemEvent로 냄.
    /// detail에는 bsd 이름만 넣는다. 새 게이트웨이 주소는 이벤트가 아니라 새 target 행에 들어간다.
    public func changes(watching names: [String]) -> AsyncStream<SystemEvent> {
        let watched = Set(names)
        return AsyncStream { continuation in
            let watcher = ChangeWatcher(watched: watched, continuation: continuation)
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

extension InterfaceDirectory {
    /// Ethernet/IEEE80211 인터페이스 전체 스냅샷. store가 nil이면 조회 전용 store를 만들어 쓴다.
    static func snapshot(store: SCDynamicStore?) -> [NetInterface] {
        let queryStore = store
            ?? SCDynamicStoreCreate(nil, "WifiDoctor.InterfaceDirectory.query" as CFString, nil, nil)
        var gateways: [String: String] = [:]
        if let queryStore,
           let keys = SCDynamicStoreCopyKeyList(queryStore, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            for key in keys {
                guard let service = SCDynamicStoreCopyValue(queryStore, key as CFString) as? [String: Any],
                      let ifName = service["InterfaceName"] as? String,
                      let router = service["Router"] as? String else { continue }
                gateways[ifName] = router
            }
        }
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var result: [NetInterface] = []
        for ifc in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(ifc) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(ifc) as String? ?? ""
            let isWifi = type == (kSCNetworkInterfaceTypeIEEE80211 as String)
            guard isWifi || type == (kSCNetworkInterfaceTypeEthernet as String) else { continue }
            let link = linkState(of: bsd)
            result.append(NetInterface(
                bsdName: bsd,
                index: if_nametoindex(bsd),
                ipv4: link.ipv4,
                gateway: gateways[bsd],
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(ifc) as String? ?? bsd,
                isWifi: isWifi,
                hasLink: link.running
            ))
        }
        return result
    }

    static func isWiredCandidate(_ i: NetInterface) -> Bool {
        !i.isWifi && i.ipv4 != nil && i.hasLink
    }

    struct LinkInfo { var ipv4: String?; var running: Bool }

    /// getifaddrs: 첫 AF_INET 주소와 IFF_RUNNING.
    static func linkState(of bsd: String) -> LinkInfo {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return LinkInfo(ipv4: nil, running: false) }
        defer { freeifaddrs(ifap) }
        var info = LinkInfo(ipv4: nil, running: false)
        var cursor = ifap
        while let p = cursor {
            if String(cString: p.pointee.ifa_name) == bsd {
                if Int32(p.pointee.ifa_flags) & IFF_RUNNING != 0 { info.running = true }
                if info.ipv4 == nil, let sa = p.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        info.ipv4 = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    }
                }
            }
            cursor = p.pointee.ifa_next
        }
        return info
    }
}

/// changes(watching:) 하나의 감시 상태.
/// @unchecked Sendable이 불가피한 이유: SCDynamicStore의 C 콜백 문맥이 self를 날 포인터로 주고받는다.
/// 스위프트 컴파일러는 이 경유 격리를 증명할 수 없다. 실제 격리 규칙은 다음과 같다.
/// - 가변 상태(store, stopped, prevByBsd, tracked, lostPorts)는 전부 콜백 전용 직렬 큐에서만 만진다.
/// - continuation.yield도 그 큐(콜백)에서만, finish는 stop() 안에서만.
/// - 초기화는 큐 설정(SCDynamicStoreSetDispatchQueue) 전에 끝나므로 콜백과 경합하지 않는다.
/// - stop()은 큐에 정리를 올리고, 큐 밖에서 콜백 큐를 뗀다.
private final class ChangeWatcher: @unchecked Sendable {
    private let watched: Set<String>
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let queue: DispatchQueue

    private var store: SCDynamicStore?
    private var stopped = false
    private var prevByBsd: [String: NetInterface] = [:]
    /// bsdName -> displayName. 현재 접속된 감시 대상 유선 포트.
    private var tracked: [String: String] = [:]
    /// 끊겨서 복귀를 기다리는 유선 포트. 8장: 같은 displayName(하드웨어 포트)이면
    /// 다른 bsd 이름으로 나타나도 "돌아옴"으로 본다.
    private var lostPorts: [(bsd: String, displayName: String)] = []

    init(watched: Set<String>, continuation: AsyncStream<SystemEvent>.Continuation) {
        self.watched = watched
        self.continuation = continuation
        self.queue = DispatchQueue(label: "WifiDoctor.InterfaceDirectory.changes")
    }

    /// SCDynamicStore은 Sendable이 아니라 큐 경계를 넘지 못한다. 해제를 위한 래퍼.
    /// @unchecked가 불가피한 이유: 이 래퍼의 유일한 용도는 감시 종료 때 큐 밖에서
    /// SCDynamicStoreSetDispatchQueue(store, nil)을 한 번 부르는 것이다. 그 시점에
    /// 알림 키는 이미 지워져 다른 문맥이 store를 건드리지 않는다.
    private struct DetachableStore: @unchecked Sendable {
        let store: SCDynamicStore
    }

    private static let callback: SCDynamicStoreCallBack = { _, _, info in
        guard let info else { return }
        Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue().handleChange()
    }

    func start() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<ChangeWatcher>.fromOpaque($0).retain().toOpaque()) },
            release: { Unmanaged<ChangeWatcher>.fromOpaque($0).release() },
            copyDescription: nil
        )
        let patterns = ["State:/Network/Service/.*/IPv4", "State:/Network/Interface/.*/Link"] as CFArray
        guard let store = SCDynamicStoreCreate(
            nil, "WifiDoctor.InterfaceDirectory.changes" as CFString, Self.callback, &context
        ), SCDynamicStoreSetNotificationKeys(store, nil, patterns) else {
            continuation.finish()
            return
        }
        self.store = store
        // 초기 스냅샷. 콜백 큐 설정 전이라 경합이 없다.
        let snap = InterfaceDirectory.snapshot(store: store)
        prevByBsd = Dictionary(snap.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
        tracked = Dictionary(
            snap.filter { InterfaceDirectory.isWiredCandidate($0) && watched.contains($0.bsdName) }
                .map { ($0.bsdName, $0.displayName) },
            uniquingKeysWith: { a, _ in a }
        )
        SCDynamicStoreSetDispatchQueue(store, queue)
    }

    /// 스트림 종료(취소) 시 임의 문맥에서 호출. 알림을 끄고 콜백 큐를 뗀다.
    func stop() {
        queue.async { [self] in
            guard !stopped, let store else { return }
            stopped = true
            self.store = nil
            SCDynamicStoreSetNotificationKeys(store, nil, nil)
            let detach = DetachableStore(store: store)
            // 콜백 큐 안에서 SetDispatchQueue(nil)을 부르면 스스로 교착할 수 있어 큐 밖에서 뗀다.
            DispatchQueue.global().async {
                SCDynamicStoreSetDispatchQueue(detach.store, nil)
                self.continuation.finish()
            }
        }
    }

    /// 큐에서만 실행. 알림 키는 무시하고 매번 전체 스냅샷을 다시 만들어 이전 상태와 비교한다.
    private func handleChange() {
        guard !stopped, let store else { return }
        let snap = InterfaceDirectory.snapshot(store: store)
        let byBsd = Dictionary(snap.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
        let newWired = snap.filter(InterfaceDirectory.isWiredCandidate)
        var events: [SystemEvent] = []
        let t = MonotonicClock.nowNs()

        // 1) 감시 중이던 유선이 후보 목록에서 사라짐. 와이파이는 대상이 아니다.
        var nextTracked: [String: String] = [:]
        for (bsd, displayName) in tracked {
            if newWired.contains(where: { $0.bsdName == bsd }) {
                nextTracked[bsd] = displayName
            } else {
                events.append(SystemEvent(tMono: t, kind: .interfaceLost, detail: bsd))
                lostPorts.append((bsd: bsd, displayName: displayName))
            }
        }

        // 2) 새로 나타난 유선. 잃었던 포트와 bsd 이름이 같거나 displayName이 같으면 복귀(8장).
        //    감시 이름의 첫 등장은 "돌아옴"이 아니므로 추적만 한다.
        for w in newWired where nextTracked[w.bsdName] == nil {
            if let i = lostPorts.firstIndex(where: { $0.bsd == w.bsdName || $0.displayName == w.displayName }) {
                events.append(SystemEvent(tMono: t, kind: .interfaceBack, detail: w.bsdName))
                lostPorts.remove(at: i)
                nextTracked[w.bsdName] = w.displayName
            } else if watched.contains(w.bsdName) {
                nextTracked[w.bsdName] = w.displayName
            }
        }

        // 3) 감시 이름 전체의 게이트웨이 변경. nil <-> 주소 전환도 변경이다.
        for name in watched.sorted() {
            if prevByBsd[name]?.gateway != byBsd[name]?.gateway {
                events.append(SystemEvent(tMono: t, kind: .gatewayChanged, detail: name))
            }
        }

        tracked = nextTracked
        prevByBsd = byBsd
        for e in events { continuation.yield(e) }
    }
}
