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
