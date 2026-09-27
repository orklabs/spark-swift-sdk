import Foundation
import CryptoKit
import Testing
@testable import SparkSDK

/// The pieces of a static-deposit refund, checked against what the operators verify
/// (`static_deposit_handler.go`, `internal_deposit_handler.go`) and what the reference SDK sends.
@Suite("Static deposit refund")
struct StaticDepositRefundTests {
    static let txid = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
    static let destination = "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0"
    static let destinationScript = Data(hexString: "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!

    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// BIP-341 key-path sighash with SIGHASH_DEFAULT for input 0 of a one-input transaction —
    /// what the operators compute (`sighash.FromTx`), written out independently.
    static func taprootSighash(_ tx: RawTransaction, prevoutScript: Data, prevoutValue: UInt64) -> Data {
        var prevouts = Data()
        var sequences = Data()
        for input in tx.inputs {
            prevouts += input.previousTxid
            prevouts += le32(input.previousIndex)
            sequences += le32(input.sequence)
        }
        var outputs = Data()
        for output in tx.outputs {
            outputs += le64(output.value)
            outputs += Data([UInt8(output.scriptPubKey.count)])
            outputs += output.scriptPubKey
        }
        var scripts = Data([UInt8(prevoutScript.count)])
        scripts += prevoutScript
        var message = Data([0x00, 0x00])  // epoch, hash type
        message += le32(tx.version)
        message += le32(tx.locktime)
        message += sha256(prevouts)
        message += sha256(le64(prevoutValue))
        message += sha256(scripts)
        message += sha256(sequences)
        message += sha256(outputs)
        message += Data([0x00])  // key path, no annex
        message += le32(0)       // input index
        let tag = sha256(Data("TapSighash".utf8))
        var tagged = tag
        tagged += tag
        tagged += message
        return sha256(tagged)
    }

    @Test("A deposit outpoint is a lower-case display txid; the operators look it up in display order")
    func outpoint() throws {
        let outpoint = try DepositOutpoint(txid: " \(Self.txid.uppercased())\n", vout: 2)
        #expect(outpoint.txid == Self.txid)
        #expect(outpoint.displayOrderTxid == Data(hexString: Self.txid))
        let displayOrder = try #require(Data(hexString: Self.txid))
        #expect(outpoint.internalOrderTxid == Data(displayOrder.reversed()))
        let utxo = outpoint.utxo(network: .mainnet)
        // `hexToBytes(depositTransactionId)` in the reference SDK; the operators match it against
        // the txid string decoded as stored.
        #expect(utxo.txid == Data(hexString: Self.txid))
        #expect(utxo.vout == 2)
        for bad in ["", "abc", String(Self.txid.dropLast()), String(Self.txid.dropLast()) + "g", Self.txid + "00"] {
            #expect(throws: SparkError.self) { _ = try DepositOutpoint(txid: bad, vout: 0) }
        }
    }

    @Test("The unsigned refund is exactly the transaction the operators rebuild: v3, final sequence, no witness")
    func spendTransaction() throws {
        let outpoint = try DepositOutpoint(txid: Self.txid, vout: 1)
        let spend = try SparkWallet.constructSpendTx(
            spending: outpoint, destinationAddress: Self.destination, amountSats: 12_345, network: .mainnet
        )
        var expected: Data = Self.le32(3)
        expected += Data([0x01])
        expected += outpoint.internalOrderTxid
        expected += Self.le32(1)
        expected += Data([0x00])
        expected += Self.le32(0xFFFF_FFFF)
        expected += Data([0x01])
        expected += Self.le64(12_345)
        expected += Data([UInt8(Self.destinationScript.count)])
        expected += Self.destinationScript
        expected += Self.le32(0)
        #expect(spend == expected)

        // Signing adds the witness without changing the transaction.
        let signature = Data(repeating: 0xCC, count: 64)
        let signed = try RawTransaction.parse(try SparkWallet.addWitnessToTx(spend, witness: signature))
        #expect(signed.hasWitnessSerialization)
        #expect(signed.inputs[0].witness == [signature])
        #expect(signed.txid == (try RawTransaction.parse(spend)).txid)
    }

    @Test("The refund sighash is the BIP-341 key-path sighash the operators compute")
    func refundSighash() throws {
        let outpoint = try DepositOutpoint(txid: Self.txid, vout: 0)
        let spend = try SparkWallet.constructSpendTx(
            spending: outpoint, destinationAddress: Self.destination, amountSats: 9_000, network: .mainnet
        )
        let depositScript = Data([0x51, 0x20]) + Data(repeating: 0x42, count: 32)
        let sighash = try computeMultiInputSighashUniffi(
            tx: spend, inputIndex: 0, prevOutScripts: [depositScript], prevOutValues: [10_000]
        )
        #expect(sighash == Self.taprootSighash(try RawTransaction.parse(spend), prevoutScript: depositScript, prevoutValue: 10_000))
    }

    @Test("The refund statement ends with the raw 32-byte sighash, as the operators verify it")
    func refundStatement() throws {
        let outpoint = try DepositOutpoint(txid: Self.txid, vout: 1)
        let sighash = Data(repeating: 0x11, count: 32)
        let statement = SparkWallet.staticDepositStatement(
            outpoint, network: .mainnet, requestType: .refund, creditAmountSats: 1_000, authorization: sighash
        )
        func expected(network: String, requestType: UInt8, credit: UInt64, authorization: Data) -> Data {
            var bytes = Data("claim_static_deposit".utf8)
            bytes += Data(network.utf8)
            bytes += Data(Self.txid.utf8)
            bytes += Self.le32(1)
            bytes += Data([requestType])
            bytes += Self.le64(credit)
            bytes += authorization
            return bytes
        }
        #expect(statement == expected(network: "mainnet", requestType: 2, credit: 1_000, authorization: sighash))
        #expect(statement.count == 20 + 7 + 64 + 4 + 1 + 8 + 32)
        let regtest = SparkWallet.staticDepositStatement(
            outpoint, network: .regtest, requestType: .fixed, creditAmountSats: 1, authorization: Data([0xAB])
        )
        #expect(regtest == expected(network: "regtest", requestType: 0, credit: 1, authorization: Data([0xAB])))
    }
}

/// Static deposit claims sign exactly the quote that was checked.
@Suite("Static deposit claim")
struct StaticDepositClaimTests {
    @Test("A claim statement commits to the quote's credit and the SSP's signature bytes")
    func claimStatement() throws {
        let outpoint = try DepositOutpoint(txid: StaticDepositRefundTests.txid.uppercased(), vout: 3)
        let quote = DepositFeeEstimate(creditAmountSats: 49_000, quoteSignature: "3045022100aabb")
        let statement = SparkWallet.staticDepositStatement(
            outpoint, network: .mainnet, requestType: .fixed,
            creditAmountSats: UInt64(quote.creditAmountSats), authorization: try #require(Data(hexString: quote.quoteSignature))
        )
        // What the SDK signed before: the lower-case txid as given, the hex-decoded quote signature.
        var previous = Data("claim_static_deposit".utf8)
        previous += Data("MAINNET".lowercased().utf8)
        previous += Data(StaticDepositRefundTests.txid.utf8)
        previous += withUnsafeBytes(of: UInt32(3).littleEndian) { Data($0) }
        previous += Data([0])
        previous += withUnsafeBytes(of: UInt64(49_000).littleEndian) { Data($0) }
        previous += try #require(Data(hexString: "3045022100aabb"))
        #expect(statement == previous)
        #expect(SparkWallet.staticDepositFee(depositSats: 50_000, quote: quote) == 1_000)
    }

