import Foundation
import GRPCCore
import SwiftProtobuf

extension SparkWallet {
    /// The wallet's balance, modelled on the reference SDK's leaf manager:
    /// - `available` / `frozen`: AVAILABLE leaves, split by `SparkLeaf.isFrozen`;
    /// - `owned`: those plus the leaves an in-flight operation still holds for the wallet — an
    ///   outgoing transfer, Lightning payment or cooperative exit before the operators apply
    ///   the sender's key tweak, a swap the wallet started, and its counter-transfer until
    ///   claimed. Once the sender's key tweak is applied the sats belong to the receiver.
    public func getBalance() async throws -> WalletBalance {
        async let nodes = queryAvailableNodes()
        async let inFlight = queryInFlightTransfers()
        async let pendingTransfers = queryPendingTransfers()
        let summary = Self.summarizeNodes(try await nodes)
        let lockedSats = Self.inFlightSats(try await inFlight, excludingLeafIds: Set(summary.leaves.map(\.id)))

        // Incoming: pending inbound transfers
        let incomingSats = try await pendingTransfers.reduce(Int64(0)) { $0 + Int64($1.totalValue) }

        let satsBalance = SatsBalance(
            available: summary.available,
            owned: summary.available + summary.frozen + lockedSats,
            incoming: incomingSats,
            frozen: summary.frozen
        )

        let tokenBalances = try await getTokenBalances()

        return WalletBalance(satsBalance: satsBalance, tokenBalances: tokenBalances, leaves: summary.leaves)
    }

    struct NodeSummary {
        var available: Int64 = 0
        var frozen: Int64 = 0
        var leaves: [SparkLeaf] = []
    }

    /// Pure classification of the wallet's AVAILABLE leaves into the balance figures. A leaf is
    /// frozen when its refund timelock is below 100 (`SparkLeaf.isFrozen`) and available
    /// otherwise: leaves at 100…199 count as available because every spend path renews them
    /// first, as the reference SDK does before counting them. Nodes in any other status are
    /// ignored — in-flight sats come from the transfers holding them (`inFlightSats`).
    static func summarizeNodes(_ nodes: [String: Spark_TreeNode]) -> NodeSummary {
        var summary = NodeSummary()
        for (id, node) in nodes where node.status == "AVAILABLE" {
            let value = Int64(node.value)
            let leaf = SparkLeaf(id: id, treeID: node.treeID, valueSats: value, status: node.status, node: node)
            if leaf.isFrozen {
                summary.frozen += value
            } else {
                summary.available += value
            }
            summary.leaves.append(leaf)
        }
        return summary
    }

    /// Transfer statuses before the sender key tweak is applied: the sender still owns the leaves.
    static let senderPendingStatuses: [Spark_TransferStatus] = [
        .senderInitiated, .senderInitiatedCoordinator, .applyingSenderKeyTweak, .senderKeyTweakPending,
    ]
    /// A counter-transfer's statuses until it completes.
    static let activeCounterSwapStatuses: [Spark_TransferStatus] = senderPendingStatuses + [
        .senderKeyTweaked, .receiverKeyTweakLocked, .receiverKeyTweakApplied, .receiverKeyTweaked, .receiverRefundSigned,
    ]
    static let outgoingTransferTypes: [Spark_TransferType] = [.cooperativeExit, .utxoSwap, .preimageSwap, .transfer]
    static let primarySwapTypes: [Spark_TransferType] = [.primarySwapV3, .swap]
    static let counterSwapTypes: [Spark_TransferType] = [.counterSwapV3, .counterSwap]

    /// The transfers that hold leaves the wallet still owns, as the reference SDK queries them:
    /// outgoing transfers and swaps it sent that are still before the sender key tweak, and
    /// counter-transfers of its swaps until they complete.
    func queryInFlightTransfers() async throws -> [Spark_Transfer] {
        async let outgoing = queryAllTransferPages(
            senderOnly: true, types: Self.outgoingTransferTypes, statuses: Self.senderPendingStatuses
        )
        async let primarySwaps = queryAllTransferPages(
            senderOnly: true, types: Self.primarySwapTypes, statuses: Self.senderPendingStatuses
        )
        async let counterSwaps = queryAllTransferPages(
            senderOnly: false, types: Self.counterSwapTypes, statuses: Self.activeCounterSwapStatuses
        )
        return try await outgoing + primarySwaps + counterSwaps
    }

    /// Sats in the leaves of `transfers`, each leaf counted once and none that is already an
    /// AVAILABLE leaf of the wallet.
    static func inFlightSats(_ transfers: [Spark_Transfer], excludingLeafIds available: Set<String>) -> Int64 {
        var values: [String: Int64] = [:]
        for transfer in transfers {
            for transferLeaf in transfer.leaves where transferLeaf.hasLeaf && !available.contains(transferLeaf.leaf.id) {
                values[transferLeaf.leaf.id] = Int64(transferLeaf.leaf.value)
            }
        }
        return values.values.reduce(0, +)
    }

    /// Every page of the wallet's transfers of `types` in `statuses` (100 per page, the server's
    /// maximum), as the sender or as either party.
    func queryAllTransferPages(
        senderOnly: Bool,
        types: [Spark_TransferType],
        statuses: [Spark_TransferStatus]
    ) async throws -> [Spark_Transfer] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let pageSize: Int64 = 100
        var transfers: [Spark_Transfer] = []
        var offset: Int64 = 0
        var previousOffset: Int64 = -1
        repeat {
            var filter = Spark_TransferFilter()
            filter.participant = senderOnly
                ? .senderIdentityPublicKey(signer.identityPublicKey)
                : .senderOrReceiverIdentityPublicKey(signer.identityPublicKey)
            filter.types = types
            filter.statuses = statuses
            filter.network = config.networkProto
            filter.limit = pageSize
            filter.offset = offset
            let response = try await client.query_all_transfers(
                request: ClientRequest(message: filter, metadata: metadata)
            )
            transfers += response.transfers
            if response.transfers.count < pageSize || response.offset == previousOffset {
                break
            }
            previousOffset = response.offset
            offset = response.offset
        } while offset >= 0
        return transfers
    }

    /// The wallet's AVAILABLE leaves on the coordinator.
    func queryAvailableNodes() async throws -> [String: Spark_TreeNode] {
        let client = try await getCoordinatorClient()
        var request = Spark_QueryNodesRequest()
        request.ownerIdentityPubkey = signer.identityPublicKey
        request.network = config.networkProto
        request.statuses = [.available]
        let response = try await client.query_nodes(
            request: try await makeAuthenticatedRequest(message: request)
        )
        return response.nodes
    }

    public func getLeaves() async throws -> [SparkLeaf] {
        try await queryAvailableNodes().compactMap { id, node -> SparkLeaf? in
            guard node.status == "AVAILABLE" else { return nil }
            return SparkLeaf(
                id: id,
                treeID: node.treeID,
                valueSats: Int64(node.value),
                status: node.status,
                node: node
            )
        }
    }
}
