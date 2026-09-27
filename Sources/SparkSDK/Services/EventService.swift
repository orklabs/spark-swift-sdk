import Foundation
import GRPCCore
import SwiftProtobuf

extension SparkWallet {
    public func subscribeToEvents() async throws -> AsyncStream<SparkEvent> {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_SubscribeToEventsRequest()
        request.identityPublicKey = signer.identityPublicKey

        let clientRequest = ClientRequest(message: request, metadata: metadata)

        return AsyncStream { continuation in
            let task = Task {
                do {
                    try await client.subscribe_to_events(
                        request: clientRequest
                    ) { response in
                        for try await message in response.messages {
                            if let event = Self.mapEvent(message) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
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
