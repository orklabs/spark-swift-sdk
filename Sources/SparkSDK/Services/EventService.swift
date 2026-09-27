import Foundation
import GRPCCore
import SwiftProtobuf
import Synchronization

/// The wallet's running event streams, so that `close()` can stop them and `start()` can accept
/// new ones again.
actor EventStreamRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    /// Registers a stream's task; false while the wallet is closed.
    func register(_ id: UUID, _ task: Task<Void, Never>) -> Bool {
        guard !closed else { return false }
        tasks[id] = task
        return true
    }

    func finished(_ id: UUID) {
        tasks[id] = nil
    }

    /// Stops every running stream and refuses new ones until `reopen()`.
    func close() {
        closed = true
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// Accepts new streams again after `close()`.
    func reopen() {
        closed = false
    }
}

/// One subscription's activity, for the heartbeat watchdog. As in the reference SDK the
/// watchdog arms on the first heartbeat — a coordinator that sends none never times out — and
/// pauses while an event is being handled, since handling one can claim a transfer.
final class EventStreamActivity: Sendable {
    private struct State {
        var connected = false
        var heartbeats = false
        var handling = false
        var lastSeen = ContinuousClock.now
    }
    private let state = Mutex(State())

    var connected: Bool {
        state.withLock { $0.connected }
    }

    func markConnected() {
        state.withLock { $0.connected = true }
    }

    /// A message arrived: the watchdog pauses until `handled()`; a heartbeat arms it.
    func received(heartbeat: Bool) {
        state.withLock {
            $0.handling = true
            if heartbeat { $0.heartbeats = true }
        }
    }

    /// The message is handled: the silence starts counting again.
    func handled() {
        state.withLock {
            $0.handling = false
            $0.lastSeen = .now
        }
    }

    /// Returns once heartbeats are armed and the stream has been silent for `timeout` outside
    /// event handling; otherwise waits until cancelled.
    func silence(longerThan timeout: Duration) async throws {
        while true {
            let deadline: ContinuousClock.Instant? = state.withLock {
                $0.heartbeats && !$0.handling ? $0.lastSeen + timeout : nil
            }
            if let deadline, deadline <= .now {
                return
            }
            try await Task.sleep(until: deadline ?? .now + timeout, clock: .continuous)
        }
    }
}

/// A subscription dropped because it went silent after sending heartbeats.
private struct EventStreamSilent: Swift.Error {}

extension SparkWallet {
    /// How long a subscription that sends heartbeats (every 5 s from the operators) may stay
    /// silent before it is dropped and resubscribed — the reference SDK's
    /// `STREAM_HEARTBEAT_TIMEOUT_MS`.
    static let eventStreamHeartbeatTimeout: Duration = .seconds(15)

    /// Events for this wallet, until the caller stops iterating or the wallet is closed. Like the
    /// reference SDK's background stream it stays up on its own:
    /// - a subscription that fails, or that the operator ends, is retried forever — 1 s doubling
    ///   to 15 s between attempts — with `.reconnecting` before each wait;
    /// - on every connection the wallet's pending transfers are claimed, so payments that arrived
    ///   while the stream was down are not left waiting, and each is reported as
    ///   `.transferReceived`;
    /// - a payment that arrives while connected is claimed, then reported;
    /// - once the operator sends heartbeats, a subscription silent for 15 s — a connection that
    ///   died without closing, as after a network change — is dropped and resubscribed.
    ///
    /// Throws only while the wallet is closed: after `close()` and before the next `start()`.
    public func subscribeToEvents() async throws -> AsyncStream<SparkEvent> {
        try await subscribeToEvents(heartbeatTimeout: Self.eventStreamHeartbeatTimeout)
    }

    func subscribeToEvents(heartbeatTimeout: Duration) async throws -> AsyncStream<SparkEvent> {
        let (stream, continuation) = AsyncStream<SparkEvent>.makeStream()
        let id = UUID()
        let task = Task {
            await self.runEventStream(continuation, heartbeatTimeout: heartbeatTimeout)
            await self.eventStreams.finished(id)
        }
        guard await eventStreams.register(id, task) else {
            task.cancel()
            continuation.finish()
            throw SparkError.invalidArgument("the wallet is closed; start() it before subscribing")
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
    func runEventStream(_ continuation: AsyncStream<SparkEvent>.Continuation, heartbeatTimeout: Duration) async {
        var attempt = 0
        while !Task.isCancelled {
            let outcome = await subscribeOnce(continuation, heartbeatTimeout: heartbeatTimeout)
            guard !Task.isCancelled else { break }
            attempt = outcome.connected ? 1 : attempt + 1
            let delay = Self.eventStreamBackoff(attempt: attempt)
            continuation.yield(.reconnecting(attempt: attempt, retryIn: delay, reason: outcome.reason))
            try? await Task.sleep(for: delay)
        }
        continuation.finish()
    }

    /// One subscription, reported until the operator ends it, it fails, or it goes silent after
    /// sending heartbeats. Returns whether it connected and why it ended.
    private func subscribeOnce(
        _ continuation: AsyncStream<SparkEvent>.Continuation,
        heartbeatTimeout: Duration
    ) async -> (connected: Bool, reason: String) {
        let activity = EventStreamActivity()
        do {
            let client = try await getCoordinatorClient()
            let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
            var request = Spark_SubscribeToEventsRequest()
            request.identityPublicKey = signer.identityPublicKey
            try await client.subscribe_to_events(
                request: ClientRequest(message: request, metadata: metadata)
            ) { response in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.report(response.messages, continuation, activity)
                    }
                    group.addTask {
                        try await activity.silence(longerThan: heartbeatTimeout)
                        throw EventStreamSilent()
                    }
                    // The first to finish decides: the stream ended, failed or went silent.
                    try await group.next()
                    group.cancelAll()
                }
            }
            return (activity.connected, "the operator ended the event stream")
        } catch is EventStreamSilent {
            return (activity.connected, "no heartbeat for \(heartbeatTimeout)")
        } catch {
            return (activity.connected, String(describing: error))
        }
    }

    /// Reports one subscription's messages until it ends.
    private func report(
        _ messages: RPCAsyncSequence<Spark_SubscribeToEventsResponse, any Swift.Error>,
        _ continuation: AsyncStream<SparkEvent>.Continuation,
        _ activity: EventStreamActivity
    ) async throws {
        var claimedOnConnect: Set<String> = []
        for try await message in messages {
            let isHeartbeat: Bool
            if case .heartbeat = message.event { isHeartbeat = true } else { isHeartbeat = false }
            activity.received(heartbeat: isHeartbeat)
            defer { activity.handled() }
            switch message.event {
            case .connected:
                activity.markConnected()
                continuation.yield(.connected)
                claimedOnConnect = await claimPendingOnConnect(continuation)
            case .receiverTransfer(let transferEvent):
                guard !claimedOnConnect.contains(transferEvent.transfer.id) else { continue }
                await claimOnArrival(transferEvent.transfer)
                if let event = Self.mapEvent(message) {
                    continuation.yield(event)
                }
            default:
                if let event = Self.mapEvent(message) {
                    continuation.yield(event)
                }
            }
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
