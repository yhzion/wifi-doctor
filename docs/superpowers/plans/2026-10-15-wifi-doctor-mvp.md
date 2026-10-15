# wifi-doctor MVP 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- 작성일: 2026-10-15
- 참조 이슈: https://github.com/yhzion/wifi-doctor/issues/1 (MVP 범위 체크리스트)
- 설계 문서: `docs/superpowers/specs/2026-10-15-wifi-doctor-design.md`

**Goal:** 와이파이 경로와 유선 대조군 경로를 동시에 측정하고, 끊김의 원인 구간을 판정해 HTML 보고서로 내는 macOS 앱(MVP)을 만듭니다.

**Architecture:** 순수 로직은 `WifiDoctorCore`(Foundation + SQLite3만)에 둡니다. 시스템 의존 코드는 `WifiDoctorProbes`(CoreWLAN, Network, SystemConfiguration, AppKit, CoreLocation)에 둡니다. SwiftUI 앱은 두 모듈을 조립만 합니다. 검출·판정 파이프라인(`SessionPipeline`)은 Core에 두어 가짜 프로브로 `swift test`에서 통합 테스트합니다.

**Tech Stack:** Swift 6.4(언어 모드 6, strict concurrency), Swift Testing, SwiftPM 로컬 패키지 `Packages/WifiDoctorKit`, xcodegen 2.46.0(앱 타깃 생성), SQLite3(시스템), Swift Charts, macOS 27 최소 배포.

**Spec:** `docs/superpowers/specs/2026-10-15-wifi-doctor-design.md`

---

## 전역 제약 (Global Constraints)

설계 문서에서 그대로 가져온 값입니다. 모든 작업에 적용됩니다.

- 대상: macOS 27, Apple Silicon, Xcode 27.0, Swift 6.4. 최소 배포 macOS 27. 하위 호환 없음.
- Swift 6 언어 모드. strict concurrency. 모델은 `Sendable`, `Codable`.
- `WifiDoctorCore`는 Foundation과 SQLite3만 import합니다. CoreWLAN, Network, SystemConfiguration, AppKit, CoreLocation을 import하지 않습니다.
- `WifiDoctorProbes`는 Core의 모델을 만들어 넘기기만 합니다. 판단하지 않습니다.
- App 모듈은 로직을 갖지 않습니다.
- App Sandbox 끔. Hardened Runtime 켬.
- IPv4만 측정합니다.
- 앱은 `scanForNetworks`를 호출하지 않습니다. awdl0를 바꾸지 않습니다. 관찰만 합니다.
- 단조 시각 `t_mono` = `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)` 나노초. 모든 측정 행의 기준.
- 게이트웨이 ICMP 20회/초(50ms). 인터넷 ICMP `1.1.1.1`, `8.8.8.8` 5회/초(200ms). DNS UDP `1.1.1.1:53` 5회/초. 시간 초과 1.0초.
- 대상 끊김: 연속 손실 `k ≥ 2` 이고 `k × interval ≥ 0.2초`.
- 사건 병합 간격 0.5초. 상태 창 `[start, end]`, 프로브 0개일 때만 ±0.2초 확장.
- 버킷 `0.2-0.5`, `0.5-1`, `1-2.5`, `2.5-10`, `10+`. 하한 포함, 상한 미포함.
- 무선 임계값: RSSI ≤ −75 dBm, SNR ≤ 15 dB, 기준선 대비 하락 ≥ 10 dB. 코드 상수. UI에서 바꾸지 않음.
- 세션 파일 `~/Documents/wifi-doctor/sessions/session-<YYYYMMDD-HHmmss>.sqlite`. 보고서 `~/Documents/wifi-doctor/reports/<세션 이름>/`.
- SQLite: WAL, `synchronous=NORMAL`, `user_version=1`. 쓰기 액터 하나. 1초 배치 트랜잭션.
- 공개 저장소. 코드·테스트·문서의 주소는 RFC 5737 대역(`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`)만. BSSID 예시는 `02:00:00:00:00:01`. SSID 예시는 `example-ssid`.
- 테스트 픽스처는 `SyntheticSession` 생성기만 씁니다. 실제 녹화 파일은 넣지 않습니다.
- 커밋 메시지는 `feat:`, `test:`, `chore:`, `docs:` 접두어를 씁니다. 각 커밋 끝에 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` 줄을 둡니다.

## 사용자가 확정한 기본값

1. 세션 파일 위치 `~/Documents/wifi-doctor/` (하위 `sessions/`, `reports/`).
2. DNS 대상 `1.1.1.1:53` 하나.
3. 무선 임계값 RSSI ≤ −75 dBm, SNR ≤ 15 dB, 기준선 대비 −10 dB.
4. 위치 권한 거부 시에도 측정 허용. 보고서에 한계 명시.
5. 결정표 2행(와이파이 GW 끊김 + 유선 INET 끊김)은 하나의 `WIRELESS` 사건으로 처리.

## 계획 중 확인한 사실과 설계 문서와의 차이

계획을 쓰면서 이 머신에서 확인했습니다. 구현자는 아래를 설계 문서보다 우선합니다.

| # | 확인 내용 | 영향 |
|---|---|---|
| D1 | macOS 27 SDK의 `CWInterface.h`에 `interfaceState` 메서드와 `CWInterfaceState` 열거형이 **없습니다**. 있는 것은 `powerOn`, `interfaceMode`(`kCWInterfaceModeNone/Station/IBSS/HostAP`), `serviceActive`, `rssiValue`(미참여 시 0), `noiseMeasurement`(미참여 시 0), `transmitRate`(미참여 시 0). | `wireless_sample.state`는 앱 정의 값으로 바꿉니다. `0 off`(`powerOn == false`), `1 disconnected`(`powerOn`이고 `interfaceMode != station`), `2 associated`(`interfaceMode == station`). 6.4절 1행의 "`state != running`"은 "`state != associated`"로 읽습니다. RSSI/노이즈/전송 속도가 0이면 `nil`로 저장합니다. 작업 5, 24에서 적용. 스파이크 S2(작업 2)에서 Wi-Fi 끊을 때 `interfaceMode`가 `none`으로 바뀌는지 확인합니다. |
| D2 | `swift package init`(6.4)은 Swift Testing을 기본 생성합니다. `.enabled(if:)`로 게이트한 스위트는 `swift test`에서 "skipped"로 나옵니다. `.linkedLibrary("sqlite3")`와 `platforms: [.macOS("27.0")]`가 컴파일됩니다. `import CoreWLAN`, `Network`, `SystemConfiguration`, `CoreLocation`이 SwiftPM 타깃에서 컴파일됩니다. | 작업 4의 `Package.swift`를 그대로 씁니다. |
| D3 | `/usr/sbin/traceroute`는 setuid root. `man traceroute`의 `-i`는 "출발지 IP 주소를 얻기 위한 인터페이스"라고만 적혀 있습니다. | 7.9절 그대로 **검증 필요**. 스파이크 S1(작업 1). |
| D4 | 이 머신의 awdl0는 지금 `UP,RUNNING` 둘 다 켜져 있습니다. | SystemGuard(작업 26)는 두 플래그를 모두 기록합니다. 구분 가능 여부는 현장 검증 메모에 적습니다. |
| D5 | `xcodegen` 2.46.0이 `/opt/homebrew/bin`에 있습니다. | Xcode 프로젝트는 `project.yml`에서 생성합니다(작업 27). `.xcodeproj`는 커밋하지 않고 `.gitignore`에 추가합니다. 대안은 "미결 질문" 참조. |
| D6 | 이 머신의 Wi-Fi는 `en0`, USB 이더넷은 `en11`로 보입니다. | 스모크 테스트는 인터페이스 이름을 환경 변수로 받습니다. 문서에 이름을 고정하지 않습니다. |

설계를 보완하는 결정(설계 문서는 침묵하거나 모순):

| # | 결정 | 이유 |
|---|---|---|
| R1 | `SessionPipeline`(검출·그룹·판정·저장 조율)을 Core에 둡니다. App의 `SessionController`는 UI 상태와 Probes 조립만 합니다. | 3.1절 "App은 로직을 갖지 않음"과 9.2절 "가짜 프로브로 파이프라인 통합 테스트"를 함께 만족합니다. |
| R2 | 프로브 결과는 **순번 순서**로 검출기에 들어가야 합니다(5.1절 가정). 그러나 시간 초과(1.0초)는 다음 응답보다 늦게 확정됩니다. Core에 `SeqOrderBuffer`를 두고, 두 Prober가 결과를 낼 때 통과시킵니다. | 설계 문서는 누가 순서를 보장하는지 적지 않았습니다. |
| R3 | `judge`는 미리 계산한 `EventStatus`, `HostStallResult`, 무선 컨텍스트를 인자로 받습니다. 설계의 `judge(event, topology, config)`보다 인자가 많습니다. | 결정표를 순수 함수로 두고 표 기반 테스트를 쉽게 하기 위함. 조합은 `SessionPipeline`이 합니다. |
| R4 | 결정표 12행: `verdict.segment = SHARED_UPSTREAM`, `evidence.secondary = "WIRED_ONLY"`, `reason_code = control_gateway_down`. 스키마는 바꾸지 않습니다. | 설계는 "둘을 동시에 기록"만 말합니다. 사건은 와이파이 씨앗이므로 와이파이 쪽 가설을 주 판정으로 둡니다. |
| R5 | 8장 "유선 인터페이스 사라짐" 구간의 사건: `EventStatus.controlForcedUnknown = true`. `judge`는 P3보다 **먼저** 이 플래그를 보고 `UNDETERMINED(control_insufficient)`를 냅니다. | 그대로 두면 `GW_e = INET_e = UNKNOWN`이 P3 `no_control`에 걸립니다. 8장은 `control_insufficient`를 요구합니다. |
| R6 | SessionStore 테스트는 `:memory:` 대신 임시 파일을 씁니다. | 설계가 요구하는 "읽기는 별도 연결"을 `:memory:`로는 검증할 수 없습니다. |
| R7 | `Tests/WifiDoctorProbesTests/`를 추가합니다(네트워크 불필요한 순수 파서 테스트: ICMP 패킷, DNS 패킷, traceroute 출력). 스모크 테스트와 분리합니다. | 11장 트리에는 없지만 파서 버그는 `swift test`로 잡아야 합니다. |
| R8 | 사건 판정 시점: 모든 대상의 마지막 관측 `t_send_mono`가 `event.end + 0.2초(창 확장) + 0.5초(병합 대기)` 이상이 되면 판정합니다. 세션 종료 시 `finish()`가 남은 사건을 판정합니다. | 12장 "+0.5초 대기"를 결정적(데이터 기준 시각)으로 만들어 테스트합니다. |
| R9 | HOST_STALL 창 `[start − 0.5초, end]`의 소속 판정은 **예정 송신 시각** `tSendMono − sendDelayUs × 1000`으로 합니다. | 지연된 프로브는 실제 송신이 창 뒤로 밀립니다(예: 2초 정지면 `end + 2초`). 실제 송신 시각으로 보면 가장 중요한 프로브가 창 밖으로 빠져 `HOST_STALL`을 놓칩니다. 설계 6.3.3절은 이 점을 적지 않았습니다. |

## Review Focus

설계가 암시하지만 어떤 테스트도 다루지 않던 입력. 각 줄의 테스트는 해당 작업에 넣었습니다.

1. 응답이 순번 역순으로 확정됨(seq 5 `ok`가 seq 4 `timeout`보다 먼저). 검출기는 순번 순으로 받아야 합니다. → 작업 6 `SeqOrderBuffer` 테스트.
2. 세션 중 게이트웨이 주소 변경으로 `gateway` 역할 대상이 둘(이전·현재). 창 안에 프로브가 없는 쪽은 상태 계산에서 빠져야 합니다. → 작업 8 테스트 `gatewayTargetWithoutProbesIsIgnored`.
3. 기준선 구간(`start − 60초 ~ start − 3초`)에 무선 샘플이 없음. 하락 규칙만 건너뛰고 절대 임계값은 적용해야 합니다. → 작업 12 테스트 `noBaselineSkipsDropRule`.
4. 같은 identifier·sequence의 ICMP 응답이 두 번 도착(7.1절: 커널이 모든 소켓에 전달, 다른 프로세스 ping). 두 번째는 버려야 하고 `ok`가 두 번 세어지면 안 됩니다. → 작업 21 `ICMPPacketTests.duplicateReplyIgnored`.
5. 세션 종료 시 열린 끊김과 아직 판정하지 않은 사건. `finish()`가 끊김을 닫고(`probe_error/open_at_end`) 사건을 판정해야 합니다. → 작업 19 테스트 `finishClosesOpenOutageAndJudges`.

---

## 파일 구조

```
wifi-doctor/
├── project.yml                               # xcodegen 입력(커밋). WifiDoctor.xcodeproj는 생성물
├── WifiDoctor/                               # App 모듈
│   ├── WifiDoctorApp.swift
│   ├── Info.plist
│   ├── WifiDoctor.entitlements
│   ├── SessionController.swift               # 조립 + UI 상태. 로직 없음
│   ├── AppSettings.swift                     # @AppStorage 키
│   └── Views/ LiveView.swift AnalysisView.swift ReportView.swift SettingsView.swift
├── Packages/WifiDoctorKit/
│   ├── Package.swift
│   ├── Sources/WifiDoctorCore/
│   │   ├── Models/   Probe.swift Wireless.swift System.swift Path.swift Outage.swift Verdict.swift Session.swift
│   │   ├── Boundary/ Protocols.swift          # Prober, WirelessMonitoring, PathDiscovering, SystemGuarding
│   │   ├── Detection/ SeqOrderBuffer.swift OutageDetector.swift EventGrouper.swift WindowStatus.swift
│   │   ├── Verdict/  PathCorrelator.swift HostStallCheck.swift Verdict.swift WirelessClassifier.swift
│   │   ├── Store/    SQLite.swift SessionStore.swift SessionWriter.swift SessionReader.swift
│   │   ├── Export/   CSVExporter.swift ReportModel.swift ReportModelBuilder.swift ReportRenderer.swift
│   │   └── Pipeline/ SessionPipeline.swift
│   ├── Sources/WifiDoctorProbes/
│   │   ├── MonotonicClock.swift InterfaceDirectory.swift
│   │   ├── ICMPPacket.swift ICMPProber.swift DNSPacket.swift DNSProber.swift
│   │   ├── WirelessMonitor.swift TracerouteParser.swift PathDiscovery.swift SystemGuard.swift
│   └── Tests/
│       ├── WifiDoctorCoreTests/   Support/SyntheticSession.swift Support/Fakes.swift + 단위별 *Tests.swift
│       ├── WifiDoctorProbesTests/ ICMPPacketTests.swift DNSPacketTests.swift TracerouteParserTests.swift
│       └── WifiDoctorProbesSmokeTests/ SmokeTests.swift   # WIFI_DOCTOR_SMOKE=1 일 때만
├── Spikes/                                   # 작업 1~3 스크립트(기록용)
├── docs/superpowers/specs/, docs/superpowers/plans/, docs/verification/
├── .gitignore
└── README.md
```

## 단계 개요

| 단계 | 작업 | 완료 기준 |
|---|---|---|
| 0. 스파이크 | 1–3 | `docs/verification/2026-10-15-spikes.md`에 S1~S3 결과와 선택한 대안이 적혀 있다. |
| 1. 골격 | 4 | `swift test`가 Core/Probes 두 모듈과 세 테스트 타깃으로 통과한다. |
| 2. Core 로직(TDD) | 5–19 | 9.1절 모든 항목의 테스트가 `swift test`로 통과한다. 가짜 프로브 파이프라인 통합 테스트가 통과한다. |
| 3. Probes(스모크) | 20–26 | 9.3절 스모크 4종이 `WIFI_DOCTOR_SMOKE=1`로 통과한다. 순수 파서 테스트가 `swift test`로 통과한다. |
| 4. App | 27–32 | `xcodegen generate && xcodebuild ... build`가 성공한다. 세션 시작→정지→HTML+CSV 저장이 수동으로 된다. README가 있다. |
| 5. 현장 검증 | 33 | 9.4절 V1~V11 결과가 `docs/verification/`에 표로 적혀 있다(사용자 수행). |

## 공통 규약

- 패키지 명령은 모두 `cd Packages/WifiDoctorKit`에서 실행합니다.
- 단위 테스트: `swift test --filter <SuiteName>`. 전체: `swift test`.
- 스모크 테스트: `WIFI_DOCTOR_SMOKE=1 WIFI_DOCTOR_WIFI_IF=<wifi bsd> WIFI_DOCTOR_WIRED_IF=<wired bsd> swift test --filter WifiDoctorProbesSmokeTests`. 인터페이스 이름은 `networksetup -listallhardwareports`로 확인합니다.
- Core 격리 점검(모든 Core 작업의 마지막 검증 단계): `grep -rE '^import (CoreWLAN|Network|SystemConfiguration|AppKit|CoreLocation)' Sources/WifiDoctorCore` → 출력 없음.
- 주소 점검(커밋 전): `git diff --cached | grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|1\.1\.1\.1|8\.8\.8\.8|127\.0\.0\.1|0\.0\.0\.0'` → 출력 없음.
- 시간 단위: 변수 이름 끝에 단위를 붙입니다(`Ns`, `Us`, `Ms`). Core의 시간은 `Int64` 나노초.

---

## 단계 0. 스파이크

세 작업은 설계를 바꿀 수 있습니다. 결과를 `docs/verification/2026-10-15-spikes.md`에 표로 적습니다. 주소는 적지 않습니다.

**사용자가 손으로 할 일:** 작업 1과 3은 USB 이더넷에 케이블을 꽂아야 합니다. 와이파이와 다른 네트워크(예: 휴대폰 테더링 vs 사무실 유선)면 가장 좋습니다. 같은 공유기여도 작업은 가능합니다.

### Task 1: 스파이크 S1 — `traceroute -i`가 송신 인터페이스를 고정하는가 (7.9절)

**Files:**
- Create: `Spikes/s1-traceroute-iface.sh`
- Create: `docs/verification/2026-10-15-spikes.md`

**Interfaces:**
- Produces: 작업 25 `PathDiscovery`의 구현 방식 결정(A/B/C).

- [ ] **Step 1: 스크립트 작성**

```bash
#!/bin/sh
# 사용법: Spikes/s1-traceroute-iface.sh <wifi_if> <wired_if>
# 각 인터페이스의 송신 패킷 수(Opkts)를 traceroute 전후로 비교합니다.
set -eu
WIFI=$1; WIRED=$2
opkts() { netstat -I "$1" -b | awk 'NR==2 {print $7}'; }
for IF in "$WIFI" "$WIRED"; do
  echo "== traceroute -i $IF"
  W0=$(opkts "$WIFI"); E0=$(opkts "$WIRED")
  /usr/sbin/traceroute -n -i "$IF" -q 1 -w 1 -m 3 1.1.1.1 2>&1 | sed -n '1,4p' | awk '{print "hop:", $1, ($2=="*"?"*":"addr")}'
  W1=$(opkts "$WIFI"); E1=$(opkts "$WIRED")
  echo "wifi Opkts +$((W1-W0))  wired Opkts +$((E1-E0))"
done
echo "== 인터페이스별 게이트웨이 일치 여부(값은 출력하지 않음)"
GW_W=$(route -n get -ifscope "$WIFI" default 2>/dev/null | awk '/gateway/ {print $2}')
GW_E=$(route -n get -ifscope "$WIRED" default 2>/dev/null | awk '/gateway/ {print $2}')
[ "$GW_W" = "$GW_E" ] && echo "same gateway" || echo "different gateway"
```

- [ ] **Step 2: 실행**

Run: `chmod +x Spikes/s1-traceroute-iface.sh && Spikes/s1-traceroute-iface.sh en0 <wired_if>` (3회 반복)
Expected(통과): `-i <wired>` 구간에서 `wired Opkts`가 3 이상 늘고 `wifi Opkts` 증가는 배경 트래픽 수준. `-i <wifi>` 구간은 반대. "different gateway"면 홉 1이 각각 다른 주소.
Expected(실패): 두 구간 모두 같은 인터페이스의 Opkts만 늘어남. 또는 `-i <wired>`의 홉 1이 와이파이 게이트웨이.

- [ ] **Step 3: 실패 시 S1b — ICMP 데이터그램 소켓 TTL 단계 탐지 가능 여부**

