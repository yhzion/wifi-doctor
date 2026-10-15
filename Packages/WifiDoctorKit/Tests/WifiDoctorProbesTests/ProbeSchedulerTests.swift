import Dispatch
import Foundation
import Testing
import WifiDoctorCore
@testable import WifiDoctorProbes

/// 공용 ProbeScheduler 회귀 테스트. Task 22 ICMPProber 테스트도
/// FakeTransport 모양(모의 transport)을 그대로 재사용할 수 있다.
@Suite struct ProbeSchedulerTests {
    private static func makeTarget(id: Int, intervalMs: Int = 200) -> ProbeTarget {
        ProbeTarget(id: id, path: .wifi, role: .dns, address: "198.51.100.53", kind: .dns, intervalMs: intervalMs)
    }

    /// (a) 순서: transport가 임의 순서로 반출한 행이 seq 순서로 나온다.
    /// 중복 seq 0은 정상 동작에서 순서 버퍼가 이미 지나간 seq라 버린다(5행만 도착).
    /// 버퍼 상태가 딕셔너리에 다시 쓰이지 않는 회귀에서는 중복 0이 계속 흘러나와
    /// 잘못된 값([0,0,0,0,0])으로 빨리 실패한다 — 매달림 없이.
    @Test func deliversSubmittedRowsInSeqOrder() async {
        let fake = FakeTransport(targetId: 5)
        let scheduler = ProbeScheduler(
            targets: [Self.makeTarget(id: 5)], queue: DispatchQueue(label: "test.scheduler.order"), transport: fake)
        let stream = scheduler.start()
        await fake.waitUntilStarted()
        for seq in [0, 0, 0, 0, 0, 2, 4, 3, 1] { fake.submitRow(seq: Int64(seq)) }
        var seqs: [Int64] = []
        for await r in stream {
            seqs.append(r.seq)
            if seqs.count == 5 { break }
        }
        scheduler.stop()
        #expect(seqs == [0, 1, 2, 3, 4])
    }

    /// (b) sendDelayUs = max(0, 실제 − 예정). 예정 송신 시각 = 첫 발화 + n × interval.
    /// 시계를 주입해 결정적으로 검증한다(내부 손기).
    @Test func sendDelayIsActualMinusScheduled() async {
        let clock = TestClock(startNs: 1_000_000_000_000)
        let fake = FakeTransport(targetId: 6, armImmediately: true)
        let scheduler = ProbeScheduler(
            targets: [Self.makeTarget(id: 6, intervalMs: 50)],
            queue: DispatchQueue(label: "test.scheduler.delay"),
            transport: fake,
            nowNs: { clock.nowNs })
        _ = scheduler.start()
        await fake.waitForSends(1)
        #expect(fake.sent[0].sendDelayUs == 0)                                   // 첫 발화: 예정 == 실제
        clock.advance(50_000_000 + 3_000_000)            // 2번째 발화가 예정보다 3ms 늦게
        await fake.waitForSends(2)
        #expect(fake.sent[1].sendDelayUs == 3_000)
        #expect(fake.sent[1].tSendMonoNs == fake.sent[0].tSendMonoNs + 50_000_000)
        clock.advance(37_000_000)                         // 3번째 발화 시각이 예정보다 10ms 이전 → 클램프 0
        await fake.waitForSends(3)
        #expect(fake.sent[2].sendDelayUs == 0)
        scheduler.stop()
    }

    /// (c) stop 멱등, 정지 뒤 반출 무시, 두 번째 start는 즉시 종료.
    @Test func stopIsIdempotentAndSecondStartFinishesImmediately() async {
        let fake = FakeTransport(targetId: 7)
        let scheduler = ProbeScheduler(
            targets: [Self.makeTarget(id: 7)], queue: DispatchQueue(label: "test.scheduler.stop"), transport: fake)
        let first = scheduler.start()
        await fake.waitUntilStarted()
        scheduler.stop()
        scheduler.stop()
        fake.submitRow(seq: 0)   // 정지 뒤 반출은 버린다
        var firstRows = 0
        for await _ in first { firstRows += 1 }
        #expect(firstRows == 0)
        let second = scheduler.start()
        var secondRows = 0
        for await _ in second { secondRows += 1 }
        #expect(secondRows == 0)
    }
}

