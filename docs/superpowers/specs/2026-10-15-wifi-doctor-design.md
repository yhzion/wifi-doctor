# wifi-doctor 설계 문서

- 작성일: 2026-10-15
- 상태: 초안(구현 전)
- 대상: macOS 27, Apple Silicon, Xcode 27.0, Swift 6.4
- 배포: 개인용. App Store 배포 없음.

이 문서는 공개 저장소에 올라갑니다. 실제 내부 IP, SSID, BSSID, MAC 주소, 현장 이름을 쓰지 않습니다. 예시 주소는 RFC 5737 문서용 대역(192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)만 씁니다.

---

## 1. 목적, 범위, 비범위

### 1.1 목적

사용자는 와이파이 끊김이 **어느 구간**에서 발생했는지 인프라 관리자에게 증명해야 합니다.
wifi-doctor는 와이파이 경로와 유선 대조군 경로를 **동시에** 측정합니다.
두 경로의 손실 패턴을 비교해 원인 구간을 판정합니다.
결과는 원시 데이터가 첨부된 HTML 보고서입니다.

### 1.2 후보 구간

| 구간 ID | 이름 | 설명 |
|---|---|---|
| `WIRELESS` | 무선 전용 구간 | 무선 링크(맥↔AP), AP, (있다면) 무선 컨트롤러 터널 |
| `WIRELESS_UPSTREAM` | 무선 경로 전용 상위 구간 | 게이트웨이 이후인데 와이파이 경로만 지나는 구간(무선 VLAN 정책 등) |
| `SHARED_FIRST_HOP` | 공유 첫 홉 | 두 경로의 첫 홉이 같을 때 그 장비(가정용: 공유기 자체) |
| `SHARED_ACCESS` | 공유 하위 L2 구간 또는 우연한 동시 발생 | 첫 홉이 서로 다른데 둘 다 응답하지 않음. traceroute에 보이지 않는 공유 L2 장비(같은 액세스 스위치 등) 또는 두 장애의 우연한 겹침 |
| `SHARED_UPSTREAM` | 게이트웨이 이후 공유 구간 | 가정용: NAT/방화벽/WAN 또는 ISP/인터넷. 기업형(`.mergedLater`): 합류 지점부터 상위. MVP는 더 나누지 않음 |
| `INTERNET_PARTIAL` | 인터넷 일부 대상 | 특정 공인 대상만 실패. 로컬 원인 아님 |
| `WIRED_ONLY` | 유선 대조군 자체 | 유선만 끊김. 와이파이 판정에서 제외 |
| `HOST_STALL` | 맥 자체 지연 | 사건 창 안에서 모든 대상의 프로브 송신이 함께 밀림. 네트워크가 아니라 측정 호스트의 문제. 통계에서 분리 |
| `UNDETERMINED` | 판정 불가 | 대조군 없음, 경로 미탐지, 표본 부족 등. 사유를 함께 기록 |

### 1.3 MVP 범위

- ① 무선 링크 모니터: CoreWLAN. RSSI, 노이즈, SNR, 전송 속도, 채널, BSSID, 연결 상태. 이벤트 + 0.2초 샘플.
- ② 첫 홉(게이트웨이) ICMP 프로브: 초당 20회. 선택 항목으로 AP 관리 IP 추가 프로브.
- ⑤ 인터넷 프로브: `1.1.1.1`, `8.8.8.8` ICMP 초당 5회. DNS UDP 질의 초당 5회.
- 유선 대조군: USB 이더넷에서 같은 대상을 인터페이스 고정으로 동시 측정.
- 경로 탐지: 세션 시작 시 인터페이스별 traceroute 1회. 공유 구간 시작점 산출.
- 끊김 검출, 경로 기반 판정, 무선 원인 세분.
- 실시간 화면(레인 + 선 그래프 + 끊김 목록), 분석 화면.
- 세션 녹화(SQLite 파일 1개), CSV 내보내기, HTML 보고서.
- 시스템 상태 기록: awdl0 상태, 잠자기/깨어남, 위치 권한 상태, 시계 동기 상태.

### 1.4 비범위(MVP에서 하지 않음)

- ③ 내부 유선 에코 장비(UDP 에코, 상향/하향 분리) → 2단계.
- ④ ISP 첫 공인 홉 자동 측정 → 2단계. MVP는 `SHARED_UPSTREAM`에서 WAN/NAT와 ISP를 나누지 않습니다.
- 재생 화면 → 2단계.
- 모니터 모드 무선 캡처 → 3단계.
- awdl0 자동 비활성화(관리자 권한 도우미) → 하지 않음. 사용자 안내로 대체.
- IPv6 측정 → 하지 않음. IPv4만 측정합니다.
- Wi-Fi 스캔, 네트워크 전환, 설정 변경 → 하지 않음. 앱은 관찰만 합니다.
- 원격 수집, 클라우드 업로드, 자동 업데이트 → 하지 않음.

---

## 2. 용어

- **경로(path)**: 측정에 쓰는 인터페이스. `wifi`, `wired` 두 개.
- **대상(target)**: 프로브를 보내는 주소. 경로마다 같은 대상 집합을 둡니다.
- **프로브(probe)**: 순번이 붙은 요청 1회. 응답, 시간 초과, 오류 중 하나로 끝납니다.
- **손실(loss)**: 시간 초과 또는 오류로 끝난 프로브 1회.
- **대상 끊김(target outage)**: 한 대상에서 연속 손실이 기준을 넘은 구간. 5.1절에서 정의.
- **사건(event)**: 시간이 겹치는 대상 끊김의 묶음. 판정의 단위. 5.2절에서 정의.
- **판정(verdict)**: 사건 하나에 붙는 원인 구간 ID와 근거.
- **단조 시각(t_mono)**: `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` 값. 나노초. 모든 측정 행의 기준 시각.
- **벽시계(t_wall)**: Unix epoch 밀리초. 보고서 표기용. 앵커(4.3절)로 단조 시각에서 변환.

---

## 3. 아키텍처

### 3.1 전체 구성

```
┌──────────────────────────────── App (SwiftUI) ────────────────────────────────┐
│ SessionController ─ LiveView ─ AnalysisView ─ ReportView ─ SettingsView      │
└───────────┬───────────────────────────────────────────────────────────────────┘
            │ AsyncStream / async 호출
┌───────────┴──────── WifiDoctorProbes (시스템 의존) ──────────────────────────┐
│ InterfaceDirectory  ICMPProber  DNSProber  WirelessMonitor  PathDiscovery    │
│ SystemGuard(awdl0, 잠자기, 위치 권한, 시계 동기)                            │
└───────────┬───────────────────────────────────────────────────────────────────┘
            │ 값 타입(모델)만 전달
┌───────────┴──────── WifiDoctorCore (순수 로직, 시스템 의존 없음) ────────────┐
│ Models  OutageDetector  EventGrouper  PathCorrelator  Verdict  WirelessClassifier │
│ SessionStore(SQLite)  CSVExporter  ReportRenderer(HTML)                     │
└───────────────────────────────────────────────────────────────────────────────┘
```

규칙:
- `WifiDoctorCore`는 Foundation과 SQLite3만 의존합니다. CoreWLAN, Network, SystemConfiguration을 import하지 않습니다.
- `WifiDoctorProbes`는 Core의 모델 타입을 만들어 넘깁니다. 판단하지 않습니다.
- App은 두 모듈을 조립합니다. 로직을 갖지 않습니다.

### 3.2 모듈 목록

각 모듈은 책임 하나를 갖습니다. "무엇을 하는가 / 어떻게 쓰는가 / 무엇에 의존하는가"를 적습니다.

#### Models (Core)

- 무엇: 모든 모듈이 공유하는 값 타입. `ProbeResult`, `WirelessSample`, `LinkEvent`, `SystemEvent`, `HopList`, `TargetOutage`, `OutageEvent`, `Verdict`, `SessionMeta`.
- 어떻게: `Sendable`, `Codable` 구조체. DB 행과 1:1로 대응.
- 의존: Foundation.

#### InterfaceDirectory (Probes)

- 무엇: Wi-Fi 인터페이스와 유선 인터페이스의 BSD 이름, 인터페이스 인덱스, IPv4 주소, 게이트웨이를 찾습니다. 변화를 알립니다.
- 어떻게: `SCNetworkInterfaceCopyAll()`로 타입을 봅니다. `kSCNetworkInterfaceTypeIEEE80211` → Wi-Fi. `kSCNetworkInterfaceTypeEthernet` 중 IPv4 주소와 링크가 있는 것 → 유선 후보. 후보가 둘 이상이면 사용자가 고릅니다. 게이트웨이는 `SCDynamicStore`의 `State:/Network/Service/<id>/IPv4`에서 `InterfaceName`이 일치하는 항목의 `Router`를 읽습니다. 같은 키에 알림을 걸어 변화를 `SystemEvent`로 냅니다.
- 의존: SystemConfiguration, `getifaddrs`.

#### ICMPProber (Probes)

