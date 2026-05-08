import Foundation
import CryptoKit
import GRPCCore
import SwiftProtobuf

private let queryTokenOutputsPageSize: UInt32 = 100
private let maxTokenOutputsTx = 500

extension SparkWallet {

    // MARK: - Public Token API

    /// Transfer tokens to a receiver.
    ///
    /// - Parameter idempotencyKey: Optional key for deduplication of the gRPC call.
    public func transferTokens(
        tokenIdentifier: Bech32mTokenIdentifier,
        tokenAmount: UInt128,
        receiverSparkAddress: String,
        strategy: TokenOutputSelectionStrategy = .smallFirst,
        idempotencyKey: String? = nil
    ) async throws -> String {
        let (rawTokenId, _) = try decodeBech32mTokenIdentifier(tokenIdentifier, network: config.network)

        let outputs = try await fetchTokenOutputs(tokenIdentifiers: [rawTokenId])
        guard !outputs.isEmpty else {
            throw SparkError.insufficientTokenBalance(token: tokenIdentifier, need: "\(tokenAmount)", have: "0")
        }

        let selected = try Self.selectTokenOutputs(outputs, amount: tokenAmount, strategy: strategy)

        // Decode receiver's Spark address to get their identity public key
        let receiverData = try Self.decodeSparkAddressPublicKey(receiverSparkAddress)

        let tx = try buildTransferTokenTransaction(
            selectedOutputs: selected,
            receiverOutputs: [(receiverPubKey: receiverData, rawTokenIdentifier: rawTokenId, tokenAmount: tokenAmount)],
            changeOwnerPubKey: signer.identityPublicKey
        )

        return try await broadcastTokenTransactionV2(
            tokenTransaction: tx,
            signingPublicKeys: selected.map { $0.output.ownerPublicKey },
            revocationCommitments: selected.compactMap { $0.output.hasRevocationCommitment ? $0.output.revocationCommitment : nil },
            idempotencyKey: idempotencyKey
        )
    }

    /// Get token balances for the current wallet.
    public func getTokenBalances() async throws -> [TokenBalance] {
        let outputs = try await fetchTokenOutputs()

        var balancesByToken: [Data: (owned: UInt128, available: UInt128)] = [:]
        for output in outputs {
            let tokenId = output.output.tokenIdentifier
            let amount = decodeUInt128(output.output.tokenAmount)
            var entry = balancesByToken[tokenId] ?? (0, 0)
            entry.owned += amount
            if !output.output.hasStatus || output.output.status == .available {
                entry.available += amount
            }
            balancesByToken[tokenId] = entry
        }

        let tokenIds = Array(balancesByToken.keys)
        let metadataMap = try await fetchTokenMetadata(tokenIdentifiers: tokenIds)

        var balances: [TokenBalance] = []
        for (tokenId, entry) in balancesByToken {
            if let meta = metadataMap[tokenId] {
                balances.append(TokenBalance(
                    tokenMetadata: meta,
                    ownedBalance: entry.owned,
                    availableToSendBalance: entry.available
                ))
            }
        }
        return balances
    }

    /// Query token outputs owned by this wallet.
    public func getTokenOutputs(
        tokenIdentifier: Bech32mTokenIdentifier? = nil
    ) async throws -> [TokenOutputInfo] {
        var rawTokenIds: [Data]? = nil
        if let tokenIdentifier {
            let (rawId, _) = try decodeBech32mTokenIdentifier(tokenIdentifier, network: config.network)
            rawTokenIds = [rawId]
        }

        let outputs = try await fetchTokenOutputs(tokenIdentifiers: rawTokenIds)
        return outputs.map { protoOutput in
            let o = protoOutput.output
            return TokenOutputInfo(
                id: o.id.isEmpty ? nil : o.id,
                ownerPublicKey: o.ownerPublicKey,
                tokenIdentifier: o.tokenIdentifier,
                tokenAmount: decodeUInt128(o.tokenAmount),
                previousTransactionHash: protoOutput.previousTransactionHash,
                previousTransactionVout: protoOutput.previousTransactionVout,
                status: o.hasStatus ? "\(o.status)" : "AVAILABLE"
            )
        }
    }

