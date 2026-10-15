import AppKit
import CoreLocation
import Darwin
import Dispatch
import Foundation
import WifiDoctorCore

/// 시스템 감시(awdl0·디스크·잠자기)와 단발 시스템 조회(sntp·위치 권한)를 모은
/// 경계 어댑터. 관찰만 한다 — awdl0를 바꾸지 않는다. 판단은 Core가 한다.
///
/// @unchecked Sendable이 불가피한 이유: 가변 상태(activity 토큰, watcher)는 전부
/// 직렬 큐(queue)에서만 만진다. begin/endSessionActivity·start·stop은 어느
/// 스레드에서나 불릴 수 있어 컴파일러가 이 큐 규율을 증명할 수 없다.
/// InterfaceDirectory.ChangeWatcher와 같은 패턴이다.
public final class SystemGuard: SystemGuarding, @unchecked Sendable {
    /// 디스크 여유 경보 문턱 500 MB.
    static let diskLowThresholdBytes: Int64 = 500 * 1_024 * 1_024
    /// awdl0·디스크 폴링 주기 5초.
    static let pollIntervalSeconds: TimeInterval = 5
    /// sntp 전체 실행 상한 10초(지키개가 SIGTERM).
    static let sntpTimeoutSeconds: TimeInterval = 10
    /// 디스크 조회 기준 경로(세션 폴더, 18장 저장 규약과 같은 자리).
    static var sessionFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/wifi-doctor/sessions")
    }
    /// sntp 전용 직렬 큐. 협력(cooperative) 스레드를 막지 않기 위해 따로 둔다.
    static let sntpQueue = DispatchQueue(label: "WifiDoctor.SystemGuard.sntp")

    private let queue = DispatchQueue(label: "WifiDoctor.SystemGuard")
    /// beginActivity 토큰은 이름 없는 비공개 형식이라, 토큰을 잡은 종료 클로저로 보관한다.
    private var endActivityWork: (() -> Void)?
    private var watcher: GuardWatcher?

    public init() {}

    // MARK: 잠자기 방지

    /// idleSystemSleep 잠금 토큰을 보관한다. begin과 end 사이에 시스템이 잠들지 않는다.
    public func beginSessionActivity() {
        queue.async { [self] in
            guard endActivityWork == nil else { return }
            let token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "wifi-doctor session"
            )
            endActivityWork = { ProcessInfo.processInfo.endActivity(token) }
        }
    }

    public func endSessionActivity() {
        queue.async { [self] in
            guard let endActivityWork else { return }
            self.endActivityWork = nil
            endActivityWork()
        }
    }

    // MARK: SystemGuarding

    public func start() -> AsyncStream<SystemEvent> {
        AsyncStream { continuation in
            let w = GuardWatcher(continuation: continuation)
            queue.async { [self] in
                guard watcher == nil else {
                    continuation.finish()
                    return
                }
                watcher = w
                w.start()
            }
            continuation.onTermination = { _ in w.stop() }
        }
    }

    public func stop() {
        queue.async { [self] in
            watcher?.stop()
            watcher = nil
        }
    }

    public func sntpReport() async -> String {
        await withCheckedContinuation { continuation in
            Self.sntpQueue.async {
                continuation.resume(returning: Self.runSntp())
            }
        }
    }

    /// CLLocationManager는 메인 스레드에서 만들어 쓴다. swift test처럼 번들이 아닌
    /// 환경에서는 denied로 나온다(요청이 창을 띄울 수 없다).
    public func locationAuthorization() async -> String {
        await MainActor.run {
            let manager = CLLocationManager()
            manager.requestWhenInUseAuthorization()
            switch manager.authorizationStatus {
            case .notDetermined: return "notDetermined"
            case .denied, .restricted: return "denied"
            default: return "authorized"
            }
        }
    }

    public func freeDiskBytes(at url: URL) -> Int64? {
        Self.freeDiskBytes(at: url)
    }
}

