import Foundation

public struct SatsBalance: Sendable {
    /// Immediately spendable satoshis
    public let available: Int64
    /// All satoshis owned (available + locked in outgoing transfers/swaps)
    public let owned: Int64
    /// Pending inbound transfers not yet claimed
    public let incoming: Int64
}

public struct WalletBalance: Sendable {
    @available(*, deprecated, message: "Use satsBalance.available instead")
    public var balance: Int64 { satsBalance.available }
    public let satsBalance: SatsBalance
    public let tokenBalances: [TokenBalance]
    public let leaves: [SparkLeaf]
}

public struct SparkLeaf: Sendable {
    public let id: String
    public let treeID: String
    public let valueSats: Int64
    public let status: String
    // Internal: the raw proto node for use within the SDK
    let node: Spark_TreeNode
}

public struct SparkTransfer: Sendable {
    public let id: String
    public let senderIdentityPublicKey: String
    public let receiverIdentityPublicKey: String
    public let totalValueSats: Int64
    public let status: String
    public let type: String
    public let createdAt: Date
    /// The Spark invoice this transfer pays, if any (e.g. lightning payments).
    public let sparkInvoice: String?
}

public struct DepositAddress: Sendable {
    public let address: String
    public let leafId: String
    public let userPublicKey: Data
    public let verifyingKey: Data
}

public struct StaticDepositAddress: Sendable {
    public let address: String
    public let verifyingKey: Data
}

public struct LightningInvoice: Sendable {
    public let paymentRequest: String
    public let paymentHash: String
    public let amountSats: Int64
    public let expiresAt: Date
}

public struct FeeQuote: Sendable {
    public let feeSats: Int64
    public let feeRateSatsPerVbyte: Int64
}

public struct UnusedDepositAddress: Sendable {
    public let address: String
    public let leafId: String
    public let userSigningPublicKey: Data
    public let verifyingPublicKey: Data
}

public struct DepositFeeEstimate: Sendable {
    public let creditAmountSats: Int64
    public let quoteSignature: String
}

public struct DepositUtxo: Sendable {
    public let txid: String
    public let vout: UInt32
}

public struct WalletSettings: Sendable {
    public let privateEnabled: Bool
    public let ownerIdentityPublicKey: String
}

// MARK: - Token Types

/// Metadata about a token type.
public struct TokenMetadata: Sendable {
    public let tokenIdentifier: Bech32mTokenIdentifier
    public let rawTokenIdentifier: Data
    public let issuerPublicKey: Data
    public let tokenName: String
    public let tokenTicker: String
    public let decimals: UInt32
    public let maxSupply: Data  // 16-byte uint128 big-endian
    public let isFreezable: Bool
    public let extraMetadata: Data?
}

/// Token balance info for a single token type.
public struct TokenBalance: Sendable {
    public let tokenMetadata: TokenMetadata
    public let ownedBalance: UInt128
    public let availableToSendBalance: UInt128
}

/// A token output (TTXO) with its previous transaction reference.
public struct TokenOutputInfo: Sendable {
    public let id: String?
    public let ownerPublicKey: Data
    public let tokenIdentifier: Data
    public let tokenAmount: UInt128
    public let previousTransactionHash: Data
    public let previousTransactionVout: UInt32
    public let status: String
}

/// Result of creating a new token.
public struct TokenCreationResult: Sendable {
    public let transactionHash: String
    public let tokenIdentifier: Bech32mTokenIdentifier?
}

/// Selection strategy for token outputs.
public enum TokenOutputSelectionStrategy: Sendable {
    case smallFirst
    case largeFirst
}

/// Result of a token transfer.
public struct TokenTransferResult: Sendable {
    public let transactionHash: String
}

// MARK: - UInt128 helpers

/// Decode a 16-byte big-endian buffer to UInt128.
public func decodeUInt128(_ data: Data) -> UInt128 {
    guard data.count == 16 else { return 0 }
    var result: UInt128 = 0
    for byte in data {
        result = (result << 8) | UInt128(byte)
    }
    return result
}

/// Encode a UInt128 to 16-byte big-endian buffer.
public func encodeUInt128(_ value: UInt128) -> Data {
    var data = Data(count: 16)
    var v = value
    for i in stride(from: 15, through: 0, by: -1) {
        data[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return data
}

// MARK: - SSP Transfer Types

/// A transfer with its associated SSP user request (the higher-level operation).
public struct TransferWithUserRequest: Sendable {
    public let sparkId: String
    public let totalAmountSats: Int64?
    public let userRequest: UserRequest?
}

/// The SSP-side operation associated with a transfer.
public enum UserRequest: Sendable {
    case lightningReceive(LightningReceiveInfo)
    case lightningSend(LightningSendInfo)
    case coopExit(CoopExitInfo)
    case leavesSwap(LeavesSwapInfo)
    case claimStaticDeposit(ClaimStaticDepositInfo)
    case unknown(String)
}

public struct LightningReceiveInfo: Sendable {
    public let id: String
    public let status: String
    public let encodedInvoice: String?
    public let paymentHash: String?
    public let amountSats: Int64?
    public let memo: String?
    public let paymentPreimage: String?
}

public struct LightningSendInfo: Sendable {
    public let id: String
    public let status: String
    public let encodedInvoice: String?
    public let feeSats: Int64?
    public let idempotencyKey: String?
    public let paymentPreimage: String?
}

public struct CoopExitInfo: Sendable {
    public let id: String
    public let status: String
    public let coopExitTxid: String?
}

public struct LeavesSwapInfo: Sendable {
    public let id: String
    public let status: String
}

public struct ClaimStaticDepositInfo: Sendable {
    public let id: String
    public let status: String
    public let transactionId: String?
    public let outputIndex: Int?
}

public enum SparkEvent: Sendable {
    case connected
    case transferReceived(SparkTransfer)
    case transferSent(SparkTransfer)
    case depositConfirmed(treeID: String)
}
