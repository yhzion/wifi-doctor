/// DNS 조회 패킷 조립·해석. 순수 논리 — 소켓 없음(RFC 1035 §4.1).
enum DNSPacket {
    /// A 레코드 조회. RD=1, QDCOUNT=1. name은 점 표기 라벨(|label| + 바이트)로 인코딩.
    static func query(id: UInt16, name: String = "www.example.com") -> [UInt8] {
        var p: [UInt8] = []
        p.reserveCapacity(12 + name.utf8.count + 6)
        p.append(UInt8(id >> 8)); p.append(UInt8(id & 0xff))
        p.append(0x01); p.append(0x00)                  // flags: RD=1
        p.append(0x00); p.append(0x01)                  // QDCOUNT 1
        p.append(0x00); p.append(0x00)                  // ANCOUNT 0
        p.append(0x00); p.append(0x00)                  // NSCOUNT 0
        p.append(0x00); p.append(0x00)                  // ARCOUNT 0
        for label in name.split(separator: ".") {
            p.append(UInt8(label.utf8.count))
            p.append(contentsOf: label.utf8)
        }
        p.append(0x00)                                  // 루트 라벨(이름 끝)
        p.append(0x00); p.append(0x01)                  // QTYPE A
        p.append(0x00); p.append(0x01)                  // QCLASS IN
        return p
    }

    /// 응답의 트랜잭션 ID. QR 비트가 1(응답)이고 헤더 12바이트가 온전할 때만 읽는다.
    static func responseId(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 12, bytes[2] & 0x80 != 0 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}