/// 테스트용 ProbeTransport. 스케줄러가 준 submit을 테스트에 내놓아 임의 결과를
/// 임의 순서로 반출하게 하고, 위임받은 송신을 기록한다.
/// Task 22(ICMPProber) 테스트도 같은 모양으로 쓴다.
///
/// @unchecked Sendable이 불가피한 이유: 스케줄러 큐(start·send)와 테스트 스레드
/// (대기·기록 읽기·반출)가 같은 상태에 접근한다. 모든 접근을 NSLock으로 보호한다.
final class FakeTransport: ProbeTransport, @unchecked Sendable {
    struct SentProbe: Equatable {
        var seq: Int64
        var tSendMonoNs: Int64
        var sendDelayUs: Int64
    }

    private let targetId: Int
    /// start()에서 즉시 onReady를 부를지(타이머 마운트). sendDelay 검증에만 필요.
    private let armImmediately: Bool
    private let lock = NSLock()
    private var submitHandler: (@Sendable (ProbeResult) -> Void)?
    private var sentProbes: [SentProbe] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var sentWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(targetId: Int, armImmediately: Bool = false) {
        self.targetId = targetId
        self.armImmediately = armImmediately
    }

    func start(submit: @escaping @Sendable (ProbeResult) -> Void, onReady: @escaping @Sendable () -> Void) {
        var toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        submitHandler = submit
        toResume = startedWaiter
        startedWaiter = nil
        lock.unlock()
        toResume?.resume()
        if armImmediately { onReady() }
    }

    func send(target: ProbeTarget, seq: Int64, tSendMonoNs: Int64, sendDelayUs: Int64) {
        var ready: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        sentProbes.append(SentProbe(seq: seq, tSendMonoNs: tSendMonoNs, sendDelayUs: sendDelayUs))
        var keep: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in sentWaiters {
            if waiter.count <= sentProbes.count { ready.append(waiter.continuation) } else { keep.append(waiter) }
        }
        sentWaiters = keep
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    func sweep(nowNs: Int64) {}
    func stop() {}

    // 테스트 지원(테스트 스레드에서 호출)

    /// 시작 완료(submit 수령)까지 기다린다.
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            var toResume: CheckedContinuation<Void, Never>?
            lock.lock()
            if submitHandler != nil { toResume = continuation } else { startedWaiter = continuation }
            lock.unlock()
            toResume?.resume()
        }
    }

    /// 송신 기록이 count개 쌓일 때까지 기다린다.
    func waitForSends(_ count: Int) async {
        await withCheckedContinuation { continuation in
            var toResume: CheckedContinuation<Void, Never>?
            lock.lock()
            if sentProbes.count >= count { toResume = continuation } else { sentWaiters.append((count, continuation)) }
            lock.unlock()
            toResume?.resume()
        }
    }

    var sent: [SentProbe] {
        lock.lock(); defer { lock.unlock() }
        return sentProbes
    }

    /// 임의 결과 반출. waitUntilStarted 뒤에만 부른다.
    func submitRow(seq: Int64, status: ProbeStatus = .ok) {
        let row = ProbeResult(targetId: targetId, seq: seq, tSendMono: seq * 1_000_000,
                              sendDelayUs: 0, rttUs: 1, status: status, ttl: nil)
        lock.lock()
        let submit = submitHandler
        lock.unlock()
        submit?(row)
    }
}

/// 테스트 시계. 스케줄러 큐(읽기)와 테스트 스레드(진행) 접근이 겹쳐 잠금으로 보호한다.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var valueNs: Int64

    init(startNs: Int64) { valueNs = startNs }

    var nowNs: Int64 {
        lock.lock(); defer { lock.unlock() }
        return valueNs
    }

    func advance(_ deltaNs: Int64) {
        lock.lock(); defer { lock.unlock() }
        valueNs += deltaNs
    }
}
