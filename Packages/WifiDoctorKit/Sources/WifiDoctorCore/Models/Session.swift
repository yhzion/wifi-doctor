public enum CoreInfo {
    public static let schemaVersion = 1
}

public struct WirelessThresholds: Sendable, Codable, Equatable {
    public var rssiFloorDbm: Int = -75
    public var snrFloorDb: Int = 15
    public var rssiDropDb: Int = 10
    public static let `default` = WirelessThresholds()
    public init(rssiFloorDbm: Int = -75, snrFloorDb: Int = 15, rssiDropDb: Int = 10) {
        self.rssiFloorDbm = rssiFloorDbm
        self.snrFloorDb = snrFloorDb
        self.rssiDropDb = rssiDropDb
    }
}

public struct SessionConfig: Sendable, Codable, Equatable {
    public var wifiIf: String
    public var wiredIf: String?
    public var apMgmtIp: String?
    public var thresholds: WirelessThresholds = .default
    public init(wifiIf: String, wiredIf: String?, apMgmtIp: String?,
                thresholds: WirelessThresholds = .default) {
        self.wifiIf = wifiIf
        self.wiredIf = wiredIf
        self.apMgmtIp = apMgmtIp
        self.thresholds = thresholds
    }
}

public struct SessionMeta: Sendable, Codable, Equatable {   // session 테이블 1:1
    public var schemaVersion: Int, appVersion: String, osVersion: String
    public var startedWallMs: Int64, startedMonoNs: Int64, endedMonoNs: Int64?
    public var wifiIf: String, wiredIf: String?, wifiGateway: String?, wiredGateway: String?, apMgmtIp: String?
    public var locationAuth: String      // authorized | denied | notDetermined
    public var sntpStart: String?, sntpEnd: String?, notes: String?
    public init(schemaVersion: Int, appVersion: String, osVersion: String,
                startedWallMs: Int64, startedMonoNs: Int64, endedMonoNs: Int64?,
                wifiIf: String, wiredIf: String?, wifiGateway: String?, wiredGateway: String?,
                apMgmtIp: String?, locationAuth: String,
                sntpStart: String?, sntpEnd: String?, notes: String?) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.startedWallMs = startedWallMs
        self.startedMonoNs = startedMonoNs
        self.endedMonoNs = endedMonoNs
        self.wifiIf = wifiIf
        self.wiredIf = wiredIf
        self.wifiGateway = wifiGateway
        self.wiredGateway = wiredGateway
        self.apMgmtIp = apMgmtIp
        self.locationAuth = locationAuth
        self.sntpStart = sntpStart
        self.sntpEnd = sntpEnd
        self.notes = notes
    }
}
