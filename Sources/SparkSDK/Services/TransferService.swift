import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

extension SparkWallet {
    /// Send sats to another Spark wallet identified by its bech32m Spark address
    /// (`spark1...` on mainnet, `sparkrt1...` on regtest). The address must be for the wallet's
    /// network. A Spark invoice is refused with `SparkError.invalidAddress`: sending to it as an
    /// address would ignore its amount, expiry and sender, and the payee would not see it paid.
    public func send(
        receiverSparkAddress: String,
        amountSats: Int64
    ) async throws -> SparkTransfer {
        let receiver = try SparkAddress.decode(receiverSparkAddress, network: config.network)
        return try await send(receiverIdentityPublicKey: receiver, amountSats: amountSats)
    }

    /// Validate the arguments of a Spark transfer before any leaf is selected or swapped.
    static func validateSendArguments(receiverIdentityPublicKey: Data, amountSats: Int64) throws {
        guard amountSats > 0 else {
            throw SparkError.invalidArgument("amountSats must be positive, got \(amountSats)")
        }
        guard receiverIdentityPublicKey.count == 33,
              receiverIdentityPublicKey.first == 0x02 || receiverIdentityPublicKey.first == 0x03 else {
            throw SparkError.invalidArgument("receiverIdentityPublicKey must be a 33-byte compressed secp256k1 public key")
        }
    }

    public func send(
        receiverIdentityPublicKey: Data,
        amountSats: Int64
    ) async throws -> SparkTransfer {
        try Self.validateSendArguments(receiverIdentityPublicKey: receiverIdentityPublicKey, amountSats: amountSats)
        let selectedLeaves = try await selectLeavesWithSwap(amountSats: amountSats)
        return try await transferLeaves(selectedLeaves, receiverIdentityPublicKey: receiverIdentityPublicKey)
    }

