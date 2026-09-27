import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

private let initialRootNodeSequence: UInt32 = 0
private let initialRefundSequence: UInt32 = 2000 // INITIAL_TIMELOCK from JS SDK

extension SparkWallet {
    /// Generate a one-time deposit address. After sending BTC on-chain, call `claimDeposit(txID:)`.
    public func getDepositAddress() async throws -> DepositAddress {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        let leafId = UUID().uuidString.lowercased()
        let keyPair = try signer.deriveLeafSigningKeyPair(leafId)

        var request = Spark_GenerateDepositAddressRequest()
        request.identityPublicKey = signer.identityPublicKey
        request.signingPublicKey = keyPair.publicKey
        request.network = config.networkProto
        request.leafID = leafId
        request.hashVariant = .v2

        let response = try await client.generate_deposit_address(
            request: ClientRequest(message: request, metadata: metadata)
        )

        let deposit = response.depositAddress
        try DepositAddressVerifier.verify(
            deposit,
            userSigningPublicKey: keyPair.publicKey,
            identityPublicKey: signer.identityPublicKey,
            isStatic: false,
            config: config
        )
        return DepositAddress(
            address: deposit.address,
            leafId: leafId,
            userPublicKey: keyPair.publicKey,
            verifyingKey: Data(deposit.verifyingKey)
        )
    }

    /// Claim an on-chain deposit after it has been confirmed.
    /// The transaction's outputs are matched against the wallet's unused deposit addresses, so
    /// the claim is built for the leaf that actually received the funds.
    /// - Parameter txID: The on-chain transaction ID (hex string)
    /// - Parameter vout: The output index. Pass `nil` (the default) to locate the output that
    ///   pays one of this wallet's deposit addresses; an explicit index must pay one of them.
    public func claimDeposit(txID: String, vout: UInt32? = nil) async throws {
        let txidBytes = try Self.txidBytes(fromDisplayHex: txID)
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)
        let networkStr = config.networkString

        // Fetch raw tx from electrs and make sure it is the transaction we asked for.
        let rawTx = try await fetchRawTransaction(txID: txID)
        guard try RawTransaction.parse(rawTx, context: "deposit tx").txid == txidBytes else {
            throw SparkError.untrustedResponse("block explorer returned a transaction that does not hash to \(txID)")
        }

        // Query unused deposit addresses and find the output that pays one of them
        var queryReq = Spark_QueryUnusedDepositAddressesRequest()
        queryReq.identityPublicKey = signer.identityPublicKey
        queryReq.network = config.networkProto
        let queryResp = try await client.query_unused_deposit_addresses(
            request: ClientRequest(message: queryReq, metadata: metadata)
        )
        let candidates = queryResp.depositAddresses.filter { !$0.leafID.isEmpty }
        let match = try DepositMatcher.match(
            rawTx: rawTx,
            candidateAddresses: candidates.map(\.depositAddress),
            requestedVout: vout,
            network: config.network
        )
        guard let depositInfo = candidates.first(where: { $0.depositAddress == match.address }) else {
            throw SparkError.invalidResponse("No unused deposit address found. Generate one first with getDepositAddress().")
        }
        let outputIndex = match.vout

        let leafId = depositInfo.leafID
        let verifyingKey = Data(depositInfo.verifyingPublicKey)

        let signingKey = try signer.deriveLeafSigningKey(leafId)
        let signingPubKey = try getPublicKeyBytes(privateKeyBytes: signingKey, compressed: true)

        // Create the CPFP root node transaction spending the deposit UTXO
        // Root node tx uses sequence=0, direct uses DIRECT_TIMELOCK_OFFSET
        let rootNodeTx = try constructNodeTxPair(
            parentTx: rawTx, vout: outputIndex,
            address: depositInfo.depositAddress,
            sequence: initialRootNodeSequence,
            directSequence: 50, // DIRECT_TIMELOCK_OFFSET
            feeSats: sparkDefaultFeeSats
        )

