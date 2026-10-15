import Testing
@testable import WifiDoctorCore

@Suite struct EventGrouperTests {
    let wGw = SyntheticSession.target(id: 1, path: .wifi, role: .gateway)
    let wInet = SyntheticSession.target(id: 2, path: .wifi, role: .internetA)
    let eGw = SyntheticSession.target(id: 3, path: .wired, role: .gateway)
    let eInet = SyntheticSession.target(id: 4, path: .wired, role: .internetA)
    var targets: [Int: ProbeTarget] { [1: wGw, 2: wInet, 3: eGw, 4: eInet] }
    func o(_ id: Int, _ s: Int64, _ e: Int64) -> TargetOutage {
        TargetOutage(targetId: id, startMono: s, endMono: e, lostCount: 4, firstSeq: 0, lastSeq: 3, closedAtEnd: false)
    }
    let S: Int64 = 1_000_000_000

    @Test func wifiOutagesWithin500msMerge() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(2, S + 400_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].startMono == 0); #expect(ev[0].endMono == 2 * S)
    }
    @Test func wifiOutagesBeyond500msSplit() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(2, S + 600_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 2)
    }
    @Test func wiredOutageWithin500msAttaches() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S + 500_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].outages.count == 2); #expect(ev[0].wiredOnly == false)
    }
    @Test func wiredOutageBeyond500msBecomesWiredOnlyEvent() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S + 600_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 2); #expect(ev[1].wiredOnly)
    }
    @Test func wiredAttachDoesNotExtendSeedWindowForOtherWired() {
        // 유선 끊김이 붙어도 사건 창은 와이파이 합집합. 유선 끊김 자체는 outages에 포함.
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, S, 3 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 1); #expect(ev[0].endMono == S)
    }
    @Test func overlapWithSleepIsSuppressed() {
        let ev = EventGrouper.group(outages: [o(1, 10 * S, 11 * S)], targets: targets, sleepIntervals: [(start: 10 * S + 500_000_000, end: 20 * S)])
        #expect(ev[0].suppressed)
    }
    @Test func eventIdsAreSequentialFromFirstEventId() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(1, 5 * S, 6 * S)], targets: targets, sleepIntervals: [], firstEventId: 7)
        #expect(ev.map(\.id) == [7, 8])
    }
    @Test func unattachedWiredOutagesMergeIntoOneWiredOnlyEvent() {
        let ev = EventGrouper.group(outages: [o(1, 0, S), o(3, 3 * S, 4 * S), o(4, 3 * S + 200_000_000, 4 * S + 300_000_000)],
                                    targets: targets, sleepIntervals: [])
        #expect(ev.count == 2)
        #expect(ev[1].wiredOnly); #expect(ev[1].outages.count == 2)
        #expect(ev[1].startMono == 3 * S); #expect(ev[1].endMono == 4 * S + 300_000_000)
    }
    @Test func wiredOutagesBeyond500msStaySeparateWiredOnlyEvents() {
        let ev = EventGrouper.group(outages: [o(3, 0, S), o(4, S + 600_000_000, 2 * S)], targets: targets, sleepIntervals: [])
        #expect(ev.count == 2); #expect(ev.allSatisfy { $0.wiredOnly })
    }
}