    /// Transfer exactly `selectedLeaves` to the receiver in one Spark transfer.
    func transferLeaves(_ selectedLeaves: [SparkLeaf], receiverIdentityPublicKey: Data) async throws -> SparkTransfer {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let soOperators = soListResponse.signingOperators

        // Get SO signing commitments (count=3: cpfp, direct, directFromCpfp)
        let leafIDs = selectedLeaves.map(\.id)
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.count = 3
        commitmentsRequest.nodeIds = leafIDs
        let commitmentsResponse = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsRequest, metadata: metadata)
        )
        let allCommitments = commitmentsResponse.signingCommitments
        guard allCommitments.count >= 3 * selectedLeaves.count else {
            throw SparkError.invalidResponse(
                "Got \(allCommitments.count) signing commitments, need \(3 * selectedLeaves.count)"
            )
        }

        var cpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directRefundJobs: [Spark_UserSignedTxSigningJob] = []
        var directFromCpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []

        let transferID = UUID().uuidString.lowercased()
        let expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(16 * 24 * 60 * 60))

        for i in 0..<selectedLeaves.count {
            let leaf = selectedLeaves[i]
            let node = leaf.node
            let oldSigningKey = try signer.deriveLeafSigningKey(leaf.id)
            let verifyingKey = Data(node.verifyingPublicKey)

            let cpfpCommitments = allCommitments[i].signingNonceCommitments
            let directCommitments = allCommitments[i + selectedLeaves.count].signingNonceCommitments
            let directFromCpfpCommitments = allCommitments[i + 2 * selectedLeaves.count].signingNonceCommitments

            let (cpfpSequence, directSequence) = try Self.computeNextSequences(from: Data(node.refundTx))

            let refundTrio = try Self.leafRefundTrio(
                node: node,
                receivingPubkey: receiverIdentityPublicKey,
                network: networkStr,
                sequence: cpfpSequence,
                directSequence: directSequence
            )

            cpfpRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: oldSigningKey, verifyingKey: verifyingKey,
                rawTx: refundTrio.cpfpRefund.tx, sighash: refundTrio.cpfpRefund.sighash,
                soCommitments: cpfpCommitments
            ))

            if let directRefund = refundTrio.directRefund {
                directRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                    leafID: leaf.id, signingKey: oldSigningKey, verifyingKey: verifyingKey,
                    rawTx: directRefund.tx, sighash: directRefund.sighash,
                    soCommitments: directCommitments
                ))
            }

            directFromCpfpRefundJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: oldSigningKey, verifyingKey: verifyingKey,
                rawTx: refundTrio.directFromCpfpRefund.tx, sighash: refundTrio.directFromCpfpRefund.sighash,
                soCommitments: directFromCpfpCommitments
            ))
        }

        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferID,
            leaves: selectedLeaves,
            receiverPubKey: receiverIdentityPublicKey,
            signer: signer,
            soOperators: soOperators,
            signingOperatorConfigs: config.signingOperators,
            threshold: config.signingThreshold
        )

        var transferPackage = Spark_TransferPackage()
        transferPackage.userSignature = tweakPackage.signature
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = cpfpRefundJobs
        transferPackage.directLeavesToSend = directRefundJobs
        transferPackage.directFromCpfpLeavesToSend = directFromCpfpRefundJobs
        for (soID, cipher) in tweakPackage.keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }

        var transferRequest = Spark_StartTransferRequest()
        transferRequest.transferID = transferID
        transferRequest.ownerIdentityPublicKey = signer.identityPublicKey
        transferRequest.receiverIdentityPublicKey = receiverIdentityPublicKey
        transferRequest.expiryTime = expiryTime
        transferRequest.transferPackage = transferPackage

        let response = try await client.start_transfer_v2(
            request: ClientRequest(message: transferRequest, metadata: metadata)
        )

        return SparkTransfer(response.transfer)
    }

    /// A leaf's refund transactions paying `receivingPubkey` at the given sequences: the CPFP
    /// refund, the direct-from-CPFP refund, and a direct refund when `directNodeTxForRefund`
    /// allows one.
    static func leafRefundTrio(
        node: Spark_TreeNode,
        receivingPubkey: Data,
        network: String,
        sequence: UInt32,
        directSequence: UInt32
    ) throws -> RefundTxTrioResult {
        try constructRefundTxTrio(
            cpfpNodeTx: Data(node.nodeTx),
            directNodeTx: try directNodeTxForRefund(node),
            vout: 0,
            receivingPubkey: receivingPubkey,
            network: network,
            sequence: sequence,
            directSequence: directSequence,
            feeSats: sparkDefaultFeeSats
        )
    }

    /// The direct node transaction a leaf's direct refund spends, or nil when the leaf has none or
    /// is a zero-timelock node. The operators reject a direct refund for a zero node ("zero nodes
    /// must not have a direct refund tx"), and zero-timelock renewal leaves exactly that shape: a
    /// timelock-0 node transaction together with a direct one. Mirrors the reference SDK's
    /// `isZeroNode` check in its refund builders. (Lightning HTLC refunds follow a different rule:
    /// the operators expect a direct HTLC refund whenever a direct node transaction exists.)
    static func directNodeTxForRefund(_ node: Spark_TreeNode) throws -> Data? {
        guard !node.directTx.isEmpty, try !isZeroTimelockNode(Data(node.nodeTx)) else {
            return nil
        }
        return Data(node.directTx)
    }

    /// A refund timelock rounded down to the 100-block interval. The operators validate every
    /// successor refund against the rounded value (`RoundDownToTimelockInterval`), so a leaf whose
    /// timelock is not a multiple of 100 — 740, left by older SDKs — counts as 700.
    static func roundedTimelock(_ timelock: UInt32) -> UInt32 {
        timelock - timelock % sparkTimeLockInterval
    }

    /// Whether a leaf with this refund timelock can be transferred, swapped or exited without a
    /// renewal first. The operators require the rounded timelock to stay above 100 so the next
    /// refund does not reach zero (`ValidateRenewalTimelockFloor`): a refund timelock of at least
    /// 200. Leaves at 100…199 need renewing; below 100 they cannot be renewed either.
    static func isTransferableRefundTimelock(_ timelock: UInt32) -> Bool {
        roundedTimelock(timelock) > sparkTimeLockInterval
    }

    /// The next CPFP and direct refund sequences for a transfer, swap or cooperative exit: the
    /// current refund timelock rounded down to the interval, minus 100, and the direct refunds 50
    /// above that — exactly what the operators expect (`ValidateSequence`), and what the
    /// reference SDK builds (`createDecrementedTimelockRefundTxs` with `enforceTimelocks`). A raw
    /// decrement produced 640 for a leaf at 740 where the operators require 600. Bit 30 is kept.
    /// Lightning HTLC refunds use `htlcSequences` instead: they are not rounded.
    static func computeNextSequences(from refundTxData: Data) throws -> (cpfp: UInt32, direct: UInt32) {
        let rawSequence = try parseSequenceFromRawTx(refundTxData)
        let currentTimelock = rawSequence & 0xFFFF
        let bit30 = rawSequence & (1 << 30)
        // Checked before subtracting: an unchecked decrement used to underflow and trap.
        guard isTransferableRefundTimelock(currentTimelock) else {
            throw SparkError.leafTimelockExhausted(
                "Leaf timelock exhausted (\(currentTimelock), rounded \(roundedTimelock(currentTimelock)) <= "
                    + "\(sparkTimeLockInterval)); needs renewal before it can move"
            )
        }
        let nextTimelock = roundedTimelock(currentTimelock) - sparkTimeLockInterval
        return (bit30 | nextTimelock, bit30 | (nextTimelock + sparkDirectTimelockOffset))
    }

    /// Whether the leaf can be transferred, swapped or exited without an operator renewal
    /// (`isTransferableRefundTimelock` on its refund transaction).
    static func timelockCanDecrement(_ refundTxData: Data) -> Bool {
        // An unparseable refund tx is treated as exhausted: the leaf is skipped rather than
        // crashing the caller or being handed to the coordinator with a bogus sequence.
        guard let sequence = try? parseSequenceFromRawTx(refundTxData) else { return false }
        return isTransferableRefundTimelock(sequence & 0xFFFF)
    }
}
