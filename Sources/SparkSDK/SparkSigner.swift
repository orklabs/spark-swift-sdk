import Foundation
import secp256k1

public protocol SparkSignerProtocol: Sendable {
    var identityPublicKey: Data { get }
    var depositPublicKey: Data { get }
    func signWithIdentityKey(_ messageHash: Data) throws -> Data
    func signCompactWithIdentityKey(_ messageHash: Data) throws -> Data
    func deriveIdentityPrivateKey() throws -> Data
    func deriveLeafSigningKey(_ leafID: String) throws -> Data
    func deriveLeafSigningKeyPair(_ leafID: String) throws -> (privateKey: Data, publicKey: Data)
    func deriveStaticDepositKey(_ index: Int) throws -> Data
    func generatePreimage(_ transferID: String) throws -> Data
}

public final class SparkSigner: SparkSignerProtocol, @unchecked Sendable {
    private let keys: KeyDerivation

    /// - Parameter validateMnemonic: Reject phrases that fail BIP-39 wordlist or checksum
    ///   validation (`SparkError.invalidMnemonic`). Defaults to `true`.
    public init(mnemonic: String, account: Int = 0, passphrase: String? = nil, validateMnemonic: Bool = true) throws {
        self.keys = try KeyDerivation(mnemonic: mnemonic, account: account, passphrase: passphrase, validateMnemonic: validateMnemonic)
    }

    /// Initialize from pre-derived account key material (skips mnemonic → seed derivation).
    public init(accountKey: Data, accountChainCode: Data) throws {
        self.keys = try KeyDerivation(accountKey: accountKey, accountChainCode: accountChainCode)
    }

    /// Export account-level key material for caching.
    /// Returns 64 bytes: 32-byte key + 32-byte chain code.
    public func exportAccountKey() -> Data {
        keys.accountKeyData + keys.accountChainCodeData
    }

    public var identityPublicKey: Data {
        keys.identityPublicKey
    }

    public var depositPublicKey: Data {
        keys.depositPublicKey
    }

    public func signWithIdentityKey(_ messageHash: Data) throws -> Data {
        try keys.signECDSA(messageHash: messageHash, with: keys.identityPrivateKey)
    }

    public func signCompactWithIdentityKey(_ messageHash: Data) throws -> Data {
        try keys.signCompactECDSA(messageHash: messageHash, with: keys.identityPrivateKey)
    }

    public func deriveIdentityPrivateKey() throws -> Data {
        keys.identityPrivateKey
    }

    public func deriveLeafSigningKey(_ leafID: String) throws -> Data {
        try keys.deriveLeafKey(leafID).privateKeyData
    }

    public func deriveLeafSigningKeyPair(_ leafID: String) throws -> (privateKey: Data, publicKey: Data) {
        let key = try keys.deriveLeafKey(leafID)
        return (key.privateKeyData, key.publicKeyData)
    }

    public func deriveStaticDepositKey(_ index: Int) throws -> Data {
        try keys.deriveStaticDepositChildKey(index).privateKeyData
    }

    public func generatePreimage(_ transferID: String) throws -> Data {
        keys.computePreimage(transferID: transferID)
    }
}
