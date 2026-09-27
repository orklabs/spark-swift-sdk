import Foundation
import CryptoKit
import Testing
import secp256k1
@testable import SparkSDK

/// A deposit address as the operators produce it (`deposit_handler.go`), with keys the test
/// controls: the verifying key is the wallet's signing key plus the operators' share, the address
/// pays it, the proof of possession is the operators' share (BIP-86 tweaked) signing the tagged
/// hash of identity key, operator key and address, and every operator signs sha256(address).
private struct SyntheticDeposit {
    let userSigningPublicKey: Data
    let identityPublicKey: Data
    let operatorShare: secp256k1.Signing.PrivateKey
    let operators: [(config: SigningOperatorConfig, key: secp256k1.Signing.PrivateKey)]

    init() throws {
        userSigningPublicKey = try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation
        identityPublicKey = try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation
        operatorShare = try secp256k1.Signing.PrivateKey()
        operators = try (1...3).map { index in
            let key = try secp256k1.Signing.PrivateKey()
            let config = SigningOperatorConfig(
                address: "https://\(index).example",
                identifier: String(repeating: "0", count: 63) + "\(index)",
                identityPublicKeyHex: key.publicKey.dataRepresentation.hexString
            )
            return (config, key)
        }
    }

    var operatorConfigs: [SigningOperatorConfig] { operators.map(\.config) }
    var coordinatorIdentifier: String { operators[0].config.identifier }

    var verifyingKey: Data {
        get throws {
            let user = try secp256k1.Signing.PublicKey(dataRepresentation: userSigningPublicKey, format: .compressed)
            return try user.combine([operatorShare.publicKey]).dataRepresentation
        }
    }

    /// BIP-340 signature by the BIP-86 tweak of the operators' share.
    func proofOfPossession(identity: Data, address: String) throws -> Data {
        var hasher = SparkHasher(tag: ["spark", "deposit", "proof_of_possession"])
        hasher.addBytes(identity)
        hasher.addBytes(operatorShare.publicKey.dataRepresentation)
        hasher.addBytes(Data(address.utf8))
        let tagHash = Data(SHA256.hash(data: Data("TapTweak".utf8)))
        let tweak = SHA256.hash(data: tagHash + tagHash + operatorShare.publicKey.dataRepresentation.dropFirst())
        let tweaked = try operatorShare.add(xonly: Array(tweak))
        let signer = try secp256k1.Schnorr.PrivateKey(dataRepresentation: tweaked.dataRepresentation)
        return try signer.signature(for: HashDigest(Array(hasher.hash()))).dataRepresentation
    }

    func addressSignature(_ key: secp256k1.Signing.PrivateKey, address: String) throws -> Data {
        try key.signature(for: HashDigest(Array(SHA256.hash(data: Data(address.utf8))))).derRepresentation
    }

    func address(network: SparkNetwork = .mainnet, withCoordinatorSignature: Bool = true) throws -> Spark_Address {
        let addressString = try SparkWallet.leafNodeAddress(verifyingKey: try verifyingKey, network: network)
        var address = Spark_Address()
        address.address = addressString
        address.verifyingKey = try verifyingKey
        address.depositAddressProof.proofOfPossessionSignature = try proofOfPossession(identity: identityPublicKey, address: addressString)
        for (config, key) in operators where withCoordinatorSignature || config.identifier != coordinatorIdentifier {
            address.depositAddressProof.addressSignatures[config.identifier] = try addressSignature(key, address: addressString)
        }
        return address
    }

    func verify(_ address: Spark_Address, isStatic: Bool, network: SparkNetwork = .mainnet) throws {
        try DepositAddressVerifier.verify(
            address,
            userSigningPublicKey: userSigningPublicKey,
            identityPublicKey: identityPublicKey,
            isStatic: isStatic,
            config: SparkConfig(network: network, signingOperators: operatorConfigs)
        )
    }
}

@Suite("Deposit address verification")
struct DepositAddressVerificationTests {

    @Test("An address with a valid proof of possession and operator signatures is accepted")
    func valid() throws {
        let deposit = try SyntheticDeposit()
        // The helper signs with the key the verifier derives: the BIP-86 tweak of the operator share.
        let tweaked = try getTaprootPubkey(verifyingPubkey: deposit.operatorShare.publicKey.dataRepresentation)
        #expect(tweaked.count == 33)
        try deposit.verify(try deposit.address(), isStatic: false)
        try deposit.verify(try deposit.address(), isStatic: true)
        try deposit.verify(try deposit.address(network: .regtest), isStatic: false, network: .regtest)
    }

