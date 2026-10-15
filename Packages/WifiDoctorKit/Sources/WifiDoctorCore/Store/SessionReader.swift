import Foundation

public struct ProbeStats: Sendable, Equatable {
    public var count: Int64
    public var lateCount: Int64
    public var sendDelayP50Us: Int64
    public var sendDelayP99Us: Int64
    public var sendDelayMaxUs: Int64
    public init(count: Int64, lateCount: Int64, sendDelayP50Us: Int64, sendDelayP99Us: Int64, sendDelayMaxUs: Int64) {
        self.count = count
        self.lateCount = lateCount
        self.sendDelayP50Us = sendDelayP50Us
        self.sendDelayP99Us = sendDelayP99Us
        self.sendDelayMaxUs = sendDelayMaxUs
    }
}

struct SessionStoreError: Error, CustomStringConvertible {
    var description: String
}

/// 읽기 전용 연결 하나를 `NSLock`으로 지킵니다. 모든 메서드가 락 안에서 문장을 끝까지 돌립니다.
/// 연결은 스레드 안전하지 않으므로 `@unchecked Sendable`입니다. 읽기는 짧고 드물어 락 경합이 문제 되지 않습니다.
public final class SessionReader: @unchecked Sendable {
    private let conn: SQLiteConnection
    private let lock = NSLock()

    init(path: String) throws {
        conn = try SQLiteConnection(path: path, readOnly: true)
    }