- 무엇: 인터페이스 하나에 바인딩한 ICMP 에코 프로브. 대상 여러 개를 하나의 소켓으로 처리합니다.
- 어떻게:
  - `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`. root 불필요(7.1절, 이 머신에서 확인).
  - `setsockopt(IPPROTO_IP, IP_BOUND_IF, ifindex)`로 인터페이스 고정.
  - 대상마다 고유한 16비트 ICMP identifier를 배정합니다. 응답은 identifier와 sequence로 짝을 맞춥니다. 커널은 같은 응답을 모든 ICMP 데이터그램 소켓에 전달하므로(7.1절) identifier 필터는 필수입니다.
  - 송신 시각은 `sendto` 직전의 `t_mono`. 예정 송신 시각(타이머 기준)과의 차이를 `send_delay_us`로 함께 기록합니다. 타이머는 `DispatchSourceTimer`에 `leeway: .milliseconds(1)`, `.strict`를 줍니다. 이 값은 맥 자체 지연 판정(6.3절 전제 검사)에 씁니다. 수신은 `recvmsg` 직후의 `t_mono`. 수신 데이터는 IPv4 헤더를 포함합니다(7.1절). 헤더의 목적지 주소가 바인딩한 인터페이스 주소와 다르면 `SystemEvent(kind: "reply_on_wrong_interface")`를 냅니다.
  - sequence는 16비트로 송신하고 DB에는 64비트 누적 순번을 저장합니다.
  - 시간 초과는 1.0초. 초과 뒤 도착한 응답은 `status = late`로 저장합니다. 손실로 셉니다.
  - 송신 주기는 대상별 `DispatchSourceTimer`. 20회/초 대상은 50ms, 5회/초 대상은 200ms.
- 출력: `AsyncStream<ProbeResult>`.
- 의존: Darwin 소켓 API. `Prober` 프로토콜을 따릅니다.

#### DNSProber (Probes)

- 무엇: 인터페이스 고정 UDP DNS 질의. 응답 도착 여부와 RTT만 봅니다.
- 어떻게: `NWConnection(host: resolver, port: 53, using: .udp)`. `NWParameters.requiredInterface`로 고정. 질의는 직접 조립한 DNS 패킷(`www.example.com` A, 재귀 요청). DNS ID = sequence 하위 16비트. 응답 코드는 묻지 않습니다. 응답이 오면 성공입니다. 시스템 리졸버를 쓰지 않습니다. 송신 시각과 `send_delay_us`는 ICMPProber와 같은 방식으로 `send` 호출 직전에 잡습니다.
- 대상: `1.1.1.1:53` 하나. 초당 5회.
- 출력: `AsyncStream<ProbeResult>`.
- 의존: Network.framework. `Prober` 프로토콜을 따릅니다.

#### Prober 프로토콜 (Core에 정의)

```swift
public protocol Prober: Sendable {
    var targets: [ProbeTarget] { get }
    func start() -> AsyncStream<ProbeResult>
    func stop()
}
```

테스트는 `FakeProber`로 대체합니다(9장).

#### WirelessMonitor (Probes)

- 무엇: Wi-Fi 링크 상태 샘플과 이벤트.
- 어떻게:
  - `CWWiFiClient.shared().interface(withName:)`.
  - 0.2초마다 `rssiValue()`, `noiseMeasurement()`, `transmitRate()`, `wlanChannel()`, `powerOn()`, `interfaceMode()`, `bssid()`, `ssid()`를 읽어 `WirelessSample`을 냅니다. SNR = RSSI − 노이즈.
  - 링크 상태 `state`는 앱 정의 값입니다(SDK에 `interfaceState`가 없음. 7.3절). `0 off` = `powerOn() == false`. `1 disconnected` = `powerOn()`이고 `interfaceMode() != station`. `2 associated` = `interfaceMode() == station`. 위치 권한 없이도 계산할 수 있습니다. `rssiValue()`, `noiseMeasurement()`, `transmitRate()`가 0이면(미참여) `nil`로 저장합니다.
  - `startMonitoringEvent(with:)`로 `linkDidChange`, `bssidDidChange`, `ssidDidChange`, `linkQualityDidChange`, `scanCacheUpdated`, `powerDidChange`를 구독합니다. `CWEventDelegate` 콜백을 `LinkEvent`로 냅니다.
  - `scanForNetworks`는 호출하지 않습니다. `scanCacheUpdated` 이벤트는 OS 또는 다른 프로세스가 스캔했음을 뜻합니다. 기록만 합니다.
  - 위치 권한이 없으면 `ssid()`와 `bssid()`가 nil입니다(7.3절). 샘플에는 nil로 저장합니다. 로밍 판정은 `bssidDidChange` 이벤트로 합니다.
- 의존: CoreWLAN, CoreLocation(권한 요청만).

#### PathDiscovery (Probes)

- 무엇: 인터페이스별 홉 목록.
- 어떻게: `/usr/sbin/traceroute -n -i <bsd> -q 1 -w 1 -m 20 1.1.1.1`을 `Process`로 실행합니다. 출력에서 홉 번호와 IP를 파싱합니다. `*`는 `nil` 홉으로 저장합니다. 세션 시작 시 경로마다 1회. 사용자가 "경로 다시 탐지"를 누르면 다시 실행합니다. 결과를 `HopList`로 냅니다.
- 의존: Foundation `Process`. traceroute는 setuid root 바이너리이므로 앱 권한이 필요 없습니다(이 머신에서 확인). `-i`가 송신 인터페이스를 실제로 고정하는지는 검증 필요(7.9절). 실패하면 직접 구현으로 대체합니다.

#### SystemGuard (Probes)

- 무엇: 측정 신뢰성을 위한 시스템 상태 기록과 보호.
- 어떻게:
  - 잠자기 방지: `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason:)`. 세션 시작에 얻고 종료에 반납.
  - 잠자기/깨어남: `NSWorkspace.willSleepNotification`, `didWakeNotification`을 `SystemEvent`로 기록.
  - awdl0: 5초마다 `getifaddrs`로 `awdl0`의 `IFF_UP`, `IFF_RUNNING`을 읽습니다. 변화를 `SystemEvent`로 기록합니다. 비활성화는 하지 않습니다. 설정 화면에 안내문을 보입니다(7.4절).
  - 위치 권한: `CLLocationManager.requestWhenInUseAuthorization()`. 상태를 세션 메타에 기록.
  - 시계 동기: 세션 시작과 종료에 `/usr/bin/sntp time.apple.com`을 실행해 오프셋 문자열을 기록합니다. 실패하면 `"unavailable"`. root 불필요(이 머신에서 확인).
- 의존: AppKit, CoreLocation, Foundation.

#### OutageDetector (Core)

- 무엇: 대상 하나의 `ProbeResult` 열에서 `TargetOutage`를 만듭니다.
- 어떻게: 5.1절의 규칙. 상태 기계 하나. 입력은 순번 순서로 들어온다고 가정합니다. 늦은 응답은 입력 전에 손실로 확정되어 있습니다.
- 의존: Models.

#### EventGrouper (Core)

- 무엇: 여러 대상의 `TargetOutage`를 `OutageEvent`로 묶습니다.
- 어떻게: 5.2절의 규칙. 잠자기 구간(`SystemEvent`)과 겹치는 끊김은 `suppressed = true`로 표시합니다.
- 의존: Models.

#### PathCorrelator (Core)

- 무엇: 두 `HopList`에서 공유 구간 시작점을 구합니다.
- 어떻게: 6.2절의 규칙. 결과는 `PathTopology { mergeIndexWifi, mergeIndexWired, kind: .sameFirstHop | .mergedLater | .noMerge | .unknown }`.
- 의존: Models.

#### Verdict (Core)

- 무엇: `OutageEvent` 하나에 원인 구간 ID와 근거 문장을 붙입니다.
- 어떻게: 6.3절 결정표. 순수 함수 `judge(event, topology, config) -> VerdictResult`.
- 의존: Models, PathCorrelator 결과.

#### WirelessClassifier (Core)

- 무엇: `WIRELESS` 판정을 받은 사건의 무선 원인을 세분합니다.
- 어떻게: 6.4절. 순수 함수. 입력은 사건 창 앞뒤의 `WirelessSample`과 `LinkEvent`.
- 의존: Models.

#### SessionStore (Core)

- 무엇: 세션 파일(SQLite) 읽기/쓰기.
- 어떻게: 시스템 `sqlite3` C API를 얇게 감쌉니다. 서드파티 의존 없음. 이유: 테이블 11개, 문장 수가 적습니다. WAL 모드, `synchronous=NORMAL`. 쓰기는 전용 액터 하나. 1초마다 한 트랜잭션으로 모아 씁니다(7.7절). 읽기는 별도 연결.
- 의존: SQLite3.

#### CSVExporter (Core)

- 무엇: 세션의 원시 데이터를 CSV로 냅니다. 보고서 첨부용.
- 어떻게: 테이블별 파일 1개. `probe.csv`, `wireless_sample.csv`, `link_event.csv`, `system_event.csv`, `hop.csv`, `outage.csv`, `verdict.csv`, `clock_anchor.csv`. 단조 시각과 변환된 벽시계를 둘 다 적습니다.
- 의존: SessionStore.

#### ReportRenderer (Core)

- 무엇: HTML 보고서 한 파일.
- 어떻게: 문자열 템플릿. 그림은 인라인 SVG로 직접 그립니다(선, 사각형만). 외부 스크립트 없음. 입력은 세션 집계 결과(`ReportModel`). 출력은 `String`.
- 의존: Models.

#### SessionController (App)

- 무엇: 세션 생애주기. 프로브 시작/정지, 스트림 병합, 저장, 검출, 판정, UI 상태 갱신.
- 어떻게: `@Observable` 액터 아님. 메인 액터에서 UI 상태만 갖습니다. 측정 파이프라인은 별도 Task에서 돕니다. 실시간 화면용으로 최근 10분을 메모리 링 버퍼에 둡니다.
- 의존: 모든 모듈.

#### Views (App)

