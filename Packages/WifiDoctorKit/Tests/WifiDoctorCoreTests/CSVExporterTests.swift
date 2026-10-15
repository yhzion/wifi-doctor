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
}
