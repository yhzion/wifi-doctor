import Foundation

public struct SessionStore {
    /// 설계 문서 4.2절 그대로. `wireless_sample.state` 주석만 D1(앱 정의 값)로 바꿨습니다.
    public static let schemaSQL: String = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA user_version = 1;

    CREATE TABLE session (
      id              INTEGER PRIMARY KEY CHECK (id = 1),
      schema_version  INTEGER NOT NULL,
      app_version     TEXT    NOT NULL,
      os_version      TEXT    NOT NULL,
      started_wall_ms INTEGER NOT NULL,
      started_mono_ns INTEGER NOT NULL,
      ended_mono_ns   INTEGER,
      wifi_if         TEXT    NOT NULL,   -- BSD 이름
      wired_if        TEXT,               -- 없으면 NULL (대조군 없음)
      wifi_gateway    TEXT,
      wired_gateway   TEXT,
      ap_mgmt_ip      TEXT,               -- 선택 입력
      location_auth   TEXT    NOT NULL,   -- authorized | denied | notDetermined
      sntp_start      TEXT,               -- sntp 출력 원문 또는 'unavailable'
      sntp_end        TEXT,
      notes           TEXT
    );

    CREATE TABLE target (
      id          INTEGER PRIMARY KEY,
      path        TEXT    NOT NULL,   -- 'wifi' | 'wired'
      role        TEXT    NOT NULL,   -- 'gateway' | 'ap_mgmt' | 'internet_a' | 'internet_b' | 'dns'
      address     TEXT    NOT NULL,
      kind        TEXT    NOT NULL,   -- 'icmp' | 'dns'
      interval_ms INTEGER NOT NULL,   -- 50 | 200
      timeout_ms  INTEGER NOT NULL,   -- 1000
      icmp_ident  INTEGER             -- icmp일 때
    );

    CREATE TABLE probe (
      target_id   INTEGER NOT NULL REFERENCES target(id),
      seq         INTEGER NOT NULL,   -- 대상별 64비트 누적 순번
      t_send_mono INTEGER NOT NULL,   -- ns, 실제 송신 시각
      send_delay_us INTEGER NOT NULL, -- 실제 송신 − 예정 송신. 맥 자체 지연 판정용
      rtt_us      INTEGER,            -- 응답 없으면 NULL
      status      INTEGER NOT NULL,   -- 0 ok, 1 timeout, 2 late, 3 send_error, 4 unreachable
      ttl         INTEGER,            -- 응답 IP 헤더의 TTL (icmp만)
      PRIMARY KEY (target_id, seq)
    ) WITHOUT ROWID;
    CREATE INDEX probe_time ON probe(target_id, t_send_mono);

    CREATE TABLE wireless_sample (
      t_mono      INTEGER PRIMARY KEY,  -- ns, 0.2초 간격
      state       INTEGER NOT NULL,     -- 앱 정의 값: 0 off, 1 disconnected, 2 associated
      rssi_dbm    INTEGER,
      noise_dbm   INTEGER,
      tx_rate_mbps REAL,
      channel     INTEGER,
      band        INTEGER,              -- CWChannelBand 원값
      width_mhz   INTEGER,
      bssid       TEXT,                 -- 권한 없으면 NULL
      ssid        TEXT                  -- 권한 없으면 NULL
    );

    CREATE TABLE link_event (
      t_mono   INTEGER NOT NULL,
      kind     TEXT    NOT NULL,   -- link_down | link_up | bssid_changed | ssid_changed | scan_cache_updated | power_changed | link_quality
      detail   TEXT                -- JSON. 예: {"rssi":-70,"txRate":540.0}
    );
    CREATE INDEX link_event_time ON link_event(t_mono);

    CREATE TABLE system_event (
      t_mono   INTEGER NOT NULL,
      kind     TEXT    NOT NULL,   -- awdl0_state | will_sleep | did_wake | interface_lost | interface_back | gateway_changed | reply_on_wrong_interface | disk_low | probe_error
      detail   TEXT
    );
    CREATE INDEX system_event_time ON system_event(t_mono);

