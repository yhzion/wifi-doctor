import Foundation
@testable import WifiDoctorCore

private func finiteStream<T: Sendable>(_ items: [T]) -> AsyncStream<T> {
    AsyncStream { continuation in
        for item in items { continuation.yield(item) }
        continuation.finish()
    }
}

struct FakeProber: Prober {
    let targets: [ProbeTarget]
    let results: [ProbeResult]
    func start() -> AsyncStream<ProbeResult> { finiteStream(results) }
    func stop() {}
}

struct FakeWirelessMonitor: WirelessMonitoring {
    let signals: [WirelessSignal]
    func start() -> AsyncStream<WirelessSignal> { finiteStream(signals) }
    func stop() {}
}

struct FakePathDiscovery: PathDiscovering {
    let byPath: [NetPath: HopList?]
    func discover(path: NetPath, interface: String, run: Int) async -> HopList? {
        byPath[path] ?? nil
    }
}

struct FakeSystemGuard: SystemGuarding {
    var events: [SystemEvent] = []
    var sntp: String = "unavailable"
    var location: String = "authorized"
    var freeBytes: Int64? = nil
    func start() -> AsyncStream<SystemEvent> { finiteStream(events) }
    func stop() {}
    func sntpReport() async -> String { sntp }
    func locationAuthorization() async -> String { location }
    func freeDiskBytes(at: URL) -> Int64? { freeBytes }
}
