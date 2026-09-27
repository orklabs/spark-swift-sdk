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
    /// - `incoming`: the leaves of pending inbound transfers, except counter-transfers of the
    ///   wallet's own swaps (already counted as locked) and leaves counted above.
    /// - `tokenBalances`: best effort — empty when the wallet's tokens cannot be read, since anyone
    ///   can send a wallet tokens; `getTokenBalances()` throws the error instead.
    public func getBalance() async throws -> WalletBalance {
        async let nodes = queryAvailableNodes()
        async let inFlight = queryInFlightTransfers()
        async let pending = queryAllPendingTransfers()
        let summary = Self.summarizeNodes(try await nodes)
        let availableIds = Set(summary.leaves.map(\.id))
        let inFlightTransfers = try await inFlight
        let lockedSats = Self.leafSats(inFlightTransfers, excludingLeafIds: availableIds)
        let incomingSats = Self.incomingSats(
            try await pending,
            excludingLeafIds: availableIds.union(inFlightTransfers.flatMap { $0.leaves.map(\.leaf.id) }),
            receiver: signer.identityPublicKey
        )

        let satsBalance = SatsBalance(
            available: summary.available,
            owned: summary.available + summary.frozen + lockedSats,
            incoming: incomingSats,
            frozen: summary.frozen
        )

        // Best effort: tokens anyone can send must not cost the wallet its sats balance.
        // `getTokenBalances()` reports what went wrong. A cancelled call still throws rather than
        // report no tokens.
        let tokenBalances = (try? await getTokenBalances()) ?? []
        try Task.checkCancellation()

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
            let value = Int64(reportedSats: node.value)
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

    /// Sats in the leaves of `transfers`, each leaf counted once and none in `excluded` (leaves
    /// already counted, e.g. the wallet's AVAILABLE leaves).
    static func leafSats(_ transfers: [Spark_Transfer], excludingLeafIds excluded: Set<String>) -> Int64 {
        var values: [String: Int64] = [:]
        for transfer in transfers {
            for transferLeaf in transfer.leaves where transferLeaf.hasLeaf && !excluded.contains(transferLeaf.leaf.id) {
                values[transferLeaf.leaf.id] = Int64(reportedSats: transferLeaf.leaf.value)
            }
        }
        return values.values.reduce(0, +)
    }

    /// Sats pending inbound: `receiver`'s own leaves of `pending` (a multi-receiver transfer also
    /// carries the other receivers'), except counter-transfers of the wallet's own swaps — the
    /// reference SDK leaves those out of incoming because the swap already counts them — and
    /// leaves in `excluded` (a self-transfer shows up as outgoing too).
    static func incomingSats(_ pending: [Spark_Transfer], excludingLeafIds excluded: Set<String>, receiver: Data) -> Int64 {
        let own = pending
            .filter { !counterSwapTypes.contains($0.type) }
            .compactMap { try? TransferLeafVerifier.scoped($0, toReceiver: receiver) }
        return leafSats(own, excludingLeafIds: excluded)
    }

    /// Every page of the wallet's pending inbound transfers.
    func queryAllPendingTransfers() async throws -> [Spark_Transfer] {
        let pageSize = 100
        var transfers: [Spark_Transfer] = []
        var offset = 0
        while true {
            let page = try await queryPendingTransfers(limit: pageSize, offset: offset)
            transfers += page
            if page.count < pageSize {
                return transfers
            }
            offset += page.count
        }
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
        var request = Spark_QueryNodesRequest()
        request.ownerIdentityPubkey = signer.identityPublicKey
        request.network = config.networkProto
        request.statuses = [.available]
        return try await queryAllNodes(request)
    }

    /// Nodes the operators return for `request`, a page of 100 at a time (their maximum), as
    /// the reference SDK pages them: without a limit the whole set comes back in one response,
    /// which outgrows the message-size limit for a wallet with many leaves. Pages are counted
    /// here rather than following the response's offset (proto3 cannot tell "0" from unset);
    /// with `include_parents` the parents pad the pages, which costs at most one extra request.
    func queryAllNodes(_ request: Spark_QueryNodesRequest, options: CallOptions = .defaults) async throws -> [String: Spark_TreeNode] {
        let client = try await getCoordinatorClient()
        let pageSize: Int64 = 100
        var nodes: [String: Spark_TreeNode] = [:]
        var page = request
        page.limit = pageSize
        page.offset = 0
        while true {
            let response = try await client.query_nodes(
                request: try await makeAuthenticatedRequest(message: page), options: options
            )
            let countBefore = nodes.count
            nodes.merge(response.nodes) { _, latest in latest }
            // A short page ends the set; a page that adds nothing means the operator is not
            // paging, and asking again would never end.
            guard response.nodes.count >= pageSize, nodes.count > countBefore else {
                return nodes
            }
            page.offset += pageSize
        }
    }

    public func getLeaves() async throws -> [SparkLeaf] {
        try await queryAvailableNodes().compactMap { id, node -> SparkLeaf? in
            guard node.status == "AVAILABLE" else { return nil }
            return SparkLeaf(
                id: id,
                treeID: node.treeID,
                valueSats: Int64(reportedSats: node.value),
                status: node.status,
                node: node
            )
        }
    }
}