- `LiveView`: 구간별 가로 레인, RSSI/SNR/전송 속도 선, 끊김 목록.
- `AnalysisView`: 끊김 길이 분포, 시간당 빈도, 구간별 원인 비율, RSSI-끊김 산점도. Swift Charts.
- `ReportView`: 요약 미리보기와 "HTML 저장" 버튼.
- `SettingsView`: 유선 인터페이스 선택, AP 관리 IP 입력(선택), 저장 폴더, awdl0 안내.

---

## 4. 데이터 모델

### 4.1 파일

- 세션 하나 = SQLite 파일 하나. 이름 `session-<YYYYMMDD-HHmmss>.sqlite`.
- 기본 위치 `~/Documents/wifi-doctor/sessions/`. 설정에서 변경 가능.
- CSV와 HTML은 `~/Documents/wifi-doctor/reports/<세션 이름>/`에 냅니다.

### 4.2 스키마

```sql
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
  event_id    INTEGER REFERENCES event(id)
);

CREATE TABLE verdict (
  event_id        INTEGER PRIMARY KEY REFERENCES event(id),
  segment         TEXT NOT NULL,   -- 1.2절 구간 ID
  wireless_cause  TEXT,            -- coverage_interference | congestion_ap | roaming | disconnect | NULL
  confidence      TEXT NOT NULL,   -- high | medium | low
  reason          TEXT NOT NULL,   -- 사람이 읽는 근거 한 문단
  evidence        TEXT NOT NULL    -- JSON. 대상별 상태와 손실률
);
```

### 4.3 시간 기준

- 모든 측정 행은 `t_mono`(ns)만 가집니다. 출처는 `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`. 이 시계는 잠자기 중 멈춥니다. 조정되지 않습니다. 두 경로의 모든 프로브가 같은 호스트의 같은 시계를 씁니다. 그래서 경로 간 시간 정렬 오차는 0입니다. 남는 오차는 프로브 위상(최대 1주기)과 시간 초과 판정 지연뿐입니다.
- `clock_anchor`에 `(t_mono, t_wall_ms)` 쌍을 저장합니다. 시점: 세션 시작, 10초마다, `did_wake` 직후.
- 벽시계 변환: `t_wall = anchor.t_wall_ms + (t_mono − anchor.t_mono) / 1e6`. anchor는 `t_mono` 이하에서 가장 가까운 것.
- 잠자기 뒤에는 단조 시계가 벽시계보다 뒤처집니다. 다음 앵커가 그 차이를 흡수합니다. 보고서는 "앵커 사이에 벽시계가 X초 점프함 = 잠자기 또는 시계 조정"을 표로 적습니다.
- 시계 동기 상태: `session.sntp_start`, `sntp_end`에 `sntp` 출력 원문을 적습니다. 예: `+0.001 +/- 0.006 time.apple.com`. 이 값은 보고서 "방법론"에 그대로 들어갑니다.

---

## 5. 끊김 정의

### 5.1 대상 끊김(TargetOutage)

입력: 대상 하나의 프로브 열. 각 프로브는 `ok` 또는 `lost`(timeout, late, send_error, unreachable).

규칙:
1. 연속 손실 묶음(run)을 찾습니다. run의 길이 `k`, 대상의 주기 `interval`.
2. `duration = k × interval`.
3. `k ≥ 2` 이고 `duration ≥ 0.2초`이면 대상 끊김입니다.
   - 20회/초(interval 50ms): `k ≥ 4` → 0.2초 이상.
   - 5회/초(interval 200ms): `k ≥ 2` → 0.4초 이상.
4. `k = 1`인 손실은 끊김이 아닙니다. 손실률 통계에만 들어갑니다.
5. `start_mono` = 첫 손실의 송신 시각. `end_mono` = 마지막 손실의 송신 시각 + interval.
6. 끊김은 다음 `ok` 응답이 와야 닫힙니다. 세션 종료 시 열려 있으면 그 시점에서 닫고 `system_event(kind:"probe_error", detail:"open_at_end")`를 적습니다.

왜 `k ≥ 2`인가: 5회/초 대상에서 손실 1회는 정상 인터넷 손실과 구분할 수 없습니다. 단일 손실을 끊김으로 세면 보고서가 시끄러워집니다. 20회/초 대상에서 `k ≥ 4`는 0.2초 하한과 같습니다.

### 5.2 사건(OutageEvent)

입력: 모든 대상의 대상 끊김, 잠자기 이벤트.

규칙:
1. **와이파이 경로**의 대상 끊김만으로 씨앗을 만듭니다. 시간이 겹치거나 간격이 0.5초 이하인 와이파이 대상 끊김을 하나로 묶습니다. 사건 창 = 합집합 `[start, end]`. 이 0.5초 간격 병합이 히스테리시스 역할을 합니다.
2. 유선 경로의 대상 끊김은 사건 창과 겹치거나 간격이 **0.5초 이하**이면 그 사건에 붙입니다. 이것이 와이파이와 유선의 시간 정렬 허용 오차입니다. 근거: 5회/초 대상의 2.5주기, 시간 초과 지연보다 작음.
3. 유선 경로에만 있고 어떤 사건에도 붙지 않은 대상 끊김은 그 자체로 사건이 됩니다. 판정은 `WIRED_ONLY`.
4. 사건 창이 `will_sleep`~`did_wake` 구간과 겹치면 `suppressed = 1`. 통계와 판정에서 제외. 보고서에는 "측정 중단" 표로 따로 적습니다.
5. `duration_ms = end − start`. 버킷: `0.2-0.5`, `0.5-1`, `1-2.5`, `2.5-10`, `10+`. 경계는 하한 포함, 상한 미포함. 1초와 10초는 업무 영향 기준(STALE, DOWN)에 맞춘 값입니다.

### 5.3 사건 창에서 대상 상태

판정은 "대상이 끊김을 가졌나"가 아니라 "사건 창 안에서 대상의 손실률"로 봅니다. 이유: 5회/초 대상은 0.2초 창에 프로브가 0~1개입니다. 독립적으로 끊김 기준을 넘지 못해도 상태를 말할 수 있어야 합니다.

창 `[start, end]` 안에 송신된 프로브로 계산합니다. 창 안에 그 대상의 프로브가 0개이면 창을 `[start − 0.2초, end + 0.2초]`로 한 번 넓힙니다. 창을 넓히지 않고 시작하는 이유: 20회/초 대상의 0.2초 끊김(손실 4회)을 넓힌 창에서 보면 손실률이 0.5 아래로 떨어져 `UP`으로 잘못 읽힙니다.

| 조건 | 상태 |
|---|---|
| (넓힌 뒤에도) 프로브 0개 | `UNKNOWN` |
| 손실률 ≥ 0.5 | `DOWN` |
| 손실률 < 0.5 | `UP` |

상태를 뒷받침하는 프로브가 2개 미만이면 그 상태에 `weak` 표시를 붙입니다. `weak` 상태가 판정에 쓰이면 신뢰도를 한 단계 낮춥니다(`high → medium`, `medium → low`). 0.2~0.5초 사건에서 5회/초 대상은 대개 `weak`입니다. 보고서는 짧은 사건의 판정 범위가 넓다는 점을 이 표시로 드러냅니다.

그룹 상태:
- `GW` = gateway 대상 상태.
- `INET` = `internet_a`, `internet_b`, `dns` 세 대상의 결합. 셋 다 `DOWN` → `DOWN`. 셋 다 `UP` → `UP`. 하나라도 `UNKNOWN`이고 나머지가 모두 같은 값이면 그 값. `DOWN`과 `UP`이 섞이면 `PARTIAL`.
- 경로마다 `GW_w`, `INET_w`, `GW_e`, `INET_e`.

---

## 6. 판정 알고리즘

### 6.1 입력

- 사건의 `GW_w`, `INET_w`, `GW_e`, `INET_e` (5.3절).
- `PathTopology` (6.2절).
- 세션 설정: 유선 대조군 있음/없음, AP 관리 IP 있음/없음.
- 무선 샘플과 링크 이벤트(6.4절에서만).

### 6.2 공유 구간 산출(PathCorrelator)

```
입력: hops_w[1..n], hops_e[1..m]  (nil = 응답 없음)
if hops_w 비어 있음 or hops_e 비어 있음:
    return .unknown
if hops_w[1] != nil and hops_w[1] == hops_e[1]:
    return .sameFirstHop
for i in 1..n:
    if hops_w[i] == nil: continue
    j = hops_e에서 hops_w[i]와 같은 주소의 첫 index
    if j 존재:
        return .mergedLater(wifiIndex: i, wiredIndex: j)
return .noMerge
```

- `.sameFirstHop`: 두 경로가 같은 게이트웨이를 씁니다. 가정용 공유기(AP=게이트웨이=NAT)가 전형입니다. 기업형에서 두 인터페이스가 같은 VLAN일 때도 여기에 옵니다. 보고서는 "첫 홉 동일. 단일 공유기 구조 또는 동일 VLAN"으로 적습니다.
- `.mergedLater`: 두 경로의 첫 홉(게이트웨이)이 서로 다른 L3 장비입니다. 합류 지점은 홉 2 이상에 있습니다. L3 관점의 공유 구간은 합류 지점부터입니다. 합류 전 홉은 각 경로 전용입니다. 주의: traceroute는 L3 홉만 보입니다. 첫 홉 앞의 L2 장비(액세스 스위치, PoE 스위치)는 두 경로가 공유해도 목록에 나오지 않습니다. 그래서 "두 첫 홉이 동시에 응답하지 않음"은 합류 지점 장애로 설명되지 않고, 보이지 않는 공유 L2 장비 또는 우연한 동시 발생으로만 설명됩니다(결정표 4행).
- `.noMerge`: 20홉 안에서 만나지 않았습니다. 중간 장비가 ICMP를 막았을 수 있습니다. 공유 구간은 "인터넷 어딘가"로만 말할 수 있습니다.
- 보고서는 두 홉 목록을 나란히 표로 싣습니다. 합류 지점을 강조합니다. 합류 전 홉이 적을수록(공유 구간이 길수록) 판정이 정밀합니다. 반대로 공유 구간이 짧으면 `SHARED_*` 판정의 범위가 넓어집니다. 이 점을 보고서 문장으로 밝힙니다.