        // Create initial timelock refund txs
        // cpfp refund: sequence = 2000, directFromCpfp: sequence = 2050 (2000 + DIRECT_OFFSET)
        let refundTrio = try constructRefundTxTrio(
            cpfpNodeTx: rootNodeTx.cpfp.tx,
            directNodeTx: nil,
            vout: 0,
            receivingPubkey: signingPubKey,
            network: networkStr,
            sequence: initialRefundSequence,
            directSequence: initialRefundSequence + 50,
            feeSats: sparkDefaultFeeSats
        )

        // Get signing commitments (3: root, cpfpRefund, directFromCpfpRefund)
        var commitmentsReq = Spark_GetSigningCommitmentsRequest()
        commitmentsReq.count = 3
        commitmentsReq.nodeIDCount = 1
        let commitmentsResp = try await client.get_signing_commitments(
            request: ClientRequest(message: commitmentsReq, metadata: metadata)
        )
        let allCommitments = commitmentsResp.signingCommitments
        guard allCommitments.count >= 3 else {
            throw SparkError.invalidResponse("Got \(allCommitments.count) signing commitments, need 3")
        }

        // Build signing jobs
        let rootJob = try FrostSigningHelper.buildSigningJob(
            leafID: leafId,
            signingKey: signingKey, verifyingKey: verifyingKey,
            rawTx: rootNodeTx.cpfp.tx, sighash: rootNodeTx.cpfp.sighash,
            soCommitments: allCommitments[0].signingNonceCommitments
        )

        let refundJob = try FrostSigningHelper.buildSigningJob(
            leafID: leafId,
            signingKey: signingKey, verifyingKey: verifyingKey,
            rawTx: refundTrio.cpfpRefund.tx, sighash: refundTrio.cpfpRefund.sighash,
            soCommitments: allCommitments[1].signingNonceCommitments
        )

        let directFromCpfpRefundJob = try FrostSigningHelper.buildSigningJob(
            leafID: leafId,
            signingKey: signingKey, verifyingKey: verifyingKey,
            rawTx: refundTrio.directFromCpfpRefund.tx, sighash: refundTrio.directFromCpfpRefund.sighash,
            soCommitments: allCommitments[2].signingNonceCommitments
        )

        var utxo = Spark_UTXO()
        utxo.rawTx = rawTx
        utxo.vout = outputIndex
        utxo.network = config.networkProto
        utxo.txid = txidBytes

        var finalizeReq = Spark_FinalizeDepositTreeCreationRequest()
        finalizeReq.identityPublicKey = signer.identityPublicKey
        finalizeReq.onChainUtxo = utxo
        finalizeReq.rootTxSigningJob = rootJob
        finalizeReq.refundTxSigningJob = refundJob
        finalizeReq.directFromCpfpRefundTxSigningJob = directFromCpfpRefundJob

        let finalizeResp = try await client.finalize_deposit_tree_creation(
            request: ClientRequest(message: finalizeReq, metadata: metadata)
        )

