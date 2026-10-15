/// ICMP 에코 패킷 조립·해석. 순수 논리 — 소켓 없음(RFC 792).
/// macOS SOCK_DGRAM IPPROTO_ICMP는 recvfrom에 IPv4 헤더 + ICMP 본문을 실어 주고
/// 식별자는 송신 그대로 돌아온다(설계 §7.1).
enum ICMPPacket {
    /// 에코 요청(type 8/code 0). 체크섬을 채워 돌려준다.
    static func echoRequest(ident: UInt16, seq: UInt16, payload: [UInt8] = Array(repeating: 0, count: 32)) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 8 + payload.count)
        packet[0] = 8   // type: echo request
        packet[1] = 0   // code
        packet[4] = UInt8(ident >> 8); packet[5] = UInt8(ident & 0xff)
        packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)
        packet.replaceSubrange(8..., with: payload)
        let c = checksum(packet)   // 체크섬 필드(0) 포함 계산
        packet[2] = UInt8(c >> 8); packet[3] = UInt8(c & 0xff)
        return packet
    }

    struct Reply: Equatable {
        var ident: UInt16
        var seq: UInt16
        var ttl: Int
        var destination: String
        var type: UInt8
    }

    /// 수신 버퍼(IPv4 헤더 포함)를 해석. ICMP 에코 응답(type 0)이 아니면 nil.
    static func parseReply(_ bytes: [UInt8]) -> Reply? {
        guard bytes.count >= 28 else { return nil }   // IPv4 헤더 20 + ICMP 헤더 8 최소
        let headerLen = Int(bytes[0] & 0x0f) * 4
        guard bytes.count >= headerLen + 8 else { return nil }
        let type = bytes[headerLen]
        guard type == 0 else { return nil }           // 에코 응답만
        return Reply(
            ident: UInt16(bytes[headerLen + 4]) << 8 | UInt16(bytes[headerLen + 5]),
            seq: UInt16(bytes[headerLen + 6]) << 8 | UInt16(bytes[headerLen + 7]),
            ttl: Int(bytes[8]),
            destination: "\(bytes[16]).\(bytes[17]).\(bytes[18]).\(bytes[19])",
            type: type
        )
    }

    /// 16비트 1의 보수 합 체크섬(RFC 1071). 올림 접기, 홀수 길이는 0 패딩.
    /// 체크섬이 유효한 패킷에 다시 적용하면 0이 나온다.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

/// 대상별 pending 송신 기록. 응답 짝 맞추기와 시간 초과.
/// seq64는 송신측 전체 일련번호, seq16는 ICMP 헤더에 실리는 하위 16비트.
/// 시간 초과 마감은 tSendMono + sendDelayUs*1000 + timeoutNs — 실제 송신이
/// 예정 시각보다 sendDelayUs 늦었으면 그만큼 창을 밀어준다.
/// rttUs는 예정 송신 시각 기준으로 잰다(Core의 scheduled send 시각 규약).
struct PendingTable {
    private struct Entry {
        var seq64: Int64
        var tSendMono: Int64
        var sendDelayUs: Int64

        func deadlineNs(timeoutNs: Int64) -> Int64 { tSendMono + sendDelayUs * 1000 + timeoutNs }
    }

    private var bySeq16: [UInt16: Entry] = [:]
    /// 송신(tSendMono) 순 seq16. expire 검사용.
    private var order: [UInt16] = []

    mutating func sent(seq64: Int64, tSendMono: Int64, sendDelayUs: Int64) {
        let seq16 = UInt16(truncatingIfNeeded: seq64)
        if bySeq16[seq16] != nil { order.removeAll { $0 == seq16 } }   // 16비트 겹침은 새 기록으로
        bySeq16[seq16] = Entry(seq64: seq64, tSendMono: tSendMono, sendDelayUs: sendDelayUs)
        order.append(seq16)
    }

    /// 응답 짝 맞추기. pending이 없으면(중복·미송신·이미 만료) nil.
    /// late여도 pending에서 제거하고 돌려준다(호출자가 .late로 기록).
    mutating func reply(seq16: UInt16, tRecvMono: Int64, timeoutNs: Int64) -> (seq64: Int64, rttUs: Int64, late: Bool)? {
        guard let entry = bySeq16[seq16] else { return nil }
        bySeq16.removeValue(forKey: seq16)
        order.removeAll { $0 == seq16 }
        return (
            seq64: entry.seq64,
            rttUs: (tRecvMono - entry.tSendMono) / 1000,
            late: tRecvMono > entry.deadlineNs(timeoutNs: timeoutNs)
        )
    }

    /// 시간 초과된 seq64를 송신 순으로 돌려주고 pending에서 지운다.
    mutating func expire(now: Int64, timeoutNs: Int64) -> [Int64] {
        var timedOut: [Int64] = []
        var remaining: [UInt16] = []
        remaining.reserveCapacity(order.count)
        for seq16 in order {
            guard let entry = bySeq16[seq16] else { continue }
            if now > entry.deadlineNs(timeoutNs: timeoutNs) {
                timedOut.append(entry.seq64)
                bySeq16.removeValue(forKey: seq16)
            } else {
                remaining.append(seq16)
            }
        }
        order = remaining
        return timedOut
    }
}
