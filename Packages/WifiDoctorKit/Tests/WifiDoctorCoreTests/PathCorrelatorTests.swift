import Testing
@testable import WifiDoctorCore

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
