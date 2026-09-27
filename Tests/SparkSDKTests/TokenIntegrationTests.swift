import Foundation
import GRPCCore
import SwiftProtobuf
import Testing
@testable import SparkSDK

// =============================================================================
// MARK: - Token (BTKN) Integration Tests
// =============================================================================

@Suite("Tokens", .serialized, .enabled(if: TestConfig.hasIntegrationCredentials))
struct TokenIntegrationTests {

    @Test("Should create a token, mint, transfer A->B, transfer B->A, and burn")
    func fullTokenLifecycle() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        // --- Phase 1: Create Token (or reuse existing) ---
        print("\n--- Phase 1: Create Token ---")
        let existingMetadatas = try await walletA.queryTokenMetadata(
            issuerPublicKeys: [walletA.signer.identityPublicKey]
        )
        let tokenIdentifier: String
        if let existing = existingMetadatas.first {
            tokenIdentifier = existing.tokenIdentifier
            print("Reusing existing token: \(existing.tokenName) (\(existing.tokenTicker))")
            print("Token identifier: \(tokenIdentifier)")
        } else {
            let creation = try await walletA.createToken(
                tokenName: "SwiftTest",
                tokenTicker: "SWFT",
                decimals: 2,
                maxSupply: 1_000_000,
                isFreezable: false
            )
            #expect(!creation.transactionHash.isEmpty)
            print("Token created, tx: \(creation.transactionHash)")

            try await Task.sleep(for: .seconds(5))

            let metadatas = try await walletA.queryTokenMetadata(
                issuerPublicKeys: [walletA.signer.identityPublicKey]
            )
            guard let tokenMeta = metadatas.first else {
                Issue.record("Token metadata not found after creation")
                return
            }
            tokenIdentifier = tokenMeta.tokenIdentifier
            print("Token identifier: \(tokenIdentifier)")
        }
        #expect(tokenIdentifier.hasPrefix("btkn1"))

