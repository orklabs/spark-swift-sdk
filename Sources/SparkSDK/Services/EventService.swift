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

    private static func mapEvent(_ response: Spark_SubscribeToEventsResponse) -> SparkEvent? {
        switch response.event {
        case .connected:
            return .connected
        case .receiverTransfer(let transferEvent):
            return .transferReceived(mapTransfer(transferEvent.transfer))
        case .senderTransfer(let transferEvent):
            return .transferSent(mapTransfer(transferEvent.transfer))
        case .deposit(let depositEvent):
            return .depositConfirmed(treeID: depositEvent.deposit.treeID)
        default:
            return nil
        }
    }

    private static func mapTransfer(_ t: Spark_Transfer) -> SparkTransfer {
        SparkTransfer(
            id: t.id,
            senderIdentityPublicKey: Data(t.senderIdentityPublicKey).hexString,
            receiverIdentityPublicKey: Data(t.receiverIdentityPublicKey).hexString,
            totalValueSats: Int64(t.totalValue),
            status: "\(t.status)",
            type: "\(t.type)",
            createdAt: t.createdTime.date,
            sparkInvoice: t.sparkInvoice.isEmpty ? nil : t.sparkInvoice
        )
    }
}
