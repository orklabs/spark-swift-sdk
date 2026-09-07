// swiftlint:disable line_length — specification test vectors are long single tokens
import Foundation
import Testing
@testable import SparkSDK

// MARK: - Test helpers

private func hex(_ s: String) -> Data { Data(hexString: s)! }

/// bech32 characters → 5-bit words
private func words(_ s: String) -> [UInt8] {
    let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    return s.compactMap { c in charset.firstIndex(of: c).map { UInt8($0) } }
}

/// The Bitcoin genesis block coinbase transaction (legacy serialisation).
private let genesisCoinbaseHex = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000"
private let genesisCoinbaseTxid = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"

/// A witness transaction with two inputs and two outputs, built by hand.
private func sampleWitnessTransaction() -> RawTransaction {
    RawTransaction(
        version: 2,
        inputs: [
            RawTransaction.Input(
                previousTxid: Data(repeating: 0x11, count: 32), previousIndex: 1,
                scriptSig: Data(), sequence: 0x4000_07D0, witness: [Data(repeating: 0xAA, count: 64)]
            ),
            RawTransaction.Input(
                previousTxid: Data(repeating: 0x22, count: 32), previousIndex: 0,
                scriptSig: Data([0x51]), sequence: 0xFFFF_FFFF, witness: []
            ),
        ],
        outputs: [
            RawTransaction.Output(value: 100_000, scriptPubKey: hex("5120") + Data(repeating: 0x33, count: 32)),
            RawTransaction.Output(value: 955, scriptPubKey: hex("0014") + Data(repeating: 0x44, count: 20)),
        ],
        locktime: 0,
        hasWitnessSerialization: true
    )
}

// MARK: - RawTransaction

@Suite("RawTransaction parser")
struct RawTransactionTests {

    @Test("Parses the genesis coinbase and reproduces its txid")
    func genesisCoinbase() throws {
        let tx = try RawTransaction.parse(hex(genesisCoinbaseHex))
        #expect(tx.version == 1)
        #expect(tx.hasWitnessSerialization == false)
        #expect(tx.inputs.count == 1)
        #expect(tx.inputs[0].previousTxid == Data(repeating: 0, count: 32))
        #expect(tx.inputs[0].previousIndex == 0xFFFF_FFFF)
        #expect(tx.inputs[0].scriptSig.count == 0x4d)
        #expect(tx.inputs[0].sequence == 0xFFFF_FFFF)
        #expect(tx.outputs.count == 1)
        #expect(tx.outputs[0].value == 5_000_000_000)
        #expect(tx.outputs[0].scriptPubKey.count == 0x43)
        #expect(tx.locktime == 0)
        #expect(tx.txidHex == genesisCoinbaseTxid)
        #expect(tx.txid == Data(hex(genesisCoinbaseTxid).reversed()))
        #expect(tx.serialized(includeWitness: true) == hex(genesisCoinbaseHex))
        #expect(try SparkWallet.computeTxId(hex(genesisCoinbaseHex)) == tx.txid)
    }

    @Test("Witness transactions round-trip and the txid ignores witness data")
    func witnessRoundTrip() throws {
        let tx = sampleWitnessTransaction()
        let bytes = tx.serialized(includeWitness: true)
        // marker + flag present
        #expect(bytes[4] == 0x00 && bytes[5] == 0x01)
        let parsed = try RawTransaction.parse(bytes)
        #expect(parsed == tx)
        #expect(parsed.inputs[0].witness == [Data(repeating: 0xAA, count: 64)])
        #expect(parsed.inputs[1].witness.isEmpty)

        // The legacy serialisation is the version, inputs, outputs and locktime only.
        var legacy = Data()
        legacy.append(hex("02000000"))
        legacy.append(0x02)
        legacy.append(Data(repeating: 0x11, count: 32)); legacy.append(hex("01000000")); legacy.append(0x00); legacy.append(hex("d0070040"))
        legacy.append(Data(repeating: 0x22, count: 32)); legacy.append(hex("00000000")); legacy.append(hex("0151")); legacy.append(hex("ffffffff"))
        legacy.append(0x02)
        legacy.append(hex("a086010000000000")); legacy.append(0x22); legacy.append(hex("5120") + Data(repeating: 0x33, count: 32))
        legacy.append(hex("bb03000000000000")); legacy.append(0x16); legacy.append(hex("0014") + Data(repeating: 0x44, count: 20))
        legacy.append(hex("00000000"))
        #expect(tx.serialized(includeWitness: false) == legacy)

        var stripped = tx
        stripped.hasWitnessSerialization = false
        for i in stripped.inputs.indices { stripped.inputs[i].witness = [] }
        #expect(try RawTransaction.parse(legacy) == stripped)
        #expect(tx.txid == stripped.txid)
        #expect(try tx.firstInputSequence == 0x4000_07D0)
        #expect(try SparkWallet.parseSequenceFromRawTx(bytes) == 0x4000_07D0)
        #expect(try SparkWallet.parseTxOutput(bytes, vout: 1).value == 955)
    }

