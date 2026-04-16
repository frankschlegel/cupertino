import Foundation
import Search
@testable import Services
import Testing

@Suite("Reciprocal Rank Fusion", .serialized)
struct ReciprocalRankFusionTests {
    @Test("Fuses result sets by rank position, not raw BM25 values")
    func fusesByPositionNotRawRank() {
        let setA: [Search.Result] = [
            makeResult(uri: "packages://a", title: "A", rank: 999.0),
            makeResult(uri: "packages://b", title: "B", rank: -1000.0),
        ]
        let setB: [Search.Result] = [
            makeResult(uri: "packages://a", title: "A Overlay", rank: 1200.0),
            makeResult(uri: "packages://c", title: "C", rank: -2000.0),
        ]

        let fused = ReciprocalRankFusion.fuse([setA, setB], limit: 10, k: 60)

        #expect(fused.first?.uri == "packages://a")
        #expect(fused.map(\.uri).contains("packages://b"))
        #expect(fused.map(\.uri).contains("packages://c"))
    }

    @Test("Dedupes by URI and enforces limit")
    func dedupesAndLimits() {
        let setA: [Search.Result] = [
            makeResult(uri: "packages://shared", title: "Shared Core", rank: -1.0),
            makeResult(uri: "packages://only-core", title: "Core", rank: -2.0),
        ]
        let setB: [Search.Result] = [
            makeResult(uri: "packages://shared", title: "Shared Overlay", rank: -1.0),
            makeResult(uri: "packages://only-overlay", title: "Overlay", rank: -2.0),
        ]

        let fused = ReciprocalRankFusion.fuse([setA, setB], limit: 2, k: 60)

        #expect(fused.count == 2)
        #expect(fused.filter { $0.uri == "packages://shared" }.count == 1)
    }
}

private extension ReciprocalRankFusionTests {
    func makeResult(uri: String, title: String, rank: Double) -> Search.Result {
        Search.Result(
            uri: uri,
            source: "packages",
            framework: "acme-routing",
            title: title,
            summary: "summary",
            filePath: "/tmp/\(title).md",
            wordCount: 42,
            rank: rank
        )
    }
}
