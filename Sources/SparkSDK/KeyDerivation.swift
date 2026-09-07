import Foundation
import CryptoKit
import secp256k1
import CommonCrypto

struct DerivedKey: Sendable {
    let privateKeyData: Data
    let publicKeyData: Data
}

final class KeyDerivation: @unchecked Sendable {
    static let sparkPurpose: UInt32 = 8797555
    private static let hardenedOffset: UInt32 = 0x80000000

    let identityPrivateKey: Data
    let identityPublicKey: Data
    let depositPublicKey: Data

    private let signingKey: Data
    private let signingChainCode: Data
    private let depositKey: Data
    private let staticDepositKey: Data
    private let staticDepositChainCode: Data
    private let htlcPreimageKey: Data

    /// The account-level key material, used for export/import.
    let accountKeyData: Data
    let accountChainCodeData: Data

    /// - Parameter validateMnemonic: Check the phrase against the BIP-39 English wordlist and
    ///   checksum first (throws `SparkError.invalidMnemonic`). Pass `false` only to load a
    ///   phrase that is known to be non-standard.
    convenience init(mnemonic: String, account: Int = 0, passphrase: String? = nil, validateMnemonic: Bool = true) throws {
        if validateMnemonic {
            try BIP39.validate(mnemonic)
        }
        guard account >= 0, account < Int(Self.hardenedOffset) else {
            throw SparkError.invalidArgument("account index must be between 0 and 2^31-1, got \(account)")
        }
        let seed = try Self.mnemonicToSeed(mnemonic, passphrase: passphrase ?? "")
        let master = try Self.hmacSHA512(key: Data("Bitcoin seed".utf8), data: seed)

        let masterKey = Data(master[master.startIndex..<master.startIndex + 32])
        let masterChainCode = Data(master[master.startIndex + 32..<master.startIndex + 64])

        // m/8797555'
        let purposeKey = try Self.deriveHardened(key: masterKey, chainCode: masterChainCode, index: Self.sparkPurpose)
        // m/8797555'/{account}'
        let accountKey = try Self.deriveHardened(key: purposeKey.key, chainCode: purposeKey.chainCode, index: UInt32(account))

        try self.init(accountKey: accountKey.key, accountChainCode: accountKey.chainCode)
    }

    /// Initialize from pre-derived account key material (skips mnemonic → seed derivation).
    init(accountKey: Data, accountChainCode: Data) throws {
        self.accountKeyData = accountKey
        self.accountChainCodeData = accountChainCode

        let identity = try Self.deriveHardened(key: accountKey, chainCode: accountChainCode, index: 0)
        let signing = try Self.deriveHardened(key: accountKey, chainCode: accountChainCode, index: 1)
        let deposit = try Self.deriveHardened(key: accountKey, chainCode: accountChainCode, index: 2)
        let staticDeposit = try Self.deriveHardened(key: accountKey, chainCode: accountChainCode, index: 3)
        let htlcPreimage = try Self.deriveHardened(key: accountKey, chainCode: accountChainCode, index: 4)

        self.identityPrivateKey = identity.key
        self.identityPublicKey = try Self.compressedPublicKey(from: identity.key)
        self.depositPublicKey = try Self.compressedPublicKey(from: deposit.key)
        self.signingKey = signing.key
        self.signingChainCode = signing.chainCode
        self.depositKey = deposit.key
        self.staticDepositKey = staticDeposit.key
        self.staticDepositChainCode = staticDeposit.chainCode
        self.htlcPreimageKey = htlcPreimage.key
    }

    func deriveLeafKey(_ leafID: String) throws -> DerivedKey {
        let hash = CryptoKit.SHA256.hash(data: Data(leafID.utf8))
        let hashBytes = Array(hash)
        let index = (UInt32(hashBytes[0]) << 24) | (UInt32(hashBytes[1]) << 16) | (UInt32(hashBytes[2]) << 8) | UInt32(hashBytes[3])
        let childIndex = index % Self.hardenedOffset

        let result = try Self.deriveHardened(key: signingKey, chainCode: signingChainCode, index: childIndex)
        return DerivedKey(
            privateKeyData: result.key,
            publicKeyData: try Self.compressedPublicKey(from: result.key)
        )
    }

    func deriveStaticDepositChildKey(_ index: Int) throws -> DerivedKey {
        let result = try Self.deriveHardened(key: staticDepositKey, chainCode: staticDepositChainCode, index: UInt32(index))
        return DerivedKey(
            privateKeyData: result.key,
            publicKeyData: try Self.compressedPublicKey(from: result.key)
        )
    }

