import Foundation
import GRPCCore
import SwiftProtobuf

/// Fresh refund txs are minted with this timelock (matches JS INITIAL_TIMELOCK).
private let renewalInitialSequence: UInt32 = 2000
/// Renew when the refund timelock drops below this — prevents it going under
/// 100 after the next transfer, which would freeze the leaf and interfere
/// with watchtowers (matches JS doesTxnNeedRenewed).
private let renewalThreshold: UInt32 = 200

/// Outcome of a renewal sweep. Renewals are per-leaf and best-effort: one
/// failing leaf never aborts the rest.
public struct SparkLeafRenewal: Sendable {
    public let checked: Int
    public let renewed: Int
    /// "leafId: error" for each leaf that could not be renewed.
    public let failures: [String]
}

extension SparkLeaf {
    /// Remaining refund-tx timelock in blocks. Below 200 the leaf needs
    /// renewal; at or below 100 it cannot move at all until renewed.
    public var refundTimelockBlocks: UInt32 {
        // Unparseable refund tx → 0 ("exhausted"): never spent, renewal attempted and its
        // failure reported per leaf instead of crashing the caller.
        ((try? SparkWallet.parseSequenceFromRawTx(Data(node.refundTx))) ?? 0) & 0xFFFF
    }
}

extension SparkWallet {
    /// Renew every leaf whose refund timelock has run low (< 200 blocks).
    /// Spark leaves age: each transfer decrements the refund timelock by 100
    /// and at the floor the coordinator refuses to move them — sends, swaps,
    /// and withdrawals of those sats all fail until renewal. The TS SDK renews
    /// automatically during operations; this is the Swift equivalent, ported
    /// from its leaf-manager/transfer flows.
    ///
    /// Three protocol variants, chosen per leaf like the TS SDK does:
    /// - node timelock == 0 → renew_node_zero_timelock (L1-deposit roots)
    /// - node timelock < 200 → renew_node_timelock (splices in a zero-timelock
    ///   "split node", resets node+refund to 2000)
    /// - otherwise → renew_refund_timelock (decrements node by 100, resets
    ///   refund to 2000)
    public func renewExhaustedLeaves() async throws -> SparkLeafRenewal {
        let leaves = try await getLeaves()
        let needing = leaves.filter { $0.refundTimelockBlocks < renewalThreshold }
        guard !needing.isEmpty else {
            return SparkLeafRenewal(checked: leaves.count, renewed: 0, failures: [])
        }

        // Parents provide the prev-out context for the new node txs.
        let client = try await getCoordinatorClient()
        let parentIds = Set(needing.compactMap { leaf -> String? in
            guard leaf.node.hasParentNodeID, !leaf.node.parentNodeID.isEmpty else { return nil }
            return leaf.node.parentNodeID
        })
        var parents: [String: Spark_TreeNode] = [:]
        if !parentIds.isEmpty {
            var request = Spark_QueryNodesRequest()
            request.nodeIds = Spark_TreeNodeIds.with { $0.nodeIds = parentIds.sorted() }
            let response = try await client.query_nodes(
                request: try await makeAuthenticatedRequest(message: request)
            )
            for (id, node) in response.nodes { parents[id] = node }
        }

        var renewed = 0
        var failures: [String] = []
        for leaf in needing {
            do {
                try await renewLeaf(leaf.node, parents: parents)
                renewed += 1
            } catch {
                failures.append("\(leaf.id): \(error)")
            }
        }
        return SparkLeafRenewal(checked: leaves.count, renewed: renewed, failures: failures)
    }

    private func renewLeaf(_ node: Spark_TreeNode, parents: [String: Spark_TreeNode]) async throws {
        let nodeTimelock = try Self.parseSequenceFromRawTx(Data(node.nodeTx)) & 0xFFFF
        if nodeTimelock == 0 {
            try await renewZeroTimelockNode(node)
            return
        }
        guard node.hasParentNodeID, let parent = parents[node.parentNodeID] else {
            throw SparkError.invalidResponse("Parent node \(node.parentNodeID) not found for leaf \(node.id)")
        }
        if nodeTimelock < renewalThreshold {
            try await renewNodeTimelock(node, parent: parent)
        } else {
            try await renewRefundTimelock(node, parent: parent)
        }
    }

    // MARK: - Variants

