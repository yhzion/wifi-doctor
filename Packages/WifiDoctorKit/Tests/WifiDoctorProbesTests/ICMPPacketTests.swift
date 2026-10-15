import Testing
@testable import WifiDoctorProbes

@Suite struct ICMPPacketTests {
    @Test func echoRequestHasValidChecksum() {
        let p = ICMPPacket.echoRequest(ident: 0x1234, seq: 7)
        #expect(p[0] == 8); #expect(p[1] == 0)
        #expect(ICMPPacket.checksum(p) == 0)                 // 체크섬 포함 전체 합은 0
        #expect(p[4] == 0x12 && p[5] == 0x34); #expect(p[6] == 0 && p[7] == 7)
    }
    @Test func parsesReplyWithIPv4Header() {
        var ip = [UInt8](repeating: 0, count: 20); ip[0] = 0x45; ip[8] = 57 /* ttl */
        ip[16...19] = [192, 0, 2, 20]                          // 목적지
        var icmp = ICMPPacket.echoRequest(ident: 0xBEEF, seq: 3); icmp[0] = 0
        icmp[2] = 0; icmp[3] = 0; let c = ICMPPacket.checksum(icmp); icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
        let r = ICMPPacket.parseReply(ip + icmp)
        #expect(r == ICMPPacket.Reply(ident: 0xBEEF, seq: 3, ttl: 57, destination: "192.0.2.20", type: 0))
    }
    @Test func nonEchoReplyIsNil() {
        var ip = [UInt8](repeating: 0, count: 20); ip[0] = 0x45
        var icmp = [UInt8](repeating: 0, count: 8); icmp[0] = 11
        #expect(ICMPPacket.parseReply(ip + icmp) == nil)
        #expect(ICMPPacket.parseReply([1, 2, 3]) == nil)
    }
    @Test func pendingTableMatchesAndFlagsLate() {
        var t = PendingTable()
        t.sent(seq64: 65_540, tSendMono: 1_000_000_000, sendDelayUs: 5)       // seq16 = 4
        let r = t.reply(seq16: 4, tRecvMono: 1_002_000_000, timeoutNs: 1_000_000_000)
        #expect(r?.seq64 == 65_540); #expect(r?.rttUs == 2_000); #expect(r?.late == false)
        t.sent(seq64: 65_541, tSendMono: 2_000_000_000, sendDelayUs: 0)
        #expect(t.reply(seq16: 5, tRecvMono: 3_100_000_000, timeoutNs: 1_000_000_000)?.late == true)
    }
    @Test func duplicateReplyIgnored() {
        var t = PendingTable()
        t.sent(seq64: 1, tSendMono: 0, sendDelayUs: 0)
        #expect(t.reply(seq16: 1, tRecvMono: 1_000, timeoutNs: 1_000_000_000) != nil)
        #expect(t.reply(seq16: 1, tRecvMono: 2_000, timeoutNs: 1_000_000_000) == nil)
        #expect(t.reply(seq16: 9, tRecvMono: 2_000, timeoutNs: 1_000_000_000) == nil)   // 미송신 seq
    }
    @Test func expireReturnsTimedOutOnly() {
        var t = PendingTable()
        t.sent(seq64: 1, tSendMono: 0, sendDelayUs: 0); t.sent(seq64: 2, tSendMono: 500_000_000, sendDelayUs: 0)
        #expect(t.expire(now: 1_000_000_001, timeoutNs: 1_000_000_000) == [1])
    }
}
