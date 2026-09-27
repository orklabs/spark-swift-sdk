import Foundation
import GRPCCore
import SwiftProtobuf
import Testing
@testable import SparkSDK

/// V3 token transactions against the operator stand-in: what the wallet broadcasts, how it signs,
/// and which answers it accepts. The partial and final transaction hashes themselves are checked
/// against the operators' vectors in `ProtoHashTests`.
@Suite("V3 token transactions")
struct TokenTransactionV3Tests {
    static let token = TokenOutputLockTests.tokenIdentifier

    /// Runs `body` on a wallet holding one 100-token output, against a stand-in that finalizes
    /// broadcasts, altered by `tamper`.
    static func withFinalizingOperator<T: Sendable>(
        tamper: @escaping @Sendable (inout SparkToken_FinalTokenTransaction) -> Void = { _ in },
        _ body: (SparkWallet, FakeOperatorState) async throws -> T
    ) async throws -> T {
        let state = FakeOperatorState { _ in false }
        await state.setBroadcast(.finalize(tamper: tamper))
        return try await withFakeOperator(state) { wallet in
            await state.setTokenOutputs(try TokenOutputLockTests.walletOutputs(wallet, amounts: [100]))
            return try await body(wallet, state)
        }
    }

    static func onlyBroadcast(_ state: FakeOperatorState) async throws -> SparkToken_BroadcastTransactionRequest {
        let broadcasts = await state.broadcasts
        #expect(broadcasts.count == 1)
        return try #require(broadcasts.first).request
    }

    /// The owner signatures are the wallet's, over the protohash of the partial transaction, in
    /// `single_signature` rather than the deprecated field.
    static func expectSigned(_ request: SparkToken_BroadcastTransactionRequest, by wallet: SparkWallet, inputs: Int) throws {
        let identity = try #require(Data(hexString: wallet.identityPublicKeyHex))
        let hash = try ProtoHash.hash(request.partialTokenTransaction)
        #expect(request.identityPublicKey == identity)
        #expect(request.tokenTransactionOwnerSignatures.map(\.inputIndex) == Array(0..<UInt32(inputs)))
        for signature in request.tokenTransactionOwnerSignatures {
            #expect(!signature.hasSignature)
            guard case .singleSignature(let keyed) = signature.authoritySignatures else {
                Issue.record("owner signature \(signature.inputIndex) is not a single signature")
                continue
            }
            #expect(keyed.publicKey == identity)
            #expect(TransferLeafVerifier.verifyECDSA(signature: keyed.signature, digest: hash, compressedPublicKey: identity))
        }
    }

    @Test("A transfer broadcasts one signed V3 transaction and returns the final transaction's hash", .timeLimit(.minutes(1)))
    func transfer() async throws {
        try await Self.withFinalizingOperator { wallet, state in
            let receiver = SparkAddress.encode(identityPublicKey: TokenHashVectorTests.key(25), network: .regtest)
            let hash = try await wallet.transferTokens(
                tokenIdentifier: try encodeBech32mTokenIdentifier(Self.token, network: .regtest),
                tokenAmount: 40,
                receiverSparkAddress: receiver
            )
            let request = try await Self.onlyBroadcast(state)
            let partial = request.partialTokenTransaction
            #expect(hash == (try ProtoHash.hash(FakeOperator.finalize(partial))).hexString)
            #expect(await state.startedTransactions.isEmpty)

            #expect(partial.version == 3)
            let metadata = partial.tokenTransactionMetadata
            #expect(metadata.validityDurationSeconds == 180)
            #expect(metadata.network == .regtest)
            #expect(metadata.sparkOperatorIdentityPublicKeys == wallet.collectOperatorIdentityPublicKeys())
            #expect(metadata.clientCreatedTimestamp.nanos % 1_000 == 0)
            #expect(metadata.invoiceAttachments.isEmpty)
            #expect(partial.transferInput.outputsToSpend.map(\.prevTokenTransactionVout) == [0])

            let identity = try #require(Data(hexString: wallet.identityPublicKeyHex))
            #expect(partial.partialTokenOutputs.map(\.ownerPublicKey) == [TokenHashVectorTests.key(25), identity])
            #expect(partial.partialTokenOutputs.map { decodeUInt128($0.tokenAmount) } == [40, 60])
            for output in partial.partialTokenOutputs {
                #expect(output.tokenIdentifier == Self.token)
                #expect(output.withdrawBondSats == 10_000)
                #expect(output.withdrawRelativeBlockLocktime == 1_000)
            }
            try Self.expectSigned(request, by: wallet, inputs: 1)
        }
    }

    @Test("A burn pays the burn key, signed for the output it spends", .timeLimit(.minutes(1)))
    func burn() async throws {
        try await Self.withFinalizingOperator { wallet, state in
            let token = try encodeBech32mTokenIdentifier(Self.token, network: .regtest)
            _ = try await wallet.burnTokens(tokenIdentifier: token, tokenAmount: 100)
            let request = try await Self.onlyBroadcast(state)
            #expect(request.partialTokenTransaction.partialTokenOutputs.map(\.ownerPublicKey) == [Data(repeating: 0x02, count: 33)])
            try Self.expectSigned(request, by: wallet, inputs: 1)
        }
    }