extension SystemGuard {
    /// /usr/bin/sntp -t 3 time.apple.com 을 돌리고 마지막 줄을 원문 그대로 돌려준다.
    /// 실패(실행 불가·0이 아닌 종료·출력 없음)면 "unavailable".
    /// sntpQueue(전용 직렬 큐)에서만 부른다. readDataToEndOfFile는 자식이 stdout을
    /// 닫을 때까지 그 큐의 스레드를 막는다 — 협력 스레드는 막지 않는다.
    static func runSntp() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sntp")
        process.arguments = ["-t", "3", "time.apple.com"]
        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr 파이프를 읽지 않으면 버퍼가 차서 자식이 막힐 수 있다. 연결만 해서 버린다.
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "unavailable"
        }
        // -t 3은 패킷 하나의 시간 초과이므로 전체 실행 상한을 따로 지킨다.
        DispatchQueue.global().asyncAfter(deadline: .now() + sntpTimeoutSeconds) {
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let lastLine = text.split(separator: "\n", omittingEmptySubsequences: true).last
        else { return "unavailable" }
        return String(lastLine)
    }

    /// 볼륨 여유 바이트. 경로가 아직 없으면 존재하는 조상으로 올라간다(같은 볼륨).
    static func freeDiskBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// getifaddrs로 awdl0의 IFF_UP·IFF_RUNNING을 본다. awdl0가 없으면 0,0.
    static func awdl0Detail() -> String {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return "up=0,running=0" }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            if String(cString: p.pointee.ifa_name) == "awdl0" {
                let flags = Int32(p.pointee.ifa_flags)
                let up = (flags & IFF_UP) != 0 ? 1 : 0
                let running = (flags & IFF_RUNNING) != 0 ? 1 : 0
                return "up=\(up),running=\(running)"
            }
            cursor = p.pointee.ifa_next
        }
        return "up=0,running=0"
    }
}

/// start() 하나의 감시 상태.
/// awdl0: 5초 폴링, 시작 직후 1회 즉시, 이후 변화 시에만.
/// 디스크: 5초마다 세션 폴더 볼륨 여유. 500 MB 미만이면 diskLow를 1회 내고
///         여유가 다시 넘으면 재무장한다.
/// 잠자기: 작업 공간 센터의 willSleep/didWake 알림을 그대로 받아 이벤트로 낸다.
///
/// @unchecked Sendable이 불가피한 이유: 가변 상태(timer, observers, lastAwdlDetail,
/// diskLowArmed, stopped)는 전부 직렬 큐(watchQueue)에서만 만진다. 알림 핸들러는
/// continuation.yield(스레드 안전)만 부르고 공유 상태를 건드리지 않는다.
private final class GuardWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<SystemEvent>.Continuation
    private let watchQueue = DispatchQueue(label: "WifiDoctor.SystemGuard.watch")
    private var timer: (any DispatchSourceTimer)?
    private var observers: [NSObjectProtocol] = []
    private var lastAwdlDetail: String?
    private var diskLowArmed = true
    private var stopped = false

    init(continuation: AsyncStream<SystemEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        watchQueue.async { [self] in
            guard !stopped else { return }
            registerObservers()
            poll()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: watchQueue)
            t.schedule(deadline: .now() + SystemGuard.pollIntervalSeconds,
                       repeating: SystemGuard.pollIntervalSeconds)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    /// 스트림 종료(취소) 시 임의 문맥에서 불린다. 멱등이다.
    func stop() {
        watchQueue.async { [self] in
            guard !stopped else { return }
            stopped = true
            if let timer {
                timer.setEventHandler(handler: nil)
                timer.cancel()
                self.timer = nil
            }
            let center = NSWorkspace.shared.notificationCenter
            for observer in observers { center.removeObserver(observer) }
            observers = []
            continuation.finish()
        }
    }

    /// watchQueue에서만 실행.
    private func registerObservers() {
        // queue nil: 센터의 게시 스레드(작업 공간 알림은 메인)에서 그대로 받는다.
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.emit(.willSleep)
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.emit(.didWake)
            }
        ]
    }

    /// watchQueue(타이머)에서만 실행. 첫 회에는 lastAwdlDetail이 nil이라 무조건 나간다.
    private func poll() {
        let detail = SystemGuard.awdl0Detail()
        if detail != lastAwdlDetail {
            lastAwdlDetail = detail
            emit(.awdl0State, detail: detail)
        }
        guard let freeBytes = SystemGuard.freeDiskBytes(at: SystemGuard.sessionFolder) else { return }
        if freeBytes < SystemGuard.diskLowThresholdBytes {
            if diskLowArmed {
                diskLowArmed = false
                emit(.diskLow, detail: String(freeBytes))
            }
        } else {
            diskLowArmed = true
        }
    }

    /// 알림 게시 스레드 또는 watchQueue에서 불린다. yield만 하므로 어느 쪽이든 안전하다.
    private func emit(_ kind: SystemEventKind, detail: String? = nil) {
        continuation.yield(SystemEvent(tMono: MonotonicClock.nowNs(), kind: kind, detail: detail))
    }
}