    private func locked<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(conn)
    }

    private func query<T>(_ sql: String, binds: (SQLiteStatement) -> Void = { _ in },
                          row: (SQLiteStatement) throws -> T) throws -> [T] {
        try locked { c in
            let st = try c.prepare(sql)
            binds(st)
            var out: [T] = []
            while try st.step() { out.append(try row(st)) }
            return out
        }
    }

    private func scalar(_ sql: String) throws -> Int64? {
        try locked { c in
            let st = try c.prepare(sql)
            return try st.step() ? st.int64(0) : nil
        }
    }

    private static func parse<E: RawRepresentable>(_ type: E.Type, _ raw: String?, _ what: String) throws -> E
    where E.RawValue == String {
        guard let raw, let v = E(rawValue: raw) else {
            throw SessionStoreError(description: "unknown \(what): \(raw ?? "NULL")")
        }
        return v
    }

    public func meta() throws -> SessionMeta {
        let rows = try query("""
            SELECT schema_version, app_version, os_version, started_wall_ms, started_mono_ns, ended_mono_ns,
              wifi_if, wired_if, wifi_gateway, wired_gateway, ap_mgmt_ip, location_auth, sntp_start, sntp_end, notes
            FROM session WHERE id = 1
            """) { s in
            SessionMeta(schemaVersion: Int(s.int64(0)!), appVersion: s.text(1)!, osVersion: s.text(2)!,
                        startedWallMs: s.int64(3)!, startedMonoNs: s.int64(4)!, endedMonoNs: s.int64(5),
                        wifiIf: s.text(6)!, wiredIf: s.text(7), wifiGateway: s.text(8), wiredGateway: s.text(9),
                        apMgmtIp: s.text(10), locationAuth: s.text(11)!, sntpStart: s.text(12), sntpEnd: s.text(13),
                        notes: s.text(14))
        }
        guard let m = rows.first else { throw SessionStoreError(description: "session row missing") }
        return m
    }

    public func targets() throws -> [ProbeTarget] {
        try query("""
            SELECT id, path, role, address, kind, interval_ms, timeout_ms, icmp_ident FROM target ORDER BY id
            """) { s in
            ProbeTarget(id: Int(s.int64(0)!), path: try Self.parse(NetPath.self, s.text(1), "path"),
                        role: try Self.parse(TargetRole.self, s.text(2), "role"), address: s.text(3)!,
                        kind: try Self.parse(ProbeKind.self, s.text(4), "kind"),
                        intervalMs: Int(s.int64(5)!), timeoutMs: Int(s.int64(6)!),
                        icmpIdent: s.int64(7).map { UInt16(truncatingIfNeeded: $0) })
        }
    }

    private static let probeColumns = "target_id, seq, t_send_mono, send_delay_us, rtt_us, status, ttl"

    private static func probe(_ s: SQLiteStatement) throws -> ProbeResult {
        guard let status = ProbeStatus(rawValue: Int(s.int64(5)!)) else {
            throw SessionStoreError(description: "unknown probe status: \(s.int64(5)!)")
        }
        return ProbeResult(targetId: Int(s.int64(0)!), seq: s.int64(1)!, tSendMono: s.int64(2)!,
                           sendDelayUs: s.int64(3)!, rttUs: s.int64(4), status: status, ttl: s.int64(6).map { Int($0) })
    }

    /// `[fromMono, toMono]` 닫힌 구간, `seq` 순.
    public func probes(targetId: Int, fromMono: Int64, toMono: Int64) throws -> [ProbeResult] {
        try query("""
            SELECT \(Self.probeColumns) FROM probe
            WHERE target_id = ? AND t_send_mono >= ? AND t_send_mono <= ? ORDER BY seq
            """, binds: { $0.bind(1, Int64(targetId)); $0.bind(2, fromMono); $0.bind(3, toMono) },
            row: Self.probe)
    }

    /// 전체 프로브를 `t_send_mono`, `target_id`, `seq` 순으로 한 행씩 넘깁니다. 락을 쥔 채 도므로 `body`에서 이 리더를 다시 부르면 안 됩니다.
    public func forEachProbe(_ body: (ProbeResult) throws -> Void) throws {
        try locked { c in
            let st = try c.prepare("SELECT \(Self.probeColumns) FROM probe ORDER BY t_send_mono, target_id, seq")
            while try st.step() { try body(try Self.probe(st)) }
        }
    }

    public func probeStats() throws -> ProbeStats {
        let (count, late, maxDelay) = try locked { c -> (Int64, Int64, Int64) in
            let st = try c.prepare("SELECT COUNT(*), SUM(status = 2), MAX(send_delay_us) FROM probe")
            _ = try st.step()
            return (st.int64(0) ?? 0, st.int64(1) ?? 0, st.int64(2) ?? 0)
        }
        func percentile(_ q: Double) throws -> Int64 {
            guard count > 0 else { return 0 }
            let offset = min(Int64(Double(count) * q), count - 1)   // 내림
            return try locked { c in
                let st = try c.prepare("SELECT send_delay_us FROM probe ORDER BY send_delay_us LIMIT 1 OFFSET ?")
                st.bind(1, offset)
                return try st.step() ? (st.int64(0) ?? 0) : 0
            }
        }
        return ProbeStats(count: count, lateCount: late, sendDelayP50Us: try percentile(0.5),
                          sendDelayP99Us: try percentile(0.99), sendDelayMaxUs: maxDelay)
    }

    /// `[fromMono, toMono]` 닫힌 구간.
    public func wirelessSamples(fromMono: Int64, toMono: Int64) throws -> [WirelessSample] {
        try query("""
            SELECT t_mono, state, rssi_dbm, noise_dbm, tx_rate_mbps, channel, band, width_mhz, bssid, ssid
            FROM wireless_sample WHERE t_mono >= ? AND t_mono <= ? ORDER BY t_mono
            """, binds: { $0.bind(1, fromMono); $0.bind(2, toMono) }) { s in
            guard let state = WirelessLinkState(rawValue: Int(s.int64(1)!)) else {
                throw SessionStoreError(description: "unknown wireless state: \(s.int64(1)!)")
            }
            return WirelessSample(tMono: s.int64(0)!, state: state, rssiDbm: s.int64(2).map { Int($0) },
                                  noiseDbm: s.int64(3).map { Int($0) }, txRateMbps: s.double(4),
                                  channel: s.int64(5).map { Int($0) }, band: s.int64(6).map { Int($0) },
                                  widthMhz: s.int64(7).map { Int($0) }, bssid: s.text(8), ssid: s.text(9))
        }
    }

    public func linkEvents() throws -> [LinkEvent] {
        try query("SELECT t_mono, kind, detail FROM link_event ORDER BY t_mono, rowid") { s in
            LinkEvent(tMono: s.int64(0)!, kind: try Self.parse(LinkEventKind.self, s.text(1), "link event kind"),
                      detail: s.text(2))
        }
    }

    public func systemEvents() throws -> [SystemEvent] {
        try query("SELECT t_mono, kind, detail FROM system_event ORDER BY t_mono, rowid") { s in
            SystemEvent(tMono: s.int64(0)!, kind: try Self.parse(SystemEventKind.self, s.text(1), "system event kind"),
                        detail: s.text(2))
        }
    }

    public func anchors() throws -> [ClockAnchor] {
        try query("SELECT t_mono, t_wall_ms FROM clock_anchor ORDER BY t_mono") { s in
            ClockAnchor(tMono: s.int64(0)!, tWallMs: s.int64(1)!)
        }
    }

    /// 회차(`run`)마다 `HopList` 하나. 경로, 회차 순.
    public func hops() throws -> [HopList] {
        let rows = try query("""
            SELECT path, run, hop_index, address, rtt_ms, t_mono FROM hop ORDER BY path, run, hop_index
            """) { s in
            (path: try Self.parse(NetPath.self, s.text(0), "path"), run: Int(s.int64(1)!), tMono: s.int64(5)!,
             hop: Hop(index: Int(s.int64(2)!), address: s.text(3), rttMs: s.double(4)))
        }
        var lists: [HopList] = []
        for r in rows {
            if let last = lists.last, last.path == r.path, last.run == r.run {
                lists[lists.count - 1].hops.append(r.hop)
            } else {
                lists.append(HopList(path: r.path, run: r.run, tMono: r.tMono, hops: [r.hop]))
            }
        }
        return lists
    }

    /// `closedAtEnd`는 스키마에 열이 없어 항상 false입니다.
    public func outages() throws -> [TargetOutage] {
        try query("""
            SELECT target_id, start_mono, end_mono, lost_count, first_seq, last_seq FROM outage ORDER BY id
            """) { s in Self.outage(s) }
    }

    private static func outage(_ s: SQLiteStatement) -> TargetOutage {
        TargetOutage(targetId: Int(s.int64(0)!), startMono: s.int64(1)!, endMono: s.int64(2)!,
                     lostCount: Int(s.int64(3)!), firstSeq: s.int64(4)!, lastSeq: s.int64(5)!, closedAtEnd: false)
    }

    /// `wiredOnly` = 사건의 끊김이 하나 이상이고 모두 유선 대상. 대상 행이 없는 끊김은 유선이 아닌 것으로 칩니다.
    public func events() throws -> [OutageEvent] {
        let wiredIds = Set(try targets().filter { $0.path == .wired }.map(\.id))
        let rows = try query("""
            SELECT event_id, target_id, start_mono, end_mono, lost_count, first_seq, last_seq FROM outage
            WHERE event_id IS NOT NULL ORDER BY id
            """) { s in (eventId: Int(s.int64(0)!), outage: Self.outage(shifted: s)) }
        var byEvent: [Int: [TargetOutage]] = [:]
        for r in rows { byEvent[r.eventId, default: []].append(r.outage) }
        return try query("SELECT id, start_mono, end_mono, suppressed FROM event ORDER BY id") { s in
            let id = Int(s.int64(0)!)
            let outs = byEvent[id] ?? []
            return OutageEvent(id: id, startMono: s.int64(1)!, endMono: s.int64(2)!, suppressed: s.int64(3)! != 0,
                               wiredOnly: !outs.isEmpty && outs.allSatisfy { wiredIds.contains($0.targetId) },
                               outages: outs)
        }
    }

    private static func outage(shifted s: SQLiteStatement) -> TargetOutage {
        TargetOutage(targetId: Int(s.int64(1)!), startMono: s.int64(2)!, endMono: s.int64(3)!,
                     lostCount: Int(s.int64(4)!), firstSeq: s.int64(5)!, lastSeq: s.int64(6)!, closedAtEnd: false)
    }

    /// `reasonCode`는 스키마에 열이 없어 항상 nil입니다.
    public func verdicts() throws -> [VerdictResult] {
        try query("""
            SELECT event_id, segment, wireless_cause, confidence, reason, evidence FROM verdict ORDER BY event_id
            """) { s in
            VerdictResult(eventId: Int(s.int64(0)!), segment: try Self.parse(Segment.self, s.text(1), "segment"),
                          wirelessCause: try s.text(2).map { try Self.parse(WirelessCause.self, $0, "wireless cause") },
                          confidence: try Self.parse(Confidence.self, s.text(3), "confidence"),
                          reasonCode: nil, reason: s.text(4)!, evidence: s.text(5)!)
        }
    }

    /// `table`은 코드 상수만 넘기십시오(SQL에 그대로 들어갑니다). 알려진 테이블만 허용합니다.
    public func rowCount(table: String) throws -> Int64 {
        let known: Set<String> = ["session", "target", "probe", "wireless_sample", "link_event", "system_event",
                                  "clock_anchor", "hop", "event", "outage", "verdict"]
        guard known.contains(table) else { throw SessionStoreError(description: "unknown table: \(table)") }
        return try scalar("SELECT COUNT(*) FROM \(table)") ?? 0
    }

    public func pragmaUserVersion() throws -> Int64 { try scalar("PRAGMA user_version") ?? 0 }

    public func pragmaJournalMode() throws -> String {
        try locked { c in
            let st = try c.prepare("PRAGMA journal_mode")
            return try st.step() ? (st.text(0) ?? "") : ""
        }
    }
}
