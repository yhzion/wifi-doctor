/// D1: SDK에 CWInterfaceState가 없어 앱이 정의한 값. DB wireless_sample.state에 그대로 저장.
public enum WirelessLinkState: Int, Sendable, Codable { case off = 0, disconnected = 1, associated = 2 }

public struct WirelessSample: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var state: WirelessLinkState
    public var rssiDbm: Int?        // 미참여(0)면 nil
    public var noiseDbm: Int?
    public var txRateMbps: Double?
    public var channel: Int?
    public var band: Int?           // CWChannelBand rawValue
    public var widthMhz: Int?
    public var bssid: String?       // 권한 없으면 nil
    public var ssid: String?
    public var snrDb: Int? { if let r = rssiDbm, let n = noiseDbm { return r - n }; return nil }
    public var isAssociated: Bool { state == .associated }
    public init(tMono: Int64, state: WirelessLinkState, rssiDbm: Int?, noiseDbm: Int?,
                txRateMbps: Double?, channel: Int?, band: Int?, widthMhz: Int?,
                bssid: String?, ssid: String?) {
        self.tMono = tMono
        self.state = state
        self.rssiDbm = rssiDbm
        self.noiseDbm = noiseDbm
        self.txRateMbps = txRateMbps
        self.channel = channel
        self.band = band
        self.widthMhz = widthMhz
        self.bssid = bssid
        self.ssid = ssid
    }
}

public enum LinkEventKind: String, Sendable, Codable {
    case linkDown = "link_down", linkUp = "link_up", bssidChanged = "bssid_changed",
         ssidChanged = "ssid_changed", scanCacheUpdated = "scan_cache_updated",
         powerChanged = "power_changed", linkQuality = "link_quality"
}

public struct LinkEvent: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var kind: LinkEventKind
    public var detail: String?      // JSON 문자열
    public init(tMono: Int64, kind: LinkEventKind, detail: String? = nil) {
        self.tMono = tMono
        self.kind = kind
        self.detail = detail
    }
}
