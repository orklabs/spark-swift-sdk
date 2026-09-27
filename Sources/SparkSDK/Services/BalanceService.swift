import Foundation
import GRPCCore
import SwiftProtobuf

extension SparkWallet {
    public func getBalance() async throws -> WalletBalance {
        let client = try await getCoordinatorClient()

        // Query all nodes (no status filter) to compute owned + available
        var nodesRequest = Spark_QueryNodesRequest()
        nodesRequest.ownerIdentityPubkey = signer.identityPublicKey
        nodesRequest.network = config.networkProto

        let nodesResponse = try await client.query_nodes(
            request: try await makeAuthenticatedRequest(message: nodesRequest)
        )

        let summary = Self.summarizeNodes(nodesResponse.nodes)
        let availableSats = summary.available
        let ownedSats = summary.owned
        let leaves = summary.leaves

        // Incoming: pending inbound transfers + deposits still being created
        // (matches TS SDK which tracks CREATING deposit nodes as incoming)
        let pendingTransfers = try await queryPendingTransfers()
        let incomingSats = pendingTransfers.reduce(Int64(0)) { $0 + Int64($1.totalValue) } + summary.creating

        let satsBalance = SatsBalance(
            available: availableSats,
            owned: ownedSats,
            incoming: incomingSats,
            frozen: summary.frozen
        )

        let tokenBalances = try await getTokenBalances()

        return WalletBalance(satsBalance: satsBalance, tokenBalances: tokenBalances, leaves: leaves)
    }

    struct NodeSummary {
        var available: Int64 = 0
        var owned: Int64 = 0
        var frozen: Int64 = 0
        var creating: Int64 = 0
        var leaves: [SparkLeaf] = []
    }

    /// Pure classification of the coordinator's nodes into the balance figures.
    /// Owned = AVAILABLE + locked (transfer, split, aggregate, renew). An AVAILABLE leaf is
    /// frozen when its refund timelock is below 100 (`SparkLeaf.isFrozen`) and available
    /// otherwise: leaves at 100…199 count as available because every spend path renews them
    /// first, as the reference SDK does before counting them.
    static func summarizeNodes(_ nodes: [String: Spark_TreeNode]) -> NodeSummary {
        let lockedStatuses: Set<String> = ["TRANSFER_LOCKED", "SPLIT_LOCKED", "AGGREGATE_LOCK", "RENEW_LOCKED"]
        var summary = NodeSummary()
        for (id, node) in nodes {
            let value = Int64(node.value)
            switch node.status {
            case "AVAILABLE":
                let leaf = SparkLeaf(id: id, treeID: node.treeID, valueSats: value, status: node.status, node: node)
                summary.owned += value
                if leaf.isFrozen {
                    summary.frozen += value
                } else {
                    summary.available += value
                }
                summary.leaves.append(leaf)
            case let status where lockedStatuses.contains(status):
                summary.owned += value
            case "CREATING":
                summary.creating += value
            default:
                break
            }
        }
        return summary
    }

    public func getLeaves() async throws -> [SparkLeaf] {
        let client = try await getCoordinatorClient()

        var request = Spark_QueryNodesRequest()
        request.ownerIdentityPubkey = signer.identityPublicKey
        request.network = config.networkProto

        let response = try await client.query_nodes(
            request: try await makeAuthenticatedRequest(message: request)
        )

        return response.nodes.compactMap { (id, node) -> SparkLeaf? in
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
