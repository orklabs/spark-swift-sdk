import Foundation
import Testing
@testable import SparkSDK

@Test func testKeyDerivation() async throws {
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    // Explicit account=0 to match original TypeScript SDK test vectors
    let keys = try KeyDerivation(mnemonic: mnemonic, account: 0)

    #expect(keys.identityPublicKey.count == 33)
    #expect(keys.depositPublicKey.count == 33)

    let keys2 = try KeyDerivation(mnemonic: mnemonic, account: 0)
    #expect(keys.identityPublicKey == keys2.identityPublicKey)
    #expect(keys.depositPublicKey == keys2.depositPublicKey)

    // Cross-check against TypeScript SDK reference vectors (from @scure/bip32, account=0)
    #expect(keys.identityPublicKey.hexString == "02698b27ac308b275671b3ca25436346469d04a5bba578ae39feba1d65897a6abc")
    #expect(keys.depositPublicKey.hexString == "02f4f6db6cf8f0ab8c9c95659b78448d09ebf490c4251349c6ebef7caf9ad6e10a")
}

@Test func testSparkSigner() async throws {
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    let signer = try SparkSigner(mnemonic: mnemonic)

    #expect(signer.identityPublicKey.count == 33)
    #expect(signer.depositPublicKey.count == 33)
    #expect(!signer.identityPublicKey.hexString.isEmpty)
}

// MARK: - BIP39 Mnemonic-to-Seed Test Vectors

@Test("Mnemonic to seed — official BIP39 vector (TREZOR passphrase)")
func mnemonicToSeedTrezorPassphrase() throws {
    // Official BIP39 test vector from trezor/python-mnemonic vectors.json
    // PBKDF2-SHA512, 2048 iterations, salt = "mnemonicTREZOR"
    let seed = try KeyDerivation.mnemonicToSeed(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        passphrase: "TREZOR"
    )
    #expect(seed.hexString == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
}

@Test("Mnemonic to seed — empty passphrase (what Spark uses)")
func mnemonicToSeedEmptyPassphrase() throws {
    // Well-known vector verified across multiple BIP39 implementations
    // PBKDF2-SHA512, 2048 iterations, salt = "mnemonic"
    let seed = try KeyDerivation.mnemonicToSeed(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        passphrase: ""
    )
    #expect(seed.hexString == "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4")
}

@Test("Different passphrases produce different seeds")
func passphraseChangesSeed() throws {
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    let seedEmpty = try KeyDerivation.mnemonicToSeed(mnemonic, passphrase: "")
    let seedTrezor = try KeyDerivation.mnemonicToSeed(mnemonic, passphrase: "TREZOR")
    #expect(seedEmpty != seedTrezor)
}

@Test("Seed is deterministic")
func seedDeterministic() throws {
    let mnemonic = "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"
    let seed1 = try KeyDerivation.mnemonicToSeed(mnemonic, passphrase: "")
    let seed2 = try KeyDerivation.mnemonicToSeed(mnemonic, passphrase: "")
    #expect(seed1 == seed2)
    #expect(seed1.count == 64) // 512 bits
}

@Test func testHexConversion() async throws {
    let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
    #expect(data.hexString == "deadbeef")

    let roundtrip = Data(hexString: "deadbeef")
    #expect(roundtrip == data)
}

@Test("Tagged hash matches an independent implementation of the reference SDK's hashstructure")
func testTaggedHash() async throws {
    // Vector computed with a separate Python implementation of the TS SDK's Hasher:
    // tagHash = sha256(concat(8-byte BE len + component)); sha256(tagHash || tagHash || values),
    // each value 8-byte BE length-prefixed, maps as (count as uint64, then sorted key/value pairs).
    var hasher = SparkHasher(tag: ["spark", "transfer", "signing payload"])
    hasher.addBytes(Data(hexString: "deadbeef")!)
    hasher.addMapStringToBytes(["op2": Data(hexString: "babe")!, "op1": Data(hexString: "cafe")!])
    let result = hasher.hash()
    #expect(result.hexString == "079a10347594aef138bac8153d261ba95406af52148d8368f8b81bd2f3f28c49")
}

@Test("Mainnet defaults to account 1, matching TypeScript SDK")
func mainnetDefaultAccount() throws {
    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    // Account 0 (explicit)
    let keys0 = try KeyDerivation(mnemonic: mnemonic, account: 0)
    // Account 1 (mainnet default via SparkWallet)
    let wallet = try SparkWallet(mnemonic: mnemonic)
    // They must differ — mainnet defaults to account 1
    #expect(keys0.identityPublicKey.hexString != wallet.identityPublicKeyHex)

    // Account 1 explicit must match mainnet default
    let keys1 = try KeyDerivation(mnemonic: mnemonic, account: 1)
    #expect(keys1.identityPublicKey.hexString == wallet.identityPublicKeyHex)
}