    /// Refund-only renewal: new node tx with timelock −100, fresh refunds at 2000.
    private func renewRefundTimelock(_ node: Spark_TreeNode, parent: Spark_TreeNode) async throws {
        let context = try RenewalContext(node: node, signer: signer)
        let parentTx = Data(parent.nodeTx)
        let address = try BitcoinAddress.p2trAddress(
            scriptPubKey: try Self.parseTxOutput(parentTx, vout: 0).script,
            network: config.network
        )

        let nodeSequence = try Self.parseSequenceFromRawTx(Data(node.nodeTx))
        let bit30 = nodeSequence & (1 << 30)
        let nodeTimelock = nodeSequence & 0xFFFF
        guard nodeTimelock >= sparkTimeLockInterval else {
            throw SparkError.leafTimelockExhausted("Node timelock \(nodeTimelock) too low for refund renewal")
        }
        let newNodeSequence = bit30 | (nodeTimelock - sparkTimeLockInterval)

        let nodePair = try constructNodeTxPair(
            parentTx: parentTx, vout: 0, address: address,
            sequence: newNodeSequence,
            directSequence: newNodeSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        let trio = try constructRefundTxTrio(
            cpfpNodeTx: nodePair.cpfp.tx,
            directNodeTx: nodePair.direct.tx,
            vout: 0,
            receivingPubkey: context.signingPublicKey,
            network: config.networkString,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )

        // Order defines which SO commitment each job consumes.
        var specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("node", nodePair.cpfp.tx, nodePair.cpfp.sighash),
            ("directNode", nodePair.direct.tx, nodePair.direct.sighash),
            ("cpfp", trio.cpfpRefund.tx, trio.cpfpRefund.sighash),
        ]
        if let direct = trio.directRefund {
            specs.append(("direct", direct.tx, direct.sighash))
        }
        specs.append(("directFromCpfp", trio.directFromCpfpRefund.tx, trio.directFromCpfpRefund.sighash))

        let jobs = try await signRenewalJobs(specs, context: context)

        var renewJob = Spark_RenewRefundTimelockSigningJob()
        renewJob.nodeTxSigningJob = jobs["node"]!
        renewJob.refundTxSigningJob = jobs["cpfp"]!
        renewJob.directNodeTxSigningJob = jobs["directNode"]!
        if let direct = jobs["direct"] { renewJob.directRefundTxSigningJob = direct }
        renewJob.directFromCpfpRefundTxSigningJob = jobs["directFromCpfp"]!

        var request = Spark_RenewLeafRequest()
        request.leafID = node.id
        request.renewRefundTimelockSigningJob = renewJob
        try await submitRenewal(request, leafId: node.id)
    }

