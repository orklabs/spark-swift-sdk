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
