import Foundation

public enum ReportModelBuilder {
    private static let anchorJumpThresholdMs: Int64 = 1000
    private static let representativeMarginNs: Int64 = 10_000_000_000
    private static let hourMs: Int64 = 3_600_000

    public static func build(reader: SessionReader, attachments: [CSVFileInfo],
                             sessionFileName: String, sessionSha256: String) throws -> ReportModel {
        let meta = try reader.meta()
        let targets = try reader.targets()
        let anchors = try reader.anchors()
        let events = try reader.events()
        let verdicts = Dictionary(try reader.verdicts().map { ($0.eventId, $0) }, uniquingKeysWith: { $1 })
        let hops = try reader.hops()
        let systemEvents = try reader.systemEvents()
        let probeStats = try reader.probeStats()

        func wallMs(_ mono: Int64) -> Int64 {
            anchors.isEmpty ? meta.startedWallMs + (mono - meta.startedMonoNs) / 1_000_000
                            : ClockAnchor.wallMs(forMono: mono, anchors: anchors)
        }

        var endMono = meta.endedMonoNs
        if endMono == nil {
            var last = meta.startedMonoNs
            try reader.forEachProbe { last = max(last, $0.tSendMono) }
            endMono = last
        }
        let sessionEndMono = endMono ?? meta.startedMonoNs

        let hostStallEvents = events.filter { !$0.suppressed && verdicts[$0.id]?.segment == .hostStall }
        let suppressedEvents = events.filter { $0.suppressed }
        let counted = events.filter { !$0.suppressed && verdicts[$0.id]?.segment != .hostStall }

        var histogram: [DurationBucket: Int] = [:]
        var perHour: [Int64: Int] = [:]
        var segmentCounts: [Segment: Int] = [:]
        for e in counted {
            histogram[e.bucket, default: 0] += 1
            if e.durationMs >= 1000 {
                let w = wallMs(e.startMono)
                perHour[Int64((Double(w) / Double(hourMs)).rounded(.down)) * hourMs, default: 0] += 1
            }
            if let v = verdicts[e.id] { segmentCounts[v.segment, default: 0] += 1 }
        }

        let top = segmentCounts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.rawValue > b.key.rawValue
        }
        let topSentence = top.map { "가장 많은 판정 구간은 \($0.key.rawValue)입니다. \($0.value)건입니다." }
            ?? "집계된 사건이 없습니다."

        let longest = counted.max { $0.durationMs < $1.durationMs }

        var representativeEvents: [OutageEvent] = []
        if let longest { representativeEvents.append(longest) }
        if let top {
            let ofTop = counted.filter { verdicts[$0.id]?.segment == top.key }
                .sorted { $0.durationMs != $1.durationMs ? $0.durationMs < $1.durationMs : $0.id < $1.id }
            let median = ofTop[(ofTop.count - 1) / 2]
            if !representativeEvents.contains(where: { $0.id == median.id }) { representativeEvents.append(median) }
        }
        let representative = try representativeEvents.map { e -> RepresentativeEvent in
            let from = e.startMono - representativeMarginNs, to = e.endMono + representativeMarginNs
            var probes: [ProbeResult] = []
            for t in targets { probes += try reader.probes(targetId: t.id, fromMono: from, toMono: to) }
            return RepresentativeEvent(event: e, verdict: verdicts[e.id], probes: probes,
                                       samples: try reader.wirelessSamples(fromMono: from, toMono: to))
        }

        func latestRun0(_ path: NetPath) -> HopList? {
            let lists = hops.filter { $0.path == path }
            guard let run = lists.map(\.run).max() else { return nil }
            return lists.first { $0.run == run }
        }
        let topology = PathCorrelator.topology(wifi: latestRun0(.wifi), wired: latestRun0(.wired))

        var sleeps: [ReportModel.Interval] = []
        var openSleep: Int64?
        for e in systemEvents {
            if e.kind == .willSleep, openSleep == nil { openSleep = e.tMono }
            else if e.kind == .didWake, let s = openSleep {
                sleeps.append(.init(start: s, end: e.tMono)); openSleep = nil
            }
        }
        if let s = openSleep { sleeps.append(.init(start: s, end: max(s, sessionEndMono))) }

        let endWall = wallMs(sessionEndMono)
        let location: String? = meta.locationAuth == "authorized" ? nil
            : "위치 권한 없음. SSID/BSSID 미기록. 로밍 세분이 제한됩니다."

        return ReportModel(
            meta: meta, targets: targets,
            periodWallMs: .init(start: meta.startedWallMs, end: endWall),
            countedEvents: counted, verdictsByEvent: verdicts, bucketHistogram: histogram,
            perHourCountOver1s: perHour, segmentCounts: segmentCounts, topSegmentSentence: topSentence,
            longestEvent: longest, topology: topology, hops: hops, topologyCaveat: caveat(topology),
            sharedAccessRepeatCount: segmentCounts[.sharedAccess] ?? 0,
            hostStallEvents: hostStallEvents, suppressedEvents: suppressedEvents,
            sleepIntervals: sleeps,
            anchorJumps: ClockAnchor.jumps(anchors: anchors, thresholdMs: anchorJumpThresholdMs),
            awdl0History: systemEvents.filter { $0.kind == .awdl0State },
            scanCacheUpdateCount: try reader.linkEvents().filter { $0.kind == .scanCacheUpdated }.count,
            probeStats: probeStats,
            lateRatio: probeStats.count == 0 ? 0 : Double(probeStats.lateCount) / Double(probeStats.count),
            representative: representative, attachments: attachments,
            sessionFileName: sessionFileName, sessionSha256: sessionSha256,
            locationLimitation: location, abnormalEnd: meta.endedMonoNs == nil)
    }

    private static func caveat(_ t: PathTopology) -> String {
        switch t {
        case .sameFirstHop:
            return "첫 홉 동일. 단일 공유기 구조 또는 동일 VLAN. 공유 구간이 길어 SHARED_* 판정 범위가 넓습니다."
        case .mergedLater(let w, let e):
            return "두 경로는 홉 \(w)/\(e)에서 합류합니다. 합류 전 홉은 각 경로 전용입니다. L2 장비는 보이지 않습니다."
        case .noMerge:
            return "20홉 안에서 합류하지 않았습니다. 공유 구간은 인터넷 어딘가로만 말할 수 있습니다."
        case .unknown:
            return "경로 탐지 실패. 결정표 5행(UNDETERMINED)이 늘어납니다."
        }
    }
}