`Spikes/s1b-ttl-probe.swift`를 만듭니다. 내용: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` → `setsockopt(IP_BOUND_IF, ifindex)` → `setsockopt(IP_TTL, 1)` → `1.1.1.1`로 에코 1개 `sendto` → `recvfrom` 1초 대기 → 받은 데이터의 IPv4 헤더 뒤 ICMP type을 출력.
Run: `swift Spikes/s1b-ttl-probe.swift <wifi_if>`
Expected(가능): `type=11`(Time Exceeded) 수신, 출발지 = 첫 홉.
Expected(불가): 시간 초과 또는 `type=0`만 수신.

- [ ] **Step 4: 결과와 대안을 기록**

`docs/verification/2026-10-15-spikes.md`에 표를 씁니다.

| 결과 | 작업 25 구현 |
|---|---|
| A: `-i` 고정됨 | 설계 그대로. `Process`로 `/usr/sbin/traceroute -n -i <bsd> -q 1 -w 1 -m 20 1.1.1.1`. |
| B: `-i` 안 됨, S1b 가능 | Probes에 `IcmpTraceroute` 구현. TTL 1~20, TTL마다 에코 1개, 1초 대기. `IP_BOUND_IF`로 고정. 출력은 같은 `HopList`. |
| C: 둘 다 안 됨 | `PathDiscovery.discover`가 `nil`을 반환. Topology `.unknown`. `system_event(probe_error, detail:"traceroute_unavailable")`. 결정표 5행이 늘어남을 보고서에 적음. 홉 수동 입력은 2단계(계획 밖). |

- [ ] **Step 5: Commit**

```bash
git add Spikes/ docs/verification/2026-10-15-spikes.md
git commit -m "chore: spike S1 traceroute interface pinning result"
```

### Task 2: 스파이크 S2 — 위치 권한 없이 CoreWLAN 값이 읽히는가 (7.3절, D1)

**Files:**
- Create: `Spikes/s2-cwlan-noauth.swift`
- Modify: `docs/verification/2026-10-15-spikes.md`

**Interfaces:**
- Produces: 작업 24 `WirelessMonitor`의 권한 거부 동작, 작업 12 로밍 세분 한계 문구.

**사용자가 손으로 할 일:** 시스템 설정 > 개인정보 보호 및 보안 > 위치 서비스에서 Terminal(또는 실행에 쓰는 앱)의 위치 권한이 **꺼져 있는지** 확인합니다. 켜져 있으면 결과가 오염됩니다.

- [ ] **Step 1: 스크립트 작성**

```swift
// swift Spikes/s2-cwlan-noauth.swift <wifi_if>
import CoreWLAN
import Foundation

final class Delegate: NSObject, CWEventDelegate {
    func bssidDidChangeForWiFiInterface(withName n: String) { print("event bssidDidChange") }
    func linkDidChangeForWiFiInterface(withName n: String) { print("event linkDidChange") }
    func ssidDidChangeForWiFiInterface(withName n: String) { print("event ssidDidChange") }
    func powerStateDidChangeForWiFiInterface(withName n: String) { print("event powerDidChange") }
}

let name = CommandLine.arguments[1]
let client = CWWiFiClient.shared()
guard let i = client.interface(withName: name) else { print("no interface"); exit(1) }
let d = Delegate()
client.delegate = d
for t in [CWEventType.bssidDidChange, .linkDidChange, .ssidDidChange, .powerDidChange] {
    try client.startMonitoringEvent(with: t)
}
print("powerOn=\(i.powerOn()) mode=\(i.interfaceMode().rawValue) serviceActive=\(i.serviceActive())")
print("rssi=\(i.rssiValue()) noise=\(i.noiseMeasurement()) txRate=\(i.transmitRate())")
print("channel=\(i.wlanChannel()?.channelNumber ?? -1) ssid=\(i.ssid() ?? "nil") bssid=\(i.bssid() ?? "nil")")
print("이제 Wi-Fi를 끄고 5초 뒤 켜세요. 30초 동안 이벤트를 기다립니다.")
let end = Date().addingTimeInterval(30)
while Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    print("tick mode=\(i.interfaceMode().rawValue) rssi=\(i.rssiValue())")
}
```

- [ ] **Step 2: 실행**

Run: `swift Spikes/s2-cwlan-noauth.swift en0`
Expected(통과): `rssi`가 0이 아닌 음수, `noise` 음수, `txRate > 0`, `channel > 0`, `ssid=nil bssid=nil`. Wi-Fi를 끄면 `mode=0`, `rssi=0`, `event linkDidChange`(또는 `powerDidChange`). 켜면 `event bssidDidChange`가 찍힘.
Expected(일부 실패): `rssi=0`이 연결 중에도 계속 나옴, 또는 `bssidDidChange`가 안 찍힘.

- [ ] **Step 3: 결과와 대안을 기록**

| 결과 | 영향 |
|---|---|
| A: 다섯 값 읽힘 + `bssidDidChange` 발생 | 설계 그대로. 권한 거부 시 SSID/BSSID만 NULL. 로밍 세분 가능. |
| B: 다섯 값 읽힘, `bssidDidChange` 미발생 | 로밍 세분은 권한 있을 때만. 작업 12 변경 없음(이벤트가 안 오면 2행이 안 맞을 뿐). 작업 17 보고서 방법론에 "위치 권한 없음: 로밍 세분 불가" 문장 추가(권한 `denied`일 때). |
| C: 다섯 값이 권한 없이 0 | 작업 24에서 권한 없을 때 `rssiDbm = nil` 등으로 저장. 작업 12는 샘플 없음 처리(`wireless_cause = NULL`, "무선 샘플 없음"). 보고서는 "위치 권한 없음: 무선 세분 불가". 사용자 기본값 4(측정 허용)는 유지. |
| D1 확인 | Wi-Fi를 끄면 `interfaceMode == 0`으로 바뀌는지. 바뀌면 D1의 상태 정의를 그대로 씁니다. 바뀌지 않으면 `rssiValue() == 0`을 `disconnected`의 보조 조건으로 씁니다. |

- [ ] **Step 4: Commit**

```bash
git add Spikes/s2-cwlan-noauth.swift docs/verification/2026-10-15-spikes.md
git commit -m "chore: spike S2 CoreWLAN without location permission"
```

### Task 3: 스파이크 S3 — 와이파이 바인딩 소켓이 유선으로 온 응답도 받는가 (7.1절)

**Files:**
- Create: `Spikes/s3-icmp-crosstalk.swift`
- Modify: `docs/verification/2026-10-15-spikes.md`

**Interfaces:**
- Produces: 작업 23 `ICMPProber` 수신 필터의 기대 부하. 설계는 바뀌지 않습니다.

- [ ] **Step 1: 스크립트 작성**

내용: 소켓 A를 `<wifi_if>`에, 소켓 B를 `<wired_if>`에 `IP_BOUND_IF`로 바인딩. B에서 identifier `0xB0B0`, seq 1~20으로 `1.1.1.1`에 에코 20개를 50ms 간격으로 송신. 동시에 A에서 2초 동안 `recvfrom`을 반복해 받은 ICMP 응답의 identifier를 모두 출력. 끝에 "A가 받은 0xB0B0 응답 수 / B가 받은 0xB0B0 응답 수"를 출력. 수신 데이터는 IPv4 헤더 20바이트 뒤가 ICMP 헤더입니다(7.1절 확인됨).

- [ ] **Step 2: 실행**

Run: `swift Spikes/s3-icmp-crosstalk.swift en0 <wired_if>`
Expected(어느 쪽이든 설계 유지):
- "A가 받은 0xB0B0 = 0" → 교차 수신 없음. 필터는 identifier만으로 충분.
- "A가 받은 0xB0B0 > 0" → 교차 수신 있음. 작업 23의 identifier 필터가 걸러냄. 응답 IPv4 헤더의 목적지 주소가 바인딩 인터페이스 주소와 다르면 `reply_on_wrong_interface`를 1분에 1회로 요약 기록(건마다 기록하면 행이 폭증).

- [ ] **Step 3: 결과 기록 후 Commit**

```bash
git add Spikes/s3-icmp-crosstalk.swift docs/verification/2026-10-15-spikes.md
git commit -m "chore: spike S3 ICMP cross-interface reply result"
```

---

## 단계 1. 골격

### Task 4: Swift Package 골격

**Files:**
- Create: `Packages/WifiDoctorKit/Package.swift`
- Create: `Packages/WifiDoctorKit/Sources/WifiDoctorCore/Models/Session.swift` (상수 하나. 작업 5에서 채움)
- Create: `Packages/WifiDoctorKit/Sources/WifiDoctorProbes/MonotonicClock.swift`
- Create: `Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/PackageTests.swift`
- Create: `Packages/WifiDoctorKit/Tests/WifiDoctorProbesTests/PackageTests.swift`
- Create: `Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/Smoke.swift`

**Interfaces:**
- Produces: `MonotonicClock.nowNs() -> Int64` (Probes). `Smoke.enabled: Bool`, `Smoke.wifiIf`, `Smoke.wiredIf` (스모크 테스트 공용).

- [ ] **Step 1: 실패하는 테스트**

`Tests/WifiDoctorCoreTests/PackageTests.swift`:
```swift
import Testing
@testable import WifiDoctorCore

@Test func coreSchemaVersionIsOne() {
    #expect(CoreInfo.schemaVersion == 1)
}
```

`Tests/WifiDoctorProbesTests/PackageTests.swift`:
```swift
import Testing
@testable import WifiDoctorProbes

@Test func monotonicClockIncreases() {
    let a = MonotonicClock.nowNs()
    let b = MonotonicClock.nowNs()
    #expect(b >= a)
    #expect(a > 0)
}
```

`Tests/WifiDoctorProbesSmokeTests/Smoke.swift`:
```swift
import Foundation
import Testing

enum Smoke {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["WIFI_DOCTOR_SMOKE"] == "1" }
    static var wifiIf: String { env["WIFI_DOCTOR_WIFI_IF"] ?? "en0" }
    static var wiredIf: String? { env["WIFI_DOCTOR_WIRED_IF"] }
}

extension Tag { @Tag static var smoke: Self }

@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct SmokeGate {
    @Test func gateIsOpen() { #expect(Smoke.enabled) }
}
```

- [ ] **Step 2: 실행해 실패 확인**

Run: `cd Packages/WifiDoctorKit && swift test`
Expected: FAIL. `Package.swift` 없음.

- [ ] **Step 3: 구현**

`Package.swift`(이 머신에서 컴파일 확인한 형태):
```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WifiDoctorKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WifiDoctorCore", targets: ["WifiDoctorCore"]),
        .library(name: "WifiDoctorProbes", targets: ["WifiDoctorProbes"]),
    ],
    targets: [
        .target(name: "WifiDoctorCore",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "WifiDoctorProbes",
                dependencies: ["WifiDoctorCore"],
                linkerSettings: [
                    .linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"),
                    .linkedFramework("SystemConfiguration"), .linkedFramework("Network"),
                    .linkedFramework("AppKit"),
                ]),
        .testTarget(name: "WifiDoctorCoreTests", dependencies: ["WifiDoctorCore"]),
        .testTarget(name: "WifiDoctorProbesTests", dependencies: ["WifiDoctorProbes"]),
        .testTarget(name: "WifiDoctorProbesSmokeTests", dependencies: ["WifiDoctorProbes"]),
    ],
    swiftLanguageModes: [.v6]
)
```

`Sources/WifiDoctorCore/Models/Session.swift`(시작점. 작업 5에서 채움):
```swift
public enum CoreInfo {
    public static let schemaVersion = 1
}
```

`Sources/WifiDoctorProbes/MonotonicClock.swift`:
```swift
import Darwin