    /// Query token metadata.
    public func queryTokenMetadata(
        tokenIdentifiers: [Bech32mTokenIdentifier]? = nil,
        issuerPublicKeys: [Data]? = nil
    ) async throws -> [TokenMetadata] {
        let client = try await getTokenClient()
        let authMetadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = SparkToken_QueryTokenMetadataRequest()
        if let ids = tokenIdentifiers {
            request.tokenIdentifiers = try ids.map { id in
                try decodeBech32mTokenIdentifier(id, network: config.network).tokenIdentifier
            }
        }
        if let keys = issuerPublicKeys {
            request.issuerPublicKeys = keys
        }

        let response = try await client.query_token_metadata(
            request: ClientRequest(message: request, metadata: authMetadata)
        )

        return try response.tokenMetadata.map { meta in
            let bech32Id = try encodeBech32mTokenIdentifier(meta.tokenIdentifier, network: config.network)
            return TokenMetadata(
                tokenIdentifier: bech32Id,
                rawTokenIdentifier: meta.tokenIdentifier,
                issuerPublicKey: meta.issuerPublicKey,
                tokenName: meta.tokenName,
                tokenTicker: meta.tokenTicker,
                decimals: meta.decimals,
                maxSupply: meta.maxSupply,
                isFreezable: meta.isFreezable,
                extraMetadata: meta.hasExtraMetadata ? meta.extraMetadata : nil
            )
        }
    }

    // MARK: - Token Issuance

    /// Create a new token on Spark. The caller's identity key becomes the issuer.
    public func createToken(
        tokenName: String,
        tokenTicker: String,
        decimals: UInt32,
        maxSupply: UInt128 = 0,
        isFreezable: Bool,
        extraMetadata: Data? = nil
    ) async throws -> TokenCreationResult {
        let nameBytes = Data(tokenName.utf8)
        guard !nameBytes.isEmpty && nameBytes.count <= 20 else {
            throw SparkError.tokenValidationFailed("Token name must be 1-20 UTF-8 bytes")
        }
        let tickerBytes = Data(tokenTicker.utf8)
        guard !tickerBytes.isEmpty && tickerBytes.count <= 6 else {
            throw SparkError.tokenValidationFailed("Token ticker must be 1-6 UTF-8 bytes")
        }
        guard decimals <= 255 else {
            throw SparkError.tokenValidationFailed("Decimals must be <= 255")
        }
        if let extra = extraMetadata {
            guard extra.count <= 1024 else {
                throw SparkError.tokenValidationFailed("Extra metadata must be <= 1024 bytes")
            }
        }

        let issuerPubKey = signer.identityPublicKey

        var createInput = SparkToken_TokenCreateInput()
        createInput.issuerPublicKey = issuerPubKey
        createInput.tokenName = tokenName
        createInput.tokenTicker = tokenTicker
        createInput.decimals = decimals
        createInput.maxSupply = encodeUInt128(maxSupply)
        createInput.isFreezable = isFreezable
        if let extra = extraMetadata {
            createInput.extraMetadata = extra
        }

        var tx = SparkToken_TokenTransaction()
        tx.version = 2
        tx.network = config.networkProto
        tx.tokenInputs = .createInput(createInput)
        tx.tokenOutputs = []
        tx.sparkOperatorIdentityPublicKeys = collectOperatorIdentityPublicKeys()
        tx.clientCreatedTimestamp = currentTimestamp()
        tx.invoiceAttachments = []

        let (txHash, tokenId) = try await broadcastTokenTransactionV2Detailed(
            tokenTransaction: tx,
            signingPublicKeys: nil,
            revocationCommitments: nil
        )

        var bech32TokenId: Bech32mTokenIdentifier? = nil
        if let tokenId {
            bech32TokenId = try encodeBech32mTokenIdentifier(tokenId, network: config.network)
        }

        return TokenCreationResult(transactionHash: txHash, tokenIdentifier: bech32TokenId)
    }

    /// Mint additional tokens for an existing token. Caller must be the token issuer.
    public func mintTokens(
        tokenIdentifier: Bech32mTokenIdentifier,
        tokenAmount: UInt128
    ) async throws -> String {
        guard tokenAmount > 0 else {
            throw SparkError.tokenValidationFailed("Mint amount must be greater than 0")
        }

        let (rawTokenId, _) = try decodeBech32mTokenIdentifier(tokenIdentifier, network: config.network)
        let issuerPubKey = signer.identityPublicKey

        var mintInput = SparkToken_TokenMintInput()
        mintInput.issuerPublicKey = issuerPubKey
        mintInput.tokenIdentifier = rawTokenId

        var mintOutput = SparkToken_TokenOutput()
        mintOutput.ownerPublicKey = issuerPubKey
        mintOutput.tokenIdentifier = rawTokenId
        mintOutput.tokenAmount = encodeUInt128(tokenAmount)

        var tx = SparkToken_TokenTransaction()
        tx.version = 2
        tx.network = config.networkProto
        tx.tokenInputs = .mintInput(mintInput)
        tx.tokenOutputs = [mintOutput]
        tx.sparkOperatorIdentityPublicKeys = collectOperatorIdentityPublicKeys()
        tx.clientCreatedTimestamp = currentTimestamp()
        tx.invoiceAttachments = []

        return try await broadcastTokenTransactionV2(
            tokenTransaction: tx,
            signingPublicKeys: nil,
            revocationCommitments: nil
        )
    }

