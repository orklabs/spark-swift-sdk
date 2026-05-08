import Foundation
import GRPCCore
import SwiftProtobuf

extension SparkWallet {

    /// Get a single transfer by its ID.
    public func getTransfer(id: String) async throws -> SparkTransfer {
        let transfers = try await getTransfers(ids: [id])
        guard let transfer = transfers.first else {
            throw SparkError.invalidResponse("Transfer not found: \(id)")
        }
        return transfer
    }

    /// Get transfers with optional filters.
    /// - Parameters:
    ///   - ids: Filter by specific transfer IDs (empty = all)
    ///   - direction: Filter by sent/received/both (default: both)
    ///   - limit: Max results (0 = server default)
    ///   - offset: Pagination offset
    public func getTransfers(
        ids: [String] = [],
        direction: TransferDirection = .both,
        limit: Int64 = 0,
        offset: Int64 = 0
    ) async throws -> [SparkTransfer] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var filter = Spark_TransferFilter()
        filter.network = config.networkProto

        switch direction {
        case .sent:
            filter.participant = .senderIdentityPublicKey(signer.identityPublicKey)
        case .received:
            filter.participant = .receiverIdentityPublicKey(signer.identityPublicKey)
        case .both:
            filter.participant = .senderOrReceiverIdentityPublicKey(signer.identityPublicKey)
        }

        if !ids.isEmpty {
            filter.transferIds = ids
        }
        if limit > 0 {
            filter.limit = limit
        }
        if offset > 0 {
            filter.offset = offset
        }

        let response = try await client.query_all_transfers(
            request: ClientRequest(message: filter, metadata: metadata)
        )

        return response.transfers.map { transfer in
            SparkTransfer(
                id: transfer.id,
                senderIdentityPublicKey: Data(transfer.senderIdentityPublicKey).hexString,
                receiverIdentityPublicKey: Data(transfer.receiverIdentityPublicKey).hexString,
                totalValueSats: Int64(transfer.totalValue),
                status: "\(transfer.status)",
                type: "\(transfer.type)",
                createdAt: transfer.createdTime.date,
                sparkInvoice: transfer.sparkInvoice.isEmpty ? nil : transfer.sparkInvoice
            )
        }
    }
}

public enum TransferDirection: Sendable {
    case sent
    case received
    case both
}
