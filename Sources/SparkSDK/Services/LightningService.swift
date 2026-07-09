import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

// Constants matching JS SDK
private let htlcTimelockOffset: UInt32 = 70
private let directHtlcTimelockOffset: UInt32 = 85
private let lightningHTLCSequence: UInt32 = 2160

extension SparkWallet {
    public func createLightningInvoice(
        amountSats: Int64,
        memo: String? = nil,
        expirySecs: Int? = nil
    ) async throws -> LightningInvoice {
        let preimage = try randomSecretKeyBytes()
        let paymentHash = Data(CryptoKit.SHA256.hash(data: preimage))
        let paymentHashHex = paymentHash.hexString

        var variables: [String: any Sendable] = [
            "network": config.networkGraphQL,
            "amount_sats": amountSats,
            "payment_hash": paymentHashHex,
        ]
        if let expirySecs { variables["expiry_secs"] = expirySecs }
        if let memo { variables["memo"] = memo }

        let response = try await sspClient.executeRaw(
            query: GraphQLMutations.requestLightningReceive,
            variables: variables
        )

        guard let receive = response["request_lightning_receive"] as? [String: Any],
              let request = receive["request"] as? [String: Any],
              let invoice = request["invoice"] as? [String: Any],
              let encodedInvoice = invoice["encoded_invoice"] as? String,
              let expiresAtStr = invoice["expires_at"] as? String else {
            throw SparkError.invalidResponse("Invalid lightning receive response")
        }

        // Split preimage and store encrypted shares with SOs using config-based identifiers/keys
        let soConfigs = config.signingOperators
        let numOperators = UInt32(soConfigs.count)
        let threshold = (numOperators + 2) / 2

        let shares = try splitSecretWithProofsUniffi(
            secret: preimage, threshold: threshold, numShares: numOperators
        )

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var storeRequest = Spark_StorePreimageShareV2Request()
        storeRequest.paymentHash = paymentHash
        storeRequest.threshold = threshold
        storeRequest.invoiceString = encodedInvoice
        storeRequest.userIdentityPublicKey = signer.identityPublicKey

        // Match shares to operators by array index, encrypt to each SO's identity key
        for i in 0..<soConfigs.count {
            let soConfig = soConfigs[i]
            let share = shares[i]

            var secretShareProto = Spark_SecretShare()
            secretShareProto.secretShare = share.share
            for proof in share.proofs {
                secretShareProto.proofs.append(proof)
            }

            let shareBytes = try secretShareProto.serializedData()
            let identityPubKey = Data(hexString: soConfig.identityPublicKeyHex)!
            let encrypted = try encryptEcies(msg: shareBytes, publicKey: identityPubKey)
            storeRequest.encryptedPreimageShares[soConfig.identifier] = encrypted
        }

        // Compute signing payload (BIP-340 tagged hash)
        var sigHasher = SparkHasher(tag: ["spark", "store_preimage_share", "signing payload"])
        sigHasher.addBytes(paymentHash)
        sigHasher.addMapStringToBytes(storeRequest.encryptedPreimageShares)
        sigHasher.addUint32(threshold)
        sigHasher.addString(encodedInvoice)
        let signingPayload = sigHasher.hash()
        storeRequest.userSignature = try signer.signWithIdentityKey(signingPayload)

        let _ = try await client.store_preimage_share_v2(
            request: ClientRequest(message: storeRequest, metadata: metadata)
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: expiresAtStr) ?? Date().addingTimeInterval(3600)

        return LightningInvoice(
            paymentRequest: encodedInvoice,
            paymentHash: paymentHashHex,
            amountSats: amountSats,
            expiresAt: expiresAt
        )
    }

