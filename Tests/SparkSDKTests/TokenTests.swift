import Foundation
import SwiftProtobuf
import Testing
@testable import SparkSDK

// MARK: - Token Identifier Tests

@Test func testTokenIdentifierEncodeDecodeMainnet() throws {
    let rawId = Data(hexString: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")!
    let encoded = try encodeBech32mTokenIdentifier(rawId, network: .mainnet)
    #expect(encoded.hasPrefix("btkn1"))

    let (decoded, network) = try decodeBech32mTokenIdentifier(encoded, network: .mainnet)
    #expect(decoded == rawId)
    #expect(network == .mainnet)
}

@Test func testTokenIdentifierEncodeDecodeRegtest() throws {
    let rawId = Data(hexString: "0000000000000000000000000000000000000000000000000000000000000001")!
    let encoded = try encodeBech32mTokenIdentifier(rawId, network: .regtest)
    #expect(encoded.hasPrefix("btknrt1"))

    let (decoded, network) = try decodeBech32mTokenIdentifier(encoded)
    #expect(decoded == rawId)
    #expect(network == .regtest)
}

@Test func testTokenIdentifierRoundtrip() throws {
    // Test with random-looking data
    let rawId = Data(hexString: "deadbeefcafebabe1234567890abcdef1122334455667788aabbccddeeff0011")!

    for network: SparkNetwork in [.mainnet, .regtest] {
        let encoded = try encodeBech32mTokenIdentifier(rawId, network: network)
        let (decoded, decodedNetwork) = try decodeBech32mTokenIdentifier(encoded)
        #expect(decoded == rawId, "Roundtrip failed for \(network)")
        #expect(decodedNetwork == network)
    }
}

@Test func testTokenIdentifierInvalidLength() throws {
    let shortId = Data(hexString: "abcdef")!
    do {
        _ = try encodeBech32mTokenIdentifier(shortId, network: .mainnet)
        Issue.record("Should have thrown for short identifier")
    } catch {
        // Expected
    }
}

@Test func testTokenIdentifierWrongNetwork() throws {
    let rawId = Data(hexString: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")!
    let encoded = try encodeBech32mTokenIdentifier(rawId, network: .mainnet)

    // Should fail when decoding with wrong network
    do {
        _ = try decodeBech32mTokenIdentifier(encoded, network: .regtest)
        Issue.record("Should have thrown for wrong network")
    } catch {
        // Expected
    }
}

// MARK: - UInt128 Encoding Tests

@Test func testUInt128EncodeDecode() {
    let testCases: [UInt128] = [0, 1, 255, 256, 1000, 1_000_000, UInt128.max]
    for value in testCases {
        let encoded = encodeUInt128(value)
        #expect(encoded.count == 16, "Encoded length should be 16 for \(value)")
        let decoded = decodeUInt128(encoded)
        #expect(decoded == value, "Roundtrip failed for \(value)")
    }
}

@Test func testUInt128EncodeDecodeSpecific() {
    // 1000 in big-endian 16 bytes
    let encoded = encodeUInt128(1000)
    #expect(encoded.count == 16)
    // Last 2 bytes should be 0x03, 0xE8 for 1000
    #expect(encoded[14] == 0x03)
    #expect(encoded[15] == 0xE8)
    // All other bytes should be 0
    for i in 0..<14 {
        #expect(encoded[i] == 0, "Byte \(i) should be 0")
    }
}

@Test func testUInt128Zero() {
    let encoded = encodeUInt128(0)
    #expect(encoded == Data(count: 16))
    #expect(decodeUInt128(encoded) == 0)
}

// MARK: - Token Output Selection Tests

@Test func testTokenOutputSelectionExactMatch() throws {
    let outputs = makeTokenOutputs([100, 200, 300, 500])
    let selected = try SparkWallet.selectTokenOutputs(outputs, amount: 200, strategy: .smallFirst)
    #expect(selected.count == 1)
    #expect(decodeUInt128(selected[0].output.tokenAmount) == 200)
}

@Test func testTokenOutputSelectionSmallFirst() throws {
    let outputs = makeTokenOutputs([10, 20, 30, 50, 100])
    let selected = try SparkWallet.selectTokenOutputs(outputs, amount: 55, strategy: .smallFirst)
    // Should pick smallest outputs that sum to >= 55: 10+20+30 = 60 >= 55
    let total = selected.reduce(UInt128(0)) { $0 + decodeUInt128($1.output.tokenAmount) }
    #expect(total >= 55)
}

@Test func testTokenOutputSelectionLargeFirst() throws {
    let outputs = makeTokenOutputs([10, 20, 30, 50, 100])
    let selected = try SparkWallet.selectTokenOutputs(outputs, amount: 55, strategy: .largeFirst)
    // Should pick 100 first (greedy)
    let total = selected.reduce(UInt128(0)) { $0 + decodeUInt128($1.output.tokenAmount) }
    #expect(total >= 55)
    // Large first should use fewer outputs
    #expect(selected.count <= 2)
}

@Test func testTokenOutputSelectionInsufficientBalance() throws {
    let outputs = makeTokenOutputs([10, 20, 30])
    do {
        _ = try SparkWallet.selectTokenOutputs(outputs, amount: 100, strategy: .smallFirst)
        Issue.record("Should have thrown for insufficient balance")
    } catch let error as SparkError {
        if case .insufficientTokenBalance = error {
            // Expected
        } else {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

@Test func testTokenOutputSelectionZeroAmount() throws {
    let outputs = makeTokenOutputs([100])
    do {
        _ = try SparkWallet.selectTokenOutputs(outputs, amount: 0, strategy: .smallFirst)
        Issue.record("Should have thrown for zero amount")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

@Test func testTokenOutputSelectionSingleOutput() throws {
    let outputs = makeTokenOutputs([500])
    let selected = try SparkWallet.selectTokenOutputs(outputs, amount: 300, strategy: .smallFirst)
    #expect(selected.count == 1)
    #expect(decodeUInt128(selected[0].output.tokenAmount) == 500)
}

@Test func testTokenOutputSelectionAllOutputs() throws {
    let outputs = makeTokenOutputs([10, 20, 30])
    let selected = try SparkWallet.selectTokenOutputs(outputs, amount: 60, strategy: .smallFirst)
    #expect(selected.count == 3)
    let total = selected.reduce(UInt128(0)) { $0 + decodeUInt128($1.output.tokenAmount) }
    #expect(total == 60)
}

// MARK: - Token Hashing Tests

@Test func testTokenHashingV2Transfer() throws {
    // Build a simple V2 transfer transaction and verify hashing doesn't throw
    var tx = SparkToken_TokenTransaction()
    tx.version = 2
    tx.network = .mainnet

    var transferInput = SparkToken_TokenTransferInput()
    var outputToSpend = SparkToken_TokenOutputToSpend()
    outputToSpend.prevTokenTransactionHash = Data(count: 32)
    outputToSpend.prevTokenTransactionVout = 0
    transferInput.outputsToSpend = [outputToSpend]
    tx.tokenInputs = .transferInput(transferInput)

    var tokenOutput = SparkToken_TokenOutput()
    tokenOutput.ownerPublicKey = Data(count: 33)
    tokenOutput.tokenAmount = encodeUInt128(1000)
    tx.tokenOutputs = [tokenOutput]

    tx.sparkOperatorIdentityPublicKeys = [Data(count: 33)]
    tx.clientCreatedTimestamp = .init(date: Date())

    let partialHash = try hashTokenTransactionV2(tx, partialHash: true)
    #expect(partialHash.count == 32)

    let fullHash = try hashTokenTransactionV2(tx, partialHash: false)
    #expect(fullHash.count == 32)

    // Partial and full hashes should differ (full includes more fields)
    #expect(partialHash != fullHash)
}

@Test func testTokenHashingV2Deterministic() throws {
    var tx = SparkToken_TokenTransaction()
    tx.version = 2
    tx.network = .regtest

    var mintInput = SparkToken_TokenMintInput()
    mintInput.issuerPublicKey = Data(repeating: 0x02, count: 33)
    mintInput.tokenIdentifier = Data(count: 32)
    tx.tokenInputs = .mintInput(mintInput)

    var tokenOutput = SparkToken_TokenOutput()
    tokenOutput.ownerPublicKey = Data(repeating: 0x03, count: 33)
    tokenOutput.tokenAmount = encodeUInt128(42)
    tx.tokenOutputs = [tokenOutput]

    tx.sparkOperatorIdentityPublicKeys = [Data(repeating: 0x02, count: 33)]
    tx.clientCreatedTimestamp = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 1700000000))

    let hash1 = try hashTokenTransactionV2(tx, partialHash: true)
    let hash2 = try hashTokenTransactionV2(tx, partialHash: true)
    #expect(hash1 == hash2, "Hashing should be deterministic")
}

@Test func testOperatorSpecificPayloadHash() throws {
    let txHash = Data(count: 32)
    let operatorKey = Data(repeating: 0x02, count: 33)

    let hash = try hashOperatorSpecificPayload(
        finalTokenTransactionHash: txHash,
        operatorIdentityPublicKey: operatorKey
    )
    #expect(hash.count == 32)

    // Should be deterministic
    let hash2 = try hashOperatorSpecificPayload(
        finalTokenTransactionHash: txHash,
        operatorIdentityPublicKey: operatorKey
    )
    #expect(hash == hash2)

    // Different inputs should produce different hashes
    let differentKey = Data(repeating: 0x03, count: 33)
    let hash3 = try hashOperatorSpecificPayload(
        finalTokenTransactionHash: txHash,
        operatorIdentityPublicKey: differentKey
    )
    #expect(hash != hash3)
}

@Test func testOperatorSpecificPayloadHashInvalidInputs() throws {
    do {
        _ = try hashOperatorSpecificPayload(
            finalTokenTransactionHash: Data(count: 16), // Wrong length
            operatorIdentityPublicKey: Data(count: 33)
        )
        Issue.record("Should have thrown for invalid hash length")
    } catch {
        // Expected
    }

    do {
        _ = try hashOperatorSpecificPayload(
            finalTokenTransactionHash: Data(count: 32),
            operatorIdentityPublicKey: Data() // Empty
        )
        Issue.record("Should have thrown for empty operator key")
    } catch {
        // Expected
    }
}

// MARK: - Operator Keys Tests

@Test func testCollectOperatorIdentityPublicKeys() throws {
    let wallet = try SparkWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    let keys = wallet.collectOperatorIdentityPublicKeys()
    // Mainnet default has 3 operators with known public keys
    #expect(keys.count == 3)
    // Should be sorted
    for i in 0..<keys.count - 1 {
        #expect(keys[i].lexicographicallyPrecedes(keys[i + 1]), "Keys should be sorted")
    }
}

// MARK: - Token Hashing: Create Input

@Test func testTokenHashingV2CreateInput() throws {
    var tx = SparkToken_TokenTransaction()
    tx.version = 2
    tx.network = .mainnet

    var createInput = SparkToken_TokenCreateInput()
    createInput.issuerPublicKey = Data(repeating: 0x02, count: 33)
    createInput.tokenName = "TestToken"
    createInput.tokenTicker = "TST"
    createInput.decimals = 8
    createInput.maxSupply = encodeUInt128(21_000_000)
    createInput.isFreezable = false
    tx.tokenInputs = .createInput(createInput)

    tx.tokenOutputs = []
    tx.sparkOperatorIdentityPublicKeys = [Data(repeating: 0x02, count: 33)]
    tx.clientCreatedTimestamp = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 1700000000))

    let partialHash = try hashTokenTransactionV2(tx, partialHash: true)
    #expect(partialHash.count == 32)

    let fullHash = try hashTokenTransactionV2(tx, partialHash: false)
    #expect(fullHash.count == 32)
    #expect(partialHash != fullHash)
}

// MARK: - Token Hashing: Mint Input

@Test func testTokenHashingV2MintInput() throws {
    var tx = SparkToken_TokenTransaction()
    tx.version = 2
    tx.network = .regtest

    var mintInput = SparkToken_TokenMintInput()
    mintInput.issuerPublicKey = Data(repeating: 0x03, count: 33)
    mintInput.tokenIdentifier = Data(repeating: 0xAB, count: 32)
    tx.tokenInputs = .mintInput(mintInput)

    var tokenOutput = SparkToken_TokenOutput()
    tokenOutput.ownerPublicKey = Data(repeating: 0x03, count: 33)
    tokenOutput.tokenIdentifier = Data(repeating: 0xAB, count: 32)
    tokenOutput.tokenAmount = encodeUInt128(5000)
    tx.tokenOutputs = [tokenOutput]

    tx.sparkOperatorIdentityPublicKeys = [Data(repeating: 0x02, count: 33)]
    tx.clientCreatedTimestamp = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 1700000000))

    let hash = try hashTokenTransactionV2(tx, partialHash: true)
    #expect(hash.count == 32)
}

// MARK: - Create/Mint Validation Tests

@Test func testCreateTokenValidation() async throws {
    let wallet = try SparkWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")

    // Name too long
    do {
        _ = try await wallet.createToken(
            tokenName: String(repeating: "A", count: 21),
            tokenTicker: "TST",
            decimals: 8,
            isFreezable: false
        )
        Issue.record("Should have thrown for name too long")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error: \(error)")
        }
    }

    // Empty name
    do {
        _ = try await wallet.createToken(
            tokenName: "",
            tokenTicker: "TST",
            decimals: 8,
            isFreezable: false
        )
        Issue.record("Should have thrown for empty name")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error: \(error)")
        }
    }

    // Ticker too long
    do {
        _ = try await wallet.createToken(
            tokenName: "Test",
            tokenTicker: "TOOLONG",
            decimals: 8,
            isFreezable: false
        )
        Issue.record("Should have thrown for ticker too long")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error: \(error)")
        }
    }

    // Decimals too high
    do {
        _ = try await wallet.createToken(
            tokenName: "Test",
            tokenTicker: "TST",
            decimals: 256,
            isFreezable: false
        )
        Issue.record("Should have thrown for decimals > 255")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error: \(error)")
        }
    }
}

@Test func testMintTokensValidation() async throws {
    let wallet = try SparkWallet(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
    let fakeTokenId = try encodeBech32mTokenIdentifier(Data(count: 32), network: .mainnet)

    do {
        _ = try await wallet.mintTokens(tokenIdentifier: fakeTokenId, tokenAmount: 0)
        Issue.record("Should have thrown for zero amount")
    } catch let error as SparkError {
        if case .tokenValidationFailed = error {
            // Expected
        } else {
            Issue.record("Wrong error: \(error)")
        }
    }
}

// MARK: - Test Helpers

private func makeTokenOutputs(_ amounts: [UInt128]) -> [SparkToken_OutputWithPreviousTransactionData] {
    amounts.enumerated().map { (i, amount) in
        var output = SparkToken_TokenOutput()
        output.ownerPublicKey = Data(repeating: 0x02, count: 33)
        output.tokenIdentifier = Data(count: 32)
        output.tokenAmount = encodeUInt128(amount)

        var outputWithData = SparkToken_OutputWithPreviousTransactionData()
        outputWithData.output = output
        outputWithData.previousTransactionHash = Data(count: 32)
        outputWithData.previousTransactionVout = UInt32(i)
        return outputWithData
    }
}
