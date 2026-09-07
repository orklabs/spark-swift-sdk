import Foundation
import SwiftProtobuf
import Testing
@testable import SparkSDK

/// The coordinator's final token transaction must equal the partial one apart from server-set fields.
@Suite("Token final transaction validation")
struct TokenTransactionValidationTests {

    private let owner = Data([0x02]) + Data(repeating: 0x11, count: 32)
    private let receiver = Data([0x03]) + Data(repeating: 0x22, count: 32)
    private let tokenId = Data(repeating: 0x33, count: 32)
    private let operatorKeys = [Data([0x02]) + Data(repeating: 0xA1, count: 32), Data([0x02]) + Data(repeating: 0xA2, count: 32), Data([0x03]) + Data(repeating: 0xA3, count: 32)]
    private let identifiers: Set<String> = ["op1", "op2", "op3"]

    private var expectations: TokenTransactionValidator.Expectations {
        .init(operatorIdentityPublicKeys: operatorKeys, operatorIdentifiers: identifiers,
              threshold: 2, withdrawBondSats: 10_000, withdrawRelativeBlockLocktime: 1_000)
    }

    private func output(owner: Data, amount: UInt128) -> SparkToken_TokenOutput {
        var o = SparkToken_TokenOutput()
        o.ownerPublicKey = owner
        o.tokenIdentifier = tokenId
        o.tokenAmount = encodeUInt128(amount)
        return o
    }

    private func partialTransfer() -> SparkToken_TokenTransaction {
        var input = SparkToken_TokenTransferInput()
        input.outputsToSpend = (0..<2).map { i in
            var ref = SparkToken_TokenOutputToSpend()
            ref.prevTokenTransactionHash = Data(repeating: UInt8(0x50 + i), count: 32)
            ref.prevTokenTransactionVout = UInt32(i)
            return ref
        }
        var tx = SparkToken_TokenTransaction()
        tx.version = 2
        tx.network = .mainnet
        tx.tokenInputs = .transferInput(input)
        tx.tokenOutputs = [output(owner: receiver, amount: 700), output(owner: owner, amount: 300)]
        tx.sparkOperatorIdentityPublicKeys = operatorKeys
        tx.clientCreatedTimestamp = Google_Protobuf_Timestamp(seconds: 1_700_000_000, nanos: 0)
        return tx
    }

    /// What an honest coordinator returns: the partial transaction plus server-set fields.
    private func finalize(_ partial: SparkToken_TokenTransaction) -> SparkToken_TokenTransaction {
        var final = partial
        for i in final.tokenOutputs.indices {
            final.tokenOutputs[i].id = "output-\(i)"
            final.tokenOutputs[i].revocationCommitment = Data([0x02]) + Data(repeating: UInt8(0x60 + i), count: 32)
            final.tokenOutputs[i].withdrawBondSats = 10_000
            final.tokenOutputs[i].withdrawRelativeBlockLocktime = 1_000
        }
        final.expiryTime = Google_Protobuf_Timestamp(seconds: 1_700_000_060, nanos: 0)
        return final
    }

    private func keyshare(_ owners: [String] = ["op1", "op2", "op3"], threshold: UInt32 = 2) -> Spark_SigningKeyshare {
        var k = Spark_SigningKeyshare()
        k.ownerIdentifiers = owners
        k.threshold = threshold
        return k
    }

    @Test("An honest final transaction passes, with and without keyshare info")
    func acceptsHonestFinal() throws {
        let partial = partialTransfer()
        let final = finalize(partial)
        try TokenTransactionValidator.validate(final: final, partial: partial, keyshareInfo: nil, expectations: expectations)
        try TokenTransactionValidator.validate(final: final, partial: partial, keyshareInfo: keyshare(), expectations: expectations)

        // Mint and create transactions too.
        var mintInput = SparkToken_TokenMintInput()
        mintInput.issuerPublicKey = owner
        mintInput.tokenIdentifier = tokenId
        var mint = partial
        mint.tokenInputs = .mintInput(mintInput)
        mint.tokenOutputs = [output(owner: owner, amount: 1_000)]
        try TokenTransactionValidator.validate(final: finalize(mint), partial: mint, keyshareInfo: nil, expectations: expectations)

        var createInput = SparkToken_TokenCreateInput()
        createInput.issuerPublicKey = owner
        createInput.tokenName = "Acme"
        createInput.tokenTicker = "ACME"
        createInput.decimals = 6
        createInput.maxSupply = encodeUInt128(1_000_000)
        createInput.isFreezable = false
        var create = partial
        create.tokenInputs = .createInput(createInput)
        create.tokenOutputs = []
        var finalCreate = finalize(create)
        if case .createInput(var ci) = finalCreate.tokenInputs {
            ci.creationEntityPublicKey = Data([0x02]) + Data(repeating: 0x77, count: 32)   // server-set
            finalCreate.tokenInputs = .createInput(ci)
        }
        try TokenTransactionValidator.validate(final: finalCreate, partial: create, keyshareInfo: nil, expectations: expectations)
    }

