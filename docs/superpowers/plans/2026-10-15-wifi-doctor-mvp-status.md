# wifi-doctor MVP 구현 상태 (2026-10-15 세션 종료 시점)

작업 브랜치 `feat/mvp`(커밋 32개)를 `main`에 병합 완료. 이 문서는 다음 세션의 재개 지점이다.
상세 진행 기록(판정 40여 건, Minor 목록)은 이 머신의 `.superpowers/sdd/2026-10-15-wifi-doctor-mvp/progress.md`(git 제외)에 있다.

## 완료 (작업 4~21, 23, 26 / 전체 33개)

| 단계 | 작업 | 내용 |
|---|---|---|
| 1. 골격 | 4 | Swift Package 3타깃(Core/Probes/테스트) |
| 2. Core | 5~12 | 모델, 끊김 검출, 사건 묶기, 창 상태, 경로 합류, HOST_STALL, 결정표 17행(+전제 P1~P4), 무선 세분 |
| 2. Core | 13~17 | SQLite 저장소(스키마 11표), 배치 쓰기 액터, CSV 8종, 보고서 집계, 단일 파일 HTML(인라인 SVG) |
| 2. Core | 18~19 | 경계 프로토콜·가짜 구현, SessionPipeline(판정 확정·은퇴·열린 run 대기·원자 finish) |
| 3. Probes | 20 | InterfaceDirectory(게이트웨이 조회, 유선 전용 lost/back, 재바인딩 시 새 이름 게이트웨이 감시) |
| 3. Probes | 21 | ICMP 에코 코덱 + PendingTable(순수) |
| 3. Probes | 23 | DNSPacket(순수) + DNSProber + 공용 ProbeScheduler(회귀 테스트 포함) |
| 3. Probes | 26 | SystemGuard(잠자기 방지, awdl0 관찰, 디스크, sntp, 위치 권한) |

검증: `cd Packages/WifiDoctorKit && swift test` → Core 109 + Probes 15 + 파서 등 전부 통과, 경고 없음.
모든 작업은 구현 → 독립 리뷰 → 수정 루프를 거쳤다. **전체 브랜치 리뷰(마지막 게이트)는 아직 실행 전** — App 완성 뒤 실행한다.

## 다음 세션: 0단계 스파이크 (사용자 동석 필요)

작업 22(ICMPProber), 24(WirelessMonitor), 25(PathDiscovery)는 스파이크 결과가 구현을 갈랐다.

**사용자가 미리 준비할 것:**
1. USB 이더넷 케이블 연결(가능하면 와이파이와 다른 네트워크, 예: 휴대폰 테더링). 인터페이스 이름은 `networksetup -listallhardwareports`로 확인.
2. 시스템 설정 > 개인정보 보호 및 보안 > 위치 서비스에서 실행 앱(Terminal 등)의 위치 권한이 꺼져 있는지 확인.
3. 스파이크 S2 실행 중 Wi-Fi를 5초간 직접 껐다 켜야 한다.

| 스파이크 | 절차 | 갈림 |
|---|---|---|
| S1 | `Spikes/s1-traceroute-iface.sh <wifi> <wired>` 3회 (`traceroute -i` 고정 여부, Opkts 비교) | A: Process로 traceroute / B: ICMP 소켓+IP_TTL 자체 구현 / C: Topology .unknown |
| S2 | `swift Spikes/s2-cwlan-noauth.swift en0` + Wi-Fi 토글 | A/B/C에 따라 Task 24 기대값·Task 16 locationLimitation 문구 |
| S3 | `swift Spikes/s3-icmp-crosstalk.swift en0 <wired>` | 어느 쪽이든 설계 유지, 교차 수신 시 요약 기록 |

결과는 `docs/verification/2026-10-15-spikes.md`에 표로 기록(스파이크 스크립트는 계획 1~3번 작업에 있다).

## 다음 세션: 나머지 작업

1. **Task 22** ICMPProber — Task 23이 만든 `ProbeScheduler`를 쓴다. **중요: ICMP 전송 계층은 `start()`에서 즉시 `onReady()`를 호출해야 타이머가 무장된다.** `sendDelayUs = max(0, actual − scheduled)` 보장(음수 금지, Task 19 판정).
2. **Task 24** WirelessMonitor — S2 결과에 따라 스모크 기대값 조정. D1: 링크 상태는 `powerOn()`/`interfaceMode()`로 앱 정의(0 off/1 disconnected/2 associated).
3. **Task 25** PathDiscovery — S1 결과 A/B/C 중 택일. 파서는 이미 계획에 있다.
4. **Task 27~32** App(xcodegen, SessionController, LiveView, AnalysisView, ReportView, README). 참고 사항:
   - Task 28: AP 관리 IP 프로버를 중단하면 `pipeline.retireTarget(id:)`를 호출한다(Task 19). 유선이 세션 중 처음 연결되는 경우 interfaceBack은 발생하지 않는다(Task 20 노트).
   - Task 31: 비정상 종료 세션의 열린 끊김은 보고서에서 마지막 프로브 시각 기준으로만 표시(파일은 고치지 않음).
5. **Task 33** 현장 검증 V1~V11(사용자 수행, V10은 24시간).
6. **전체 브랜치 리뷰** → 진행 기록의 Minor 목록 분류 → 완료.

## 컨벤션 (모든 후속 작업에 적용)

- 패키지 명령은 `Packages/WifiDoctorKit`에서. 스모크: `WIFI_DOCTOR_SMOKE=1 WIFI_DOCTOR_WIFI_IF=<bsd> [WIFI_DOCTOR_WIRED_IF=<bsd>] swift test --filter …SmokeTests`.
- Core 격리 grep, 커밋 전 주소 점검(RFC 5737만 허용) — 공개 저장소.
- 커밋 접두어 `feat:/test:/chore:/docs:`(+수정 `fix:`), 끝에 실제 모델명의 `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- 병합·푸시는 사용자 확인 후. GitHub 이슈 #1이 MVP 추적.

## 산출물 규칙

세션 파일(`*.sqlite`), CSV, 보고서 HTML은 커밋하지 않는다(`.gitignore`). 현장 검증 결과는 `docs/verification/`에 표만.