    /// Burn tokens by transferring them to a dead address.
    public func burnTokens(
        tokenIdentifier: Bech32mTokenIdentifier,
        tokenAmount: UInt128,
        strategy: TokenOutputSelectionStrategy = .smallFirst
    ) async throws -> String {
        let burnPubKey = Data(repeating: 0x02, count: 33)
        let (rawTokenId, _) = try decodeBech32mTokenIdentifier(tokenIdentifier, network: config.network)

        let outputs = try await fetchTokenOutputs(tokenIdentifiers: [rawTokenId])
        guard !outputs.isEmpty else {
            throw SparkError.insufficientTokenBalance(token: tokenIdentifier, need: "\(tokenAmount)", have: "0")
        }

        let selected = try Self.selectTokenOutputs(outputs, amount: tokenAmount, strategy: strategy)

        let tx = try buildTransferTokenTransaction(
            selectedOutputs: selected,
            receiverOutputs: [(receiverPubKey: burnPubKey, rawTokenIdentifier: rawTokenId, tokenAmount: tokenAmount)],
            changeOwnerPubKey: signer.identityPublicKey
        )

        return try await broadcastTokenTransactionV2(
            tokenTransaction: tx,
            signingPublicKeys: selected.map { $0.output.ownerPublicKey },
            revocationCommitments: selected.compactMap { $0.output.hasRevocationCommitment ? $0.output.revocationCommitment : nil }
        )
    }

    // MARK: - Token Output Selection

    /// Select token outputs to satisfy a target amount.
    static func selectTokenOutputs(
        _ outputs: [SparkToken_OutputWithPreviousTransactionData],
        amount: UInt128,
        strategy: TokenOutputSelectionStrategy
    ) throws -> [SparkToken_OutputWithPreviousTransactionData] {
        guard amount > 0 else {
            throw SparkError.tokenValidationFailed("Token amount must be greater than 0")
        }

        let totalAvailable = outputs.reduce(UInt128(0)) { $0 + decodeUInt128($1.output.tokenAmount) }
        guard totalAvailable >= amount else {
            throw SparkError.insufficientTokenBalance(
                token: "token", need: "\(amount)", have: "\(totalAvailable)"
            )
        }

        if let exact = outputs.first(where: { decodeUInt128($0.output.tokenAmount) == amount }) {
            return [exact]
        }

        switch strategy {
        case .smallFirst:
            let sorted = outputs.sorted { decodeUInt128($0.output.tokenAmount) < decodeUInt128($1.output.tokenAmount) }
            var sum: UInt128 = 0
            var count = 0
            for output in sorted {
                sum += decodeUInt128(output.output.tokenAmount)
                count += 1
                if sum >= amount { return Array(sorted.prefix(count)) }
                if count >= maxTokenOutputsTx { break }
            }

            var selected = Array(sorted.prefix(min(count, maxTokenOutputsTx)))
            let remaining = Array(sorted.dropFirst(min(count, maxTokenOutputsTx))).reversed()
            var smallSum = selected.reduce(UInt128(0)) { $0 + decodeUInt128($1.output.tokenAmount) }

            for largeOutput in remaining {
                if smallSum >= amount { break }
                guard !selected.isEmpty else { break }
                let smallest = selected.removeFirst()
                smallSum = smallSum - decodeUInt128(smallest.output.tokenAmount) + decodeUInt128(largeOutput.output.tokenAmount)
                selected.append(largeOutput)
            }

            guard smallSum >= amount else {
                throw SparkError.insufficientTokenBalance(token: "token", need: "\(amount)", have: "\(smallSum)")
            }
            return selected

        case .largeFirst:
            let sorted = outputs.sorted { decodeUInt128($0.output.tokenAmount) > decodeUInt128($1.output.tokenAmount) }
            var selected: [SparkToken_OutputWithPreviousTransactionData] = []
            var remaining = amount
            for output in sorted {
                if remaining == 0 { break }
                if selected.count >= maxTokenOutputsTx { break }
                selected.append(output)
                let a = decodeUInt128(output.output.tokenAmount)
                remaining = a >= remaining ? 0 : remaining - a
            }
            guard remaining == 0 else {
                throw SparkError.insufficientTokenBalance(token: "token", need: "\(amount)", have: "\(amount - remaining)")
            }
            return selected
        }
    }

