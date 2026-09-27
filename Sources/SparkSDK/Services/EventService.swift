import Foundation
import GRPCCore
import SwiftProtobuf

/// The wallet's running event streams, so that `close()` can stop them.
actor EventStreamRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    /// Registers a stream's task; false once the wallet is closed.
    func register(_ id: UUID, _ task: Task<Void, Never>) -> Bool {
        guard !closed else { return false }
        tasks[id] = task
        return true
    }

    func finished(_ id: UUID) {
        tasks[id] = nil
    }

    /// Stops every running stream and refuses new ones.
    func close() {
        closed = true
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

extension SparkWallet {
    /// Events for this wallet, until the caller stops iterating or the wallet is closed. Like the
    /// reference SDK's background stream it stays up on its own:
    /// - a subscription that fails, or that the operator ends, is retried forever — 1 s doubling
    ///   to 15 s between attempts — with `.reconnecting` before each wait;
    /// - on every connection the wallet's pending transfers are claimed, so payments that arrived
    ///   while the stream was down are not left waiting, and each is reported as
    ///   `.transferReceived`;
    /// - a payment that arrives while connected is claimed, then reported.
    ///
    /// Throws only when the wallet is already closed.
    public func subscribeToEvents() async throws -> AsyncStream<SparkEvent> {
        let (stream, continuation) = AsyncStream<SparkEvent>.makeStream()
        let id = UUID()
        let task = Task {
            await self.runEventStream(continuation)
            await self.eventStreams.finished(id)
        }
        guard await eventStreams.register(id, task) else {
            task.cancel()
            continuation.finish()
            throw SparkError.invalidArgument("the wallet is closed")
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// Wait before event-stream attempt `attempt` + 1 after `attempt` failures in a row: 1 s
    /// doubling to 15 s, the reference SDK's background-stream backoff.
    static func eventStreamBackoff(attempt: Int) -> Duration {
        .seconds(min(15, 1 << min(max(attempt, 1) - 1, 4)))
    }

    /// Subscribes, reports, and subscribes again — until the task is cancelled.
    func runEventStream(_ continuation: AsyncStream<SparkEvent>.Continuation) async {
        var attempt = 0
        while !Task.isCancelled {
            let outcome = await subscribeOnce(continuation)
            guard !Task.isCancelled else { break }
            attempt = outcome.connected ? 1 : attempt + 1
            let delay = Self.eventStreamBackoff(attempt: attempt)
            continuation.yield(.reconnecting(attempt: attempt, retryIn: delay, reason: outcome.reason))
            try? await Task.sleep(for: delay)
        }
        continuation.finish()
    }

    /// One subscription, reported until the operator ends it or it fails. Returns whether it
    /// connected and why it ended.
    private func subscribeOnce(
        _ continuation: AsyncStream<SparkEvent>.Continuation
    ) async -> (connected: Bool, reason: String) {
        do {
            let client = try await getCoordinatorClient()
            let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
            var request = Spark_SubscribeToEventsRequest()
            request.identityPublicKey = signer.identityPublicKey
            return try await client.subscribe_to_events(
                request: ClientRequest(message: request, metadata: metadata)
            ) { response in
                var connected = false
                var claimedOnConnect: Set<String> = []
                do {
                    for try await message in response.messages {
                        switch message.event {
                        case .connected:
                            connected = true
                            continuation.yield(.connected)
                            claimedOnConnect = await self.claimPendingOnConnect(continuation)
                        case .receiverTransfer(let transferEvent):
                            guard !claimedOnConnect.contains(transferEvent.transfer.id) else { continue }
                            await self.claimOnArrival(transferEvent.transfer)
                            if let event = Self.mapEvent(message) {
                                continuation.yield(event)
                            }
                        default:
                            if let event = Self.mapEvent(message) {
                                continuation.yield(event)
                            }
                        }
                    }
                    return (connected, "the operator ended the event stream")
                } catch {
                    return (connected, String(describing: error))
                }
            }
        } catch {
            return (false, String(describing: error))
        }
    }

    /// Claims every pending transfer once the stream is up — payments that arrived while it was
    /// down included — and reports the claimed payments. Returns the ids claimed, so that their
    /// stream events, if the operators send those too, are not handled twice.
    private func claimPendingOnConnect(_ continuation: AsyncStream<SparkEvent>.Continuation) async -> Set<String> {
        guard let claim = try? await claimPendingTransfers() else { return [] }
        for transfer in claim.claimedTransfers where Self.isIncomingPayment(transfer) {
            continuation.yield(.transferReceived(SparkTransfer(transfer)))
        }
        return Set(claim.claimedTransferIds)
    }

    /// Claims a payment that arrived on the stream before it is reported, as the reference SDK
    /// does. Best effort: one that cannot be claimed now stays pending for the next claim pass.
    private func claimOnArrival(_ transfer: Spark_Transfer) async {
        guard Self.isIncomingPayment(transfer),
              PendingTransferDrain.claimableStatuses.contains(transfer.status),
              (try? await claimTransfer(transfer)) != nil else { return }
        await renewClaimedLeaves(transfer.leaves.map(\.leaf.id))
    }

    /// The event an operator's stream message is reported as, if any. As in the reference SDK, a
    /// counter-transfer of the wallet's own swap and a self-transfer are not reported as received
    /// — the operation that made them claims them — and a deposit is reported once its leaf is
    /// available.
    static func mapEvent(_ response: Spark_SubscribeToEventsResponse) -> SparkEvent? {
        switch response.event {
        case .connected:
            return .connected
        case .receiverTransfer(let transferEvent):
            guard isIncomingPayment(transferEvent.transfer) else { return nil }
            return .transferReceived(SparkTransfer(transferEvent.transfer))
        case .senderTransfer(let transferEvent):
            return .transferSent(SparkTransfer(transferEvent.transfer))
        case .deposit(let depositEvent):
            guard depositEvent.deposit.status == "AVAILABLE" else { return nil }
            return .depositConfirmed(treeID: depositEvent.deposit.treeID)
        default:
            return nil
        }
    }

    /// Whether a transfer to this wallet is a payment someone made to it, rather than the
    /// counter-transfer of one of its own swaps or a transfer to itself.
    static func isIncomingPayment(_ transfer: Spark_Transfer) -> Bool {
        transfer.type != .counterSwap && transfer.type != .counterSwapV3
            && transfer.senderIdentityPublicKey != transfer.receiverIdentityPublicKey
    }
}