### 6.3 결정표(Verdict)

먼저 전제 검사. 위에서부터 순서대로 봅니다. 첫 일치에서 끝납니다.

| 순서 | 조건 | 결과 |
|---|---|---|
| P1 | 사건이 `suppressed`(잠자기 겹침) | 판정하지 않음 |
| P2 | 맥 자체 지연(6.3.3) | `HOST_STALL`. 통계에서 분리 |
| P3 | 유선 대조군 없음(`wired_if` NULL) 또는 사건 창에서 `GW_e`와 `INET_e`가 모두 `UNKNOWN` | `UNDETERMINED`, 사유 `no_control`. 아래 6.3.1의 보조 설명 추가 |
| P4 | `GW_w = UNKNOWN` 이고 `INET_w = UNKNOWN` | `UNDETERMINED`, 사유 `no_wifi_samples` (정상적으로는 일어나지 않음. 씨앗이 와이파이 끊김이므로) |

본 판정(대조군 있음). 위에서부터 첫 일치 행을 씁니다. `*`는 아무 값.

| # | GW_w | INET_w | GW_e | INET_e | Topology | 판정 | 신뢰도 |
|---|---|---|---|---|---|---|---|
| 1 | DOWN | * | UP | UP | * | `WIRELESS` → 6.4절 세분 | high |
| 2 | DOWN | * | UP | DOWN | * | `WIRELESS` + 동시 발생한 상위 문제 기록(6.3.2) | medium |
| 3 | DOWN | * | DOWN | * | sameFirstHop | `SHARED_FIRST_HOP` | high |
| 4 | DOWN | * | DOWN | * | mergedLater | `SHARED_ACCESS` (서로 다른 두 게이트웨이가 함께 응답 없음. 합류 지점은 상위라 원인이 될 수 없음. 보이지 않는 공유 L2 장비 또는 우연한 동시 발생) | low |
| 5 | DOWN | * | DOWN | * | noMerge / unknown | `UNDETERMINED`, 사유 `both_gateways_down_no_topology` | low |
| 6 | DOWN | * | UNKNOWN | * | * | `UNDETERMINED`, 사유 `control_insufficient` | low |
| 7 | UP | DOWN | UP | UP | * | `WIRELESS_UPSTREAM` (와이파이 경로만 지나는 게이트웨이 이후 구간) | medium |
| 8 | UP | DOWN | UP | DOWN | * | `SHARED_UPSTREAM` | high |
| 9 | UP | DOWN | UP | PARTIAL | * | `INTERNET_PARTIAL` | medium |
| 10 | UP | PARTIAL | UP | PARTIAL | * | `INTERNET_PARTIAL` | high |
| 11 | UP | PARTIAL | UP | UP | * | `WIRELESS_UPSTREAM` 또는 특정 대상 문제. 사유 `partial_wifi_only` | low |
| 12 | UP | DOWN | DOWN | * | * | `WIRED_ONLY` 와 `SHARED_UPSTREAM` 동시 기록. 사유 `control_gateway_down` | low |
| 13 | UP | * | UP | UNKNOWN | * | `UNDETERMINED`, 사유 `control_insufficient` | low |
| 14 | UP | UP | * | * | * | 사건 아님. 씨앗 끊김이 창 확장 뒤 사라진 경우. 사건을 `suppressed`로 표시, 사유 `no_loss_in_window` | - |
| 15 | UNKNOWN | DOWN | UP | UP | * | `WIRELESS` 또는 `WIRELESS_UPSTREAM`. 사유 `gateway_unknown`. 세분 시도 | low |
| 16 | UNKNOWN | DOWN | UP | DOWN | * | `SHARED_UPSTREAM` | medium |
| 17 | 기타 | | | | | `UNDETERMINED`, 사유 `unmatched` + 상태 덤프 | low |

유선만 끊긴 사건(5.2절 3항)은 이 표를 거치지 않고 `WIRED_ONLY`입니다.

AP 관리 IP가 있을 때(선택): `AP_w` 상태를 추가로 계산합니다. 1번 행에서 `AP_w = UP`이면 세분 결과에 "AP는 응답함. 무선 링크 또는 AP 무선부 문제"를 덧붙입니다. `AP_w = DOWN`이면 "AP 자체 또는 그 앞 무선 링크"를 덧붙입니다. 결정표의 행은 바꾸지 않습니다. 기업형에서 AP 관리 IP가 사용자 VLAN에서 닿지 않으면 `AP_w`는 항상 `DOWN`입니다. 세션 시작 시 AP 관리 IP 응답이 0이면 경고를 띄우고 이 대상을 무시합니다.

#### 6.3.1 대조군 없을 때의 보조 설명

판정은 `UNDETERMINED`입니다. 보고서에는 와이파이 경로만으로 말할 수 있는 범위를 덧붙입니다.

| GW_w | INET_w | 보조 설명 |
|---|---|---|
| DOWN | * | "무선 구간 또는 게이트웨이 자체. 유선 대조군이 없어 구분 불가" |
| UP | DOWN | "게이트웨이 이후. 상위 장비 또는 ISP/인터넷. 유선 대조군이 없어 무선 VLAN 전용 경로 가능성 배제 불가" |
| UP | PARTIAL | "특정 인터넷 대상 문제 가능성" |

#### 6.3.2 동시 발생

2번 행처럼 와이파이 게이트웨이와 유선 인터넷이 함께 끊기면 두 사건이 겹친 것입니다. 판정은 `WIRELESS`로 하되 `reason`에 "같은 창에서 유선 경로의 인터넷 손실도 관측됨"을 적습니다. 두 개로 쪼개지 않습니다. 이유: 드물고, 쪼개는 규칙이 복잡합니다.

4번 행(`SHARED_ACCESS`)의 보고서 문구: "와이파이 게이트웨이와 유선 게이트웨이는 서로 다른 장비인데 같은 창에서 둘 다 응답하지 않았습니다. 경로 추적상 두 경로는 홉 N에서 만나므로 합류 지점 장애로는 설명되지 않습니다. 가능한 원인은 (1) 경로 추적에 보이지 않는 공유 L2 장비(예: 두 포트가 같은 액세스 스위치), (2) 서로 무관한 두 장애의 우연한 겹침입니다. 이 사건이 반복되면 (1)의 가능성이 커집니다." 반복 횟수를 함께 적습니다.

#### 6.3.3 맥 자체 지연(HOST_STALL) 검사

목적: "맥이 스스로 만든 끊김"이라는 반박을 데이터로 막습니다. 프로브 스레드 지연, 커널 네트워크 스택 정체, 메모리 압박은 두 경로를 동시에 끊은 것처럼 보이게 합니다.

방법: 각 프로브의 `send_delay_us`(실제 송신 − 예정 송신)를 봅니다. 네트워크 장애는 송신을 늦추지 않습니다. 응답만 사라집니다. 맥 자체 지연은 송신 자체가 밀립니다.

규칙:
1. 창 `[start − 0.5초, end]` 안에 송신된 프로브를 봅니다.
2. 프로브가 **지연됨** = `send_delay_us ≥ interval × 1000`. 즉 실제 송신 간격이 2 × interval 이상.
3. 창 안에 프로브가 1개 이상 있는 모든 대상(두 경로 합쳐서)이 지연된 프로브를 1개 이상 가지면 → `HOST_STALL`.
4. 일부 대상만 지연되었으면 `HOST_STALL`이 아닙니다. 본 판정을 진행하되 `evidence`에 `host_delay_partial = true`와 대상별 최대 `send_delay_us`를 넣고 신뢰도를 한 단계 낮춥니다.
5. `HOST_STALL` 사건은 `event.suppressed = 0`으로 두되 `verdict.segment = 'HOST_STALL'`입니다. 분석 화면과 보고서 요약 통계(끊김 길이 분포, 시간당 빈도, 원인 비율)에서 제외합니다. 보고서에는 별도 표로 횟수와 시각을 적습니다.

대안 비교: 루프백(`127.0.0.1`) ICMP 프로브를 추가해 그 손실로 호스트 문제를 보는 방법이 있습니다. 선택하지 않았습니다. 이유: 대상과 행이 늘어나고, 루프백은 네트워크 스택을 거의 거치지 않아 가벼운 정체를 못 봅니다. `send_delay_us`는 이미 보내는 프로브에 정수 하나를 덧붙일 뿐입니다.

한계: 송신은 정상이고 **수신 처리**만 늦어진 경우는 이 검사로 잡히지 않습니다. 그 경우 응답은 `late`로 기록되고 RTT가 비정상적으로 큽니다. 보고서 방법론에 `late` 비율을 적어 이 한계를 드러냅니다.

### 6.4 무선 원인 세분(WirelessClassifier)

적용 대상: `WIRELESS` 판정(결정표 1, 2, 15행).

