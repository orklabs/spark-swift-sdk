import Foundation
import GRPCCore
import SwiftProtobuf

extension SparkWallet {

    /// Get a single transfer by its ID.
    public func getTransfer(id: String) async throws -> SparkTransfer {
        SparkTransfer(try await queryTransferById(id))
    }

    /// Get transfers with optional filters.
    ///
    /// Without `ids`, only the transfers a user makes are listed, as the reference SDK lists
    /// them: Spark transfers, Lightning payments (preimage swaps), cooperative exits and static
    /// deposit claims (UTXO swaps). The legs of leaf swaps are left out; the operators also
    /// answer that query in well under a second, where an unfiltered one took them 17 s to over
    /// a minute for a wallet with a long history.
    /// - Parameters:
    ///   - ids: Filter by specific transfer IDs (empty = all), of any type
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

        if ids.isEmpty {
            filter.types = Self.listedTransferTypes
        } else {
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

        return response.transfers.map(SparkTransfer.init)
    }

    /// The transfer types `getTransfers` lists: the reference SDK's `getTransfers` types.
    static let listedTransferTypes: [Spark_TransferType] = [.cooperativeExit, .preimageSwap, .utxoSwap, .transfer]
}

public enum TransferDirection: Sendable {
    case sent
    case received
    case both
}
