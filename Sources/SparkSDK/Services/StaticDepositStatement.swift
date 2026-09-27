import Foundation
import CryptoKit

/// An output paying a static deposit address, by display-order txid (lower-case hex) and vout.
struct DepositOutpoint: Sendable, Equatable {
    let txid: String
    let vout: UInt32

    /// Throws `SparkError.invalidArgument` unless `txid` is 64 hex characters.
    init(txid: String, vout: UInt32) throws {
        let normalized = txid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            throw SparkError.invalidArgument("transaction id must be 64 hex characters, got '\(txid)'")
        }
        self.txid = normalized
        self.vout = vout
    }

    /// The txid bytes in display order: how the operators store and look up deposit UTXOs.
    var displayOrderTxid: Data {
        Data(hexString: txid) ?? Data()
    }

    /// The txid bytes in internal order: how a transaction input spends the output.
    var internalOrderTxid: Data {
        Data(displayOrderTxid.reversed())
    }

    func utxo(network: Spark_Network) -> Spark_UTXO {
        var utxo = Spark_UTXO()
        utxo.txid = displayOrderTxid
        utxo.vout = vout
        utxo.network = network
        return utxo
    }
}

/// What a static-deposit statement authorizes (the operators' `UtxoSwapRequestType`).
enum StaticDepositRequestType: UInt8 {
    case fixed = 0
    case maxFee = 1
    case refund = 2
}

extension SparkWallet {
    /// The statement the wallet signs (SHA-256, identity key) to authorize a static-deposit claim
    /// or refund — the operators' `createUserStatementLegacy` and the reference SDK's
    /// `getStaticDepositSigningPayload`: "claim_static_deposit", the lower-case network, the
    /// display-order txid, the vout (little-endian u32), the request type (u8), the credit amount
    /// (little-endian u64), then `authorization` as raw bytes — the SSP's quote signature for a
    /// claim, the refund transaction's 32-byte sighash for a refund.
    static func staticDepositStatement(
        _ outpoint: DepositOutpoint,
        network: SparkNetwork,
        requestType: StaticDepositRequestType,
        creditAmountSats: UInt64,
        authorization: Data
    ) -> Data {
        var statement = Data("claim_static_deposit".utf8)
        statement.append(Data(network.name.utf8))
        statement.append(Data(outpoint.txid.utf8))
        withUnsafeBytes(of: outpoint.vout.littleEndian) { statement.append(contentsOf: $0) }
        statement.append(requestType.rawValue)
        withUnsafeBytes(of: creditAmountSats.littleEndian) { statement.append(contentsOf: $0) }
        statement.append(authorization)
        return statement
    }
}
