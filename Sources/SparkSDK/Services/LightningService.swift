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
        guard amountSats >= 0 else {
            throw SparkError.invalidArgument("amountSats must not be negative, got \(amountSats)")
        }
        if let expirySecs, expirySecs <= 0 {
            throw SparkError.invalidArgument("expirySecs must be positive, got \(expirySecs)")
        }
        if let memo, memo.utf8.count > 639 {
            throw SparkError.invalidArgument("memo must be at most 639 bytes")
        }
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

        // The invoice we hand out must be the one we asked for: our payment hash, our amount,
        // our network. Checked before any preimage share leaves the device.
        let decodedInvoice = try LightningValidator.verifyCreatedInvoice(
            encodedInvoice: encodedInvoice,
            reportedPaymentHashHex: invoice["payment_hash"] as? String,
            expectedPaymentHash: paymentHash,
            expectedAmountSats: amountSats,
            network: config.network
        )

        // Split the preimage and store one encrypted share with each operator.
        let shares = try splitSecretWithProofsUniffi(
            secret: preimage, threshold: config.signingThreshold, numShares: UInt32(config.signingOperators.count)
        )
        let storeRequest = try Self.storePreimageShareRequest(
            paymentHash: paymentHash,
            shares: shares,
            encodedInvoice: encodedInvoice,
            identityPublicKey: signer.identityPublicKey,
            config: config
        )

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let _ = try await client.store_preimage_share_v2(
            request: ClientRequest(message: storeRequest, metadata: metadata)
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.date(from: expiresAtStr) ?? decodedInvoice.expiresAt

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
    /// - Parameters:
    ///   - paymentRequest: BOLT-11 invoice. Must be for the wallet's network.
    ///   - maxFeeSats: Highest routing fee the caller accepts. The SSP's fee estimate is fetched
    ///     first and the payment is refused with `SparkError.feeExceedsLimit` if it is higher.
    ///   - amountSats: Amount to pay for an amountless invoice. Must be omitted (or equal) for an
    ///     invoice that carries an amount.
    ///   - idempotencyKey: Optional key for deduplication. If the same key is used for multiple
    ///     calls, the server returns the same result instead of creating duplicates.
    ///   - transferId: Optional UUID to make the whole send resumable. On
    ///     `SparkError.lightningSendIncomplete` call again with the same id (and the same invoice,
    ///     amount and `idempotencyKey`): when the coordinator already holds that transfer, no leaf
    ///     is selected or locked again — the held transfer must pay this invoice's payment hash
    ///     with at most `maxFeeSats` on top — and the SSP is asked to pay from it. The SSP answers
    ///     a repeated request for a transfer with the request it already has, so a send that went
    ///     through returns its request id instead of paying twice.
    /// - Returns: The SSP lightning send request id.
    public func payLightningInvoice(
        paymentRequest: String,
        maxFeeSats: Int64,
        amountSats: Int64? = nil,
        idempotencyKey: String? = nil,
        transferId: String? = nil
    ) async throws -> String {
        let payment = try LightningPayment(
            paymentRequest: paymentRequest, maxFeeSats: maxFeeSats, amountSats: amountSats,
            idempotencyKey: idempotencyKey, network: config.network
        )
        let resumeTransferId = try LightningValidator.normalizeTransferId(transferId)

        // Resuming a send the coordinator already holds: its leaves are locked for this payment,
        // so selecting leaves again would come up short (or swap for nothing) and a second swap
        // would be refused. Check what it holds and have the SSP pay from that.
        if let resumeTransferId, let held = try await heldLightningSend(transferId: resumeTransferId) {
            try LightningValidator.verifyHeldSend(
                held, transferId: resumeTransferId, for: payment,
                identityPublicKey: signer.identityPublicKey, sspIdentityPublicKey: config.sspIdentityPublicKey
            )
            return try await requestLightningSend(payment, transferId: resumeTransferId)
        }
        let transfer = try await startLightningSend(payment, transferId: resumeTransferId ?? UUID().uuidString.lowercased())
        return try await requestLightningSend(payment, transferId: transfer.id)
    }

    /// The Lightning send this wallet started under `transferId`, as the coordinator holds it —
    /// its HTLC (preimage request) with the transfer — or nil when the coordinator holds none.
    func heldLightningSend(transferId: String) async throws -> Spark_PreimageRequestWithTransfer? {
        var request = Spark_QueryHtlcRequest()
        request.identityPublicKey = signer.identityPublicKey
        request.transferIds = [transferId]
        request.matchRole = .sender
        request.limit = 1
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let response = try await client.query_htlc(request: ClientRequest(message: request, metadata: metadata))
        return response.preimageRequests.first
    }

    /// Steps 1–3 of a Lightning send: quote the fee against the cap, select leaves for amount +
    /// fee (swapping if needed) and hand them to the coordinator as an HTLC transfer to the SSP in
    /// one `initiate_preimage_swap_v3`. Returns the transfer the coordinator now holds.
    func startLightningSend(_ payment: LightningPayment, transferId: String) async throws -> Spark_Transfer {
        let feeEstimate = try await getLightningSendFeeEstimate(
            encodedInvoice: payment.encodedInvoice, amountSats: payment.amountlessInvoiceAmountSats
        )
        let feeSats = UInt64(max(feeEstimate, 1))
        guard Int64(feeSats) <= payment.maxFeeSats else {
            throw SparkError.feeExceedsLimit(feeSats: Int64(feeSats), maxFeeSats: payment.maxFeeSats)
        }

        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        // Select leaves covering invoice amount + fee (with swap if needed)
        let (totalNeeded, overflow) = payment.amountSats.addingReportingOverflow(Int64(feeSats))
        guard !overflow else {
            throw SparkError.invalidArgument("amount plus fee overflows")
        }
        let selectedLeaves = try await selectLeavesWithSwap(amountSats: totalNeeded)

        // Get SO operator info
        let soListResponse = try await client.get_signing_operator_list(
            request: ClientRequest(message: Google_Protobuf_Empty(), metadata: metadata)
        )

        // receiverIdentityPubkey = SSP identity public key (matching JS SDK)
        let receiverPubKey = config.sspIdentityPublicKey

        // ── Step 1: Prepare key tweaks (for TransferPackage) ──

        let (_, tweakPackage) = try KeyTweakHelper.buildSendPackage(
            transferID: transferId,
            leaves: selectedLeaves,
            receiverPubKey: receiverPubKey,
            signer: signer,
            soOperators: soListResponse.signingOperators,
            signingOperatorConfigs: config.signingOperators,
            threshold: config.signingThreshold
        )

        // ── Step 2: Get signing commitments for TransferPackage (HTLC refunds) ──

        var htlcCommitmentsReq = Spark_GetSigningCommitmentsRequest()
        htlcCommitmentsReq.count = 3
        htlcCommitmentsReq.nodeIds = selectedLeaves.map(\.id)
        let htlcCommitmentsResp = try await client.get_signing_commitments(
            request: ClientRequest(message: htlcCommitmentsReq, metadata: metadata)
        )
        let htlcCommitments = htlcCommitmentsResp.signingCommitments
        guard htlcCommitments.count >= 3 * selectedLeaves.count else {
            throw SparkError.invalidResponse("Got \(htlcCommitments.count) signing commitments, need \(3 * selectedLeaves.count)")
        }

        // The HTLC's seqlock path pays the sender identity key.
        let htlcJobs = try buildHtlcSigningJobs(
            selectedLeaves: selectedLeaves, paymentHash: payment.invoice.paymentHash, receiverPubKey: receiverPubKey,
            senderIdentityPubKey: signer.identityPublicKey, htlcCommitments: htlcCommitments, networkStr: config.networkString
        )

        // Build TransferPackage
        var transferPackage = Spark_TransferPackage()
        transferPackage.userSignature = tweakPackage.signature
        transferPackage.hashVariant = .v2
        transferPackage.leavesToSend = htlcJobs.cpfp
        transferPackage.directLeavesToSend = htlcJobs.direct
        transferPackage.directFromCpfpLeavesToSend = htlcJobs.directFromCpfp
        for (soID, cipher) in tweakPackage.keyTweakPackage {
            transferPackage.keyTweakPackage[soID] = cipher
        }

        // ── Step 3: Single call to initiate_preimage_swap_v3 ──

        var transferRequest = Spark_StartTransferRequest()
        transferRequest.transferID = transferId
        transferRequest.ownerIdentityPublicKey = signer.identityPublicKey
        transferRequest.receiverIdentityPublicKey = receiverPubKey
        // 16 days from now (matching JS SDK)
        transferRequest.expiryTime = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(16 * 24 * 60 * 60))
        transferRequest.transferPackage = transferPackage
        let swapRequest = Self.preimageSwapRequest(
            paymentHash: payment.invoice.paymentHash,
            invoiceAmountSats: payment.amountSats,
            bolt11Invoice: payment.encodedInvoice,
            feeSats: feeSats,
            transferRequest: transferRequest
        )

        return try await submitPreimageSwap(
            swapRequest,
            idempotencyKey: Self.preimageSwapIdempotencyKey(idempotencyKey: payment.idempotencyKey, transferId: transferId)
        )
    }

    /// Hand a Lightning send's preimage swap to the coordinator. A failure after which the
    /// coordinator may still have committed the swap — leaves locked under the transfer id —
    /// surfaces as `lightningSendIncomplete` with that id, so the caller can resume instead of
    /// losing track of the leaves until the transfer expires.
    func submitPreimageSwap(_ request: Spark_InitiatePreimageSwapRequest, idempotencyKey: String) async throws -> Spark_Transfer {
        let client = try await getCoordinatorClient()
        let metadata = metadataWithIdempotencyKey(
            idempotencyKey, base: try await getAuthMetadata(for: config.coordinatorAddress)
        )
        do {
            return try await client.initiate_preimage_swap_v3(
                request: ClientRequest(message: request, metadata: metadata)
            ).transfer
        } catch where Self.preimageSwapMayHaveCommitted(error) {
            throw SparkError.lightningSendIncomplete(
                transferId: request.transferRequest.transferID,
                reason: "the preimage swap's outcome is unknown: \(error)"
            )
        }
    }

    /// Whether a failed `initiate_preimage_swap_v3` may still have been committed by the
    /// coordinator. The statuses the operators give a request they refused before committing —
    /// validation, authentication, a leaf or resource that is not available, a lock conflict —
    /// rule it out. Anything else (a connection lost after the request went out, a deadline, a
    /// cancelled task, an internal or unknown error) does not.
    static func preimageSwapMayHaveCommitted(_ error: any Swift.Error) -> Bool {
        guard let rpcError = error as? RPCError else { return true }
        switch rpcError.code {
        case .invalidArgument, .failedPrecondition, .outOfRange, .notFound, .alreadyExists,
             .permissionDenied, .unauthenticated, .resourceExhausted, .aborted, .unimplemented:
            return false
        default:
            return true
        }
    }

    /// Step 4 of a Lightning send: ask the SSP to pay the invoice from the transfer the
    /// coordinator holds. The leaves are locked for that transfer by now, so any failure surfaces
    /// its id for the app to resume (same `transferId`) or reconcile via the SSP.
    func requestLightningSend(_ payment: LightningPayment, transferId: String) async throws -> String {
        let sspVariables = Self.lightningSendVariables(
            encodedInvoice: payment.encodedInvoice,
            amountlessInvoiceAmountSats: payment.amountlessInvoiceAmountSats,
            idempotencyKey: payment.idempotencyKey,
            transferId: transferId
        )
        let sspResponse: [String: Any]
        do {
            sspResponse = try await sspClient.executeRaw(
                query: GraphQLMutations.requestLightningSend,
                variables: sspVariables
            )
        } catch {
            throw SparkError.lightningSendIncomplete(transferId: transferId, reason: String(describing: error))
        }

        guard let send = sspResponse["request_lightning_send"] as? [String: Any],
              let request = send["request"] as? [String: Any],
              let id = request["id"] as? String else {
            throw SparkError.lightningSendIncomplete(
                transferId: transferId, reason: "invalid lightning send response from the SSP"
            )
        }
        return id
    }

    /// The `store_preimage_share_v2` request of a Lightning receive: each operator's share of the
    /// preimage, ECIES-encrypted to its configured identity key. An operator validates the share
    /// at its own index (`Index + 1`, which its identifier encodes), so each gets the share with
    /// that index whatever the order of the configuration — the reference SDK's
    /// `shares[operator.id]`. No `user_signature`: the current protocol reserves that field and
    /// the operators never read it (reference SDK 0.6.5).
    static func storePreimageShareRequest(
        paymentHash: Data,
        shares: [VerifiableSecretShareResult],
        encodedInvoice: String,
        identityPublicKey: Data,
        config: SparkConfig
    ) throws -> Spark_StorePreimageShareV2Request {
        var request = Spark_StorePreimageShareV2Request()
        request.paymentHash = paymentHash
        request.threshold = config.signingThreshold
        request.invoiceString = encodedInvoice
        request.userIdentityPublicKey = identityPublicKey
        for soConfig in config.signingOperators {
            guard let index = operatorShareIndex(soConfig.identifier),
                  let share = shares.first(where: { $0.index == index }) else {
                throw SparkError.invalidArgument("no preimage share for operator \(soConfig.identifier)")
            }
            var secretShareProto = Spark_SecretShare()
            secretShareProto.secretShare = share.share
            secretShareProto.proofs = share.proofs
            guard let identityPubKey = Data(hexString: soConfig.identityPublicKeyHex), !identityPubKey.isEmpty else {
                throw SparkError.invalidArgument("operator \(soConfig.identifier) has no identity public key configured")
            }
            request.encryptedPreimageShares[soConfig.identifier] = try encryptEcies(
                msg: try secretShareProto.serializedData(), publicKey: identityPubKey
            )
        }
        return request
    }

    /// The secret-share index an operator validates its share at: its identifier, a 32-byte
    /// big-endian number equal to its index + 1.
    static func operatorShareIndex(_ identifier: String) -> UInt32? {
        guard identifier.count == 64, let index = UInt32(identifier, radix: 16), index > 0 else { return nil }
        return index
    }

    /// The `initiate_preimage_swap_v3` request of a Lightning send: the HTLC transfer to the SSP
    /// in `transfer_request`, whose receiver the top-level receiver must equal. Only
    /// `transfer_request`: the operators build the swap from it alone, and the legacy `transfer`
    /// field — plain, non-HTLC refunds signed over to the SSP — is reserved in the current
    /// protocol; the reference SDK stopped sending it in 0.9.0.
    static func preimageSwapRequest(
        paymentHash: Data,
        invoiceAmountSats: Int64,
        bolt11Invoice: String,
        feeSats: UInt64,
        transferRequest: Spark_StartTransferRequest
    ) -> Spark_InitiatePreimageSwapRequest {
        var request = Spark_InitiatePreimageSwapRequest()
        request.paymentHash = paymentHash
        request.reason = .send
        request.receiverIdentityPublicKey = transferRequest.receiverIdentityPublicKey
        request.feeSats = feeSats
        request.invoiceAmount = Spark_InvoiceAmount.with {
            $0.valueSats = UInt64(invoiceAmountSats)
            $0.invoiceAmountProof = Spark_InvoiceAmountProof.with { $0.bolt11Invoice = bolt11Invoice }
        }
        request.transferRequest = transferRequest
        return request
    }

    /// The coordinator idempotency key of a Lightning send's preimage swap: the caller's key, else
    /// the transfer id — never none. The coordinator answers a repeated key with the transfer it
    /// already committed instead of running the swap again, so a transport retry of a swap whose
    /// answer was lost, or a retry after `lightningSendIncomplete`, gets that transfer rather than
    /// a duplicate-transfer rejection. The reference SDK always sends one
    /// (`idempotencyKey: transferId`).
    static func preimageSwapIdempotencyKey(idempotencyKey: String?, transferId: String) -> String {
        idempotencyKey ?? transferId
    }

    /// Variables of the SSP's `request_lightning_send`. `amount_sats` is set for an amountless
    /// invoice only — the SSP schema says it "should ONLY be set when the invoice amount is zero",
    /// and without it the SSP cannot pay one (reference SDK, CHANGELOG 0.7.6). The SSP accepts
    /// either `idempotency_key` or `user_outbound_transfer_external_id`, not both.
    static func lightningSendVariables(
        encodedInvoice: String,
        amountlessInvoiceAmountSats: Int64?,
        idempotencyKey: String?,
        transferId: String
    ) -> [String: any Sendable] {
        var variables: [String: any Sendable] = ["encoded_invoice": encodedInvoice]
        if let amountlessInvoiceAmountSats {
            variables["amount_sats"] = amountlessInvoiceAmountSats
        }
        if let idempotencyKey {
            variables["idempotency_key"] = idempotencyKey
        } else {
            variables["user_outbound_transfer_external_id"] = transferId
        }
        return variables
    }

    /// HTLC refund signing jobs (cpfp, direct, directFromCpfp) for a lightning send, one set per leaf.
    private func buildHtlcSigningJobs(
        selectedLeaves: [SparkLeaf],
        paymentHash: Data,
        receiverPubKey: Data,
        senderIdentityPubKey: Data,
        htlcCommitments: [Spark_RequestedSigningCommitments],
        networkStr: String
    ) throws -> (cpfp: [Spark_UserSignedTxSigningJob], direct: [Spark_UserSignedTxSigningJob], directFromCpfp: [Spark_UserSignedTxSigningJob]) {
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

            let (htlcNextSequence, htlcDirectSequence) = try Self.htlcSequences(from: Data(node.refundTx))

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
        return (htlcCpfpJobs, htlcDirectJobs, htlcDirectFromCpfpJobs)
    }

    /// Sequences of a Lightning send's HTLC refunds: the current refund timelock minus 100, plus
    /// 70 for the CPFP HTLC and 85 for the direct ones — the reference SDK's
    /// `getNextHTLCTransactionSequence`, and what the operators rebuild (refund sequence − 30 and
    /// − 15, `lightning_handler.go`). Unlike transfer refunds these are NOT rounded down to the
    /// interval. Spend paths only select leaves `isSpendable` allows, which keeps a leaf the
    /// operators would refuse to let the receiver claim (rounded timelock at the floor) out.
    static func htlcSequences(from refundTxData: Data) throws -> (cpfp: UInt32, direct: UInt32) {
        let rawSequence = try parseSequenceFromRawTx(refundTxData)
        let currentTimelock = rawSequence & 0xFFFF
        guard currentTimelock > sparkTimeLockInterval else {
            throw SparkError.leafTimelockExhausted(
                "Leaf timelock exhausted (\(currentTimelock) <= \(sparkTimeLockInterval)); needs renewal before it can pay"
            )
        }
        let nextTimelock = currentTimelock - sparkTimeLockInterval
        let bit30 = rawSequence & (1 << 30)
        return (bit30 | (nextTimelock + htlcTimelockOffset), bit30 | (nextTimelock + directHtlcTimelockOffset))
    }

    /// Get fee estimate for outbound lightning payment
    public func getLightningSendFeeEstimate(encodedInvoice: String, amountSats: Int64? = nil) async throws -> Int64 {
        var variables: [String: any Sendable] = ["encoded_invoice": encodedInvoice]
        if let amountSats { variables["amount_sats"] = amountSats }

        let response = try await sspClient.executeRaw(
            query: GraphQLQueries.lightningSendFeeEstimate,
            variables: variables
        )

        guard let estimate = response["lightning_send_fee_estimate"] as? [String: Any] else {
            throw SparkError.invalidResponse("Invalid fee estimate response")
        }
        // In the unit the SSP reports (the reference SDK switches on it too).
        return try SspCurrencyAmount.sats(estimate["fee_estimate"] as? [String: Any], field: "lightning fee estimate")
    }

    /// nSequence of the first input of a raw Bitcoin transaction (where Spark keeps leaf timelocks).
    static func parseSequenceFromRawTx(_ rawTx: Data) throws -> UInt32 {
        try RawTransaction.parse(rawTx, context: "leaf tx").firstInputSequence
    }
}