    CREATE TABLE clock_anchor (
      t_mono   INTEGER PRIMARY KEY,
      t_wall_ms INTEGER NOT NULL
    );

    CREATE TABLE hop (
      path      TEXT    NOT NULL,   -- 'wifi' | 'wired'
      run       INTEGER NOT NULL,   -- 탐지 회차. 0부터
      hop_index INTEGER NOT NULL,   -- 1부터
      address   TEXT,               -- '*'이면 NULL
      rtt_ms    REAL,
      t_mono    INTEGER NOT NULL,
      PRIMARY KEY (path, run, hop_index)
    );

    CREATE TABLE event (
      id          INTEGER PRIMARY KEY,
      start_mono  INTEGER NOT NULL,
      end_mono    INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL,
      bucket      TEXT    NOT NULL,   -- '0.2-0.5' | '0.5-1' | '1-2.5' | '2.5-10' | '10+'
      suppressed  INTEGER NOT NULL DEFAULT 0  -- 잠자기와 겹침 등
    );

    CREATE TABLE outage (
      id          INTEGER PRIMARY KEY,
      target_id   INTEGER NOT NULL REFERENCES target(id),
      start_mono  INTEGER NOT NULL,   -- 첫 손실 프로브의 t_send_mono
      end_mono    INTEGER NOT NULL,   -- 마지막 손실 프로브의 t_send_mono + interval
      lost_count  INTEGER NOT NULL,
      first_seq   INTEGER NOT NULL,
      last_seq    INTEGER NOT NULL,
      event_id    INTEGER REFERENCES event(id),
      closed_at_end INTEGER NOT NULL DEFAULT 0  -- 세션 종료로 닫힘(5.1절 6항)
    );

    CREATE TABLE verdict (
      event_id        INTEGER PRIMARY KEY REFERENCES event(id),
      segment         TEXT NOT NULL,   -- 1.2절 구간 ID
      wireless_cause  TEXT,            -- coverage_interference | congestion_ap | roaming | disconnect | NULL
      confidence      TEXT NOT NULL,   -- high | medium | low
      reason_code     TEXT,            -- 6.3절 사유 코드. 없으면 NULL
      reason          TEXT NOT NULL,   -- 사람이 읽는 근거 한 문단
      evidence        TEXT NOT NULL    -- JSON. 대상별 상태와 손실률
    );
    """

    /// 파일을 만들고 PRAGMA, 스키마, session 행(id = 1)을 씁니다.
    public static func create(path: String, meta: SessionMeta) throws -> SessionWriter {
        let conn = try SQLiteConnection(path: path)
        try conn.exec(schemaSQL)
        let st = try conn.prepare("""
            INSERT INTO session (id, schema_version, app_version, os_version, started_wall_ms, started_mono_ns,
              ended_mono_ns, wifi_if, wired_if, wifi_gateway, wired_gateway, ap_mgmt_ip, location_auth,
              sntp_start, sntp_end, notes) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        st.bind(1, Int64(meta.schemaVersion)); st.bind(2, meta.appVersion); st.bind(3, meta.osVersion)
        st.bind(4, meta.startedWallMs); st.bind(5, meta.startedMonoNs); st.bind(6, meta.endedMonoNs)
        st.bind(7, meta.wifiIf); st.bind(8, meta.wiredIf); st.bind(9, meta.wifiGateway)
        st.bind(10, meta.wiredGateway); st.bind(11, meta.apMgmtIp); st.bind(12, meta.locationAuth)
        st.bind(13, meta.sntpStart); st.bind(14, meta.sntpEnd); st.bind(15, meta.notes)
        _ = try st.step()
        return try SessionWriter(connection: conn)
    }

    public static func openReader(path: String) throws -> SessionReader {
        try SessionReader(path: path)
    }
}