입력 창: `[start − 3초, end]`의 `wireless_sample`과 `link_event`. 기준선: `[start − 60초, start − 3초]`의 RSSI 중앙값과 SNR 중앙값.

우선순위 순으로 첫 일치:

| 순서 | 조건 | 원인 |
|---|---|---|
| 1 | 창 안에 `link_down` 이벤트 또는 `state != associated` 샘플 | `disconnect` (연결 끊김) |
| 2 | 창 안에 `bssid_changed` 이벤트 | `roaming` (로밍) |
| 3 | 창 안 RSSI 최솟값 ≤ −75 dBm, 또는 SNR 최솟값 ≤ 15 dB, 또는 기준선 대비 RSSI 하락 ≥ 10 dB | `coverage_interference` (커버리지·간섭) |
| 4 | 그 외(신호 양호) | `congestion_ap` (채널 혼잡·AP 처리) |

창 안에 무선 샘플이 없으면 `wireless_cause = NULL`, `reason`에 "무선 샘플 없음"을 적습니다.

임계값 −75 dBm, 15 dB, 10 dB는 설정 파일 상수로 둡니다. UI에서 바꾸지 않습니다.

### 6.5 가정용 구조에서 원래 행렬의 재현

가정용: AP = 게이트웨이 = NAT. 두 경로의 첫 홉이 같은 공유기입니다. Topology = `.sameFirstHop`.

| 원래 기획안 행렬 | 와이파이 경로 | 유선 경로 | 결정표 행 | 판정 |
|---|---|---|---|---|
| 무선 구간 | GW DOWN | GW UP | 1 | `WIRELESS` → 세분 |
| 공유기 자체 | GW DOWN | GW DOWN | 3 | `SHARED_FIRST_HOP` = 공유기 자체 |
| WAN/NAT 또는 ISP/인터넷 | GW UP, INET DOWN | GW UP, INET DOWN | 8 | `SHARED_UPSTREAM` |
| 인터넷(특정 대상) | GW UP, INET PARTIAL | GW UP, INET PARTIAL | 10 | `INTERNET_PARTIAL` |

원래 행렬의 "WAN/NAT"과 "ISP/인터넷" 구분은 ④ ISP 첫 공인 홉 측정이 필요합니다. 2단계에서 `SHARED_UPSTREAM`을 둘로 나눕니다: ISP 첫 홉 DOWN → WAN/NAT, ISP 첫 홉 UP + 인터넷 DOWN → ISP/인터넷. MVP 보고서는 "게이트웨이 이후 공유 구간(공유기 WAN/NAT 또는 ISP/인터넷)"으로 적습니다.

가정용에서 7번 행(`WIRELESS_UPSTREAM`)이 나오면 비정상입니다. 같은 공유기가 무선 클라이언트만 상위로 보내지 못하는 상황입니다. 보고서는 "공유기 내부(무선 측 포워딩/NAT) 의심. 추가 확인 필요"로 적습니다.

### 6.6 의사코드

```
func judge(event, topology, config) -> VerdictResult:
    if event.suppressed:
        return nil                                   // P1
    stall = hostStallCheck(event)                    // P2, 6.3.3절
    if stall.allTargetsDelayed:
        return HOST_STALL(evidence: stall)
    s = statusInWindow(event)            // GW_w, INET_w, GW_e, INET_e, (AP_w)
    if config.wiredIf == nil or (s.GW_e == UNKNOWN and s.INET_e == UNKNOWN):
        return UNDETERMINED(reason: "no_control", note: auxiliaryNote(s))   // P3
    row = firstMatch(decisionTable, s, topology)   // 6.3절 표
    result = row.segment
    if stall.someTargetsDelayed or s.hasWeak:
        result.confidence = lower(result.confidence)
    if result == WIRELESS:
        result.wirelessCause = classifyWireless(event, samples, linkEvents)
    if config.apMgmtIp != nil and result == WIRELESS:
        result.note += apNote(s.AP_w)
    result.evidence = s   // JSON으로 저장
    return result
```

---

## 7. 기술적 위험과 검증 상태

표기:
- **확인됨**: 2026-10-15, macOS 27.0.1, 이 개발 머신에서 실험 또는 SDK 헤더로 확인.
- **문서 근거**: SDK 헤더 주석 또는 Apple 문서에 근거. 실행 확인은 안 함.
- **검증 필요**: 근거 부족. 구현 초기에 실험으로 확인해야 함.

### 7.1 비특권 ICMP와 인터페이스 고정

