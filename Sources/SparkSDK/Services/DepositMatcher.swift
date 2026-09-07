import Foundation

/// Finds which output of an on-chain transaction pays one of the wallet's unused deposit
/// addresses, so a claim is built for the leaf that actually received the funds.
enum DepositMatcher {
    struct Match: Equatable {
        let vout: UInt32
        let address: String
    }

    static func match(
        rawTx: Data,
        candidateAddresses: [String],
        requestedVout: UInt32?,
        network: SparkNetwork
    ) throws -> Match {
        let tx = try RawTransaction.parse(rawTx, context: "deposit tx")
        var scripts: [Data: String] = [:]
        for address in candidateAddresses {
            if let script = try? BitcoinAddress.scriptPubKey(for: address, network: network) {
                scripts[script] = address
            }
        }
        guard !scripts.isEmpty else {
            throw SparkError.invalidResponse("No unused deposit address found. Generate one first with getDepositAddress().")
        }
        if let requestedVout {
            let output = try tx.output(at: requestedVout)
            guard let address = scripts[output.scriptPubKey] else {
                throw SparkError.invalidArgument("output \(requestedVout) of \(tx.txidHex) does not pay one of this wallet's deposit addresses")
            }
            return Match(vout: requestedVout, address: address)
        }
        for (index, output) in tx.outputs.enumerated() {
            if let address = scripts[output.scriptPubKey] {
                return Match(vout: UInt32(index), address: address)
            }
        }
        throw SparkError.invalidArgument("transaction \(tx.txidHex) does not pay any of this wallet's unused deposit addresses")
    }
}