        // --- Phase 2: Mint Tokens ---
        print("\n--- Phase 2: Mint 10000 tokens ---")
        let mintAmount: UInt128 = 10000
        let mintTx = try await walletA.mintTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: mintAmount
        )
        #expect(!mintTx.isEmpty)
        try await Self.expectOperatorsKnow(mintTx, by: walletA)
        print("Mint tx: \(mintTx)")

        try await Task.sleep(for: .seconds(5))

        // Check balance
        let balancesAfterMint = try await walletA.getTokenBalances()
        let swftBalance = balancesAfterMint.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        #expect(swftBalance != nil)
        print("WalletA SWFT balance after mint: \(swftBalance?.ownedBalance ?? 0)")
        #expect(swftBalance!.ownedBalance >= mintAmount)

        // --- Phase 3: Transfer A -> B (5000 tokens) ---
        print("\n--- Phase 3: Transfer 5000 SWFT A -> B ---")
        let transferAmount: UInt128 = 5000
        let sparkAddressB = walletB.getSparkAddress()
        let transferTx = try await walletA.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressB
        )
        #expect(!transferTx.isEmpty)
        try await Self.expectOperatorsKnow(transferTx, by: walletA)
        print("Transfer A->B tx: \(transferTx)")

        try await Task.sleep(for: .seconds(5))

        // Check B's balance
        let balancesB = try await walletB.getTokenBalances()
        let swftBalanceB = balancesB.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletB SWFT balance: \(swftBalanceB?.ownedBalance ?? 0)")
        #expect(swftBalanceB != nil)
        #expect(swftBalanceB!.ownedBalance >= transferAmount)

        // Check A's remaining balance
        let balancesA2 = try await walletA.getTokenBalances()
        let swftBalanceA2 = balancesA2.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletA SWFT balance after transfer: \(swftBalanceA2?.ownedBalance ?? 0)")

        // --- Phase 4: Transfer B -> A (send it all back) ---
        print("\n--- Phase 4: Transfer all SWFT B -> A ---")
        let sparkAddressA = walletA.getSparkAddress()
        let returnTx = try await walletB.transferTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: transferAmount,
            receiverSparkAddress: sparkAddressA
        )
        #expect(!returnTx.isEmpty)
        try await Self.expectOperatorsKnow(returnTx, by: walletB)
        print("Transfer B->A tx: \(returnTx)")

        try await Task.sleep(for: .seconds(5))

        // B is back to what it held before the round trip (it may keep tokens from earlier runs)
        let finalBBalances = try await walletB.getTokenBalances()
        let finalBSwft = finalBBalances.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletB final SWFT balance: \(finalBSwft?.ownedBalance ?? 0)")
        #expect((finalBSwft?.ownedBalance ?? 0) == swftBalanceB!.ownedBalance - transferAmount)

        // A should have all tokens back
        let finalABalances = try await walletA.getTokenBalances()
        let finalASwft = finalABalances.first { $0.tokenMetadata.tokenIdentifier == tokenIdentifier }
        print("WalletA final SWFT balance: \(finalASwft?.ownedBalance ?? 0)")
        #expect(finalASwft != nil && finalASwft!.ownedBalance >= mintAmount)

        // --- Phase 5: Burn some tokens ---
        print("\n--- Phase 5: Burn 1000 SWFT ---")
        let burnAmount: UInt128 = 1000
        let burnTx = try await walletA.burnTokens(
            tokenIdentifier: tokenIdentifier,
            tokenAmount: burnAmount
        )
        #expect(!burnTx.isEmpty)
        try await Self.expectOperatorsKnow(burnTx, by: walletA)
        print("Burn tx: \(burnTx)")

        try await Task.sleep(for: .seconds(5))

        let afterBurn = try await walletA.getTokenBalances()
        let afterBurnSwft = afterBurn.first(where: { $0.tokenMetadata.tokenIdentifier == tokenIdentifier })
        print("WalletA token balance after burn: \(afterBurnSwft?.ownedBalance ?? 0)")

        print("\nFull token lifecycle complete!")
    }

    @Test("Two concurrent sends from one wallet both land, on different outputs")
    func concurrentTokenSends() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let issued = try await walletA.queryTokenMetadata(issuerPublicKeys: [walletA.signer.identityPublicKey])
        let token = try #require(issued.first, "wallet A has issued no token; the lifecycle test creates one").tokenIdentifier
        let rawToken = try decodeBech32mTokenIdentifier(token, network: walletA.config.network).tokenIdentifier
        var available = try await walletA.fetchTokenOutputs(tokenIdentifiers: [rawToken]).filter(TokenOutputLocks.isAvailable)
        if available.count < 2 {
            for _ in available.count..<2 {
                _ = try await walletA.mintTokens(tokenIdentifier: token, tokenAmount: 10)
            }
            try await Task.sleep(for: .seconds(5))
            available = try await walletA.fetchTokenOutputs(tokenIdentifiers: [rawToken]).filter(TokenOutputLocks.isAvailable)
        }
        // The smallest output's amount: each send then spends a single output, and without
        // locks both would pick the same one and the operators would refuse one as pre-empted.
        let amount = try #require(available.map { decodeUInt128($0.output.tokenAmount) }.min())
        let balanceB = { (try await walletB.getTokenBalances()).first { $0.tokenMetadata.tokenIdentifier == token }?.ownedBalance ?? 0 }
        let before = try await balanceB()

        let addressB = walletB.getSparkAddress()
        async let first = walletA.transferTokens(tokenIdentifier: token, tokenAmount: amount, receiverSparkAddress: addressB)
        async let second = walletA.transferTokens(tokenIdentifier: token, tokenAmount: amount, receiverSparkAddress: addressB)
        let hashes = try await [first, second]
        print("Concurrent sends of \(amount): \(hashes)")
        #expect(Set(hashes).count == 2)
        for hash in hashes {
            try await Self.expectOperatorsKnow(hash, by: walletA)
        }

        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before + 2 * amount)

        // Back to A.
        let addressA = walletA.getSparkAddress()
        _ = try await walletB.transferTokens(tokenIdentifier: token, tokenAmount: 2 * amount, receiverSparkAddress: addressA)
        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before)
    }

    @Test("A send retried with its idempotency key is made once and returns the same hash")
    func idempotentTokenSend() async throws {
        let walletA = try await makeWallet(walletAMnemonic)
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let issued = try await walletA.queryTokenMetadata(issuerPublicKeys: [walletA.signer.identityPublicKey])
        let token = try #require(issued.first, "wallet A has issued no token; the lifecycle test creates one").tokenIdentifier
        let balanceB = { (try await walletB.getTokenBalances()).first { $0.tokenMetadata.tokenIdentifier == token }?.ownedBalance ?? 0 }
        let before = try await balanceB()

        let key = UUID().uuidString
        let addressB = walletB.getSparkAddress()
        let send = {
            try await walletA.transferTokens(tokenIdentifier: token, tokenAmount: 7, receiverSparkAddress: addressB, idempotencyKey: key)
        }
        let first = try await send()
        let retry = try await send()
        print("Keyed send: \(first), retried: \(retry)")
        #expect(retry == first)
        try await Self.expectOperatorsKnow(first, by: walletA)

        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before + 7)

        // Back to A.
        let addressA = walletA.getSparkAddress()
        _ = try await walletB.transferTokens(tokenIdentifier: token, tokenAmount: 7, receiverSparkAddress: addressA)
        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before)
    }

    @Test("V2 token transactions still work when configured")
    func v2TokenSend() async throws {
        let walletA = try await makeWallet(walletAMnemonic, config: SparkConfig(tokenTransactionVersion: .v2))
        defer { Task { await walletA.close() } }
        let walletB = try await makeWallet(walletBMnemonic)
        defer { Task { await walletB.close() } }

        let issued = try await walletA.queryTokenMetadata(issuerPublicKeys: [walletA.signer.identityPublicKey])
        let token = try #require(issued.first, "wallet A has issued no token; the lifecycle test creates one").tokenIdentifier
        let balanceB = { (try await walletB.getTokenBalances()).first { $0.tokenMetadata.tokenIdentifier == token }?.ownedBalance ?? 0 }
        let before = try await balanceB()

        let hash = try await walletA.transferTokens(tokenIdentifier: token, tokenAmount: 3, receiverSparkAddress: walletB.getSparkAddress())
        print("V2 send: \(hash)")
        try await Self.expectOperatorsKnow(hash, by: walletA, version: 2)
        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before + 3)

        // Back to A, as V3.
        _ = try await walletB.transferTokens(tokenIdentifier: token, tokenAmount: 3, receiverSparkAddress: walletA.getSparkAddress())
        try await Task.sleep(for: .seconds(5))
        #expect(try await balanceB() == before)
    }

    /// The operators hold a finalized transaction of `version` under `hash`, the hash the SDK
    /// reported for it.
    static func expectOperatorsKnow(_ hash: String, by wallet: SparkWallet, version: UInt32 = 3) async throws {
        var byHash = SparkToken_QueryTokenTransactionsByTxHash()
        byHash.tokenTransactionHashes = [try #require(Data(hexString: hash))]
        var request = SparkToken_QueryTokenTransactionsRequest()
        request.queryType = .byTxHash(byHash)
        let response = try await wallet.getTokenClient().query_token_transactions(request: ClientRequest(
            message: request, metadata: try await wallet.getAuthMetadata(for: wallet.config.coordinatorAddress)
        ))
        let found = response.tokenTransactionsWithStatus
        #expect(found.map(\.tokenTransactionHash.hexString) == [hash], "the operators hold no transaction \(hash)")
        #expect(found.first?.status == .tokenTransactionFinalized, "status \(String(describing: found.first?.status))")
        #expect(found.first?.tokenTransaction.version == version)
    }

    @Test("Should query token outputs")
    func queryTokenOutputs() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let outputs = try await wallet.getTokenOutputs()
        print("Token outputs: \(outputs.count)")
        for output in outputs.prefix(5) {
            let tokenId = output.tokenIdentifier.hexString
            print("  amount=\(output.tokenAmount) token=\(tokenId.prefix(16))... status=\(output.status)")
        }
    }

    @Test("Should query token balances")
    func queryTokenBalances() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let balances = try await wallet.getTokenBalances()
        print("Token balances: \(balances.count) tokens")
        for balance in balances {
            print("  \(balance.tokenMetadata.tokenName) (\(balance.tokenMetadata.tokenTicker))")
            print("    identifier: \(balance.tokenMetadata.tokenIdentifier)")
            print("    owned: \(balance.ownedBalance)")
            print("    available: \(balance.availableToSendBalance)")
            print("    decimals: \(balance.tokenMetadata.decimals)")
        }
    }

    @Test("Should query token metadata by issuer")
    func queryTokenMetadataByIssuer() async throws {
        let wallet = try await makeWallet(walletAMnemonic)
        defer { Task { await wallet.close() } }

        let metadatas = try await wallet.queryTokenMetadata(
            issuerPublicKeys: [wallet.signer.identityPublicKey]
        )
        print("Token metadata for issuer: \(metadatas.count) tokens")
        for meta in metadatas {
            print("  \(meta.tokenName) (\(meta.tokenTicker))")
            print("    identifier: \(meta.tokenIdentifier)")
            print("    issuer: \(meta.issuerPublicKey.hexString)")
            print("    maxSupply: \(decodeUInt128(meta.maxSupply))")
            print("    freezable: \(meta.isFreezable)")
        }
    }
}
