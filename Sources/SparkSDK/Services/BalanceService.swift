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

        // Available: only nodes with AVAILABLE status
        // Owned: available + locked (transferLocked, splitLocked, aggregateLock, renewLocked)
        let lockedStatuses: Set<String> = [
            "TRANSFER_LOCKED", "SPLIT_LOCKED", "AGGREGATE_LOCK", "RENEW_LOCKED"
        ]

        var availableSats: Int64 = 0
        var ownedSats: Int64 = 0
        var leaves: [SparkLeaf] = []

        for (id, node) in nodesResponse.nodes {
            if node.status == "AVAILABLE" {
                availableSats += Int64(node.value)
                ownedSats += Int64(node.value)
                leaves.append(SparkLeaf(
                    id: id,
                    treeID: node.treeID,
                    valueSats: Int64(node.value),
                    status: node.status,
                    node: node
                ))
            } else if lockedStatuses.contains(node.status) {
                ownedSats += Int64(node.value)
            }
        }

        // Incoming: pending inbound transfers + deposits still being created
        // (matches TS SDK which tracks CREATING deposit nodes as incoming)
        let pendingTransfers = try await queryPendingTransfers()
        var incomingSats = pendingTransfers.reduce(Int64(0)) { $0 + Int64($1.totalValue) }
        for (_, node) in nodesResponse.nodes {
            if node.status == "CREATING" {
                incomingSats += Int64(node.value)
            }
        }

        let satsBalance = SatsBalance(
            available: availableSats,
            owned: ownedSats,
            incoming: incomingSats
        )

        let tokenBalances = try await getTokenBalances()

        return WalletBalance(satsBalance: satsBalance, tokenBalances: tokenBalances, leaves: leaves)
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
