import Foundation

public enum SparkNetwork: Sendable {
    case mainnet
    case regtest

    /// Lower-case name, as the operators spell it in signed statements.
    var name: String {
        switch self {
        case .mainnet: return "mainnet"
        case .regtest: return "regtest"
        }
    }
}

public struct SigningOperatorConfig: Sendable {
    public let address: String
    public let identifier: String
    public let identityPublicKeyHex: String

    public init(address: String, identifier: String, identityPublicKeyHex: String) {
        self.address = address
        self.identifier = identifier
        self.identityPublicKeyHex = identityPublicKeyHex
    }
}

/// How token transactions are sent to the operators.
public enum TokenTransactionVersion: Sendable {
    /// One `broadcast_transaction` call, signed over the protohash of the partial transaction:
    /// the reference SDK's default, and the format the operators are moving to.
    case v3
    /// `start_transaction` then `commit_transaction`, signed over the V2 hashes. Kept while the
    /// operators accept it, as the reference SDK keeps it.
    case v2
}

public struct SparkConfig: Sendable {
    /// Lightspark's hosted SSP, the default.
    public static let defaultSspURL = "https://api.lightspark.com/graphql/spark/2025-03-19"

    public let network: SparkNetwork
    public let signingOperators: [SigningOperatorConfig]
    public let sspURL: String
    /// The SSP's identity key, when it is not the default SSP's (see `sspIdentityPublicKey`).
    private let sspIdentityPublicKeyHex: String?
    /// FROST signing threshold the operators enforce. Defaults to the reference SDK's value for
    /// the operator count (2 of 3 on mainnet).
    public let signingThreshold: UInt32
    /// Withdraw bond the coordinator is expected to set on token outputs (reference SDK: 10 000).
    public let expectedWithdrawBondSats: UInt64
    /// Relative block locktime the coordinator is expected to set on token outputs (reference SDK: 1 000).
    public let expectedWithdrawRelativeBlockLocktime: UInt64
    /// How token transactions are sent: V3 by default, as in the reference SDK.
    public let tokenTransactionVersion: TokenTransactionVersion

    /// - Parameters:
    ///   - sspURL: The SSP's GraphQL endpoint; Lightspark's hosted SSP by default.
    ///   - sspIdentityPublicKeyHex: The SSP's identity key, which transfers to the SSP (Lightning
    ///     sends, leaf swaps, cooperative exits) are addressed to. Required with a custom
    ///     `sspURL`: without it those operations refuse to run rather than send to Lightspark's
    ///     key, as the reference SDK takes the SSP's URL and key together.
    public init(
        network: SparkNetwork = .mainnet,
        signingOperators: [SigningOperatorConfig]? = nil,
        sspURL: String? = nil,
        sspIdentityPublicKeyHex: String? = nil,
        signingThreshold: UInt32? = nil,
        expectedWithdrawBondSats: UInt64 = 10_000,
        expectedWithdrawRelativeBlockLocktime: UInt64 = 1_000,
        tokenTransactionVersion: TokenTransactionVersion = .v3
    ) {
        self.network = network
        let operators = signingOperators ?? Self.defaultOperators(for: network)
        self.signingOperators = operators
        self.sspURL = sspURL ?? Self.defaultSspURL
        self.sspIdentityPublicKeyHex = sspIdentityPublicKeyHex
        self.signingThreshold = signingThreshold ?? Self.defaultThreshold(operatorCount: operators.count)
        self.expectedWithdrawBondSats = expectedWithdrawBondSats
        self.expectedWithdrawRelativeBlockLocktime = expectedWithdrawRelativeBlockLocktime
        self.tokenTransactionVersion = tokenTransactionVersion
    }

    /// The threshold the Spark deployments use for a given operator count (2 of 3, 3 of 5).
    static func defaultThreshold(operatorCount: Int) -> UInt32 {
        max(2, (UInt32(max(operatorCount, 0)) + 2) / 2)
    }

    /// The hosted operators. Regtest uses them too, as the reference SDK's REGTEST preset does:
    /// they serve both networks under the same keys.
    public static func defaultOperators(for network: SparkNetwork) -> [SigningOperatorConfig] {
        [
            SigningOperatorConfig(
                address: "https://0.spark.lightspark.com",
                identifier: "0000000000000000000000000000000000000000000000000000000000000001",
                identityPublicKeyHex: "03dfbdff4b6332c220f8fa2ba8ed496c698ceada563fa01b67d9983bfc5c95e763"
            ),
            SigningOperatorConfig(
                address: "https://spark-operator.breez.technology",
                identifier: "0000000000000000000000000000000000000000000000000000000000000002",
                identityPublicKeyHex: "03e625e9768651c9be268e287245cc33f96a68ce9141b0b4769205db027ee8ed77"
            ),
            SigningOperatorConfig(
                address: "https://2.spark.flashnet.xyz",
                identifier: "0000000000000000000000000000000000000000000000000000000000000003",
                identityPublicKeyHex: "022eda13465a59205413086130a65dc0ed1b8f8e51937043161f8be0c369b1a410"
            ),
        ]
    }

    var signingOperatorAddresses: [String] {
        signingOperators.map(\.address)
    }

    var networkString: String {
        network.name
    }

    var networkProto: Spark_Network {
        switch network {
        case .mainnet: return .mainnet
        case .regtest: return .regtest
        }
    }

    var networkGraphQL: String {
        switch network {
        case .mainnet: return "MAINNET"
        case .regtest: return "REGTEST"
        }
    }

    public var coordinatorAddress: String {
        signingOperators[0].address
    }

    /// The SSP's identity key: the one configured, else the default SSP's for the network. Empty
    /// for a custom `sspURL` configured without a key.
    public var sspIdentityPublicKey: Data {
        if let sspIdentityPublicKeyHex {
            return Data(hexString: sspIdentityPublicKeyHex) ?? Data()
        }
        guard sspURL == Self.defaultSspURL else { return Data() }
        switch network {
        case .mainnet:
            return Data(hexString: "023e33e2920326f64ea31058d44777442d97d7d5cbfcf54e3060bc1695e5261c93") ?? Data()
        case .regtest:
            return Data(hexString: "022bf283544b16c0622daecb79422007d167eca6ce9f0c98c0c49833b1f7170bfe") ?? Data()
        }
    }

    /// The SSP's identity key for a transfer to it; throws `SparkError.invalidArgument` when there
    /// is none (a custom `sspURL` without `sspIdentityPublicKeyHex`) or it is not a compressed key.
    func requireSspIdentityPublicKey() throws -> Data {
        let key = sspIdentityPublicKey
        guard key.count == 33, key.first == 0x02 || key.first == 0x03 else {
            throw SparkError.invalidArgument(
                "no valid SSP identity key: a custom sspURL needs sspIdentityPublicKeyHex, the SSP's compressed public key"
            )
        }
        return key
    }
}