    @Test("Every tampered field is refused")
    func refusesTampering() throws {
        let partial = partialTransfer()
        let honest = finalize(partial)

        func expectRejected(_ label: String, _ mutate: (inout SparkToken_TokenTransaction) -> Void) {
            var final = honest
            mutate(&final)
            #expect(throws: SparkError.self, Comment(rawValue: label)) {
                try TokenTransactionValidator.validate(final: final, partial: partial, keyshareInfo: nil, expectations: expectations)
            }
        }

        expectRejected("output owner redirected") { $0.tokenOutputs[0].ownerPublicKey = Data([0x02]) + Data(repeating: 0xEE, count: 32) }
        expectRejected("output amount changed") { $0.tokenOutputs[0].tokenAmount = encodeUInt128(701) }
        expectRejected("change amount changed") { $0.tokenOutputs[1].tokenAmount = encodeUInt128(299) }
        expectRejected("output token id changed") { $0.tokenOutputs[1].tokenIdentifier = Data(repeating: 0x44, count: 32) }
        expectRejected("output removed") { $0.tokenOutputs.removeLast() }
        expectRejected("output added") { $0.tokenOutputs.append(self.output(owner: self.receiver, amount: 1)) }
        expectRejected("withdraw bond lowered") { $0.tokenOutputs[0].withdrawBondSats = 1 }
        expectRejected("withdraw locktime lowered") { $0.tokenOutputs[0].withdrawRelativeBlockLocktime = 10 }
        expectRejected("network changed") { $0.network = .regtest }
        expectRejected("version changed") { $0.version = 3 }
        expectRejected("operator key swapped") { $0.sparkOperatorIdentityPublicKeys[0] = Data([0x02]) + Data(repeating: 0xBB, count: 32) }
        expectRejected("operator key dropped") { $0.sparkOperatorIdentityPublicKeys.removeLast() }
        expectRejected("operator key added") { $0.sparkOperatorIdentityPublicKeys.append(Data([0x02]) + Data(repeating: 0xBB, count: 32)) }
        expectRejected("input replaced") {
            if case .transferInput(var ti) = $0.tokenInputs {
                ti.outputsToSpend[0].prevTokenTransactionVout = 9
                $0.tokenInputs = .transferInput(ti)
            }
        }
        expectRejected("input added") {
            if case .transferInput(var ti) = $0.tokenInputs {
                ti.outputsToSpend.append(ti.outputsToSpend[0])
                $0.tokenInputs = .transferInput(ti)
            }
        }
        expectRejected("type changed") {
            var mintInput = SparkToken_TokenMintInput()
            mintInput.issuerPublicKey = self.owner
            mintInput.tokenIdentifier = self.tokenId
            $0.tokenInputs = .mintInput(mintInput)
        }
        expectRejected("invoice attachment added") {
            var attachment = SparkToken_InvoiceAttachment()
            attachment.sparkInvoice = "spark1..."
            $0.invoiceAttachments = [attachment]
        }
    }

    @Test("Keyshare info must name the configured operators with the expected threshold")
    func keyshareChecks() throws {
        let partial = partialTransfer()
        let final = finalize(partial)
        for (label, info) in [
            ("wrong threshold", keyshare(threshold: 1)),
            ("too few operators", keyshare(["op1", "op2"])),
            ("unknown operator", keyshare(["op1", "op2", "evil"])),
            ("duplicate operator", keyshare(["op1", "op1", "op2"])),
        ] {
            #expect(throws: SparkError.self, Comment(rawValue: label)) {
                try TokenTransactionValidator.validate(final: final, partial: partial, keyshareInfo: info, expectations: expectations)
            }
        }
    }

    @Test("Config derives the reference threshold and token expectations")
    func configDefaults() {
        #expect(SparkConfig.defaultThreshold(operatorCount: 3) == 2)
        #expect(SparkConfig.defaultThreshold(operatorCount: 5) == 3)
        #expect(SparkConfig.defaultThreshold(operatorCount: 1) == 2)
        let config = SparkConfig(network: .mainnet)
        #expect(config.signingThreshold == 2)
        #expect(config.expectedWithdrawBondSats == 10_000)
        #expect(config.expectedWithdrawRelativeBlockLocktime == 1_000)
        #expect(SparkConfig(network: .mainnet, signingThreshold: 3).signingThreshold == 3)
    }
}
