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

        // Step 2: SO nonce commitments, three per leaf (cpfp, direct, directFromCpfp), laid out
        // leaf-major like the transfer flow.
        var commitmentsRequest = Spark_GetSigningCommitmentsRequest()
        commitmentsRequest.count = 3
        commitmentsRequest.nodeIds = leafIds
        let commitmentsResponse = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsRequest, metadata: metadata)
        )
        let allCommitments = commitmentsResponse.signingCommitments
        guard allCommitments.count >= 3 * selectedLeaves.count else {
            throw SparkError.invalidResponse(
                "Got \(allCommitments.count) signing commitments, need \(3 * selectedLeaves.count)"
            )
        }

        // Step 3: Refund transactions that also spend a connector output, FROST-signed by the user
        let receiverPubKey = config.sspIdentityPublicKey
        var cpfpJobs: [Spark_UserSignedTxSigningJob] = []
        var directJobs: [Spark_UserSignedTxSigningJob] = []
        var directFromCpfpJobs: [Spark_UserSignedTxSigningJob] = []
        for (i, leaf) in selectedLeaves.enumerated() {
            let signingKey = try signer.deriveLeafSigningKey(leaf.id)
            let verifyingKey = Data(leaf.node.verifyingPublicKey)
            let refunds = try Self.buildConnectorRefunds(
                node: leaf.node,
                receiverPubKey: receiverPubKey,
                connectorTxid: connectorTxId,
                connectorTx: validated.connectorTx,
                connectorVout: UInt32(i),
                network: networkStr
            )
            cpfpJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                rawTx: refunds.cpfp.tx, sighash: refunds.cpfp.sighash,
                soCommitments: allCommitments[i].signingNonceCommitments
            ))
            if let direct = refunds.direct {
                directJobs.append(try FrostSigningHelper.buildSigningJob(
                    leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                    rawTx: direct.tx, sighash: direct.sighash,
                    soCommitments: allCommitments[i + selectedLeaves.count].signingNonceCommitments
                ))
            }
            directFromCpfpJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                rawTx: refunds.directFromCpfp.tx, sighash: refunds.directFromCpfp.sighash,
                soCommitments: allCommitments[i + 2 * selectedLeaves.count].signingNonceCommitments
            ))
        }

        // Step 4: Key tweaks handing the leaves to the SSP, encrypted per operator and signed
        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferID,
            leaves: selectedLeaves,
            receiverPubKey: receiverPubKey,
            signer: signer,
            soOperators: soListResponse.signingOperators,
            signingOperatorConfigs: config.signingOperators,
            threshold: config.signingThreshold
        )

        var transferPackage = Spark_TransferPackage()
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = cpfpJobs
        transferPackage.directLeavesToSend = directJobs
        transferPackage.directFromCpfpLeavesToSend = directFromCpfpJobs
        for (soID, cipher) in tweakPackage.keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }
        transferPackage.userSignature = tweakPackage.signature

        // Step 5: cooperative_exit_v2 with the transfer package. The coordinator no longer accepts
        // the older form (unsigned jobs plus a separate finalize call).
        var transferRequest = Spark_StartTransferRequest()
        transferRequest.transferID = transferID
        transferRequest.ownerIdentityPublicKey = signer.identityPublicKey
        transferRequest.receiverIdentityPublicKey = receiverPubKey
        transferRequest.expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(7 * 24 * 60 * 60 + 300))
        transferRequest.transferPackage = transferPackage

        var exitReq = Spark_CooperativeExitRequest()
        exitReq.transfer = transferRequest
        exitReq.exitID = UUID().uuidString.lowercased()
        exitReq.exitTxid = coopExitTxidBytes
        exitReq.connectorTx = connectorTxBytes

        let exitResponse = try await client.cooperative_exit_v2(
            request: ClientRequest(message: exitReq, metadata: metadata)
        )
        guard exitResponse.hasTransfer else {
            throw SparkError.invalidResponse("cooperative_exit_v2 returned no transfer")
        }

        // Step 6: Complete coop exit via SSP
        let _ = try await sspClient.executeRaw(
            query: GraphQLMutations.completeCoopExit,
            variables: [
                "user_outbound_transfer_external_id": exitResponse.transfer.id,
            ] as [String: any Sendable]
        )

        return coopExitTxid
    }

    // MARK: - Connector refunds

    struct ConnectorRefund: Equatable {
        let tx: Data
        let sighash: Data
    }

    struct ConnectorRefunds: Equatable {
        let cpfp: ConnectorRefund
        /// Absent for zero-timelock nodes and leaves without a direct node transaction.
        let direct: ConnectorRefund?
        let directFromCpfp: ConnectorRefund
    }

    /// The leaf's next refund transactions with the connector output appended as a second input,
    /// and their two-input sighashes (BIP-341, prevouts = node output + connector output). This is
    /// what the user signs for a cooperative exit; mirrors the reference SDK's
    /// `createConnectorRefundTxs` + `signRefundsForCoopExit`.
    static func buildConnectorRefunds(
        node: Spark_TreeNode,
        receiverPubKey: Data,
        connectorTxid: Data,
        connectorTx: RawTransaction,
        connectorVout: UInt32,
        network: String
    ) throws -> ConnectorRefunds {
        let (cpfpSequence, directSequence) = try computeNextSequences(from: Data(node.refundTx))
        let cpfpNodeTx = Data(node.nodeTx)
        let isZeroNode = try isZeroTimelockNode(cpfpNodeTx)
        let directNodeTx: Data? = (node.directTx.isEmpty || isZeroNode) ? nil : Data(node.directTx)

        let trio = try constructRefundTxTrio(
            cpfpNodeTx: cpfpNodeTx,
            directNodeTx: directNodeTx,
            vout: 0,
            receivingPubkey: receiverPubKey,
            network: network,
            sequence: cpfpSequence,
            directSequence: directSequence,
            feeSats: sparkDefaultFeeSats
        )
        let connectorOutput = try connectorTx.output(at: connectorVout)
        let connectorInput = RawTransaction.Input(previousTxid: connectorTxid, previousIndex: connectorVout)
        let nodeOutput = try RawTransaction.parse(cpfpNodeTx, context: "node tx").output(at: 0)

        func withConnector(_ refundTx: Data, spending output: RawTransaction.Output) throws -> ConnectorRefund {
            let tx = try addInputToRawTx(refundTx, input: connectorInput)
            let sighash = try computeMultiInputSighashUniffi(
                tx: tx,
                inputIndex: 0,
                prevOutScripts: [output.scriptPubKey, connectorOutput.scriptPubKey],
                prevOutValues: [output.value, connectorOutput.value]
            )
            return ConnectorRefund(tx: tx, sighash: sighash)
        }

        let cpfp = try withConnector(trio.cpfpRefund.tx, spending: nodeOutput)
        var direct: ConnectorRefund? = nil
        if let directRefund = trio.directRefund, let directNodeTx {
            let directOutput = try RawTransaction.parse(directNodeTx, context: "direct node tx").output(at: 0)
            direct = try withConnector(directRefund.tx, spending: directOutput)
        }
        let directFromCpfp = try withConnector(trio.directFromCpfpRefund.tx, spending: nodeOutput)
        return ConnectorRefunds(cpfp: cpfp, direct: direct, directFromCpfp: directFromCpfp)
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