    /// Pay a Lightning invoice via single-call initiate_preimage_swap_v3 with TransferPackage
    /// (matching the JS reference SDK approach).
    ///
    /// - Parameter idempotencyKey: Optional key for deduplication. If the same key is used
    ///   for multiple calls, the server returns the same result instead of creating duplicates.
    public func payLightningInvoice(
        paymentRequest: String,
        amountSats: Int64? = nil,
        idempotencyKey: String? = nil
    ) async throws -> String {
        let invoiceInfo = try Self.decodeBolt11PaymentHash(paymentRequest)
        let paymentHash = invoiceInfo.paymentHash
        let invoiceAmountSats = amountSats ?? invoiceInfo.amountSats
        guard let invoiceAmountSats else {
            throw SparkError.invalidResponse("Invoice has no amount and amountSats not provided")
        }

        // Get fee estimate from SSP
        let feeEstimate = try await getLightningSendFeeEstimate(
            encodedInvoice: paymentRequest, amountSats: invoiceInfo.amountSats == nil ? amountSats : nil
        )
        let feeSats = UInt64(max(feeEstimate, 1))

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        // Select leaves covering invoice amount + fee (with swap if needed)
        let totalNeeded = invoiceAmountSats + Int64(feeSats)
        let selectedLeaves = try await selectLeavesWithSwap(amountSats: totalNeeded)
        let leafIDs = selectedLeaves.map(\.id)

        // Get SO operator info
        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )
        let soOperators = soListResponse.signingOperators

        // receiverIdentityPubkey = SSP identity public key (matching JS SDK)
        let receiverPubKey = config.sspIdentityPublicKey
        // sender identity public key (for HTLC seqlock destination)
        let senderIdentityPubKey = signer.identityPublicKey
        let transferID = UUID().uuidString.lowercased()

