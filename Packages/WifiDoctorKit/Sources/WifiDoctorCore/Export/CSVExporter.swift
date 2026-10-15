import Foundation

public struct CSVFileInfo: Sendable, Equatable {
    public var name: String
    public var rows: Int
    public init(name: String, rows: Int) {
        self.name = name
        self.rows = rows
    }
}

public enum CSVExporter {
    /// 8개 파일. 각 행에 t_mono와 t_wall_ms(앵커 변환) 둘 다 기록. 앵커가 없으면 t_wall_ms는 빈 칸.
    public static func export(reader: SessionReader, to dir: URL) throws -> [CSVFileInfo] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anchors = try reader.anchors()
        func wall(_ mono: Int64) -> String {
            anchors.isEmpty ? "" : String(ClockAnchor.wallMs(forMono: mono, anchors: anchors))
        }
        func num<T: BinaryInteger>(_ v: T?) -> String { v.map { String($0) } ?? "" }
        func str(_ v: String?) -> String { v.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" } ?? "" }

        var infos: [CSVFileInfo] = []

        let probe = try CSVFile(dir: dir, name: "probe.csv", header: "target_id,seq,t_send_mono,t_wall_ms,send_delay_us,rtt_us,status,ttl")
        try reader.forEachProbe { p in
            try probe.row([num(p.targetId), num(p.seq), num(p.tSendMono), wall(p.tSendMono), num(p.sendDelayUs),
                           num(p.rttUs), num(p.status.rawValue), num(p.ttl)])
        }
        infos.append(try probe.close())

        let wireless = try CSVFile(dir: dir, name: "wireless_sample.csv",
                                   header: "t_mono,t_wall_ms,state,rssi_dbm,noise_dbm,tx_rate_mbps,channel,band,width_mhz,bssid,ssid")
        for s in try reader.wirelessSamples(fromMono: .min, toMono: .max) {
            try wireless.row([num(s.tMono), wall(s.tMono), num(s.state.rawValue), num(s.rssiDbm), num(s.noiseDbm),
                              s.txRateMbps.map { String($0) } ?? "", num(s.channel), num(s.band), num(s.widthMhz),
                              str(s.bssid), str(s.ssid)])
        }
        infos.append(try wireless.close())

        let link = try CSVFile(dir: dir, name: "link_event.csv", header: "t_mono,t_wall_ms,kind,detail")
        for e in try reader.linkEvents() { try link.row([num(e.tMono), wall(e.tMono), str(e.kind.rawValue), str(e.detail)]) }
        infos.append(try link.close())

        let system = try CSVFile(dir: dir, name: "system_event.csv", header: "t_mono,t_wall_ms,kind,detail")
        for e in try reader.systemEvents() { try system.row([num(e.tMono), wall(e.tMono), str(e.kind.rawValue), str(e.detail)]) }
        infos.append(try system.close())

        let anchorFile = try CSVFile(dir: dir, name: "clock_anchor.csv", header: "t_mono,t_wall_ms")
        for a in anchors { try anchorFile.row([num(a.tMono), num(a.tWallMs)]) }
        infos.append(try anchorFile.close())

        let hop = try CSVFile(dir: dir, name: "hop.csv", header: "path,run,hop_index,address,rtt_ms,t_mono,t_wall_ms")
        for l in try reader.hops() {
            for h in l.hops {
                try hop.row([str(l.path.rawValue), num(l.run), num(h.index), str(h.address), h.rttMs.map { String($0) } ?? "",
                             num(l.tMono), wall(l.tMono)])
            }
        }
        infos.append(try hop.close())

        let outage = try CSVFile(dir: dir, name: "outage.csv",
                                 header: "id,event_id,target_id,start_mono,t_wall_ms,end_mono,lost_count,first_seq,last_seq,closed_at_end")
        for r in try reader.outageRows() {
            let o = r.outage
            try outage.row([num(r.id), num(r.eventId), num(o.targetId), num(o.startMono), wall(o.startMono), num(o.endMono), num(o.lostCount),
                            num(o.firstSeq), num(o.lastSeq), o.closedAtEnd ? "1" : "0"])
        }
        infos.append(try outage.close())

        let verdict = try CSVFile(dir: dir, name: "verdict.csv",
                                  header: "event_id,segment,wireless_cause,confidence,reason_code,reason,evidence")
        for v in try reader.verdicts() {
            try verdict.row([num(v.eventId), str(v.segment.rawValue), str(v.wirelessCause?.rawValue),
                             str(v.confidence.rawValue), str(v.reasonCode), str(v.reason), str(v.evidence)])
        }
        infos.append(try verdict.close())

        return infos
    }
}

/// 헤더를 쓰고 행을 모아 64KB마다 파일에 내려 쓰는 스트리밍 CSV 파일.
private final class CSVFile {
    private let name: String
    private let handle: FileHandle
    private var buffer = Data()
    private var rows = 0

    init(dir: URL, name: String, header: String) throws {
        self.name = name
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.append(Data((header + "\n").utf8))
    }

    func row(_ fields: [String]) throws {
        buffer.append(Data((fields.joined(separator: ",") + "\n").utf8))
        rows += 1
        if buffer.count >= 65_536 { try drain() }
    }

    private func drain() throws {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws -> CSVFileInfo {
        try drain()
        try handle.close()
        return CSVFileInfo(name: name, rows: rows)
    }
}