- **확인됨**: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`는 일반 사용자(uid 501)로 생성됩니다. 에코 요청을 보내고 응답을 받았습니다.
- **확인됨**: `setsockopt(IPPROTO_IP, IP_BOUND_IF, ifindex)`로 송신 인터페이스가 고정됩니다. 활성 인터페이스에 바인딩하면 응답이 옵니다. 링크가 없는 인터페이스에 바인딩하면 `sendto`가 `EHOSTUNREACH`(No route to host)로 실패합니다. 이 오류는 `status = 4 unreachable`로 기록합니다.
- **확인됨**: 수신 데이터에 IPv4 헤더(20바이트)가 포함됩니다. ICMP identifier는 커널이 바꾸지 않고 보낸 값이 그대로 돌아옵니다. (Linux와 다름.)
- **확인됨**: 같은 인터페이스에 바인딩한 ICMP 데이터그램 소켓 두 개가 **같은 응답을 둘 다** 받았습니다. 그래서 identifier 필터링은 필수입니다. 다른 프로세스의 ping 응답도 들어올 수 있습니다.
- **검증 필요**: 와이파이에 바인딩한 소켓이 유선으로 도착한 응답도 받는지. 받아도 identifier 필터로 걸러지므로 설계는 바뀌지 않습니다. 하지만 수신 처리량에 영향을 줄 수 있습니다.
- **확인됨(SDK 헤더)**: Network.framework의 `nw_parameters_create_custom_ip`는 `com.apple.developer.networking.custom-protocol` 엔타이틀먼트가 필요합니다. 이 엔타이틀먼트를 개인 개발자가 받을 수 있는지는 확인하지 않았습니다. 신청하지 않고 BSD 소켓을 씁니다. BSD 소켓이 이미 동작하므로 필요가 없습니다. 결론: ICMP는 BSD 소켓, UDP(DNS)는 Network.framework `requiredInterface`.
- **확인됨**: `SO_TIMESTAMP_MONOTONIC` 소켓 옵션이 헤더에 있습니다. MVP는 쓰지 않습니다. `recvmsg` 직후 `t_mono`로 충분합니다. RTT 정밀도가 문제로 보이면 2단계에서 검토합니다.

### 7.2 App Sandbox

결정: **App Sandbox를 끕니다.** Hardened Runtime은 켭니다. 서명은 Developer ID 또는 로컬 개발 서명.

이유:
- App Store 배포가 없습니다. 샌드박스의 이점(배포 심사 통과)이 없습니다.
- `/usr/sbin/traceroute`, `/usr/bin/sntp`를 `Process`로 실행합니다. 샌드박스 안에서 자식 프로세스는 샌드박스를 상속합니다. setuid 바이너리가 그 안에서 정상 동작하는지 확인하는 비용이 이점보다 큽니다.
- 임의 폴더에 세션 파일과 보고서를 씁니다.

영향: 없음. 개인용 앱입니다. 보고서 "방법론"에 "앱은 관리자 권한 없이 실행됨"을 적습니다. 이것은 샌드박스와 무관하게 참입니다.

### 7.3 CoreWLAN과 위치 권한

- **확인됨(SDK 헤더)**: `CWInterface.ssid()`, `ssidData()`, `bssid()`, `countryCode()`는 "Location Services가 켜져 있고 앱이 위치 사용 권한을 받았을 때만" 값을 돌려줍니다. 아니면 nil입니다.
- **확인됨(SDK 헤더)**: `rssiValue()`, `noiseMeasurement()`, `transmitRate()`, `wlanChannel()`, `powerOn()`, `interfaceMode()`에는 그런 주석이 없습니다.
- **확인됨(SDK 헤더)**: macOS 27 SDK `CWInterface.h`에 `interfaceState` 메서드와 `CWInterfaceState` 열거형이 없습니다. 있는 것은 `powerOn()`, `interfaceMode()`(`kCWInterfaceModeNone/Station/IBSS/HostAP`), `serviceActive()`입니다. 헤더 주석은 `rssiValue()`, `noiseMeasurement()`, `transmitRate()`가 "인터페이스가 Wi-Fi 네트워크에 참여하지 않으면 0"을, `interfaceMode()`가 그때 `kCWInterfaceModeNone`을 돌려준다고 적습니다. 대체: 링크 상태는 `powerOn()`과 `interfaceMode()`로 계산한 앱 정의 값(3.2절 WirelessMonitor)으로 기록합니다.
- **검증 필요**: 위 여섯 값이 권한 없이 실제로 읽히는지. Wi-Fi를 끊었을 때 `interfaceMode()`가 `none`으로 바뀌는지. 헤더만으로는 단언할 수 없습니다.
- **검증 필요**: 권한이 없을 때 `bssidDidChange` 이벤트가 발생하는지. 발생하면 BSSID 값 없이도 로밍을 검출할 수 있습니다. 발생하지 않으면 로밍 세분은 권한 없이는 불가능합니다. 보고서에 그 한계를 적습니다.
- **확인됨(SDK 헤더)**: `CLLocationManager.requestWhenInUseAuthorization()`은 macOS 10.15부터 있습니다. Info.plist에 `NSLocationUsageDescription`을 넣습니다. 앱은 위치 자체를 쓰지 않습니다. 권한만 받습니다.
- **확인됨(SDK 헤더, 사용 중단)**: `CWInterface.interfaceNames()`, `CWInterface.interface()`, `CWInterface.interfaceWithName:`, `CWInterface.initWithInterfaceName:`는 10.10에서 사용 중단. `CWWiFiClient.interfaceNames()` 클래스 메서드는 13.0에서 사용 중단(인스턴스 메서드로 대체). `startIBSSMode`는 11.0에서 사용 중단. 앱은 `CWWiFiClient.shared()`와 인스턴스 메서드만 씁니다.
- **확인됨(SDK 헤더)**: `CWEventType`에 `scanCacheUpdated`, `linkQualityDidChange`, `bssidDidChange`, `linkDidChange`가 있습니다. `linkQualityDidChange` 콜백은 rssi와 transmitRate를 인자로 줍니다.

### 7.4 awdl0 비활성화

- **확인됨**: `ifconfig awdl0 down`은 일반 사용자로 `permission denied`입니다. root가 필요합니다.
- 결정: 앱은 awdl0를 **건드리지 않습니다**. 상태만 5초마다 기록합니다.
- 사용자 안내(설정 화면 문구): "AirDrop과 Handoff를 끄려면 시스템 설정 > 일반 > AirDrop 및 Handoff에서 AirDrop을 '없음'으로, Handoff를 끄세요. 추가로 터미널에서 `sudo ifconfig awdl0 down`을 실행할 수 있습니다. macOS는 AirDrop 등을 쓸 때 awdl0를 다시 켤 수 있습니다. 앱은 상태 변화를 기록합니다."
- 이유: 관리자 권한 도우미(`SMAppService` + XPC)는 MVP 범위를 넘습니다. 기록만 해도 "awdl0가 UP이던 시간대와 끊김의 상관"을 보고서에 보일 수 있습니다.
- **검증 필요**: awdl0가 `IFF_UP`이지만 실제 AWDL 동작은 없을 때를 `IFF_RUNNING`으로 구분할 수 있는지. 안 되면 `UP/DOWN`만 기록합니다.

### 7.5 Wi-Fi 스캔

- 앱은 `scanForNetworks`를 호출하지 않습니다. 보고서에 명시합니다.
- OS와 다른 프로세스의 스캔은 막을 수 없습니다. `scanCacheUpdated` 이벤트로 "스캔이 있었다"는 사실과 시각만 기록합니다. 누가 스캔했는지는 알 수 없습니다.
- 한계: 로밍을 위한 드라이버 내부 스캔은 이 이벤트로 보이지 않을 수 있습니다. **검증 필요**. 보고서 "방법론"에 "앱은 스캔을 하지 않았고, OS 스캔 캐시 갱신 이벤트는 N회 기록됨" 형태로 적습니다.
- `wdutil`은 sudo가 필요합니다. 쓰지 않습니다.

### 7.6 측정 시계와 잠자기

- `CLOCK_MONOTONIC_RAW`는 잠자기 중 멈춥니다. 앵커(4.3절)로 벽시계와 맞춥니다.
- 잠자기 방지는 `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`. 이것은 유휴 잠자기만 막습니다. 덮개를 닫거나 사용자가 잠자기를 고르면 잠듭니다. 앱은 `will_sleep`/`did_wake`를 기록하고 그 구간의 사건을 `suppressed`로 표시합니다.
- 디스플레이 잠자기는 막지 않습니다. **검증 필요**: 디스플레이가 꺼진 상태에서 Wi-Fi 측정이 끊기지 않는지(Apple Silicon의 저전력 동작). 끊기면 `.idleDisplaySleepDisabled`를 추가합니다.
- **확인됨(SDK 헤더)**: `NSActivityIdleSystemSleepDisabled`, `NSActivityIdleDisplaySleepDisabled`, `IOPMAssertionTypePreventUserIdleSystemSleep` 모두 존재합니다. `ProcessInfo`를 씁니다. 이유: 더 간단하고 같은 효과입니다.

### 7.7 저장 용량과 SQLite 쓰기

행 수(하루, 대조군 포함, AP 관리 IP 없음):
- 와이파이: 게이트웨이 20/s + `1.1.1.1` 5/s + `8.8.8.8` 5/s + DNS 5/s = 35/s.
- 유선: 같음 = 35/s.
- 합계 70/s × 86,400초 = **약 605만 행/일**.
- 무선 샘플 5/s × 86,400 = 43만 행/일.

행 크기 추정: `probe`는 WITHOUT ROWID 테이블. 정수 7개(가변 길이 인코딩. `send_delay_us`는 보통 1~2바이트). 레코드 약 25~35바이트. B-tree 오버헤드와 `probe_time` 인덱스를 더해 행당 60~80바이트로 봅니다. 하루 **약 360~480 MB**. 무선 샘플은 BSSID/SSID 문자열 포함 약 30 MB. 합계 하루 0.5 GB 안팎. 개인용 로컬 디스크에서 허용합니다. 세션 시작 시 여유 공간을 확인하고 2 GB 미만이면 경고합니다(8장).

쓰기 방식:
- 쓰기 전용 액터 하나. 프로브 결과를 메모리 큐에 모읍니다.
- 1초마다 `BEGIN; INSERT ... (prepared statement 재사용) ...; COMMIT;`. 한 트랜잭션에 약 70~80행. 초당 트랜잭션 1회면 WAL + `synchronous=NORMAL`에서 충분합니다.
- 자동 체크포인트는 기본값(1000페이지). 세션 종료 시 `PRAGMA wal_checkpoint(TRUNCATE)`.
- **검증 필요**: 24시간 녹화 뒤 분석 화면 질의(끊김 표와 좁은 시간 창의 원시 프로브)가 1초 안에 끝나는지. 분석 화면은 `outage`, `event`, `verdict` 테이블(수백~수천 행)과 좁은 창의 `probe`만 읽도록 설계했습니다. 하루 전체 원시 스캔은 CSV 내보내기에서만 일어납니다.

### 7.8 두 인터페이스 동시 활성과 라우팅

- macOS는 기본 경로가 하나입니다(서비스 순서). 인터페이스 고정 소켓은 scoped routing으로 그 인터페이스의 게이트웨이를 씁니다.
- **확인됨**: `route -n get -ifscope <if> default`가 인터페이스별 게이트웨이를 돌려줍니다. 앱은 CLI 대신 `SCDynamicStore`의 `Router` 키를 씁니다. 같은 정보입니다.
- 가정용에서 두 인터페이스가 같은 서브넷, 같은 게이트웨이 IP를 가질 수 있습니다. 이 경우에도 IP_BOUND_IF가 송신 인터페이스를 정합니다. 응답 IP 헤더의 목적지 주소가 바인딩한 인터페이스 주소와 같은지 확인해 기록합니다(3.2절 ICMPProber).

### 7.9 traceroute 인터페이스 고정

- **확인됨**: `/usr/sbin/traceroute`는 setuid root입니다. 일반 사용자로 `-i en0 -n -q 1 -w 1 -m 2 1.1.1.1`이 동작했습니다.
- **검증 필요**: `-i`가 송신 인터페이스를 실제로 고정하는지, 또는 출발지 주소만 바꾸는지. man 페이지는 "출발지 IP 주소를 얻기 위해" 인터페이스를 지정한다고만 말합니다. 두 인터페이스가 서로 다른 네트워크에 붙은 상태에서 홉 목록이 달라지는지 확인해야 합니다.
- 대체안(검증 실패 시): ICMP 데이터그램 소켓에 `IP_TTL`을 1부터 올리며 에코를 보내고, `ICMP Time Exceeded`가 같은 소켓으로 들어오는지 확인합니다. 이것도 **검증 필요**입니다. 둘 다 실패하면 경로 탐지는 `.unknown`이 되고 결정표 5번 행이 늘어납니다. 그 경우 사용자가 홉 목록을 수동 입력하는 길을 2단계에서 검토합니다.

### 7.10 DNS 프로브의 의미

- `www.example.com`을 리졸버에 묻습니다. 리졸버는 캐시에서 답합니다. 이 프로브는 "리졸버까지의 경로 + 리졸버 생존"을 봅니다. 재귀 해석 성능은 보지 않습니다. 보고서 방법론에 적습니다.

---

## 8. 오류 처리

| 상황 | 감지 | 처리 | 기록 |
|---|---|---|---|
| 유선 미연결(세션 시작 시) | InterfaceDirectory에 유선 후보 없음 | 사용자에게 "대조군 없이 시작" 확인. 시작하면 `wired_if = NULL`. 모든 판정 `UNDETERMINED(no_control)` | `session.wired_if = NULL` |
| 유선 인터페이스 사라짐(세션 중) | SCDynamicStore 알림, `sendto` `ENXIO`/`EHOSTUNREACH` 연속 | 유선 프로브는 계속 시도. 결과는 `status = 4`. 유선 대상 끊김이 생기지만 `WIRED_ONLY`. 그 창의 와이파이 사건은 `GW_e`/`INET_e`가 `DOWN`으로 보이므로 오판 위험. 그래서 `interface_lost`~`interface_back` 구간의 와이파이 사건은 대조군을 `UNKNOWN`으로 강제 → `UNDETERMINED(control_insufficient)` | `system_event(interface_lost / interface_back)` |
| 유선 인터페이스 BSD 이름 변경(재연결 후) | 알림의 인터페이스 목록 비교 | 같은 하드웨어 포트 이름(`SCNetworkInterfaceGetLocalizedDisplayName`)이면 새 이름으로 재바인딩. 소켓 재생성 | `system_event(interface_back, detail: 새 이름)` |
| Wi-Fi 인터페이스 꺼짐 | `powerDidChange`, `state = 0 (off)` | 측정 계속. 손실로 기록. 세분은 `disconnect` | `link_event(power_changed)` |
| 게이트웨이 주소 변경(DHCP) | SCDynamicStore `Router` 변경 | 새 `target` 행 추가. 이전 대상 중단. 보고서에 변경 시각 표기 | `system_event(gateway_changed)` |
| 위치 권한 거부 | `CLLocationManager` 상태 | 계속 진행. SSID/BSSID NULL. 보고서에 "권한 없음, 로밍 세분 제한"을 적음 | `session.location_auth` |
| ICMP 소켓 생성 실패 | `socket()` 오류 | 세션 시작 거부. 오류 메시지와 errno 표시 | 없음(세션 없음) |
| 디스크 부족 | 시작 시 여유 < 2 GB 경고. 세션 중 `SQLITE_FULL` 또는 여유 < 500 MB | 500 MB 미만이면 녹화 정지. 실시간 화면은 유지. 사용자에게 알림 | `system_event(disk_low)` |
| SQLite 쓰기 오류(기타) | 반환 코드 | 3회 재시도. 실패하면 녹화 정지, 알림 | `system_event(probe_error)` |
| traceroute 실패/시간 초과(30초) | `Process` 종료 코드, 타임아웃 | Topology `.unknown`. 세션은 진행. 설정 화면에 "경로 다시 탐지" 버튼 | `hop` 행 없음 + `system_event(probe_error, detail:"traceroute")` |
| sntp 실패 | 종료 코드 | `'unavailable'` 기록. 진행 | `session.sntp_*` |
| 잠자기 | `willSleepNotification` | 측정 계속 시도(실제로는 멈춤). 깨어나면 앵커 기록. 겹친 사건 `suppressed` | `system_event(will_sleep / did_wake)` |
| 앱 비정상 종료 | 다음 실행 시 `ended_mono_ns IS NULL` 파일 발견 | 열기 가능. 열린 끊김은 마지막 프로브 시각으로 닫음. 보고서에 "비정상 종료" 표기 | `notes` |

---

## 9. 테스트 전략

### 9.1 단위 테스트(순수 로직, `WifiDoctorCore`)

Swift Testing. `swift test`로 Xcode 없이 실행 가능.

- `OutageDetector`:
  - 20/s에서 손실 3회 → 끊김 아님. 4회 → 0.2초 끊김.
  - 5/s에서 손실 1회 → 끊김 아님. 2회 → 0.4초 끊김.
  - `late` 상태가 손실로 처리됨.
  - 세션 끝에 열린 끊김이 닫힘.
- `EventGrouper`:
  - 와이파이 끊김 두 개, 간격 0.4초 → 사건 1개. 간격 0.6초 → 사건 2개.
  - 유선 끊김이 와이파이 사건과 0.5초 안 → 붙음. 0.6초 → 별도 `WIRED_ONLY` 사건.
  - 잠자기 구간과 겹침 → `suppressed`.
  - 버킷 경계: 0.2, 0.5, 1.0, 2.5, 10.0 각각 하한 포함.
- `PathCorrelator`: 같은 첫 홉, 나중 합류, 합류 없음, `nil` 홉 포함, 빈 목록.
- `Verdict`: 결정표 17행 각각 한 케이스 이상. 6.5절 가정용 표 4행. 대조군 없음. AP 관리 IP 유무. 전제 검사 P1~P4 순서(잠자기 겹침이 HOST_STALL보다 먼저).
- `HOST_STALL` 검사(6.3.3):
  - 모든 대상의 `send_delay_us`가 창 안에서 interval 이상 → `HOST_STALL`.
  - 와이파이 대상만 지연 → `HOST_STALL` 아님. `host_delay_partial = true`, 신뢰도 한 단계 하향.
  - 지연 없이 두 게이트웨이 손실 → 3행 또는 4행 그대로.
  - 지연된 프로브가 창 밖(`start − 0.6초`)에만 있음 → `HOST_STALL` 아님.
- `WirelessClassifier`: 우선순위 4개 각각. 샘플 없음.
- `SessionStore`: 메모리 DB(`:memory:`)에 쓰고 읽기. 1초 배치 커밋이 순서를 보존함.
- `ReportRenderer`: 고정 입력 → HTML에 요약 숫자, 홉 표, 방법론 문장이 포함됨. 실제 주소가 아닌 `192.0.2.1` 등을 씁니다.

합성 데이터 생성기 `SyntheticSession`: 주기, 손실 구간, 송신 지연 구간(경로별 또는 전체), 무선 샘플 곡선을 받아 `ProbeResult`와 `WirelessSample` 배열을 만듭니다. 송신 지연 구간에서는 `t_send_mono`를 밀고 `send_delay_us`를 그만큼 채웁니다. 테스트 픽스처는 이 생성기만 씁니다. 실제 녹화 파일은 테스트에 넣지 않습니다(10장).

### 9.2 경계: 프로브의 가짜 구현

`Prober`, `WirelessMonitoring`, `PathDiscovering`, `SystemGuarding` 프로토콜을 Core에 둡니다. `WifiDoctorProbes`가 실제 구현, 테스트가 가짜 구현을 제공합니다. `SessionController`는 프로토콜만 봅니다. 그래서 전체 파이프라인(프로브 → 저장 → 검출 → 판정)을 가짜 프로브로 통합 테스트합니다.

### 9.3 시스템 의존 모듈의 스모크 테스트

실제 네트워크가 필요합니다. CI에서 돌리지 않습니다. 수동 실행 태그를 붙입니다.
- `ICMPProber`: 활성 인터페이스에 바인딩해 `1.1.1.1` 응답 1회. 비활성 인터페이스에서 `unreachable`.
- `DNSProber`: `1.1.1.1:53` 응답 1회.
- `WirelessMonitor`: 샘플 1개에 RSSI 값 존재.
- `PathDiscovery`: 홉 1개 이상 파싱.

### 9.4 수동 현장 검증 절차

각 절차는 "예상 판정"이 나오면 통과입니다. 결과를 `docs/verification/`에 날짜별로 적습니다(실제 주소는 쓰지 않음).

| # | 절차 | 예상 판정 |
|---|---|---|
| V1 | 와이파이+유선 모두 연결. 10분 정상 측정 | 사건 0건 또는 `INTERNET_PARTIAL`만 |
| V2 | 맥의 Wi-Fi를 끄고 5초 뒤 켬 | `WIRELESS` / `disconnect`. 유선은 영향 없음 |
| V3 | AP 전원 차단 30초(가정용이면 공유기 무선만 끄기) | `WIRELESS`. BSSID 변화 없음 또는 `disconnect` |
| V4 | 유선 케이블 분리 10초 | `WIRED_ONLY`. 그 구간 와이파이 사건은 `UNDETERMINED(control_insufficient)` |
| V5 | 공유기(가정용) 전원 차단 30초 | `SHARED_FIRST_HOP` |
| V6 | WAN 케이블만 분리(가정용) | `SHARED_UPSTREAM` |
| V7 | 벽 뒤로 이동해 RSSI를 −80 dBm 이하로 떨어뜨림 | `WIRELESS` / `coverage_interference` 또는 사건 없음 |
| V8 | 다른 AP 영역으로 걸어가 로밍 유발(기업형) | `WIRELESS` / `roaming` |
| V9 | 세션 시작 뒤 맥을 잠자기(덮개 닫기) 1분 | 그 구간 사건 `suppressed`. 앵커가 점프를 기록 |
| V10 | 24시간 녹화 | 파일 크기 0.3~0.6 GB. 분석 화면 1초 내 응답. 보고서 생성 성공 |
| V11 | 측정 중 터미널에서 `kill -STOP <앱 pid>`, 2초 뒤 `kill -CONT` | 사건 1건, `HOST_STALL`. 요약 통계에서 제외됨. 별도 표에 표시 |

---

## 10. 저장소 위생

공개 저장소입니다. 다음 규칙을 지킵니다.

`.gitignore`:
```
# 측정 산출물
*.sqlite
*.sqlite-wal
*.sqlite-shm
sessions/
reports/
*.csv
docs/verification/**/*.html