    // MARK: - Internal: Build V2 Transfer Transaction

    private func buildTransferTokenTransaction(
        selectedOutputs: [SparkToken_OutputWithPreviousTransactionData],
        receiverOutputs: [(receiverPubKey: Data, rawTokenIdentifier: Data, tokenAmount: UInt128)],
        changeOwnerPubKey: Data
    ) throws -> SparkToken_TokenTransaction {
        let sorted = selectedOutputs.sorted { $0.previousTransactionVout < $1.previousTransactionVout }

        var availableByToken: [Data: UInt128] = [:]
        for output in sorted {
            availableByToken[output.output.tokenIdentifier, default: 0] += decodeUInt128(output.output.tokenAmount)
        }

        var requestedByToken: [Data: UInt128] = [:]
        for receiver in receiverOutputs {
            requestedByToken[receiver.rawTokenIdentifier, default: 0] += receiver.tokenAmount
        }

        var tokenOutputs: [SparkToken_TokenOutput] = receiverOutputs.map { receiver in
            var output = SparkToken_TokenOutput()
            output.ownerPublicKey = receiver.receiverPubKey
            output.tokenIdentifier = receiver.rawTokenIdentifier
            output.tokenAmount = encodeUInt128(receiver.tokenAmount)
            return output
        }

        // Add change outputs
        for (tokenId, availableAmount) in availableByToken {
            let requestedAmount = requestedByToken[tokenId] ?? 0
            if availableAmount > requestedAmount {
                var changeOutput = SparkToken_TokenOutput()
                changeOutput.ownerPublicKey = changeOwnerPubKey
                changeOutput.tokenIdentifier = tokenId
                changeOutput.tokenAmount = encodeUInt128(availableAmount - requestedAmount)
                tokenOutputs.append(changeOutput)
            }
        }

        var transferInput = SparkToken_TokenTransferInput()
        transferInput.outputsToSpend = sorted.map { output in
            var ref = SparkToken_TokenOutputToSpend()
            ref.prevTokenTransactionHash = output.previousTransactionHash
            ref.prevTokenTransactionVout = output.previousTransactionVout
            return ref
        }

        var tx = SparkToken_TokenTransaction()
        tx.version = 2
        tx.network = config.networkProto
        tx.tokenInputs = .transferInput(transferInput)
        tx.tokenOutputs = tokenOutputs
        tx.sparkOperatorIdentityPublicKeys = collectOperatorIdentityPublicKeys()
        tx.clientCreatedTimestamp = currentTimestamp()
        tx.invoiceAttachments = []

        return tx
    }

    // MARK: - Internal: V2 Broadcast (Two-Phase: start + commit)

    private func broadcastTokenTransactionV2(
        tokenTransaction: SparkToken_TokenTransaction,
        signingPublicKeys: [Data]?,
        revocationCommitments: [Data]?,
        idempotencyKey: String? = nil
    ) async throws -> String {
        let (txHash, _) = try await broadcastTokenTransactionV2Detailed(
            tokenTransaction: tokenTransaction,
            signingPublicKeys: signingPublicKeys,
            revocationCommitments: revocationCommitments,
            idempotencyKey: idempotencyKey
        )
        return txHash
    }

