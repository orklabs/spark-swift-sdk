import Foundation
import Synchronization

/// Token outputs the wallet has picked for a transaction that may still be in flight, kept as the
/// reference SDK's `TokenOutputManager` keeps them. The operators report an output of a started
/// transaction as AVAILABLE until that transaction is signed, and of two transactions spending
/// one output they keep only one (the earlier client timestamp), so two sends from one wallet
/// must not pick the same outputs.
///
/// A lock ends after `expiry` (30 s, the reference SDK's default) or once the operators report the
/// output PENDING_OUTBOUND. A failed send does not release its outputs early: the operators may
/// already hold its transaction.
final class TokenOutputLocks: Sendable {
    typealias Output = SparkToken_OutputWithPreviousTransactionData

    let expiry: Duration
    /// When each locked output (`key(_:)`) was picked.
    private let lockedAt = Mutex<[String: ContinuousClock.Instant]>([:])

    init(expiry: Duration = .seconds(30)) {
        self.expiry = expiry
    }

    /// Picks with `select` among the `outputs` that can be spent (available and not locked) and
    /// locks the picked ones. Picking and locking happen under one lock, so concurrent sends
    /// never pick the same output.
    func acquire(_ outputs: [Output], select: ([Output]) throws -> [Output]) throws -> [Output] {
        try lockedAt.withLock { locks in
            let now = ContinuousClock.now
            locks = locks.filter { now - $0.value < expiry }
            // Pending on the operators: their status covers it from here.
            for output in outputs where output.output.hasStatus && output.output.status == .pendingOutbound {
                locks[Self.key(output)] = nil
            }
            let spendable = outputs.filter { Self.isAvailable($0) && locks[Self.key($0)] == nil }
            let selected = try select(spendable)
            for output in selected {
                locks[Self.key(output)] = now
            }
            return selected
        }
    }

    /// Whether the operators report `output` spendable: AVAILABLE, or no status at all.
    /// PENDING_OUTBOUND outputs belong to a signed transaction that has not finalized.
    static func isAvailable(_ output: Output) -> Bool {
        !output.output.hasStatus || output.output.status == .available
    }

    /// The token transaction output that `output` is: previous transaction hash and vout.
    static func key(_ output: Output) -> String {
        "\(output.previousTransactionHash.hexString):\(output.previousTransactionVout)"
    }
}
