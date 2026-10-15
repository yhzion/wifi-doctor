import Foundation

public protocol Prober: Sendable {
    var targets: [ProbeTarget] { get }
    func start() -> AsyncStream<ProbeResult>
    func stop()
}

public enum WirelessSignal: Sendable, Equatable {
    case sample(WirelessSample)
    case event(LinkEvent)
}

public protocol WirelessMonitoring: Sendable {
    func start() -> AsyncStream<WirelessSignal>
    func stop()
}

public protocol PathDiscovering: Sendable {
    func discover(path: NetPath, interface: String, run: Int) async -> HopList?
}

public protocol SystemGuarding: Sendable {
    func start() -> AsyncStream<SystemEvent>
    func stop()
    func sntpReport() async -> String
    func locationAuthorization() async -> String
    func freeDiskBytes(at: URL) -> Int64?
}
