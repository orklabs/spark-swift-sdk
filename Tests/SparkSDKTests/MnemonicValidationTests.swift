// swiftlint:disable line_length — specification test vectors are long single tokens
import Foundation
import Testing
@testable import SparkSDK

@Suite("BIP-39 mnemonic validation")
struct MnemonicValidationTests {

    static let vector12a = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let vector12b = "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"
    static let vector18 = "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal will"
    static let vector24a = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
    static let vector24b = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"

    @Test("Official test vectors validate")
    func validVectors() throws {
        for m in [Self.vector12a, Self.vector12b, Self.vector18, Self.vector24a, Self.vector24b] {
            try BIP39.validate(m)
            #expect(BIP39.isValid(m))
        }
        #expect(BIP39Wordlist.english.count == 2048)
        #expect(BIP39Wordlist.english.first == "abandon")
        #expect(BIP39Wordlist.english.last == "zoo")
    }

    @Test("Typos, unknown words, wrong counts, case and spacing are rejected")
    func invalid() {
        let cases: [(String, String)] = [
            ("checksum: last word swapped", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"),
            ("checksum: one word changed", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnics"),
            ("checksum: two words swapped", "drill ozone grab fiber curtain grace pudding thank cruise elder eight picnic"),
            ("unknown word", "ozone drill grab fibre curtain grace pudding thank cruise elder eight picnic"),
            ("eleven words", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"),
            ("thirteen words", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about abandon"),
            ("upper case", "Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"),
            ("double space", "abandon  abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"),
            ("trailing space", Self.vector12a + " "),
            ("empty", ""),
            ("hex seed", String(repeating: "ab", count: 32)),
        ]
        for (label, mnemonic) in cases {
            #expect(!BIP39.isValid(mnemonic), Comment(rawValue: label))
            #expect(throws: SparkError.self, Comment(rawValue: label)) { try BIP39.validate(mnemonic) }
        }
    }

    @Test("Wallet and signer refuse an invalid mnemonic unless validation is explicitly disabled")
    func walletIntegration() throws {
        let typo = "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnics"
        #expect(throws: SparkError.self) { _ = try SparkWallet(mnemonic: typo) }
        #expect(throws: SparkError.self) { _ = try SparkSigner(mnemonic: typo) }
        #expect(throws: SparkError.self) { _ = try KeyDerivation(mnemonic: typo) }
        // Escape hatch keeps the previous behaviour for phrases known to be non-standard.
        let lenient = try SparkWallet(mnemonic: typo, validateMnemonic: false)
        #expect(lenient.identityPublicKeyHex.count == 66)
        // Valid phrases still derive the same keys as before.
        let wallet = try SparkWallet(mnemonic: Self.vector12b)
        let keys = try KeyDerivation(mnemonic: Self.vector12b, account: 1)
        #expect(wallet.identityPublicKeyHex == keys.identityPublicKey.hexString)
    }

    @Test("Account indexes outside the hardened range are refused instead of trapping")
    func accountRange() {
        #expect(throws: SparkError.self) { _ = try KeyDerivation(mnemonic: Self.vector12a, account: -1) }
        #expect(throws: SparkError.self) { _ = try KeyDerivation(mnemonic: Self.vector12a, account: 1 << 31) }
        #expect(throws: SparkError.self) { _ = try SparkWallet(mnemonic: Self.vector12a, account: -7) }
        #expect((try? KeyDerivation(mnemonic: Self.vector12a, account: (1 << 31) - 1)) != nil)
    }
}
