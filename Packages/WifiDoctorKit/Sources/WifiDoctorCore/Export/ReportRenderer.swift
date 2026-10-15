import Foundation

public enum ReportRenderer {
    private static let timeFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    public static func render(_ m: ReportModel) -> String {
        let r = Renderer(m: m)
        return r.html()
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private struct Renderer {
        let m: ReportModel
        let formatter: DateFormatter

        init(m: ReportModel) {
            self.m = m
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = ReportRenderer.timeFormat
            formatter = f
        }

        func wall(_ ms: Int64) -> String {
            formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        func wallMono(_ t: Int64) -> String { wall(m.wallMs(forMono: t)) }
        func seconds(_ ms: Int64) -> String { String(format: "%.3f", Double(ms) / 1000) }
        func td(_ s: String) -> String { "<td>\(esc(s))</td>" }
        func th(_ s: String) -> String { "<th>\(esc(s))</th>" }
        func table(_ head: [String], _ rows: [[String]]) -> String {
            var s = "<table><thead><tr>\(head.map(th).joined())</tr></thead><tbody>"
            for r in rows { s += "<tr>\(r.map(td).joined())</tr>" }
            return s + "</tbody></table>\n"
        }

        func html() -> String {
            """
            <!DOCTYPE html>
            <html lang="ko"><head><meta charset="utf-8">
            <title>Wi-Fi Doctor 보고서</title>
            <style>
            body{font-family:-apple-system,Helvetica,Arial,sans-serif;margin:24px auto;max-width:960px;padding:0 16px;color:#222;line-height:1.5}
            h1{font-size:22px}h2{font-size:18px;border-bottom:1px solid #ccc;padding-bottom:4px;margin-top:32px}h3{font-size:15px}
            table{border-collapse:collapse;margin:8px 0;font-size:13px}th,td{border:1px solid #bbb;padding:3px 8px;text-align:left}
            th{background:#f0f0f0}.warn{background:#fff3cd;padding:6px 10px;border:1px solid #e0c060}
            code{background:#f4f4f4;padding:0 3px}svg{max-width:100%;height:auto;border:1px solid #ddd}
            </style></head><body>
            <h1>Wi-Fi Doctor 보고서</h1>
            \(summary())\(basis())\(methodology())\(representativeSection())\(allEvents())\(attachmentsSection())
            </body></html>

            """
        }

        // MARK: 1. 요약
        func summary() -> String {
            var s = "<h2>1. 요약</h2>\n"
            if m.abnormalEnd { s += "<p class=\"warn\"><strong>비정상 종료된 세션</strong>입니다. 세션 종료 시각이 기록되지 않았습니다.</p>\n" }
            s += "<p>시각 표기: 이 Mac의 현재 시간대(\(esc(TimeZone.current.identifier))), 형식 \(esc(ReportRenderer.timeFormat))</p>\n"
            s += "<p>측정 기간: \(esc(wall(m.periodWallMs.start))) ~ \(esc(wall(m.periodWallMs.end)))</p>\n"
            s += "<p>총 사건 수: \(m.countedEvents.count) (HOST_STALL과 suppressed 사건 제외)</p>\n"
            if let l = m.longestEvent {
                s += "<p>최장 끊김: 사건 \(l.id), \(l.durationMs) ms, 시작 \(esc(wallMono(l.startMono)))</p>\n"
            } else {
                s += "<p>최장 끊김: 없음</p>\n"
            }
            let hours = m.perHourCountOver1s.sorted { $0.key < $1.key }
            s += "<p>1초 이상 사건의 시간대별 횟수</p>\n"
            s += hours.isEmpty ? "<p>없음</p>\n"
                : table(["시간대 시작", "건수"], hours.map { [wall($0.key), String($0.value)] })
            s += "<p>길이 구간별 횟수</p>\n"
            s += table(["구간(초)", "건수"], DurationBucket.allCases.map { [$0.rawValue, String(m.bucketHistogram[$0] ?? 0)] })
            s += "<p>판정 ID별 횟수</p>\n"
            let segs = Segment.allCases.compactMap { seg in m.segmentCounts[seg].map { [seg.rawValue, String($0)] } }
            s += segs.isEmpty ? "<p>없음</p>\n" : table(["판정 ID", "건수"], segs)
            s += "<p>\(esc(m.topSegmentSentence))</p>\n"
            return s
        }

        // MARK: 2. 판정 근거
        func basis() -> String {
            var s = "<h2>2. 판정 근거</h2>\n"
            s += "<p>판정은 결정표(설계 6.3절)로 정합니다. 사건 창에서 무선 경로(Wi-Fi 게이트웨이), 유선 경로 대조군, 인터넷 대상의 응답 여부를 비교합니다. 각 사건의 판정과 근거는 5번 표에 있습니다.</p>\n"
            s += "<p>경로 구조(Topology): \(esc(topologyName()))</p>\n"
            s += "<p>\(esc(m.topologyCaveat))</p>\n"
            s += "<h3>두 경로의 홉 목록</h3>\n"
            var rows: [[String]] = []
            for l in m.hops.sorted(by: { ($0.path.rawValue, $0.run, $0.tMono) < ($1.path.rawValue, $1.run, $1.tMono) }) {
                for h in l.hops {
                    rows.append([l.path.rawValue, String(l.run), wallMono(l.tMono), String(h.index),
                                 h.address ?? "*", h.rttMs.map { String(format: "%.2f", $0) } ?? "-"])
                }
            }
            s += rows.isEmpty ? "<p>홉 목록이 없습니다.</p>\n"
                : table(["경로", "실행", "측정 시각", "홉", "주소", "RTT(ms)"], rows)
            if m.segmentCounts[.sharedAccess] ?? 0 > 0 {
                s += "<p>SHARED_ACCESS: 와이파이 게이트웨이와 유선 게이트웨이는 서로 다른 장비인데 같은 창에서 둘 다 응답하지 않았습니다. 경로 추적상 두 경로는 \(esc(mergeHopText()))에서 만나므로 합류 지점 장애로는 설명되지 않습니다. 가능한 원인은 (1) 경로 추적에 보이지 않는 공유 L2 장비(예: 두 포트가 같은 액세스 스위치), (2) 서로 무관한 두 장애의 우연한 겹침입니다. 이 사건이 반복되면 (1)의 가능성이 커집니다. 이 세션에서의 반복 횟수: \(m.sharedAccessRepeatCount)회.</p>\n"
            }
            return s
        }

        func topologyName() -> String {
            switch m.topology {
            case .sameFirstHop: return "sameFirstHop (첫 홉 동일)"
            case .mergedLater(let w, let e): return "mergedLater (와이파이 홉 \(w), 유선 홉 \(e)에서 합류)"
            case .noMerge: return "noMerge (20홉 안에서 합류하지 않음)"
            case .unknown: return "unknown (경로 탐지 실패)"
            }
        }
        func mergeHopText() -> String {
            if case .mergedLater(let w, let e) = m.topology { return "와이파이 홉 \(w), 유선 홉 \(e)" }
            return "합류 홉(기록 없음)"
        }

        // MARK: 3. 방법론
        func methodology() -> String {
            var s = "<h2>3. 방법론</h2>\n<h3>프로브 대상</h3>\n"
            s += table(["target_id", "경로", "역할", "주소", "종류", "주기(ms)", "시간 초과(ms)"],
                       m.targets.map { [String($0.id), $0.path.rawValue, $0.role.rawValue, $0.address,
                                        $0.kind.rawValue, String($0.intervalMs), String($0.timeoutMs)] })
            s += "<p>DNS 프로브는 www.example.com을 리졸버에 묻습니다. 리졸버는 캐시에서 답합니다. 이 프로브는 리졸버까지의 경로와 리졸버 생존을 봅니다. 재귀 해석 성능은 보지 않습니다.</p>\n"
            s += "<h3>끊김 정의</h3>\n"
            s += "<p>대상 끊김은 한 대상에서 연속 손실 묶음의 길이 k가 2 이상이고 k × 주기가 0.2초 이상인 구간입니다. 손실은 timeout, late, send_error, unreachable입니다. k = 1인 손실은 끊김이 아니며 손실률 통계에만 들어갑니다. 시작은 첫 손실의 송신 시각, 끝은 마지막 손실의 송신 시각에 주기를 더한 시각입니다. 시간이 겹치는 대상 끊김은 사건 하나로 묶습니다(병합 간격 0.5초).</p>\n"
            s += "<h3>인터페이스 고정</h3>\n"
            s += "<p>인터페이스 고정: ICMP는 <code>IP_BOUND_IF</code>, DNS는 <code>NWParameters.requiredInterface</code>.</p>\n"
            s += "<h3>권한</h3>\n<p>앱은 관리자 권한 없이 실행됨.</p>\n"
            s += "<p>위치 권한 상태: \(esc(m.meta.locationAuth))</p>\n"
            if let l = m.locationLimitation { s += "<p>\(esc(l))</p>\n" }
            s += "<h3>awdl0 상태 이력</h3>\n"
            s += "<p>앱은 awdl0를 바꾸지 않고 상태만 기록합니다.</p>\n"
            s += m.awdl0History.isEmpty ? "<p>기록 없음</p>\n"
                : table(["시각", "상태"], m.awdl0History.map { [wallMono($0.tMono), $0.detail ?? ""] })
            s += "<h3>스캔</h3>\n<p>앱은 스캔을 하지 않았고, OS 스캔 캐시 갱신 이벤트는 \(m.scanCacheUpdateCount)회 기록됨.</p>\n"
            s += "<h3>시계 동기</h3>\n<p>sntp 시작: \(esc(m.meta.sntpStart ?? "기록 없음"))</p>\n<p>sntp 종료: \(esc(m.meta.sntpEnd ?? "기록 없음"))</p>\n"
            s += "<h3>앵커 점프</h3>\n"
            s += m.anchorJumps.isEmpty ? "<p>없음</p>\n"
                : table(["이전 앵커 벽시계", "다음 앵커 벽시계", "점프(ms)"],
                        m.anchorJumps.map { [wall($0.fromAnchor.tWallMs), wall($0.toAnchor.tWallMs), String($0.jumpMs)] })
            s += "<h3>잠자기 구간</h3>\n"
            s += m.sleepIntervals.isEmpty ? "<p>없음</p>\n"
                : table(["시작", "끝"], m.sleepIntervals.map { [wallMono($0.start), wallMono($0.end)] })
            s += "<h3>측정 호스트 건전성</h3>\n"
            let p = m.probeStats
            s += table(["항목", "값"], [
                ["프로브 수", String(p.count)],
                ["send_delay_us p50", String(p.sendDelayP50Us)],
                ["send_delay_us p99", String(p.sendDelayP99Us)],
                ["send_delay_us 최댓값", String(p.sendDelayMaxUs)],
                ["late 응답 비율", String(format: "%.4f%% (%lld/%lld)", m.lateRatio * 100, p.lateCount, p.count)],
                ["HOST_STALL 사건 수", String(m.hostStallEvents.count)],
            ])
            if !m.hostStallEvents.isEmpty {
                s += table(["사건", "시작", "끝", "길이(ms)"],
                           m.hostStallEvents.map { [String($0.id), wallMono($0.startMono), wallMono($0.endMono), String($0.durationMs)] })
            }
            s += "<p>이 사건들은 맥 자체 지연으로 판정되어 아래 통계에서 제외됨</p>\n"
            if !m.suppressedEvents.isEmpty {
                s += "<p>잠자기 등으로 제외된(suppressed) 사건: \(m.suppressedEvents.count)건</p>\n"
            }
            return s
        }

        // MARK: 4. 대표 끊김
        func representativeSection() -> String {
            var s = "<h2>4. 대표 끊김 확대 그림</h2>\n"
            if m.representative.isEmpty { return s + "<p>대표 사건이 없습니다.</p>\n" }
            s += "<p>가로축은 시간(사건 시작 10초 전부터 끝 10초 후까지)입니다. 점은 프로브입니다. 회색은 응답, 빨강은 손실입니다. 파란 선은 RSSI입니다. 반투명 사각형은 사건 창입니다.</p>\n"
            for (i, rep) in m.representative.enumerated() {
                let e = rep.event
                s += "<h3>\(i == 0 ? "가장 긴 사건" : "가장 흔한 판정의 중앙값 사건"): 사건 \(e.id)</h3>\n"
                s += "<p>\(esc(wallMono(e.startMono))) ~ \(esc(wallMono(e.endMono))), \(e.durationMs) ms"
                if let v = rep.verdict { s += ", 판정 \(esc(v.segment.rawValue))" }
                s += "</p>\n" + svg(rep)
            }
            return s
        }

        func svg(_ rep: RepresentativeEvent) -> String {
            let margin: Int64 = 10_000_000_000
            let t0 = rep.event.startMono - margin, t1 = rep.event.endMono + margin
            let left = 190.0, right = 20.0, width = 900.0, plotW = width - left - right
            let rssiH = 80.0, rowH = 24.0, top = 10.0
            let rows = m.targets.filter { t in rep.probes.contains { $0.targetId == t.id } }
            let height = top + rssiH + 10 + rowH * Double(rows.count) + 30
            func x(_ t: Int64) -> Double { left + Double(t - t0) / Double(t1 - t0) * plotW }
            func f(_ d: Double) -> String { String(format: "%.1f", d) }
            var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"900\" height=\"\(f(height))\" viewBox=\"0 0 900 \(f(height))\" font-size=\"11\" font-family=\"sans-serif\">\n"
            s += "<rect x=\"\(f(x(rep.event.startMono)))\" y=\"\(f(top))\" width=\"\(f(max(1, x(rep.event.endMono) - x(rep.event.startMono))))\" height=\"\(f(height - top - 30))\" fill=\"#f4a000\" fill-opacity=\"0.25\"/>\n"
            // RSSI 띠: -100 ~ -30 dBm
            s += "<rect x=\"\(f(left))\" y=\"\(f(top))\" width=\"\(f(plotW))\" height=\"\(f(rssiH))\" fill=\"none\" stroke=\"#ccc\"/>\n"
            s += "<text x=\"4\" y=\"\(f(top + 12))\">RSSI (dBm)</text>\n"
            s += "<text x=\"\(f(left - 4))\" y=\"\(f(top + 10))\" text-anchor=\"end\">-30</text>\n"
            s += "<text x=\"\(f(left - 4))\" y=\"\(f(top + rssiH))\" text-anchor=\"end\">-100</text>\n"
            let pts = rep.samples.compactMap { smp -> String? in
                guard let r = smp.rssiDbm, smp.tMono >= t0, smp.tMono <= t1 else { return nil }
                let c = min(-30.0, max(-100.0, Double(r)))
                return "\(f(x(smp.tMono))),\(f(top + (-30.0 - c) / 70.0 * rssiH))"
            }
            if !pts.isEmpty {
                s += "<polyline points=\"\(pts.joined(separator: " "))\" fill=\"none\" stroke=\"#1f5fbf\" stroke-width=\"1.5\"/>\n"
            }
            for (i, t) in rows.enumerated() {
                let cy = top + rssiH + 10 + rowH * (Double(i) + 0.5)
                s += "<line x1=\"\(f(left))\" y1=\"\(f(cy))\" x2=\"\(f(left + plotW))\" y2=\"\(f(cy))\" stroke=\"#e6e6e6\"/>\n"
                s += "<text x=\"4\" y=\"\(f(cy + 4))\">\(esc("#\(t.id) \(t.role.rawValue) \(t.path.rawValue)"))</text>\n"
                for p in rep.probes where p.targetId == t.id && p.tSendMono >= t0 && p.tSendMono <= t1 {
                    s += "<circle cx=\"\(f(x(p.tSendMono)))\" cy=\"\(f(cy))\" r=\"2\" fill=\"\(p.status.isLost ? "#d00000" : "#888888")\"/>\n"
                }
            }
            let axisY = height - 14
            s += "<text x=\"\(f(left))\" y=\"\(f(axisY))\">\(esc(wallMono(t0)))</text>\n"
            s += "<text x=\"\(f(left + plotW))\" y=\"\(f(axisY))\" text-anchor=\"end\">\(esc(wallMono(t1)))</text>\n"
            return s + "</svg>\n"
        }

        // MARK: 5. 끊김 전체 표
        func allEvents() -> String {
            var s = "<h2>5. 끊김 전체 표</h2>\n"
            if m.countedEvents.isEmpty { return s + "<p>사건이 없습니다.</p>\n" }
            s += table(["시각", "길이(초)", "판정", "무선 원인", "신뢰도", "근거 요약"], m.countedEvents.map { e in
                let v = m.verdictsByEvent[e.id]
                return [wallMono(e.startMono), seconds(e.durationMs), v?.segment.rawValue ?? "-",
                        v?.wirelessCause?.rawValue ?? "-", v?.confidence.rawValue ?? "-", v?.reason ?? "-"]
            })
            return s
        }

        // MARK: 6. 첨부
        func attachmentsSection() -> String {
            var s = "<h2>6. 첨부 목록</h2>\n"
            s += table(["CSV 파일", "행 수"], m.attachments.map { [$0.name, String($0.rows)] })
            s += "<p>세션 파일: \(esc(m.sessionFileName))</p>\n<p>SHA-256: \(esc(m.sessionSha256))</p>\n"
            if let n = m.meta.notes, !n.isEmpty { s += "<p>메모: \(esc(n))</p>\n" }
            return s
        }
    }
}