    @Test("Every truncation of a valid transaction throws instead of trapping")
    func truncationNeverCrashes() {
        for raw in [hex(genesisCoinbaseHex), sampleWitnessTransaction().serialized(includeWitness: true)] {
            for length in 0..<raw.count {
                let prefix = raw.prefix(length)
                #expect(throws: SparkError.self, "prefix of \(length) bytes") {
                    _ = try RawTransaction.parse(prefix)
                }
            }
        }
    }

    @Test("Trailing bytes, bad segwit flags and hostile counts are rejected")
    func structuralErrors() {
        #expect(throws: SparkError.self) { _ = try RawTransaction.parse(hex(genesisCoinbaseHex) + Data([0x00])) }
        #expect(throws: SparkError.self) { _ = try RawTransaction.parse(hex("02000000") + hex("0002") + hex("00000000")) }
        // input count 0xFFFFFFFF with nothing behind it
        #expect(throws: SparkError.self) { _ = try RawTransaction.parse(hex("02000000") + hex("feffffffff")) }
        // varbytes length far beyond the buffer
        #expect(throws: SparkError.self) {
            _ = try RawTransaction.parse(hex("02000000") + hex("01") + Data(repeating: 0, count: 36) + hex("fdffff") + hex("00"))
        }
        #expect(throws: SparkError.self) { _ = try RawTransaction.parse(Data()) }
    }

    @Test("Output lookup, input appends and witness attachment are bounds-checked")
    func helpers() throws {
        let tx = sampleWitnessTransaction()
        let bytes = tx.serialized(includeWitness: true)
        #expect(throws: SparkError.self) { _ = try tx.output(at: 2) }
        #expect(throws: SparkError.self) { _ = try SparkWallet.parseTxOutput(bytes, vout: 7) }

        let connector = RawTransaction.Input(previousTxid: Data(repeating: 0x55, count: 32), previousIndex: 3)
        let extended = try RawTransaction.parse(try SparkWallet.addInputToRawTx(bytes, input: connector))
        #expect(extended.inputs.count == 3)
        #expect(extended.inputs[2].previousTxid == Data(repeating: 0x55, count: 32))
        #expect(extended.inputs[2].previousIndex == 3)
        #expect(extended.inputs[2].sequence == 0xFFFF_FFFF)
        #expect(extended.inputs[2].witness.isEmpty)
        #expect(extended.inputs[0].witness == tx.inputs[0].witness)
        #expect(extended.outputs == tx.outputs)
        #expect(extended.hasWitnessSerialization)

        // Legacy serialisation stays legacy after an append.
        let legacyExtended = try RawTransaction.parse(try SparkWallet.addInputToRawTx(hex(genesisCoinbaseHex), input: connector))
        #expect(legacyExtended.inputs.count == 2)
        #expect(!legacyExtended.hasWitnessSerialization)

        let spend = try SparkWallet.constructSpendTx(
            depositTxId: genesisCoinbaseTxid, outputIndex: 0,
            destinationAddress: "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
            amountSats: 12_345, network: .mainnet
        )
        let parsedSpend = try RawTransaction.parse(spend)
        #expect(parsedSpend.version == 3)
        #expect(parsedSpend.inputs[0].previousTxid == Data(hex(genesisCoinbaseTxid).reversed()))
        #expect(parsedSpend.outputs[0].scriptPubKey == hex("512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"))
        #expect(parsedSpend.outputs[0].value == 12_345)
        let signed = try RawTransaction.parse(try SparkWallet.addWitnessToTx(spend, witness: Data(repeating: 0xCC, count: 64)))
        #expect(signed.inputs[0].witness == [Data(repeating: 0xCC, count: 64)])
        #expect(signed.txid == parsedSpend.txid)

        #expect(throws: SparkError.self) { _ = try SparkWallet.txidBytes(fromDisplayHex: "abc") }
        #expect(throws: SparkError.self) { _ = try SparkWallet.txidBytes(fromDisplayHex: String(repeating: "zz", count: 32)) }
        #expect(try SparkWallet.isZeroTimelockNode(hex(genesisCoinbaseHex)) == false)
    }

    @Test("Timelock helpers treat unparseable refund transactions as exhausted rather than crashing")
    func timelockHelpersOnGarbage() {
        #expect(SparkWallet.timelockCanDecrement(Data()) == false)
        #expect(SparkWallet.timelockCanDecrement(Data([1, 2, 3])) == false)
        #expect(throws: SparkError.self) { _ = try SparkWallet.computeNextSequences(from: Data([0xFF])) }
        var node = Spark_TreeNode()
        node.refundTx = Data([0x00, 0x01])
        let leaf = SparkLeaf(id: "x", treeID: "t", valueSats: 1, status: "AVAILABLE", node: node)
        #expect(leaf.refundTimelockBlocks == 0)
    }
}