    func computePreimage(transferID: String) -> Data {
        let key = SymmetricKey(data: htlcPreimageKey)
        let data = Data(transferID.utf8)
        let hmac = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: data, using: key)
        return Data(hmac)
    }

    func signECDSA(messageHash: Data, with privateKey: Data) throws -> Data {
        let key = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
        // Use HashDigest (secp256k1's Digest type) to avoid the DataProtocol overload
        // which would SHA256 hash the data again
        let digest = HashDigest(Array(messageHash))
        let sig = try key.signature(for: digest)
        return try sig.derRepresentation
    }

    func signCompactECDSA(messageHash: Data, with privateKey: Data) throws -> Data {
        let key = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
        let digest = HashDigest(Array(messageHash))
        let sig = try key.signature(for: digest)
        return try sig.compactRepresentation
    }

    // MARK: - BIP32

    private struct ExtendedKey {
        let key: Data
        let chainCode: Data
    }

    private static func deriveHardened(key: Data, chainCode: Data, index: UInt32) throws -> ExtendedKey {
        var data = Data([0x00])
        data.append(key)
        let hardenedIndex = index | hardenedOffset
        withUnsafeBytes(of: hardenedIndex.bigEndian) { data.append(contentsOf: $0) }

        let derived = try hmacSHA512(key: chainCode, data: data)
        let il = Data(derived[derived.startIndex..<derived.startIndex + 32])
        let ir = Data(derived[derived.startIndex + 32..<derived.startIndex + 64])

        // BIP32: childKey = (IL + parentKey) mod n
        let childKey = try addPrivateKeys(il, key)
        return ExtendedKey(key: childKey, chainCode: ir)
    }

    private static func addPrivateKeys(_ a: Data, _ b: Data) throws -> Data {
        // secp256k1 curve order
        let n: [UInt64] = [
            0xBFD25E8CD0364141,
            0xBAAEDCE6AF48A03B,
            0xFFFFFFFFFFFFFFFE,
            0xFFFFFFFFFFFFFFFF,
        ]

        func bytesToU64BE(_ data: Data, offset: Int) -> UInt64 {
            var val: UInt64 = 0
            for i in 0..<8 {
                val = (val << 8) | UInt64(data[data.startIndex + offset + i])
            }
            return val
        }

        // Parse a and b as 256-bit big-endian numbers, add mod n
        var aLimbs: [UInt64] = [0, 0, 0, 0]
        var bLimbs: [UInt64] = [0, 0, 0, 0]
        for i in 0..<4 {
            aLimbs[3 - i] = bytesToU64BE(a, offset: i * 8)
            bLimbs[3 - i] = bytesToU64BE(b, offset: i * 8)
        }

        // Add with carry
        var result: [UInt64] = [0, 0, 0, 0]
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, c1) = aLimbs[i].addingReportingOverflow(bLimbs[i])
            let (s2, c2) = s1.addingReportingOverflow(carry)
            result[i] = s2
            carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
        }

        // Reduce mod n: if result >= n, subtract n
        var needsReduce = carry > 0
        if !needsReduce {
            for i in (0..<4).reversed() {
                if result[i] > n[i] { needsReduce = true; break }
                if result[i] < n[i] { break }
            }
        }

        if needsReduce {
            var borrow: UInt64 = 0
            for i in 0..<4 {
                let (d1, b1) = result[i].subtractingReportingOverflow(n[i])
                let (d2, b2) = d1.subtractingReportingOverflow(borrow)
                result[i] = d2
                borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
            }
        }

        // Check result is not zero (invalid key per BIP32)
        let isZero = result.allSatisfy { $0 == 0 }
        if isZero {
            throw SparkError.keyDerivationFailed
        }

        // Serialize back to 32-byte big-endian
        var output = Data(count: 32)
        for i in 0..<4 {
            let val = result[3 - i]
            for j in 0..<8 {
                output[i * 8 + j] = UInt8((val >> (56 - j * 8)) & 0xFF)
            }
        }
        return output
    }

    private static func hmacSHA512(key: Data, data: Data) throws -> Data {
        let hmacKey = SymmetricKey(data: key)
        let hmac = CryptoKit.HMAC<CryptoKit.SHA512>.authenticationCode(for: data, using: hmacKey)
        return Data(hmac)
    }

    static func compressedPublicKey(from privateKey: Data) throws -> Data {
        let key = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
        return Data(key.publicKey.dataRepresentation)
    }

    // MARK: - BIP39

    static func mnemonicToSeed(_ mnemonic: String, passphrase: String) throws -> Data {
        let password = mnemonic.decomposedStringWithCompatibilityMapping
        let salt = ("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping

        return try pbkdf2SHA512(
            password: Data(password.utf8),
            salt: Data(salt.utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    private static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var derivedKey = Data(count: keyLength)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw SparkError.keyDerivationFailed
        }
        return derivedKey
    }
}
