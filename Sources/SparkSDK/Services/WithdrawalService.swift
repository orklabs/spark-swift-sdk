import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// Constants defined in KeyTweakHelper.swift

extension SparkWallet {
    /// Get fee estimate for on-chain withdrawal
    public func getWithdrawalFeeEstimate(
        onChainAddress: String,
        leafIds: [String]
    ) async throws -> FeeQuote {
        let response = try await sspClient.executeRaw(
            query: GraphQLMutations.getFeeEstimate,
            variables: [
                "leaf_external_ids": leafIds,
                "withdrawal_address": onChainAddress,
            ] as [String: any Sendable]
        )

        guard let estimates = response["coop_exit_fee_estimates"] as? [String: Any],
              let fast = estimates["speed_fast"] as? [String: Any],
              let userFee = fast["user_fee"] as? [String: Any],
              let l1Fee = fast["l1_broadcast_fee"] as? [String: Any],
              let userFeeValue = userFee["original_value"] as? Int64,
              let l1FeeValue = l1Fee["original_value"] as? Int64 else {
            throw SparkError.invalidResponse("Invalid fee estimate response")
        }

        // Values are in sats
        let totalFeeSats = userFeeValue + l1FeeValue
        return FeeQuote(feeSats: totalFeeSats, feeRateSatsPerVbyte: 0)
    }

    /// Withdraw funds to an on-chain Bitcoin address via cooperative exit.
    ///
    /// The SSP's fee is deducted from `amountSats`: the recipient receives `amountSats` minus the
    /// fee. Leaves are swapped to denominations that sum to exactly `amountSats` first, so no more
    /// than the requested amount ever leaves the wallet.
    ///
    /// Before anything is signed the SSP's response is verified: the exit transaction must hash
    /// to the txid it reports, pay `onChainAddress` at least `amountSats - fee`, and the connector
    /// transaction must spend it. A response that fails these checks throws
    /// `SparkError.untrustedResponse` and no leaves are handed over.
    ///
    /// - Parameters:
    ///   - onChainAddress: Destination Bitcoin address on the wallet's network (P2PKH, P2SH,
    ///     P2WPKH, P2WSH or P2TR).
    ///   - amountSats: Amount in sats to withdraw, fee included.
    ///   - maxFeeSats: Highest fee the caller accepts. When `nil` the SSP's fee quote for the
    ///     selected leaves is used as the bound. Throws `SparkError.feeExceedsLimit` if the quote
    ///     is above the cap.
    /// - Returns: The L1 transaction ID of the cooperative exit.
    public func withdraw(
        onChainAddress: String,
        amountSats: Int64,
        maxFeeSats: Int64? = nil
    ) async throws -> String {
        guard amountSats > 0 else {
            throw SparkError.invalidArgument("withdrawal amount must be positive, got \(amountSats)")
        }
        // Fail fast on a malformed or wrong-network destination, before any leaf is moved.
        _ = try BitcoinAddress.scriptPubKey(for: onChainAddress, network: config.network)

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        // Select leaves that sum to exactly the requested amount (swapping via the SSP if
        // needed), so `withdraw_all` below cannot send more than was asked for.
        let selectedLeaves = try await selectLeavesWithSwap(amountSats: amountSats)
        let leafIds = selectedLeaves.map(\.id)
        let selectedTotal = selectedLeaves.reduce(0 as Int64) { $0 + $1.valueSats }
        guard selectedTotal == amountSats else {
            throw SparkError.invalidResponse("Selected leaves sum to \(selectedTotal) sats, expected exactly \(amountSats)")
        }

        // Bound the fee before asking the SSP to build the exit.
        let quote = try await getWithdrawalFeeEstimate(onChainAddress: onChainAddress, leafIds: leafIds)
        let feeCap = try CoopExitValidator.resolveFeeCap(
            quotedFeeSats: quote.feeSats, maxFeeSats: maxFeeSats, amountSats: amountSats
        )
        let minimumPayoutSats = amountSats - feeCap

        // Step 1: Request coop exit from SSP — get the exit and connector transactions
        let transferID = UUID().uuidString.lowercased()

        let sspResponse = try await sspClient.executeRaw(
            query: GraphQLMutations.requestCoopExit,
            variables: [
                "leaf_external_ids": leafIds,
                "withdrawal_address": onChainAddress,
                "exit_speed": "FAST",
                "withdraw_all": true,
                "user_outbound_transfer_external_id": transferID,
            ] as [String: any Sendable]
        )

        guard let exitData = sspResponse["request_coop_exit"] as? [String: Any],
              let request = exitData["request"] as? [String: Any],
              let connectorTxHex = request["raw_connector_transaction"] as? String,
              let coopExitTxHex = request["raw_coop_exit_transaction"] as? String,
              let coopExitTxid = request["coop_exit_txid"] as? String else {
            throw SparkError.invalidResponse("Invalid coop exit response")
        }

        // Verify what the SSP built before signing anything.
        let validated = try CoopExitValidator.validate(
            rawCoopExitTransactionHex: coopExitTxHex,
            rawConnectorTransactionHex: connectorTxHex,
            coopExitTxidHex: coopExitTxid,
            payoutAddress: onChainAddress,
            minimumPayoutSats: minimumPayoutSats,
            leafCount: selectedLeaves.count,
            network: config.network
        )
        guard let connectorTxBytes = Data(hexString: connectorTxHex) else {
            throw SparkError.invalidResponse("Invalid connector tx hex")
        }
        let connectorTxId = validated.connectorTx.txid
        let coopExitTxidBytes = validated.exitTxid

        // Step 2: Build LeafRefundTxSigningJobs with connector inputs
        let receiverPubKey = config.sspIdentityPublicKey
        let expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(7 * 24 * 60 * 60 + 300))

