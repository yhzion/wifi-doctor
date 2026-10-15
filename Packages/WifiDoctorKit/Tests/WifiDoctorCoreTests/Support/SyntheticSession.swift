import Foundation
@testable import WifiDoctorCore

enum SyntheticSession {
    static func target(id: Int, path: NetPath, role: TargetRole) -> ProbeTarget {
        let address: String
        let kind: ProbeKind
        let intervalMs: Int
        switch role {
        case .gateway: address = "192.0.2.1"; kind = .icmp; intervalMs = 50
        case .apMgmt: address = "192.0.2.2"; kind = .icmp; intervalMs = 50
        case .internetA: address = "203.0.113.1"; kind = .icmp; intervalMs = 200
        case .internetB: address = "198.51.100.1"; kind = .icmp; intervalMs = 200
        case .dns: address = "203.0.113.1"; kind = .dns; intervalMs = 200
        }
        return ProbeTarget(id: id, path: path, role: role, address: address, kind: kind, intervalMs: intervalMs)
    }

    static func probes(target: ProbeTarget, startNs: Int64, count: Int, lostSeqs: Set<Int64>,
                       delayedSeqs: [Int64: Int64] = [:], lateSeqs: Set<Int64> = []) -> [ProbeResult] {
        (0..<Int64(count)).map { seq in
            let delayUs = delayedSeqs[seq] ?? 0
            let status: ProbeStatus = lostSeqs.contains(seq) ? .timeout : (lateSeqs.contains(seq) ? .late : .ok)
            let rttUs: Int64? = switch status {
            case .ok: 1000
            case .late: 1_200_000
            default: nil
            }
            return ProbeResult(targetId: target.id, seq: seq,
                               tSendMono: startNs + seq * target.intervalNs + delayUs * 1000,
                               sendDelayUs: delayUs, rttUs: rttUs, status: status, ttl: nil)
        }
    }

    static func samples(startNs: Int64, count: Int, rssi: (Int) -> Int, noise: Int = -90,
                        state: WirelessLinkState = .associated) -> [WirelessSample] {
        (0..<count).map { i in
            WirelessSample(tMono: startNs + Int64(i) * 200_000_000, state: state, rssiDbm: rssi(i),
                           noiseDbm: noise, txRateMbps: nil, channel: nil, band: nil, widthMhz: nil,
                           bssid: nil, ssid: nil)
        }
    }
}
