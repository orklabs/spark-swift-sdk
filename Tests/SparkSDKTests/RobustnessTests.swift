import Foundation
import Testing
@testable import SparkSDK

/// Replaces the force-unwraps and unchecked indexing that let server data crash the app.
@Suite("Operator reconciliation and input validation")
struct RobustnessTests {

    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let keysA = try! KeyDerivation(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", account: 0)
    private let keysB = try! KeyDerivation(mnemonic: "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic", account: 0)
    private let keysC = try! KeyDerivation(mnemonic: "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote", account: 0)

    private var config: [SigningOperatorConfig] {
        [
            SigningOperatorConfig(address: "https://a", identifier: "op1", identityPublicKeyHex: keysA.identityPublicKey.hexString),
            SigningOperatorConfig(address: "https://b", identifier: "op2", identityPublicKeyHex: keysB.identityPublicKey.hexString),
            SigningOperatorConfig(address: "https://c", identifier: "op3", identityPublicKeyHex: keysC.identityPublicKey.hexString),
        ]
    }

    private func server(_ entries: [(String, UInt64)]) -> [String: Spark_SigningOperatorInfo] {
        var map: [String: Spark_SigningOperatorInfo] = [:]
        for (id, index) in entries {
            var info = Spark_SigningOperatorInfo()
            info.identifier = id
            info.index = index
            info.publicKey = Data(repeating: 0xEE, count: 33)   // never used: keys come from config
            map[id] = info
        }
        return map
    }

    @Test("The coordinator's operator list is reconciled with the configuration")
    func operatorMatching() throws {
        let targets = try KeyTweakHelper.matchOperators(server: server([("op2", 1), ("op3", 2), ("op1", 0)]), config: config)
        #expect(targets.map(\.soID) == ["op1", "op2", "op3"])
        #expect(targets.map(\.shareIndex) == [1, 2, 3])
        #expect(targets[0].identityPublicKey == keysA.identityPublicKey)
        #expect(targets[2].identityPublicKey == keysC.identityPublicKey)

        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: [:], config: config) }
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1)]), config: config) }
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1), ("evil", 2)]), config: config) }
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1), ("op3", 7)]), config: config) }
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 0), ("op3", 2)]), config: config) }
        var noKey = config
        noKey[1] = SigningOperatorConfig(address: "https://b", identifier: "op2", identityPublicKeyHex: "")
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1), ("op3", 2)]), config: noKey) }
    }

    @Test("Secret shares map to operators by index and a missing share is an error, not a crash")
    func shareMapping() throws {
        let targets = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1), ("op3", 2)]), config: config)
        let secret = try randomSecretKeyBytes()
        let shares = try splitSecretWithProofsUniffi(secret: secret, threshold: 2, numShares: 3)
        let mapped = try KeyTweakHelper.shares(shares, for: targets)
        #expect(mapped.count == 3)
        #expect(mapped["op1"]?.index == 1)
        #expect(mapped["op3"]?.index == 3)
        #expect(throws: SparkError.self) { _ = try KeyTweakHelper.shares(Array(shares.dropLast()), for: targets) }
    }

    @Test("Key tweak packages are encrypted to configured keys and reject bad transfer ids")
    func encryptAndSign() throws {
        let targets = try KeyTweakHelper.matchOperators(server: server([("op1", 0), ("op2", 1), ("op3", 2)]), config: config)
        let signer = try SparkSigner(mnemonic: Self.mnemonic)
        let tweaks = Dictionary(uniqueKeysWithValues: targets.map { ($0.soID, Spark_SendLeafKeyTweaks()) })
        let package = try KeyTweakHelper.encryptAndSign(
            transferID: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", perSoTweaks: tweaks, targets: targets, signer: signer, tag: "transfer"
        )
        #expect(Set(package.keyTweakPackage.keys) == ["op1", "op2", "op3"])
        #expect(!package.signature.isEmpty)
        // Only the configured operator can decrypt its entry.
        let decrypted = try decryptEcies(encryptedMsg: package.keyTweakPackage["op2"]!, privateKey: keysB.identityPrivateKey)
        #expect(decrypted == (try Spark_SendLeafKeyTweaks().serializedData()))
        #expect(throws: (any Swift.Error).self) {
            _ = try decryptEcies(encryptedMsg: package.keyTweakPackage["op2"]!, privateKey: keysA.identityPrivateKey)
        }

        #expect(throws: SparkError.self) {
            _ = try KeyTweakHelper.encryptAndSign(transferID: "not-a-uuid", perSoTweaks: tweaks, targets: targets, signer: signer, tag: "transfer")
        }
        var missing = tweaks
        missing["op3"] = nil
        #expect(throws: SparkError.self) {
            _ = try KeyTweakHelper.encryptAndSign(transferID: "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", perSoTweaks: missing, targets: targets, signer: signer, tag: "transfer")
        }
    }

    @Test("Spark addresses round-trip and are tied to a network")
    func sparkAddresses() throws {
        let key = keysA.identityPublicKey
        let mainnet = SparkAddress.encode(identityPublicKey: key, network: .mainnet)
        let regtest = SparkAddress.encode(identityPublicKey: key, network: .regtest)
        #expect(mainnet.hasPrefix("spark1"))
        #expect(regtest.hasPrefix("sparkrt1"))
        #expect(try SparkAddress.decode(mainnet, network: .mainnet) == key)
        #expect(try SparkAddress.decode(regtest, network: .regtest) == key)
        #expect(try SparkAddress.decode(mainnet.uppercased(), network: .mainnet) == key)
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(mainnet, network: .regtest) }
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(regtest, network: .mainnet) }

        // Legacy prefixes are still accepted.
        let payload = Data([0x0a, 33]) + key
        let legacy = Bech32m.encode(hrp: "sp", data: Bech32m.toWords(payload))
        #expect(try SparkAddress.decode(legacy, network: .mainnet) == key)

        // Wrong checksum variant, wrong payload, garbage.
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(Bech32.encode(hrp: "spark", data: Bech32m.toWords(payload), encoding: .bech32), network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(Bech32m.encode(hrp: "spark", data: Bech32m.toWords(Data([0x0a, 32]) + key.prefix(32))), network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(Bech32m.encode(hrp: "spark", data: Bech32m.toWords(Data([0x0a, 33, 0x04]) + key.dropFirst())), network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode("spark1garbage", network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode("", network: .mainnet) }

        let wallet = try SparkWallet(mnemonic: Self.mnemonic)
        #expect(try SparkAddress.decode(wallet.getSparkAddress(), network: .mainnet).hexString == wallet.identityPublicKeyHex)
    }

    @Test("Deposit claims target the output that pays one of the wallet's deposit addresses")
    func depositMatching() throws {
        let depositAddress = "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0"
        let depositScript = Data(hexString: "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
        let otherAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let tx = RawTransaction(
            version: 2,
            inputs: [RawTransaction.Input(previousTxid: Data(repeating: 1, count: 32), previousIndex: 0)],
            outputs: [
                RawTransaction.Output(value: 1_000, scriptPubKey: Data(hexString: "0014")! + Data(repeating: 0x55, count: 20)),
                RawTransaction.Output(value: 50_000, scriptPubKey: depositScript),
            ],
            locktime: 0, hasWitnessSerialization: true
        ).serialized(includeWitness: true)

        let match = try DepositMatcher.match(rawTx: tx, candidateAddresses: [otherAddress, depositAddress, "not-an-address"], requestedVout: nil, network: .mainnet)
        #expect(match == DepositMatcher.Match(vout: 1, address: depositAddress))
        #expect(try DepositMatcher.match(rawTx: tx, candidateAddresses: [depositAddress], requestedVout: 1, network: .mainnet).vout == 1)
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: tx, candidateAddresses: [depositAddress], requestedVout: 0, network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: tx, candidateAddresses: [depositAddress], requestedVout: 5, network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: tx, candidateAddresses: [otherAddress], requestedVout: nil, network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: tx, candidateAddresses: [], requestedVout: nil, network: .mainnet) }
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: tx, candidateAddresses: [depositAddress], requestedVout: nil, network: .regtest) }
        #expect(throws: SparkError.self) { _ = try DepositMatcher.match(rawTx: Data([1, 2, 3]), candidateAddresses: [depositAddress], requestedVout: nil, network: .mainnet) }
    }

    @Test("Spark transfers validate the amount and receiver key before touching any leaf")
    func sendArguments() throws {
        let key = keysB.identityPublicKey
        try SparkWallet.validateSendArguments(receiverIdentityPublicKey: key, amountSats: 1)
        #expect(throws: SparkError.self) { try SparkWallet.validateSendArguments(receiverIdentityPublicKey: key, amountSats: 0) }
        #expect(throws: SparkError.self) { try SparkWallet.validateSendArguments(receiverIdentityPublicKey: key, amountSats: -10) }
        #expect(throws: SparkError.self) { try SparkWallet.validateSendArguments(receiverIdentityPublicKey: key.prefix(32), amountSats: 1) }
        #expect(throws: SparkError.self) { try SparkWallet.validateSendArguments(receiverIdentityPublicKey: Data([0x04]) + key.dropFirst(), amountSats: 1) }
        #expect(throws: SparkError.self) { try SparkWallet.validateSendArguments(receiverIdentityPublicKey: Data(), amountSats: 1) }
    }

    @Test("Exporting the account key throws for custom signers instead of crashing")
    func exportAccountKey() throws {
        let wallet = try SparkWallet(mnemonic: Self.mnemonic)
        let exported = try wallet.exportAccountKey()
        #expect(exported.count == 64)
        let restored = try SparkWallet(accountKey: exported)
        #expect(restored.identityPublicKeyHex == wallet.identityPublicKeyHex)

        struct ForwardingSigner: SparkSignerProtocol {
            let inner: SparkSigner
            var identityPublicKey: Data { inner.identityPublicKey }
            var depositPublicKey: Data { inner.depositPublicKey }
            func signWithIdentityKey(_ messageHash: Data) throws -> Data { try inner.signWithIdentityKey(messageHash) }
            func signCompactWithIdentityKey(_ messageHash: Data) throws -> Data { try inner.signCompactWithIdentityKey(messageHash) }
            func deriveIdentityPrivateKey() throws -> Data { try inner.deriveIdentityPrivateKey() }
            func deriveLeafSigningKey(_ leafID: String) throws -> Data { try inner.deriveLeafSigningKey(leafID) }
            func deriveLeafSigningKeyPair(_ leafID: String) throws -> (privateKey: Data, publicKey: Data) { try inner.deriveLeafSigningKeyPair(leafID) }
            func deriveStaticDepositKey(_ index: Int) throws -> Data { try inner.deriveStaticDepositKey(index) }
            func generatePreimage(_ transferID: String) throws -> Data { try inner.generatePreimage(transferID) }
        }
        let custom = SparkWallet(signer: ForwardingSigner(inner: try SparkSigner(mnemonic: Self.mnemonic)))
        #expect(throws: SparkError.self) { _ = try custom.exportAccountKey() }
    }
}