// MARK: - Bech32 / Bech32m

@Suite("Bech32 and Bech32m")
struct Bech32Tests {

    @Test("BIP-173 valid vectors decode as bech32")
    func bip173Valid() throws {
        for s in [
            "A12UEL5L", "a12uel5l",
            "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
            "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w",
        ] {
            let (_, _, encoding) = try Bech32.decode(s, maxLength: 90)
            #expect(encoding == .bech32, "\(s)")
        }
    }

    @Test("BIP-350 valid vectors decode as bech32m")
    func bip350Valid() throws {
        for s in ["A1LQFN3A", "a1lqfn3a", "abcdef1l7aum6echk45nj3s0wdvt2fg8x9yrzpqzd3ryx", "?1v759aa"] {
            let (_, _, encoding) = try Bech32.decode(s, maxLength: 90)
            #expect(encoding == .bech32m, "\(s)")
        }
    }

    @Test("Malformed strings are rejected")
    func invalid() {
        for s in [
            "an84characterslonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1569pvx",
            "pzry9x8gf2tvdw0s3jn54khce6mua7l",   // no separator
            "1pzry9x8gf2tvdw0s3jn54khce6mua7l",  // empty hrp
            "x1b4n0q5v",                          // invalid data character
            "li1dgmt3",                           // too short checksum
            "A1G7SGD8",                           // checksum computed with uppercase hrp
            "10a06t8", "1qzzfhee",                // empty hrp
            "in1muywd", "mm1crxm3i", "au1s5cgom", "M1VUXWEZ", "16plkw9", "1p2gdwpf",
            "bc1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", // mixed case
            "",
        ] {
            #expect(throws: SparkError.self, "\(s)") { _ = try Bech32.decode(s, maxLength: 90) }
        }
    }

    @Test("Encoding round-trips for both checksum variants")
    func roundTrip() throws {
        let payload = [UInt8](repeating: 7, count: 20)
        for encoding in [Bech32.Encoding.bech32, .bech32m] {
            let encoded = Bech32.encode(hrp: "spark", data: payload, encoding: encoding)
            let (hrp, data, decodedEncoding) = try Bech32.decode(encoded, maxLength: nil)
            #expect(hrp == "spark")
            #expect(data == payload)
            #expect(decodedEncoding == encoding)
        }
        // Spark address helper still requires bech32m.
        let bech32Only = Bech32.encode(hrp: "spark", data: payload, encoding: .bech32)
        #expect(throws: SparkError.self) { _ = try Bech32m.decodeBech32m(bech32Only) }
    }
}

// MARK: - Bitcoin addresses

@Suite("Bitcoin address decoding")
struct BitcoinAddressTests {

    private let p2wpkhScript = "0014751e76e8199196d454941c45d1b3a323f1433bd6"