    @Test("A mint pays the issuer, signed by the issuer", .timeLimit(.minutes(1)))
    func mint() async throws {
        try await Self.withFinalizingOperator { wallet, state in
            let token = try encodeBech32mTokenIdentifier(Self.token, network: .regtest)
            let hash = try await wallet.mintTokens(tokenIdentifier: token, tokenAmount: 5)
            let request = try await Self.onlyBroadcast(state)
            let partial = request.partialTokenTransaction
            let identity = try #require(Data(hexString: wallet.identityPublicKeyHex))
            #expect(hash == (try ProtoHash.hash(FakeOperator.finalize(partial))).hexString)
            #expect(partial.mintInput.issuerPublicKey == identity)
            #expect(partial.mintInput.tokenIdentifier == Self.token)
            #expect(partial.partialTokenOutputs.map(\.ownerPublicKey) == [identity])
            #expect(partial.partialTokenOutputs.map { decodeUInt128($0.tokenAmount) } == [5])
            try Self.expectSigned(request, by: wallet, inputs: 1)
        }
    }

    @Test("A create carries the token's parameters and returns the identifier the operators report", .timeLimit(.minutes(1)))
    func create() async throws {
        try await Self.withFinalizingOperator { wallet, state in
            let result = try await wallet.createToken(
                tokenName: "Piggy", tokenTicker: "PIG", decimals: 2, maxSupply: 1_000, isFreezable: false
            )
            let request = try await Self.onlyBroadcast(state)
            let create = request.partialTokenTransaction.createInput
            #expect(create.tokenName == "Piggy" && create.tokenTicker == "PIG" && create.decimals == 2)
            #expect(decodeUInt128(create.maxSupply) == 1_000)
            #expect(!create.hasCreationEntityPublicKey)
            #expect(request.partialTokenTransaction.partialTokenOutputs.isEmpty)
            #expect(result.tokenIdentifier == (try encodeBech32mTokenIdentifier(FakeOperator.createdTokenIdentifier, network: .regtest)))
            #expect(result.transactionHash == (try ProtoHash.hash(FakeOperator.finalize(request.partialTokenTransaction))).hexString)
            try Self.expectSigned(request, by: wallet, inputs: 1)
        }
    }

    typealias Tamper = @Sendable (inout SparkToken_FinalTokenTransaction) -> Void

    static let tamperings: [(String, Tamper)] = [
        ("output owner redirected", { $0.finalTokenOutputs[0].partialTokenOutput.ownerPublicKey = TokenHashVectorTests.key(99) }),
        ("output amount changed", { $0.finalTokenOutputs[0].partialTokenOutput.tokenAmount = encodeUInt128(41) }),
        ("withdraw bond changed", { $0.finalTokenOutputs[1].partialTokenOutput.withdrawBondSats = 1 }),
        ("revocation commitment missing", { $0.finalTokenOutputs[1].revocationCommitment = Data() }),
        ("output dropped", { $0.finalTokenOutputs.removeLast() }),
        ("input changed", { $0.transferInput.outputsToSpend[0].prevTokenTransactionVout = 7 }),
        ("metadata changed", { $0.tokenTransactionMetadata.validityDurationSeconds = 300 }),
        ("version changed", { $0.version = 2 }),
        ("type changed", { $0.tokenInputs = .mintInput(SparkToken_TokenMintInput()) }),
    ]

    @Test("A final transaction that is not the one signed is refused", .timeLimit(.minutes(1)), arguments: 0..<9)
    func tampered(index: Int) async throws {
        let (label, tamper) = Self.tamperings[index]
        try await Self.withFinalizingOperator(tamper: tamper) { wallet, _ in
            let receiver = SparkAddress.encode(identityPublicKey: TokenHashVectorTests.key(25), network: .regtest)
            let error = await #expect(throws: SparkError.self, Comment(rawValue: label)) {
                _ = try await wallet.transferTokens(
                    tokenIdentifier: try encodeBech32mTokenIdentifier(Self.token, network: .regtest),
                    tokenAmount: 40,
                    receiverSparkAddress: receiver
                )
            }
            guard case .untrustedResponse = error else {
                Issue.record("\(label): expected untrustedResponse, got \(String(describing: error))")
                return
            }
        }
    }

    @Test("V2 is still used when configured", .timeLimit(.minutes(1)))
    func v2WhenConfigured() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state, tokenTransactionVersion: .v2) { wallet in
            await state.setTokenOutputs(try TokenOutputLockTests.walletOutputs(wallet, amounts: [100]))
            await #expect(throws: RPCError.self) { try await TokenOutputLockTests.send(from: wallet) }
            #expect(await state.startedTransactions.count == 1)
            #expect(await state.startedTransactions.first?.transaction.version == 2)
            #expect(await state.broadcasts.isEmpty)
        }
    }
}