        // Single shared expiry time — 16 days from now (matching JS SDK)
        let expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(16 * 24 * 60 * 60))

        // ── Step 1: Prepare key tweaks (for TransferPackage) ──

        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferID,
            leaves: selectedLeaves,
            receiverPubKey: receiverPubKey,
            signer: signer,
            soOperators: soOperators,
            signingOperatorConfigs: config.signingOperators
        )
        let keyTweakPackage = tweakPackage.keyTweakPackage
        let packageSignature = tweakPackage.signature

        // ── Step 2: Get signing commitments for TransferPackage (HTLC refunds) ──

        var htlcCommitmentsReq = Spark_GetSigningCommitmentsRequest()
        htlcCommitmentsReq.count = 3
        htlcCommitmentsReq.nodeIds = leafIDs
        let htlcCommitmentsResp = try await client.get_signing_commitments(
            request: ClientRequest(message: htlcCommitmentsReq, metadata: metadata)
        )
        let htlcCommitments = htlcCommitmentsResp.signingCommitments

        var htlcCpfpJobs: [Spark_UserSignedTxSigningJob] = []
        var htlcDirectJobs: [Spark_UserSignedTxSigningJob] = []
        var htlcDirectFromCpfpJobs: [Spark_UserSignedTxSigningJob] = []

        for i in 0..<selectedLeaves.count {
            let leaf = selectedLeaves[i]
            let node = leaf.node
            let signingKey = try signer.deriveLeafSigningKey(leaf.id)
            let verifyingKey = Data(node.verifyingPublicKey)

            let cpfpCommitments = htlcCommitments[i].signingNonceCommitments
            let directCommitments = htlcCommitments[i + selectedLeaves.count].signingNonceCommitments
            let directFromCpfpCommitments = htlcCommitments[i + 2 * selectedLeaves.count].signingNonceCommitments

            let (cpfpSeq, _) = try Self.computeNextSequences(from: Data(node.refundTx))
            let bit30 = cpfpSeq & (1 << 30)
            let nextTimelock = cpfpSeq & 0xFFFF

            // HTLC sequences (matching JS SDK getNextHTLCTransactionSequence)
            let htlcNextSequence = bit30 | (nextTimelock + htlcTimelockOffset)
            let htlcDirectSequence = bit30 | (nextTimelock + directHtlcTimelockOffset)

            // CPFP HTLC refund (no fee applied)
            let cpfpHtlc = try constructHtlcTransaction(
                nodeTx: Data(node.nodeTx), vout: 0,
                sequence: htlcNextSequence,
                paymentHash: paymentHash,
                hashlockPubkey: receiverPubKey,
                seqlockPubkey: senderIdentityPubKey,
                htlcSequence: lightningHTLCSequence,
                applyFee: false, feeSats: 0,
                network: networkStr
            )
            htlcCpfpJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                rawTx: cpfpHtlc.tx, sighash: cpfpHtlc.sighash,
                soCommitments: cpfpCommitments
            ))

            // Direct HTLC refund (if directTx exists)
            if !node.directTx.isEmpty {
                let directHtlc = try constructHtlcTransaction(
                    nodeTx: Data(node.directTx), vout: 0,
                    sequence: htlcDirectSequence,
                    paymentHash: paymentHash,
                    hashlockPubkey: receiverPubKey,
                    seqlockPubkey: senderIdentityPubKey,
                    htlcSequence: lightningHTLCSequence,
                    applyFee: true, feeSats: sparkDefaultFeeSats,
                    network: networkStr
                )
                htlcDirectJobs.append(try FrostSigningHelper.buildSigningJob(
                    leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                    rawTx: directHtlc.tx, sighash: directHtlc.sighash,
                    soCommitments: directCommitments
                ))
            }

            // DirectFromCpfp HTLC refund (always, from cpfp node tx)
            let directFromCpfpHtlc = try constructHtlcTransaction(
                nodeTx: Data(node.nodeTx), vout: 0,
                sequence: htlcDirectSequence,
                paymentHash: paymentHash,
                hashlockPubkey: receiverPubKey,
                seqlockPubkey: senderIdentityPubKey,
                htlcSequence: lightningHTLCSequence,
                applyFee: true, feeSats: sparkDefaultFeeSats,
                network: networkStr
            )
            htlcDirectFromCpfpJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                rawTx: directFromCpfpHtlc.tx, sighash: directFromCpfpHtlc.sighash,
                soCommitments: directFromCpfpCommitments
            ))
        }

        // Build TransferPackage
        var transferPackage = Spark_TransferPackage()
        transferPackage.userSignature = packageSignature
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = htlcCpfpJobs
        transferPackage.directLeavesToSend = htlcDirectJobs
        transferPackage.directFromCpfpLeavesToSend = htlcDirectFromCpfpJobs
        for (soID, cipher) in keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }

        // ── Step 3: Get signing commitments for the swap transfer field (regular refunds) ──

        var swapCommitmentsReq = Spark_GetSigningCommitmentsRequest()
        swapCommitmentsReq.count = 3
        swapCommitmentsReq.nodeIds = leafIDs
        let swapCommitmentsResp = try await client.get_signing_commitments(
            request: ClientRequest(message: swapCommitmentsReq, metadata: metadata)
        )
        let swapCommitments = swapCommitmentsResp.signingCommitments

        var swapCpfpJobs: [Spark_UserSignedTxSigningJob] = []

        for i in 0..<selectedLeaves.count {
            let leaf = selectedLeaves[i]
            let node = leaf.node
            let signingKey = try signer.deriveLeafSigningKey(leaf.id)
            let verifyingKey = Data(node.verifyingPublicKey)

            let cpfpCommitments = swapCommitments[i].signingNonceCommitments

            let (nextSequence, _) = try Self.computeNextSequences(from: Data(node.refundTx))

            let cpfpRefund = try constructRefundTx(
                tx: Data(node.nodeTx), vout: 0,
                pubkey: receiverPubKey, network: networkStr, sequence: nextSequence
            )
            swapCpfpJobs.append(try FrostSigningHelper.buildSigningJob(
                leafID: leaf.id, signingKey: signingKey, verifyingKey: verifyingKey,
                rawTx: cpfpRefund.tx, sighash: cpfpRefund.sighash,
                soCommitments: cpfpCommitments
            ))
        }

        // ── Step 4: Single call to initiate_preimage_swap_v3 ──

        var swapRequest = Spark_InitiatePreimageSwapRequest()
        swapRequest.paymentHash = paymentHash
        swapRequest.reason = .send
        swapRequest.receiverIdentityPublicKey = receiverPubKey
        swapRequest.feeSats = feeSats

        var invoiceAmount = Spark_InvoiceAmount()
        invoiceAmount.valueSats = UInt64(invoiceAmountSats)
        invoiceAmount.invoiceAmountProof = Spark_InvoiceAmountProof.with {
            $0.bolt11Invoice = paymentRequest
        }
        swapRequest.invoiceAmount = invoiceAmount

        // transfer field (field 4): only cpfp regular refund jobs (direct/directFromCpfp undefined when transferRequest exists)
        var transferField = Spark_StartUserSignedTransferRequest()
        transferField.transferID = transferID
        transferField.ownerIdentityPublicKey = signer.identityPublicKey
        transferField.receiverIdentityPublicKey = receiverPubKey
        transferField.expiryTime = expiryTime
        transferField.leavesToSend = swapCpfpJobs
        swapRequest.transfer = transferField

        // transferRequest field (field 7): full StartTransferRequest with HTLC TransferPackage
        var transferRequest = Spark_StartTransferRequest()
        transferRequest.transferID = transferID
        transferRequest.ownerIdentityPublicKey = signer.identityPublicKey
        transferRequest.receiverIdentityPublicKey = receiverPubKey
        transferRequest.expiryTime = expiryTime
        transferRequest.transferPackage = transferPackage
        swapRequest.transferRequest = transferRequest

        let swapMetadata: Metadata
        if let idempotencyKey {
            swapMetadata = metadataWithIdempotencyKey(idempotencyKey, base: metadata)
        } else {
            swapMetadata = metadata
        }

        let swapResponse = try await client.initiate_preimage_swap_v3(
            request: ClientRequest(message: swapRequest, metadata: swapMetadata)
        )

        // ── Step 5: SSP call with transfer external ID ──

        // SSP accepts either idempotency_key or user_outbound_transfer_external_id, not both.
        // When an idempotency key is provided, use it; otherwise use the transfer external ID.
        var sspVariables: [String: any Sendable] = [
            "encoded_invoice": paymentRequest,
        ]
        if let idempotencyKey {
            sspVariables["idempotency_key"] = idempotencyKey
        } else {
            sspVariables["user_outbound_transfer_external_id"] = swapResponse.transfer.id
        }

        let sspResponse = try await sspClient.executeRaw(
            query: GraphQLMutations.requestLightningSend,
            variables: sspVariables
        )

        guard let send = sspResponse["request_lightning_send"] as? [String: Any],
              let request = send["request"] as? [String: Any],
              let id = request["id"] as? String else {
            throw SparkError.invalidResponse("Invalid lightning send response")
        }

        return id
    }

    /// Get fee estimate for outbound lightning payment
    public func getLightningSendFeeEstimate(encodedInvoice: String, amountSats: Int64? = nil) async throws -> Int64 {
        var variables: [String: any Sendable] = ["encoded_invoice": encodedInvoice]
        if let amountSats { variables["amount_sats"] = amountSats }

        let response = try await sspClient.executeRaw(
            query: GraphQLQueries.lightningSendFeeEstimate,
            variables: variables
        )

        guard let estimate = response["lightning_send_fee_estimate"] as? [String: Any],
              let feeEstimate = estimate["fee_estimate"] as? [String: Any],
              let originalValue = feeEstimate["original_value"] as? Int64 else {
            throw SparkError.invalidResponse("Invalid fee estimate response")
        }

        // originalValue is in millisats, convert to sats (ceiling)
        return (originalValue + 999) / 1000
    }

    /// Decode BOLT11 invoice to extract payment hash and amount
    static func decodeBolt11PaymentHash(_ invoice: String) throws -> (paymentHash: Data, amountSats: Int64?) {
        let lower = invoice.lowercased()
        guard lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") || lower.hasPrefix("lnbcrt") else {
            throw SparkError.invalidResponse("Not a valid BOLT11 invoice")
        }

        guard let separatorIndex = lower.lastIndex(of: "1") else {
            throw SparkError.invalidResponse("Invalid BOLT11 format")
        }

        let hrp = String(lower[lower.startIndex..<separatorIndex])
        let dataStr = String(lower[lower.index(after: separatorIndex)...])

        guard dataStr.count > 6 else {
            throw SparkError.invalidResponse("BOLT11 data too short")
        }
        let dataWithoutChecksum = String(dataStr.dropLast(6))

        let bech32Chars = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        let bech32Values: [Character: UInt8] = Dictionary(uniqueKeysWithValues:
            bech32Chars.enumerated().map { (Character(String($0.element)), UInt8($0.offset)) }
        )

        var values: [UInt8] = []
        for ch in dataWithoutChecksum {
            guard let val = bech32Values[ch] else {
                throw SparkError.invalidResponse("Invalid bech32 character: \(ch)")
            }
            values.append(val)
        }

        guard values.count > 7 else {
            throw SparkError.invalidResponse("BOLT11 data too short for timestamp")
        }

        var pos = 7 // skip timestamp

        var paymentHash: Data?
        while pos + 3 <= values.count {
            let fieldType = values[pos]
            let dataLength = Int(values[pos + 1]) * 32 + Int(values[pos + 2])
            pos += 3

            guard pos + dataLength <= values.count else { break }

            if fieldType == 1 { // payment hash (p)
                paymentHash = Self.convertBech32Bits(Array(values[pos..<pos + dataLength]), fromBits: 5, toBits: 8, pad: false)
            }

            pos += dataLength
        }

        guard let hash = paymentHash, hash.count == 32 else {
            throw SparkError.invalidResponse("Could not extract payment hash from invoice")
        }

        var amountSats: Int64? = nil
        let amountPart: String
        if hrp.hasPrefix("lnbcrt") {
            amountPart = String(hrp.dropFirst(6))
        } else if hrp.hasPrefix("lnbc") {
            amountPart = String(hrp.dropFirst(4))
        } else if hrp.hasPrefix("lntb") {
            amountPart = String(hrp.dropFirst(4))
        } else {
            amountPart = ""
        }

        if !amountPart.isEmpty {
            let multiplierChar = amountPart.last!
            let numberStr = String(amountPart.dropLast())
            if let number = Int64(numberStr) {
                switch multiplierChar {
                case "m": amountSats = number * 100_000   // milli-BTC
                case "u": amountSats = number * 100       // micro-BTC
                case "n": amountSats = (number + 9) / 10  // nano-BTC (ceiling)
                case "p": amountSats = (number + 9999) / 10000 // pico-BTC
                default:
                    if let fullNumber = Int64(amountPart) {
                        amountSats = fullNumber * 100_000_000 // BTC
                    }
                }
            }
        }

        return (hash, amountSats)
    }

    /// Parse nSequence from the first input of a raw Bitcoin transaction
    static func parseSequenceFromRawTx(_ rawTx: Data) -> UInt32 {
        var offset = 4 // skip version
        if rawTx.count > 5 && rawTx[offset] == 0x00 && rawTx[offset + 1] == 0x01 {
            offset += 2
        }
        offset += 1 // skip input count varint (assume single byte)
        offset += 36 // skip prevout hash (32) + index (4)
        let scriptLen = Int(rawTx[offset])
        offset += 1 + scriptLen
        return rawTx.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    /// Convert between bit widths (bech32 5-bit to 8-bit)
    private static func convertBech32Bits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> Data? {
        var acc: Int = 0
        var bits: Int = 0
        var result: [UInt8] = []
        let maxv = (1 << toBits) - 1

        for value in data {
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad && bits > 0 {
            result.append(UInt8((acc << (toBits - bits)) & maxv))
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            if !pad { /* ignore trailing bits */ }
        }

        return Data(result)
    }
}
