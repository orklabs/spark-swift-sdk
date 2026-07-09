import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// Constants defined in KeyTweakHelper.swift

extension SparkWallet {

    /// Select leaves that exactly cover the target amounts. If no exact match exists,
    /// triggers a leaf swap via SSP to split leaves into the required denominations.
    func selectLeavesWithSwap(amountSats: Int64) async throws -> [SparkLeaf] {
        let leaves = try await getLeaves()

        // First try exact selection (leaves that sum exactly to the target)
        if let exact = Self.tryExactSelection(leaves, amountSats: amountSats) {
            return exact
        }

        // No exact match — swap leaves via SSP to get right denominations
        let newLeaves = try await requestLeavesSwap(targetAmounts: [amountSats])

        // Retry selection with new leaves (must find exact match — never overspend)
        if let exact = Self.tryExactSelection(newLeaves, amountSats: amountSats) {
            return exact
        }

        throw SparkError.invalidResponse("Failed to select leaves for target amount \(amountSats) after swap")
    }

    /// Try to find leaves that exactly sum to the target amount.
    /// Uses descending greedy — works perfectly for power-of-2 denominations from SSP.
    /// Returns nil if no exact combination found.
    static func tryExactSelection(_ leaves: [SparkLeaf], amountSats: Int64) -> [SparkLeaf]? {
        // Check if single leaf matches exactly
        if let exact = leaves.first(where: { $0.valueSats == amountSats }) {
            return [exact]
        }

        // Greedy descending: take each leaf if it fits in the remaining amount.
        // For power-of-2 denominations this always finds an exact match if one exists.
        let sorted = leaves.sorted { $0.valueSats > $1.valueSats }
        var selected: [SparkLeaf] = []
        var remaining = amountSats
        for leaf in sorted {
            if leaf.valueSats <= remaining {
                selected.append(leaf)
                remaining -= leaf.valueSats
                if remaining == 0 {
                    return selected
                }
            }
        }
        return nil
    }

    /// Request leaf swap via SSP: splits existing leaves into target denominations.
    /// Returns newly claimed leaves after the swap.
    func requestLeavesSwap(targetAmounts: [Int64]) async throws -> [SparkLeaf] {
        let totalTarget = targetAmounts.reduce(0, +)
        let leaves = try await getLeaves()

        // Select leaves covering the total target (smallest first)
        let sorted = leaves.sorted { $0.valueSats < $1.valueSats }
        var selected: [SparkLeaf] = []
        var total: Int64 = 0
        for leaf in sorted {
            if total < totalTarget {
                selected.append(leaf)
                total += leaf.valueSats
            }
        }
        guard total >= totalTarget else {
            throw SparkError.insufficientBalance(need: totalTarget, have: total)
        }

        return try await processSwapBatch(leaves: selected, targetAmounts: targetAmounts)
    }

    /// Process a single batch of leaves for swapping.
    /// 1. Send swap transfer to coordinator (with adaptor key)
    /// 2. Aggregate FROST signatures with adaptor pubkey
    /// 3. Call SSP request_swap mutation
    /// 4. Claim inbound transfer from SSP
    func processSwapBatch(leaves: [SparkLeaf], targetAmounts: [Int64]) async throws -> [SparkLeaf] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString
        let receiverPubKey = config.sspIdentityPublicKey

        // Get SO operator list
        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let soOperators = soListResponse.signingOperators

        // Generate adaptor keypair
        let adaptorPrivKey = try randomSecretKeyBytes()
        let adaptorPubKey = try getPublicKeyBytes(privateKeyBytes: adaptorPrivKey, compressed: true)

