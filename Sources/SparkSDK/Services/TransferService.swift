import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

extension SparkWallet {
    public func send(
        receiverIdentityPublicKey: Data,
        amountSats: Int64
    ) async throws -> SparkTransfer {
        let selectedLeaves = try await selectLeavesWithSwap(amountSats: amountSats)

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

            let cpfpNodeTx = Data(node.nodeTx)
            let directNodeTx = node.directTx.isEmpty ? nil : Data(node.directTx)

            let refundTrio = try constructRefundTxTrio(
                cpfpNodeTx: cpfpNodeTx,
                directNodeTx: directNodeTx,
                vout: 0,
                receivingPubkey: receiverIdentityPublicKey,
                network: networkStr,
                sequence: cpfpSequence,
                directSequence: directSequence,
                feeSats: sparkDefaultFeeSats
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
            signingOperatorConfigs: config.signingOperators
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

        let transfer = response.transfer
        return SparkTransfer(
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

    static func selectLeaves(_ leaves: [SparkLeaf], amountSats: Int64) throws -> [SparkLeaf] {
        let sorted = leaves.sorted { $0.valueSats > $1.valueSats }
        var selected: [SparkLeaf] = []
        var total: Int64 = 0
        for leaf in sorted {
            selected.append(leaf)
            total += leaf.valueSats
            if total >= amountSats {
                return selected
            }
        }
        throw SparkError.insufficientBalance(need: amountSats, have: total)
    }

    /// Compute next cpfp and direct sequences from a refund tx.
    static func computeNextSequences(from refundTxData: Data) throws -> (cpfp: UInt32, direct: UInt32) {
        let rawSequence = try parseSequenceFromRawTx(refundTxData)
        let currentTimelock = rawSequence & 0xFFFF
        let bit30 = rawSequence & (1 << 30)
        // A leaf at the timelock floor cannot be moved again until it is
        // renewed by the operators. This used to underflow UInt32 and TRAP —
        // crashing the caller instead of failing the one leaf's operation.
        // Strictly greater: the coordinator rejects a decrement that reaches
        // zero ("too small to subtract TimeLockInterval without reaching zero").
        guard currentTimelock > sparkTimeLockInterval else {
            throw SparkError.leafTimelockExhausted(
                "Leaf timelock exhausted (\(currentTimelock) <= \(sparkTimeLockInterval)); needs renewal before it can move"
            )
        }
        let nextTimelock = currentTimelock - sparkTimeLockInterval
        return (bit30 | nextTimelock, bit30 | (nextTimelock + sparkDirectTimelockOffset))
    }

    /// Whether the leaf's refund timelock still has room to decrement — i.e.
    /// the leaf can be transferred/swapped without operator renewal. Strictly
    /// greater: the coordinator rejects decrements that reach zero.
    static func timelockCanDecrement(_ refundTxData: Data) -> Bool {
        // An unparseable refund tx is treated as exhausted: the leaf is skipped rather than
        // crashing the caller or being handed to the coordinator with a bogus sequence.
        guard let sequence = try? parseSequenceFromRawTx(refundTxData) else { return false }
        return (sequence & 0xFFFF) > sparkTimeLockInterval
    }
}
