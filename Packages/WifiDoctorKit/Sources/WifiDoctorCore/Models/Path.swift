public struct Hop: Sendable, Codable, Equatable {
    public var index: Int
    public var address: String?
    public var rttMs: Double?
    public init(index: Int, address: String?, rttMs: Double?) {
        self.index = index
        self.address = address
        self.rttMs = rttMs
    }
}

public struct HopList: Sendable, Codable, Equatable {
    public var path: NetPath
    public var run: Int
    public var tMono: Int64
    public var hops: [Hop]
    public init(path: NetPath, run: Int, tMono: Int64, hops: [Hop]) {
        self.path = path
        self.run = run
        self.tMono = tMono
        self.hops = hops
    }
}

public enum PathTopology: Sendable, Codable, Equatable {
    case sameFirstHop, mergedLater(wifiIndex: Int, wiredIndex: Int), noMerge, unknown
}
