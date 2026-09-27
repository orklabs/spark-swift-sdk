import Foundation
import Testing
@testable import SparkSDK

/// How operator stream messages become `SparkEvent`s, following the reference SDK's
/// `handleStreamEvent`.
@Suite("Event stream")
struct EventStreamTests {
    static let wallet = Data([0x02] + Array(repeating: 0x11, count: 32))
    static let other = Data([0x03] + Array(repeating: 0x22, count: 32))

    static func transferMessage(
        receiver: Bool, type: Spark_TransferType, from sender: Data = other, to recipient: Data = wallet
    ) -> Spark_SubscribeToEventsResponse {
        var event = Spark_TransferEvent()
        event.transfer.id = "0199a8f0-0000-7000-8000-000000000001"
        event.transfer.type = type
        event.transfer.status = .senderKeyTweaked
        event.transfer.senderIdentityPublicKey = sender
        event.transfer.receiverIdentityPublicKey = recipient
        event.transfer.totalValue = 10
        var message = Spark_SubscribeToEventsResponse()
        if receiver {
            message.receiverTransfer = event
        } else {
            message.senderTransfer = event
        }
        return message
    }

    static func depositMessage(status: String) -> Spark_SubscribeToEventsResponse {
        var event = Spark_DepositEvent()
        event.deposit.treeID = "tree"
        event.deposit.status = status
        var message = Spark_SubscribeToEventsResponse()
        message.deposit = event
        return message
    }

    @Test("A payment to the wallet is reported; its own swaps' counter-transfers and self-transfers are not")
    func receivedTransfers() {
        for type in [Spark_TransferType.transfer, .preimageSwap, .utxoSwap] {
            guard case .transferReceived(let transfer)? = SparkWallet.mapEvent(Self.transferMessage(receiver: true, type: type)) else {
                Issue.record("a \(type) payment was not reported")
                continue
            }
            #expect(transfer.totalValueSats == 10)
        }
        for type in [Spark_TransferType.counterSwap, .counterSwapV3] {
            #expect(SparkWallet.mapEvent(Self.transferMessage(receiver: true, type: type)) == nil)
        }
        let selfTransfer = Self.transferMessage(receiver: true, type: .transfer, from: Self.wallet, to: Self.wallet)
        #expect(SparkWallet.mapEvent(selfTransfer) == nil)
    }

    @Test("Outgoing transfers are reported with their status, swaps included")
    func sentTransfers() {
        for type in [Spark_TransferType.transfer, .primarySwapV3] {
            guard case .transferSent(let transfer)? = SparkWallet.mapEvent(
                Self.transferMessage(receiver: false, type: type, from: Self.wallet, to: Self.other)
            ) else {
                Issue.record("a sent \(type) was not reported")
                continue
            }
            #expect(transfer.status == "\(Spark_TransferStatus.senderKeyTweaked)")
        }
    }

    @Test("A deposit is reported once its leaf is available; connection events pass through")
    func depositsAndConnection() {
        guard case .depositConfirmed(let treeID)? = SparkWallet.mapEvent(Self.depositMessage(status: "AVAILABLE")) else {
            Issue.record("an available deposit was not reported")
            return
        }
        #expect(treeID == "tree")
        #expect(SparkWallet.mapEvent(Self.depositMessage(status: "CREATING")) == nil)
        var connected = Spark_SubscribeToEventsResponse()
        connected.connected = Spark_ConnectedEvent()
        guard case .connected? = SparkWallet.mapEvent(connected) else {
            Issue.record("the connected event was not reported")
            return
        }
        #expect(SparkWallet.mapEvent(Spark_SubscribeToEventsResponse()) == nil)
    }
}

/// The event stream's connection handling against a local operator stand-in, whose subscription
/// sends `connected` and then ends.
@Suite("Event stream connection")
struct EventStreamConnectionTests {
    /// Events up to and including the `count`-th `.connected`; stops iterating there.
    static func events(_ stream: AsyncStream<SparkEvent>, untilConnection count: Int) async -> [SparkEvent] {
        var events: [SparkEvent] = []
        var connections = 0
        for await event in stream {
            events.append(event)
            if case .connected = event {
                connections += 1
                if connections == count { break }
            }
        }
        return events
    }

