/// 6.4절: WIRELESS 판정의 무선 원인 분류.
public struct WirelessClassification: Sendable, Equatable {
    public var cause: WirelessCause?
    public var note: String
    public var baselineRssi: Int?
    public var minRssi: Int?
    public var minSnr: Int?
    public init(cause: WirelessCause?, note: String, baselineRssi: Int?, minRssi: Int?, minSnr: Int?) {
        self.cause = cause
        self.note = note
        self.baselineRssi = baselineRssi
        self.minRssi = minRssi
        self.minSnr = minSnr
    }
}

public enum WirelessClassifier {
    private static let windowLeadNs: Int64 = 3_000_000_000
    private static let baselineSpanNs: Int64 = 60_000_000_000

    /// window = [start − 3초, end]. baseline = [start − 60초, start − 3초).
    public static func classify(start: Int64, end: Int64, samples: [WirelessSample],
                                events: [LinkEvent], thresholds: WirelessThresholds) -> WirelessClassification {
        let windowStart = start - windowLeadNs
        let windowSamples = samples.filter { $0.tMono >= windowStart && $0.tMono <= end }
        let baselineRssis = samples.filter { $0.tMono >= start - baselineSpanNs && $0.tMono < windowStart }
            .compactMap(\.rssiDbm)
        let baselineRssi = median(baselineRssis)
        let minRssi = windowSamples.compactMap(\.rssiDbm).min()
        let minSnr = windowSamples.compactMap(\.snrDb).min()

        guard !windowSamples.isEmpty else {
            return WirelessClassification(cause: nil, note: "무선 샘플 없음", baselineRssi: baselineRssi,
                                          minRssi: nil, minSnr: nil)
        }
        let windowEvents = events.filter { $0.tMono >= windowStart && $0.tMono <= end }
        let numbers = "창 최소 RSSI \(fmt(minRssi)), 최소 SNR \(fmt(minSnr, unit: "dB")), 기준선 \(fmt(baselineRssi))"

        func result(_ cause: WirelessCause, _ reason: String) -> WirelessClassification {
            WirelessClassification(cause: cause, note: "\(reason). \(numbers)", baselineRssi: baselineRssi,
                                   minRssi: minRssi, minSnr: minSnr)
        }
        if windowEvents.contains(where: { $0.kind == .linkDown }) || windowSamples.contains(where: { !$0.isAssociated }) {
            return result(.disconnect, "연결 끊김")
        }
        if windowEvents.contains(where: { $0.kind == .bssidChanged }) {
            return result(.roaming, "BSSID 변경")
        }
        if let m = minRssi, m <= thresholds.rssiFloorDbm { return result(.coverageInterference, "신호 약함") }
        if let s = minSnr, s <= thresholds.snrFloorDb { return result(.coverageInterference, "SNR 낮음") }
        if let b = baselineRssi, let m = minRssi, b - m >= thresholds.rssiDropDb {
            return result(.coverageInterference, "기준선 대비 하락")
        }
        return result(.congestionAp, "신호 양호")
    }

    /// 정렬 후 가운데 값. 짝수면 아래쪽.
    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    private static func fmt(_ v: Int?, unit: String = "dBm") -> String {
        guard let v else { return "없음" }
        return "\(v < 0 ? "−" : "")\(abs(v)) \(unit)"
    }
}
