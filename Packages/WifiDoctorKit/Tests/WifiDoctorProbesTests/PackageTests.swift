import Testing
@testable import WifiDoctorProbes

@Test func monotonicClockIncreases() {
    let a = MonotonicClock.nowNs()
    let b = MonotonicClock.nowNs()
    #expect(b >= a)
    #expect(a > 0)
}
