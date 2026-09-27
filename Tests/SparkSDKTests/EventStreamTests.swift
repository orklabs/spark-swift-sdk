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
