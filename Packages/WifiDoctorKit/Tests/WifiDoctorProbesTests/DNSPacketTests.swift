import Testing
@testable import WifiDoctorProbes

@Suite struct DNSPacketTests {
    @Test func queryLayout() {
        let q = DNSPacket.query(id: 0xABCD)
        #expect(q[0] == 0xAB && q[1] == 0xCD)
        #expect(q[2] == 0x01 && q[3] == 0x00)        // RD=1
        #expect(q[4] == 0 && q[5] == 1)              // QDCOUNT 1
        #expect(Array(q[12...16]) == [3, 0x77, 0x77, 0x77, 7])   // "www" 길이 3, "example" 길이 7
        #expect(q.suffix(4) == [0, 1, 0, 1])          // QTYPE A, QCLASS IN
    }
    @Test func responseIdReadsFirstTwoBytesOnlyIfQR() {
        #expect(DNSPacket.responseId([0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]) == 0x1234)
        #expect(DNSPacket.responseId([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]) == nil)   // QR=0
        #expect(DNSPacket.responseId([0x12]) == nil)
    }
}