        var signingJobs: [Spark_LeafRefundTxSigningJob] = []

        struct LeafSigningData {
            let leafId: String
            let signingKey: Data
            let verifyingKey: Data
            let cpfpRefundTx: Data
            let directRefundTx: Data?
            let directFromCpfpRefundTx: Data
            let cpfpNonce: NonceResult
            let directNonce: NonceResult
            let directFromCpfpNonce: NonceResult
            let cpfpNodeTx: Data
            let directNodeTx: Data?
            let connectorOutputIndex: Int
        }

        var leafDataList: [LeafSigningData] = []

        for i in 0..<selectedLeaves.count {
            let leaf = selectedLeaves[i]
            let node = leaf.node
            let signingKey = try signer.deriveLeafSigningKey(leaf.id)
            let signingPubKey = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)
            let verifyingKey = Data(node.verifyingPublicKey)

            let (cpfpSequence, directSequence) = try Self.computeNextSequences(from: Data(node.refundTx))

            let cpfpNodeTx = Data(node.nodeTx)
            let directNodeTx = node.directTx.isEmpty ? nil : Data(node.directTx)

            let isZeroNode = try Self.isZeroTimelockNode(cpfpNodeTx)

            // Build refund txs (single input)
            let refundTrio = try constructRefundTxTrio(
                cpfpNodeTx: cpfpNodeTx,
                directNodeTx: directNodeTx,
                vout: 0,
                receivingPubkey: receiverPubKey,
                network: networkStr,
                sequence: cpfpSequence,
                directSequence: directSequence,
                feeSats: sparkDefaultFeeSats
            )

            // Add connector input to each refund tx
            let connectorInput = RawTransaction.Input(previousTxid: connectorTxId, previousIndex: UInt32(i))
            let cpfpRefundWithConnector = try Self.addInputToRawTx(refundTrio.cpfpRefund.tx, input: connectorInput)

            var directRefundWithConnector: Data? = nil
            if let directRefund = refundTrio.directRefund, !isZeroNode {
                directRefundWithConnector = try Self.addInputToRawTx(directRefund.tx, input: connectorInput)
            }

            let directFromCpfpRefundWithConnector = try Self.addInputToRawTx(refundTrio.directFromCpfpRefund.tx, input: connectorInput)