public enum MonotonicClock {
    /// CLOCK_MONOTONIC_RAW 나노초. 잠자기 중 멈춤.
    public static func nowNs() -> Int64 {
        Int64(bitPattern: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test`
Expected: `coreSchemaVersionIsOne`, `monotonicClockIncreases` PASS. `SmokeGate` skipped.
Run: `WIFI_DOCTOR_SMOKE=1 swift test --filter SmokeGate`
Expected: `gateIsOpen` PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/
git commit -m "chore: add WifiDoctorKit package skeleton (Core, Probes, tests)"
```

---

## 단계 2. Core 로직 (TDD)

### Task 5: 모델 타입과 시간 변환

**Files:**
- Create: `Sources/WifiDoctorCore/Models/Probe.swift`, `Wireless.swift`, `System.swift`, `Path.swift`, `Outage.swift`, `Verdict.swift`
- Modify: `Sources/WifiDoctorCore/Models/Session.swift`
- Test: `Tests/WifiDoctorCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces: 아래 모든 타입. 이후 작업은 이 이름을 그대로 씁니다.

- [ ] **Step 1: 실패하는 테스트**

```swift
import Foundation
import Testing
@testable import WifiDoctorCore

@Suite struct ModelsTests {
    @Test func probeStatusLost() {
        #expect(ProbeStatus.ok.isLost == false)
        for s in [ProbeStatus.timeout, .late, .sendError, .unreachable] { #expect(s.isLost) }
        #expect(ProbeStatus.late.rawValue == 2)
    }

    @Test func bucketBoundariesIncludeLowerBound() {
        #expect(DurationBucket.of(durationMs: 200) == .b02_05)
        #expect(DurationBucket.of(durationMs: 499) == .b02_05)
        #expect(DurationBucket.of(durationMs: 500) == .b05_1)
        #expect(DurationBucket.of(durationMs: 1000) == .b1_25)
        #expect(DurationBucket.of(durationMs: 2500) == .b25_10)
        #expect(DurationBucket.of(durationMs: 10_000) == .b10plus)
        #expect(DurationBucket.b02_05.rawValue == "0.2-0.5")
    }

    @Test func wallClockFromNearestAnchorAtOrBefore() {
        let anchors = [ClockAnchor(tMono: 1_000_000_000, tWallMs: 1_700_000_000_000),
                       ClockAnchor(tMono: 11_000_000_000, tWallMs: 1_700_000_070_000)] // 60초 점프(잠자기)
        #expect(ClockAnchor.wallMs(forMono: 2_000_000_000, anchors: anchors) == 1_700_000_001_000)
        #expect(ClockAnchor.wallMs(forMono: 12_000_000_000, anchors: anchors) == 1_700_000_071_000)
        // 첫 앵커보다 앞선 시각은 첫 앵커 기준
        #expect(ClockAnchor.wallMs(forMono: 500_000_000, anchors: anchors) == 1_699_999_999_500)
        let jumps = ClockAnchor.jumps(anchors: anchors, thresholdMs: 2000)
        #expect(jumps.count == 1)
        #expect(jumps[0].jumpMs == 60_000)
    }

    @Test func wirelessSampleSnrAndState() {
        let s = WirelessSample(tMono: 1, state: .associated, rssiDbm: -60, noiseDbm: -90,
                               txRateMbps: 540, channel: 36, band: 2, widthMhz: 80,
                               bssid: "02:00:00:00:00:01", ssid: "example-ssid")
        #expect(s.snrDb == 30)
        #expect(s.isAssociated)
        #expect(WirelessLinkState.associated.rawValue == 2)
    }

    @Test func modelsRoundTripJSON() throws {
        let r = ProbeResult(targetId: 1, seq: 7, tSendMono: 100, sendDelayUs: 12, rttUs: 1500, status: .ok, ttl: 64)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ProbeResult.self, from: data)
        #expect(back == r)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ModelsTests`
Expected: FAIL. 컴파일 오류(타입 없음).

- [ ] **Step 3: 구현**

`Models/Probe.swift`:
```swift
public enum NetPath: String, Sendable, Codable, Hashable { case wifi, wired }

public enum TargetRole: String, Sendable, Codable, Hashable {
    case gateway, apMgmt = "ap_mgmt", internetA = "internet_a", internetB = "internet_b", dns
}

public enum ProbeKind: String, Sendable, Codable { case icmp, dns }

public struct ProbeTarget: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var path: NetPath
    public var role: TargetRole
    public var address: String
    public var kind: ProbeKind
    public var intervalMs: Int      // 50 | 200
    public var timeoutMs: Int       // 1000
    public var icmpIdent: UInt16?
    public var intervalNs: Int64 { Int64(intervalMs) * 1_000_000 }
    public init(id: Int, path: NetPath, role: TargetRole, address: String, kind: ProbeKind,
                intervalMs: Int, timeoutMs: Int = 1000, icmpIdent: UInt16? = nil) { ... }
}

public enum ProbeStatus: Int, Sendable, Codable {
    case ok = 0, timeout = 1, late = 2, sendError = 3, unreachable = 4
    public var isLost: Bool { self != .ok }
}

public struct ProbeResult: Sendable, Codable, Equatable {
    public var targetId: Int
    public var seq: Int64
    public var tSendMono: Int64
    public var sendDelayUs: Int64
    public var rttUs: Int64?
    public var status: ProbeStatus
    public var ttl: Int?
}
```

`Models/Wireless.swift`:
```swift
/// D1: SDK에 CWInterfaceState가 없어 앱이 정의한 값. DB wireless_sample.state에 그대로 저장.
public enum WirelessLinkState: Int, Sendable, Codable { case off = 0, disconnected = 1, associated = 2 }

public struct WirelessSample: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var state: WirelessLinkState
    public var rssiDbm: Int?        // 미참여(0)면 nil
    public var noiseDbm: Int?
    public var txRateMbps: Double?
    public var channel: Int?
    public var band: Int?           // CWChannelBand rawValue
    public var widthMhz: Int?
    public var bssid: String?       // 권한 없으면 nil
    public var ssid: String?
    public var snrDb: Int? { if let r = rssiDbm, let n = noiseDbm { return r - n }; return nil }
    public var isAssociated: Bool { state == .associated }
}

public enum LinkEventKind: String, Sendable, Codable {
    case linkDown = "link_down", linkUp = "link_up", bssidChanged = "bssid_changed",
         ssidChanged = "ssid_changed", scanCacheUpdated = "scan_cache_updated",
         powerChanged = "power_changed", linkQuality = "link_quality"
}

public struct LinkEvent: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var kind: LinkEventKind
    public var detail: String?      // JSON 문자열
}
```

`Models/System.swift`:
```swift
public enum SystemEventKind: String, Sendable, Codable {
    case awdl0State = "awdl0_state", willSleep = "will_sleep", didWake = "did_wake",
         interfaceLost = "interface_lost", interfaceBack = "interface_back",
         gatewayChanged = "gateway_changed", replyOnWrongInterface = "reply_on_wrong_interface",
         diskLow = "disk_low", probeError = "probe_error"
}

public struct SystemEvent: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var kind: SystemEventKind
    public var detail: String?
}

public struct ClockAnchor: Sendable, Codable, Equatable {
    public var tMono: Int64
    public var tWallMs: Int64

    /// anchors는 tMono 오름차순. tMono 이하에서 가장 가까운 앵커. 없으면 첫 앵커.
    public static func wallMs(forMono t: Int64, anchors: [ClockAnchor]) -> Int64 {
        let a = anchors.last(where: { $0.tMono <= t }) ?? anchors[0]
        return a.tWallMs + (t - a.tMono) / 1_000_000
    }

    public struct Jump: Sendable, Equatable { public var fromAnchor: ClockAnchor; public var toAnchor: ClockAnchor; public var jumpMs: Int64 }
    /// 인접 앵커 사이에서 (벽시계 차 − 단조 차)가 thresholdMs 이상이면 점프.
    public static func jumps(anchors: [ClockAnchor], thresholdMs: Int64) -> [Jump]
}
```

`Models/Path.swift`:
```swift
public struct Hop: Sendable, Codable, Equatable { public var index: Int; public var address: String?; public var rttMs: Double? }
public struct HopList: Sendable, Codable, Equatable { public var path: NetPath; public var run: Int; public var tMono: Int64; public var hops: [Hop] }
public enum PathTopology: Sendable, Codable, Equatable {
    case sameFirstHop, mergedLater(wifiIndex: Int, wiredIndex: Int), noMerge, unknown
}
```

`Models/Outage.swift`:
```swift
public struct TargetOutage: Sendable, Codable, Equatable {
    public var targetId: Int
    public var startMono: Int64     // 첫 손실 t_send_mono
    public var endMono: Int64       // 마지막 손실 t_send_mono + interval
    public var lostCount: Int
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var closedAtEnd: Bool    // 세션 종료로 닫힘
}

public enum DurationBucket: String, Sendable, Codable, CaseIterable {
    case b02_05 = "0.2-0.5", b05_1 = "0.5-1", b1_25 = "1-2.5", b25_10 = "2.5-10", b10plus = "10+"
    public static func of(durationMs d: Int64) -> DurationBucket {
        if d < 500 { return .b02_05 }; if d < 1000 { return .b05_1 }
        if d < 2500 { return .b1_25 }; if d < 10_000 { return .b25_10 }; return .b10plus
    }
}

public struct OutageEvent: Sendable, Codable, Equatable {
    public var id: Int
    public var startMono: Int64
    public var endMono: Int64
    public var durationMs: Int64 { (endMono - startMono) / 1_000_000 }
    public var bucket: DurationBucket { .of(durationMs: durationMs) }
    public var suppressed: Bool
    public var wiredOnly: Bool              // 5.2절 3항 사건
    public var outages: [TargetOutage]
}
```

`Models/Verdict.swift`:
```swift
public enum Segment: String, Sendable, Codable, CaseIterable {
    case wireless = "WIRELESS", wirelessUpstream = "WIRELESS_UPSTREAM", sharedFirstHop = "SHARED_FIRST_HOP",
         sharedAccess = "SHARED_ACCESS", sharedUpstream = "SHARED_UPSTREAM", internetPartial = "INTERNET_PARTIAL",
         wiredOnly = "WIRED_ONLY", hostStall = "HOST_STALL", undetermined = "UNDETERMINED"
}
public enum Confidence: String, Sendable, Codable {
    case high, medium, low
    public func lowered() -> Confidence { self == .high ? .medium : .low }
}
public enum WirelessCause: String, Sendable, Codable {
    case coverageInterference = "coverage_interference", congestionAp = "congestion_ap", roaming, disconnect
}
public struct VerdictResult: Sendable, Codable, Equatable {
    public var eventId: Int
    public var segment: Segment
    public var wirelessCause: WirelessCause?
    public var confidence: Confidence
    public var reasonCode: String?      // no_control, control_insufficient, partial_wifi_only, ... (6.3절)
    public var reason: String           // 사람이 읽는 근거
    public var evidence: String         // JSON: 대상별 상태·손실률, secondary, host_delay_partial, maxSendDelayUs
}
public enum JudgeOutcome: Sendable, Equatable {
    case suppressedBySleep              // P1
    case noLossInWindow                 // 14행. 사건을 suppressed로 표시
    case verdict(VerdictResult)
}
```

`Models/Session.swift`(추가):
```swift
public struct WirelessThresholds: Sendable, Codable, Equatable {
    public var rssiFloorDbm: Int = -75
    public var snrFloorDb: Int = 15
    public var rssiDropDb: Int = 10
    public static let `default` = WirelessThresholds()
}
public struct SessionConfig: Sendable, Codable, Equatable {
    public var wifiIf: String
    public var wiredIf: String?
    public var apMgmtIp: String?
    public var thresholds: WirelessThresholds = .default
}
public struct SessionMeta: Sendable, Codable, Equatable {   // session 테이블 1:1
    public var schemaVersion: Int, appVersion: String, osVersion: String
    public var startedWallMs: Int64, startedMonoNs: Int64, endedMonoNs: Int64?
    public var wifiIf: String, wiredIf: String?, wifiGateway: String?, wiredGateway: String?, apMgmtIp: String?
    public var locationAuth: String      // authorized | denied | notDetermined
    public var sntpStart: String?, sntpEnd: String?, notes: String?
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter ModelsTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Models Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/ModelsTests.swift
git commit -m "feat(core): add shared model types and clock anchor conversion"
```

### Task 6: SyntheticSession 생성기, SeqOrderBuffer, OutageDetector

**Files:**
- Create: `Tests/WifiDoctorCoreTests/Support/SyntheticSession.swift`
- Create: `Sources/WifiDoctorCore/Detection/SeqOrderBuffer.swift`
- Create: `Sources/WifiDoctorCore/Detection/OutageDetector.swift`
- Test: `Tests/WifiDoctorCoreTests/SeqOrderBufferTests.swift`, `Tests/WifiDoctorCoreTests/OutageDetectorTests.swift`

**Interfaces:**
- Produces:
  - `SyntheticSession.probes(target: ProbeTarget, startNs: Int64, count: Int, lostSeqs: Set<Int64>, delayedSeqs: [Int64: Int64] = [:], lateSeqs: Set<Int64> = []) -> [ProbeResult]` — `delayedSeqs[seq] = sendDelayUs`. 지연된 프로브는 `tSendMono`도 그만큼 밀립니다.
  - `SyntheticSession.samples(startNs: Int64, count: Int, rssi: (Int) -> Int, noise: Int = -90, state: WirelessLinkState = .associated) -> [WirelessSample]` (0.2초 간격)
  - `SyntheticSession.target(id:path:role:)` — 역할에 맞는 주기(gateway/apMgmt 50ms, 나머지 200ms), 주소는 RFC 5737.
  - `struct SeqOrderBuffer { mutating func push(_ r: ProbeResult) -> [ProbeResult] }` — 연속 순번만 내보냄.
  - `struct OutageDetector { init(target: ProbeTarget); mutating func feed(_ r: ProbeResult) -> TargetOutage?; mutating func finish() -> TargetOutage? }`

- [ ] **Step 1: 실패하는 테스트**

`SeqOrderBufferTests.swift`:
```swift
@Suite struct SeqOrderBufferTests {
    func r(_ seq: Int64, _ s: ProbeStatus) -> ProbeResult {
        ProbeResult(targetId: 1, seq: seq, tSendMono: seq * 50_000_000, sendDelayUs: 0, rttUs: s == .ok ? 1000 : nil, status: s, ttl: nil)
    }
    @Test func releasesInSeqOrderWhenResolvedOutOfOrder() {
        var b = SeqOrderBuffer(nextSeq: 1)
        #expect(b.push(r(1, .ok)).map(\.seq) == [1])
        #expect(b.push(r(3, .ok)).isEmpty)          // 2는 아직 시간 초과 대기
        #expect(b.push(r(4, .ok)).isEmpty)
        #expect(b.push(r(2, .timeout)).map(\.seq) == [2, 3, 4])
    }
    @Test func duplicateSeqIsDropped() {
        var b = SeqOrderBuffer(nextSeq: 1)
        _ = b.push(r(1, .ok))
        #expect(b.push(r(1, .ok)).isEmpty)
    }
}
```

`OutageDetectorTests.swift`:
```swift
@Suite struct OutageDetectorTests {
    let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)       // 50ms
    let inet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)   // 200ms

    func run(_ t: ProbeTarget, _ probes: [ProbeResult]) -> [TargetOutage] {
        var d = OutageDetector(target: t); var out: [TargetOutage] = []
        for p in probes { if let o = d.feed(p) { out.append(o) } }
        if let o = d.finish() { out.append(o) }
        return out
    }
    @Test func threeLossesAt20HzIsNotOutage() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [5, 6, 7])
        #expect(run(gw, p).isEmpty)
    }
    @Test func fourLossesAt20HzIs200msOutage() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [5, 6, 7, 8])
        let o = run(gw, p); #expect(o.count == 1)
        #expect(o[0].startMono == 5 * 50_000_000)
        #expect(o[0].endMono == 8 * 50_000_000 + 50_000_000)
        #expect(o[0].lostCount == 4); #expect(o[0].firstSeq == 5); #expect(o[0].lastSeq == 8)
        #expect(o[0].closedAtEnd == false)
    }
    @Test func oneLossAt5HzIsNotOutageTwoIs400ms() {
        #expect(run(inet, SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3])).isEmpty)
        let o = run(inet, SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3, 4]))
        #expect(o.count == 1); #expect(o[0].endMono - o[0].startMono == 400_000_000)
    }
    @Test func lateCountsAsLoss() {
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [3], lateSeqs: [4])
        #expect(run(inet, p).count == 1)
    }
    @Test func openOutageIsClosedAtFinish() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 10, lostSeqs: [6, 7, 8, 9])
        let o = run(gw, p); #expect(o.count == 1); #expect(o[0].closedAtEnd)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter 'SeqOrderBufferTests|OutageDetectorTests'`
Expected: FAIL(컴파일 오류).

- [ ] **Step 3: 구현**

`SeqOrderBuffer`: `nextSeq`, `pending: [Int64: ProbeResult]`. `push`: `seq < nextSeq` 또는 이미 있음 → 버림. 저장 후 `nextSeq`부터 연속으로 꺼내 반환.

`OutageDetector`: 상태 `runStart: ProbeResult?`, `runCount`, `lastLost: ProbeResult?`. `feed`: 손실이면 run 연장. `ok`면 run을 평가: `runCount ≥ 2 && runCount * intervalNs ≥ 200_000_000` → `TargetOutage` 반환, 아니면 nil. `finish`: 열린 run을 같은 규칙으로 평가하고 `closedAtEnd = true`.

`SyntheticSession`: 테스트 전용. `tSendMono = startNs + seq * intervalNs + delayedUs*1000`. 손실 seq는 `status = .timeout`, `rttUs = nil`. late seq는 `.late`, `rttUs = 1_200_000`.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter 'SeqOrderBufferTests|OutageDetectorTests'`
Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Detection Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests
git commit -m "feat(core): outage detector with seq ordering and synthetic fixtures"
```

### Task 7: EventGrouper

**Files:**
- Create: `Sources/WifiDoctorCore/Detection/EventGrouper.swift`
- Test: `Tests/WifiDoctorCoreTests/EventGrouperTests.swift`

**Interfaces:**
- Produces: `enum EventGrouper { static func group(outages: [TargetOutage], targets: [Int: ProbeTarget], sleepIntervals: [(start: Int64, end: Int64)], firstEventId: Int = 1) -> [OutageEvent] }`. 사건은 `startMono` 오름차순. `mergeGapNs = 500_000_000`.

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct EventGrouperTests {
    let wGw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let wInet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)
    let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
    var targets: [Int: ProbeTarget] { [1: wGw, 2: wInet, 3: eGw] }
    func o(_ id: Int, _ s: Int64, _ e: Int64) -> TargetOutage {
        TargetOutage(targetId: id, startMono: s, endMono: e, lostCount: 4, firstSeq: 0, lastSeq: 3, closedAtEnd: false)
    }
    let S: Int64 = 1_000_000_000

    @Test func wifiOutagesWithin500msMerge() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(2, S + 400_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].startMono == 0); #expect(ev[0].endMono == 2 * S)
    }
    @Test func wifiOutagesBeyond500msSplit() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(2, S + 600_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 2)
    }
    @Test func wiredOutageWithin500msAttaches() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S + 500_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].outages.count == 2); #expect(ev[0].wiredOnly == false)
    }
    @Test func wiredOutageBeyond500msBecomesWiredOnlyEvent() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S + 600_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 2); #expect(ev[1].wiredOnly)
    }
    @Test func wiredAttachDoesNotExtendSeedWindowForOtherWired() {
        // 유선 끊김이 붙어도 사건 창은 와이파이 합집합. 유선 끊김 자체는 outages에 포함.
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S, 3 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].endMono == S)
    }
    @Test func overlapWithSleepIsSuppressed() {
        let ev = EventGrouper.group(outages: [o(1, 10 * S, 11 * S)], targets: targets, sleepIntervals: [(start: 10 * S + 500_000_000, end: 20 * S)])
        #expect(ev[0].suppressed)
    }
    @Test func eventIdsAreSequentialFromFirstEventId() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(1, 5 * S, 6 * S)], targets: targets, sleepIntervals: [], firstEventId: 7)
        #expect(ev.map(\.id) == [7, 8])
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter EventGrouperTests` → FAIL(컴파일 오류).

- [ ] **Step 3: 구현 요점**

1. `targets[o.targetId].path`로 와이파이/유선을 나눕니다. 와이파이 끊김을 `startMono` 순 정렬. 현재 창과 `겹침 또는 gap ≤ 0.5초`면 합집합으로 확장. 아니면 새 사건.
2. 유선 끊김은 각 사건 창과 `겹침 또는 gap ≤ 0.5초`면 그 사건 `outages`에 추가(창은 늘리지 않음). 여러 사건에 해당하면 가장 먼저 겹치는 사건.
3. 붙지 않은 유선 끊김은 `wiredOnly = true` 사건(창 = 그 끊김).
4. `suppressed = sleepIntervals.contains { 겹침 }`.
5. 최종 정렬 `startMono`, id 부여.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter EventGrouperTests` → 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Detection/EventGrouper.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/EventGrouperTests.swift
git commit -m "feat(core): group target outages into events with 0.5s hysteresis"
```

### Task 8: WindowStatus (5.3절 창 상태)

**Files:**
- Create: `Sources/WifiDoctorCore/Detection/WindowStatus.swift`
- Test: `Tests/WifiDoctorCoreTests/WindowStatusTests.swift`

**Interfaces:**
- Produces:
```swift
public enum TargetState: String, Sendable, Codable { case up = "UP", down = "DOWN", unknown = "UNKNOWN" }
public enum GroupState: String, Sendable, Codable { case up = "UP", down = "DOWN", partial = "PARTIAL", unknown = "UNKNOWN" }
public struct WindowState: Sendable, Codable, Equatable { public var state: TargetState; public var weak: Bool; public var probeCount: Int; public var lostCount: Int }
public struct EventStatus: Sendable, Codable, Equatable {
    public var gwW: TargetState, inetW: GroupState, gwE: TargetState, inetE: GroupState, apW: TargetState?
    public var perTarget: [Int: WindowState]
    public var hasWeak: Bool
    public var controlForcedUnknown: Bool
}
public enum WindowStatus {
    public static func targetState(probes: [ProbeResult], start: Int64, end: Int64) -> WindowState
    public static func combine(_ states: [TargetState]) -> GroupState
    public static func evaluate(event: OutageEvent, probes: [ProbeResult], targets: [Int: ProbeTarget],
                                hasWired: Bool, controlForcedUnknown: Bool) -> EventStatus
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct WindowStatusTests {
    let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let inet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)

