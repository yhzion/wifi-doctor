/// 프로브 결과를 seq 순서대로만 내보낸다. 연속 순번이 채워질 때까지 보관한다.
public struct SeqOrderBuffer: Sendable {
    private var nextSeq: Int64
    private var pending: [Int64: ProbeResult] = [:]

    public init(nextSeq: Int64 = 0) { self.nextSeq = nextSeq }

    public mutating func push(_ r: ProbeResult) -> [ProbeResult] {
        guard r.seq >= nextSeq, pending[r.seq] == nil else { return [] }
        pending[r.seq] = r
        var out: [ProbeResult] = []
        while let next = pending.removeValue(forKey: nextSeq) {
            out.append(next)
            nextSeq += 1
        }
        return out
    }
}
