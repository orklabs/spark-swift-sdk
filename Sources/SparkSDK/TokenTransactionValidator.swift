import Foundation

/// Checks that the "final" token transaction the coordinator returns from `start_transaction` is
/// the transaction the wallet submitted, plus only the server-set fields it is allowed to add
/// (output ids, revocation commitments, withdraw bond and locktime, expiry). Mirrors the reference
/// SDK's `validateTokenTransaction`. Runs before the wallet signs the final hash for every
/// operator, so a coordinator cannot redirect or resize token outputs.
enum TokenTransactionValidator {

    struct Expectations {
        /// Operator identity keys the wallet placed in the partial transaction.
        let operatorIdentityPublicKeys: [Data]
        /// Operator identifiers from the wallet configuration.
        let operatorIdentifiers: Set<String>
        let threshold: UInt32
        let withdrawBondSats: UInt64
        let withdrawRelativeBlockLocktime: UInt64
    }

    static func validate(
        final: SparkToken_TokenTransaction,
        partial: SparkToken_TokenTransaction,
        keyshareInfo: Spark_SigningKeyshare?,
        expectations: Expectations
    ) throws {
        func fail(_ what: String) -> SparkError {
            .untrustedResponse("final token transaction rejected: \(what)")
        }

        guard final.version == partial.version else { throw fail("version changed") }
        guard final.network == partial.network else { throw fail("network changed") }
        guard final.invoiceAttachments == partial.invoiceAttachments else { throw fail("invoice attachments changed") }

        let expectedKeys = Set(expectations.operatorIdentityPublicKeys)
        guard Set(final.sparkOperatorIdentityPublicKeys) == expectedKeys,
              final.sparkOperatorIdentityPublicKeys.count == expectations.operatorIdentityPublicKeys.count,
              Set(partial.sparkOperatorIdentityPublicKeys) == expectedKeys else {
            throw fail("operator identity public keys changed")
        }

        switch (final.tokenInputs, partial.tokenInputs) {
        case (.mintInput(let f), .mintInput(let p)):
            guard !f.issuerPublicKey.isEmpty, f.issuerPublicKey == p.issuerPublicKey else { throw fail("mint issuer changed") }
            guard f.hasTokenIdentifier, p.hasTokenIdentifier, f.tokenIdentifier == p.tokenIdentifier else {
                throw fail("mint token identifier changed")
            }
        case (.createInput(let f), .createInput(let p)):
            guard !f.issuerPublicKey.isEmpty, f.issuerPublicKey == p.issuerPublicKey else { throw fail("create issuer changed") }
            guard f.tokenName == p.tokenName, f.tokenTicker == p.tokenTicker, f.decimals == p.decimals,
                  f.maxSupply == p.maxSupply, f.isFreezable == p.isFreezable else {
                throw fail("token creation parameters changed")
            }
            guard f.hasExtraMetadata == p.hasExtraMetadata, f.extraMetadata == p.extraMetadata else {
                throw fail("token extra metadata changed")
            }
        case (.transferInput(let f), .transferInput(let p)):
            guard f.outputsToSpend.count == p.outputsToSpend.count, !p.outputsToSpend.isEmpty else {
                throw fail("outputs to spend count changed")
            }
            for (index, (fo, po)) in zip(f.outputsToSpend, p.outputsToSpend).enumerated() {
                guard fo.prevTokenTransactionHash == po.prevTokenTransactionHash,
                      fo.prevTokenTransactionVout == po.prevTokenTransactionVout else {
                    throw fail("input \(index) changed")
                }
            }
        default:
            throw fail("transaction type changed or missing")
        }

        guard final.tokenOutputs.count == partial.tokenOutputs.count else {
            throw fail("output count changed (\(final.tokenOutputs.count) vs \(partial.tokenOutputs.count))")
        }
        for (index, (fo, po)) in zip(final.tokenOutputs, partial.tokenOutputs).enumerated() {
            guard fo.ownerPublicKey == po.ownerPublicKey else { throw fail("output \(index) owner changed") }
            guard fo.tokenAmount == po.tokenAmount else { throw fail("output \(index) amount changed") }
            if po.hasTokenIdentifier {
                guard fo.hasTokenIdentifier, fo.tokenIdentifier == po.tokenIdentifier else {
                    throw fail("output \(index) token identifier changed")
                }
            }
            if fo.hasTokenPublicKey, po.hasTokenPublicKey {
                guard fo.tokenPublicKey == po.tokenPublicKey else { throw fail("output \(index) token public key changed") }
            }
            if fo.hasWithdrawBondSats {
                guard fo.withdrawBondSats == expectations.withdrawBondSats else {
                    throw fail("output \(index) withdraw bond \(fo.withdrawBondSats) differs from expected \(expectations.withdrawBondSats)")
                }
            }
            if fo.hasWithdrawRelativeBlockLocktime {
                guard fo.withdrawRelativeBlockLocktime == expectations.withdrawRelativeBlockLocktime else {
                    throw fail("output \(index) withdraw locktime \(fo.withdrawRelativeBlockLocktime) differs from expected \(expectations.withdrawRelativeBlockLocktime)")
                }
            }
        }

        if let keyshareInfo {
            guard keyshareInfo.threshold == expectations.threshold else {
                throw fail("keyshare threshold \(keyshareInfo.threshold) differs from expected \(expectations.threshold)")
            }
            guard keyshareInfo.ownerIdentifiers.count == expectations.operatorIdentifiers.count else {
                throw fail("keyshare operator count \(keyshareInfo.ownerIdentifiers.count) differs from configured \(expectations.operatorIdentifiers.count)")
            }
            guard Set(keyshareInfo.ownerIdentifiers).count == keyshareInfo.ownerIdentifiers.count else {
                throw fail("duplicate keyshare owner identifiers")
            }
            for identifier in keyshareInfo.ownerIdentifiers where !expectations.operatorIdentifiers.contains(identifier) {
                throw fail("keyshare owner \(identifier) is not a configured operator")
            }
        }
    }
}