    @Test("The coordinator's own signature is required for static addresses only")
    func coordinatorSignature() throws {
        let deposit = try SyntheticDeposit()
        let withoutCoordinator = try deposit.address(withCoordinatorSignature: false)
        try deposit.verify(withoutCoordinator, isStatic: false)
        #expect(throws: SparkError.self) { try deposit.verify(withoutCoordinator, isStatic: true) }
    }

    @Test("A missing or forged operator signature is refused")
    func operatorSignatures() throws {
        let deposit = try SyntheticDeposit()
        var missing = try deposit.address()
        missing.depositAddressProof.addressSignatures[deposit.operators[1].config.identifier] = nil
        #expect(throws: SparkError.self) { try deposit.verify(missing, isStatic: false) }

        var forged = try deposit.address()
        forged.depositAddressProof.addressSignatures[deposit.operators[2].config.identifier] =
            try deposit.addressSignature(try secp256k1.Signing.PrivateKey(), address: forged.address)
        #expect(throws: SparkError.self) { try deposit.verify(forged, isStatic: false) }

        var garbage = try deposit.address()
        garbage.depositAddressProof.addressSignatures[deposit.operators[2].config.identifier] = Data([1, 2, 3])
        #expect(throws: SparkError.self) { try deposit.verify(garbage, isStatic: false) }
    }

    @Test("A proof of possession that is tampered with or made for other data is refused")
    func proofOfPossession() throws {
        let deposit = try SyntheticDeposit()
        var tampered = try deposit.address()
        tampered.depositAddressProof.proofOfPossessionSignature[10] ^= 0x01
        #expect(throws: SparkError.self) { try deposit.verify(tampered, isStatic: false) }

        var otherIdentity = try deposit.address()
        let strangerIdentity = try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation
        otherIdentity.depositAddressProof.proofOfPossessionSignature =
            try deposit.proofOfPossession(identity: strangerIdentity, address: otherIdentity.address)
        #expect(throws: SparkError.self) { try deposit.verify(otherIdentity, isStatic: false) }

        var missing = try deposit.address()
        missing.clearDepositAddressProof()
        #expect(throws: SparkError.self) { try deposit.verify(missing, isStatic: false) }
    }

    @Test("An address that does not pay the verifying key is refused, even with genuine signatures over it")
    func addressMustPayVerifyingKey() throws {
        let deposit = try SyntheticDeposit()
        var swapped = try deposit.address()
        // A coordinator's own address, signed by every operator key the test holds.
        let foreign = try SparkWallet.leafNodeAddress(
            verifyingKey: try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation, network: .mainnet
        )
        swapped.address = foreign
        swapped.depositAddressProof.proofOfPossessionSignature =
            try deposit.proofOfPossession(identity: deposit.identityPublicKey, address: foreign)
        for (config, key) in deposit.operators {
            swapped.depositAddressProof.addressSignatures[config.identifier] = try deposit.addressSignature(key, address: foreign)
        }
        #expect(throws: SparkError.self) { try deposit.verify(swapped, isStatic: true) }
        // An address for another network is refused too.
        #expect(throws: SparkError.self) { try deposit.verify(try deposit.address(network: .regtest), isStatic: false) }
    }

    @Test("Degenerate keys are refused without crashing")
    func degenerateKeys() throws {
        let key = try secp256k1.Signing.PrivateKey().publicKey.dataRepresentation
        #expect(throws: SparkError.self) { _ = try DepositAddressVerifier.subtractPublicKeys(key, key) }
        #expect(throws: SparkError.self) { _ = try DepositAddressVerifier.subtractPublicKeys(Data([0x02]), key) }
        #expect(!DepositAddressVerifier.verifySchnorr(signature: Data(count: 64), message: Data(count: 32), taprootInternalKey: key))
        #expect(!DepositAddressVerifier.verifySchnorr(signature: Data(count: 10), message: Data(count: 32), taprootInternalKey: key))
    }

    @Test("A coordinator handing out an address without a proof is refused before the wallet shows it",
          .timeLimit(.minutes(1)))
    func unprovenAddressFromCoordinator() async throws {
        var unproven = Spark_Address()
        unproven.address = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
        unproven.verifyingKey = try #require(Data(hexString: "02cc8a4bc64d897bddc5fbc2f670f7a8ba0b386779106cf1223c6fc5d7cd6fc115"))
        let state = FakeOperatorState(rejection: .beforeHeaders, depositAddress: unproven) { _ in false }
        try await withFakeOperator(state) { wallet in
            await #expect(throws: SparkError.self) { _ = try await wallet.getDepositAddress() }
            await #expect(throws: SparkError.self) { _ = try await wallet.getStaticDepositAddress() }
        }
    }
}
