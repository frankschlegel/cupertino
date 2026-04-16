import Foundation
import Search

// MARK: - Reciprocal Rank Fusion

enum ReciprocalRankFusion {
    private static let defaultK = 60.0

    /// Merge independent ranked result sets without comparing raw scores across indexes.
    /// Results are deduplicated by URI and ranked with Reciprocal Rank Fusion (RRF).
    static func fuse(
        _ resultSets: [[Search.Result]],
        limit: Int,
        k: Double = defaultK
    ) -> [Search.Result] {
        let nonEmptySets = resultSets.filter { !$0.isEmpty }
        guard !nonEmptySets.isEmpty else { return [] }
        guard nonEmptySets.count > 1 else { return Array(nonEmptySets[0].prefix(limit)) }

        struct Aggregate {
            var representative: Search.Result
            var reciprocalScore: Double
            var bestPosition: Int
        }

        var aggregates: [String: Aggregate] = [:]
        aggregates.reserveCapacity(nonEmptySets.reduce(0) { $0 + $1.count })

        for results in nonEmptySets {
            for (zeroBasedIndex, result) in results.enumerated() {
                let position = zeroBasedIndex + 1
                let contribution = 1.0 / (k + Double(position))

                if var aggregate = aggregates[result.uri] {
                    aggregate.reciprocalScore += contribution
                    if position < aggregate.bestPosition {
                        aggregate.bestPosition = position
                        aggregate.representative = result
                    }
                    aggregates[result.uri] = aggregate
                } else {
                    aggregates[result.uri] = Aggregate(
                        representative: result,
                        reciprocalScore: contribution,
                        bestPosition: position
                    )
                }
            }
        }

        let fused = aggregates.values.map { aggregate in
            let result = aggregate.representative
            return Search.Result(
                id: result.id,
                uri: result.uri,
                source: result.source,
                framework: result.framework,
                title: result.title,
                summary: result.summary,
                filePath: result.filePath,
                wordCount: result.wordCount,
                rank: -aggregate.reciprocalScore,
                availability: result.availability,
                matchedSymbols: result.matchedSymbols
            )
        }

        return Array(fused.sorted { $0.rank < $1.rank }.prefix(limit))
    }
}