    @Test("Segwit addresses decode to the right script and kind")
    func segwit() throws {
        let vectors: [(String, BitcoinAddress.Kind, String)] = [
            ("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", .p2wpkh, p2wpkhScript),
            ("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", .p2wpkh, p2wpkhScript),
            ("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3", .p2wsh,
             "00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262"),
            ("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", .p2tr,
             "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
        ]
        for (address, kind, script) in vectors {
            let decoded = try BitcoinAddress.decode(address, network: .mainnet)
            #expect(decoded.kind == kind, Comment(rawValue: address))
            #expect(decoded.scriptPubKey == hex(script), Comment(rawValue: address))
            #expect(try BitcoinAddress.scriptPubKey(for: address, network: .mainnet) == hex(script))
        }
        // BOLT-11 P2TR fallback example: program is the decoded 5-bit words after the version.
        let program = Bech32.fromWords(Array(try Bech32.decode("bc1pptdvg0d2nj99568qn6ssdy4cygnwuxgw2ukmnwgwz7jpqjz2kszse2s3lm", maxLength: 90).data.dropFirst()))!
        let decoded = try BitcoinAddress.decode("bc1pptdvg0d2nj99568qn6ssdy4cygnwuxgw2ukmnwgwz7jpqjz2kszse2s3lm", network: .mainnet)
        #expect(decoded.scriptPubKey == hex("5120") + program)
        #expect(program.count == 32)
    }

    @Test("Legacy Base58Check addresses decode for both networks")
    func base58() throws {
        let hash160 = hex("751e76e8199196d454941c45d1b3a323f1433bd6")
        let p2pkh = hex("76a914") + hash160 + hex("88ac")
        let p2sh = hex("a914") + hash160 + hex("87")
        #expect(try BitcoinAddress.decode("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", network: .mainnet) == .init(kind: .p2pkh, scriptPubKey: p2pkh))
        #expect(try BitcoinAddress.decode("3CNHUhP3uyB9EUtRLsmvFUmvGdjGdkTxJw", network: .mainnet) == .init(kind: .p2sh, scriptPubKey: p2sh))
        #expect(try BitcoinAddress.decode("mrCDrCybB6J1vRfbwM5hemdJz73FwDBC8r", network: .regtest) == .init(kind: .p2pkh, scriptPubKey: p2pkh))
        #expect(try BitcoinAddress.decode("2N3vVYSK5XRgVSGWy21PnsRmBUywSQNdCsf", network: .regtest) == .init(kind: .p2sh, scriptPubKey: p2sh))

        // BOLT-11 fallback-address examples, cross-checked against the 5-bit words in the spec.
        let rustyHash = Bech32.fromWords(words("qjmp7lwpagxun9pygexvgpjdc4jdj85f"))!
        #expect(try BitcoinAddress.decode("1RustyRX2oai4EYYDpQGWvEL62BBGqN9T", network: .mainnet).scriptPubKey == hex("76a914") + rustyHash + hex("88ac"))
        let p2shHash = Bech32.fromWords(words("3a24vwu6r8ejrss3axul8rxldph2q7z9"))!
        #expect(try BitcoinAddress.decode("3EktnHQD7RiAE6uzMj2ZifT9YgRrkSgzQX", network: .mainnet).scriptPubKey == hex("a914") + p2shHash + hex("87"))
    }

    @Test("Wrong network, bad checksums, wrong witness rules and exotic versions are refused")
    func rejected() {
        let cases: [(String, SparkNetwork)] = [
            ("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", .regtest),   // mainnet address on regtest
            ("mrCDrCybB6J1vRfbwM5hemdJz73FwDBC8r", .mainnet),           // regtest legacy on mainnet
            ("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", .regtest),
            ("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", .mainnet),   // testnet
            ("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", .regtest),
            ("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5", .mainnet),   // bad checksum
            ("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMJ", .mainnet),           // bad base58 checksum
            ("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh", .mainnet),   // v0 with bech32m checksum
            ("BC1QR508D6QEJXTDG4Y5R3ZARVARYV98GJ9P", .mainnet),         // v0 with 16-byte program
            ("bc1pw5dgrnzv", .mainnet),                                 // v1 with 1-byte program
            ("bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs", .mainnet),         // v2: valid bech32m, unsupported here
            ("bc1gmk9yu", .mainnet),                                    // empty data
            ("bc1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", .mainnet),   // mixed case
            ("", .mainnet),
            ("not an address", .mainnet),
        ]
        for (address, network) in cases {
            #expect(throws: SparkError.self, "\(address) on \(network)") {
                _ = try BitcoinAddress.decode(address, network: network)
            }
        }
    }

    @Test("P2TR encoding round-trips on both networks")
    func p2trRoundTrip() throws {
        let program = hex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        let mainnet = try BitcoinAddress.encodeP2TR(program: program, network: .mainnet)
        #expect(mainnet == "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")
        let regtest = try BitcoinAddress.encodeP2TR(program: program, network: .regtest)
        #expect(regtest.hasPrefix("bcrt1p"))
        #expect(try BitcoinAddress.decode(regtest, network: .regtest).scriptPubKey == hex("5120") + program)
        #expect(throws: SparkError.self) { _ = try BitcoinAddress.decode(regtest, network: .mainnet) }
        #expect(try BitcoinAddress.p2trAddress(scriptPubKey: hex("5120") + program, network: .mainnet) == mainnet)
        #expect(throws: SparkError.self) { _ = try BitcoinAddress.p2trAddress(scriptPubKey: hex("0014") + Data(repeating: 1, count: 20), network: .mainnet) }
    }
}
