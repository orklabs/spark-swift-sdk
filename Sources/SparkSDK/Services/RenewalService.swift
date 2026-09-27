import Foundation
import GRPCCore
import SwiftProtobuf

/// Fresh refund txs are minted with this timelock (matches JS INITIAL_TIMELOCK).
private let renewalInitialSequence: UInt32 = 2000
/// Renew when the refund timelock drops below this — prevents it going under
/// 100 after the next transfer, which would freeze the leaf and interfere
/// with watchtowers (matches JS doesTxnNeedRenewed).
let renewalThreshold: UInt32 = 200

/// Outcome of a renewal sweep. Renewals are per-leaf and best-effort: one
/// failing leaf never aborts the rest.
public struct SparkLeafRenewal: Sendable {
    public let checked: Int
    public let renewed: Int
    /// "leafId: error" for each leaf that could not be renewed.
    public let failures: [String]
}

extension SparkLeaf {
    /// Remaining refund-tx timelock in blocks. Below 200 the leaf must be renewed before it can
    /// move; below 100 the coordinator will not renew it either (frozen).
    public var refundTimelockBlocks: UInt32 {
        // Unparseable refund tx → 0 ("exhausted"): never spent, renewal attempted and its
        // failure reported per leaf instead of crashing the caller.
        ((try? SparkWallet.parseSequenceFromRawTx(Data(node.refundTx))) ?? 0) & 0xFFFF
    }

    /// Whether the leaf can be transferred, paid or exited right now without a renewal: its
    /// refund timelock, rounded down to the 100-block interval, is above the floor the coordinator
    /// enforces — at least 200. Leaves at 100…199 are renewable (`isRenewable`);
    /// `getSpendableLeaves()` renews them first.
    public var isSpendable: Bool {
        SparkWallet.isTransferableRefundTimelock(refundTimelockBlocks)
    }

    /// Whether the coordinator will renew this leaf's timelocks (refund timelock in [100, 200)).
    /// A leaf below that range is frozen: only a unilateral exit can recover it.
    public var isRenewable: Bool {
        refundTimelockBlocks >= sparkTimeLockInterval && refundTimelockBlocks < renewalThreshold
    }

    /// Whether the leaf is frozen: its refund timelock is below 100, the minimum the coordinator
    /// renews, and it is too low to move, so only a unilateral on-chain exit can recover it. A
    /// leaf at exactly 100 is renewable, not frozen. Leaves only get here through SDKs that
    /// decremented timelocks without renewing.
    public var isFrozen: Bool {
        refundTimelockBlocks < sparkTimeLockInterval
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
        try await renewLeaves(try await getLeaves())
    }

