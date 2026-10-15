import Foundation
import Testing
@testable import WifiDoctorCore

@Suite struct ReportModelBuilderTests {
    /// 사건 4개: WIRELESS 0.3초, WIRELESS 1.2초, HOST_STALL 0.5초, suppressed 2초. 앵커 2개(60초 점프).
    func makeStore() async throws -> String {
        let path = tempDBPath()
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        for p in SyntheticSession.probes(target: gw, startNs: 1_000, count: 2000, lostSeqs: [], lateSeqs: [5]) { await w.enqueue(p) }
        await w.enqueue(ClockAnchor(tMono: 1_000, tWallMs: 1_700_000_000_000))
        await w.enqueue(ClockAnchor(tMono: 50_000_001_000, tWallMs: 1_700_000_110_000))
        await w.enqueue(SystemEvent(tMono: 2_000, kind: .awdl0State, detail: "up"))
        await w.enqueue(LinkEvent(tMono: 3_000, kind: .scanCacheUpdated, detail: nil))
        await w.enqueue(LinkEvent(tMono: 4_000, kind: .scanCacheUpdated, detail: nil))
        _ = try await w.flush()
        let S: Int64 = 1_000_000_000
        func ev(_ id: Int, _ s: Int64, _ e: Int64, sup: Bool = false) -> OutageEvent { OutageEvent(id: id, startMono: s, endMono: e, suppressed: sup, wiredOnly: false, outages: []) }
        func vd(_ id: Int, _ seg: Segment) -> VerdictResult { VerdictResult(eventId: id, segment: seg, wirelessCause: seg == .wireless ? .roaming : nil, confidence: .high, reasonCode: nil, reason: "r", evidence: "{}") }
        try await w.writeEvent(ev(1, 10 * S, 10 * S + 300_000_000), verdict: vd(1, .wireless))
        try await w.writeEvent(ev(2, 20 * S, 21 * S + 200_000_000), verdict: vd(2, .wireless))
        try await w.writeEvent(ev(3, 30 * S, 30 * S + 500_000_000), verdict: vd(3, .hostStall))
        try await w.writeEvent(ev(4, 40 * S, 42 * S, sup: true), verdict: nil)
        try await w.writeHops(HopList(path: .wifi, run: 0, tMono: 0, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1)]))
        try await w.writeHops(HopList(path: .wired, run: 0, tMono: 0, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1)]))
        try await w.finishSession(endedMonoNs: 100 * S, sntpEnd: "unavailable", notes: nil)
        return path
    }
    @Test func aggregatesExcludeHostStallAndSuppressed() async throws {
        let path = try await makeStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let m = try ReportModelBuilder.build(reader: SessionStore.openReader(path: path), attachments: [], sessionFileName: "session-x.sqlite", sessionSha256: "00")
        #expect(m.countedEvents.map(\.id) == [1, 2])
        #expect(m.hostStallEvents.map(\.id) == [3]); #expect(m.suppressedEvents.map(\.id) == [4])
        #expect(m.bucketHistogram[.b02_05] == 1); #expect(m.bucketHistogram[.b1_25] == 1)
        #expect(m.segmentCounts[.wireless] == 2); #expect(m.segmentCounts[.hostStall] == nil)
        #expect(m.longestEvent?.id == 2)
        #expect(m.perHourCountOver1s.values.reduce(0, +) == 1)
        #expect(m.topology == .sameFirstHop)
        #expect(m.anchorJumps.count == 1); #expect(m.anchorJumps[0].jumpMs == 60_000)
        #expect(m.scanCacheUpdateCount == 2)
        #expect(m.probeStats.count == 2000); #expect(abs(m.lateRatio - 1.0 / 2000) < 1e-9)
        #expect(m.representative.count == 2); #expect(m.representative[0].event.id == 2)
        #expect(m.locationLimitation != nil)         // sampleMeta는 denied
        #expect(m.abnormalEnd == false)
        #expect(m.topSegmentSentence.contains("WIRELESS"))
    }

    @Test func roundTripsThroughCodableAndPairsSleepAndHandlesUnendedSession() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        await w.enqueue(SystemEvent(tMono: 5_000, kind: .willSleep, detail: nil))
        await w.enqueue(SystemEvent(tMono: 9_000, kind: .didWake, detail: nil))
        await w.enqueue(SystemEvent(tMono: 20_000, kind: .willSleep, detail: nil))
        _ = try await w.flush()
        let m = try ReportModelBuilder.build(reader: SessionStore.openReader(path: path), attachments: [CSVFileInfo(name: "a.csv", rows: 1)], sessionFileName: "s", sessionSha256: "00")
        #expect(m.abnormalEnd)
        #expect(m.sleepIntervals == [.init(start: 5_000, end: 9_000), .init(start: 20_000, end: 20_000)])
        #expect(m.topology == .unknown)
        #expect(m.longestEvent == nil); #expect(m.representative.isEmpty); #expect(m.lateRatio == 0)
        #expect(m.topSegmentSentence.contains("없습니다"))
        let back = try JSONDecoder().decode(ReportModel.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }
}
