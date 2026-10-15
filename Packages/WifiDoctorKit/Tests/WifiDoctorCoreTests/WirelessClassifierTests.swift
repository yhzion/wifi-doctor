import Testing
@testable import WifiDoctorCore

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