    @Test("A quote with no credit or a signature that is not hex is refused before the SSP is asked",
          .timeLimit(.minutes(1)))
    func invalidQuotes() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            let txid = StaticDepositRefundTests.txid
            do {
                _ = try await wallet.claimStaticDeposit(
                    transactionId: txid, quote: DepositFeeEstimate(creditAmountSats: 0, quoteSignature: "aa")
                )
                Issue.record("a quote crediting nothing was claimed")
            } catch SparkError.invalidArgument {}
            do {
                _ = try await wallet.claimStaticDeposit(
                    transactionId: txid, quote: DepositFeeEstimate(creditAmountSats: 10, quoteSignature: "not hex")
                )
                Issue.record("a quote whose signature is not hex was claimed")
            } catch SparkError.invalidResponse {}
            await #expect(throws: SparkError.self) {
                _ = try await wallet.claimStaticDeposit(
                    transactionId: "abc", quote: DepositFeeEstimate(creditAmountSats: 10, quoteSignature: "aa")
                )
            }
        }
    }
}

/// Transaction ids from callers reach the block explorer only once they are known to be txids.
@Suite("Block explorer lookups")
struct BlockExplorerTests {
    @Test("A txid that is not 64 hex characters throws before any request, instead of trapping",
          .timeLimit(.minutes(1)))
    func malformedTxids() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            for bad in ["", "not a txid", "zz" + String(repeating: "0", count: 62), "a b", String(repeating: "0", count: 65)] {
                do {
                    _ = try await wallet.fetchRawTransaction(txID: bad)
                    Issue.record("fetched '\(bad)'")
                } catch SparkError.invalidArgument {}
            }
        }
        #expect(try DepositOutpoint.normalizedTxid(" \(StaticDepositRefundTests.txid.uppercased()) ") == StaticDepositRefundTests.txid)
    }

    @Test("A mainnet transaction fetched by an upper-case txid hashes to it",
          .enabled(if: TestConfig.hasIntegrationCredentials), .timeLimit(.minutes(1)))
    func fetchKnownTransaction() async throws {
        // The first bitcoin transaction between people: Satoshi to Hal Finney, block 170.
        let txid = "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
        let wallet = try SparkWallet(mnemonic: TestConfig.walletAMnemonic)
        let raw = try await wallet.fetchRawTransaction(txID: txid.uppercased())
        #expect(try RawTransaction.parse(raw).txidHex == txid)
    }
}

