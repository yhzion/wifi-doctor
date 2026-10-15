public enum NetPath: String, Sendable, Codable, Hashable { case wifi, wired }

public enum TargetRole: String, Sendable, Codable, Hashable {
    case gateway, apMgmt = "ap_mgmt", internetA = "internet_a", internetB = "internet_b", dns
}

public enum ProbeKind: String, Sendable, Codable { case icmp, dns }

public struct ProbeTarget: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var path: NetPath
    public var role: TargetRole
    public var address: String
    public var kind: ProbeKind
    public var intervalMs: Int      // 50 | 200
    public var timeoutMs: Int       // 1000
    public var icmpIdent: UInt16?
    public var intervalNs: Int64 { Int64(intervalMs) * 1_000_000 }
    public init(id: Int, path: NetPath, role: TargetRole, address: String, kind: ProbeKind,
                intervalMs: Int, timeoutMs: Int = 1000, icmpIdent: UInt16? = nil) {
        self.id = id
        self.path = path
        self.role = role
        self.address = address
        self.kind = kind
        self.intervalMs = intervalMs
        self.timeoutMs = timeoutMs
        self.icmpIdent = icmpIdent
    }
}

public enum ProbeStatus: Int, Sendable, Codable {
    case ok = 0, timeout = 1, late = 2, sendError = 3, unreachable = 4
    public var isLost: Bool { self != .ok }
}

public struct ProbeResult: Sendable, Codable, Equatable {
    public var targetId: Int
    public var seq: Int64
    public var tSendMono: Int64
    public var sendDelayUs: Int64
    public var rttUs: Int64?
    public var status: ProbeStatus
    public var ttl: Int?
    public init(targetId: Int, seq: Int64, tSendMono: Int64, sendDelayUs: Int64,
                rttUs: Int64?, status: ProbeStatus, ttl: Int?) {
        self.targetId = targetId
        self.seq = seq
        self.tSendMono = tSendMono
        self.sendDelayUs = sendDelayUs
        self.rttUs = rttUs
        self.status = status
        self.ttl = ttl
    }
}
