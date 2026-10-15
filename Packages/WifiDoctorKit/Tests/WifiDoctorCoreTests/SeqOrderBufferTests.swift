import Testing
@testable import WifiDoctorCore

@Suite struct SeqOrderBufferTests {
    func r(_ seq: Int64, _ s: ProbeStatus) -> ProbeResult {
        ProbeResult(targetId: 1, seq: seq, tSendMono: seq * 50_000_000, sendDelayUs: 0, rttUs: s == .ok ? 1000 : nil, status: s, ttl: nil)
    }
    @Test func releasesInSeqOrderWhenResolvedOutOfOrder() {
        var b = SeqOrderBuffer(nextSeq: 1)
        #expect(b.push(r(1, .ok)).map(\.seq) == [1])
        #expect(b.push(r(3, .ok)).isEmpty)          // 2는 아직 시간 초과 대기
        #expect(b.push(r(4, .ok)).isEmpty)
        #expect(b.push(r(2, .timeout)).map(\.seq) == [2, 3, 4])
    }
    @Test func duplicateSeqIsDropped() {
        var b = SeqOrderBuffer(nextSeq: 1)
        _ = b.push(r(1, .ok))
        #expect(b.push(r(1, .ok)).isEmpty)
    }
}
