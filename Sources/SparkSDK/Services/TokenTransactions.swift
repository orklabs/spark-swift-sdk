import Foundation
import GRPCCore
import SwiftProtobuf

/// A token transaction the wallet has built and not yet sent, in the configured version
/// (`SparkConfig.tokenTransactionVersion`).
enum TokenTransactionDraft: Sendable {
    /// Sent with `start_transaction` and `commit_transaction`.
    case v2(SparkToken_TokenTransaction)
    /// Sent with `broadcast_transaction`.
    case v3(SparkToken_PartialTokenTransaction)
}

/// An output a token transaction creates.
struct TokenOutputSpec: Equatable, Sendable {
    let owner: Data
    let tokenIdentifier: Data
    let amount: UInt128
}

extension SparkWallet {
    /// How long the operators may take to carry out a V3 token transaction: the reference SDK's
    /// default (the operators accept 1 to 300 seconds).
    static let tokenValidityDurationSeconds: UInt64 = 180

    // MARK: - Building

    /// The outputs of a transfer spending `spent` to `receivers`: the receivers' outputs, then
    /// change to `changeOwner` for each token spent beyond what they are paid.
    static func transferOutputs(
        spending spent: [SparkToken_OutputWithPreviousTransactionData],
        paying receivers: [TokenOutputSpec],
        changeOwner: Data
    ) -> [TokenOutputSpec] {
        var change: [Data: UInt128] = [:]
        var order: [Data] = []
        for output in spent {
            let token = output.output.tokenIdentifier
            if change[token] == nil { order.append(token) }
            change[token, default: 0] += decodeUInt128(output.output.tokenAmount)
        }
        for receiver in receivers {
            change[receiver.tokenIdentifier, default: 0] -= min(change[receiver.tokenIdentifier] ?? 0, receiver.amount)
        }
        return receivers + order.compactMap { token in
            guard let amount = change[token], amount > 0 else { return nil }
            return TokenOutputSpec(owner: changeOwner, tokenIdentifier: token, amount: amount)
        }
    }

    /// A transfer spending `spent`, in vout order, to `outputs`.
    func transferDraft(
        spending spent: [SparkToken_OutputWithPreviousTransactionData],
        outputs: [TokenOutputSpec]
    ) -> TokenTransactionDraft {
        var input = SparkToken_TokenTransferInput()
        input.outputsToSpend = spent.sorted { $0.previousTransactionVout < $1.previousTransactionVout }.map { output in
            var reference = SparkToken_TokenOutputToSpend()
            reference.prevTokenTransactionHash = output.previousTransactionHash
            reference.prevTokenTransactionVout = output.previousTransactionVout
            return reference
        }
        return draft(inputs: .transfer(input), outputs: outputs)
    }

    /// A mint of `amount` of `tokenIdentifier` to the issuer, this wallet.
    func mintDraft(tokenIdentifier: Data, amount: UInt128) -> TokenTransactionDraft {
        var input = SparkToken_TokenMintInput()
        input.issuerPublicKey = signer.identityPublicKey
        input.tokenIdentifier = tokenIdentifier
        let output = TokenOutputSpec(owner: signer.identityPublicKey, tokenIdentifier: tokenIdentifier, amount: amount)
        return draft(inputs: .mint(input), outputs: [output])
    }

    /// The creation of a token this wallet issues.
    func createDraft(_ input: SparkToken_TokenCreateInput) -> TokenTransactionDraft {
        draft(inputs: .create(input), outputs: [])
    }

    private enum DraftInputs {
        case transfer(SparkToken_TokenTransferInput)
        case mint(SparkToken_TokenMintInput)
        case create(SparkToken_TokenCreateInput)
    }

    private func draft(inputs: DraftInputs, outputs: [TokenOutputSpec]) -> TokenTransactionDraft {
        switch config.tokenTransactionVersion {
        case .v2:
            var tx = SparkToken_TokenTransaction()
            tx.version = 2
            tx.network = config.networkProto
            switch inputs {
            case .transfer(let input): tx.tokenInputs = .transferInput(input)
            case .mint(let input): tx.tokenInputs = .mintInput(input)
            case .create(let input): tx.tokenInputs = .createInput(input)
            }
            // The coordinator adds the withdraw bond and locktime to V2 outputs.
            tx.tokenOutputs = outputs.map { spec in
                var output = SparkToken_TokenOutput()
                output.ownerPublicKey = spec.owner
                output.tokenIdentifier = spec.tokenIdentifier
                output.tokenAmount = encodeUInt128(spec.amount)
                return output
            }
            tx.sparkOperatorIdentityPublicKeys = collectOperatorIdentityPublicKeys()
            tx.clientCreatedTimestamp = currentTimestamp()
            tx.invoiceAttachments = []
            return .v2(tx)
        case .v3:
            var metadata = SparkToken_TokenTransactionMetadata()
            // Strictly ascending, as the operators require of V3 transactions.
            metadata.sparkOperatorIdentityPublicKeys = collectOperatorIdentityPublicKeys()
            metadata.network = config.networkProto
            metadata.clientCreatedTimestamp = currentTimestamp()
            metadata.validityDurationSeconds = Self.tokenValidityDurationSeconds
            var partial = SparkToken_PartialTokenTransaction()
            partial.version = 3
            partial.tokenTransactionMetadata = metadata
            switch inputs {
            case .transfer(let input): partial.tokenInputs = .transferInput(input)
            case .mint(let input): partial.tokenInputs = .mintInput(input)
            case .create(let input): partial.tokenInputs = .createInput(input)
            }
            // V3 outputs carry the withdraw bond and locktime, which must equal the network's.
            partial.partialTokenOutputs = outputs.map { spec in
                var output = SparkToken_PartialTokenOutput()
                output.ownerPublicKey = spec.owner
                output.withdrawBondSats = config.expectedWithdrawBondSats
                output.withdrawRelativeBlockLocktime = config.expectedWithdrawRelativeBlockLocktime
                output.tokenIdentifier = spec.tokenIdentifier
                output.tokenAmount = encodeUInt128(spec.amount)
                return output
            }
            return .v3(partial)
        }
    }

