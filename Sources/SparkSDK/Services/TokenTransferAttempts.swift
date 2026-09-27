import Foundation
import Synchronization

/// Token transfers sent with an idempotency key, so a retry with the key resends the same
/// transaction rather than building another.
///
/// The operators recognise the same transaction again: `start_transaction` answers from their
/// idempotency records (kept 24 hours) or, while the transaction is started, from the stored
/// transaction itself, and `commit_transaction` of a finalized transfer reports it finalized. A
/// rebuilt transaction would differ in its client timestamp, and in its outputs while the first
/// transaction's outputs are spent or locked (`TokenOutputLocks`), so it could not match what the
/// operators answer for the key. Resending never makes a second transfer: an attempt whose
/// transaction expired unsent fails again, and a new key starts a new transfer.
final class TokenTransferAttempts: Sendable {
    /// What a transfer asked for: a retry with the key must ask for the same.
    struct Request: Equatable, Sendable {
        let tokenIdentifier: Data
        let amount: UInt128
        let receiverIdentityPublicKey: Data
    }

    struct Attempt: Sendable {
        let request: Request
        /// The partial transaction, as first sent.
        let transaction: SparkToken_TokenTransaction
        /// The outputs it spends.
        let spentOutputs: [SparkToken_OutputWithPreviousTransactionData]
    }

    /// How many keys are remembered; the oldest is forgotten first.
    static let capacity = 1_000

    private struct State {
        var attempts: [String: Attempt] = [:]
        /// Keys, oldest first.
        var order: [String] = []
    }
    private let state = Mutex(State())

    func attempt(for key: String) -> Attempt? {
        state.withLock { $0.attempts[key] }
    }

    func remember(_ attempt: Attempt, for key: String) {
        state.withLock { state in
            if state.attempts.updateValue(attempt, forKey: key) == nil {
                state.order.append(key)
            }
            while state.order.count > Self.capacity {
                state.attempts[state.order.removeFirst()] = nil
            }
        }
    }
}
