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
    private static let staleNs: Int64 = 3_000_000_000               // 최근 프로브보다 3초 넘게 뒤처진 대상은 기다리지 않음
    private static let holdCapNs: Int64 = 120_000_000_000           // 열린 run 대기 상한
    private static let classifierLeadNs: Int64 = 63_000_000_000     // 무선 분류 기준선 60초 + 창 앞 3초
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
    private var openRunStart: [Int: Int64] = [:]                    // 대상별 열린 손실 run의 첫 손실 송신 시각
    private var latestProbeMono: Int64 = 0
    private var finished = false
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
            retire(id)
        }
        targets[newTarget.id] = newTarget
        detectors[newTarget.id] = OutageDetector(target: newTarget)
        activeTargetIds.insert(newTarget.id)
    }

    /// 측정을 멈춘 대상(예: AP 관리 Prober 중지). 검출기를 닫고 판정 기준 시각 계산에서 뺍니다.
    public func retireTarget(id: Int) { retire(id) }

    public func ingest(_ r: ProbeResult) async {
        guard !finished else { return }
        ring.append(r)
        lastSeenByTarget[r.targetId] = max(lastSeenByTarget[r.targetId] ?? .min, r.tSendMono)
        latestProbeMono = max(latestProbeMono, r.tSendMono)
        if r.status == .ok { okCounts[r.targetId, default: 0] += 1 }
        // 늦게 온 순번 역순 프로브(이미 닫힌 run 뒤의 ok)는 검출기에서 아무 일도 하지 않습니다.
        if detectors[r.targetId] != nil {
            if let o = detectors[r.targetId]?.feed(r) { closedOutages.append(o) }
            if !r.status.isLost {
                openRunStart[r.targetId] = nil
            } else if openRunStart[r.targetId] == nil {
                openRunStart[r.targetId] = r.tSendMono
            }
        }
        advance(to: r.tSendMono)
        let judged = settle(force: false)
        if recording { await writer.enqueue(r) }
        await store(judged)
    }

    public func ingest(_ s: WirelessSample) async {
        guard !finished else { return }
        samples.append(s)
        advance(to: s.tMono)
        if recording { await writer.enqueue(s) }
    }

    public func ingest(_ e: LinkEvent) async {
        guard !finished else { return }
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
        case .interfaceLost:                        // interface_lost/back은 유선 인터페이스만 가리킵니다.
            controlBlackouts.append((start: e.tMono, end: .max))
        case .interfaceBack:
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
    /// 상태 변경과 판정은 첫 await 전에 끝냅니다. 두 번째 호출은 같은 출력을 돌려줍니다.
    public func finish() async throws -> [PipelineOutput] {
        guard !finished else { return allOutputs }
        finished = true
        var openAtEnd: [SystemEvent] = []
        for id in detectors.keys.sorted() {
            guard let o = detectors[id]?.finish() else { continue }
            closedOutages.append(o)
            if o.closedAtEnd { openAtEnd.append(SystemEvent(tMono: o.endMono, kind: .probeError, detail: "open_at_end")) }
        }
        openRunStart.removeAll()
        let judged = settle(force: true)
        continuation.finish()
        for e in openAtEnd { await writer.enqueue(e) }
        await store(judged)
        try await flushStore()
        return allOutputs
    }

    public func recentProbes(sinceNs: Int64) -> [ProbeResult] { ring.filter { $0.tSendMono >= sinceNs } }
    public func recentSamples(sinceNs: Int64) -> [WirelessSample] { samples.filter { $0.tMono >= sinceNs } }
    public func okCount(targetId: Int) -> Int { okCounts[targetId] ?? 0 }

    // MARK: - 내부

    /// 대상을 은퇴시킵니다. 열린 run은 세션 종료가 아니라 교체·중지로 잘린 것이므로 closedAtEnd = false.
    private func retire(_ id: Int) {
        if var o = detectors[id]?.finish() {
            o.closedAtEnd = false
            closedOutages.append(o)
        }
        detectors[id] = nil
        openRunStart[id] = nil
        activeTargetIds.remove(id)
    }

    /// 판정 기준 시각에 쓰는 대상: 은퇴하지 않았고, 최근 프로브보다 3초 넘게 뒤처지지 않은 대상.
    private func liveTargetIds() -> [Int] {
        let staleBefore = latestProbeMono - Self.staleNs
        return activeTargetIds.filter { (lastSeenByTarget[$0] ?? .min) >= staleBefore }
    }

    private func advance(to t: Int64) {
        latestMono = max(latestMono, t)
        ingestCount += 1
        guard ingestCount % Self.trimEvery == 0 else { return }
        // 아직 판정하지 않은 끊김과 열린 run의 데이터는 무선 분류 기준선까지 남깁니다.
        var cutoff = latestMono - Self.ringSpanNs
        let pending = closedOutages.map(\.startMono) + liveTargetIds().compactMap { openRunStart[$0] }
        if let oldest = pending.min() { cutoff = min(cutoff, oldest - Self.classifierLeadNs) }
        ring.removeAll { $0.tSendMono < cutoff }
        samples.removeAll { $0.tMono < cutoff }
        linkEvents.removeAll { $0.tMono < cutoff }
    }

    /// 사건 확정 조건. `force`면 모두 확정합니다.
    /// R8: 살아 있는 대상의 마지막 관측 tSendMono 최솟값(watermark) ≥ event.end + 0.7초.
    /// 12장: 그리고 살아 있는 대상에 run 시작 ≤ event.end + 0.5초인 열린 손실 run이 없어야 합니다
    /// (유선 blackout이 열려 있으면 유선 run은 무시). watermark ≥ event.end + 120초면 기다리지 않습니다.
    /// 확정·판정·출력은 동기로 끝냅니다. 저장은 호출자가 `store`로 합니다.
    private func settle(force: Bool) -> [PipelineOutput] {
        guard !closedOutages.isEmpty else { return [] }
        let live = liveTargetIds()
        let watermark = live.map { lastSeenByTarget[$0] ?? .min }.min() ?? .min
        let blackoutOpen = controlBlackouts.last?.end == .max
        let openStarts = live.compactMap { id -> Int64? in
            if blackoutOpen && targets[id]?.path == .wired { return nil }
            return openRunStart[id]
        }
        func isFinal(_ e: OutageEvent) -> Bool {
            guard watermark >= e.endMono + Self.settleLagNs else { return false }
            if watermark >= e.endMono + Self.holdCapNs { return true }
            return !openStarts.contains { $0 <= e.endMono + EventGrouper.mergeGapNs }
        }
        let candidates = EventGrouper.group(outages: closedOutages, targets: targets, sleepIntervals: sleepIntervals)
        var judged: [PipelineOutput] = []
        for var event in candidates where force || isFinal(event) {
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
