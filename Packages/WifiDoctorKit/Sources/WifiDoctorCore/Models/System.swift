public enum SystemEventKind: String, Sendable, Codable {
    case awdl0State = "awdl0_state", willSleep = "will_sleep", didWake = "did_wake",
         interfaceLost = "interface_lost", interfaceBack = "interface_back",
         gatewayChanged = "gateway_changed", replyOnWrongInterface = "reply_on_wrong_interface",
         diskLow = "disk_low", probeError = "probe_error"
}

public struct SystemEvent: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var kind: SystemEventKind
    public var detail: String?
    public init(tMono: Int64, kind: SystemEventKind, detail: String? = nil) {
        self.tMono = tMono
        self.kind = kind
        self.detail = detail
    }
}

public struct ClockAnchor: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var tWallMs: Int64
    public init(tMono: Int64, tWallMs: Int64) {
        self.tMono = tMono
        self.tWallMs = tWallMs
    }

    /// anchors는 tMono 오름차순. tMono 이하에서 가장 가까운 앵커. 없으면 첫 앵커.
    public static func wallMs(forMono t: Int64, anchors: [ClockAnchor]) -> Int64 {
        let a = anchors.last(where: { $0.tMono <= t }) ?? anchors[0]
        return a.tWallMs + (t - a.tMono) / 1_000_000
    }

    public struct Jump: Sendable, Codable, Equatable {
        public var fromAnchor: ClockAnchor
        public var toAnchor: ClockAnchor
        public var jumpMs: Int64
        public init(fromAnchor: ClockAnchor, toAnchor: ClockAnchor, jumpMs: Int64) {
            self.fromAnchor = fromAnchor
            self.toAnchor = toAnchor
            self.jumpMs = jumpMs
        }
    }

    /// 인접 앵커 사이에서 (벽시계 차 − 단조 차)가 thresholdMs 이상이면 점프.
    public static func jumps(anchors: [ClockAnchor], thresholdMs: Int64) -> [Jump] {
        guard anchors.count > 1 else { return [] }
        var result: [Jump] = []
        for (from, to) in zip(anchors, anchors.dropFirst()) {
            let jumpMs = (to.tWallMs - from.tWallMs) - (to.tMono - from.tMono) / 1_000_000
            if jumpMs >= thresholdMs {
                result.append(Jump(fromAnchor: from, toAnchor: to, jumpMs: jumpMs))
            }
        }
        return result
    }
}
