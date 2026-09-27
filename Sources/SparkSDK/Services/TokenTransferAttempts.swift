import Foundation
import Synchronization

/// Token transfers sent with an idempotency key, so a retry with the key resends the same
/// transaction rather than building another.
///
/// The operators recognise the same transaction again. They answer a repeated key from their
/// idempotency records (kept 24 hours). Without the record, V3's `broadcast_transaction` answers
/// with the transaction stored under the partial transaction's hash, and V2's `start_transaction`
/// answers from the stored transaction while it is started, where `commit_transaction` of a
/// finalized transfer reports it finalized. A rebuilt transaction would differ in its client
/// timestamp, and in its outputs while the first transaction's outputs are spent or locked
/// (`TokenOutputLocks`), so it could not match what the operators answer for the key. Resending
/// never makes a second transfer: an attempt whose transaction expired unsent fails again, and a
/// new key starts a new transfer.
final class TokenTransferAttempts: Sendable {
    /// What a transfer asked for: a retry with the key must ask for the same.
    struct Request: Equatable, Sendable {
        let tokenIdentifier: Data
        let amount: UInt128
        let receiverIdentityPublicKey: Data
    }

    struct Attempt: Sendable {
        let request: Request
        /// The transaction, as first built.
        let transaction: TokenTransactionDraft
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
