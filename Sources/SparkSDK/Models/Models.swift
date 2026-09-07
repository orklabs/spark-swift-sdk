import Foundation

public struct SatsBalance: Sendable {
    /// Satoshis that can be sent right now: AVAILABLE leaves whose refund timelock is above the
    /// floor the coordinator enforces.
    public let available: Int64
    /// All satoshis owned (available + frozen + locked in outgoing transfers/swaps)
    public let owned: Int64
    /// Pending inbound transfers not yet claimed
    public let incoming: Int64
    /// Satoshis in AVAILABLE leaves at the timelock floor. The coordinator will neither move nor
    /// renew them; only a unilateral on-chain exit can recover them.
    public let frozen: Int64
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

/// What `withdrawAll` would do right now. Produced by `quoteWithdrawAll` after pending inbound
/// transfers were claimed and renewable leaves renewed.
public struct WithdrawAllQuote: Sendable, Equatable {
    /// Sats that would be handed to the SSP: every spendable leaf.
    public let spendableSats: Int64
    /// The SSP's fee quote (fast exit) for those leaves. Zero when there is nothing to send.
    public let quotedFeeSats: Int64
    /// Sats in leaves at the timelock floor. They stay behind; only a unilateral exit moves them.
    public let frozenSats: Int64
    /// Sats in leaves locked by an in-flight swap or exit. Withdraw again once they settle.
    public let lockedSats: Int64
    /// Inbound sats that are still unclaimed after the claim attempt.
    public let incomingSats: Int64
    /// Number of leaves that would be exited.
    public let leafCount: Int

    /// What the destination would receive if the SSP charges exactly its quote.
    public var estimatedPayoutSats: Int64 { spendableSats - quotedFeeSats }
    /// Share of the wallet's own sats (spendable + frozen) that cannot leave off-chain, 0...1.
    public var frozenFraction: Double {
        let total = spendableSats + frozenSats
        return total > 0 ? Double(frozenSats) / Double(total) : 0
    }
    /// Whether the quoted fee leaves anything to pay out.
    public var coversFee: Bool { spendableSats > quotedFeeSats && quotedFeeSats >= 0 }
}

/// Outcome of `withdrawAll`.
public struct WithdrawAllResult: Sendable, Equatable {
    /// L1 transaction id of the cooperative exit.
    public let txid: String
    /// Sats handed to the SSP: every spendable sat at drain time.
    public let sentSats: Int64
    /// Sats the verified exit transaction pays to the destination.
    public let payoutSats: Int64
    /// Sats left in frozen leaves; only a unilateral exit can recover them.
    public let frozenSats: Int64
    /// Sats left in leaves locked by an in-flight operation.
    public let lockedSats: Int64
    /// Inbound sats that could not be claimed before the drain.
    public let unclaimedSats: Int64

    /// SSP fee actually taken.
    public var feeSats: Int64 { sentSats - payoutSats }
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
