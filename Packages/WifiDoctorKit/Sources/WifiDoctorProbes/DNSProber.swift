import Dispatch
import Foundation
import Network
import WifiDoctorCore

/// 인터페이스에 묶은 UDP DNS 프로버. intervalMs 간격으로 A 조회를 보내고
/// 올바른 트랜잭션 ID의 응답 도착만으로 성공으로 친다(응답 코드는 보지 않는다 — 설계).
/// 판단은 하지 않고 측정 행만 만든다. 타이머·순서·스트림은 공용 ProbeScheduler가 맡는다.
public final class DNSProber: Prober {
    public let targets: [ProbeTarget]
    private let scheduler: ProbeScheduler<DNSTransport>

    public init(interface: NetInterface, target: ProbeTarget) {
        self.targets = [target]
        let queue = DispatchQueue(label: "WifiDoctor.DNSProber")
        let transport = DNSTransport(interface: interface, target: target, queue: queue)
        self.scheduler = ProbeScheduler(targets: [target], queue: queue, transport: transport)
    }

    public func start() -> AsyncStream<ProbeResult> { scheduler.start() }
    public func stop() { scheduler.stop() }
}

/// DNSProber의 송수신 계층(NWConnection UDP). 단일 대상 전용 — 프로토콜의
/// target 파라미터와 생성자의 target은 항상 같다.
///
/// @unchecked Sendable이 불가피한 이유: NWConnection·pending 표처럼 Sendable 표시가
/// 없거나 가변인 상태를 저장한다. 실제 격리: 상태 설정·송신·수신 콜백·스윕·정지는
/// 전부 스케줄러가 준 직렬 큐에서만 실행된다(연결도 그 큐로 시작한다).
/// lookupInterface만 그 큐가 아닌 모니터 큐에서 돌아가고, 완료 전에는 다른 메서드와 겹치지 않는다.
private final class DNSTransport: ProbeTransport, @unchecked Sendable {
    /// DNS ID별 송신 기록. 시간 규약은 ICMP PendingTable과 같다:
    /// rttUs는 예정 송신 시각 기준, 만료 마감은 tSendMonoNs + sendDelayUs*1000 + timeoutNs.
    private struct Pending {
        var seq: Int64
        var tSendMonoNs: Int64
        var sendDelayUs: Int64

        func deadlineNs(timeoutNs: Int64) -> Int64 { tSendMonoNs + sendDelayUs * 1000 + timeoutNs }
    }

    private let bsdName: String
    private let target: ProbeTarget
    private let queue: DispatchQueue
    private var submit: (@Sendable (ProbeResult) -> Void)?
    private var interface: NWInterface?
    private var connection: NWConnection?
    private var ready = false
    /// DNS ID(UInt16) → 송신 기록. 5회/초·1초 만료라 ID 겹침은 없지만
    /// 겹치면 새 기록이 이긴다(키 덮어쓰기).
    private var pending: [UInt16: Pending] = [:]

    private var timeoutNs: Int64 { Int64(target.timeoutMs) * 1_000_000 }

    init(interface: NetInterface, target: ProbeTarget, queue: DispatchQueue) {
        self.bsdName = interface.bsdName
        self.target = target
        self.queue = queue
    }