        _ = finalizeResp.rootNode
    }

    /// Generate a static (reusable) deposit address.
    public func getStaticDepositAddress() async throws -> StaticDepositAddress {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        let staticKey = try signer.deriveStaticDepositKey(0)
        let staticPubKey = try getPublicKeyBytes(privateKeyBytes: staticKey, compressed: true)

        var request = Spark_GenerateStaticDepositAddressRequest()
        request.signingPublicKey = staticPubKey
        request.identityPublicKey = signer.identityPublicKey
        request.network = config.networkProto
        request.hashVariant = .v2

        let response = try await client.generate_static_deposit_address(
            request: ClientRequest(message: request, metadata: metadata)
        )

        let deposit = response.depositAddress
        try DepositAddressVerifier.verify(
            deposit,
            userSigningPublicKey: staticPubKey,
            identityPublicKey: signer.identityPublicKey,
            isStatic: true,
            config: config
        )
        return StaticDepositAddress(
            address: deposit.address,
            verifyingKey: Data(deposit.verifyingKey)
        )
    }

    /// Claim a static deposit for whatever credit the SSP quotes, unchecked.
    /// - Parameters:
    ///   - transactionId: The on-chain tx id
    ///   - outputIndex: The output index (vout)
    /// Returns the Spark transfer ID for the claimed deposit.
    @available(*, deprecated, message: """
        Signs whatever credit the SSP quotes. Use claimStaticDepositWithMaxFee, or \
        claimStaticDeposit(transactionId:outputIndex:quote:) with a quote you checked.
        """)
    @discardableResult
    public func claimStaticDeposit(transactionId: String, outputIndex: UInt32 = 0) async throws -> String {
        let quote = try await getDepositFeeEstimate(transactionId: transactionId, outputIndex: outputIndex)
        return try await claimStaticDeposit(transactionId: transactionId, outputIndex: outputIndex, quote: quote)
    }

    /// Claim a static deposit for exactly the credit of `quote` — the SSP-signed quote
    /// `getDepositFeeEstimate` returned for this output — as the reference SDK's
    /// `claimStaticDeposit` does: the wallet signs a fixed-amount claim for that credit and the
    /// SSP's quote signature, so the SSP cannot credit less.
    /// Returns the Spark transfer ID for the claimed deposit.
    @discardableResult
    public func claimStaticDeposit(
        transactionId: String,
        outputIndex: UInt32 = 0,
        quote: DepositFeeEstimate
    ) async throws -> String {
        let outpoint = try DepositOutpoint(txid: transactionId, vout: outputIndex)
        guard quote.creditAmountSats > 0 else {
            throw SparkError.invalidArgument("the quote credits \(quote.creditAmountSats) sats; nothing to claim")
        }
        guard let quoteSignature = Data(hexString: quote.quoteSignature), !quoteSignature.isEmpty else {
            throw SparkError.invalidResponse("the SSP's quote signature is not hex")
        }
        let statement = Self.staticDepositStatement(
            outpoint, network: config.network, requestType: .fixed,
            creditAmountSats: UInt64(quote.creditAmountSats), authorization: quoteSignature
        )
        let signature = try signer.signWithIdentityKey(Data(CryptoKit.SHA256.hash(data: statement)))
        let staticSecretKey = try signer.deriveStaticDepositKey(0)

        let claimResponse = try await sspClient.executeRaw(
            query: GraphQLMutations.claimStaticDeposit,
            variables: [
                "transaction_id": outpoint.txid,
                "output_index": Int(outpoint.vout),
                "network": config.networkGraphQL,
                "request_type": "FIXED_AMOUNT",
                "credit_amount_sats": quote.creditAmountSats,
                "deposit_secret_key": staticSecretKey.hexString,
                "signature": signature.hexString,
                "quote_signature": quote.quoteSignature,
            ] as [String: any Sendable]
        )

        guard let claimData = claimResponse["claim_static_deposit"] as? [String: Any],
              let transferId = claimData["transfer_id"] as? String else {
            throw SparkError.invalidResponse("No transfer_id in claim response")
        }
        return transferId
    }

    /// Query unused (unclaimed) deposit addresses.
    public func queryUnusedDepositAddresses(limit: Int = 100, offset: Int = 0) async throws -> [UnusedDepositAddress] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_QueryUnusedDepositAddressesRequest()
        request.identityPublicKey = signer.identityPublicKey
        request.network = config.networkProto
        request.limit = Int64(limit)
        request.offset = Int64(offset)

        let response = try await client.query_unused_deposit_addresses(
            request: ClientRequest(message: request, metadata: metadata)
        )

        return response.depositAddresses.map { deposit in
            UnusedDepositAddress(
                address: deposit.depositAddress,
                leafId: deposit.leafID,
                userSigningPublicKey: Data(deposit.userSigningPublicKey),
                verifyingPublicKey: Data(deposit.verifyingPublicKey)
            )
        }
    }

    /// Get UTXOs sent to a deposit address. Calls the Spark coordinator (not mempool).
    /// - Parameters:
    ///   - address: The deposit address to check
    ///   - excludeClaimed: If true, only returns unclaimed UTXOs (default true)
    /// - Returns: Array of UTXOs at this address
    public func getUtxosForDepositAddress(
        address: String,
        excludeClaimed: Bool = true
    ) async throws -> [DepositUtxo] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_GetUtxosForAddressRequest()
        request.address = address
        request.network = config.networkProto
        request.excludeClaimed = excludeClaimed

        let response = try await client.get_utxos_for_address(
            request: ClientRequest(message: request, metadata: metadata)
        )

        return response.utxos.map { utxo in
            let txidHex = utxo.txid.hexString
            return DepositUtxo(txid: txidHex, vout: utxo.vout)
        }
    }

    /// Query all static deposit addresses for this wallet.
    public func queryStaticDepositAddresses() async throws -> [StaticDepositAddress] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_QueryStaticDepositAddressesRequest()
        request.identityPublicKey = signer.identityPublicKey
        request.network = config.networkProto
        request.hashVariant = .v2

        let response = try await client.query_static_deposit_addresses(
            request: ClientRequest(message: request, metadata: metadata)
        )

        return response.depositAddresses.map { deposit in
            StaticDepositAddress(
                address: deposit.depositAddress,
                verifyingKey: Data(deposit.verifyingPublicKey)
            )
        }
    }

    /// Claim a static deposit, but only if the fee is at or below `maxFee` sats: the SSP's quote
    /// is checked against the deposit's value (from a transaction that hashes to the txid) and
    /// then claimed exactly, as the reference SDK does.
    /// Returns nil if the fee exceeds the max.
    @discardableResult
    public func claimStaticDepositWithMaxFee(
        transactionId: String,
        maxFee: Int64,
        outputIndex: UInt32 = 0
    ) async throws -> String? {
        let outpoint = try DepositOutpoint(txid: transactionId, vout: outputIndex)
        let rawTx = try await fetchRawTransaction(txID: outpoint.txid)
        guard try RawTransaction.parse(rawTx, context: "deposit tx").txid == outpoint.internalOrderTxid else {
            throw SparkError.untrustedResponse("block explorer returned a transaction that does not hash to \(outpoint.txid)")
        }
        let depositSats = Int64(reportedSats: try Self.parseTxOutput(rawTx, vout: outputIndex).value)

        let quote = try await getDepositFeeEstimate(transactionId: outpoint.txid, outputIndex: outputIndex)
        guard Self.staticDepositFee(depositSats: depositSats, quote: quote) <= maxFee else {
            return nil
        }
        return try await claimStaticDeposit(transactionId: outpoint.txid, outputIndex: outputIndex, quote: quote)
    }

    /// What the SSP keeps of a deposit under `quote`.
    static func staticDepositFee(depositSats: Int64, quote: DepositFeeEstimate) -> Int64 {
        depositSats - quote.creditAmountSats
    }

    /// Get fee quote for claiming a static deposit (how much will be credited after fees).
    public func getDepositFeeEstimate(transactionId: String, outputIndex: UInt32 = 0) async throws -> DepositFeeEstimate {
        let response = try await sspClient.executeRaw(
            query: GraphQLQueries.staticDepositQuote,
            variables: [
                "transaction_id": transactionId,
                "output_index": Int(outputIndex),
                "network": config.networkGraphQL,
            ] as [String: any Sendable]
        )

        guard let quoteData = response["static_deposit_quote"] as? [String: Any],
              let creditAmountSats = quoteData["credit_amount_sats"] as? Int64,
              let signature = quoteData["signature"] as? String else {
            throw SparkError.invalidResponse("Invalid static deposit quote response")
        }

        return DepositFeeEstimate(creditAmountSats: creditAmountSats, quoteSignature: signature)
    }

    /// Refund a static deposit back on-chain. Returns the signed transaction hex.
    /// - Parameters:
    ///   - depositTransactionId: The on-chain tx id of the deposit
    ///   - outputIndex: The output index (vout)
    ///   - destinationAddress: Bitcoin address to send refund to
    ///   - satsPerVbyte: Fee rate (max 150)
    /// - Returns: Signed transaction hex ready for broadcast
    public func refundStaticDeposit(
        depositTransactionId: String,
        outputIndex: UInt32 = 0,
        destinationAddress: String,
        satsPerVbyte: UInt64
    ) async throws -> String {
        guard satsPerVbyte <= 150 else {
            throw SparkError.invalidResponse("satsPerVbyte must be <= 150")
        }

        // Estimated vbytes for 1-input 1-output P2TR tx
        let estimatedVbytes: UInt64 = 194
        let fee = satsPerVbyte * estimatedVbytes
        guard fee >= 194 else {
            throw SparkError.invalidResponse("Fee must be at least 194 sats")
        }

        let outpoint = try DepositOutpoint(txid: depositTransactionId, vout: outputIndex)
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        // The deposit output, from a transaction that hashes to the txid.
        let rawDepositTx = try await fetchRawTransaction(txID: outpoint.txid)
        guard try RawTransaction.parse(rawDepositTx, context: "deposit tx").txid == outpoint.internalOrderTxid else {
            throw SparkError.untrustedResponse("block explorer returned a transaction that does not hash to \(outpoint.txid)")
        }
        let depositOutput = try Self.parseTxOutput(rawDepositTx, vout: outputIndex)
        let totalAmount = depositOutput.value
        let creditAmountSats = Int64(reportedSats: totalAmount) - Int64(fee)
        guard creditAmountSats > 0 else {
            throw SparkError.invalidResponse("Fee too large, credit amount must be > 0")
        }

        // Build spend tx: 1 input (deposit utxo), 1 output (destination)
        let spendTx = try Self.constructSpendTx(
            spending: outpoint,
            destinationAddress: destinationAddress,
            amountSats: UInt64(creditAmountSats),
            network: config.network
        )

        // Compute sighash for the spend tx
        let sighash = try computeMultiInputSighashUniffi(
            tx: spendTx,
            inputIndex: 0,
            prevOutScripts: [depositOutput.script],
            prevOutValues: [depositOutput.value]
        )

        let staticKey = try signer.deriveStaticDepositKey(0)
        let staticPubKey = try getPublicKeyBytes(privateKeyBytes: staticKey, compressed: true)

        // Authorize the refund: the statement ends with the spend transaction's raw sighash.
        let statement = Self.staticDepositStatement(
            outpoint, network: config.network, requestType: .refund,
            creditAmountSats: UInt64(creditAmountSats), authorization: sighash
        )
        let userSignature = try signer.signWithIdentityKey(Data(CryptoKit.SHA256.hash(data: statement)))

        // Create nonce for FROST signing
        let keyPackage = KeyPackage(secretKey: staticKey, publicKey: staticPubKey, verifyingKey: staticPubKey)
        let nonceResult = try frostNonce(keyPackage: keyPackage)

        // Build signing job
        var signingJob = Spark_SigningJob()
        signingJob.signingPublicKey = staticPubKey
        signingJob.rawTx = spendTx
        signingJob.signingNonceCommitment = Common_SigningCommitment.with {
            $0.hiding = nonceResult.commitment.hiding
            $0.binding = nonceResult.commitment.binding
        }

        // Call gRPC
        var refundReq = Spark_InitiateStaticDepositUtxoRefundRequest()
        refundReq.onChainUtxo = outpoint.utxo(network: config.networkProto)
        refundReq.refundTxSigningJob = signingJob
        refundReq.userSignature = userSignature

        let refundResp = try await client.initiate_static_deposit_utxo_refund(
            request: ClientRequest(message: refundReq, metadata: metadata)
        )

        let signingResult = refundResp.refundTxSigningResult
        let verifyingKey = Data(refundResp.depositAddress.verifyingPublicKey)

        // Sign FROST and aggregate
        let realKeyPackage = KeyPackage(secretKey: staticKey, publicKey: staticPubKey, verifyingKey: verifyingKey)
        var nativeCommitments: [String: SigningCommitment] = [:]
        for (soID, protoCommitment) in signingResult.signingNonceCommitments {
            nativeCommitments[soID] = SigningCommitment(
                hiding: protoCommitment.hiding,
                binding: protoCommitment.binding
            )
        }

        let selfSignature = try signFrost(
            msg: sighash,
            keyPackage: realKeyPackage,
            nonce: nonceResult.nonce,
            selfCommitment: nonceResult.commitment,
            statechainCommitments: nativeCommitments,
            adaptorPublicKey: nil
        )

        let aggregatedSig = try aggregateFrost(
            msg: sighash,
            statechainCommitments: nativeCommitments,
            selfCommitment: nonceResult.commitment,
            statechainSignatures: signingResult.signatureShares,
            selfSignature: selfSignature,
            statechainPublicKeys: signingResult.publicKeys,
            selfPublicKey: staticPubKey,
            verifyingKey: verifyingKey,
            adaptorPublicKey: nil
        )

        // Add witness to spend tx
        let signedTx = try Self.addWitnessToTx(spendTx, witness: aggregatedSig)
        return signedTx.hexString
    }

    /// Broadcast a raw transaction hex via mempool/electrs API
    public func broadcastTransaction(_ txHex: String) async throws -> String {
        let baseURL: String
        switch config.network {
        case .mainnet:
            baseURL = "https://mempool.space/api"
        case .regtest:
            baseURL = "http://localhost:3000"
        }

        let url = URL(string: "\(baseURL)/tx")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(txHex.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SparkError.invalidResponse("Failed to broadcast tx: \(body)")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Refund a static deposit and broadcast it. Returns the txid.
    public func refundAndBroadcastStaticDeposit(
        depositTransactionId: String,
        outputIndex: UInt32 = 0,
        destinationAddress: String,
        satsPerVbyte: UInt64
    ) async throws -> String {
        let txHex = try await refundStaticDeposit(
            depositTransactionId: depositTransactionId,
            outputIndex: outputIndex,
            destinationAddress: destinationAddress,
            satsPerVbyte: satsPerVbyte
        )
        return try await broadcastTransaction(txHex)
    }

    // MARK: - Internal helpers

    /// Parse a display-order (big-endian hex) txid into the internal byte order used on the wire.
    static func txidBytes(fromDisplayHex hex: String) throws -> Data {
        guard hex.count == 64, let bytes = Data(hexString: hex) else {
            throw SparkError.invalidResponse("Invalid transaction id: \(hex)")
        }
        return Data(bytes.reversed())
    }

    /// The unsigned 1-input 1-output transaction spending a static deposit: version 3, final
    /// sequence, locktime 0, in the non-witness serialisation. The operators rebuild exactly that
    /// and compare it byte for byte (`validateStaticDepositSingleInputTx`), and the reference SDK
    /// sends `tx.toBytes()`; the signature is attached afterwards by `addWitnessToTx`.
    static func constructSpendTx(
        spending outpoint: DepositOutpoint,
        destinationAddress: String,
        amountSats: UInt64,
        network: SparkNetwork
    ) throws -> Data {
        let scriptPubKey = try BitcoinAddress.scriptPubKey(for: destinationAddress, network: network)
        let tx = RawTransaction(
            version: 3,
            inputs: [RawTransaction.Input(previousTxid: outpoint.internalOrderTxid, previousIndex: outpoint.vout)],
            outputs: [RawTransaction.Output(value: amountSats, scriptPubKey: scriptPubKey)],
            locktime: 0,
            hasWitnessSerialization: false
        )
        return tx.serialized(includeWitness: false)
    }

    /// Attach a single-item witness (a schnorr signature) to the first input of a segwit tx.
    static func addWitnessToTx(_ rawTx: Data, witness: Data) throws -> Data {
        var tx = try RawTransaction.parse(rawTx, context: "spend tx")
        guard !tx.inputs.isEmpty else {
            throw SparkError.malformedTransaction("spend tx has no inputs")
        }
        tx.hasWitnessSerialization = true
        tx.inputs[0].witness = [witness]
        return tx.serialized(includeWitness: true)
    }

    // MARK: - Internal helpers

    /// Fetch raw transaction bytes from electrs/blockstream API
    func fetchRawTransaction(txID: String) async throws -> Data {
        let baseURL: String
        switch config.network {
        case .mainnet:
            baseURL = "https://mempool.space/api"
        case .regtest:
            baseURL = "http://localhost:3000"
        }

        let url = URL(string: "\(baseURL)/tx/\(txID)/hex")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SparkError.invalidResponse("Failed to fetch raw transaction \(txID)")
        }
        let hexString = String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawTx = Data(hexString: hexString) else {
            throw SparkError.invalidResponse("Invalid hex in raw transaction response")
        }
        return rawTx
    }
}
