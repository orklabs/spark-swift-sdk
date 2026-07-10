import Foundation

/// Outcome of a leaf consolidation run. `feeSats` is MEASURED (total before
/// minus total after) rather than assumed — SSP swaps are requested with
/// fee_sats 0 today, and this surfaces it if that ever changes.
public struct SparkLeafConsolidation: Sendable {
    public let leavesBefore: Int
    public let leavesAfter: Int
    public let totalSatsBefore: Int64
    public let totalSatsAfter: Int64
    public let rounds: Int
    /// Leaves whose refund timelock is exhausted — they cannot move off-chain
    /// until the operators renew them, so consolidation skips them. They stay
    /// fully exitable via the recovery bundle.
    public let skippedLeaves: Int

    public var feeSats: Int64 { totalSatsBefore - totalSatsAfter }
}

extension SparkWallet {
    /// Swap the wallet's leaves toward the fewest denominations (the binary
    /// decomposition of the total — same greedy power-of-two shape blink's
    /// exit tooling consolidates toward). Fewer leaves = a recovery bundle
    /// that is kilobytes instead of megabytes, and a unilateral exit that
    /// costs a handful of transaction chains instead of one per dust leaf.
    ///
    /// Off-chain and instant: each round is an atomic SSP leaf swap (the same
    /// mechanism sends already use for denominations), requested with
    /// fee_sats 0. Requires operators online — this is maintenance, not the
    /// emergency path. Batched so a very fragmented wallet never swaps more
    /// than `maxLeavesPerRound` leaves in one request.
    public func consolidateLeaves(maxLeavesPerRound: Int = 100) async throws -> SparkLeafConsolidation {
        // Un-freeze what we can first: renewal resets low refund timelocks so
        // those leaves can join the swap instead of being skipped. Best-effort —
        // a failed renewal just leaves that leaf in the skipped bucket.
        _ = try? await renewExhaustedLeaves()

        var current = try await getLeaves()
        let leavesBefore = current.count
        let totalBefore = current.reduce(0 as Int64) { $0 + $1.valueSats }

        // Leaves at the timelock floor cannot be swapped until renewed —
        // consolidate around them instead of failing the whole run.
        func swappable(_ leaves: [SparkLeaf]) -> [SparkLeaf] {
            leaves.filter { Self.timelockCanDecrement(Data($0.node.refundTx)) }
        }

        var rounds = 0
        while rounds < 12 {
            let movable = swappable(current)
            let ideal = Self.binaryDecomposition(of: movable.reduce(0 as Int64) { $0 + $1.valueSats })
            guard movable.count > ideal.count else { break }

            // Merge the smallest leaves first — they are the ones that make
            // exits uneconomical and bundles huge.
            let batch = Array(
                movable.sorted { $0.valueSats < $1.valueSats }.prefix(maxLeavesPerRound)
            )
            let batchTotal = batch.reduce(0 as Int64) { $0 + $1.valueSats }
            let targets = Self.binaryDecomposition(of: batchTotal)
            guard batch.count > targets.count, batchTotal > 0 else { break }

            _ = try await processSwapBatch(leaves: batch, targetAmounts: targets)
            rounds += 1

            let refreshed = try await getLeaves()
            guard refreshed.count < current.count else { break }  // no progress — stop
            current = refreshed
        }

        return SparkLeafConsolidation(
            leavesBefore: leavesBefore,
            leavesAfter: current.count,
            totalSatsBefore: totalBefore,
            totalSatsAfter: current.reduce(0 as Int64) { $0 + $1.valueSats },
            rounds: rounds,
            skippedLeaves: current.count - swappable(current).count
        )
    }

    /// Power-of-two denominations summing exactly to `total` (its set bits),
    /// largest first. The minimal leaf set the SSP denomination system can
    /// represent the amount with.
    static func binaryDecomposition(of total: Int64) -> [Int64] {
        guard total > 0 else { return [] }
        var result: [Int64] = []
        for bit in stride(from: 62, through: 0, by: -1) where (total >> bit) & 1 == 1 {
            result.append(1 << bit)
        }
        return result
    }
}