    @Test func lossRatioAtLeastHalfIsDown() {
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let w = WindowStatus.targetState(probes: p, start: 4 * 50_000_000, end: 8 * 50_000_000)
        #expect(w.state == .down); #expect(w.probeCount == 5); #expect(w.lostCount == 4); #expect(w.weak == false)
    }
    @Test func noProbesExpandsOnceBy200ms() {
        // 5Hz 대상. 창 [0.21s, 0.39s]에는 프로브 없음(0.2s, 0.4s). 넓힌 창 [0.01, 0.59]에 2개.
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [])
        let w = WindowStatus.targetState(probes: p, start: 210_000_000, end: 390_000_000)
        #expect(w.state == .up); #expect(w.probeCount == 2)
    }
    @Test func stillNoProbesIsUnknown() {
        let w = WindowStatus.targetState(probes: [], start: 0, end: 200_000_000)
        #expect(w.state == .unknown)
    }
    @Test func singleProbeIsWeak() {
        let p = SyntheticSession.probes(target: inet, startNs: 0, count: 10, lostSeqs: [2])
        let w = WindowStatus.targetState(probes: p, start: 400_000_000, end: 450_000_000)
        #expect(w.state == .down); #expect(w.weak)
    }
    @Test func groupCombination() {
        #expect(WindowStatus.combine([.down, .down, .down]) == .down)
        #expect(WindowStatus.combine([.up, .up, .up]) == .up)
        #expect(WindowStatus.combine([.unknown, .down, .down]) == .down)
        #expect(WindowStatus.combine([.up, .down, .unknown]) == .partial)
        #expect(WindowStatus.combine([.unknown, .unknown, .unknown]) == .unknown)
    }
    @Test func gatewayTargetWithoutProbesIsIgnored() {
        // 게이트웨이 변경: id 1(이전, 창에 프로브 없음), id 9(현재). GW_w는 id 9로 계산.
        let newGw = SyntheticSession.target(id: 9, path: .wifi, role: .gateway)
        let p = SyntheticSession.probes(target: newGw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let ev = OutageEvent(id: 1, startMono: 200_000_000, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
        let s = WindowStatus.evaluate(event: ev, probes: p, targets: [1: gw, 9: newGw], hasWired: false, controlForcedUnknown: false)
        #expect(s.gwW == .down)
    }
    @Test func controlForcedUnknownOverridesWiredStates() {
        let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
        let p = SyntheticSession.probes(target: eGw, startNs: 0, count: 20, lostSeqs: [4, 5, 6, 7])
        let ev = OutageEvent(id: 1, startMono: 200_000_000, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
        let s = WindowStatus.evaluate(event: ev, probes: p, targets: [3: eGw], hasWired: true, controlForcedUnknown: true)
        #expect(s.gwE == .unknown); #expect(s.inetE == .unknown); #expect(s.controlForcedUnknown)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WindowStatusTests` → FAIL.

- [ ] **Step 3: 구현 요점**

- `targetState`: `[start, end]`에 `tSendMono`가 있는 프로브. 0개면 `[start − 0.2초, end + 0.2초]`로 한 번. 그래도 0개 → `unknown`. `lost/count ≥ 0.5` → `down`, 아니면 `up`. `weak = count < 2`.
- `evaluate`: 대상별 `WindowState`. 역할별로 `up/down`인 대상 중 프로브가 있는 대상만 모읍니다. 같은 역할 대상이 여럿이면 `probeCount > 0`인 것만 씁니다. `GW` = 그 경로 gateway 대상 상태(없으면 `unknown`). `INET` = `combine([internet_a, internet_b, dns])`. `apW` = apMgmt 대상이 있을 때만. `hasWeak` = 판정에 쓰인 대상(up/down) 중 weak 있음. `controlForcedUnknown`이면 `gwE = .unknown`, `inetE = .unknown`. `hasWired == false`면 유선 측은 모두 `unknown`.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WindowStatusTests` → 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Detection/WindowStatus.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/WindowStatusTests.swift
git commit -m "feat(core): per-target window state and group combination"
```

### Task 9: PathCorrelator

**Files:**
- Create: `Sources/WifiDoctorCore/Verdict/PathCorrelator.swift`
- Test: `Tests/WifiDoctorCoreTests/PathCorrelatorTests.swift`

**Interfaces:**
- Produces: `enum PathCorrelator { static func topology(wifi: HopList?, wired: HopList?) -> PathTopology }`

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct PathCorrelatorTests {
    func hl(_ path: NetPath, _ addrs: [String?]) -> HopList {
        HopList(path: path, run: 0, tMono: 0, hops: addrs.enumerated().map { Hop(index: $0.offset + 1, address: $0.element, rttMs: 1) })
    }
    @Test func sameFirstHop() {
        let t = PathCorrelator.topology(wifi: hl(.wifi, ["192.0.2.1", "198.51.100.1"]), wired: hl(.wired, ["192.0.2.1", "198.51.100.1"]))
        #expect(t == .sameFirstHop)
    }
    @Test func mergedLaterReturnsBothIndices() {
        let t = PathCorrelator.topology(wifi: hl(.wifi, ["192.0.2.1", "192.0.2.254", "203.0.113.1"]),
                                        wired: hl(.wired, ["198.51.100.1", "203.0.113.1"]))
        #expect(t == .mergedLater(wifiIndex: 3, wiredIndex: 2))
    }
    @Test func noMerge() {
        let t = PathCorrelator.topology(wifi: hl(.wifi, ["192.0.2.1", "192.0.2.2"]), wired: hl(.wired, ["198.51.100.1", "198.51.100.2"]))
        #expect(t == .noMerge)
    }
    @Test func nilHopsAreSkipped() {
        let t = PathCorrelator.topology(wifi: hl(.wifi, [nil, "203.0.113.1"]), wired: hl(.wired, ["198.51.100.1", nil, "203.0.113.1"]))
        #expect(t == .mergedLater(wifiIndex: 2, wiredIndex: 3))
    }
    @Test func emptyOrMissingIsUnknown() {
        #expect(PathCorrelator.topology(wifi: hl(.wifi, []), wired: hl(.wired, ["192.0.2.1"])) == .unknown)
        #expect(PathCorrelator.topology(wifi: nil, wired: hl(.wired, ["192.0.2.1"])) == .unknown)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter PathCorrelatorTests` → FAIL.

- [ ] **Step 3: 구현** — 6.2절 의사코드를 그대로 옮깁니다. 첫 홉 비교는 `wifi.hops[0].address != nil` 조건 포함.

- [ ] **Step 4: 통과 확인** — `swift test --filter PathCorrelatorTests` → 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Verdict/PathCorrelator.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/PathCorrelatorTests.swift
git commit -m "feat(core): derive shared-path topology from two hop lists"
```

### Task 10: HostStallCheck (6.3.3절)

**Files:**
- Create: `Sources/WifiDoctorCore/Verdict/HostStallCheck.swift`
- Test: `Tests/WifiDoctorCoreTests/HostStallCheckTests.swift`

**Interfaces:**
- Produces:
```swift
public struct HostStallResult: Sendable, Codable, Equatable {
    public var allTargetsDelayed: Bool
    public var someTargetsDelayed: Bool
    public var maxSendDelayUsByTarget: [Int: Int64]
    public var targetsInWindow: Int
}
public enum HostStallCheck {
    /// 창 [start − 0.5초, end]. 창 소속은 예정 송신 시각(tSendMono − sendDelayUs × 1000)으로 봄(R9). 지연 = sendDelayUs ≥ intervalMs × 1000.
    public static func evaluate(event: OutageEvent, probes: [ProbeResult], targets: [Int: ProbeTarget]) -> HostStallResult
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct HostStallCheckTests {
    let wGw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
    var targets: [Int: ProbeTarget] { [1: wGw, 3: eGw] }
    let ev = OutageEvent(id: 1, startMono: 1_000_000_000, endMono: 1_400_000_000, suppressed: false, wiredOnly: false, outages: [])

    @Test func allTargetsDelayedIsStall() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [20: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [21: 55_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed); #expect(r.targetsInWindow == 2)
    }
    @Test func onlyWifiDelayedIsPartial() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [20: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed)
        #expect(r.maxSendDelayUsByTarget[1] == 60_000)
    }
    @Test func noDelayIsNotStall() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed == false)
    }
    @Test func delayOutsideWindowIsIgnored() {
        // 지연 프로브가 start − 0.6초(seq 8, t=0.4s)에만 있음
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [20, 21, 22, 23], delayedSeqs: [8: 60_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [8: 60_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed == false); #expect(r.someTargetsDelayed == false)
    }
    @Test func delayedProbeIsCountedByScheduledTime() {   // R9
        // seq 28은 1.4초 예정, 2초 밀려 3.4초에 송신. 창 [0.5, 1.4]에 예정 시각으로 포함.
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [24, 25, 26, 27], delayedSeqs: [28: 2_000_000])
        let e = SyntheticSession.probes(target: eGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [28: 2_000_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w + e, targets: targets)
        #expect(r.allTargetsDelayed)
    }
    @Test func delayBelowIntervalIsNotDelayed() {
        let w = SyntheticSession.probes(target: wGw, startNs: 0, count: 40, lostSeqs: [], delayedSeqs: [20: 49_000])
        let r = HostStallCheck.evaluate(event: ev, probes: w, targets: [1: wGw])
        #expect(r.someTargetsDelayed == false)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter HostStallCheckTests` → FAIL.

- [ ] **Step 3: 구현 요점** — 창 `[start − 500_000_000, end]`에 예정 송신 시각(`tSendMono − sendDelayUs * 1000`)이 들어가는 프로브를 대상별로 모읍니다. 대상별 `max(sendDelayUs)`. 지연 대상 = `max ≥ intervalMs * 1000`. `targetsInWindow > 0 && 모든 대상 지연` → `allTargetsDelayed`. `someTargetsDelayed = 지연 대상 ≥ 1 && !all`.

- [ ] **Step 4: 통과 확인** — 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Verdict/HostStallCheck.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/HostStallCheckTests.swift
git commit -m "feat(core): host stall check from send delays"
```

### Task 11: Verdict 결정표

**Files:**
- Create: `Sources/WifiDoctorCore/Verdict/Verdict.swift`
- Test: `Tests/WifiDoctorCoreTests/VerdictTests.swift`

**Interfaces:**
- Consumes: `EventStatus`, `HostStallResult`, `PathTopology`, `SessionConfig`, `WirelessClassifier.classify`(작업 12. 이 작업에서는 주입 가능한 클로저로 받습니다).
- Produces:
```swift
public enum Verdict {
    public static func judge(event: OutageEvent, status: EventStatus, stall: HostStallResult,
                             topology: PathTopology, config: SessionConfig,
                             classify: (OutageEvent) -> WirelessCause?) -> JudgeOutcome
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct VerdictTests {
    let ev = OutageEvent(id: 1, startMono: 0, endMono: 400_000_000, suppressed: false, wiredOnly: false, outages: [])
    let cfg = SessionConfig(wifiIf: "en0", wiredIf: "en11", apMgmtIp: nil)
    let noStall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: false, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
    func st(_ gwW: TargetState, _ inetW: GroupState, _ gwE: TargetState, _ inetE: GroupState, weak: Bool = false, ap: TargetState? = nil) -> EventStatus {
        EventStatus(gwW: gwW, inetW: inetW, gwE: gwE, inetE: inetE, apW: ap, perTarget: [:], hasWeak: weak, controlForcedUnknown: false)
    }
    func judge(_ s: EventStatus, topo: PathTopology = .sameFirstHop, stall: HostStallResult? = nil, cfg: SessionConfig? = nil, cause: WirelessCause? = .congestionAp) -> VerdictResult? {
        if case .verdict(let v) = Verdict.judge(event: ev, status: s, stall: stall ?? noStall, topology: topo, config: cfg ?? self.cfg, classify: { _ in cause }) { return v }
        return nil
    }

    // 전제 검사
    @Test func p1SleepBeforeHostStall() {
        var e = ev; e.suppressed = true
        let stall = HostStallResult(allTargetsDelayed: true, someTargetsDelayed: false, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
        #expect(Verdict.judge(event: e, status: st(.down, .down, .down, .down), stall: stall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .suppressedBySleep)
    }
    @Test func p2HostStall() {
        let stall = HostStallResult(allTargetsDelayed: true, someTargetsDelayed: false, maxSendDelayUsByTarget: [1: 90_000], targetsInWindow: 2)
        let v = judge(st(.down, .down, .down, .down), stall: stall)
        #expect(v?.segment == .hostStall)
    }
    @Test func p3NoControlWhenWiredMissing() {
        let v = judge(st(.down, .up, .unknown, .unknown), cfg: SessionConfig(wifiIf: "en0", wiredIf: nil, apMgmtIp: nil))
        #expect(v?.segment == .undetermined); #expect(v?.reasonCode == "no_control")
        #expect(v?.reason.contains("유선 대조군이 없어") == true)   // 6.3.1 보조 설명
    }
    @Test func p3NoControlWhenBothWiredUnknown() {
        let v = judge(st(.up, .down, .unknown, .unknown))
        #expect(v?.reasonCode == "no_control"); #expect(v?.reason.contains("게이트웨이 이후") == true)
    }
    @Test func controlForcedUnknownBeatsP3() {   // R5
        var s = st(.down, .up, .unknown, .unknown); s.controlForcedUnknown = true
        #expect(judge(s)?.reasonCode == "control_insufficient")
    }
    @Test func p4NoWifiSamples() {
        #expect(judge(st(.unknown, .unknown, .up, .up))?.reasonCode == "no_wifi_samples")
    }

    // 결정표 17행. (GW_w, INET_w, GW_e, INET_e, topo, segment, confidence, reasonCode)
    @Test(arguments: [
        (TargetState.down, GroupState.up, TargetState.up, GroupState.up, PathTopology.sameFirstHop, Segment.wireless, Confidence.high, nil as String?),            // 1
        (.down, .up, .up, .down, .sameFirstHop, .wireless, .medium, nil),                        // 2
        (.down, .down, .down, .down, .sameFirstHop, .sharedFirstHop, .high, nil),                // 3
        (.down, .down, .down, .down, .mergedLater(wifiIndex: 3, wiredIndex: 2), .sharedAccess, .low, nil), // 4
        (.down, .down, .down, .down, .noMerge, .undetermined, .low, "both_gateways_down_no_topology"),     // 5
        (.down, .down, .down, .down, .unknown, .undetermined, .low, "both_gateways_down_no_topology"),     // 5
        (.down, .down, .unknown, .up, .sameFirstHop, .undetermined, .low, "control_insufficient"),          // 6
        (.up, .down, .up, .up, .sameFirstHop, .wirelessUpstream, .medium, nil),                  // 7
        (.up, .down, .up, .down, .sameFirstHop, .sharedUpstream, .high, nil),                    // 8
        (.up, .down, .up, .partial, .sameFirstHop, .internetPartial, .medium, nil),              // 9
        (.up, .partial, .up, .partial, .sameFirstHop, .internetPartial, .high, nil),             // 10
        (.up, .partial, .up, .up, .sameFirstHop, .wirelessUpstream, .low, "partial_wifi_only"), // 11
        (.up, .down, .down, .down, .sameFirstHop, .sharedUpstream, .low, "control_gateway_down"), // 12 (R4)
        (.up, .down, .up, .unknown, .sameFirstHop, .undetermined, .low, "control_insufficient"), // 13
        (.unknown, .down, .up, .up, .sameFirstHop, .wireless, .low, "gateway_unknown"),          // 15
        (.unknown, .down, .up, .down, .sameFirstHop, .sharedUpstream, .medium, nil),             // 16
        (.unknown, .up, .up, .up, .sameFirstHop, .undetermined, .low, "unmatched"),              // 17
    ])
    func decisionTable(row: (TargetState, GroupState, TargetState, GroupState, PathTopology, Segment, Confidence, String?)) {
        let (gwW, inetW, gwE, inetE, topo, seg, conf, code) = row
        let v = judge(st(gwW, inetW, gwE, inetE), topo: topo)
        #expect(v?.segment == seg); #expect(v?.confidence == conf); #expect(v?.reasonCode == code)
    }
    @Test func row14NoLossInWindow() {
        #expect(Verdict.judge(event: ev, status: st(.up, .up, .up, .up), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) == .noLossInWindow)
    }
    @Test func row2RecordsConcurrentUpstreamLoss() {
        #expect(judge(st(.down, .up, .up, .down))?.reason.contains("유선 경로의 인터넷 손실도 관측됨") == true)
    }
    @Test func row12RecordsSecondaryWiredOnly() {
        #expect(judge(st(.up, .down, .down, .down))?.evidence.contains("\"secondary\":\"WIRED_ONLY\"") == true)
    }
    @Test func row4ReasonMentionsMergeHop() {
        #expect(judge(st(.down, .down, .down, .down), topo: .mergedLater(wifiIndex: 3, wiredIndex: 2))?.reason.contains("홉 3") == true)
    }
    @Test func wirelessRowsCallClassifier() {
        #expect(judge(st(.down, .up, .up, .up), cause: .roaming)?.wirelessCause == .roaming)
        #expect(judge(st(.up, .down, .up, .up), cause: .roaming)?.wirelessCause == nil)   // 7행은 세분 안 함
    }
    @Test func weakLowersConfidence() {
        #expect(judge(st(.down, .up, .up, .up, weak: true))?.confidence == .medium)
    }
    @Test func partialHostDelayLowersConfidenceAndMarksEvidence() {
        let stall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: true, maxSendDelayUsByTarget: [1: 70_000], targetsInWindow: 2)
        let v = judge(st(.down, .up, .up, .up), stall: stall)
        #expect(v?.confidence == .medium); #expect(v?.evidence.contains("\"host_delay_partial\":true") == true)
    }
    @Test func weakAndPartialDelayLowerTwice() {
        let stall = HostStallResult(allTargetsDelayed: false, someTargetsDelayed: true, maxSendDelayUsByTarget: [:], targetsInWindow: 2)
        #expect(judge(st(.down, .up, .up, .up, weak: true), stall: stall)?.confidence == .low)
    }
    @Test func apNoteWhenConfigured() {
        let c = SessionConfig(wifiIf: "en0", wiredIf: "en11", apMgmtIp: "192.0.2.10")
        #expect(judge(st(.down, .up, .up, .up, ap: .up), cfg: c)?.reason.contains("AP는 응답함") == true)
        #expect(judge(st(.down, .up, .up, .up, ap: .down), cfg: c)?.reason.contains("AP 자체 또는") == true)
    }
    @Test func wiredOnlyEventSkipsTable() {
        var e = ev; e.wiredOnly = true
        if case .verdict(let v) = Verdict.judge(event: e, status: st(.up, .up, .down, .down), stall: noStall, topology: .sameFirstHop, config: cfg, classify: { _ in nil }) {
            #expect(v.segment == .wiredOnly); #expect(v.confidence == .high)
        } else { Issue.record("expected verdict") }
    }
    // 6.5절 가정용 표 4행은 결정표 1, 3, 8, 10행 케이스와 같음(위 arguments에 포함).
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter VerdictTests` → FAIL.

- [ ] **Step 3: 구현 요점**

1. 순서: `event.wiredOnly` → `WIRED_ONLY/high` 즉시 반환. `suppressed` → `.suppressedBySleep`. `stall.allTargetsDelayed` → `HOST_STALL/high`(evidence에 `maxSendDelayUsByTarget`). `status.controlForcedUnknown` → `UNDETERMINED/control_insufficient`. P3: `config.wiredIf == nil || (gwE == .unknown && inetE == .unknown)` → `UNDETERMINED/no_control` + 6.3.1 보조 문장(`gwW == .down` → "무선 구간 또는 게이트웨이 자체. 유선 대조군이 없어 구분 불가", `gwW == .up && inetW == .down` → "게이트웨이 이후. 상위 장비 또는 ISP/인터넷. 유선 대조군이 없어 무선 VLAN 전용 경로 가능성 배제 불가", `gwW == .up && inetW == .partial` → "특정 인터넷 대상 문제 가능성"). P4: `gwW == .unknown && inetW == .unknown` → `no_wifi_samples`.
2. 결정표를 `[Row]` 배열로 둡니다. `Row { gwW: TargetState?, inetW: GroupState?, gwE: TargetState?, inetE: GroupState?, topo: (PathTopology) -> Bool, segment, confidence, reasonCode, classify: Bool }`. `nil` = `*`. 첫 일치. 14행은 `.noLossInWindow` 반환. 17행은 기본값(`unmatched`, evidence에 상태 덤프).
3. 신뢰도 하향: `hasWeak`이면 한 단계, `someTargetsDelayed`이면 한 단계(각각 독립. 둘 다면 두 단계).
4. `classify`는 1, 2, 15행에서만 호출.
5. AP 문구는 `config.apMgmtIp != nil && segment == .wireless && status.apW != nil`일 때 `reason` 끝에 추가.
6. `evidence`는 `JSONEncoder`(`sortedKeys`)로 `EvidencePayload { perTarget, gwW, inetW, gwE, inetE, apW, topology: String, secondary: String?, hostDelayPartial: Bool, maxSendDelayUsByTarget }`를 인코딩합니다. 키 이름은 snake_case(`keyEncodingStrategy = .convertToSnakeCase`). 테스트의 `"secondary":"WIRED_ONLY"`와 `"host_delay_partial":true` 문자열이 포함되도록 `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`만 쓰고 `prettyPrinted`는 쓰지 않습니다.
7. 4행 reason은 6.3.2 문구를 쓰고 `홉 N`에 `wifiIndex`를 넣습니다. 반복 횟수는 ReportModelBuilder(작업 16)가 셉니다.

- [ ] **Step 4: 통과 확인** — `swift test --filter VerdictTests` → 모두 PASS(인자 케이스 17 포함).

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Verdict/Verdict.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/VerdictTests.swift
git commit -m "feat(core): decision table verdict with preconditions"
```

### Task 12: WirelessClassifier (6.4절)

**Files:**
- Create: `Sources/WifiDoctorCore/Verdict/WirelessClassifier.swift`
- Test: `Tests/WifiDoctorCoreTests/WirelessClassifierTests.swift`

**Interfaces:**
- Produces:
```swift
public struct WirelessClassification: Sendable, Equatable { public var cause: WirelessCause?; public var note: String; public var baselineRssi: Int?; public var minRssi: Int?; public var minSnr: Int? }
public enum WirelessClassifier {
    /// window = [start − 3초, end]. baseline = [start − 60초, start − 3초).
    public static func classify(start: Int64, end: Int64, samples: [WirelessSample], events: [LinkEvent], thresholds: WirelessThresholds) -> WirelessClassification
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct WirelessClassifierTests {
    let S: Int64 = 1_000_000_000
    let th = WirelessThresholds.default
    // 기준선 60초(−60dBm) + 창 3초. 사건 start = 70초.
    func base(_ rssi: Int = -60) -> [WirelessSample] { SyntheticSession.samples(startNs: 10 * S, count: 300, rssi: { _ in rssi }) }
    func win(_ rssi: @escaping (Int) -> Int, state: WirelessLinkState = .associated) -> [WirelessSample] { SyntheticSession.samples(startNs: 67 * S, count: 20, rssi: rssi, state: state) }

    @Test func linkDownIsDisconnect() {
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -60 }),
                                            events: [LinkEvent(tMono: 69 * S, kind: .linkDown, detail: nil), LinkEvent(tMono: 69 * S, kind: .bssidChanged, detail: nil)], thresholds: th)
        #expect(c.cause == .disconnect)
    }
    @Test func notAssociatedSampleIsDisconnect() {
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -60 }, state: .disconnected), events: [], thresholds: th)
        #expect(c.cause == .disconnect)
    }
    @Test func bssidChangeIsRoaming() {
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -60 }),
                                            events: [LinkEvent(tMono: 70 * S, kind: .bssidChanged, detail: nil)], thresholds: th)
        #expect(c.cause == .roaming)
    }
    @Test func lowRssiIsCoverage() {
        #expect(WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -76 }), events: [], thresholds: th).cause == .coverageInterference)
    }
    @Test func lowSnrIsCoverage() {
        // noise −90 기본. RSSI −75는 임계 이하이므로 SNR만 보려면 RSSI −60, 노이즈 −74
        let w = SyntheticSession.samples(startNs: 67 * S, count: 20, rssi: { _ in -60 }, noise: -74)
        #expect(WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + w, events: [], thresholds: th).cause == .coverageInterference)
    }
    @Test func dropFromBaselineIsCoverage() {
        // 기준선 −50, 창 −61: 절대값은 양호, 하락 11dB
        #expect(WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base(-50) + win({ _ in -61 }), events: [], thresholds: th).cause == .coverageInterference)
    }
    @Test func goodSignalIsCongestion() {
        #expect(WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -60 }), events: [], thresholds: th).cause == .congestionAp)
    }
    @Test func noSamplesInWindowIsNil() {
        let early = SyntheticSession.samples(startNs: 10 * S, count: 280, rssi: { _ in -60 })   // 10초~65.8초. 창(67초~)에 없음
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: early, events: [], thresholds: th)
        #expect(c.cause == nil); #expect(c.note.contains("무선 샘플 없음"))
    }
    @Test func noBaselineSkipsDropRule() {
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: win({ _ in -61 }), events: [], thresholds: th)
        #expect(c.cause == .congestionAp); #expect(c.baselineRssi == nil)
    }
    @Test func eventsBeforeWindowAreIgnored() {
        let c = WirelessClassifier.classify(start: 70 * S, end: 71 * S, samples: base() + win({ _ in -60 }),
                                            events: [LinkEvent(tMono: 66 * S, kind: .bssidChanged, detail: nil)], thresholds: th)
        #expect(c.cause == .congestionAp)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter WirelessClassifierTests` → FAIL.

- [ ] **Step 3: 구현 요점** — 창 `[start − 3_000_000_000, end]`, 기준선 `[start − 60_000_000_000, start − 3_000_000_000)`. 중앙값은 정렬 후 가운데(짝수면 아래쪽). RSSI/SNR이 nil인 샘플은 수치 계산에서 제외하되 `isAssociated == false`는 1행 조건에 셉니다. 우선순위 1→4 첫 일치. `note`에 수치를 적습니다(예: "창 최소 RSSI −76 dBm, 기준선 −60 dBm").

- [ ] **Step 4: 통과 확인** — 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Verdict/WirelessClassifier.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/WirelessClassifierTests.swift
git commit -m "feat(core): classify wireless cause for WIRELESS verdicts"
```

### Task 13: SessionStore — 스키마, 세션/대상/프로브 쓰기와 읽기

**Files:**
- Create: `Sources/WifiDoctorCore/Store/SQLite.swift` (얇은 래퍼)
- Create: `Sources/WifiDoctorCore/Store/SessionStore.swift` (스키마, 생성/열기)
- Create: `Sources/WifiDoctorCore/Store/SessionReader.swift`
- Test: `Tests/WifiDoctorCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces:
```swift
/// sqlite3 C API 래퍼. 연결 하나. 스레드 안전하지 않음(호출자가 액터로 보호).
final class SQLiteConnection { init(path: String) throws; func exec(_ sql: String) throws; func prepare(_ sql: String) throws -> SQLiteStatement; func lastInsertRowId() -> Int64 }
final class SQLiteStatement { func bind(_ idx: Int32, _ v: Int64?); func bind(_ idx: Int32, _ v: Double?); func bind(_ idx: Int32, _ v: String?); func step() throws -> Bool; func reset(); func int64(_ col: Int32) -> Int64?; func double(_ col: Int32) -> Double?; func text(_ col: Int32) -> String? }

public struct SessionStore {
    public static let schemaSQL: String                       // 4.2절 그대로. wireless_sample.state 주석만 D1로 변경
    public static func create(path: String, meta: SessionMeta) throws -> SessionWriter   // 파일 생성, PRAGMA, 스키마, session 행
    public static func openReader(path: String) throws -> SessionReader
}
public final class SessionReader: Sendable {   // 읽기 전용 연결. 메서드는 모두 throws
    func meta() throws -> SessionMeta
    func targets() throws -> [ProbeTarget]
    func probes(targetId: Int, fromMono: Int64, toMono: Int64) throws -> [ProbeResult]
    func probeStats() throws -> ProbeStats          // count, lateCount, sendDelayP50/P99/Max(us)
    func forEachProbe(_ body: (ProbeResult) throws -> Void) throws
    func wirelessSamples(fromMono: Int64, toMono: Int64) throws -> [WirelessSample]
    func linkEvents() throws -> [LinkEvent]; func systemEvents() throws -> [SystemEvent]; func anchors() throws -> [ClockAnchor]
    func hops() throws -> [HopList]; func outages() throws -> [TargetOutage]; func events() throws -> [OutageEvent]; func verdicts() throws -> [VerdictResult]
    func rowCount(table: String) throws -> Int64
}
public struct ProbeStats: Sendable, Equatable { public var count: Int64; public var lateCount: Int64; public var sendDelayP50Us: Int64; public var sendDelayP99Us: Int64; public var sendDelayMaxUs: Int64 }
```
- 작업 14가 `SessionWriter`를 정의합니다. 이 작업에서는 `create`가 돌려주는 최소 `SessionWriter`(`insertTarget`, `write(probes:)` 동기 메서드)를 만들고 작업 14에서 액터로 확장합니다.

- [ ] **Step 1: 실패하는 테스트**

```swift
import Foundation
import Testing
@testable import WifiDoctorCore

func tempDBPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString).sqlite").path
}
func sampleMeta() -> SessionMeta {
    SessionMeta(schemaVersion: 1, appVersion: "0.1", osVersion: "27.0.1", startedWallMs: 1_700_000_000_000, startedMonoNs: 1_000,
                endedMonoNs: nil, wifiIf: "en0", wiredIf: "en11", wifiGateway: "192.0.2.1", wiredGateway: "198.51.100.1",
                apMgmtIp: nil, locationAuth: "denied", sntpStart: "+0.001 +/- 0.006 time.apple.com", sntpEnd: nil, notes: nil)
}

@Suite struct SessionStoreTests {
    @Test func createWritesPragmasAndSessionRow() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try SessionStore.create(path: path, meta: sampleMeta())
        let r = try SessionStore.openReader(path: path)
        #expect(try r.meta() == sampleMeta())
        #expect(try r.pragmaUserVersion() == 1)
        #expect(try r.pragmaJournalMode() == "wal")
    }
    @Test func targetsAndProbesRoundTrip() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway)
        gw.id = try w.insertTarget(gw)
        let probes = SyntheticSession.probes(target: gw, startNs: 0, count: 100, lostSeqs: [10, 11], lateSeqs: [12])
        try w.write(probes: probes)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.targets() == [gw])
        let got = try r.probes(targetId: gw.id, fromMono: 0, toMono: 99 * 50_000_000)
        #expect(got == probes)
        let s = try r.probeStats()
        #expect(s.count == 100); #expect(s.lateCount == 1)
        #expect(try r.rowCount(table: "probe") == 100)
    }
    @Test func duplicatePrimaryKeyIsRejected() throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try w.insertTarget(gw)
        let p = SyntheticSession.probes(target: gw, startNs: 0, count: 1, lostSeqs: [])
        try w.write(probes: p)
        #expect(throws: (any Error).self) { try w.write(probes: p) }
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter SessionStoreTests` → FAIL.

- [ ] **Step 3: 구현 요점**

- `import SQLite3`. `sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)`. 문자열 바인딩은 `SQLITE_TRANSIENT`(`unsafeBitCast(-1, to: sqlite3_destructor_type.self)`).
- `create`: `PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA user_version = 1;` 뒤에 4.2절 `CREATE TABLE` 11개. `session` 행 `id = 1` 삽입.
- `probe` 삽입 prepared statement는 재사용. `write(probes:)`는 `BEGIN`~`COMMIT` 한 트랜잭션. 실패 시 `ROLLBACK` 후 throw.
- `probeStats`: `SELECT COUNT(*), SUM(status = 2), MAX(send_delay_us) FROM probe`. p50/p99는 `SELECT send_delay_us FROM probe ORDER BY send_delay_us LIMIT 1 OFFSET ?`(OFFSET = `count * 0.5`, `count * 0.99`, 내림).
- `SessionReader`에 테스트용 `pragmaUserVersion()`, `pragmaJournalMode()`.
- `events()`는 `event` 행과 그 `outage` 행을 합쳐 `OutageEvent`를 만듭니다(`wiredOnly`는 `outages`의 대상 경로가 모두 `wired`일 때 true. 대상 경로는 `targets()`로 조회).

- [ ] **Step 4: 통과 확인** — 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Store Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/SessionStoreTests.swift
git commit -m "feat(core): SQLite session store schema, probe write and read"
```

### Task 14: SessionWriter 액터 — 배치 큐, 나머지 테이블, 앵커, 세션 종료

**Files:**
- Create: `Sources/WifiDoctorCore/Store/SessionWriter.swift` (작업 13의 임시 구조체를 액터로 대체)
- Modify: `Sources/WifiDoctorCore/Store/SessionStore.swift`
- Test: `Tests/WifiDoctorCoreTests/SessionWriterTests.swift`

**Interfaces:**
- Produces:
```swift
public actor SessionWriter {
    public func insertTarget(_ t: ProbeTarget) throws -> Int             // 새 id
    public func enqueue(_ p: ProbeResult); public func enqueue(_ s: WirelessSample); public func enqueue(_ e: LinkEvent); public func enqueue(_ e: SystemEvent)
    public func enqueue(_ a: ClockAnchor)
    public func flush() throws -> Int                                     // 한 트랜잭션. 쓴 행 수. 3회 재시도 후 throw
    public func writeHops(_ h: HopList) throws
    public func writeEvent(_ e: OutageEvent, verdict: VerdictResult?) throws   // event + outage(event_id) + verdict
    public func updateEventSuppressed(id: Int, suppressed: Bool) throws
    public func finishSession(endedMonoNs: Int64, sntpEnd: String?, notes: String?) throws  // session UPDATE + wal_checkpoint(TRUNCATE)
    public var pendingCount: Int { get }
}
```
- 작업 13의 `write(probes:)`는 `enqueue` + `flush()`로 대체합니다. 작업 13 테스트를 그에 맞춰 고칩니다.

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct SessionWriterTests {
    @Test func flushWritesOneTransactionPreservingOrder() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        var inet = SyntheticSession.target(id: 0, path: .wifi, role: .internetA); inet.id = try await w.insertTarget(inet)
        let a = SyntheticSession.probes(target: gw, startNs: 0, count: 20, lostSeqs: [])
        let b = SyntheticSession.probes(target: inet, startNs: 0, count: 5, lostSeqs: [])
        for p in zip(a, b).flatMap({ [$0.0, $0.1] }) { await w.enqueue(p) }
        for p in a.dropFirst(5) { await w.enqueue(p) }
        #expect(await w.pendingCount == 25)
        #expect(try await w.flush() == 25)
        #expect(await w.pendingCount == 0)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.probes(targetId: gw.id, fromMono: 0, toMono: .max).map(\.seq) == Array(0..<20))
    }
    @Test func allRowTypesRoundTrip() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        let s = WirelessSample(tMono: 5, state: .associated, rssiDbm: -60, noiseDbm: -90, txRateMbps: 540, channel: 36, band: 2, widthMhz: 80, bssid: nil, ssid: nil)
        await w.enqueue(s)
        await w.enqueue(LinkEvent(tMono: 6, kind: .bssidChanged, detail: "{\"rssi\":-70}"))
        await w.enqueue(SystemEvent(tMono: 7, kind: .awdl0State, detail: "up,running"))
        await w.enqueue(ClockAnchor(tMono: 8, tWallMs: 1_700_000_000_008))
        _ = try await w.flush()
        try await w.writeHops(HopList(path: .wifi, run: 0, tMono: 9, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1.2), Hop(index: 2, address: nil, rttMs: nil)]))
        let ev = OutageEvent(id: 1, startMono: 100, endMono: 400_000_100, suppressed: false, wiredOnly: false,
                             outages: [TargetOutage(targetId: 1, startMono: 100, endMono: 400_000_100, lostCount: 8, firstSeq: 2, lastSeq: 9, closedAtEnd: false)])
        let v = VerdictResult(eventId: 1, segment: .wireless, wirelessCause: .roaming, confidence: .high, reasonCode: nil, reason: "r", evidence: "{}")
        try await w.writeEvent(ev, verdict: v)
        try await w.finishSession(endedMonoNs: 999, sntpEnd: "unavailable", notes: nil)
        let r = try SessionStore.openReader(path: path)
        #expect(try r.wirelessSamples(fromMono: 0, toMono: 10) == [s])
        #expect(try r.linkEvents().count == 1); #expect(try r.systemEvents().count == 1); #expect(try r.anchors().count == 1)
        #expect(try r.hops()[0].hops[1].address == nil)
        #expect(try r.outages()[0].lostCount == 8)
        #expect(try r.verdicts() == [v])
        #expect(try r.meta().endedMonoNs == 999); #expect(try r.meta().sntpEnd == "unavailable")
        #expect(try r.events()[0].bucket == .b02_05)
    }
    @Test func suppressedUpdate() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        try await w.writeEvent(OutageEvent(id: 3, startMono: 0, endMono: 300_000_000, suppressed: false, wiredOnly: false, outages: []), verdict: nil)
        try await w.updateEventSuppressed(id: 3, suppressed: true)
        #expect(try SessionStore.openReader(path: path).events()[0].suppressed)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter SessionWriterTests` → FAIL.

- [ ] **Step 3: 구현 요점**

- 큐 5개(probe, sample, linkEvent, systemEvent, anchor). `flush`는 `BEGIN` → 큐 순서대로 prepared statement 실행 → `COMMIT`. 오류 시 `ROLLBACK`, 큐 유지, 최대 3회 시도 후 throw(호출자가 `probe_error`를 기록하고 녹화를 멈춤).
- `writeEvent`: `event` INSERT(id 명시) → 각 outage INSERT(`event_id`) → verdict INSERT(있을 때). 한 트랜잭션.
- `finishSession`: `UPDATE session SET ended_mono_ns=?, sntp_end=?, notes=?`; `PRAGMA wal_checkpoint(TRUNCATE)`.
- 디스크 부족: `SQLITE_FULL`은 재시도하지 않고 즉시 throw(`SessionStoreError.diskFull`).

- [ ] **Step 4: 통과 확인** — `swift test --filter 'SessionStoreTests|SessionWriterTests'` → 모두 PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Store Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests
git commit -m "feat(core): batching session writer actor and remaining tables"
```

### Task 15: CSVExporter

**Files:**
- Create: `Sources/WifiDoctorCore/Export/CSVExporter.swift`
- Test: `Tests/WifiDoctorCoreTests/CSVExporterTests.swift`

**Interfaces:**
- Produces:
```swift
public struct CSVFileInfo: Sendable, Equatable { public var name: String; public var rows: Int }
public enum CSVExporter {
    /// 8개 파일. 각 행에 t_mono와 t_wall_ms(앵커 변환) 둘 다 기록.
    public static func export(reader: SessionReader, to dir: URL) throws -> [CSVFileInfo]
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct CSVExporterTests {
    @Test func writesEightFilesWithMonoAndWallColumns() async throws {
        let path = tempDBPath(); defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        for p in SyntheticSession.probes(target: gw, startNs: 1_000, count: 10, lostSeqs: []) { await w.enqueue(p) }
        await w.enqueue(ClockAnchor(tMono: 1_000, tWallMs: 1_700_000_000_000))
        _ = try await w.flush()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let infos = try CSVExporter.export(reader: SessionStore.openReader(path: path), to: dir)
        #expect(infos.map(\.name).sorted() == ["clock_anchor.csv", "hop.csv", "link_event.csv", "outage.csv", "probe.csv", "system_event.csv", "verdict.csv", "wireless_sample.csv"])
        #expect(infos.first { $0.name == "probe.csv" }?.rows == 10)
        let text = try String(contentsOf: dir.appendingPathComponent("probe.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines[0] == "target_id,seq,t_send_mono,t_wall_ms,send_delay_us,rtt_us,status,ttl")
        #expect(lines[1].hasPrefix("1,0,1000,1700000000000,"))
        #expect(lines.count == 11)
    }
}
```

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현 요점** — `FileHandle`로 스트리밍. `probe.csv`는 `reader.forEachProbe`. nil은 빈 칸. 문자열 필드(`detail`, `reason`, `evidence`)는 큰따옴표로 감싸고 내부 `"`는 `""`로. 벽시계는 `ClockAnchor.wallMs(forMono:anchors:)`. 앵커가 없으면 `t_wall_ms` 빈 칸.

- [ ] **Step 4: 통과 확인** — PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Export/CSVExporter.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/CSVExporterTests.swift
git commit -m "feat(core): CSV export of all session tables"
```

### Task 16: ReportModel과 ReportModelBuilder (집계)

**Files:**
- Create: `Sources/WifiDoctorCore/Export/ReportModel.swift`
- Create: `Sources/WifiDoctorCore/Export/ReportModelBuilder.swift`
- Test: `Tests/WifiDoctorCoreTests/ReportModelBuilderTests.swift`

**Interfaces:**
- Produces:
```swift
public struct ReportModel: Sendable, Codable, Equatable {
    public var meta: SessionMeta
    public var targets: [ProbeTarget]
    public var periodWallMs: (start: Int64, end: Int64)        // Codable을 위해 struct Period로 구현
    public var countedEvents: [OutageEvent]                      // suppressed·HOST_STALL 제외
    public var verdictsByEvent: [Int: VerdictResult]
    public var bucketHistogram: [DurationBucket: Int]
    public var perHourCountOver1s: [Int64: Int]                  // 시간대 시작 wall ms → 건수
    public var segmentCounts: [Segment: Int]
    public var topSegmentSentence: String
    public var longestEvent: OutageEvent?
    public var topology: PathTopology
    public var hops: [HopList]
    public var topologyCaveat: String                            // 공유 구간 범위 주의 문장
    public var sharedAccessRepeatCount: Int                      // 4행 반복 횟수
    public var hostStallEvents: [OutageEvent]
    public var suppressedEvents: [OutageEvent]
    public var sleepIntervals: [(start: Int64, end: Int64)]      // struct Interval로 구현
    public var anchorJumps: [ClockAnchor.Jump]
    public var awdl0History: [SystemEvent]
    public var scanCacheUpdateCount: Int
    public var probeStats: ProbeStats
    public var lateRatio: Double
    public var representative: [RepresentativeEvent]              // 최장 1 + 최다 판정 중앙값 1
    public var attachments: [CSVFileInfo]
    public var sessionFileName: String
    public var sessionSha256: String
    public var locationLimitation: String?                        // 권한 denied일 때 한계 문장
    public var abnormalEnd: Bool                                  // ended_mono_ns NULL
}
public struct RepresentativeEvent: Sendable, Codable, Equatable {
    public var event: OutageEvent; public var verdict: VerdictResult?
    public var probes: [ProbeResult]            // 사건 전후 10초
    public var samples: [WirelessSample]
}
public enum ReportModelBuilder {
    public static func build(reader: SessionReader, attachments: [CSVFileInfo], sessionFileName: String, sessionSha256: String) throws -> ReportModel
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct ReportModelBuilderTests {
    /// 사건 4개: WIRELESS 0.3초, WIRELESS 1.2초, HOST_STALL 0.5초, suppressed 2초. 앵커 2개(60초 점프).
    func makeStore() async throws -> String {
        let path = tempDBPath()
        let w = try SessionStore.create(path: path, meta: sampleMeta())
        var gw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); gw.id = try await w.insertTarget(gw)
        for p in SyntheticSession.probes(target: gw, startNs: 1_000, count: 2000, lostSeqs: [], lateSeqs: [5]) { await w.enqueue(p) }
        await w.enqueue(ClockAnchor(tMono: 1_000, tWallMs: 1_700_000_000_000))
        await w.enqueue(ClockAnchor(tMono: 50_000_001_000, tWallMs: 1_700_000_110_000))
        await w.enqueue(SystemEvent(tMono: 2_000, kind: .awdl0State, detail: "up"))
        await w.enqueue(LinkEvent(tMono: 3_000, kind: .scanCacheUpdated, detail: nil))
        await w.enqueue(LinkEvent(tMono: 4_000, kind: .scanCacheUpdated, detail: nil))
        _ = try await w.flush()
        let S: Int64 = 1_000_000_000
        func ev(_ id: Int, _ s: Int64, _ e: Int64, sup: Bool = false) -> OutageEvent { OutageEvent(id: id, startMono: s, endMono: e, suppressed: sup, wiredOnly: false, outages: []) }
        func vd(_ id: Int, _ seg: Segment) -> VerdictResult { VerdictResult(eventId: id, segment: seg, wirelessCause: seg == .wireless ? .roaming : nil, confidence: .high, reasonCode: nil, reason: "r", evidence: "{}") }
        try await w.writeEvent(ev(1, 10 * S, 10 * S + 300_000_000), verdict: vd(1, .wireless))
        try await w.writeEvent(ev(2, 20 * S, 21 * S + 200_000_000), verdict: vd(2, .wireless))
        try await w.writeEvent(ev(3, 30 * S, 30 * S + 500_000_000), verdict: vd(3, .hostStall))
        try await w.writeEvent(ev(4, 40 * S, 42 * S, sup: true), verdict: nil)
        try await w.writeHops(HopList(path: .wifi, run: 0, tMono: 0, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1)]))
        try await w.writeHops(HopList(path: .wired, run: 0, tMono: 0, hops: [Hop(index: 1, address: "192.0.2.1", rttMs: 1)]))
        try await w.finishSession(endedMonoNs: 100 * S, sntpEnd: "unavailable", notes: nil)
        return path
    }
    @Test func aggregatesExcludeHostStallAndSuppressed() async throws {
        let path = try await makeStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let m = try ReportModelBuilder.build(reader: SessionStore.openReader(path: path), attachments: [], sessionFileName: "session-x.sqlite", sessionSha256: "00")
        #expect(m.countedEvents.map(\.id) == [1, 2])
        #expect(m.hostStallEvents.map(\.id) == [3]); #expect(m.suppressedEvents.map(\.id) == [4])
        #expect(m.bucketHistogram[.b02_05] == 1); #expect(m.bucketHistogram[.b1_25] == 1)
        #expect(m.segmentCounts[.wireless] == 2); #expect(m.segmentCounts[.hostStall] == nil)
        #expect(m.longestEvent?.id == 2)
        #expect(m.perHourCountOver1s.values.reduce(0, +) == 1)
        #expect(m.topology == .sameFirstHop)
        #expect(m.anchorJumps.count == 1); #expect(m.anchorJumps[0].jumpMs == 60_000)
        #expect(m.scanCacheUpdateCount == 2)
        #expect(m.probeStats.count == 2000); #expect(abs(m.lateRatio - 1.0 / 2000) < 1e-9)
        #expect(m.representative.count == 2); #expect(m.representative[0].event.id == 2)
        #expect(m.locationLimitation != nil)         // sampleMeta는 denied
        #expect(m.abnormalEnd == false)
        #expect(m.topSegmentSentence.contains("WIRELESS"))
    }
}
```

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현 요점**

- `countedEvents = events.filter { !$0.suppressed && verdict?.segment != .hostStall }`.
- `perHourCountOver1s`: `durationMs ≥ 1000`인 countedEvents를 `wallMs(start)`의 시간대(`/ 3_600_000 * 3_600_000`)로 묶음.
- 대표 사건: `longestEvent`, 그리고 가장 많은 segment의 사건들을 길이로 정렬한 중앙값. 둘이 같으면 하나만. 각 대표 사건에 `[start − 10초, end + 10초]`의 대상별 프로브와 샘플.
- `topologyCaveat`: `.sameFirstHop` → "첫 홉 동일. 단일 공유기 구조 또는 동일 VLAN. 공유 구간이 길어 SHARED_* 판정 범위가 넓습니다." `.mergedLater(w, e)` → "두 경로는 홉 w/e에서 합류합니다. 합류 전 홉은 각 경로 전용입니다. L2 장비는 보이지 않습니다." `.noMerge` → "20홉 안에서 합류하지 않았습니다. 공유 구간은 인터넷 어딘가로만 말할 수 있습니다." `.unknown` → "경로 탐지 실패. 결정표 5행(UNDETERMINED)이 늘어납니다."
- `locationLimitation`: `meta.locationAuth != "authorized"` → "위치 권한 없음. SSID/BSSID 미기록. 로밍 세분이 제한됩니다." (S2 결과 C면 "무선 세분 불가"로 바꿉니다.)
- `abnormalEnd = meta.endedMonoNs == nil`.
- `sharedAccessRepeatCount = segmentCounts[.sharedAccess] ?? 0`.

- [ ] **Step 4: 통과 확인** — PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Export/ReportModel.swift Packages/WifiDoctorKit/Sources/WifiDoctorCore/Export/ReportModelBuilder.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/ReportModelBuilderTests.swift
git commit -m "feat(core): aggregate session into report model"
```

### Task 17: ReportRenderer (HTML + 인라인 SVG)

**Files:**
- Create: `Sources/WifiDoctorCore/Export/ReportRenderer.swift`
- Test: `Tests/WifiDoctorCoreTests/ReportRendererTests.swift`

**Interfaces:**
- Produces: `public enum ReportRenderer { public static func render(_ m: ReportModel) -> String }`

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct ReportRendererTests {
    func model() async throws -> ReportModel {
        let path = try await ReportModelBuilderTests().makeStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        return try ReportModelBuilder.build(reader: SessionStore.openReader(path: path),
                                            attachments: [CSVFileInfo(name: "probe.csv", rows: 2000)], sessionFileName: "session-20261015-120000.sqlite", sessionSha256: "ab12")
    }
    @Test func containsSixSectionsAndNumbers() async throws {
        let html = ReportRenderer.render(try await model())
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        for h in ["요약", "판정 근거", "방법론", "대표 끊김", "끊김 전체 표", "첨부"] { #expect(html.contains(h)) }
        #expect(html.contains("총 사건 수: 2"))
        #expect(html.contains("192.0.2.1"))                  // 홉 표
        #expect(html.contains("앱은 스캔을 하지 않았"))        // 방법론
        #expect(html.contains("OS 스캔 캐시 갱신 이벤트는 2회"))
        #expect(html.contains("+0.001 +/- 0.006 time.apple.com"))
        #expect(html.contains("맥 자체 지연으로 판정되어 아래 통계에서 제외됨"))
        #expect(html.contains("probe.csv"))
        #expect(html.contains("ab12"))
        #expect(html.contains("위치 권한 없음"))
        #expect(html.contains("관리자 권한 없이 실행"))
    }
    @Test func inlineSvgAndNoExternalResources() async throws {
        let html = ReportRenderer.render(try await model())
        #expect(html.contains("<svg"))
        #expect(html.contains("<script") == false)
        #expect(html.contains("src=\"http") == false)
        #expect(html.contains("href=\"http") == false)
        #expect(html.contains("@import") == false)
    }
    @Test func escapesUserText() async throws {
        var m = try await model(); m.meta.notes = "<b>x</b>"
        #expect(ReportRenderer.render(m).contains("&lt;b&gt;x&lt;/b&gt;"))
    }
}
```

- [ ] **Step 2: 실패 확인** — FAIL.

- [ ] **Step 3: 구현 요점**

- 문자열 보간 템플릿. `<style>` 인라인. 함수 `esc(_:)`로 모든 텍스트 이스케이프.
- 13.3절 6구성 순서. 방법론에 고정 문장: 프로브 대상/주기/시간 초과 표(targets), 5장 끊김 정의 문장, "인터페이스 고정: ICMP는 `IP_BOUND_IF`, DNS는 `NWParameters.requiredInterface`", "앱은 관리자 권한 없이 실행됨", 위치 권한 상태, awdl0 이력 표, "앱은 스캔을 하지 않았고, OS 스캔 캐시 갱신 이벤트는 N회 기록됨", sntp 원문, 앵커 점프 표, 잠자기 구간 표, `send_delay_us` p50/p99/max, `late` 비율, HOST_STALL 횟수·시각 표 + "이 사건들은 맥 자체 지연으로 판정되어 아래 통계에서 제외됨". DNS 프로브 의미(7.10절) 한 문장.
- 대표 끊김 SVG: 폭 900, 대상당 가로 줄 하나. x = 시간(사건 전후 10초), 프로브 1개 = 반지름 2의 원(`ok` 회색, 손실 빨강). RSSI는 `<polyline>`. 사건 창은 반투명 `<rect>`. 선·사각형·원만 씁니다.
- `SHARED_ACCESS`가 있으면 6.3.2 문구와 `sharedAccessRepeatCount`를 적습니다.
- `abnormalEnd`면 요약 첫 줄에 "비정상 종료된 세션" 표시.

- [ ] **Step 4: 통과 확인** — 3 tests PASS. Core 격리 grep → 출력 없음.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Export/ReportRenderer.swift Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/ReportRendererTests.swift
git commit -m "feat(core): render single-file HTML report with inline SVG"
```

### Task 18: 경계 프로토콜과 가짜 구현

**Files:**
- Create: `Sources/WifiDoctorCore/Boundary/Protocols.swift`
- Create: `Tests/WifiDoctorCoreTests/Support/Fakes.swift`
- Test: `Tests/WifiDoctorCoreTests/FakesTests.swift`

**Interfaces:**
- Produces(Core):
```swift
public protocol Prober: Sendable {
    var targets: [ProbeTarget] { get }
    func start() -> AsyncStream<ProbeResult>      // 순번 순서 보장(SeqOrderBuffer 통과)
    func stop()
}
public enum WirelessSignal: Sendable, Equatable { case sample(WirelessSample), event(LinkEvent) }
public protocol WirelessMonitoring: Sendable { func start() -> AsyncStream<WirelessSignal>; func stop() }
public protocol PathDiscovering: Sendable { func discover(path: NetPath, interface: String, run: Int) async -> HopList? }
public protocol SystemGuarding: Sendable {
    func start() -> AsyncStream<SystemEvent>; func stop()
    func sntpReport() async -> String                 // 실패 시 "unavailable"
    func locationAuthorization() async -> String      // authorized | denied | notDetermined
    func freeDiskBytes(at: URL) -> Int64?
}
```
- Produces(테스트 지원): `FakeProber(targets:results:)` — `start()`가 주어진 결과를 순서대로 냄. `FakeWirelessMonitor(signals:)`. `FakePathDiscovery(byPath: [NetPath: HopList?])`. `FakeSystemGuard(events:sntp:location:freeBytes:)`.

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct FakesTests {
    @Test func fakeProberEmitsAllInOrder() async {
        let gw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
        let probes = SyntheticSession.probes(target: gw, startNs: 0, count: 5, lostSeqs: [])
        let p = FakeProber(targets: [gw], results: probes)
        var got: [ProbeResult] = []
        for await r in p.start() { got.append(r) }
        #expect(got == probes)
    }
    @Test func fakePathDiscoveryReturnsConfigured() async {
        let hl = HopList(path: .wifi, run: 0, tMono: 0, hops: [])
        let d = FakePathDiscovery(byPath: [.wifi: hl, .wired: nil])
        #expect(await d.discover(path: .wifi, interface: "en0", run: 0) == hl)
        #expect(await d.discover(path: .wired, interface: "en11", run: 0) == nil)
    }
}
```

- [ ] **Step 2: 실패 확인** — FAIL.
- [ ] **Step 3: 구현** — 위 선언 그대로. 가짜는 `final class ... : @unchecked Sendable` 대신 값 저장만 하는 `struct`로 둡니다.
- [ ] **Step 4: 통과 확인** — PASS.
- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Boundary Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests
git commit -m "feat(core): boundary protocols for probes and test fakes"
```

### Task 19: SessionPipeline — 가짜 프로브로 끝까지 (프로브 → 저장 → 검출 → 판정)

**Files:**
- Create: `Sources/WifiDoctorCore/Pipeline/SessionPipeline.swift`
- Test: `Tests/WifiDoctorCoreTests/SessionPipelineTests.swift`

**Interfaces:**
- Consumes: 작업 6~18의 모든 타입.
- Produces:
```swift
public struct PipelineOutput: Sendable, Equatable { public var event: OutageEvent; public var outcome: JudgeOutcome }
public actor SessionPipeline {
    public init(config: SessionConfig, targets: [ProbeTarget], writer: SessionWriter, topology: PathTopology)
    public func setTopology(_ t: PathTopology)
    public func replaceGatewayTarget(path: NetPath, with newTarget: ProbeTarget)   // gateway_changed
    public func ingest(_ r: ProbeResult) async
    public func ingest(_ s: WirelessSample) async
    public func ingest(_ e: LinkEvent) async
    public func ingest(_ e: SystemEvent) async       // will_sleep/did_wake, interface_lost/back, disk_low 반응
    public func flushStore() async throws             // App이 1초마다 호출
    public func finish() async throws -> [PipelineOutput]   // 열린 끊김 닫기, 남은 사건 판정, 반환
    public var outputs: AsyncStream<PipelineOutput> { get }  // 판정 즉시
    public var recording: Bool { get }                // disk_low(< 500MB)면 false
    public func recentProbes(sinceNs: Int64) -> [ProbeResult]         // LiveView용 링 버퍼(10분)
    public func recentSamples(sinceNs: Int64) -> [WirelessSample]
    public func okCount(targetId: Int) -> Int          // AP 관리 IP 응답 확인용
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct SessionPipelineTests {
    let S: Int64 = 1_000_000_000
    struct Rig {
        let pipeline: SessionPipeline; let writer: SessionWriter; let path: String; let targets: [ProbeTarget]
        var wg: ProbeTarget { targets[0] }; var wi: ProbeTarget { targets[1] }
        var eg: ProbeTarget { targets[2] }; var ei: ProbeTarget { targets[3] }
    }

    /// 와이파이 gw/inetA, 유선 gw/inetA 네 대상. 60초 분량.
    func rig(wired: Bool = true) async throws -> Rig {
        let path = tempDBPath()
        var meta = sampleMeta(); meta.wiredIf = wired ? "en11" : nil
        let w = try SessionStore.create(path: path, meta: meta)
        var ts = [SyntheticSession.target(id: 0, path: .wifi, role: .gateway), SyntheticSession.target(id: 0, path: .wifi, role: .internetA)]
        if wired { ts += [SyntheticSession.target(id: 0, path: .wired, role: .gateway), SyntheticSession.target(id: 0, path: .wired, role: .internetA)] }
        for i in ts.indices { ts[i].id = try await w.insertTarget(ts[i]) }
        let cfg = SessionConfig(wifiIf: "en0", wiredIf: wired ? "en11" : nil, apMgmtIp: nil)
        return Rig(pipeline: SessionPipeline(config: cfg, targets: ts, writer: w, topology: .sameFirstHop), writer: w, path: path, targets: ts)
    }
    /// 대상별 프로브 배열을 시간 순으로 섞어 ingest.
    func feed(_ r: Rig, _ lists: [[ProbeResult]]) async {
        for p in lists.flatMap { $0 }.sorted(by: { $0.tSendMono < $1.tSendMono }) { await r.pipeline.ingest(p) }
    }

    @Test func wifiGatewayLossWithHealthyWiredIsWireless() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        let lost: Set<Int64> = Set(400..<420)            // 20초~21초, 1초 끊김
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: lost),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        for s in SyntheticSession.samples(startNs: 0, count: 300, rssi: { _ in -60 }) { await r.pipeline.ingest(s) }
        let out = try await r.pipeline.finish()
        #expect(out.count == 1)
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .wireless); #expect(v.wirelessCause == .congestionAp)
        #expect(out[0].event.bucket == .b1_25)
        let reader = try SessionStore.openReader(path: r.path)
        #expect(try reader.events().count == 1); #expect(try reader.verdicts().count == 1)
        #expect(try reader.rowCount(table: "probe") == 3000)
    }
    @Test(.timeLimit(.minutes(1))) func verdictIsEmittedBeforeFinishOnceAllTargetsPassWindow() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 600, lostSeqs: Set(100..<110)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 150, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 600, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 150, lostSeqs: [])])
        var got: [PipelineOutput] = []
        for await o in await r.pipeline.outputs { got.append(o); break }   // 30초 분량 뒤에는 이미 판정됨
        #expect(got.count == 1)
    }
    @Test func sleepOverlapIsSuppressedAndStored() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 19 * S, kind: .willSleep, detail: nil))
        await r.pipeline.ingest(SystemEvent(tMono: 25 * S, kind: .didWake, detail: nil))
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out[0].outcome == .suppressedBySleep)
        #expect(try SessionStore.openReader(path: r.path).events()[0].suppressed)
    }
    @Test func interfaceLostForcesControlUnknown() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 15 * S, kind: .interfaceLost, detail: "en11"))
        await r.pipeline.ingest(SystemEvent(tMono: 30 * S, kind: .interfaceBack, detail: "en11"))
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: Set(300..<380)),   // 유선 unreachable 15~19초. 와이파이 사건(20초)과 0.5초 넘게 떨어짐
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: Set(75..<95))])
        let out = try await r.pipeline.finish()
        let wifiEvent = out.first { !$0.event.wiredOnly }!
        guard case .verdict(let v) = wifiEvent.outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .undetermined); #expect(v.reasonCode == "control_insufficient")
        #expect(out.contains { $0.event.wiredOnly })
    }
    @Test func noWiredIsNoControl() async throws {
        let r = try await rig(wired: false); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi) = (r.wg, r.wi)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.reasonCode == "no_control")
    }
    @Test func finishClosesOpenOutageAndJudges() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 600, lostSeqs: Set(580..<600)),  // 끝까지 손실
                       SyntheticSession.probes(target: wi, startNs: 0, count: 150, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 600, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 150, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out.count == 1); #expect(out[0].event.outages[0].closedAtEnd)
        let sys = try SessionStore.openReader(path: r.path).systemEvents()
        #expect(sys.contains { $0.kind == .probeError && $0.detail == "open_at_end" })
    }
    @Test func hostStallWhenAllTargetsDelayed() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        // 20.0초에 모든 대상 송신이 2초 밀림. 와이파이 gw는 그 직전 4개 손실.
        let d: Int64 = 2_000_000
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(396..<400), delayedSeqs: [400: d]),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: [], delayedSeqs: [100: d]),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: [], delayedSeqs: [400: d]),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [], delayedSeqs: [100: d])])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .hostStall)
    }
    @Test func diskLowStopsRecordingButKeepsDetection() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        await r.pipeline.ingest(SystemEvent(tMono: 1, kind: .diskLow, detail: "400000000"))
        #expect(await r.pipeline.recording == false)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 1200, lostSeqs: Set(400..<420)),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        let out = try await r.pipeline.finish()
        #expect(out.count == 1)
        #expect(try SessionStore.openReader(path: r.path).rowCount(table: "probe") == 0)
    }
    @Test func gatewayReplacementKeepsDetecting() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(atPath: r.path) }
        let (wg, wi, eg, ei) = (r.wg, r.wi, r.eg, r.ei)
        var newGw = SyntheticSession.target(id: 0, path: .wifi, role: .gateway); newGw.id = try await r.writer.insertTarget(newGw)
        await feed(r, [SyntheticSession.probes(target: wg, startNs: 0, count: 200, lostSeqs: []),
                       SyntheticSession.probes(target: wi, startNs: 0, count: 300, lostSeqs: []),
                       SyntheticSession.probes(target: eg, startNs: 0, count: 1200, lostSeqs: []),
                       SyntheticSession.probes(target: ei, startNs: 0, count: 300, lostSeqs: [])])
        await r.pipeline.replaceGatewayTarget(path: .wifi, with: newGw)
        await feed(r, [SyntheticSession.probes(target: newGw, startNs: 10 * S, count: 1000, lostSeqs: Set(200..<220))])
        let out = try await r.pipeline.finish()
        guard case .verdict(let v) = out[0].outcome else { Issue.record("no verdict"); return }
        #expect(v.segment == .wireless)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter SessionPipelineTests` → FAIL.

- [ ] **Step 3: 구현 요점**

1. 상태: `targets: [Int: ProbeTarget]`, 대상별 `OutageDetector`, `ring: [ProbeResult]`(10분, `tSendMono` 기준 정리), `samples`, `linkEvents`(최근 70초 이상 유지), `sleepIntervals`, `controlBlackouts`(`interface_lost`~`interface_back`, 열린 구간은 `end = .max`), `closedOutages: [TargetOutage]`(사건 미배정), `lastSeenByTarget: [Int: Int64]`, `nextEventId`, `recording = true`.
2. `ingest(ProbeResult)`: 링 버퍼·`lastSeenByTarget` 갱신 → `recording`이면 `writer.enqueue` → `detector.feed` → 닫힌 끊김을 `closedOutages`에 추가 → `settle()`.
3. `settle()`: `EventGrouper.group(closedOutages, ...)`로 후보 사건을 만듭니다. 후보 중 `모든 대상의 lastSeen ≥ event.end + 700ms`(R8)인 사건만 확정합니다. 확정 사건의 끊김은 `closedOutages`에서 제거. 확정 사건마다 `judgeAndStore(event)`.
4. `judgeAndStore`: `status = WindowStatus.evaluate(..., controlForcedUnknown: controlBlackouts와 창 겹침)`, `stall = HostStallCheck.evaluate`, `classify = { WirelessClassifier.classify(start:end:samples:events:thresholds).cause }`. `Verdict.judge` 결과: `.suppressedBySleep` → event.suppressed 유지하고 `writeEvent(verdict: nil)`. `.noLossInWindow` → `event.suppressed = true`, `writeEvent(verdict: nil)`. `.verdict(v)` → `writeEvent(verdict: v)`. 출력 스트림에 `PipelineOutput` 전달.
5. `ingest(SystemEvent)`: 항상 `writer.enqueue`. `willSleep`/`didWake` → sleepIntervals. `interfaceLost`/`interfaceBack` → controlBlackouts. `diskLow` → detail의 바이트 수 < 500_000_000이면 `recording = false`. 이후 프로브·무선 샘플은 enqueue하지 않습니다. 사건·판정·시스템 이벤트(행 수가 적음)는 계속 씁니다. `replyOnWrongInterface`, `awdl0State`, `gatewayChanged`는 기록만.
6. `finish()`: 각 detector `finish()` → 닫힌 끊김에 `closedAtEnd`면 `SystemEvent(probeError, "open_at_end")` enqueue → `settle(force: true)`(lastSeen 조건 무시) → `flushStore()` → 모든 출력 반환.
7. `replaceGatewayTarget`: 이전 gateway 대상의 detector를 `finish()`로 닫고 새 대상을 추가. 이전 대상은 `targets`에 남겨 둡니다(창 상태 계산은 작업 8 규칙으로 프로브 없는 쪽을 무시).
8. 링 버퍼 정리는 `ingest` 100회마다 한 번.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter SessionPipelineTests` → 9 tests PASS. 전체 `swift test` → 모두 PASS. Core 격리 grep → 출력 없음.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorCore/Pipeline Packages/WifiDoctorKit/Tests/WifiDoctorCoreTests/SessionPipelineTests.swift
git commit -m "feat(core): session pipeline from probes to stored verdicts"
```

---

## 단계 3. Probes (시스템 의존. 순수 파서는 단위 테스트, 나머지는 스모크)

스모크 실행 명령(모든 작업 공통):
`WIFI_DOCTOR_SMOKE=1 WIFI_DOCTOR_WIFI_IF=en0 WIFI_DOCTOR_WIRED_IF=<wired> swift test --filter WifiDoctorProbesSmokeTests`

### Task 20: InterfaceDirectory

**Files:**
- Create: `Sources/WifiDoctorProbes/InterfaceDirectory.swift`
- Test: `Tests/WifiDoctorProbesSmokeTests/InterfaceDirectorySmokeTests.swift`

**Interfaces:**
- Produces:
```swift
public struct NetInterface: Sendable, Equatable { public var bsdName: String; public var index: UInt32; public var ipv4: String?; public var gateway: String?; public var displayName: String; public var isWifi: Bool; public var hasLink: Bool }
public final class InterfaceDirectory: Sendable {
    public init()
    public func wifiInterface() -> NetInterface?
    public func wiredCandidates() -> [NetInterface]            // Ethernet + IPv4 + 링크 있음
    public func interface(named: String) -> NetInterface?
    /// gateway_changed / interface_lost / interface_back 를 SystemEvent로 냄
    public func changes(watching names: [String]) -> AsyncStream<SystemEvent>
}
```

- [ ] **Step 1: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct InterfaceDirectorySmokeTests {
    @Test func findsWifiWithGateway() {
        let d = InterfaceDirectory()
        let w = d.wifiInterface()
        #expect(w?.bsdName == Smoke.wifiIf)
        #expect(w?.ipv4 != nil); #expect(w?.gateway != nil); #expect((w?.index ?? 0) > 0)
    }
    @Test func wiredCandidateMatchesEnvWhenCableConnected() {
        guard let wired = Smoke.wiredIf else { return }
        let names = InterfaceDirectory().wiredCandidates().map(\.bsdName)
        #expect(names.contains(wired))      // 케이블 미연결이면 실패가 정상. 결과를 기록만 함
    }
}
```

- [ ] **Step 2: 구현 요점**

- `SCNetworkInterfaceCopyAll()` → `SCNetworkInterfaceGetInterfaceType` (`kSCNetworkInterfaceTypeIEEE80211` → Wi-Fi, `kSCNetworkInterfaceTypeEthernet` → 유선 후보), `SCNetworkInterfaceGetBSDName`, `SCNetworkInterfaceGetLocalizedDisplayName`.
- `getifaddrs`로 IPv4와 `IFF_RUNNING`. `if_nametoindex`로 인덱스.
- 게이트웨이: `SCDynamicStoreCreate` → `SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4")` → 각 사전의 `InterfaceName`이 일치하면 `Router`.
- `changes`: `SCDynamicStoreSetNotificationKeys`에 같은 패턴 + `State:/Network/Interface/.*/Link`. 콜백에서 이전 스냅샷과 비교: 게이트웨이 바뀜 → `gatewayChanged(detail: "<bsd>")`(주소는 detail에 넣지 않음. 새 target 행에 들어감), 유선이 목록에서 사라짐 → `interfaceLost(detail: bsd)`, 돌아옴 → `interfaceBack(detail: 새 bsd)`. 같은 `displayName`의 포트가 다른 bsd 이름으로 나타나면 그것을 "돌아옴"으로 봅니다(8장).
- `SCDynamicStoreSetDispatchQueue`로 전용 큐에서 콜백.

- [ ] **Step 3: 스모크 실행**

Run: 공통 스모크 명령 + `--filter InterfaceDirectorySmokeTests`
Expected: `findsWifiWithGateway` PASS. `wiredCandidateMatchesEnvWhenCableConnected`는 케이블 연결 시 PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/InterfaceDirectory.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests
git commit -m "feat(probes): interface directory with gateway lookup and change events"
```

### Task 21: ICMP 패킷 조립·해석 (순수)

**Files:**
- Create: `Sources/WifiDoctorProbes/ICMPPacket.swift`
- Test: `Tests/WifiDoctorProbesTests/ICMPPacketTests.swift`

**Interfaces:**
- Produces:
```swift
enum ICMPPacket {
    static func echoRequest(ident: UInt16, seq: UInt16, payload: [UInt8] = Array(repeating: 0, count: 32)) -> [UInt8]   // 체크섬 포함
    struct Reply: Equatable { var ident: UInt16; var seq: UInt16; var ttl: Int; var destination: String; var type: UInt8 }
    /// 수신 버퍼(IPv4 헤더 포함)를 해석. ICMP 에코 응답(type 0)이 아니면 nil.
    static func parseReply(_ bytes: [UInt8]) -> Reply?
    static func checksum(_ bytes: [UInt8]) -> UInt16
}
/// 대상별 pending 송신 기록. 응답 짝 맞추기와 시간 초과.
struct PendingTable {
    mutating func sent(seq64: Int64, tSendMono: Int64, sendDelayUs: Int64)
    mutating func reply(seq16: UInt16, tRecvMono: Int64, timeoutNs: Int64) -> (seq64: Int64, rttUs: Int64, late: Bool)?   // 중복이면 nil
    mutating func expire(now: Int64, timeoutNs: Int64) -> [Int64]       // 시간 초과된 seq64
}
```

- [ ] **Step 1: 실패하는 테스트**

```swift
@Suite struct ICMPPacketTests {
    @Test func echoRequestHasValidChecksum() {
        let p = ICMPPacket.echoRequest(ident: 0x1234, seq: 7)
        #expect(p[0] == 8); #expect(p[1] == 0)
        #expect(ICMPPacket.checksum(p) == 0)                 // 체크섬 포함 전체 합은 0
        #expect(p[4] == 0x12 && p[5] == 0x34); #expect(p[6] == 0 && p[7] == 7)
    }
    @Test func parsesReplyWithIPv4Header() {
        var ip = [UInt8](repeating: 0, count: 20); ip[0] = 0x45; ip[8] = 57 /* ttl */
        ip[16...19] = [192, 0, 2, 20]                          // 목적지
        var icmp = ICMPPacket.echoRequest(ident: 0xBEEF, seq: 3); icmp[0] = 0
        icmp[2] = 0; icmp[3] = 0; let c = ICMPPacket.checksum(icmp); icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
        let r = ICMPPacket.parseReply(ip + icmp)
        #expect(r == ICMPPacket.Reply(ident: 0xBEEF, seq: 3, ttl: 57, destination: "192.0.2.20", type: 0))
    }
    @Test func nonEchoReplyIsNil() {
        var ip = [UInt8](repeating: 0, count: 20); ip[0] = 0x45
        var icmp = [UInt8](repeating: 0, count: 8); icmp[0] = 11
        #expect(ICMPPacket.parseReply(ip + icmp) == nil)
        #expect(ICMPPacket.parseReply([1, 2, 3]) == nil)
    }
    @Test func pendingTableMatchesAndFlagsLate() {
        var t = PendingTable()
        t.sent(seq64: 65_540, tSendMono: 1_000_000_000, sendDelayUs: 5)       // seq16 = 4
        let r = t.reply(seq16: 4, tRecvMono: 1_002_000_000, timeoutNs: 1_000_000_000)
        #expect(r?.seq64 == 65_540); #expect(r?.rttUs == 2_000); #expect(r?.late == false)
        t.sent(seq64: 65_541, tSendMono: 2_000_000_000, sendDelayUs: 0)
        #expect(t.reply(seq16: 5, tRecvMono: 3_100_000_000, timeoutNs: 1_000_000_000)?.late == true)
    }
    @Test func duplicateReplyIgnored() {
        var t = PendingTable()
        t.sent(seq64: 1, tSendMono: 0, sendDelayUs: 0)
        #expect(t.reply(seq16: 1, tRecvMono: 1_000, timeoutNs: 1_000_000_000) != nil)
        #expect(t.reply(seq16: 1, tRecvMono: 2_000, timeoutNs: 1_000_000_000) == nil)
        #expect(t.reply(seq16: 9, tRecvMono: 2_000, timeoutNs: 1_000_000_000) == nil)   // 미송신 seq
    }
    @Test func expireReturnsTimedOutOnly() {
        var t = PendingTable()
        t.sent(seq64: 1, tSendMono: 0, sendDelayUs: 0); t.sent(seq64: 2, tSendMono: 500_000_000, sendDelayUs: 0)
        #expect(t.expire(now: 1_000_000_001, timeoutNs: 1_000_000_000) == [1])
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter ICMPPacketTests` → FAIL.
- [ ] **Step 3: 구현** — RFC 792 에코(type 8/code 0), 체크섬은 16비트 1의 보수 합. `parseReply`: 길이 ≥ 28, `(bytes[0] & 0x0f) * 4`가 IPv4 헤더 길이. `PendingTable`은 `[UInt16: (seq64, tSend, delay)]`와 `expire`용 `tSend` 순 배열. `late` 응답도 pending에서 제거하고 반환합니다(호출자가 `status = .late`로 기록. 단 `expire`가 먼저 `timeout`을 냈으면 그 seq의 응답은 기록을 `late`로 **덧쓰지 않고** `PendingTable`에 없으므로 버립니다. 설계 "초과 뒤 도착한 응답은 late로 저장"은 `expire` 호출 주기(100ms) 안에 도착한 경우에 해당).
- [ ] **Step 4: 통과 확인** — 6 tests PASS.
- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/ICMPPacket.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesTests/ICMPPacketTests.swift
git commit -m "feat(probes): ICMP echo packet codec and pending table"
```

### Task 22: ICMPProber

**Files:**
- Create: `Sources/WifiDoctorProbes/ICMPProber.swift`
- Test: `Tests/WifiDoctorProbesSmokeTests/ICMPProberSmokeTests.swift`

**Interfaces:**
- Consumes: `ICMPPacket`, `PendingTable`, `SeqOrderBuffer`, `MonotonicClock`, `Prober`.
- Produces: `public final class ICMPProber: Prober { public init(interface: NetInterface, targets: [ProbeTarget]) throws; public var systemEvents: AsyncStream<SystemEvent> }` — `init`에서 `socket()` 실패 시 `ICMPProberError.socketFailed(errno:)` throw(8장: 세션 시작 거부).

- [ ] **Step 1: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct ICMPProberSmokeTests {
    @Test func activeInterfaceGetsReply() async throws {
        let wifi = InterfaceDirectory().wifiInterface()!
        let t = ProbeTarget(id: 1, path: .wifi, role: .internetA, address: "1.1.1.1", kind: .icmp, intervalMs: 200, icmpIdent: 0x4a01)
        let p = try ICMPProber(interface: wifi, targets: [t])
        var first: ProbeResult?
        for await r in p.start() { first = r; break }
        p.stop()
        #expect(first?.status == .ok); #expect((first?.rttUs ?? 0) > 0); #expect(first?.ttl != nil)
    }
    @Test func interfaceWithoutLinkIsUnreachable() async throws {
        guard let wired = Smoke.wiredIf, let i = InterfaceDirectory().interface(named: wired), i.hasLink == false else { return }  // 케이블 미연결일 때만
        let t = ProbeTarget(id: 2, path: .wired, role: .internetA, address: "1.1.1.1", kind: .icmp, intervalMs: 200, icmpIdent: 0x4a02)
        let p = try ICMPProber(interface: i, targets: [t])
        var first: ProbeResult?
        for await r in p.start() { first = r; break }
        p.stop()
        #expect(first?.status == .unreachable)
    }
}
```

- [ ] **Step 2: 구현 요점**

- 소켓 1개: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`, `setsockopt(IPPROTO_IP, IP_BOUND_IF, &ifindex)`, `IP_RECVTTL`은 쓰지 않음(수신 데이터에 IPv4 헤더가 포함되므로 그 TTL을 읽음). 논블로킹 + `DispatchSource.makeReadSource`.
- 대상마다 `DispatchSourceTimer(flags: .strict)`, `schedule(deadline:, repeating: interval, leeway: .milliseconds(1))`. 핸들러: `scheduled = 예정 시각(첫 발사 시각 + n × interval)`, `t = MonotonicClock.nowNs()`, `sendDelayUs = (t − scheduled) / 1000`(음수면 0), `sendto`. `EHOSTUNREACH`/`ENETUNREACH`/`ENXIO` → 즉시 `status = .unreachable` 결과. 그 외 오류 → `.sendError`.
- 수신: `recvfrom` 반복 → `ICMPPacket.parseReply` → ident로 대상 찾기(우리 ident가 아니면 버림) → `PendingTable.reply` → 결과. `destination != interface.ipv4`이면 `replyOnWrongInterface` 카운트. 1분에 1회 `SystemEvent`로 요약(S3 결과 반영).
- 100ms 타이머로 `PendingTable.expire` → `.timeout` 결과.
- 모든 결과는 대상별 `SeqOrderBuffer`를 통과해 `AsyncStream.Continuation.yield`. 스트림 버퍼 `.bufferingNewest(10_000)`.
- 내부 상태는 전용 serial `DispatchQueue` 하나에서만 만집니다(`@unchecked Sendable` 명시 + 이유 주석).

- [ ] **Step 3: 스모크 실행** — `activeInterfaceGetsReply` PASS. 케이블 미연결 시 `interfaceWithoutLinkIsUnreachable` PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/ICMPProber.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/ICMPProberSmokeTests.swift
git commit -m "feat(probes): interface-bound ICMP prober with send-delay tracking"
```

### Task 23: DNS 패킷(순수)과 DNSProber

**Files:**
- Create: `Sources/WifiDoctorProbes/DNSPacket.swift`, `Sources/WifiDoctorProbes/DNSProber.swift`
- Test: `Tests/WifiDoctorProbesTests/DNSPacketTests.swift`, `Tests/WifiDoctorProbesSmokeTests/DNSProberSmokeTests.swift`

**Interfaces:**
- Produces: `enum DNSPacket { static func query(id: UInt16, name: String = "www.example.com") -> [UInt8]; static func responseId(_ bytes: [UInt8]) -> UInt16? }`, `public final class DNSProber: Prober { public init(interface: NetInterface, target: ProbeTarget) }`.

- [ ] **Step 1: 실패하는 단위 테스트**

```swift
@Suite struct DNSPacketTests {
    @Test func queryLayout() {
        let q = DNSPacket.query(id: 0xABCD)
        #expect(q[0] == 0xAB && q[1] == 0xCD)
        #expect(q[2] == 0x01 && q[3] == 0x00)        // RD=1
        #expect(q[4] == 0 && q[5] == 1)              // QDCOUNT 1
        #expect(Array(q[12...16]) == [3, 0x77, 0x77, 0x77, 7])   // "www" 길이 3, "example" 길이 7
        #expect(q.suffix(4) == [0, 1, 0, 1])          // QTYPE A, QCLASS IN
    }
    @Test func responseIdReadsFirstTwoBytesOnlyIfQR() {
        #expect(DNSPacket.responseId([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]) == 0x1234)
        #expect(DNSPacket.responseId([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]) == nil)   // QR=0
        #expect(DNSPacket.responseId([0x12]) == nil)
    }
}
```

- [ ] **Step 2: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct DNSProberSmokeTests {
    @Test func resolverReplies() async {
        let wifi = InterfaceDirectory().wifiInterface()!
        let t = ProbeTarget(id: 3, path: .wifi, role: .dns, address: "1.1.1.1", kind: .dns, intervalMs: 200)
        let p = DNSProber(interface: wifi, target: t)
        var first: ProbeResult?
        for await r in p.start() { first = r; break }
        p.stop()
        #expect(first?.status == .ok); #expect((first?.rttUs ?? 0) > 0)
    }
}
```

- [ ] **Step 3: 구현 요점**

- `NWParameters.udp`에 `requiredInterface = nw_interface(이름으로 조회: NWPathMonitor(requiredInterfaceType:) 대신 NWPath.availableInterfaces에서 name 일치)`. 인터페이스 객체를 못 찾으면 `NWParameters.prohibitedInterfaceTypes`로 대체하지 않고 `.unreachable`을 냅니다(설계: 유선 끊김은 unreachable).
- `NWConnection(host: NWEndpoint.Host(address), port: 53, using: params)`. `state == .ready` 전 송신은 `.sendError`.
- 타이머·`sendDelayUs`·시간 초과·`SeqOrderBuffer`는 ICMPProber와 같은 방식(공용 `ProbeScheduler` 헬퍼를 만들어 두 Prober가 함께 씁니다). DNS ID = `UInt16(truncatingIfNeeded: seq)`. 응답은 `responseId`로 짝 맞추기. 응답 코드는 보지 않습니다.
- `receiveMessage` 반복 호출.

- [ ] **Step 4: 확인** — `swift test --filter DNSPacketTests` PASS. 스모크 `resolverReplies` PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/DNSPacket.swift Packages/WifiDoctorKit/Sources/WifiDoctorProbes/DNSProber.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesTests/DNSPacketTests.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/DNSProberSmokeTests.swift
git commit -m "feat(probes): interface-bound UDP DNS prober"
```

### Task 24: WirelessMonitor

**Files:**
- Create: `Sources/WifiDoctorProbes/WirelessMonitor.swift`
- Test: `Tests/WifiDoctorProbesSmokeTests/WirelessMonitorSmokeTests.swift`

**Interfaces:**
- Produces: `public final class WirelessMonitor: WirelessMonitoring { public init(interfaceName: String) }`. 0.2초 샘플 + `CWEventDelegate` 이벤트.

- [ ] **Step 1: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct WirelessMonitorSmokeTests {
    @Test func firstSampleHasRssi() async {
        let m = WirelessMonitor(interfaceName: Smoke.wifiIf)
        var sample: WirelessSample?
        for await s in m.start() { if case .sample(let x) = s { sample = x; break } }
        m.stop()
        #expect(sample?.state == .associated)
        #expect((sample?.rssiDbm ?? 0) < 0)            // S2 결과 C면 이 줄을 "== nil"로 바꾸고 기록
        #expect((sample?.txRateMbps ?? 0) > 0)
        #expect(sample?.ssid == nil)                    // swift test는 번들이 아니라 권한 없음
    }
}
```

- [ ] **Step 2: 구현 요점**

- `CWWiFiClient.shared().interface(withName:)`. 0.2초 `DispatchSourceTimer`에서 `WirelessSample(tMono: MonotonicClock.nowNs(), state: D1 규칙, rssiDbm: rssi == 0 ? nil : rssi, noiseDbm: noise == 0 ? nil : noise, txRateMbps: rate == 0 ? nil : rate, channel: wlanChannel()?.channelNumber, band: wlanChannel()?.channelBand.rawValue, widthMhz: channelWidth → 20/40/80/160, bssid: bssid(), ssid: ssid())`.
- `startMonitoringEvent(with:)`: `.linkDidChange`, `.bssidDidChange`, `.ssidDidChange`, `.linkQualityDidChange`, `.scanCacheUpdated`, `.powerDidChange`. 델리게이트 콜백 → `LinkEvent`. `linkDidChange`는 콜백 시점의 `interfaceMode`로 `linkDown`/`linkUp`을 가릅니다. `linkQualityDidChange(rssi:transmitRate:)`는 `detail = {"rssi":-70,"txRate":540.0}`. `linkQuality` 이벤트는 초당 여러 번 올 수 있으므로 같은 값이 연속이면 생략.
- `scanForNetworks`는 호출하지 않습니다(주석으로 명시).

- [ ] **Step 3: 스모크 실행** — PASS(S2 결과에 따라 기대값 조정 후 기록).

- [ ] **Step 4: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/WirelessMonitor.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/WirelessMonitorSmokeTests.swift
git commit -m "feat(probes): CoreWLAN sampling and link events"
```

### Task 25: traceroute 파서(순수)와 PathDiscovery

**Files:**
- Create: `Sources/WifiDoctorProbes/TracerouteParser.swift`, `Sources/WifiDoctorProbes/PathDiscovery.swift`
- Test: `Tests/WifiDoctorProbesTests/TracerouteParserTests.swift`, `Tests/WifiDoctorProbesSmokeTests/PathDiscoverySmokeTests.swift`

**Interfaces:**
- Produces: `enum TracerouteParser { static func parse(_ output: String) -> [Hop] }`, `public final class PathDiscovery: PathDiscovering { public init(); public var errors: AsyncStream<SystemEvent> }`.
- 구현 방식은 **작업 1 결과(A/B/C)** 를 따릅니다.

- [ ] **Step 1: 실패하는 단위 테스트**

```swift
@Suite struct TracerouteParserTests {
    @Test func parsesHopsStarsAndSkipsHeader() {
        let out = """
        traceroute to 1.1.1.1 (1.1.1.1), 20 hops max, 40 byte packets
         1  192.0.2.1  1.234 ms
         2  * 
         3  203.0.113.9  12.5 ms
        """
        let hops = TracerouteParser.parse(out)
        #expect(hops == [Hop(index: 1, address: "192.0.2.1", rttMs: 1.234), Hop(index: 2, address: nil, rttMs: nil), Hop(index: 3, address: "203.0.113.9", rttMs: 12.5)])
    }
    @Test func emptyOutputIsEmpty() { #expect(TracerouteParser.parse("").isEmpty) }
}
```

- [ ] **Step 2: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct PathDiscoverySmokeTests {
    @Test func atLeastOneHopOnWifi() async {
        let hl = await PathDiscovery().discover(path: .wifi, interface: Smoke.wifiIf, run: 0)
        #expect((hl?.hops.count ?? 0) >= 1)
        #expect(hl?.hops.first?.address != nil)
    }
}
```

- [ ] **Step 3: 구현 요점**

- 결과 A: `Process("/usr/sbin/traceroute", ["-n", "-i", bsd, "-q", "1", "-w", "1", "-m", "20", "1.1.1.1"])`. stdout+stderr 수집. 30초 타임아웃(`DispatchWorkItem`으로 `terminate()`). 종료 코드 ≠ 0 또는 타임아웃 → `nil` + `SystemEvent(probeError, "traceroute")`.
- 결과 B: `IcmpTraceroute`(TTL 1~20, 각 1초 대기, `IP_BOUND_IF`). 파서는 쓰지 않지만 같은 `[Hop]`을 냅니다.
- 결과 C: `discover`가 항상 `nil`을 반환하고 `probeError(detail: "traceroute_unavailable")`.
- `HopList(path:, run:, tMono: MonotonicClock.nowNs(), hops:)`.

- [ ] **Step 4: 확인** — `swift test --filter TracerouteParserTests` PASS. 스모크 PASS(결과 C면 스모크를 `hl == nil` 기대로 바꾸고 기록).

- [ ] **Step 5: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/TracerouteParser.swift Packages/WifiDoctorKit/Sources/WifiDoctorProbes/PathDiscovery.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesTests/TracerouteParserTests.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/PathDiscoverySmokeTests.swift
git commit -m "feat(probes): per-interface path discovery"
```

### Task 26: SystemGuard

**Files:**
- Create: `Sources/WifiDoctorProbes/SystemGuard.swift`
- Test: `Tests/WifiDoctorProbesSmokeTests/SystemGuardSmokeTests.swift`

**Interfaces:**
- Produces: `public final class SystemGuard: SystemGuarding { public init(); public func beginSessionActivity(); public func endSessionActivity() }`.

- [ ] **Step 1: 스모크 테스트**

```swift
@Suite(.enabled(if: Smoke.enabled), .tags(.smoke))
struct SystemGuardSmokeTests {
    @Test func sntpReturnsOffsetOrUnavailable() async {
        let s = await SystemGuard().sntpReport()
        #expect(s == "unavailable" || s.contains("time.apple.com"))
    }
    @Test func awdl0StateIsEmittedFirst() async {
        let g = SystemGuard()
        var first: SystemEvent?
        for await e in g.start() { first = e; break }
        g.stop()
        #expect(first?.kind == .awdl0State)
        #expect(first?.detail?.hasPrefix("up=") == true)      // 예: "up=1,running=1"
    }
    @Test func freeDiskIsPositive() {
        #expect((SystemGuard().freeDiskBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
}
```

- [ ] **Step 2: 구현 요점**

- 잠자기 방지: `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "wifi-doctor session")` 토큰 보관. `endActivity`.
- `NSWorkspace.shared.notificationCenter`의 `willSleepNotification`/`didWakeNotification` → `willSleep`/`didWake`.
- awdl0: 5초 타이머 `getifaddrs`로 `awdl0`의 `IFF_UP`, `IFF_RUNNING` → `detail = "up=\(u),running=\(r)"`. 시작 직후 1회 즉시 내고, 이후 변화 시에만.
- 디스크: 5초마다 `freeDiskBytes(세션 폴더)`. 500 MB 미만이면 `diskLow(detail: 바이트 수)` 1회(값이 다시 넘으면 재무장).
- `sntpReport`: `Process("/usr/bin/sntp", ["-t", "3", "time.apple.com"])` 10초 타임아웃, 마지막 줄 원문. 실패 `"unavailable"`.
- `locationAuthorization`: `CLLocationManager()`를 만들고 `requestWhenInUseAuthorization()` 호출 후 `authorizationStatus`를 문자열로. 번들이 아닌 `swift test`에서는 `denied`로 나옵니다.
- D4 확인: AirDrop을 켠 상태와 끈 상태에서 `ifconfig awdl0` 플래그를 비교해 `RUNNING`이 달라지는지 `docs/verification/2026-10-15-spikes.md`에 한 줄 적습니다.

- [ ] **Step 3: 스모크 실행** — 3 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/WifiDoctorKit/Sources/WifiDoctorProbes/SystemGuard.swift Packages/WifiDoctorKit/Tests/WifiDoctorProbesSmokeTests/SystemGuardSmokeTests.swift
git commit -m "feat(probes): system guard for sleep, awdl0, disk, sntp and location"
```

---

## 단계 4. App (SwiftUI)

UI 작업은 TDD 대상이 아닙니다. 검증은 빌드 성공과 아래 수동 확인 목록입니다. 로직은 넣지 않습니다. 계산이 필요하면 Core에 함수를 추가하고 테스트를 Core에 둡니다.

빌드 명령(공통): 저장소 루트에서
`xcodegen generate && xcodebuild -project WifiDoctor.xcodeproj -scheme WifiDoctor -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode build`
실행: `open .build/xcode/Build/Products/Debug/WifiDoctor.app`

### Task 27: xcodegen 프로젝트와 앱 껍데기

**Files:**
- Create: `project.yml`, `WifiDoctor/WifiDoctorApp.swift`, `WifiDoctor/Info.plist`, `WifiDoctor/WifiDoctor.entitlements`
- Modify: `.gitignore` (`WifiDoctor.xcodeproj/` 한 줄 추가)

**Interfaces:**
- Produces: 빌드 가능한 앱 타깃. 로컬 패키지 두 제품에 링크.

- [ ] **Step 1: `project.yml`**

```yaml
name: WifiDoctor
options:
  deploymentTarget:
    macOS: "27.0"
  createIntermediateGroups: true
packages:
  WifiDoctorKit:
    path: Packages/WifiDoctorKit
targets:
  WifiDoctor:
    type: application
    platform: macOS
    sources: [WifiDoctor]
    dependencies:
      - package: WifiDoctorKit
        product: WifiDoctorCore
      - package: WifiDoctorKit
        product: WifiDoctorProbes
    info:
      path: WifiDoctor/Info.plist
      properties:
        CFBundleDisplayName: wifi-doctor
        NSLocationUsageDescription: "Wi-Fi 이름(SSID)과 접속점(BSSID)을 기록하기 위해 위치 권한이 필요합니다. 위치 자체는 사용하지 않습니다."
        LSMinimumSystemVersion: "27.0"
    entitlements:
      path: WifiDoctor/WifiDoctor.entitlements
      properties:
        com.apple.security.app-sandbox: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yhzion.wifi-doctor
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: "-"
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
```

- [ ] **Step 2: `WifiDoctorApp.swift`**

```swift
import SwiftUI

@main
struct WifiDoctorApp: App {
    var body: some Scene {
        WindowGroup("wifi-doctor") { Text("wifi-doctor").padding() }
    }
}
```

- [ ] **Step 3: 빌드**

Run: 공통 빌드 명령
Expected: `** BUILD SUCCEEDED **`. `.build/xcode/Build/Products/Debug/WifiDoctor.app` 존재. `codesign -d --entitlements - .build/xcode/Build/Products/Debug/WifiDoctor.app 2>&1 | grep -c app-sandbox` → `0`(샌드박스 키가 false면 엔타이틀먼트에 포함되지 않거나 false). `codesign -d -v ... 2>&1 | grep runtime` → `flags=0x10000(runtime)`.

**사람이 손으로 할 일(선택):** Developer ID 서명을 원하면 Xcode에서 타깃의 Signing 팀을 고르고 `project.yml`의 `CODE_SIGN_IDENTITY`를 지웁니다. 로컬 실행에는 ad-hoc(`-`)으로 충분합니다.

- [ ] **Step 4: Commit**

```bash
git add project.yml WifiDoctor .gitignore
git commit -m "chore: xcodegen app target with sandbox off and hardened runtime"
```

### Task 28: AppSettings, SessionController, SettingsView

**Files:**
- Create: `WifiDoctor/AppSettings.swift`, `WifiDoctor/SessionController.swift`, `WifiDoctor/Views/SettingsView.swift`
- Modify: `WifiDoctor/WifiDoctorApp.swift` (탭 4개: 실시간, 분석, 보고서, 설정. 이 작업에서는 설정만 채움)

**Interfaces:**
- Consumes: `InterfaceDirectory`, `ICMPProber`, `DNSProber`, `WirelessMonitor`, `PathDiscovery`, `SystemGuard`, `SessionStore`, `SessionPipeline`, `PathCorrelator`.
- Produces:
```swift
@Observable final class AppSettings { var wiredInterface: String?; var apMgmtIp: String; var baseFolder: URL /* 기본 ~/Documents/wifi-doctor */ }   // @AppStorage 대신 UserDefaults 직접 읽기/쓰기
@MainActor @Observable final class SessionController {
    enum State { case idle, starting, running, stopping }
    var state: State; var elapsed: TimeInterval; var fileSizeBytes: Int64; var awdl0: String; var locationAuth: String; var hasWired: Bool
    var liveOutputs: [PipelineOutput]          // 끊김 목록(최신 위)
    var topology: PathTopology; var hops: [HopList]
    var warnings: [String]                     // AP 응답 0, 디스크 < 2GB, 유선 없음 등
    func start() async; func stop() async; func rediscoverPaths() async
    var currentSessionPath: String?
}
```

- [ ] **Step 1: SessionController.start() 순서(구현 요점)**

1. `InterfaceDirectory`로 Wi-Fi와 유선(설정값 또는 후보 1개)을 찾습니다. 유선 없음 → `warnings.append("유선 대조군 없음. 모든 판정이 UNDETERMINED(no_control)입니다.")` 후 진행(8장. 확인 다이얼로그는 SettingsView의 토글 "대조군 없이 시작 허용"으로 대체).
2. `SystemGuard.freeDiskBytes(baseFolder)` < 2 GB → 경고.
3. 폴더 생성. `session-<YYYYMMDD-HHmmss>.sqlite` 경로. `SystemGuard.locationAuthorization()`, `sntpReport()`(시작) → `SessionMeta` → `SessionStore.create`.
4. 대상 생성(`insertTarget`로 id): 경로마다 gateway(50ms, icmp), internet_a `1.1.1.1`, internet_b `8.8.8.8`(200ms, icmp), dns `1.1.1.1`(200ms, dns). AP 관리 IP 입력 시 와이파이 경로에 `apMgmt`(50ms). ICMP identifier는 `0x4a00 + targetId`.
5. `ICMPProber(wifi)`, `ICMPProber(wired)`, `DNSProber ×2`, `WirelessMonitor`, `SystemGuard.start()`, `InterfaceDirectory.changes`. 소켓 생성 실패 → 세션 시작 거부, errno 표시.
6. `PathDiscovery.discover` 두 경로 병렬 → `writer.writeHops` → `PathCorrelator.topology` → `pipeline.setTopology`.
7. `SessionPipeline` 생성. 스트림마다 `Task`로 `for await ... { await pipeline.ingest(...) }`. 1초마다 `pipeline.flushStore()` + `ClockAnchor` 10초마다(`did_wake` 직후에도) enqueue. UI 상태 1초마다 갱신(경과, 파일 크기).
8. 시작 5초 뒤 `pipeline.okCount(apTargetId) == 0`이면 경고 + 그 대상 Prober 중단.
9. `gatewayChanged` 수신 → 새 `ProbeTarget` 삽입 → `pipeline.replaceGatewayTarget` → 해당 경로 ICMPProber 재시작.
10. `stop()`: Prober 전부 `stop()` → `pipeline.finish()` → `sntpReport()`(종료) → `writer.finishSession` → `SystemGuard.endSessionActivity()`.

- [ ] **Step 2: SettingsView 내용** — 유선 인터페이스 Picker(`wiredCandidates`, 표시 이름 + bsd), "대조군 없이 시작 허용" 토글, AP 관리 IP TextField(선택), 저장 폴더(기본 `~/Documents/wifi-doctor`, 폴더 선택 버튼 `NSOpenPanel`), "경로 다시 탐지" 버튼(세션 중 활성), awdl0 안내문(7.4절 문구 그대로), 위치 권한 상태와 "권한이 없으면 SSID/BSSID를 기록하지 않습니다. 측정은 계속됩니다." 문장.

- [ ] **Step 3: 빌드와 수동 확인**

Run: 공통 빌드 명령 → `BUILD SUCCEEDED`. 앱 실행 → 설정 탭에서 유선 후보에 USB 어댑터가 보임(케이블 연결 시) → 시작 → 10초 후 정지 → `~/Documents/wifi-doctor/sessions/session-*.sqlite` 생성 → `sqlite3 <file> 'select count(*) from probe'`가 300 이상(와이파이 35/s × 10초).

**사람이 손으로 할 일:** 첫 실행 시 위치 권한 다이얼로그가 뜹니다. 거부해도 측정은 계속됩니다(기본값 4).

- [ ] **Step 4: Commit**

```bash
git add WifiDoctor
git commit -m "feat(app): session controller assembling probes and pipeline, settings view"
```

### Task 29: LiveView

**Files:**
- Create: `WifiDoctor/Views/LiveView.swift`
- Modify: `WifiDoctor/SessionController.swift` (1초마다 `pipeline.recentProbes/recentSamples` 스냅샷을 `liveProbes`, `liveSamples`로 노출)

- [ ] **Step 1: 구성(13.1절)** — 상단 상태 줄(경과, 파일 크기, awdl0, 위치 권한, 대조군 유무). 레인 4~5개(`wifi/gateway`, `wifi/internet`, `wired/gateway`, `wired/internet`, 선택 `wifi/ap_mgmt`): 최근 10분, 1초 = 1픽셀 이상(`Canvas`). 1초 칸 색: 손실 0 초록, 손실 있음 노랑, 그 칸이 확정 사건 창에 포함 빨강. 선 그래프 3개(RSSI, SNR, 전송 속도)는 Swift Charts `LineMark`, 레인과 같은 x 범위. 끊김 목록 `Table`(시각, 길이, 버킷, 판정, 무선 원인), 최신이 위.
- 칸 색 계산은 Core에 `LiveLane.colorBuckets(probes:, events:, fromNs:, toNs:, bucketNs: 1_000_000_000) -> [LaneBucket]`로 두고 Core 테스트 1개(`LiveLaneTests`: 손실 없음/손실만/사건 포함 각 1칸)를 함께 추가합니다.

- [ ] **Step 2: 빌드와 수동 확인** — 세션 시작 후 레인이 1초마다 채워짐. Wi-Fi를 끄면 와이파이 레인이 빨강으로 바뀌고 목록에 사건이 뜸(약 2초 뒤).

- [ ] **Step 3: Commit**

```bash
git add WifiDoctor Packages/WifiDoctorKit
git commit -m "feat(app): live view with lanes, signal lines and outage list"
```

### Task 30: AnalysisView

**Files:**
- Create: `WifiDoctor/Views/AnalysisView.swift`
- Modify: `WifiDoctor/SessionController.swift` (세션 파일 선택: 현재 세션 또는 `sessions/`의 과거 파일. `SessionReader`와 `ReportModelBuilder.build`로 `ReportModel`을 만들어 노출)

- [ ] **Step 1: 구성(13.2절)** — Swift Charts `BarMark` 3개: 버킷 분포(`bucketHistogram`), 시간당 빈도(`perHourCountOver1s`), 판정 ID별 횟수(`segmentCounts`). 산점도 `PointMark`: x = 사건 시작 3초 전 RSSI 중앙값, y = 길이(초, `.log` 축). 홉 목록 두 개 표와 합류 지점 강조. RSSI 중앙값은 Core `ReportModel`에 `rssiBeforeByEvent: [Int: Int]`를 추가하고 작업 16 빌더가 채웁니다(테스트 1개 추가: 사건 1의 값 −60).
- 질의는 `outage`, `event`, `verdict`와 대표 사건 창의 `probe`만 읽습니다(7.7절).

- [ ] **Step 2: 빌드와 수동 확인** — 작업 29에서 만든 세션을 정지한 뒤 분석 탭 전환이 1초 안에 끝남. 막대 3개와 산점도가 보임.

- [ ] **Step 3: Commit**

```bash
git add WifiDoctor Packages/WifiDoctorKit
git commit -m "feat(app): analysis view with distributions and hop lists"
```

### Task 31: ReportView — HTML + CSV 내보내기

**Files:**
- Create: `WifiDoctor/Views/ReportView.swift`
- Modify: `WifiDoctor/SessionController.swift` (`exportReport() async throws -> URL`)

- [ ] **Step 1: 구성(13.3절)** — 요약 미리보기(총 사건 수, 최장 끊김, 가장 많은 판정 문장) + "HTML 저장" 버튼. `exportReport`: `reports/<세션 이름>/` 생성 → `CSVExporter.export` → 세션 파일 SHA-256(`CryptoKit.SHA256`, 스트리밍) → `ReportModelBuilder.build(attachments:sessionFileName:sessionSha256:)` → `ReportRenderer.render` → `report.html` 저장 → Finder에서 폴더 열기(`NSWorkspace.shared.activateFileViewerSelecting`).
- 비정상 종료 파일(`ended_mono_ns IS NULL`)도 열 수 있어야 합니다. 열린 끊김은 `ReportModelBuilder`가 `abnormalEnd = true`로 표시만 합니다(끊김 닫기는 파일을 바꾸지 않고 보고서에서만 마지막 프로브 시각 기준).

- [ ] **Step 2: 빌드와 수동 확인** — 저장 후 `reports/<세션>/report.html`을 브라우저로 열면 6개 섹션이 보이고 외부 요청이 없음(개발자 도구 Network 탭 비어 있음). CSV 8개 존재. `shasum -a 256 sessions/<세션>.sqlite`가 보고서의 값과 같음.

- [ ] **Step 3: Commit**

```bash
git add WifiDoctor
git commit -m "feat(app): report view exporting HTML and CSV attachments"
```

### Task 32: README와 저장소 위생

**Files:**
- Create: `README.md`

- [ ] **Step 1: 내용** — 목적 한 단락. 빌드·테스트 명령(공통 규약의 명령 그대로). 스모크 테스트 명령과 환경 변수. `xcodegen generate` 안내. 커밋 전 주소 점검 명령(10장 grep). 산출물(.sqlite, CSV, HTML)은 커밋하지 않음. `docs/verification/`에는 결과 표만. 예시 주소 규칙(RFC 5737, `02:00:00:00:00:01`, `example-ssid`).

- [ ] **Step 2: 점검**

Run: `git ls-files | grep -E '\.(sqlite|csv|html)$'` → 출력 없음. `grep -rEn '([0-9]{1,3}\.){3}[0-9]{1,3}' --include='*.swift' --include='*.md' --include='*.yml' . | grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|1\.1\.1\.1|8\.8\.8\.8|127\.0\.0\.1|0\.0\.0\.0|swift-tools-version|27\.0|6\.4' ` → 출력 없음.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with build, test and hygiene procedure"
```

---

## 단계 5. 수동 현장 검증 (사용자 수행)

### Task 33: V1~V11

**사용자가 직접 합니다.** 결과를 `docs/verification/<YYYY-MM-DD>-field.md`에 표로 적습니다(실제 주소·SSID·BSSID 없음). 각 행은 "절차 / 예상 판정 / 실제 판정 / 통과 여부 / 비고".

| # | 절차 | 예상 판정(통과 조건) |
|---|---|---|
| V1 | 와이파이+유선 연결. 10분 측정 | 사건 0건 또는 `INTERNET_PARTIAL`만 |
| V2 | 맥 Wi-Fi 끄고 5초 뒤 켬 | `WIRELESS` / `disconnect`. 유선 사건 없음 |
| V3 | AP 전원 차단 30초(가정용: 공유기 무선만 끄기) | `WIRELESS`. BSSID 변화 없음 또는 `disconnect` |
| V4 | 유선 케이블 분리 10초 | `WIRED_ONLY`. 그 구간 와이파이 사건은 `UNDETERMINED(control_insufficient)` |
| V5 | 공유기 전원 차단 30초 | `SHARED_FIRST_HOP` |
| V6 | WAN 케이블만 분리 | `SHARED_UPSTREAM` |
| V7 | RSSI −80 dBm 이하로 이동 | `WIRELESS` / `coverage_interference` 또는 사건 없음 |
| V8 | 다른 AP로 로밍(기업형) | `WIRELESS` / `roaming` (S2 결과 B/C면 권한 허용 상태에서만 기대) |
| V9 | 세션 중 덮개 닫기 1분 | 그 구간 사건 `suppressed`. 앵커 점프 표에 약 60초 |
| V10 | 24시간 녹화 | 파일 0.3~0.6 GB. 분석 탭 1초 내. 보고서 생성 성공. 디스플레이 잠자기 구간에 측정 공백 없음(있으면 `SystemGuard`에 `.idleDisplaySleepDisabled` 추가 — 7.6절) |
| V11 | 측정 중 `kill -STOP <pid>`, 2초 뒤 `kill -CONT` | 사건 1건 `HOST_STALL`. 요약 통계 제외. 별도 표에 표시 |

통과하지 못한 항목은 GitHub 이슈 #1에 코멘트로 남기고, 원인 수정은 별도 작업으로 계획합니다.

```bash
git add docs/verification/
git commit -m "docs: field verification results V1-V11"
```

---

## 설계 문서 → 작업 대응표

| 설계 항목 | 작업 |
|---|---|
| 1.3 ① 무선 링크 모니터 | 24 (D1 상태 정의: 5) |
| 1.3 ② 게이트웨이 ICMP 20/s, AP 관리 IP 선택 | 21, 22, 28(대상 생성·AP 응답 0 경고) |
| 1.3 ⑤ 인터넷 ICMP·DNS 5/s | 22, 23, 28 |
| 1.3 유선 대조군 동시 측정 | 20, 22, 23, 28 |
| 1.3 경로 탐지, 공유 구간 | 1(스파이크), 9, 25, 28 |
| 1.3 끊김 검출, 판정, 무선 세분 | 6, 7, 8, 10, 11, 12, 19 |
| 1.3 실시간·분석 화면 | 29, 30 |
| 1.3 세션 녹화, CSV, HTML | 13, 14, 15, 16, 17, 31 |
| 1.3 시스템 상태 기록(awdl0, 잠자기, 위치 권한, 시계) | 26, 28, 5(앵커) |
| 3.2 Prober 프로토콜·가짜 구현 | 18 |
| 3.2 SessionController(조립), Views | 28–31 |
| 4.1 파일 위치·이름 | 28, 31 |
| 4.2 스키마 11개 테이블 | 13, 14 |
| 4.3 시간 기준, 앵커, 점프 표 | 5, 14, 16, 17, 28 |
| 5.1 대상 끊김 | 6 |
| 5.2 사건, 0.5초 병합, suppressed, 버킷 | 5, 7 |
| 5.3 창 상태, weak, 그룹 상태 | 8 |
| 6.2 PathCorrelator | 9 |
| 6.3 전제 검사 P1~P4, 결정표 17행, AP 문구 | 11 |
| 6.3.1 대조군 없음 보조 설명 | 11 |
| 6.3.2 동시 발생(2행), 4행 문구·반복 횟수 | 11, 16, 17 |
| 6.3.3 HOST_STALL | 10, 11, 16, 17 |
| 6.4 WirelessClassifier, 임계값 상수 | 5, 12 |
| 6.5 가정용 재현 | 11(인자 케이스) |
| 6.6 의사코드 | 11, 19 |
| 7.1 비특권 ICMP, identifier 필터, 교차 수신 | 3(스파이크), 21, 22 |
| 7.2 샌드박스 끔, Hardened Runtime | 27 |
| 7.3 위치 권한 | 2(스파이크), 24, 26, 28 |
| 7.4 awdl0 기록·안내문 | 26, 28 |
| 7.5 스캔 미실행, 스캔 캐시 횟수 | 24, 16, 17 |
| 7.6 잠자기 방지, 디스플레이 잠자기 | 26, 33(V10) |
| 7.7 저장 용량, 배치 쓰기, 분석 질의 속도 | 14, 30, 33(V10) |
| 7.8 두 인터페이스 라우팅, 응답 목적지 확인 | 22 |
| 7.9 traceroute 고정, 대체안 | 1, 25 |
| 7.10 DNS 프로브 의미 | 17(방법론 문장) |
| 8장 유선 미연결 | 28 |
| 8장 유선 사라짐 → control UNKNOWN | 8, 19, 20 |
| 8장 BSD 이름 변경 재바인딩 | 20, 28 |
| 8장 Wi-Fi 꺼짐 | 24, 12 |
| 8장 게이트웨이 변경 | 19, 20, 28 |
| 8장 위치 권한 거부 | 16, 17, 28 |
| 8장 ICMP 소켓 실패 | 22, 28 |
| 8장 디스크 부족 | 19, 26, 28 |
| 8장 SQLite 쓰기 오류 3회 재시도 | 14 |
| 8장 traceroute 실패·재탐지 | 25, 28 |
| 8장 sntp 실패 | 26 |
| 8장 잠자기 | 19, 26 |
| 8장 비정상 종료 | 16, 31 |
| 9.1 단위 테스트 전 항목 | 6–17 |
| 9.2 가짜 프로브 통합 | 18, 19 |
| 9.3 스모크 4종 | 20, 22, 23, 24, 25 |
| 9.4 V1~V11 | 33 |
| 10장 저장소 위생 | 32, 공통 규약 |
| 11장 프로젝트 구조 | 4, 27 |
| 12장 데이터 흐름, 판정 시점 | 19, 28 |
| 13.1~13.3 화면·보고서 구성 | 29, 30, 31, 17 |
| 이슈 #1 완료 조건(swift test, V1~V11) | 19, 33 |

## 자체 검토 결과

- 설계 1~13장의 MVP 항목이 모두 위 표에 작업을 가집니다. 2단계 항목(③, ④, 재생, 모니터 모드, 홉 수동 입력)은 넣지 않았습니다.
- 타입·함수 이름 일치: `NetPath`, `TargetRole`, `ProbeTarget`, `ProbeResult`, `ProbeStatus`, `WirelessSample`, `WirelessLinkState`, `LinkEvent`, `SystemEvent`, `ClockAnchor`, `Hop`, `HopList`, `PathTopology`, `TargetOutage`, `OutageEvent`, `DurationBucket`, `Segment`, `Confidence`, `WirelessCause`, `VerdictResult`, `JudgeOutcome`, `SessionConfig`, `SessionMeta`, `WirelessThresholds`, `TargetState`, `GroupState`, `WindowState`, `EventStatus`, `HostStallResult`, `SessionWriter`, `SessionReader`, `ProbeStats`, `CSVFileInfo`, `ReportModel`, `PipelineOutput`, `SessionPipeline`, `NetInterface`를 작업 5~31에서 같은 이름으로 씁니다.
- 의존 순서: 5 → 6 → 7, 8 → 9, 10 → 11 → 12 → 13 → 14 → 15, 16 → 17 → 18 → 19. Probes(20~26)는 Core 5, 6, 18에만 의존. App(27~31)은 모두에 의존. 스파이크(1~3)는 25, 24, 22의 구현 선택을 정하므로 맨 앞.
- TBD/placeholder 없음. "검증 필요" 항목은 각각 스파이크(1~3) 또는 현장 검증(33)에 배정했습니다.
- Review Focus 5개 모두 소유 작업에 테스트가 있습니다(6, 8, 12, 21, 19).

## 미결 질문 (사용자 결정)

1. **실행 방법**: Subagent-driven(작업마다 새 구현자 + 리뷰어, 끝에 브랜치 전체 리뷰) 또는 Native(이 세션이 직접 구현, 끝에 리뷰 1회). 추천: **Subagent-driven**. 이유: 작업 33개, Core 타입 인터페이스를 작업 간에 공유하므로 작업마다 독립 리뷰가 이름 불일치를 일찍 잡습니다.
2. **Xcode 프로젝트 생성 방식**: 기본값은 xcodegen(`project.yml` 커밋, `.xcodeproj`는 `.gitignore`). 대안 (a) `.xcodeproj`도 커밋, (b) Xcode GUI로 한 번 만들고 커밋(재현 불가). 기본값으로 진행해도 되는지.
3. **번들 ID**: `com.yhzion.wifi-doctor`로 두었습니다. 다른 값을 원하는지.
4. **서명**: 로컬 ad-hoc(`-`)으로 두었습니다. Developer ID를 쓸지.
5. **D1 반영 승인**: SDK에 `interfaceState`가 없어 `wireless_sample.state`를 앱 정의 값(0 off / 1 disconnected / 2 associated)으로 바꿨습니다. 설계 문서 3.2, 4.2, 6.4절도 같이 고칠지(이 계획은 문서 수정 작업을 포함하지 않음).
