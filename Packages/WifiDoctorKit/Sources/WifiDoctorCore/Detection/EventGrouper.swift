import Foundation

public enum EventGrouper {
    public static let mergeGapNs: Int64 = 500_000_000

    public static func group(outages: [TargetOutage],
                             targets: [Int: ProbeTarget],
                             sleepIntervals: [(start: Int64, end: Int64)],
                             firstEventId: Int = 1) -> [OutageEvent] {
        let sorted = outages.sorted { $0.startMono < $1.startMono }
        let wifi = sorted.filter { targets[$0.targetId]?.path == .wifi }
        let wired = sorted.filter { targets[$0.targetId]?.path == .wired }

        func near(_ aStart: Int64, _ aEnd: Int64, _ bStart: Int64, _ bEnd: Int64) -> Bool {
            aStart <= bEnd + mergeGapNs && bStart <= aEnd + mergeGapNs
        }

        var events: [OutageEvent] = []
        for out in wifi {
            if let last = events.indices.last,
               near(events[last].startMono, events[last].endMono, out.startMono, out.endMono) {
                events[last].endMono = max(events[last].endMono, out.endMono)
                events[last].outages.append(out)
            } else {
                events.append(OutageEvent(id: 0, startMono: out.startMono, endMono: out.endMono,
                                          suppressed: false, wiredOnly: false, outages: [out]))
            }
        }

        let wifiEventCount = events.count
        for out in wired {
            if let i = events[..<wifiEventCount].firstIndex(where: {
                near($0.startMono, $0.endMono, out.startMono, out.endMono)
            }) {
                events[i].outages.append(out)
            } else if let last = events.indices.last, last >= wifiEventCount,
                      near(events[last].startMono, events[last].endMono, out.startMono, out.endMono) {
                events[last].endMono = max(events[last].endMono, out.endMono)
                events[last].outages.append(out)
            } else {
                events.append(OutageEvent(id: 0, startMono: out.startMono, endMono: out.endMono,
                                          suppressed: false, wiredOnly: true, outages: [out]))
            }
        }

        events.sort { $0.startMono < $1.startMono }
        for i in events.indices {
            events[i].id = firstEventId + i
            let s = events[i].startMono, e = events[i].endMono
            events[i].suppressed = sleepIntervals.contains { $0.start <= e && s <= $0.end }
        }
        return events
    }
}