    // MARK: - Sending

    /// Sends `draft`, signing for the `spentOutputs` of a transfer (or as the issuer of a mint or
    /// create), and returns the final transaction's hash and, for a create, the token's
    /// identifier.
    func sendTokenTransaction(
        _ draft: TokenTransactionDraft,
        spentOutputs: [SparkToken_OutputWithPreviousTransactionData] = [],
        idempotencyKey: String? = nil
    ) async throws -> (transactionHash: String, tokenIdentifier: Data?) {
        let owners = spentOutputs
            .sorted { $0.previousTransactionVout < $1.previousTransactionVout }
            .map(\.output.ownerPublicKey)
        switch draft {
        case .v2(let transaction):
            var signingPublicKeys: [Data]?
            if case .transferInput = transaction.tokenInputs {
                signingPublicKeys = owners
            }
            return try await broadcastTokenTransactionV2Detailed(
                tokenTransaction: transaction, signingPublicKeys: signingPublicKeys, idempotencyKey: idempotencyKey
            )
        case .v3(let partial):
            return try await broadcastTokenTransactionV3(partial, spentOutputOwners: owners, idempotencyKey: idempotencyKey)
        }
    }

    /// V3: one `broadcast_transaction`, signed over the protohash of `partial`, which binds its
    /// inputs, outputs and amounts; the operators then build, sign and commit the final
    /// transaction, which is checked to be `partial` before its hash is returned.
    private func broadcastTokenTransactionV3(
        _ partial: SparkToken_PartialTokenTransaction,
        spentOutputOwners: [Data],
        idempotencyKey: String?
    ) async throws -> (transactionHash: String, tokenIdentifier: Data?) {
        let client = try await getTokenClient()
        let authMetadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = SparkToken_BroadcastTransactionRequest()
        request.identityPublicKey = signer.identityPublicKey
        request.partialTokenTransaction = partial
        request.tokenTransactionOwnerSignatures = try ownerSignaturesV3(
            partial, hash: try ProtoHash.hash(partial), spentOutputOwners: spentOutputOwners
        )

        let response = try await client.broadcast_transaction(request: ClientRequest(
            message: request,
            metadata: idempotencyKey.map { metadataWithIdempotencyKey($0, base: authMetadata) } ?? authMetadata
        ))
        guard response.hasFinalTokenTransaction else {
            throw SparkError.invalidResponse("Missing final token transaction in broadcast response")
        }
        try TokenTransactionValidator.validateV3(final: response.finalTokenTransaction, partial: partial)
        let hash = try ProtoHash.hash(response.finalTokenTransaction)
        return (hash.hexString, response.hasTokenIdentifier ? response.tokenIdentifier : nil)
    }

    /// One signature per input of a transfer, by the owner of the output it spends, or one by
    /// the issuer for a mint or create; in `single_signature`, as the reference SDK sends them.
    private func ownerSignaturesV3(
        _ partial: SparkToken_PartialTokenTransaction,
        hash: Data,
        spentOutputOwners: [Data]
    ) throws -> [SparkToken_SignatureWithIndex] {
        let keys: [Data]
        switch partial.tokenInputs {
        case .transferInput(let input):
            guard spentOutputOwners.count == input.outputsToSpend.count else {
                throw SparkError.tokenValidationFailed("Missing signing keys for the outputs to spend")
            }
            keys = spentOutputOwners
        case .mintInput, .createInput:
            keys = [signer.identityPublicKey]
        case nil:
            throw SparkError.tokenValidationFailed("Token transaction has no inputs")
        }
        return try keys.enumerated().map { index, key in
            guard key == signer.identityPublicKey else {
                throw SparkError.tokenValidationFailed("Cannot sign with unknown key: \(key.hexString)")
            }
            var keyed = Multisig_KeyedSignature()
            keyed.publicKey = key
            keyed.signature = try signer.signWithIdentityKey(hash)
            var signature = SparkToken_SignatureWithIndex()
            signature.inputIndex = UInt32(index)
            signature.authoritySignatures = .singleSignature(keyed)
            return signature
        }
    }
}