            // Generate FROST nonce commitments
            let signingPubKeyForNonce = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)
            let keyPackage = KeyPackage(secretKey: signingKey, publicKey: signingPubKeyForNonce, verifyingKey: verifyingKey)
            let cpfpNonce = try frostNonce(keyPackage: keyPackage)
            let directNonce = try frostNonce(keyPackage: keyPackage)
            let directFromCpfpNonce = try frostNonce(keyPackage: keyPackage)

            // Build SigningJob for each refund tx
            var cpfpSigningJob = Spark_SigningJob()
            cpfpSigningJob.signingPublicKey = signingPubKey
            cpfpSigningJob.rawTx = cpfpRefundWithConnector
            cpfpSigningJob.signingNonceCommitment = Common_SigningCommitment.with {
                $0.hiding = cpfpNonce.commitment.hiding
                $0.binding = cpfpNonce.commitment.binding
            }

            var directFromCpfpSigningJob = Spark_SigningJob()
            directFromCpfpSigningJob.signingPublicKey = signingPubKey
            directFromCpfpSigningJob.rawTx = directFromCpfpRefundWithConnector
            directFromCpfpSigningJob.signingNonceCommitment = Common_SigningCommitment.with {
                $0.hiding = directFromCpfpNonce.commitment.hiding
                $0.binding = directFromCpfpNonce.commitment.binding
            }

            var leafJob = Spark_LeafRefundTxSigningJob()
            leafJob.leafID = leaf.id
            leafJob.refundTxSigningJob = cpfpSigningJob

            if let directTx = directRefundWithConnector {
                var directSigningJob = Spark_SigningJob()
                directSigningJob.signingPublicKey = signingPubKey
                directSigningJob.rawTx = directTx
                directSigningJob.signingNonceCommitment = Common_SigningCommitment.with {
                    $0.hiding = directNonce.commitment.hiding
                    $0.binding = directNonce.commitment.binding
                }
                leafJob.directRefundTxSigningJob = directSigningJob
            }

            leafJob.directFromCpfpRefundTxSigningJob = directFromCpfpSigningJob

            signingJobs.append(leafJob)

            leafDataList.append(LeafSigningData(
                leafId: leaf.id,
                signingKey: signingKey,
                verifyingKey: verifyingKey,
                cpfpRefundTx: cpfpRefundWithConnector,
                directRefundTx: directRefundWithConnector,
                directFromCpfpRefundTx: directFromCpfpRefundWithConnector,
                cpfpNonce: cpfpNonce,
                directNonce: directNonce,
                directFromCpfpNonce: directFromCpfpNonce,
                cpfpNodeTx: cpfpNodeTx,
                directNodeTx: directNodeTx,
                connectorOutputIndex: i
            ))
        }

        // Step 3: Call cooperative_exit_v2 with unsigned refund txs
        var transferRequest = Spark_StartTransferRequest()
        transferRequest.transferID = transferID
        transferRequest.ownerIdentityPublicKey = signer.identityPublicKey
        transferRequest.receiverIdentityPublicKey = receiverPubKey
        transferRequest.expiryTime = expiryTime
        transferRequest.leavesToSend = signingJobs

        var exitReq = Spark_CooperativeExitRequest()
        exitReq.transfer = transferRequest
        exitReq.exitID = UUID().uuidString.lowercased()
        exitReq.exitTxid = coopExitTxidBytes
        exitReq.connectorTx = connectorTxBytes

        let exitResponse = try await client.cooperative_exit_v2(
            request: ClientRequest(message: exitReq, metadata: metadata)
        )

        // Step 4: Sign FROST with SO signing results and aggregate
        var cpfpSignatures: [Spark_UserSignedTxSigningJob] = []
        var directSignatures: [Spark_UserSignedTxSigningJob] = []
        var directFromCpfpSignatures: [Spark_UserSignedTxSigningJob] = []

        for result in exitResponse.signingResults {
            guard let leafData = leafDataList.first(where: { $0.leafId == result.leafID }) else {
                throw SparkError.invalidResponse("Signing result for unknown leaf \(result.leafID)")
            }

            // Parse connector tx output for multi-input sighash
            let connectorPrevOut = try Self.parseTxOutput(connectorTxBytes, vout: UInt32(leafData.connectorOutputIndex))

            // Sign CPFP refund
            let cpfpNodeOutput = try Self.parseTxOutput(leafData.cpfpNodeTx, vout: 0)
            let cpfpSighash = try computeMultiInputSighashUniffi(
                tx: leafData.cpfpRefundTx,
                inputIndex: 0,
                prevOutScripts: [cpfpNodeOutput.script, connectorPrevOut.script],
                prevOutValues: [cpfpNodeOutput.value, connectorPrevOut.value]
            )

            let cpfpAgg = try signAndAggregateFrost(
                sighash: cpfpSighash,
                signingKey: leafData.signingKey,
                verifyingKey: leafData.verifyingKey,
                nonce: leafData.cpfpNonce,
                signingResult: result.refundTxSigningResult
            )

            var cpfpJob = Spark_UserSignedTxSigningJob()
            cpfpJob.leafID = result.leafID
            cpfpJob.signingPublicKey = try getPublicKeyBytes(privateKeyBytes: leafData.signingKey, compressed: true)
            cpfpJob.rawTx = leafData.cpfpRefundTx
            cpfpJob.userSignature = cpfpAgg
            cpfpSignatures.append(cpfpJob)

            // Sign direct refund (if exists)
            if let directRefundTx = leafData.directRefundTx, let directNodeTx = leafData.directNodeTx, result.hasDirectRefundTxSigningResult {
                let directNodeOutput = try Self.parseTxOutput(directNodeTx, vout: 0)
                let directSighash = try computeMultiInputSighashUniffi(
                    tx: directRefundTx,
                    inputIndex: 0,
                    prevOutScripts: [directNodeOutput.script, connectorPrevOut.script],
                    prevOutValues: [directNodeOutput.value, connectorPrevOut.value]
                )

                let directAgg = try signAndAggregateFrost(
                    sighash: directSighash,
                    signingKey: leafData.signingKey,
                    verifyingKey: leafData.verifyingKey,
                    nonce: leafData.directNonce,
                    signingResult: result.directRefundTxSigningResult
                )

                var directJob = Spark_UserSignedTxSigningJob()
                directJob.leafID = result.leafID
                directJob.signingPublicKey = try getPublicKeyBytes(privateKeyBytes: leafData.signingKey, compressed: true)
                directJob.rawTx = directRefundTx
                directJob.userSignature = directAgg
                directSignatures.append(directJob)
            }

            // Sign directFromCpfp refund
            let dcfpSighash = try computeMultiInputSighashUniffi(
                tx: leafData.directFromCpfpRefundTx,
                inputIndex: 0,
                prevOutScripts: [cpfpNodeOutput.script, connectorPrevOut.script],
                prevOutValues: [cpfpNodeOutput.value, connectorPrevOut.value]
            )

            let dcfpAgg = try signAndAggregateFrost(
                sighash: dcfpSighash,
                signingKey: leafData.signingKey,
                verifyingKey: leafData.verifyingKey,
                nonce: leafData.directFromCpfpNonce,
                signingResult: result.directFromCpfpRefundTxSigningResult
            )

            var dcfpJob = Spark_UserSignedTxSigningJob()
            dcfpJob.leafID = result.leafID
            dcfpJob.signingPublicKey = try getPublicKeyBytes(privateKeyBytes: leafData.signingKey, compressed: true)
            dcfpJob.rawTx = leafData.directFromCpfpRefundTx
            dcfpJob.userSignature = dcfpAgg
            directFromCpfpSignatures.append(dcfpJob)
        }

        // Step 5: Prepare key tweaks (transfer leaves to SSP)
        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let soOperators = soListResponse.signingOperators

        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferID,
            leaves: selectedLeaves,
            receiverPubKey: receiverPubKey,
            signer: signer,
            soOperators: soOperators,
            signingOperatorConfigs: config.signingOperators
        )

        var transferPackage = Spark_TransferPackage()
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = cpfpSignatures
        transferPackage.directLeavesToSend = directSignatures
        transferPackage.directFromCpfpLeavesToSend = directFromCpfpSignatures
        for (soID, cipher) in tweakPackage.keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }
        transferPackage.userSignature = tweakPackage.signature

        // Step 6: Finalize transfer with transfer package
        var finalizeReq = Spark_FinalizeTransferWithTransferPackageRequest()
        finalizeReq.transferID = exitResponse.transfer.id
        finalizeReq.ownerIdentityPublicKey = signer.identityPublicKey
        finalizeReq.transferPackage = transferPackage

        let _ = try await client.finalize_transfer_with_transfer_package(
            request: ClientRequest(message: finalizeReq, metadata: metadata)
        )

        // Step 7: Complete coop exit via SSP
        let _ = try await sspClient.executeRaw(
            query: GraphQLMutations.completeCoopExit,
            variables: [
                "user_outbound_transfer_external_id": exitResponse.transfer.id,
            ] as [String: any Sendable]
        )

        return coopExitTxid
    }

    // MARK: - FROST signing helpers

    /// Sign FROST and aggregate with SO signing results
    func signAndAggregateFrost(
        sighash: Data,
        signingKey: Data,
        verifyingKey: Data,
        nonce: NonceResult,
        signingResult: Spark_SigningResult
    ) throws -> Data {
        let selfPublicKey = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)
        let keyPackage = KeyPackage(
            secretKey: signingKey,
            publicKey: selfPublicKey,
            verifyingKey: verifyingKey
        )

        // Convert proto commitments to native
        var nativeCommitments: [String: SigningCommitment] = [:]
        for (soID, protoCommitment) in signingResult.signingNonceCommitments {
            nativeCommitments[soID] = SigningCommitment(
                hiding: protoCommitment.hiding,
                binding: protoCommitment.binding
            )
        }

        let selfSignature = try signFrost(
            msg: sighash,
            keyPackage: keyPackage,
            nonce: nonce.nonce,
            selfCommitment: nonce.commitment,
            statechainCommitments: nativeCommitments,
            adaptorPublicKey: nil
        )

        return try aggregateFrost(
            msg: sighash,
            statechainCommitments: nativeCommitments,
            selfCommitment: nonce.commitment,
            statechainSignatures: signingResult.signatureShares,
            selfSignature: selfSignature,
            statechainPublicKeys: signingResult.publicKeys,
            selfPublicKey: selfPublicKey,
            verifyingKey: verifyingKey,
            adaptorPublicKey: nil
        )
    }

    // MARK: - Raw tx helpers (bounds-checked, see RawTransaction)

    /// Transaction id in internal byte order (the form used in input prevouts).
    static func computeTxId(_ rawTx: Data) throws -> Data {
        try RawTransaction.parse(rawTx).txid
    }

    /// Parse a tx output (script + value) at a given vout.
    static func parseTxOutput(_ rawTx: Data, vout: UInt32) throws -> (script: Data, value: UInt64) {
        let output = try RawTransaction.parse(rawTx).output(at: vout)
        return (script: output.scriptPubKey, value: output.value)
    }

    /// Check if a node tx has zero timelock (sequence & 0xFFFF == 0)
    static func isZeroTimelockNode(_ nodeTx: Data) throws -> Bool {
        (try parseSequenceFromRawTx(nodeTx) & 0xFFFF) == 0
    }

    /// Append an input to a raw transaction, preserving its serialisation format. A witness
    /// transaction gets an empty witness stack for the new input.
    static func addInputToRawTx(_ rawTx: Data, input: RawTransaction.Input) throws -> Data {
        var tx = try RawTransaction.parse(rawTx, context: "refund tx")
        tx.inputs.append(input)
        return tx.serialized(includeWitness: true)
    }
}