# Xcode / SwiftPM
.build/
DerivedData/
xcuserdata/
*.xcuserstate
*.xcscmblueprint
.swiftpm/xcode/package.xcworkspace/xcuserdata/
```

추가 규칙:
- 테스트 픽스처와 문서의 주소는 RFC 5737 대역만 씁니다. BSSID/MAC 예시는 `02:00:00:00:00:01` 형태(로컬 관리 주소)만 씁니다. SSID 예시는 `example-ssid`.
- 보고서 HTML은 저장소에 커밋하지 않습니다. 보고서는 사용자가 인프라 관리자에게 직접 전달합니다.
- `docs/verification/`에는 결과 표만 적습니다. 원시 파일은 넣지 않습니다.
- 커밋 전 `git diff --cached | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}'`로 주소를 점검하는 절차를 README에 적습니다. 자동 훅은 두지 않습니다(개인 프로젝트, 과한 장치).

---

## 11. 프로젝트 구조

권장: **Xcode 프로젝트(앱 타깃) + 로컬 Swift Package(로직)**.

```
wifi-doctor/
├── WifiDoctor.xcodeproj            # 앱 타깃만. 서명, 엔타이틀먼트, Info.plist
├── WifiDoctor/                     # App 모듈 (SwiftUI)
│   ├── WifiDoctorApp.swift
│   ├── SessionController.swift
│   └── Views/
├── Packages/
│   └── WifiDoctorKit/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── WifiDoctorCore/     # 순수 로직 + SQLite
│       │   └── WifiDoctorProbes/   # CoreWLAN, Network, SystemConfiguration
│       └── Tests/
│           ├── WifiDoctorCoreTests/
│           └── WifiDoctorProbesSmokeTests/   # 수동 태그
├── docs/
│   ├── superpowers/specs/
│   └── verification/
├── .gitignore
└── README.md
```

