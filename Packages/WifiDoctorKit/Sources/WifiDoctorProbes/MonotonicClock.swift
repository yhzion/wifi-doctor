import Darwin

public enum MonotonicClock {
    /// CLOCK_MONOTONIC_RAW 나노초. 잠자기 중 멈춤.
    public static func nowNs() -> Int64 {
        Int64(bitPattern: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }
}
