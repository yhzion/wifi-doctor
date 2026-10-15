import Foundation
import Testing
@testable import WifiDoctorCore

@Suite struct SessionPipelineTests {
    let S: Int64 = 1_000_000_000
    struct Rig {
        let pipeline: SessionPipeline; let writer: SessionWriter; let path: String; let targets: [ProbeTarget]
        var wg: ProbeTarget { targets[0] }; var wi: ProbeTarget { targets[1] }
        var eg: ProbeTarget { targets[2] }; var ei: ProbeTarget { targets[3] }
    }

    /// 와이파이 gw/inetA, 유선 gw/inetA 네 대상. 60초 분량.
    func rig(wired: Bool = true) async throws -> Rig {
        let path = tempDBPath()
        var meta = sampleMeta(); meta.wiredIf = wired ? "en11" : nil
        let w = try SessionStore.create(path: path, meta: meta)
        var ts = [SyntheticSession.target(id: 0, path: .wifi, role: .gateway), SyntheticSession.target(id: 0, path: .wifi, role: .internetA)]
        if wired { ts += [SyntheticSession.target(id: 0, path: .wired, role: .gateway), SyntheticSession.target(id: 0, path: .wired, role: .internetA)] }
        for i in ts.indices { ts[i].id = try await w.insertTarget(ts[i]) }
        let cfg = SessionConfig(wifiIf: "en0", wiredIf: wired ? "en11" : nil, apMgmtIp: nil)
        return Rig(pipeline: SessionPipeline(config: cfg, targets: ts, writer: w, topology: .sameFirstHop), writer: w, path: path, targets: ts)
    }
    /// 대상별 프로브 배열을 예정 송신 시각 순으로 섞어 ingest. 실제 Prober처럼 대상별 순번 순서를 지킵니다.
    func feed(_ r: Rig, _ lists: [[ProbeResult]]) async {
        func scheduled(_ p: ProbeResult) -> Int64 { p.tSendMono - p.sendDelayUs * 1000 }
        for p in lists.joined().sorted(by: { scheduled($0) < scheduled($1) }) { await r.pipeline.ingest(p) }
    }

    @Test func wifiGatewayLossWithHealthyWiredIsWireless() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        let lost: Set<Int64> = Set(400..<420)            // 20초~21초, 1초 끊김
        // 사건은 프로브가 창을 지나면 바로 판정되므로 무선 샘플을 먼저 넣습니다.
        for s in SyntheticSession.samples(startNs: 0, count: 300, rssi: { _ in -60 }) { await r.pipeline.ingest(s) }
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: lost),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out.count == 1)
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .wireless); #expect(v.wirelessCause == .congestionAp)
        #expect(out[0].event.bucket == .b1_25)
        let reader = try SessionStore.openReader(path: r.path)
        #expect(try reader.events().count == 1); #expect(try reader.verdicts().count == 1)
        #expect(try reader.rowCount(table: "probe") == 3000)
    }
    @Test(.timeLimit(.minutes(1))) func verdictIsEmittedBeforeFinishOnceAllTargetsPassWindow() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 600, lostSeqs: Set(100..<110)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 150, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 600, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 150, lostSeqs: [])])
        var got: [PipelineOutput] = []
        for await o in await r.pipeline.outputs { got.append(o); break }   // 30초 분량 뒤에는 이미 판정됨
        #expect(got.count == 1)
    }
    @Test func sleepOverlapIsSuppressedAndStored() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 19 * S, kind: .willSleep, detail: nil))
        await r.pipeline.ingest(SystemEvent(tMono: 25 * S, kind: .didWake, detail: nil))
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out[0].outcome == .suppressedBySleep)
        #expect(try SessionStore.openReader(path: r.path).events()[0].suppressed)
    }
    @Test func interfaceLostForcesControlUnknown() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 15 * S, kind: .interfaceLost, detail: "en11"))
        await r.pipeline.ingest(SystemEvent(tMono: 30 * S, kind: .interfaceBack, detail: "en11"))
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: Set(300..<380)),   // 유선 unreachable 15~19초. 와이파이 사건(20초)과 0.5초 넘게 떨어짐
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: Set(75..<95))])
        let out = try await r.pipeline.finish()
        let wifiEvent = out.first { !$0.event.wiredOnly }!
        guard case .verdict(let v) = wifiEvent.outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .undetermined); #expect(v.reasonCode == "control_insufficient")
        #expect(out.contains { $0.event.wiredOnly })
    }
    @Test func noWiredIsNoControl() async throws {
        let r = try await rig(wired: false); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi) = (r.wg, r.wi)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.reasonCode == "no_control")
    }
    @Test func finishClosesOpenOutageAndJudges() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 600, lostSeqs: Set(580..<600)),  // 끝까지 손실
                       SyntheticSession.probes(target: wi, startNs: 0, count: 150, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 600, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 150, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out.count == 1); #expect(out[0].event.outages[0].closedAtEnd)
        let sys = try SessionStore.openReader(path: r.path).systemEvents()
        #expect(sys.contains { $0.kind == .probeError && $0.detail == "open_at_end" })
    }
    @Test func hostStallWhenAllTargetsDelayed() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        // 20.0초에 모든 대상 송신이 2초 밀림. 와이파이 gw는 그 직전 4개 손실.
        let d: Int64 = 2_000_000
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(396..<400), delayedSeqs: [400: d]),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: [], delayedSeqs: [100: d]),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: [], delayedSeqs: [400: d]),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [], delayedSeqs: [100: d])])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .hostStall)
    }
    @Test func diskLowStopsRecordingButKeepsDetection() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 1, kind: .diskLow, detail: "400000000"))
        #expect(await r.pipeline.recording == false)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out.count == 1)
        #expect(try SessionStore.openReader(path: r.path).rowCount(table: "probe") == 0)
    }
    @Test func gatewayReplacementKeepsDetecting() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        var newGw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); newGw.id = try await r.writer.insertTarget(newGw)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 200, lostSeqs: []),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        await r.pipeline.replaceGatewayTarget(path: .wifi, with: newGw)
        await feed(r, [SyntheticSession.probes(target: newGw, startNs: 10 * S, count: 1000, lostSeqs: Set(200..<220))])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .wireless)
    }
}