이유:
- 앱 번들, 서명, 엔타이틀먼트(샌드박스 끔, Hardened Runtime), Info.plist 권한 문구는 Xcode 프로젝트가 가장 단순합니다.
- 로직은 패키지에 두면 `swift test`로 빠르게 돌립니다. Xcode를 열지 않아도 됩니다.
- 패키지를 둘로 나눈 이유: `WifiDoctorCore`가 시스템 프레임워크를 import하지 않음을 컴파일러가 보장합니다. 테스트가 네트워크 없이 돕니다.
- 대안(순수 SwiftPM 실행 파일 + 수동 번들링)은 서명과 Info.plist 처리가 번거롭습니다. 선택하지 않습니다.

Swift 설정:
- Swift 6 언어 모드. strict concurrency. `Sendable` 모델.
- 최소 배포 버전 macOS 27. 하위 호환은 고려하지 않습니다.

---

## 12. 데이터 흐름

```
[ICMPProber(wifi)] ┐
[ICMPProber(wired)]├─ ProbeResult ─┐
[DNSProber(wifi)]  │               │
[DNSProber(wired)] ┘               ▼
[WirelessMonitor] ── WirelessSample/LinkEvent ──► SessionController
[SystemGuard] ────── SystemEvent ───────────────►   │
[PathDiscovery] ──── HopList (시작 시 1회) ──────►   │
                                                     ├─► SessionStore(1초 배치 쓰기)
                                                     ├─► 링 버퍼(최근 10분) ─► LiveView
                                                     ├─► OutageDetector(대상별) ─► TargetOutage
                                                     │        └─► EventGrouper ─► OutageEvent ─► Verdict ─► WirelessClassifier
                                                     │                                              └─► SessionStore(outage/event/verdict)
                                                     │                                              └─► LiveView 끊김 목록
                                                     └─► 세션 종료 ─► AnalysisView 질의 ─► ReportRenderer ─► HTML + CSVExporter
```

- 검출과 판정은 실시간으로 돕니다. 사건은 닫힌 뒤(마지막 대상 끊김이 닫힌 뒤 + 0.5초 대기) 판정합니다. 판정 결과는 바뀌지 않습니다. 재판정은 하지 않습니다(설정 상수가 바뀌면 다음 세션부터 적용).
- 재생 화면(2단계)이 생기면 저장된 프로브로 같은 검출·판정 코드를 다시 돌립니다. 순수 로직이라 가능합니다.

---

## 13. 화면

### 13.1 실시간(LiveView)

- 상단: 세션 상태(경과 시간, 파일 크기, awdl0 상태, 위치 권한, 유선 대조군 유무).
- 레인(가로 시간축, 최근 10분, 1초당 1픽셀 이상):
  - `wifi/gateway`, `wifi/internet(3개 합산)`, `wired/gateway`, `wired/internet`. 선택 입력 시 `wifi/ap_mgmt`.
  - 초록 = 창 안 손실 0. 노랑 = 손실 있으나 끊김 아님. 빨강 = 끊김.
- 선 그래프: RSSI(dBm), SNR(dB), 전송 속도(Mbps). 레인과 시간축 공유.
- 끊김 목록: 시각, 길이, 버킷, 판정, 무선 원인. 최신이 위.

### 13.2 분석(AnalysisView)

- 끊김 길이 분포(버킷별 막대).
- 시간당 빈도(1초 이상 사건, 시간대별 막대).
- 구간별 원인 비율(판정 ID별 막대. 파이 차트는 쓰지 않음).
- RSSI-끊김 산점도: x = 사건 시작 3초 전 RSSI 중앙값, y = 길이(초, 로그 축).
- 홉 목록 두 개와 합류 지점.

### 13.3 보고서(HTML)

구성:
1. 요약: 측정 기간, 총 사건 수(`HOST_STALL`과 `suppressed` 제외), 최장 끊김, 1초 이상 사건의 시간당 횟수, 판정 ID별 횟수, 가장 많은 판정 한 문장.
2. 판정 근거: 결정표(6.3절) 요약과 Topology. 두 홉 목록. 공유 구간 범위에 대한 주의 문장.
3. 방법론: 프로브 대상/주기/시간 초과, 끊김 정의(5장 그대로), 인터페이스 고정 방법, 위치 권한 상태, awdl0 상태 이력, 스캔 미실행 선언과 OS 스캔 캐시 갱신 횟수, 시계 동기(sntp 원문), 앵커 점프 표, 잠자기 구간. 측정 호스트 건전성: 세션 전체 `send_delay_us`의 p50/p99/최댓값, `late` 응답 비율, `HOST_STALL`로 분리한 사건 수와 시각 표, 그리고 "이 사건들은 맥 자체 지연으로 판정되어 아래 통계에서 제외됨"이라는 문장.
4. 대표 끊김 확대 그림: 가장 긴 사건과 가장 흔한 판정의 중앙값 사건 2개. 사건 전후 10초의 대상별 프로브를 점으로, RSSI를 선으로 그린 인라인 SVG.
5. 끊김 전체 표: 시각, 길이, 판정, 무선 원인, 신뢰도, 근거 요약.
6. 첨부 목록: CSV 파일 이름과 행 수. 세션 파일 이름과 SHA-256.

보고서는 외부 리소스를 참조하지 않습니다. 파일 하나로 열립니다.

---

## 14. 단계 계획

- **MVP**: 이 문서의 1~13장. 2단계 항목은 제외.
- **2단계**: ③ 내부 유선 에코 장비(UDP 에코 서버는 별도 소형 프로그램), ④ ISP 첫 공인 홉 자동 선택(홉 목록에서 첫 공인 주소)과 `SHARED_UPSTREAM` 분할, 재생 화면, `SO_TIMESTAMP_MONOTONIC` 검토, 홉 수동 입력.
- **3단계(선택)**: 두 번째 맥의 모니터 모드 캡처(재전송률, 비콘 누락)를 세션에 병합.

---

## 15. 자체 검토 결과

- 모든 섹션에 내용이 있습니다. TBD 없음.
- 1.2절 구간 ID(9개)와 6.3절 결정표·전제 검사의 판정 값이 일치합니다. `SHARED_ACCESS`는 4행에서만, `HOST_STALL`은 전제 검사 P2에서만 나옵니다.
- 결정표 4행을 고쳤습니다. `.mergedLater`에서 두 첫 홉은 서로 다른 장비이고 합류 지점은 상위이므로, 처음 초안의 "합류 지점" 판정은 두 첫 홉의 동시 무응답을 설명하지 못했습니다. 6.2절 `.mergedLater` 설명에 "traceroute는 L2 장비를 보여주지 않음"을 추가해 4행과 맞췄습니다. 신뢰도는 `low`.
- 맥 자체 지연 검사(6.3.3)를 추가했습니다. `probe.send_delay_us` 한 열만 늘었습니다. 전제 검사 P2로 결정표보다 먼저 돕니다. 잠자기(P1)가 먼저인 이유: 잠자기도 큰 송신 지연을 만들지만 이미 `suppressed`로 처리되므로 `HOST_STALL` 통계를 오염시키지 않게 합니다.
- 4.2절 `probe` 스키마, 7.7절 행 크기, 9.1절 테스트, 9.4절 V11, 13.3절 보고서 방법론이 `send_delay_us`와 `HOST_STALL`을 같은 의미로 씁니다.
- 5.1절 `k ≥ 2`와 5.3절 "창 안 손실률" 규칙은 서로 보완합니다. 끊김 생성은 엄격하게, 창 안 상태 판정은 손실률로 합니다. 9.1절 테스트가 둘을 모두 다룹니다.
- 7.2절(샌드박스 끔)과 3.2절 PathDiscovery/SystemGuard의 `Process` 사용이 일치합니다.
- 7.3절 위치 권한 제약과 3.2절 WirelessMonitor의 nil 처리, 6.4절 로밍 세분이 일치합니다.
- 4.3절 시간 기준과 5.2절 "정렬 허용 오차 0.5초"의 근거가 연결됩니다.
- 5.3절 상태 창을 `[start, end]`로 두고 프로브가 없을 때만 넓히도록 고쳤습니다. 처음 초안의 "항상 ±0.2초"는 짧은 끊김을 `UP`으로 오판했습니다.
- 크기: 모듈 13개, 테이블 11개, 결정표 17행. 구현 계획 하나로 다룰 수 있는 범위입니다.
- 구현 계획 작성 중 D1 반영(2026-10-15): macOS 27 SDK에 `CWInterface.interfaceState`/`CWInterfaceState`가 없음을 확인했습니다. 3.2절 WirelessMonitor, 4.2절 `wireless_sample.state`, 6.4절 1행, 7.3절, 8장 "Wi-Fi 인터페이스 꺼짐" 행을 앱 정의 상태(0 off / 1 disconnected / 2 associated)로 고쳤습니다.
