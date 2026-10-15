import Foundation
import Testing
@testable import WifiDoctorCore

@Suite struct CSVExporterTests {
    @Test func writesEightFilesWithMonoAndWallColumns() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        for p in SyntheticSession.probes(target: gw, startNs: 1_000, count: 10, lostSeqs: []) { await w.enqueue(p) }
        await w.enqueue(ClockAnchor(tMono: 1_000, tWallMs: 1_700_000_000_000))
        _ = try await w.flush()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let infos = try CSVExporter.export(reader: SessionStore.openReader(path: path), to: dir)
        #expect(infos.map(\.name).sorted() == ["clock_anchor.csv", "hop.csv", "link_event.csv", "outage.csv", "probe.csv", "system_event.csv", "verdict.csv", "wireless_sample.csv"])
        #expect(infos.first { $0.name == "probe.csv" }?.rows == 10)
        let text = try String(contentsOf: dir.appendingPathComponent("probe.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines[0] == "target_id,seq,t_send_mono,t_wall_ms,send_delay_us,rtt_us,status,ttl")
        #expect(lines[1].hasPrefix("1,0,1000,1700000000000,"))
        #expect(lines.count == 11)
    }

    private func exportDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString)")
    }

    @Test func quotesSpecialCharactersInStringFields() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        await w.enqueue(LinkEvent(tMono: 5, kind: .linkQuality, detail: "{\"rssi\":-70,\"note\":\"a,b\"}"))
        await w.enqueue(SystemEvent(tMono: 6, kind: .probeError, detail: "줄1\n줄2"))
        _ = try await w.flush()
        let ev = OutageEvent(id: 1, startMono: 100, endMono: 400_000_100, suppressed: false, wiredOnly: false, outages: [])
        let v = VerdictResult(eventId: 1, segment: .wireless, wirelessCause: nil, confidence: .high, reasonCode: nil,
                              reason: "said \"hi\", then left", evidence: "{}")
        try await w.writeEvent(ev, verdict: v)
        let dir = exportDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CSVExporter.export(reader: SessionStore.openReader(path: path), to: dir)
        let link = try String(contentsOf: dir.appendingPathComponent("link_event.csv"), encoding: .utf8)
        #expect(link.contains("5,,\"link_quality\",\"{\"\"rssi\"\":-70,\"\"note\"\":\"\"a,b\"\"}\"\n"))
        let sys = try String(contentsOf: dir.appendingPathComponent("system_event.csv"), encoding: .utf8)
        #expect(sys.contains("6,,\"probe_error\",\"줄1\n줄2\"\n"))
        let ver = try String(contentsOf: dir.appendingPathComponent("verdict.csv"), encoding: .utf8)
        #expect(ver.contains("1,\"WIRELESS\",,\"high\",,\"said \"\"hi\"\", then left\",\"{}\"\n"))
    }

    @Test func emptyAnchorsGiveBlankWallAndNilFieldsAreEmpty() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        for p in SyntheticSession.probes(target: gw, startNs: 1_000, count: 3, lostSeqs: [1]) { await w.enqueue(p) }
        _ = try await w.flush()
        let dir = exportDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CSVExporter.export(reader: SessionStore.openReader(path: path), to: dir)
        let lines = try String(contentsOf: dir.appendingPathComponent("probe.csv"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("1,0,1000,,"))
        let timeout = lines[2].split(separator: ",", omittingEmptySubsequences: false)
        #expect(timeout[3] == "")      // t_wall_ms
        #expect(timeout[5] == "")      // rtt_us
        #expect(timeout[7] == "")      // ttl
    }

    @Test func outageCsvCarriesOutageAndEventIds() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        let ev = OutageEvent(id: 7, startMono: 100, endMono: 400_000_100, suppressed: false, wiredOnly: false,
                             outages: [TargetOutage(targetId: 1, startMono: 100, endMono: 400_000_100, lostCount: 8, firstSeq: 2, lastSeq: 9, closedAtEnd: false)])
        try await w.writeEvent(ev, verdict: nil)
        let dir = exportDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CSVExporter.export(reader: SessionStore.openReader(path: path), to: dir)
        let lines = try String(contentsOf: dir.appendingPathComponent("outage.csv"), encoding: .utf8).split(separator: "\n")
        #expect(lines[0] == "id,event_id,target_id,start_mono,t_wall_ms,end_mono,lost_count,first_seq,last_seq,closed_at_end")
        #expect(lines[1] == "1,7,1,100,,400000100,8,2,9,0")
    }
}