    @Test("Attempts back off from 1 s doubling to 15 s, as the reference SDK's stream does")
    func backoff() {
        #expect((0...7).map(SparkWallet.eventStreamBackoff) == [1, 1, 2, 4, 8, 15, 15, 15].map { .seconds($0) })
    }

    @Test("An ended subscription is resumed, and every connection claims the pending transfers",
          .timeLimit(.minutes(1)))
    func reconnectAndClaim() async throws {
        let state = FakeOperatorState { _ in false }
        let events = try await withFakeOperator(state) { wallet in
            await Self.events(try await wallet.subscribeToEvents(), untilConnection: 2)
        }
        guard events.count == 3, case .connected = events[0], case .reconnecting(1, .seconds(1), let reason) = events[1],
              case .connected = events[2] else {
            Issue.record("expected connected, reconnecting, connected; got \(events)")
            return
        }
        #expect(reason.contains("ended"))
        #expect(await Array(state.methods.prefix(3)) == ["subscribe_to_events", "query_pending_transfers", "subscribe_to_events"])
    }

    @Test("Closing the wallet ends its event streams and refuses new ones", .timeLimit(.minutes(1)))
    func closeEndsStreams() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            let stream = try await wallet.subscribeToEvents()
            var iterator = stream.makeAsyncIterator()
            guard case .connected? = await iterator.next() else {
                Issue.record("the stream did not connect")
                return
            }
            await wallet.close()
            while await iterator.next() != nil {}
            await #expect(throws: SparkError.self) { _ = try await wallet.subscribeToEvents() }
        }
    }

    /// Every event a subscription yields within `duration`.
    static func events(_ stream: AsyncStream<SparkEvent>, for duration: Duration) async throws -> [SparkEvent] {
        let log = EventLog()
        let reader = Task {
            for await event in stream {
                await log.append(event)
            }
        }
        try await Task.sleep(for: duration)
        reader.cancel()
        return await log.events
    }

    @Test("A subscription that goes silent after sending heartbeats is dropped and resubscribed",
          .timeLimit(.minutes(1)))
    func heartbeatSilence() async throws {
        let state = FakeOperatorState { _ in false }
        await state.setSubscription(.heartbeatThenSilence)
        let events = try await withFakeOperator(state) { wallet in
            await Self.events(try await wallet.subscribeToEvents(heartbeatTimeout: .milliseconds(300)), untilConnection: 2)
        }
        guard events.count == 3, case .connected = events[0], case .reconnecting(1, _, let reason) = events[1],
              case .connected = events[2] else {
            Issue.record("expected connected, reconnecting, connected; got \(events)")
            return
        }
        #expect(reason.contains("heartbeat"))
    }

    @Test("A quiet subscription that never sent a heartbeat is kept", .timeLimit(.minutes(1)))
    func quietWithoutHeartbeats() async throws {
        let state = FakeOperatorState { _ in false }
        await state.setSubscription(.silence)
        let events = try await withFakeOperator(state) { wallet in
            try await Self.events(try await wallet.subscribeToEvents(heartbeatTimeout: .milliseconds(200)), for: .seconds(1))
        }
        guard events.count == 1, case .connected = events[0] else {
            Issue.record("expected only the connection; got \(events)")
            return
        }
    }

    @Test("The watchdog arms on a heartbeat and pauses while an event is handled")
    func watchdog() async throws {
        func fires(_ activity: EventStreamActivity, within: Duration) async -> Bool {
            let watchdog = Task { try await activity.silence(longerThan: .milliseconds(100)) }
            let timer = Task {
                try await Task.sleep(for: within)
                watchdog.cancel()
            }
            defer { timer.cancel() }
            return (try? await watchdog.value) != nil
        }
        let unarmed = EventStreamActivity()
        unarmed.received(heartbeat: false)
        unarmed.handled()
        #expect(await !fires(unarmed, within: .milliseconds(400)))

        let armed = EventStreamActivity()
        armed.received(heartbeat: true)
        armed.handled()
        #expect(await fires(armed, within: .seconds(5)))

        let busy = EventStreamActivity()
        busy.received(heartbeat: true)
        #expect(await !fires(busy, within: .milliseconds(400)))
    }
}