/// Without an output index, static-deposit calls use the output that pays the wallet's static
/// deposit address, as the reference SDK's `getDepositTransactionVout` finds it.
@Suite("Static deposit output detection")
struct StaticDepositVoutTests {
    static let staticAddress = "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0"
    static let otherAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    static func transaction(paying addresses: [String]) throws -> RawTransaction {
        RawTransaction(
            version: 2,
            inputs: [RawTransaction.Input(previousTxid: Data(repeating: 0x01, count: 32), previousIndex: 0)],
            outputs: try addresses.map {
                RawTransaction.Output(value: 1_000, scriptPubKey: try BitcoinAddress.scriptPubKey(for: $0, network: .mainnet))
            },
            locktime: 0, hasWitnessSerialization: false
        )
    }

    @Test("The first output paying a static deposit address is used; none is an error")
    func detection() throws {
        let addresses = [Self.staticAddress]
        #expect(try SparkWallet.staticDepositVout(
            of: try Self.transaction(paying: [Self.otherAddress, Self.staticAddress]), paying: addresses, network: .mainnet
        ) == 1)
        #expect(try SparkWallet.staticDepositVout(
            of: try Self.transaction(paying: [Self.staticAddress, Self.staticAddress]), paying: addresses, network: .mainnet
        ) == 0)
        #expect(throws: SparkError.self) {
            let other = try Self.transaction(paying: [Self.otherAddress])
            _ = try SparkWallet.staticDepositVout(of: other, paying: addresses, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try SparkWallet.staticDepositVout(of: try Self.transaction(paying: [Self.staticAddress]), paying: [], network: .mainnet)
        }
    }

    @Test("A past deposit to a test wallet's static address is found at the output the operators report",
          .enabled(if: TestConfig.hasIntegrationCredentials), .timeLimit(.minutes(2)))
    func detectsPastDeposit() async throws {
        for mnemonic in [TestConfig.walletBMnemonic, TestConfig.walletAMnemonic] {
            let wallet = try await makeWallet(mnemonic)
            defer { Task { await wallet.close() } }
            let address = try await wallet.getStaticDepositAddress().address
            guard let utxo = try await wallet.getUtxosForDepositAddress(address: address, excludeClaimed: false).first else { continue }
            #expect(try await wallet.staticDepositVout(txid: utxo.txid, outputIndex: nil) == utxo.vout)
            print("static deposit \(utxo.txid):\(utxo.vout) found by its address")
            return
        }
        Issue.record("neither test wallet has ever received a static deposit")
    }
}
