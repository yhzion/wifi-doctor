import Dispatch
import Foundation
import WifiDoctorCore

/// 프로브 송수신 메커니즘. ICMPProber(Task 22)와 DNSProber의 전송 계층이 채운다.
/// start·send·sweep·stop은 모두 스케줄러의 직렬 큐에서만 불린다(실행 스레드는 스케줄러가 보장).
/// 응답은 수신 큐에서 submit으로 반출한다(어느 큐에서 불려도 된다).
protocol ProbeTransport: Sendable {
    /// 시작. 결과 보고 창구(submit)를 받아 저장한다. 준비 완료 또는 더 기다릴 수 없는
    /// 상태(.waiting·.failed 등)에 도달하면 onReady를 부른다. 타이머는 그 이후에 만다.
    /// onReady는 여러 번 불려도 된다(스케줄러가 멱등하게 처리한다).
    func start(submit: @escaping @Sendable (ProbeResult) -> Void, onReady: @escaping @Sendable () -> Void)
    /// 타이머 발화 한 번. tSendMonoNs는 예정 송신 시각, sendDelayUs는 예정 대비 실제 지연(최소 0).
    /// 송신 실패·도달 불가·응답은 submit으로 보고한다.
    func send(target: ProbeTarget, seq: Int64, tSendMonoNs: Int64, sendDelayUs: Int64)
    /// 만료 스윕. 시간 초과 행을 submit으로 내보내고 자기 pending 표에서 지운다.
    func sweep(nowNs: Int64)
    /// 정지. 연결·소켓 정리. 스케줄러 stop()에서 한 번만 불린다.
    func stop()
}

/// ICMPProber(Task 22)·DNSProber가 함께 쓰는 공용 프로브 스케줄러.
/// 맡는 일: 타깃별 DispatchSourceTimer(.strict, leeway 1ms, 반복 intervalMs),
/// 예정 송신 시각 = 첫 발화 + n × interval, sendDelayUs = max(0, 실제 − 예정),
/// 100ms 만료 스윕(transport에 위임), 타깃별 SeqOrderBuffer로 seq 순서 보장,
/// AsyncStream(.bufferingNewest(10_000)), 멱등 stop(continuation finish는 정확히 한 번).
/// 송신·수신·pending 짝 맞춤은 transport가 담당한다.
///
/// @unchecked Sendable이 불가피한 이유: 가변 상태(continuation, 버퍼, seq 계수기, 타이머)는
/// 생성자로 받은 직렬 큐에서만 만지고 타이머도 그 큐에 실려 있다. 컴파일러는
/// DispatchSourceTimer의 큐 경계 격리를 증명할 수 없다.
final class ProbeScheduler<Transport: ProbeTransport>: @unchecked Sendable {
    private let targets: [ProbeTarget]
    private let transport: Transport
    private let queue: DispatchQueue

    private var continuation: AsyncStream<ProbeResult>.Continuation?
    /// targetId → 발화 기준(첫 발화 시각, 발화 횟수)
    private var slots: [Int: Slot] = [:]
    private var nextSeq: [Int: Int64] = [:]
    private var buffers: [Int: SeqOrderBuffer] = [:]
    private var timers: [any DispatchSourceTimer] = []
    private var sweepTimer: (any DispatchSourceTimer)?
    private var stopped = false

    private struct Slot {
        var originNs: Int64 = 0
        var fireCount: Int = 0
    }

    init(targets: [ProbeTarget], queue: DispatchQueue, transport: Transport) {
        self.targets = targets
        self.queue = queue
        self.transport = transport
    }

    func start() -> AsyncStream<ProbeResult> {
        AsyncStream(bufferingPolicy: .bufferingNewest(10_000)) { continuation in
            queue.async { [self] in
                guard !stopped, self.continuation == nil else {
                    continuation.finish()
                    return
                }
                self.continuation = continuation
                continuation.onTermination = { [weak self] _ in self?.stop() }
                transport.start(
                    submit: { [weak self] result in self?.enqueue(result) },
                    onReady: { [weak self] in self?.armTimers() }
                )
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            for timer in timers {
                timer.setEventHandler(handler: nil)
                timer.cancel()
            }
            timers = []
            if let sweepTimer {
                sweepTimer.setEventHandler(handler: nil)
                sweepTimer.cancel()
                self.sweepTimer = nil
            }
            transport.stop()
            continuation?.finish()
            continuation = nil
        }
    }

    /// onReady 이후 타이머를 만다. 첫 발화를 예정 시각 기준(첫 실제 발화)으로 삼는다.
    private func armTimers() {
        queue.async { [self] in
            guard !stopped, timers.isEmpty else { return }
            for target in targets {
                buffers[target.id] = SeqOrderBuffer()
                nextSeq[target.id] = 0
                slots[target.id] = Slot()
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(target.intervalMs), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.fire(target: target) }
                timer.resume()
                timers.append(timer)
            }
            let sweep = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            sweep.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(1))
            sweep.setEventHandler { [weak self] in self?.sweepExpired() }
            sweep.resume()
            sweepTimer = sweep
        }
    }

    private func fire(target: ProbeTarget) {
        let nowNs = MonotonicClock.nowNs()
        guard var slot = slots[target.id] else { return }
        if slot.fireCount == 0 { slot.originNs = nowNs }
        let scheduledNs = slot.originNs + Int64(slot.fireCount) * target.intervalNs
        slot.fireCount += 1
        slots[target.id] = slot
        let sendDelayUs = max(0, (nowNs - scheduledNs) / 1000)
        let seq = nextSeq[target.id] ?? 0
        nextSeq[target.id] = seq + 1
        transport.send(target: target, seq: seq, tSendMonoNs: scheduledNs, sendDelayUs: sendDelayUs)
    }

    private func sweepExpired() {
        transport.sweep(nowNs: MonotonicClock.nowNs())
    }

    /// 결과 행을 seq 순서로 내보낸다. transport의 수신 콜백 등 어느 큐에서나 불린다.
    private func enqueue(_ result: ProbeResult) {
        queue.async { [self] in
            guard !stopped, let continuation, var buffer = buffers[result.targetId] else { return }
            for ordered in buffer.push(result) { continuation.yield(ordered) }
            buffers[result.targetId] = buffer
        }
    }
}