        let transferID = UUID().uuidString.lowercased()
        let expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(16 * 24 * 60 * 60))

        // Get signing commitments (only cpfp needed for swap, direct/directFromCpfp cleared)
        let leafIDs = leaves.map(\.id)
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.count = 3
        commitmentsRequest.nodeIds = leafIDs
        let commitmentsResponse = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsRequest, metadata: metadata)
        )
        let allCommitments = commitmentsResponse.signingCommitments

        // Build transfer package (only cpfp refund jobs — direct/directFromCpfp cleared for swaps)
        var cpfpRefundJobs: [Spark_UserSignedTxSigningJob] = []

        // Store signing info for FROST aggregation later
        struct LeafSigningInfo {
            let leafID: String
            let signingKey: Data
            let verifyingKey: Data
            let selfCommitment: SigningCommitment
            let sighash: Data
        }
        var leafSigningInfos: [LeafSigningInfo] = []

        for i in 0..<leaves.count {
            let leaf = leaves[i]
            let node = leaf.node
            let oldSigningKey = try signer.deriveLeafSigningKey(leaf.id)
            let verifyingKey = Data(node.verifyingPublicKey)

            let cpfpCommitments = allCommitments[i].signingNonceCommitments
            let (cpfpSequence, _) = try Self.computeNextSequences(from: Data(node.refundTx))

            // Build CPFP refund tx
            let cpfpNodeTx = Data(node.nodeTx)
            let cpfpRefund = try constructRefundTx(
                tx: cpfpNodeTx, vout: 0,
                pubkey: receiverPubKey, network: networkStr, sequence: cpfpSequence
            )

            // Build signing job with adaptor key
            let publicKey = try getPublicKeyBytes(privateKeyBytes: oldSigningKey, compressed: true)
            let keyPackage = KeyPackage(secretKey: oldSigningKey, publicKey: publicKey, verifyingKey: verifyingKey)
            let nonceResult = try frostNonce(keyPackage: keyPackage)

            var nativeCommitments: [String: SigningCommitment] = [:]
            for (soID, protoCommitment) in cpfpCommitments {
                nativeCommitments[soID] = SigningCommitment(
                    hiding: protoCommitment.hiding,
                    binding: protoCommitment.binding
                )
            }

            let userSignature = try signFrost(
                msg: cpfpRefund.sighash,
                keyPackage: keyPackage,
                nonce: nonceResult.nonce,
                selfCommitment: nonceResult.commitment,
                statechainCommitments: nativeCommitments,
                adaptorPublicKey: adaptorPubKey
            )

            var signingCommitments = Spark_SigningCommitments()
            for (soID, commitment) in cpfpCommitments {
                signingCommitments.signingCommitments[soID] = commitment
            }

            var job = Spark_UserSignedTxSigningJob()
            job.leafID = leaf.id
            job.signingPublicKey = publicKey
            job.rawTx = cpfpRefund.tx
            job.signingNonceCommitment = Common_SigningCommitment.with {
                $0.hiding = nonceResult.commitment.hiding
                $0.binding = nonceResult.commitment.binding
            }
            job.userSignature = userSignature
            job.signingCommitments = signingCommitments
            cpfpRefundJobs.append(job)

            leafSigningInfos.append(LeafSigningInfo(
                leafID: leaf.id,
                signingKey: oldSigningKey,
                verifyingKey: verifyingKey,
                selfCommitment: nonceResult.commitment,
                sighash: cpfpRefund.sighash
            ))

            // Key tweak proofs are handled below by KeyTweakHelper
        }

        // Build key tweaks via shared helper
        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferID,
            leaves: leaves,
            receiverPubKey: receiverPubKey,
            signer: signer,
            soOperators: soOperators,
            signingOperatorConfigs: config.signingOperators
        )

        var transferPackage = Spark_TransferPackage()
        transferPackage.userSignature = tweakPackage.signature
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = cpfpRefundJobs
        // Clear direct/directFromCpfp for swap (matching JS SDK line 320-321)
        transferPackage.directLeavesToSend = []
        transferPackage.directFromCpfpLeavesToSend = []
        for (soID, cipher) in tweakPackage.keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }

        // Send swap transfer to coordinator
        var swapRequest = Spark_InitiateSwapPrimaryTransferRequest()
        var transferReq = Spark_StartTransferRequest()
        transferReq.transferID = transferID
        transferReq.ownerIdentityPublicKey = signer.identityPublicKey
        transferReq.receiverIdentityPublicKey = receiverPubKey
        transferReq.expiryTime = expiryTime
        transferReq.transferPackage = transferPackage
        swapRequest.transfer = transferReq

        var adaptorKeys = Spark_AdaptorPublicKeyPackage()
        adaptorKeys.adaptorPublicKey = adaptorPubKey
        swapRequest.adaptorPublicKeys = adaptorKeys

        let swapResponse = try await client.initiate_swap_primary_transfer(
            request: ClientRequest(message: swapRequest, metadata: metadata)
        )

        guard swapResponse.hasTransfer else {
            throw SparkError.invalidResponse("No transfer in swap response")
        }

        // Aggregate FROST signatures with adaptor pubkey for each leaf
        var adaptorSignatures: [String: Data] = [:]
        for signingResult in swapResponse.signingResults {
            guard let info = leafSigningInfos.first(where: { $0.leafID == signingResult.leafID }),
                  let job = cpfpRefundJobs.first(where: { $0.leafID == signingResult.leafID }) else {
                continue
            }

            let sigResult = signingResult.refundTxSigningResult
            let sighash = info.sighash

            var soCommitments: [String: SigningCommitment] = [:]
            for (soID, commitment) in sigResult.signingNonceCommitments {
                soCommitments[soID] = SigningCommitment(
                    hiding: commitment.hiding,
                    binding: commitment.binding
                )
            }

            var soSignatures: [String: Data] = [:]
            for (soID, sig) in sigResult.signatureShares {
                soSignatures[soID] = sig
            }

            var soPublicKeys: [String: Data] = [:]
            for (soID, pk) in sigResult.publicKeys {
                soPublicKeys[soID] = pk
            }

            let aggregated = try aggregateFrost(
                msg: sighash,
                statechainCommitments: soCommitments,
                selfCommitment: info.selfCommitment,
                statechainSignatures: soSignatures,
                selfSignature: job.userSignature,
                statechainPublicKeys: soPublicKeys,
                selfPublicKey: job.signingPublicKey,
                verifyingKey: Data(signingResult.verifyingKey),
                adaptorPublicKey: adaptorPubKey
            )

            adaptorSignatures[signingResult.leafID] = aggregated
        }

        // Build user leaves for SSP request_swap mutation
        var userLeaves: [[String: String]] = []
        for signingResult in swapResponse.signingResults {
            guard let adaptorSig = adaptorSignatures[signingResult.leafID] else { continue }
            let adaptorSigHex = adaptorSig.hexString

            // Get intermediate refund txs from the swap transfer response
            let transferLeaf = swapResponse.transfer.leaves.first { $0.leaf.id == signingResult.leafID }

            let userLeaf: [String: String] = [
                "leaf_id": signingResult.leafID,
                "raw_unsigned_refund_transaction": Data(transferLeaf?.intermediateRefundTx ?? Data()).hexString,
                "direct_raw_unsigned_refund_transaction": Data(transferLeaf?.intermediateDirectRefundTx ?? Data()).hexString,
                "direct_from_cpfp_raw_unsigned_refund_transaction": Data(transferLeaf?.intermediateDirectFromCpfpRefundTx ?? Data()).hexString,
                "adaptor_added_signature": adaptorSigHex,
                "direct_adaptor_added_signature": adaptorSigHex,
                "direct_from_cpfp_adaptor_added_signature": adaptorSigHex,
            ]
            userLeaves.append(userLeaf)
        }

        // Call SSP request_swap mutation
        let totalAmountSats = leaves.reduce(0 as Int64) { $0 + $1.valueSats }
        let sspResponse = try await sspClient.executeRaw(
            query: GraphQLMutations.requestSwap,
            variables: [
                "adaptor_pubkey": adaptorPubKey.hexString,
                "total_amount_sats": totalAmountSats,
                "target_amount_sats": targetAmounts,
                "fee_sats": Int64(0),
                "user_leaves": userLeaves,
                "user_outbound_transfer_external_id": swapResponse.transfer.id,
            ] as [String: any Sendable]
        )

        guard let requestSwap = sspResponse["request_swap"] as? [String: Any],
              let request = requestSwap["request"] as? [String: Any],
              let status = request["leaves_swap_request_status"] as? String,
              status != "FAILED",
              let inboundTransfer = request["leaves_swap_request_inbound_transfer"] as? [String: Any],
              let sparkId = inboundTransfer["transfer_spark_id"] as? String else {
            throw SparkError.invalidResponse("Leaf swap request failed")
        }

        // Query the inbound transfer by spark ID and claim it
        let inboundTransferProto = try await queryTransferById(sparkId)
        try await claimTransfer(inboundTransferProto)

        // Return the new leaves
        return try await getLeaves()
    }

    /// Query a specific transfer by its ID
    func queryTransferById(_ transferId: String) async throws -> Spark_Transfer {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var filter = Spark_TransferFilter()
        filter.participant = .senderOrReceiverIdentityPublicKey(signer.identityPublicKey)
        filter.transferIds = [transferId]
        filter.network = config.networkProto

        let response = try await client.query_all_transfers(
            request: ClientRequest(message: filter, metadata: metadata)
        )

        guard let transfer = response.transfers.first else {
            throw SparkError.invalidResponse("Transfer not found: \(transferId)")
        }
        return transfer
    }

}