    private func broadcastTokenTransactionV2Detailed(
        tokenTransaction: SparkToken_TokenTransaction,
        signingPublicKeys: [Data]?,
        revocationCommitments: [Data]?,
        idempotencyKey: String? = nil
    ) async throws -> (transactionHash: String, tokenIdentifier: Data?) {
        let client = try await getTokenClient()
        let authMetadata = try await getAuthMetadata(for: config.coordinatorAddress)

        // Phase 1: Hash partial transaction and sign
        let partialHash = try hashTokenTransactionV2(tokenTransaction, partialHash: true)
        let ownerSignatures = try buildOwnerSignatures(
            tx: tokenTransaction, hash: partialHash, signingPublicKeys: signingPublicKeys
        )

        var startRequest = SparkToken_StartTransactionRequest()
        startRequest.identityPublicKey = signer.identityPublicKey
        startRequest.partialTokenTransaction = tokenTransaction
        startRequest.partialTokenTransactionOwnerSignatures = ownerSignatures
        startRequest.validityDurationSeconds = 60

        let startMetadata: Metadata
        if let idempotencyKey {
            startMetadata = metadataWithIdempotencyKey(idempotencyKey, base: authMetadata)
        } else {
            startMetadata = authMetadata
        }

        let startResponse = try await client.start_transaction(
            request: ClientRequest(message: startRequest, metadata: startMetadata)
        )

        guard startResponse.hasFinalTokenTransaction else {
            throw SparkError.invalidResponse("Missing final token transaction in start response")
        }

        let finalTx = startResponse.finalTokenTransaction

        // Phase 2: Hash final transaction and create per-operator signatures
        let finalHash = try hashTokenTransactionV2(finalTx, partialHash: false)
        let operatorSignatures = try buildOperatorSignatures(
            tx: finalTx, finalHash: finalHash
        )

        var commitRequest = SparkToken_CommitTransactionRequest()
        commitRequest.finalTokenTransaction = finalTx
        commitRequest.finalTokenTransactionHash = finalHash
        commitRequest.inputTtxoSignaturesPerOperator = operatorSignatures
        commitRequest.ownerIdentityPublicKey = signer.identityPublicKey

        let commitResponse = try await client.commit_transaction(
            request: ClientRequest(message: commitRequest, metadata: authMetadata)
        )

        let tokenId = commitResponse.hasTokenIdentifier ? commitResponse.tokenIdentifier : nil
        return (finalHash.hexString, tokenId)
    }

    // MARK: - Internal: Signature Helpers

    private func buildOwnerSignatures(
        tx: SparkToken_TokenTransaction,
        hash: Data,
        signingPublicKeys: [Data]?
    ) throws -> [SparkToken_SignatureWithIndex] {
        var signatures: [SparkToken_SignatureWithIndex] = []

        switch tx.tokenInputs {
        case .mintInput:
            let sig = try signer.signWithIdentityKey(hash)
            var s = SparkToken_SignatureWithIndex()
            s.signature = sig
            s.inputIndex = 0
            signatures.append(s)

        case .createInput:
            let sig = try signer.signWithIdentityKey(hash)
            var s = SparkToken_SignatureWithIndex()
            s.signature = sig
            s.inputIndex = 0
            signatures.append(s)

        case .transferInput:
            guard let keys = signingPublicKeys else {
                throw SparkError.tokenValidationFailed("Missing signing public keys for transfer")
            }
            for (i, key) in keys.enumerated() {
                guard key == signer.identityPublicKey else {
                    throw SparkError.tokenValidationFailed("Cannot sign with unknown key: \(key.hexString)")
                }
                let sig = try signer.signWithIdentityKey(hash)
                var s = SparkToken_SignatureWithIndex()
                s.signature = sig
                s.inputIndex = UInt32(i)
                signatures.append(s)
            }

        default:
            throw SparkError.invalidResponse("Unknown token input type")
        }

        return signatures
    }

    private func buildOperatorSignatures(
        tx: SparkToken_TokenTransaction,
        finalHash: Data
    ) throws -> [SparkToken_InputTtxoSignaturesPerOperator] {
        var result: [SparkToken_InputTtxoSignaturesPerOperator] = []

        for operatorConfig in config.signingOperators {
            guard let operatorPubKey = Data(hexString: operatorConfig.identityPublicKeyHex),
                  !operatorPubKey.isEmpty else { continue }

            let payloadHash = try hashOperatorSpecificPayload(
                finalTokenTransactionHash: finalHash,
                operatorIdentityPublicKey: operatorPubKey
            )

            var ttxoSignatures: [SparkToken_SignatureWithIndex] = []

            switch tx.tokenInputs {
            case .mintInput, .createInput:
                let sig = try signer.signWithIdentityKey(payloadHash)
                var s = SparkToken_SignatureWithIndex()
                s.signature = sig
                s.inputIndex = 0
                ttxoSignatures.append(s)

            case .transferInput(let transferInput):
                for i in 0..<transferInput.outputsToSpend.count {
                    let sig = try signer.signWithIdentityKey(payloadHash)
                    var s = SparkToken_SignatureWithIndex()
                    s.signature = sig
                    s.inputIndex = UInt32(i)
                    ttxoSignatures.append(s)
                }

            default:
                throw SparkError.invalidResponse("Unknown token input type")
            }

            var perOperator = SparkToken_InputTtxoSignaturesPerOperator()
            perOperator.ttxoSignatures = ttxoSignatures
            perOperator.operatorIdentityPublicKey = operatorPubKey
            result.append(perOperator)
        }

        return result
    }

