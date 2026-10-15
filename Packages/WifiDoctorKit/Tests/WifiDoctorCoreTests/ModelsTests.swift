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
