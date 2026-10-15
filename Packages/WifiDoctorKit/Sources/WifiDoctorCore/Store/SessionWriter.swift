import Foundation

/// 임시 동기 쓰기 객체. 작업 14가 배치 액터로 바꿉니다.
public final class SessionWriter {
    private let conn: SQLiteConnection
    private let insertProbe: SQLiteStatement

    init(connection: SQLiteConnection) throws {
        conn = connection
        insertProbe = try connection.prepare("""
            INSERT INTO probe (target_id, seq, t_send_mono, send_delay_us, rtt_us, status, ttl)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
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
        _ = try st.step()
        return Int(conn.lastInsertRowId())
    }

    /// 한 트랜잭션. 실패하면 ROLLBACK 하고 던집니다.
    public func write(probes: [ProbeResult]) throws {
        try conn.exec("BEGIN")
        do {
            for p in probes {
                insertProbe.bind(1, Int64(p.targetId)); insertProbe.bind(2, p.seq)
                insertProbe.bind(3, p.tSendMono); insertProbe.bind(4, p.sendDelayUs)
                insertProbe.bind(5, p.rttUs); insertProbe.bind(6, Int64(p.status.rawValue))
                insertProbe.bind(7, p.ttl.map { Int64($0) })
                defer { insertProbe.reset() }
                _ = try insertProbe.step()
            }
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }
}
