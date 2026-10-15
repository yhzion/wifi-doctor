import Foundation
import SQLite3

/// 쓰기 액터. 연결은 이 액터 안에만 있습니다. 측정 행은 `enqueue`로 쌓고 `flush()`가 한 트랜잭션으로 씁니다.
public actor SessionWriter {
    private let conn: SQLiteConnection
    private let insertProbe: SQLiteStatement
    private let insertSample: SQLiteStatement
    private let insertLinkEvent: SQLiteStatement
    private let insertSystemEvent: SQLiteStatement
    private let insertAnchor: SQLiteStatement

    private var probes: [ProbeResult] = []
    private var samples: [WirelessSample] = []
    private var linkEvents: [LinkEvent] = []
    private var systemEvents: [SystemEvent] = []
    private var anchors: [ClockAnchor] = []

    private static let maxFlushAttempts = 3

    init(connection: SQLiteConnection) throws {
        conn = connection
        insertProbe = try connection.prepare("""
            INSERT INTO probe (target_id, seq, t_send_mono, send_delay_us, rtt_us, status, ttl)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        insertSample = try connection.prepare("""
            INSERT INTO wireless_sample (t_mono, state, rssi_dbm, noise_dbm, tx_rate_mbps, channel, band, width_mhz, bssid, ssid)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        insertLinkEvent = try connection.prepare("INSERT INTO link_event (t_mono, kind, detail) VALUES (?, ?, ?)")
        insertSystemEvent = try connection.prepare("INSERT INTO system_event (t_mono, kind, detail) VALUES (?, ?, ?)")
        insertAnchor = try connection.prepare("INSERT INTO clock_anchor (t_mono, t_wall_ms) VALUES (?, ?)")
    }

    public var pendingCount: Int {
        probes.count + samples.count + linkEvents.count + systemEvents.count + anchors.count
    }

    /// `target.id`가 0 이하면 SQLite가 번호를 매깁니다. 쓰인 id를 돌려줍니다.
    public func insertTarget(_ t: ProbeTarget) throws -> Int {
        let st = try conn.prepare("""
            INSERT INTO target (id, path, role, address, kind, interval_ms, timeout_ms, icmp_ident)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        st.bind(1, t.id > 0 ? Int64(t.id) : nil)
        st.bind(2, t.path.rawValue); st.bind(3, t.role.rawValue); st.bind(4, t.address)
        st.bind(5, t.kind.rawValue); st.bind(6, Int64(t.intervalMs)); st.bind(7, Int64(t.timeoutMs))
        st.bind(8, t.icmpIdent.map { Int64($0) })
        _ = try Self.run(st)
        return Int(conn.lastInsertRowId())
    }

    public func enqueue(_ p: ProbeResult) { probes.append(p) }
    public func enqueue(_ s: WirelessSample) { samples.append(s) }
    public func enqueue(_ e: LinkEvent) { linkEvents.append(e) }
    public func enqueue(_ e: SystemEvent) { systemEvents.append(e) }
    public func enqueue(_ a: ClockAnchor) { anchors.append(a) }

    /// flush가 끝내 실패했을 때 호출자가 독이 된 배치를 버립니다. 버린 행 수를 돌려줍니다.
    public func discardPending() -> Int {
        let count = pendingCount
        probes.removeAll(); samples.removeAll(); linkEvents.removeAll()
        systemEvents.removeAll(); anchors.removeAll()
        return count
    }

    /// 큐 5개를 한 트랜잭션으로 씁니다. 쓴 행 수를 돌려줍니다.
    /// 실패하면 ROLLBACK 하고 큐를 유지한 채 총 3회까지 시도합니다. `SQLITE_FULL`은 재시도 없이 `diskFull`.
    public func flush() throws -> Int {
        let count = pendingCount
        guard count > 0 else { return 0 }
        var lastError: Error = SessionStoreError(description: "flush failed")
        for _ in 0..<Self.maxFlushAttempts {
            do {
                try conn.exec("BEGIN")
                do {
                    try writeQueues()
                    try conn.exec("COMMIT")
                } catch {
                    try? conn.exec("ROLLBACK")
                    throw error
                }
                probes.removeAll(); samples.removeAll(); linkEvents.removeAll()
                systemEvents.removeAll(); anchors.removeAll()
                return count
            } catch {
                if Self.isDiskFull(error) { throw SessionStoreError.diskFull }
                lastError = error
            }
        }
        throw lastError
    }

    private func writeQueues() throws {
        for p in probes {
            insertProbe.bind(1, Int64(p.targetId)); insertProbe.bind(2, p.seq)
            insertProbe.bind(3, p.tSendMono); insertProbe.bind(4, p.sendDelayUs)
            insertProbe.bind(5, p.rttUs); insertProbe.bind(6, Int64(p.status.rawValue))
            insertProbe.bind(7, p.ttl.map { Int64($0) })
            _ = try Self.run(insertProbe)
        }
        for s in samples {
            insertSample.bind(1, s.tMono); insertSample.bind(2, Int64(s.state.rawValue))
            insertSample.bind(3, s.rssiDbm.map { Int64($0) }); insertSample.bind(4, s.noiseDbm.map { Int64($0) })
            insertSample.bind(5, s.txRateMbps); insertSample.bind(6, s.channel.map { Int64($0) })
            insertSample.bind(7, s.band.map { Int64($0) }); insertSample.bind(8, s.widthMhz.map { Int64($0) })
            insertSample.bind(9, s.bssid); insertSample.bind(10, s.ssid)
            _ = try Self.run(insertSample)
        }
        for e in linkEvents {
            insertLinkEvent.bind(1, e.tMono); insertLinkEvent.bind(2, e.kind.rawValue); insertLinkEvent.bind(3, e.detail)
            _ = try Self.run(insertLinkEvent)
        }
        for e in systemEvents {
            insertSystemEvent.bind(1, e.tMono); insertSystemEvent.bind(2, e.kind.rawValue); insertSystemEvent.bind(3, e.detail)
            _ = try Self.run(insertSystemEvent)
        }
        for a in anchors {
            insertAnchor.bind(1, a.tMono); insertAnchor.bind(2, a.tWallMs)
            _ = try Self.run(insertAnchor)
        }
    }

    /// 탐지 회차의 모든 홉 행에 `HopList.tMono`를 씁니다(리더가 첫 행의 값을 씁니다).
    public func writeHops(_ h: HopList) throws {
        try inTransaction {
            let st = try conn.prepare("INSERT INTO hop (path, run, hop_index, address, rtt_ms, t_mono) VALUES (?, ?, ?, ?, ?, ?)")
            for hop in h.hops {
                st.bind(1, h.path.rawValue); st.bind(2, Int64(h.run)); st.bind(3, Int64(hop.index))
                st.bind(4, hop.address); st.bind(5, hop.rttMs); st.bind(6, h.tMono)
                _ = try Self.run(st)
            }
        }
    }

    /// event, outage(event_id, closed_at_end), verdict를 한 트랜잭션으로 씁니다.
    public func writeEvent(_ e: OutageEvent, verdict: VerdictResult?) throws {
        try inTransaction {
            let ev = try conn.prepare("""
                INSERT INTO event (id, start_mono, end_mono, duration_ms, bucket, suppressed) VALUES (?, ?, ?, ?, ?, ?)
                """)
            ev.bind(1, Int64(e.id)); ev.bind(2, e.startMono); ev.bind(3, e.endMono)
            ev.bind(4, e.durationMs); ev.bind(5, e.bucket.rawValue); ev.bind(6, e.suppressed ? 1 : 0 as Int64)
            _ = try Self.run(ev)
            let out = try conn.prepare("""
                INSERT INTO outage (target_id, start_mono, end_mono, lost_count, first_seq, last_seq, event_id, closed_at_end)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for o in e.outages {
                out.bind(1, Int64(o.targetId)); out.bind(2, o.startMono); out.bind(3, o.endMono)
                out.bind(4, Int64(o.lostCount)); out.bind(5, o.firstSeq); out.bind(6, o.lastSeq)
                out.bind(7, Int64(e.id)); out.bind(8, o.closedAtEnd ? 1 : 0 as Int64)
                _ = try Self.run(out)
                out.reset()
            }
            if let v = verdict {
                let vs = try conn.prepare("""
                    INSERT INTO verdict (event_id, segment, wireless_cause, confidence, reason_code, reason, evidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """)
                vs.bind(1, Int64(v.eventId)); vs.bind(2, v.segment.rawValue); vs.bind(3, v.wirelessCause?.rawValue)
                vs.bind(4, v.confidence.rawValue); vs.bind(5, v.reasonCode); vs.bind(6, v.reason); vs.bind(7, v.evidence)
                _ = try Self.run(vs)
            }
        }
    }

    public func updateEventSuppressed(id: Int, suppressed: Bool) throws {
        let st = try conn.prepare("UPDATE event SET suppressed = ? WHERE id = ?")
        st.bind(1, suppressed ? 1 : 0 as Int64); st.bind(2, Int64(id))
        _ = try Self.run(st)
    }

    /// session 행을 갱신하고 WAL을 비웁니다.
    public func finishSession(endedMonoNs: Int64, sntpEnd: String?, notes: String?) throws {
        let st = try conn.prepare("UPDATE session SET ended_mono_ns = ?, sntp_end = ?, notes = ? WHERE id = 1")
        st.bind(1, endedMonoNs); st.bind(2, sntpEnd); st.bind(3, notes)
        _ = try Self.run(st)
        try Self.mapDiskFull { try conn.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try Self.mapDiskFull {
            try conn.exec("BEGIN")
            do {
                try body()
                try conn.exec("COMMIT")
            } catch {
                try? conn.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// 문장을 한 번 돌리고 항상 reset 합니다. 디스크 부족은 `diskFull`로 바꿉니다.
    private static func run(_ st: SQLiteStatement) throws -> Bool {
        defer { st.reset() }
        return try mapDiskFull { try st.step() }
    }

    private static func mapDiskFull<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch {
            if isDiskFull(error) { throw SessionStoreError.diskFull }
            throw error
        }
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        if let e = error as? SessionStoreError { return e == .diskFull }
        if let e = error as? SQLiteError { return (e.code & 0xFF) == SQLITE_FULL }
        return false
    }
}
