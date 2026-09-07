import Foundation

/// Client-side checks on the SSP's cooperative-exit response, run BEFORE any refund transaction
/// is signed or any key tweak is prepared. Mirrors the reference SDK's
/// `validateCoopExitPayoutTransaction` and `validateConnectorTxBindsToCoopExitTxid`.
///
/// Without these checks the wallet hands its leaves to the SSP on the SSP's word: the operators
/// release the transfer once the exit txid confirms, but only the client knows what that
/// transaction was supposed to pay.
enum CoopExitValidator {

    struct ValidatedExit: Equatable {
        /// Exit txid in internal (little-endian) byte order, as the coordinator expects it.
        let exitTxid: Data
        let connectorTx: RawTransaction
        /// The payout output that satisfied the check.
        let payoutVout: Int
        let payoutSats: UInt64
    }

    /// The fee the withdrawal is allowed to pay: the SSP's quote, bounded by the caller's cap.
    /// The payout is later required to be at least `amountSats - feeCap`.
    static func resolveFeeCap(quotedFeeSats: Int64, maxFeeSats: Int64?, amountSats: Int64) throws -> Int64 {
        guard amountSats > 0 else {
            throw SparkError.invalidArgument("withdrawal amount must be positive, got \(amountSats)")
        }
        guard quotedFeeSats >= 0 else {
            throw SparkError.untrustedResponse("SSP quoted a negative withdrawal fee (\(quotedFeeSats) sats)")
        }
        if let maxFeeSats {
            guard maxFeeSats >= 0 else {
                throw SparkError.invalidArgument("maxFeeSats must not be negative")
            }
            guard quotedFeeSats <= maxFeeSats else {
                throw SparkError.feeExceedsLimit(feeSats: quotedFeeSats, maxFeeSats: maxFeeSats)
            }
        }
        let cap = maxFeeSats ?? quotedFeeSats
        guard cap < amountSats else {
            throw SparkError.feeExceedsLimit(feeSats: cap, maxFeeSats: amountSats - 1)
        }
        return cap
    }

    /// Validate the SSP's exit and connector transactions.
    ///
    /// - The raw exit transaction must hash to `coopExitTxidHex` (either byte order is accepted,
    ///   like the operators do).
    /// - It must contain an output paying `payoutAddress` at least `minimumPayoutSats`.
    /// - The connector transaction's first input must spend that exit transaction, and it must
    ///   carry one connector output per leaf plus the SSP's own output.
    static func validate(
        rawCoopExitTransactionHex: String,
        rawConnectorTransactionHex: String,
        coopExitTxidHex: String,
        payoutAddress: String,
        minimumPayoutSats: Int64,
        leafCount: Int,
        network: SparkNetwork
    ) throws -> ValidatedExit {
        guard minimumPayoutSats > 0 else {
            throw SparkError.invalidArgument("minimum payout must be positive")
        }
        let expectedScript = try BitcoinAddress.scriptPubKey(for: payoutAddress, network: network)

        guard let exitBytes = Data(hexString: rawCoopExitTransactionHex), !exitBytes.isEmpty else {
            throw SparkError.untrustedResponse("SSP coop exit response: raw_coop_exit_transaction is not valid hex")
        }
        let exitTx = try RawTransaction.parse(exitBytes, context: "coop exit tx")

        guard let claimedTxid = Data(hexString: coopExitTxidHex), claimedTxid.count == 32 else {
            throw SparkError.untrustedResponse("SSP coop exit response: coop_exit_txid is not a 32-byte hex id")
        }
        guard RawTransaction.txidMatches(exitTx.txid, claimedTxid) else {
            throw SparkError.untrustedResponse(
                "SSP coop exit response is inconsistent: coop_exit_txid \(coopExitTxidHex) does not match raw_coop_exit_transaction (\(exitTx.txidHex))"
            )
        }

        var payout: (vout: Int, sats: UInt64)? = nil
        for (index, output) in exitTx.outputs.enumerated() where output.scriptPubKey == expectedScript {
            if output.value >= UInt64(minimumPayoutSats) {
                payout = (index, output.value)
                break
            }
        }
        guard let payout else {
            throw SparkError.untrustedResponse(
                "SSP cooperative exit transaction does not pay \(payoutAddress) at least \(minimumPayoutSats) sats"
            )
        }

        guard let connectorBytes = Data(hexString: rawConnectorTransactionHex), !connectorBytes.isEmpty else {
            throw SparkError.untrustedResponse("SSP coop exit response: raw_connector_transaction is not valid hex")
        }
        let connectorTx = try RawTransaction.parse(connectorBytes, context: "connector tx")
        guard let parent = connectorTx.inputs.first else {
            throw SparkError.untrustedResponse("SSP coop exit response is malformed: connector transaction has no inputs")
        }
        guard RawTransaction.txidMatches(parent.previousTxid, exitTx.txid) else {
            throw SparkError.untrustedResponse(
                "SSP coop exit response is inconsistent: connector transaction does not spend the coop exit transaction"
            )
        }
        guard leafCount > 0, connectorTx.outputs.count == leafCount + 1 else {
            throw SparkError.untrustedResponse(
                "SSP coop exit response is malformed: connector transaction has \(connectorTx.outputs.count) outputs for \(leafCount) leaves"
            )
        }

        return ValidatedExit(exitTxid: exitTx.txid, connectorTx: connectorTx, payoutVout: payout.vout, payoutSats: payout.sats)
    }
}