    /// Full node renewal: zero-timelock "split node" spliced above a fresh
    /// node tx at 2000, refunds reset to 2000.
    private func renewNodeTimelock(_ node: Spark_TreeNode, parent: Spark_TreeNode) async throws {
        let context = try RenewalContext(node: node, signer: signer)
        let parentTx = Data(parent.nodeTx)
        let address = try BitcoinAddress.p2trAddress(
            scriptPubKey: try Self.parseTxOutput(parentTx, vout: 0).script,
            network: config.network
        )

        // Split node: spends the parent output with zero timelock.
        let splitPair = try constructNodeTxPair(
            parentTx: parentTx, vout: 0, address: address,
            sequence: 0,
            directSequence: sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        // New node: spends the split node output at the initial timelock.
        let splitAddress = try BitcoinAddress.p2trAddress(
            scriptPubKey: try Self.parseTxOutput(splitPair.cpfp.tx, vout: 0).script,
            network: config.network
        )
        let nodePair = try constructNodeTxPair(
            parentTx: splitPair.cpfp.tx, vout: 0, address: splitAddress,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        let trio = try constructRefundTxTrio(
            cpfpNodeTx: nodePair.cpfp.tx,
            directNodeTx: nodePair.direct.tx,
            vout: 0,
            receivingPubkey: context.signingPublicKey,
            network: config.networkString,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )

        var specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("split", splitPair.cpfp.tx, splitPair.cpfp.sighash),
            ("directSplit", splitPair.direct.tx, splitPair.direct.sighash),
            ("node", nodePair.cpfp.tx, nodePair.cpfp.sighash),
            ("directNode", nodePair.direct.tx, nodePair.direct.sighash),
            ("cpfp", trio.cpfpRefund.tx, trio.cpfpRefund.sighash),
        ]
        if let direct = trio.directRefund {
            specs.append(("direct", direct.tx, direct.sighash))
        }
        specs.append(("directFromCpfp", trio.directFromCpfpRefund.tx, trio.directFromCpfpRefund.sighash))

        let jobs = try await signRenewalJobs(specs, context: context)

        var renewJob = Spark_RenewNodeTimelockSigningJob()
        renewJob.splitNodeTxSigningJob = jobs["split"]!
        renewJob.splitNodeDirectTxSigningJob = jobs["directSplit"]!
        renewJob.nodeTxSigningJob = jobs["node"]!
        renewJob.refundTxSigningJob = jobs["cpfp"]!
        renewJob.directNodeTxSigningJob = jobs["directNode"]!
        if let direct = jobs["direct"] { renewJob.directRefundTxSigningJob = direct }
        renewJob.directFromCpfpRefundTxSigningJob = jobs["directFromCpfp"]!

        var request = Spark_RenewLeafRequest()
        request.leafID = node.id
        request.renewNodeTimelockSigningJob = renewJob
        try await submitRenewal(request, leafId: node.id)
    }

    /// Zero-node renewal: the node tx is at timelock 0 (L1-deposit roots) —
    /// appends another zero-timelock node and resets the refunds.
    private func renewZeroTimelockNode(_ node: Spark_TreeNode) async throws {
        let context = try RenewalContext(node: node, signer: signer)
        let nodeTx = Data(node.nodeTx)
        let address = try BitcoinAddress.p2trAddress(
            scriptPubKey: try Self.parseTxOutput(nodeTx, vout: 0).script,
            network: config.network
        )

        let nodePair = try constructNodeTxPair(
            parentTx: nodeTx, vout: 0, address: address,
            sequence: 0,
            directSequence: sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        // Zero-timelock node → no direct node context for the refunds.
        let trio = try constructRefundTxTrio(
            cpfpNodeTx: nodePair.cpfp.tx,
            directNodeTx: nil,
            vout: 0,
            receivingPubkey: context.signingPublicKey,
            network: config.networkString,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )

        let specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("node", nodePair.cpfp.tx, nodePair.cpfp.sighash),
            ("directNode", nodePair.direct.tx, nodePair.direct.sighash),
            ("cpfp", trio.cpfpRefund.tx, trio.cpfpRefund.sighash),
            ("directFromCpfp", trio.directFromCpfpRefund.tx, trio.directFromCpfpRefund.sighash),
        ]

        let jobs = try await signRenewalJobs(specs, context: context)

        var renewJob = Spark_RenewNodeZeroTimelockSigningJob()
        renewJob.nodeTxSigningJob = jobs["node"]!
        renewJob.refundTxSigningJob = jobs["cpfp"]!
        renewJob.directNodeTxSigningJob = jobs["directNode"]!
        renewJob.directFromCpfpRefundTxSigningJob = jobs["directFromCpfp"]!

        var request = Spark_RenewLeafRequest()
        request.leafID = node.id
        request.renewNodeZeroTimelockSigningJob = renewJob
        try await submitRenewal(request, leafId: node.id)
    }

    // MARK: - Shared plumbing

    private struct RenewalContext {
        let leafId: String
        let signingKey: Data
        let signingPublicKey: Data
        let verifyingKey: Data

        init(node: Spark_TreeNode, signer: SparkSignerProtocol) throws {
            leafId = node.id
            signingKey = try signer.deriveLeafSigningKey(node.id)
            signingPublicKey = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)
            verifyingKey = Data(node.verifyingPublicKey)
        }
    }

    /// Fetch one SO commitment per job (indexed by position) and FROST-sign.
    private func signRenewalJobs(
        _ specs: [(slot: String, tx: Data, sighash: Data)],
        context: RenewalContext
    ) async throws -> [String: Spark_UserSignedTxSigningJob] {
        let client = try await getCoordinatorClient()
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.nodeIds = [context.leafId]
        commitmentsRequest.count = UInt32(specs.count)
        let commitmentsResponse = try await client.get_signing_commitments(
            request: try await makeAuthenticatedRequest(message: commitmentsRequest)
        )
        let allCommitments = commitmentsResponse.signingCommitments
        guard allCommitments.count >= specs.count else {
            throw SparkError.invalidResponse(
                "Got \(allCommitments.count) signing commitments, need \(specs.count)"
            )
        }

        var jobs: [String: Spark_UserSignedTxSigningJob] = [:]
        for (index, spec) in specs.enumerated() {
            jobs[spec.slot] = try FrostSigningHelper.buildSigningJob(
                leafID: context.leafId,
                signingKey: context.signingKey,
                verifyingKey: context.verifyingKey,
                rawTx: spec.tx,
                sighash: spec.sighash,
                soCommitments: allCommitments[index].signingNonceCommitments
            )
        }
        return jobs
    }

    private func submitRenewal(_ request: Spark_RenewLeafRequest, leafId: String) async throws {
        let client = try await getCoordinatorClient()
        let response = try await client.renew_leaf(
            request: try await makeAuthenticatedRequest(message: request)
        )
        guard response.renewResult != nil else {
            throw SparkError.invalidResponse("renew_leaf returned no result for leaf \(leafId)")
        }
    }
}
