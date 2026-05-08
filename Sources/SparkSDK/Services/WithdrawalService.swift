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
    /// Fee is deducted from the withdrawal amount.
    /// - Parameters:
    ///   - onChainAddress: Bitcoin address to withdraw to
    ///   - amountSats: Amount in sats to withdraw (fee will be deducted from this)
    /// - Returns: The L1 transaction ID
    public func withdraw(
        onChainAddress: String,
        amountSats: Int64
    ) async throws -> String {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        // Select leaves
        let leaves = try await getLeaves()
        let selectedLeaves = try Self.selectLeaves(leaves, amountSats: amountSats)
        let leafIds = selectedLeaves.map(\.id)

        // Step 1: Request coop exit from SSP — get connector tx
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
              let coopExitTxid = request["coop_exit_txid"] as? String else {
            throw SparkError.invalidResponse("Invalid coop exit response")
        }

        guard let connectorTxBytes = Data(hexString: connectorTxHex) else {
            throw SparkError.invalidResponse("Invalid connector tx hex")
        }

        // Parse connector tx to get connector outputs and txid
        let connectorTxId = Self.computeTxId(connectorTxBytes)

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

            let (cpfpSequence, directSequence) = Self.computeNextSequences(from: Data(node.refundTx))

            let cpfpNodeTx = Data(node.nodeTx)
            let directNodeTx = node.directTx.isEmpty ? nil : Data(node.directTx)

            let isZeroNode = Self.isZeroTimelockNode(cpfpNodeTx)

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
            let connectorInput = Self.makeConnectorInputBytes(txId: connectorTxId, vout: UInt32(i))
            let cpfpRefundWithConnector = Self.addInputToRawTx(refundTrio.cpfpRefund.tx, input: connectorInput)

            var directRefundWithConnector: Data? = nil
            if let directRefund = refundTrio.directRefund, !isZeroNode {
                directRefundWithConnector = Self.addInputToRawTx(directRefund.tx, input: connectorInput)
            }

            let directFromCpfpRefundWithConnector = Self.addInputToRawTx(refundTrio.directFromCpfpRefund.tx, input: connectorInput)

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
        let coopExitTxidBytes = Data(Data(hexString: coopExitTxid)!.reversed())

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
            let connectorPrevOut = Self.parseTxOutput(connectorTxBytes, vout: UInt32(leafData.connectorOutputIndex))

            // Sign CPFP refund
            let cpfpNodeOutput = Self.parseTxOutput(leafData.cpfpNodeTx, vout: 0)
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
                let directNodeOutput = Self.parseTxOutput(directNodeTx, vout: 0)
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

    // MARK: - Raw tx helpers

    /// Compute txid from raw transaction bytes (double SHA-256)
    /// Returns bytes in internal byte order (reversed from display hex)
    static func computeTxId(_ rawTx: Data) -> Data {
        // Strip witness data if present to get the txid serialization
        let strippedTx = stripWitness(rawTx)
        let hash1 = Data(CryptoKit.SHA256.hash(data: strippedTx))
        let hash2 = Data(CryptoKit.SHA256.hash(data: hash1))
        // Return in internal byte order (used as prevout hash in inputs)
        return hash2
    }

    /// Strip witness data from a segwit transaction to get legacy serialization
    static func stripWitness(_ rawTx: Data) -> Data {
        var offset = 4 // skip version
        let hasWitness = rawTx.count > 5 && rawTx[offset] == 0x00 && rawTx[offset + 1] == 0x01
        if !hasWitness { return rawTx }

        var result = Data()
        result.append(rawTx[0..<4]) // version

        offset += 2 // skip marker + flag

        // Parse inputs
        let (inputCount, inputCountLen) = readVarInt(rawTx, at: offset)
        let inputCountStart = offset
        offset += inputCountLen

        // Skip all inputs
        for _ in 0..<inputCount {
            offset += 36 // txid + vout
            let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: offset)
            offset += scriptLenLen + Int(scriptLen) + 4 // script + sequence
        }

        // Parse outputs
        let (outputCount, outputCountLen) = readVarInt(rawTx, at: offset)
        offset += outputCountLen
        for _ in 0..<outputCount {
            offset += 8 // value
            let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: offset)
            offset += scriptLenLen + Int(scriptLen)
        }

        let afterOutputs = offset

        // result = version + inputs + outputs + locktime
        result.append(rawTx[inputCountStart..<afterOutputs])
        result.append(rawTx[(rawTx.count - 4)...]) // locktime

        return result
    }

    /// Parse a tx output (script + value) at a given vout
    static func parseTxOutput(_ rawTx: Data, vout: UInt32) -> (script: Data, value: UInt64) {
        var offset = 4 // skip version
        if rawTx.count > 5 && rawTx[offset] == 0x00 && rawTx[offset + 1] == 0x01 {
            offset += 2 // skip segwit marker + flag
        }

        // Skip inputs
        let (inputCount, inputCountLen) = readVarInt(rawTx, at: offset)
        offset += inputCountLen
        for _ in 0..<inputCount {
            offset += 36
            let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: offset)
            offset += scriptLenLen + Int(scriptLen) + 4
        }

        // Parse outputs
        let (_, outputCountLen) = readVarInt(rawTx, at: offset)
        offset += outputCountLen

        for i in 0..<(vout + 1) {
            let value = rawTx.subdata(in: offset..<(offset + 8))
                .withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            offset += 8
            let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: offset)
            offset += scriptLenLen
            let script = rawTx.subdata(in: offset..<(offset + Int(scriptLen)))
            offset += Int(scriptLen)

            if i == vout {
                return (script: script, value: value)
            }
        }

        fatalError("vout \(vout) not found in transaction")
    }

    /// Check if a node tx has zero timelock (sequence == 0)
    static func isZeroTimelockNode(_ nodeTx: Data) -> Bool {
        let seq = parseSequenceFromRawTx(nodeTx)
        return (seq & 0xFFFF) == 0
    }

    /// Create raw bytes for a connector input (txid + vout + empty script + sequence)
    static func makeConnectorInputBytes(txId: Data, vout: UInt32) -> Data {
        var input = Data()
        // txid is already in internal byte order (reversed from display)
        input.append(txId)
        // vout (LE)
        var voutLE = vout.littleEndian
        input.append(Data(bytes: &voutLE, count: 4))
        // scriptSig length = 0
        input.append(UInt8(0))
        // sequence = 0xFFFFFFFF
        var seq: UInt32 = 0xFFFFFFFF
        input.append(Data(bytes: &seq, count: 4))
        return input
    }

    /// Add an input to a raw (non-witness) transaction
    static func addInputToRawTx(_ rawTx: Data, input: Data) -> Data {
        var offset = 4 // skip version

        // Check for segwit marker
        let hasWitness = rawTx.count > 5 && rawTx[offset] == 0x00 && rawTx[offset + 1] == 0x01
        if hasWitness {
            offset += 2
        }

        // Read input count
        let (inputCount, inputCountLen) = readVarInt(rawTx, at: offset)
        let inputCountOffset = offset
        offset += inputCountLen

        // Find the end of all inputs
        for _ in 0..<inputCount {
            offset += 36 // txid + vout
            let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: offset)
            offset += scriptLenLen + Int(scriptLen) + 4 // script + sequence
        }
        let afterInputs = offset

        // Build new tx
        var result = Data()

        if hasWitness {
            // version + marker + flag
            result.append(rawTx[0..<4])
            result.append(contentsOf: [0x00, 0x01])
        } else {
            result.append(rawTx[0..<4]) // version
        }

        // New input count
        result.append(encodeVarInt(inputCount + 1))
        // Existing inputs (skip old input count bytes)
        result.append(rawTx[(inputCountOffset + inputCountLen)..<afterInputs])
        // New connector input
        result.append(input)

        if hasWitness {
            // outputs section
            let outputsStart = afterInputs
            // Find end of outputs
            var outOffset = outputsStart
            let (outputCount, outputCountLen) = readVarInt(rawTx, at: outOffset)
            outOffset += outputCountLen
            for _ in 0..<outputCount {
                outOffset += 8
                let (scriptLen, scriptLenLen) = readVarInt(rawTx, at: outOffset)
                outOffset += scriptLenLen + Int(scriptLen)
            }
            let afterOutputs = outOffset

            result.append(rawTx[outputsStart..<afterOutputs])

            // Existing witness data
            for _ in 0..<inputCount {
                let (witnessCount, witnessCountLen) = readVarInt(rawTx, at: outOffset)
                let witnessStart = outOffset
                outOffset += witnessCountLen
                for _ in 0..<witnessCount {
                    let (itemLen, itemLenLen) = readVarInt(rawTx, at: outOffset)
                    outOffset += itemLenLen + Int(itemLen)
                }
                result.append(rawTx[witnessStart..<outOffset])
            }
            // Empty witness for new input
            result.append(UInt8(0x00))

            // locktime
            result.append(rawTx[(rawTx.count - 4)...])
        } else {
            // Rest of tx (outputs + locktime)
            result.append(rawTx[afterInputs...])
        }

        return result
    }

    /// Read a Bitcoin varint from data at offset. Returns (value, bytesRead)
    static func readVarInt(_ data: Data, at offset: Int) -> (UInt64, Int) {
        let first = data[offset]
        if first < 0xFD {
            return (UInt64(first), 1)
        } else if first == 0xFD {
            let val = data.subdata(in: (offset + 1)..<(offset + 3))
                .withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
            return (UInt64(val), 3)
        } else if first == 0xFE {
            let val = data.subdata(in: (offset + 1)..<(offset + 5))
                .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            return (UInt64(val), 5)
        } else {
            let val = data.subdata(in: (offset + 1)..<(offset + 9))
                .withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            return (val, 9)
        }
    }

    /// Encode an integer as a Bitcoin varint
    static func encodeVarInt(_ value: UInt64) -> Data {
        if value < 0xFD {
            return Data([UInt8(value)])
        } else if value <= 0xFFFF {
            var result = Data([0xFD])
            var val = UInt16(value).littleEndian
            result.append(Data(bytes: &val, count: 2))
            return result
        } else if value <= 0xFFFFFFFF {
            var result = Data([0xFE])
            var val = UInt32(value).littleEndian
            result.append(Data(bytes: &val, count: 4))
            return result
        } else {
            var result = Data([0xFF])
            var val = value.littleEndian
            result.append(Data(bytes: &val, count: 8))
            return result
        }
    }
}
