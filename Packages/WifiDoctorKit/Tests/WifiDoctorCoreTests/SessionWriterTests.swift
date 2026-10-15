import Foundation
import Testing
@testable import WifiDoctorCore

@Suite struct SessionWriterTests {
    @Test func flushWritesOneTransactionPreservingOrder() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        var inet = SyntheticSession.target(id: 0, path: .wifi, role: .internetA); inet.id = try await w.insertTarget(inet)
        let a = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [])
        let b = SyntheticSession.probes(target: inet, startNs: 0, count: 5, lostSeqs: [])
        for p in zip(a, b).flatMap({ [$0.0, $0.1] }) { await w.enqueue(p) }
        for p in a.dropFirst(5) { await w.enqueue(p) }
        #expect(await w.pendingCount == 25)
        #expect(try await w.flush() == 25)
        #expect(await w.pendingCount == 0)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.probes(targetId: gw.id, fromMono: 0, toMono: .max).map(\.seq) == Array(0..<20))
    }
    @Test func allRowTypesRoundTrip() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        let s = WirelessSample(tMono: 5, state: .associated, rssiDbm: -60, noiseDbm: -90, txRateMbps: 540, channel: 36, band: 2, widthMhz: 80, bssid: nil, ssid: nil)
        await w.enqueue(s)
        await w.enqueue(LinkEvent(tMono: 6, kind: .bssidChanged, detail: "{\"rssi\":-70}"))
        await w.enqueue(SystemEvent(tMono: 7, kind: .awdl0State, detail: "up,running"))
        await w.enqueue(ClockAnchor(tMono: 8, tWallMs: 1_700_000_000_008))
        _ = try await w.flush()
        try await w.writeHops(HopList(path: .wifi, run: 0, tMono: 9, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1.2), Hop(index: 2, address: nil, rttMs: nil)]))
        let ev = OutageEvent(id: 1, startMono: 100, endMono: 400_000_100, suppressed: false, wiredOnly: false,
                             outages: [TargetOutage(targetId: 1, startMono: 100, endMono: 400_000_100, lostCount: 8, firstSeq: 2, lastSeq: 9, closedAtEnd: false)])
        let v = VerdictResult(eventId: 1, segment: .wireless, wirelessCause: .roaming, confidence: .high, reasonCode: nil, reason: "r", evidence: "{}")
        try await w.writeEvent(ev, verdict: v)
        try await w.finishSession(endedMonoNs: 999, sntpEnd: "unavailable", notes: nil)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.wirelessSamples(fromMono: 0, toMono: 10) == [s])
        #expect(try r.linkEvents().count == 1); #expect(try r.systemEvents().count == 1); #expect(try r.anchors().count == 1)
        #expect(try r.hops()[0].hops[1].address == nil)
        #expect(try r.outages()[0].lostCount == 8)
        #expect(try r.verdicts() == [v])
        #expect(try r.meta().endedMonoNs == 999); #expect(try r.meta().sntpEnd == "unavailable")
        #expect(try r.events()[0].bucket == .b02_05)
    }
    @Test func suppressedUpdate() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        try await w.writeEvent(OutageEvent(id: 3, startMono: 0, endMono: 300_000_000, suppressed: false, wiredOnly: false, outages: []), verdict: nil)
        try await w.updateEventSuppressed(id: 3, suppressed: true)
        #expect(try SessionStore.openReader(path: path).events()[0].suppressed)
    }
}
