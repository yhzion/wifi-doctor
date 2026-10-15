import Foundation

public enum TargetState: String, Sendable, Codable { case up = "UP", down = "DOWN", unknown = "UNKNOWN" }
public enum GroupState: String, Sendable, Codable { case up = "UP", down = "DOWN", partial = "PARTIAL", unknown = "UNKNOWN" }

public struct WindowState: Sendable, Codable, Equatable {
    public var state: TargetState
    public var weak: Bool
    public var probeCount: Int
    public var lostCount: Int
    public init(state: TargetState, weak: Bool, probeCount: Int, lostCount: Int) {
        self.state = state
        self.weak = weak
        self.probeCount = probeCount
        self.lostCount = lostCount
    }
}

public struct EventStatus: Sendable, Codable, Equatable {
    public var gwW: TargetState
    public var inetW: GroupState
    public var gwE: TargetState
    public var inetE: GroupState
    public var apW: TargetState?
    public var perTarget: [Int: WindowState]
    public var hasWeak: Bool
    public var controlForcedUnknown: Bool
    public init(gwW: TargetState, inetW: GroupState, gwE: TargetState, inetE: GroupState, apW: TargetState?,
                perTarget: [Int: WindowState], hasWeak: Bool, controlForcedUnknown: Bool) {
        self.gwW = gwW
        self.inetW = inetW
        self.gwE = gwE
        self.inetE = inetE
        self.apW = apW
        self.perTarget = perTarget
        self.hasWeak = hasWeak
        self.controlForcedUnknown = controlForcedUnknown
    }
}

public enum WindowStatus {
    private static let expandNs: Int64 = 200_000_000

    public static func targetState(probes: [ProbeResult], start: Int64, end: Int64) -> WindowState {
        var inWindow = probes.filter { $0.tSendMono >= start && $0.tSendMono <= end }
        if inWindow.isEmpty {
            inWindow = probes.filter { $0.tSendMono >= start - expandNs && $0.tSendMono <= end + expandNs }
        }
        guard !inWindow.isEmpty else {
            return WindowState(state: .unknown, weak: false, probeCount: 0, lostCount: 0)
        }
        let lost = inWindow.filter { $0.status.isLost }.count
        let state: TargetState = Double(lost) / Double(inWindow.count) >= 0.5 ? .down : .up
        return WindowState(state: state, weak: inWindow.count < 2, probeCount: inWindow.count, lostCount: lost)
    }

    public static func combine(_ states: [TargetState]) -> GroupState {
        let known = Set(states.filter { $0 != .unknown })
        switch (known.contains(.down), known.contains(.up)) {
        case (true, true): return .partial
        case (true, false): return .down
        case (false, true): return .up
        case (false, false): return .unknown
        }
    }

    public static func evaluate(event: OutageEvent, probes: [ProbeResult], targets: [Int: ProbeTarget],
                                hasWired: Bool, controlForcedUnknown: Bool) -> EventStatus {
        var perTarget: [Int: WindowState] = [:]
        for (id, _) in targets {
            perTarget[id] = targetState(probes: probes.filter { $0.targetId == id },
                                        start: event.startMono, end: event.endMono)
        }
        // 프로브가 있는 대상만 사용한다. id 오름차순으로 고정한다.
        func used(_ path: NetPath, _ roles: [TargetRole]) -> [(id: Int, ws: WindowState)] {
            targets.values
                .filter { $0.path == path && roles.contains($0.role) }
                .sorted { $0.id < $1.id }
                .compactMap { t in
                    guard let ws = perTarget[t.id], ws.probeCount > 0 else { return nil }
                    return (t.id, ws)
                }
        }
        // 같은 역할 대상이 여럿이면 가장 최근(id가 큰) 대상을 쓴다.
        func single(_ path: NetPath, _ role: TargetRole) -> (id: Int, ws: WindowState)? {
            used(path, [role]).last
        }

        var weakUsed = false
        func gateway(_ path: NetPath) -> TargetState {
            guard let g = single(path, .gateway) else { return .unknown }
            weakUsed = weakUsed || g.ws.weak
            return g.ws.state
        }
        func internet(_ path: NetPath) -> GroupState {
            let u = used(path, [.internetA, .internetB, .dns])
            weakUsed = weakUsed || u.contains { $0.ws.weak }
            return combine(u.map { $0.ws.state })
        }

        let gwW = gateway(.wifi)
        let inetW = internet(.wifi)
        var apW: TargetState?
        if targets.values.contains(where: { $0.path == .wifi && $0.role == .apMgmt }) {
            if let a = single(.wifi, .apMgmt) {
                apW = a.ws.state
                weakUsed = weakUsed || a.ws.weak
            } else {
                apW = .unknown
            }
        }
        var gwE = TargetState.unknown
        var inetE = GroupState.unknown
        if hasWired && !controlForcedUnknown {
            gwE = gateway(.wired)
            inetE = internet(.wired)
        }
        return EventStatus(gwW: gwW, inetW: inetW, gwE: gwE, inetE: inetE, apW: apW,
                           perTarget: perTarget, hasWeak: weakUsed,
                           controlForcedUnknown: controlForcedUnknown)
    }
}