    func start(submit: @escaping @Sendable (ProbeResult) -> Void, onReady: @escaping @Sendable () -> Void) {
        self.submit = submit
        // 인터페이스 객체를 이름으로 찾는다. 못 찾으면(유선 끊김 등) 연결을 만들지 않고
        // 바로 준비 완료 — 이후 모든 슬롯은 .unreachable(설계: 유선 끊김은 unreachable).
        interface = Self.lookupInterface(named: bsdName)
        guard let interface else {
            onReady()
            return
        }
        let params = NWParameters.udp
        params.requiredInterface = interface
        let conn = NWConnection(
            host: NWEndpoint.Host(target.address),
            port: NWEndpoint.Port(rawValue: 53)!,
            using: params
        )
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready = true
                receiveNext()
                onReady()
            case .waiting, .failed, .cancelled:
                ready = false
                onReady()
            default:
                break   // .setup, .preparing — 아직 판단할 단계가 아니다
            }
        }
        conn.start(queue: queue)
    }

    func send(target: ProbeTarget, seq: Int64, tSendMonoNs: Int64, sendDelayUs: Int64) {
        guard interface != nil else {
            submit?(row(seq: seq, tSendMonoNs: tSendMonoNs, sendDelayUs: sendDelayUs, rttUs: nil, status: .unreachable))
            return
        }
        // .ready 전 송신은 .sendError(브리프).
        guard ready, let connection else {
            submit?(row(seq: seq, tSendMonoNs: tSendMonoNs, sendDelayUs: sendDelayUs, rttUs: nil, status: .sendError))
            return
        }
        let id = UInt16(truncatingIfNeeded: seq)
        pending[id] = Pending(seq: seq, tSendMonoNs: tSendMonoNs, sendDelayUs: sendDelayUs)
        // 송신 완료 콜백의 오류는 드물다. 오류가 나도 항목은 만료 스윕이 .timeout으로 정리한다.
        connection.send(content: Data(DNSPacket.query(id: id)), completion: .contentProcessed { _ in })
    }

    func sweep(nowNs: Int64) {
        for (id, entry) in pending where nowNs > entry.deadlineNs(timeoutNs: timeoutNs) {
            pending.removeValue(forKey: id)
            submit?(row(seq: entry.seq, tSendMonoNs: entry.tSendMonoNs, sendDelayUs: entry.sendDelayUs,
                        rttUs: nil, status: .timeout))
        }
    }

    func stop() {
        ready = false
        submit = nil
        let conn = connection
        connection = nil
        conn?.cancel()
    }

    /// receiveMessage 반복 호출. 연결 오류·정지(connection == nil)면 반복이 끊긴다.
    private func receiveNext() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                let tRecvNs = MonotonicClock.nowNs()
                if let id = DNSPacket.responseId([UInt8](data)) {
                    reply(id: id, tRecvNs: tRecvNs)
                }
            }
            if error == nil { receiveNext() }
        }
    }

    /// 응답 짝 맞추기. pending이 없으면(중복·만료됨·모르는 ID) 무시한다.
    private func reply(id: UInt16, tRecvNs: Int64) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        submit?(row(
            seq: entry.seq,
            tSendMonoNs: entry.tSendMonoNs,
            sendDelayUs: entry.sendDelayUs,
            rttUs: (tRecvNs - entry.tSendMonoNs) / 1000,
            status: tRecvNs > entry.deadlineNs(timeoutNs: timeoutNs) ? .late : .ok
        ))
    }

    private func row(seq: Int64, tSendMonoNs: Int64, sendDelayUs: Int64, rttUs: Int64?, status: ProbeStatus) -> ProbeResult {
        ProbeResult(targetId: target.id, seq: seq, tSendMono: tSendMonoNs, sendDelayUs: sendDelayUs,
                    rttUs: rttUs, status: status, ttl: nil)
    }

    /// NWPath.availableInterfaces에서 이름이 일치하는 NWInterface를 찾는다(설계:
    /// NWPathMonitor(requiredInterfaceType:)이 아니라 이름 일치 조회).
    /// 첫 경로 스냅샷 하나만 기다린다(보통 수십 ms). 못 찾으면 nil → 이후 .unreachable.
    private static func lookupInterface(named bsdName: String) -> NWInterface? {
        // NWInterface는 Sendable 표시가 없어 큐 간 전달 창구가 필요하다.
        // 쓰기는 모니터 큐에서 한 번, 읽기는 세마포어 동기화 뒤 호출자에서 한 번이다.
        final class Box: @unchecked Sendable { var interface: NWInterface? }
        let monitor = NWPathMonitor()
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            box.interface = path.availableInterfaces.first { $0.name == bsdName }
            done.signal()
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        let reached = done.wait(timeout: .now() + 2) == .success
        monitor.cancel()
        return reached ? box.interface : nil
    }
}