    /// Renew the renewable leaves among `leaves` (refund timelock in [100, 200)) and report the
    /// ones below the renewal minimum as failures. Each renewal is independent: one failing leaf
    /// never stops the others.
    func renewLeaves(_ leaves: [SparkLeaf]) async throws -> SparkLeafRenewal {
        let (needing, stuck) = Self.renewalCandidates(leaves)
        // The coordinator refuses to renew a leaf whose refund timelock is already below one
        // interval (100 blocks); report those without a round trip.
        var failures = stuck.map {
            "\($0.id): refund timelock \($0.refundTimelockBlocks) is below the coordinator's renewal minimum of \(sparkTimeLockInterval); only a unilateral exit can recover it"
        }
        guard !needing.isEmpty else {
            return SparkLeafRenewal(checked: leaves.count, renewed: 0, failures: failures)
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

    /// Split AVAILABLE leaves into those the coordinator will renew (refund timelock in
    /// [100, 200)) and those it will not (below 100), which only a unilateral exit can recover.
    static func renewalCandidates(_ leaves: [SparkLeaf]) -> (renewable: [SparkLeaf], stuck: [SparkLeaf]) {
        var renewable: [SparkLeaf] = []
        var stuck: [SparkLeaf] = []
        for leaf in leaves where leaf.refundTimelockBlocks < renewalThreshold {
            if leaf.refundTimelockBlocks >= sparkTimeLockInterval {
                renewable.append(leaf)
            } else {
                stuck.append(leaf)
            }
        }
        return (renewable, stuck)
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
        let txs = try Self.refundRenewalTransactions(
            node: node, parent: parent, signingPublicKey: context.signingPublicKey, config: config
        )

        // Order defines which SO commitment each job consumes.
        var specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("node", txs.node.cpfp.tx, txs.node.cpfp.sighash),
            ("directNode", txs.node.direct.tx, txs.node.direct.sighash),
            ("cpfp", txs.refunds.cpfpRefund.tx, txs.refunds.cpfpRefund.sighash),
        ]
        if let direct = txs.refunds.directRefund {
            specs.append(("direct", direct.tx, direct.sighash))
        }
        specs.append(("directFromCpfp", txs.refunds.directFromCpfpRefund.tx, txs.refunds.directFromCpfpRefund.sighash))

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
        let txs = try Self.nodeRenewalTransactions(
            node: node, parent: parent, signingPublicKey: context.signingPublicKey, config: config
        )
        guard let split = txs.split else {
            throw SparkError.invalidResponse("Node renewal for leaf \(node.id) built no split node")
        }

        var specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("split", split.cpfp.tx, split.cpfp.sighash),
            ("directSplit", split.direct.tx, split.direct.sighash),
            ("node", txs.node.cpfp.tx, txs.node.cpfp.sighash),
            ("directNode", txs.node.direct.tx, txs.node.direct.sighash),
            ("cpfp", txs.refunds.cpfpRefund.tx, txs.refunds.cpfpRefund.sighash),
        ]
        if let direct = txs.refunds.directRefund {
            specs.append(("direct", direct.tx, direct.sighash))
        }
        specs.append(("directFromCpfp", txs.refunds.directFromCpfpRefund.tx, txs.refunds.directFromCpfpRefund.sighash))

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
        let txs = try Self.zeroTimelockRenewalTransactions(
            node: node, signingPublicKey: context.signingPublicKey, config: config
        )

        let specs: [(slot: String, tx: Data, sighash: Data)] = [
            ("node", txs.node.cpfp.tx, txs.node.cpfp.sighash),
            ("directNode", txs.node.direct.tx, txs.node.direct.sighash),
            ("cpfp", txs.refunds.cpfpRefund.tx, txs.refunds.cpfpRefund.sighash),
            ("directFromCpfp", txs.refunds.directFromCpfpRefund.tx, txs.refunds.directFromCpfpRefund.sighash),
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

    // MARK: - Renewal transactions (what the operators rebuild, renew_leaf_handler.go)

    struct RenewalTransactions {
        /// The split node (node renewal only).
        var split: NodeTxPairResult?
        let node: NodeTxPairResult
        let refunds: RefundTxTrioResult
    }

    /// The P2TR address a leaf's node transaction pays: the leaf's verifying key with the BIP-86
    /// key-path tweak (`P2TRScriptFromPubKey(leaf.VerifyingPubkey)` on the operators).
    static func leafNodeAddress(verifyingKey: Data, network: SparkNetwork) throws -> String {
        let tweaked = try getTaprootPubkey(verifyingPubkey: verifyingKey)
        guard tweaked.count == 33 else {
            throw SparkError.invalidResponse("Unexpected taproot key length \(tweaked.count)")
        }
        return try BitcoinAddress.p2trAddress(scriptPubKey: Data([0x51, 0x20]) + tweaked.dropFirst(), network: network)
    }

    /// Refund renewal: a new node transaction spending the parent's output `node.vout` at the
    /// node timelock minus 100, paying the leaf's node address, and fresh refunds at 2000.
    static func refundRenewalTransactions(
        node: Spark_TreeNode,
        parent: Spark_TreeNode,
        signingPublicKey: Data,
        config: SparkConfig
    ) throws -> RenewalTransactions {
        let nodeSequence = try parseSequenceFromRawTx(Data(node.nodeTx))
        let bit30 = nodeSequence & (1 << 30)
        let nodeTimelock = nodeSequence & 0xFFFF
        guard nodeTimelock >= sparkTimeLockInterval else {
            throw SparkError.leafTimelockExhausted("Node timelock \(nodeTimelock) too low for refund renewal")
        }
        let newNodeSequence = bit30 | (nodeTimelock - sparkTimeLockInterval)
        let nodePair = try constructNodeTxPair(
            parentTx: Data(parent.nodeTx), vout: node.vout,
            address: try leafNodeAddress(verifyingKey: Data(node.verifyingPublicKey), network: config.network),
            sequence: newNodeSequence,
            directSequence: newNodeSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        return RenewalTransactions(
            split: nil,
            node: nodePair,
            refunds: try initialRefunds(nodePair: nodePair, signingPublicKey: signingPublicKey, config: config)
        )
    }

    /// Node renewal: a zero-timelock split node spending the parent's output `node.vout`, a new
    /// node transaction at 2000 spending it, both paying the leaf's node address, and fresh
    /// refunds at 2000.
    static func nodeRenewalTransactions(
        node: Spark_TreeNode,
        parent: Spark_TreeNode,
        signingPublicKey: Data,
        config: SparkConfig
    ) throws -> RenewalTransactions {
        let address = try leafNodeAddress(verifyingKey: Data(node.verifyingPublicKey), network: config.network)
        let splitPair = try constructNodeTxPair(
            parentTx: Data(parent.nodeTx), vout: node.vout, address: address,
            sequence: 0,
            directSequence: sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        let nodePair = try constructNodeTxPair(
            parentTx: splitPair.cpfp.tx, vout: 0, address: address,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        return RenewalTransactions(
            split: splitPair,
            node: nodePair,
            refunds: try initialRefunds(nodePair: nodePair, signingPublicKey: signingPublicKey, config: config)
        )
    }

    /// Zero-timelock renewal: another zero-timelock node spending the leaf's own node
    /// transaction (output 0), and fresh refunds at 2000 without a direct refund.
    static func zeroTimelockRenewalTransactions(
        node: Spark_TreeNode,
        signingPublicKey: Data,
        config: SparkConfig
    ) throws -> RenewalTransactions {
        let nodePair = try constructNodeTxPair(
            parentTx: Data(node.nodeTx), vout: 0,
            address: try leafNodeAddress(verifyingKey: Data(node.verifyingPublicKey), network: config.network),
            sequence: 0,
            directSequence: sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        // Zero-timelock node → no direct node context for the refunds.
        let refunds = try constructRefundTxTrio(
            cpfpNodeTx: nodePair.cpfp.tx,
            directNodeTx: nil,
            vout: 0,
            receivingPubkey: signingPublicKey,
            network: config.networkString,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
        return RenewalTransactions(split: nil, node: nodePair, refunds: refunds)
    }

    /// Refunds at the initial timelock (2000) spending a renewed node pair.
    private static func initialRefunds(
        nodePair: NodeTxPairResult,
        signingPublicKey: Data,
        config: SparkConfig
    ) throws -> RefundTxTrioResult {
        try constructRefundTxTrio(
            cpfpNodeTx: nodePair.cpfp.tx,
            directNodeTx: nodePair.direct.tx,
            vout: 0,
            receivingPubkey: signingPublicKey,
            network: config.networkString,
            sequence: renewalInitialSequence,
            directSequence: renewalInitialSequence + sparkDirectTimelockOffset,
            feeSats: sparkDefaultFeeSats
        )
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
