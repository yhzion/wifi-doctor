import Foundation
import Testing
@testable import WifiDoctorCore

func tempDBPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString).sqlite").path
}
func sampleMeta() -> SessionMeta {
    SessionMeta(schemaVersion: 1, appVersion: "0.1", osVersion: "27.0.1", startedWallMs: 1_700_000_000_000, startedMonoNs: 1_000,
                endedMonoNs: nil, wifiIf: "en0", wiredIf: "en11", wifiGateway: "192.0.2.1", wiredGateway: "198.51.100.1",
                apMgmtIp: nil, locationAuth: "denied", sntpStart: "+0.001 +/- 0.006 time.apple.com", sntpEnd: nil, notes: nil)
}

@Suite struct SessionStoreTests {
    @Test func createWritesPragmasAndSessionRow() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SessionStore.create(path: path, meta: sampleMeta())
        let r = try SessionStore.openReader(path: path)
        #expect(try r.meta() == sampleMeta())
        #expect(try r.pragmaUserVersion() == 1)
        #expect(try r.pragmaJournalMode() == "wal")
    }
    @Test func targetsAndProbesRoundTrip() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway)
        gw.id = try w.insertTarget(gw)
        let probes = SyntheticSession.probes(target: gw, startNs: 0, count: 100, lostSeqs: [10, 11], lateSeqs: [12])
        try w.write(probes: probes)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.targets() == [gw])
        let got = try r.probes(targetId: gw.id, fromMono: 0, toMono: 99 * 50_000_000)
        #expect(got == probes)
        let s = try r.probeStats()
        #expect(s.count == 100); #expect(s.lateCount == 1)
        #expect(try r.rowCount(table: "probe") == 100)
    }
    @Test func duplicatePrimaryKeyIsRejected() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try w.insertTarget(gw)
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 1, lostSeqs: [])
        try w.write(probes: p)
        #expect(throws: (any Error).self) { try w.write(probes: p) }
    }
}

@Suite struct SessionStoreExtraColumnsTests {
    @Test func verdictReasonCodeAndOutageClosedAtEndRoundTrip() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try w.insertTarget(gw)
        let c = try SQLiteConnection(path: path)
        try c.exec("""
            INSERT INTO event (id, start_mono, end_mono, duration_ms, bucket, suppressed) VALUES (1, 0, 400000000, 400, '0.2-0.5', 0);
            INSERT INTO outage (target_id, start_mono, end_mono, lost_count, first_seq, last_seq, event_id, closed_at_end)
              VALUES (\(gw.id), 0, 400000000, 8, 0, 7, 1, 1);
            INSERT INTO verdict (event_id, segment, wireless_cause, confidence, reason_code, reason, evidence)
              VALUES (1, 'UNDETERMINED', NULL, 'low', 'no_control', 'r', '{}');
            """)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.outages().map(\.closedAtEnd) == [true])
        #expect(try r.events().first?.outages.map(\.closedAtEnd) == [true])
        #expect(try r.verdicts().first?.reasonCode == "no_control")
    }
}
