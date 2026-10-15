import Foundation

public struct ReportModel: Sendable, Codable, Equatable {
    public struct Period: Sendable, Codable, Equatable {
        public var start: Int64
        public var end: Int64
        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }
    }
    public struct Interval: Sendable, Codable, Equatable {
        public var start: Int64
        public var end: Int64
        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }
    }

    public var meta: SessionMeta
    public var targets: [ProbeTarget]
    public var periodWallMs: Period
    public var countedEvents: [OutageEvent]                 // suppressed·HOST_STALL 제외
    public var verdictsByEvent: [Int: VerdictResult]
    public var bucketHistogram: [DurationBucket: Int]
    public var perHourCountOver1s: [Int64: Int]             // 시간대 시작 wall ms → 건수
    public var segmentCounts: [Segment: Int]
    public var topSegmentSentence: String
    public var longestEvent: OutageEvent?
    public var topology: PathTopology
    public var hops: [HopList]
    public var topologyCaveat: String
    public var sharedAccessRepeatCount: Int
    public var hostStallEvents: [OutageEvent]
    public var suppressedEvents: [OutageEvent]
    public var anchors: [ClockAnchor]
    public var sleepIntervals: [Interval]                   // 단조 시각(ns)
    public var anchorJumps: [ClockAnchor.Jump]
    public var awdl0History: [SystemEvent]
    public var scanCacheUpdateCount: Int
    public var probeStats: ProbeStats
    public var lateRatio: Double
    public var representative: [RepresentativeEvent]
    public var attachments: [CSVFileInfo]
    public var sessionFileName: String
    public var sessionSha256: String
    public var locationLimitation: String?
    public var abnormalEnd: Bool

    /// 단조 시각(ns) → 벽시계 ms. 앵커가 있으면 앵커 기준, 없으면 세션 시작 기준.
    public func wallMs(forMono t: Int64) -> Int64 {
        Self.wallMs(forMono: t, anchors: anchors, meta: meta)
    }

    static func wallMs(forMono t: Int64, anchors: [ClockAnchor], meta: SessionMeta) -> Int64 {
        anchors.isEmpty ? meta.startedWallMs + (t - meta.startedMonoNs) / 1_000_000
                        : ClockAnchor.wallMs(forMono: t, anchors: anchors)
    }
}

public struct RepresentativeEvent: Sendable, Codable, Equatable {
    public var event: OutageEvent
    public var verdict: VerdictResult?
    public var probes: [ProbeResult]            // 사건 전후 10초, 모든 대상
    public var samples: [WirelessSample]
}