    // MARK: - Internal: Fetch Token Outputs

    func fetchTokenOutputs(
        tokenIdentifiers: [Data]? = nil
    ) async throws -> [SparkToken_OutputWithPreviousTransactionData] {
        let client = try await getTokenClient()
        let authMetadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var allOutputs: [SparkToken_OutputWithPreviousTransactionData] = []
        var cursor: String? = nil

        repeat {
            var request = SparkToken_QueryTokenOutputsRequest()
            request.ownerPublicKeys = [signer.identityPublicKey]
            request.network = config.networkProto
            if let ids = tokenIdentifiers {
                request.tokenIdentifiers = ids
            }
            var pageReq = Spark_PageRequest()
            pageReq.pageSize = queryTokenOutputsPageSize
            if let cursor { pageReq.cursor = cursor }
            pageReq.direction = .next
            request.pageRequest = pageReq

            let response = try await client.query_token_outputs(
                request: ClientRequest(message: request, metadata: authMetadata)
            )

            allOutputs.append(contentsOf: response.outputsWithPreviousTransactionData)

            if response.hasPageResponse && !response.pageResponse.nextCursor.isEmpty {
                cursor = response.pageResponse.nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allOutputs
    }

    // MARK: - Internal: Fetch Token Metadata

    func fetchTokenMetadata(
        tokenIdentifiers: [Data]
    ) async throws -> [Data: TokenMetadata] {
        guard !tokenIdentifiers.isEmpty else { return [:] }

        let client = try await getTokenClient()
        let authMetadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = SparkToken_QueryTokenMetadataRequest()
        request.tokenIdentifiers = tokenIdentifiers

        let response = try await client.query_token_metadata(
            request: ClientRequest(message: request, metadata: authMetadata)
        )

        var result: [Data: TokenMetadata] = [:]
        for meta in response.tokenMetadata {
            let bech32Id = try encodeBech32mTokenIdentifier(meta.tokenIdentifier, network: config.network)
            result[meta.tokenIdentifier] = TokenMetadata(
                tokenIdentifier: bech32Id,
                rawTokenIdentifier: meta.tokenIdentifier,
                issuerPublicKey: meta.issuerPublicKey,
                tokenName: meta.tokenName,
                tokenTicker: meta.tokenTicker,
                decimals: meta.decimals,
                maxSupply: meta.maxSupply,
                isFreezable: meta.isFreezable,
                extraMetadata: meta.hasExtraMetadata ? meta.extraMetadata : nil
            )
        }
        return result
    }

    // MARK: - Internal: Timestamp

    private func currentTimestamp() -> Google_Protobuf_Timestamp {
        var ts = Google_Protobuf_Timestamp(date: Date())
        ts.nanos = (ts.nanos / 1000) * 1000
        return ts
    }

    // MARK: - Internal: Spark Address Decoding

    /// Decode a Spark address (spark1... or sparkrt1...) to extract the identity public key.
    static func decodeSparkAddressPublicKey(_ sparkAddress: String) throws -> Data {
        let (_, data) = try Bech32m.decodeBech32m(sparkAddress)
        guard let payload = Bech32m.fromWords(data) else {
            throw SparkError.invalidResponse("Invalid Spark address encoding")
        }
        // Payload is protobuf: field 1 (tag=10), length, then pubkey bytes
        guard payload.count >= 2,
              payload[0] == 10 else { // tag for field 1, wire type 2
            throw SparkError.invalidResponse("Invalid Spark address payload")
        }
        let keyLen = Int(payload[1])
        guard payload.count >= 2 + keyLen else {
            throw SparkError.invalidResponse("Spark address payload too short")
        }
        return payload.subdata(in: 2..<(2 + keyLen))
    }

    // MARK: - Internal: Operator Keys

    func collectOperatorIdentityPublicKeys() -> [Data] {
        config.signingOperators
            .compactMap { Data(hexString: $0.identityPublicKeyHex) }
            .filter { !$0.isEmpty }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }
}
