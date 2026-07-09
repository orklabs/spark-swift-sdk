import Foundation
import GRPCCore
import SwiftProtobuf

/// A leaf currently owned by the wallet, with its full TreeNode encoded for
/// offline use (raw node tx, pre-signed refund txs, verifying key, parent id).
public struct SparkRecoveryLeaf: Codable, Sendable {
    public let id: String
    public let status: String
    public let valueSats: Int64
    /// Hex of the protobuf-serialized TreeNode (`TreeNode.encode().finish()` bytes).
    public let treeNodeHex: String
}

/// An ancestor node on the path from a leaf to its tree root.
public struct SparkRecoveryNode: Codable, Sendable {
    public let id: String
    public let treeNodeHex: String
}

/// Everything besides the seed needed to unilaterally exit the wallet's funds
/// while Spark operators are offline. Leaves cannot be re-discovered from the
/// seed once operators are down, so this snapshot must be captured while they
/// are online and refreshed whenever the leaf set changes.
public struct SparkRecoverySnapshot: Codable, Sendable {
    /// "MAINNET" or "REGTEST"
    public let network: String
    public let identityPublicKeyHex: String
    public let leaves: [SparkRecoveryLeaf]
    public let nodes: [SparkRecoveryNode]

    public var totalLeafSats: Int64 { leaves.reduce(0) { $0 + $1.valueSats } }
}

extension SparkWallet {
    /// query_nodes with include_parents returns every leaf's full ancestor
    /// chain in ONE message, and long-lived wallets exceed the transport's
    /// 4 MiB default cap (seen live: 6.9 MB → resourceExhausted). Raise both
    /// size limits for the recovery queries only.
    private static var recoveryCallOptions: CallOptions {
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = 128 * 1024 * 1024
        options.maxResponseMessageBytes = 128 * 1024 * 1024
        return options
    }

    /// Fetch the wallet's leaves plus the complete ancestor chain of every leaf.
    ///
    /// The bulk include-parents query can omit nodes (notably legacy tree roots),
    /// so referenced-but-missing parents are re-fetched by node id until every
    /// chain terminates at a root. Throws if a chain still cannot be completed —
    /// callers must NOT persist a snapshot from a failed call over a previous
    /// good one, because an incomplete snapshot is useless for a unilateral exit.
    public func getRecoverySnapshot() async throws -> SparkRecoverySnapshot {
        let client = try await getCoordinatorClient()

        var all: [String: Spark_TreeNode] = [:]

        var request = Spark_QueryNodesRequest()
        request.ownerIdentityPubkey = signer.identityPublicKey
        request.includeParents = true
        request.network = config.networkProto

        let response = try await client.query_nodes(
            request: try await makeAuthenticatedRequest(message: request),
            options: Self.recoveryCallOptions
        )
        for (id, node) in response.nodes { all[id] = node }

        // Repair pass: fetch any parent referenced by a node in the map but not
        // present in it. Bounded so a coordinator that keeps returning nothing
        // can't loop us forever; no-progress also exits.
        var missing = Self.missingParentIds(in: all)
        var attempts = 0
        while !missing.isEmpty, attempts < 10 {
            attempts += 1
            var repairRequest = Spark_QueryNodesRequest()
            repairRequest.nodeIds = Spark_TreeNodeIds.with { $0.nodeIds = missing.sorted() }
            repairRequest.includeParents = true

            let repairResponse = try await client.query_nodes(
                request: try await makeAuthenticatedRequest(message: repairRequest),
                options: Self.recoveryCallOptions
            )
            let countBefore = all.count
            for (id, node) in repairResponse.nodes { all[id] = node }
            guard all.count > countBefore else { break }
            missing = Self.missingParentIds(in: all)
        }
        if !missing.isEmpty {
            throw SparkError.invalidResponse(
                "Recovery snapshot incomplete: missing ancestor nodes \(missing.sorted().joined(separator: ", "))"
            )
        }

        return try Self.buildRecoverySnapshot(
            from: all,
            identityPublicKey: signer.identityPublicKey,
            network: config.networkGraphQL
        )
    }

    /// Parent ids referenced by nodes in the map but absent from it.
    static func missingParentIds(in all: [String: Spark_TreeNode]) -> Set<String> {
        var missing = Set<String>()
        for node in all.values where node.hasParentNodeID && !node.parentNodeID.isEmpty {
            if all[node.parentNodeID] == nil { missing.insert(node.parentNodeID) }
        }
        return missing
    }

    /// Pure classification of a complete node map into snapshot leaves + ancestors.
    /// A leaf is a node we own, in a spendable/locked status, that no other node
    /// claims as parent; everything else rides along as ancestor material.
    static func buildRecoverySnapshot(
        from all: [String: Spark_TreeNode],
        identityPublicKey: Data,
        network: String
    ) throws -> SparkRecoverySnapshot {
        // Same set getBalance() counts as owned.
        let ownedStatuses: Set<String> = [
            "AVAILABLE", "TRANSFER_LOCKED", "SPLIT_LOCKED", "AGGREGATE_LOCK", "RENEW_LOCKED"
        ]
        let referencedAsParent = Set(
            all.values.filter { $0.hasParentNodeID && !$0.parentNodeID.isEmpty }.map(\.parentNodeID)
        )

        var leaves: [SparkRecoveryLeaf] = []
        var nodes: [SparkRecoveryNode] = []
        for (id, node) in all {
            let hex = try node.serializedData().hexString
            let isLeaf = node.ownerIdentityPublicKey == identityPublicKey
                && ownedStatuses.contains(node.status)
                && !referencedAsParent.contains(id)
            if isLeaf {
                leaves.append(SparkRecoveryLeaf(
                    id: id,
                    status: node.status,
                    valueSats: Int64(node.value),
                    treeNodeHex: hex
                ))
            } else {
                nodes.append(SparkRecoveryNode(id: id, treeNodeHex: hex))
            }
        }
        // Deterministic ordering so identical wallet state yields identical bytes.
        leaves.sort { $0.id < $1.id }
        nodes.sort { $0.id < $1.id }

        return SparkRecoverySnapshot(
            network: network,
            identityPublicKeyHex: identityPublicKey.hexString,
            leaves: leaves,
            nodes: nodes
        )
    }
}
