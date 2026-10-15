import Foundation

public struct PipelineOutput: Sendable, Equatable {
    public var event: OutageEvent
    public var outcome: JudgeOutcome
    public init(event: OutageEvent, outcome: JudgeOutcome) {
        self.event = event
        self.outcome = outcome
    }
}

/// 프로브·무선 샘플·링크 이벤트·시스템 이벤트를 받아 저장하고, 끊김을 검출해 사건으로 묶고 판정합니다(12장).
/// 판정 상태는 동기 구간에서 모두 바꾸고, 그 뒤에 쓰기 액터를 기다립니다(재진입 안전).
public actor SessionPipeline {
    private static let ringSpanNs: Int64 = 600_000_000_000          // 링 버퍼 10분
    private static let settleLagNs: Int64 = 700_000_000             // R8: 창 확장 0.2초 + 병합 대기 0.5초
    private static let trimEvery = 100
    private static let diskLowBytes: Int64 = 500_000_000

    private let config: SessionConfig
    private let writer: SessionWriter
    private var topology: PathTopology
    private var targets: [Int: ProbeTarget]
    private var activeTargetIds: Set<Int>
    private var detectors: [Int: OutageDetector]
    private var ring: [ProbeResult] = []
    private var samples: [WirelessSample] = []
    private var linkEvents: [LinkEvent] = []
    private var sleepIntervals: [(start: Int64, end: Int64)] = []
    private var controlBlackouts: [(start: Int64, end: Int64)] = []
    private var closedOutages: [TargetOutage] = []
    private var lastSeenByTarget: [Int: Int64] = [:]
    private var okCounts: [Int: Int] = [:]
    private var latestMono: Int64 = 0
    private var ingestCount = 0
    private var nextEventId = 1
    private var allOutputs: [PipelineOutput] = []
    private let stream: AsyncStream<PipelineOutput>
    private let continuation: AsyncStream<PipelineOutput>.Continuation

    public private(set) var recording = true
    public var outputs: AsyncStream<PipelineOutput> { stream }

    public init(config: SessionConfig, targets: [ProbeTarget], writer: SessionWriter, topology: PathTopology) {
        self.config = config
        self.writer = writer
        self.topology = topology
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        activeTargetIds = Set(targets.map(\.id))
        detectors = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, OutageDetector(target: $0)) })
        (stream, continuation) = AsyncStream.makeStream(of: PipelineOutput.self, bufferingPolicy: .unbounded)
    }

    public func setTopology(_ t: PathTopology) { topology = t }

    /// gateway_changed: 이전 gateway 대상의 검출기를 닫고 새 대상을 추가합니다. 이전 대상은 창 상태 계산용으로 남깁니다.
    public func replaceGatewayTarget(path: NetPath, with newTarget: ProbeTarget) {
        for id in activeTargetIds.sorted() where targets[id]?.path == path && targets[id]?.role == .gateway {
            if let o = detectors[id]?.finish() { closedOutages.append(o) }
            detectors[id] = nil
            activeTargetIds.remove(id)
        }
        targets[newTarget.id] = newTarget
        detectors[newTarget.id] = OutageDetector(target: newTarget)
        activeTargetIds.insert(newTarget.id)
    }

    public func ingest(_ r: ProbeResult) async {
        ring.append(r)
        lastSeenByTarget[r.targetId] = max(lastSeenByTarget[r.targetId] ?? .min, r.tSendMono)
        if r.status == .ok { okCounts[r.targetId, default: 0] += 1 }
        // 늦게 온 순번 역순 프로브(이미 닫힌 run 뒤의 ok)는 검출기에서 아무 일도 하지 않습니다.
        if let o = detectors[r.targetId]?.feed(r) { closedOutages.append(o) }
        advance(to: r.tSendMono)
        let judged = settle(force: false)
        if recording { await writer.enqueue(r) }
        await store(judged)
    }

    public func ingest(_ s: WirelessSample) async {
        samples.append(s)
        advance(to: s.tMono)
        if recording { await writer.enqueue(s) }
    }

    public func ingest(_ e: LinkEvent) async {
        linkEvents.append(e)
        advance(to: e.tMono)
        await writer.enqueue(e)
    }

    public func ingest(_ e: SystemEvent) async {
        switch e.kind {
        case .willSleep:
            sleepIntervals.append((start: e.tMono, end: .max))
        case .didWake:
            if let i = sleepIntervals.indices.last, sleepIntervals[i].end == .max { sleepIntervals[i].end = e.tMono }
        case .interfaceLost where config.wiredIf != nil && e.detail == config.wiredIf:
            controlBlackouts.append((start: e.tMono, end: .max))
        case .interfaceBack where e.detail != config.wifiIf:
            // 유선 BSD 이름이 바뀌면 interface_back은 새 이름을 싣습니다(8장).
            if let i = controlBlackouts.indices.last, controlBlackouts[i].end == .max { controlBlackouts[i].end = e.tMono }
        case .diskLow:
            if let free = e.detail.flatMap({ Int64($0) }), free < Self.diskLowBytes { recording = false }
        default:
            break
        }
        await writer.enqueue(e)
    }

    /// App이 1초마다 호출합니다. 최종 실패(디스크 부족 포함)면 배치를 버리고 기록을 남긴 뒤 녹화를 멈춥니다(8장).
    public func flushStore() async throws {
        do {
            _ = try await writer.flush()
        } catch {
            let dropped = await writer.discardPending()
            await writer.enqueue(SystemEvent(tMono: latestMono, kind: .probeError,
                                             detail: "flush_failed: \(dropped) rows dropped"))
            _ = try? await writer.flush()
            recording = false
            throw error
        }
    }

    /// 열린 끊김을 닫고 남은 사건을 모두 판정합니다. 세션 전체의 출력을 돌려줍니다.
    public func finish() async throws -> [PipelineOutput] {
        for id in detectors.keys.sorted() {
            guard let o = detectors[id]?.finish() else { continue }
            closedOutages.append(o)
            if o.closedAtEnd {
                await writer.enqueue(SystemEvent(tMono: o.endMono, kind: .probeError, detail: "open_at_end"))
            }
        }
        let judged = settle(force: true)
        continuation.finish()
        await store(judged)
        try await flushStore()
        return allOutputs
    }

    public func recentProbes(sinceNs: Int64) -> [ProbeResult] { ring.filter { $0.tSendMono >= sinceNs } }
    public func recentSamples(sinceNs: Int64) -> [WirelessSample] { samples.filter { $0.tMono >= sinceNs } }
    public func okCount(targetId: Int) -> Int { okCounts[targetId] ?? 0 }

    // MARK: - 내부

    private func advance(to t: Int64) {
        latestMono = max(latestMono, t)
        ingestCount += 1
        guard ingestCount % Self.trimEvery == 0 else { return }
        let cutoff = latestMono - Self.ringSpanNs
        ring.removeAll { $0.tSendMono < cutoff }
        samples.removeAll { $0.tMono < cutoff }
        linkEvents.removeAll { $0.tMono < cutoff }
    }

    /// R8: 모든 활성 대상의 마지막 관측 tSendMono ≥ event.end + 0.7초인 사건만 확정합니다. `force`면 조건을 무시합니다.
    /// 확정·판정·출력은 동기로 끝냅니다. 저장은 호출자가 `store`로 합니다.
    private func settle(force: Bool) -> [PipelineOutput] {
        guard !closedOutages.isEmpty else { return [] }
        let watermark = activeTargetIds.map { lastSeenByTarget[$0] ?? .min }.min() ?? .min
        let candidates = EventGrouper.group(outages: closedOutages, targets: targets, sleepIntervals: sleepIntervals)
        var judged: [PipelineOutput] = []
        for var event in candidates where force || watermark >= event.endMono + Self.settleLagNs {
            closedOutages.removeAll { event.outages.contains($0) }
            event.id = nextEventId
            nextEventId += 1
            let outcome = judge(event)
            if outcome == .noLossInWindow { event.suppressed = true }
            let output = PipelineOutput(event: event, outcome: outcome)
            judged.append(output)
            allOutputs.append(output)
            continuation.yield(output)
        }
        return judged
    }

    private func judge(_ event: OutageEvent) -> JudgeOutcome {
        let probes = ring.filter { $0.tSendMono >= event.startMono - 500_000_000 }
        let forced = controlBlackouts.contains { $0.start <= event.endMono && event.startMono <= $0.end }
        let status = WindowStatus.evaluate(event: event, probes: probes, targets: targets,
                                           hasWired: config.wiredIf != nil, controlForcedUnknown: forced)
        let stall = HostStallCheck.evaluate(event: event, probes: probes, targets: targets)
        return Verdict.judge(event: event, status: status, stall: stall, topology: topology, config: config) { e in
            WirelessClassifier.classify(start: e.startMono, end: e.endMono, samples: samples,
                                        events: linkEvents, thresholds: config.thresholds).cause
        }
    }

    private func store(_ judged: [PipelineOutput]) async {
        for o in judged {
            var verdict: VerdictResult?
            if case .verdict(let v) = o.outcome { verdict = v }
            do {
                try await writer.writeEvent(o.event, verdict: verdict)
            } catch {
                if error as? SessionStoreError == .diskFull { recording = false }
                await writer.enqueue(SystemEvent(tMono: o.event.endMono, kind: .probeError,
                                                 detail: "event_write_failed: \(o.event.id)"))
            }
        }
    }
}
