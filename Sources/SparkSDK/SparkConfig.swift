import Foundation

public enum SparkNetwork: Sendable {
    case mainnet
    case regtest
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

public struct SparkConfig: Sendable {
    public let network: SparkNetwork
    public let signingOperators: [SigningOperatorConfig]
    public let sspURL: String

    public init(
        network: SparkNetwork = .mainnet,
        signingOperators: [SigningOperatorConfig]? = nil,
        sspURL: String? = nil
    ) {
        self.network = network
        self.signingOperators = signingOperators ?? Self.defaultOperators(for: network)
        self.sspURL = sspURL ?? "https://api.lightspark.com/graphql/spark/2025-03-19"
    }

    public static func defaultOperators(for network: SparkNetwork) -> [SigningOperatorConfig] {
        switch network {
        case .mainnet:
            return [
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
        case .regtest:
            return [
                SigningOperatorConfig(
                    address: "http://localhost:9001",
                    identifier: "0000000000000000000000000000000000000000000000000000000000000001",
                    identityPublicKeyHex: ""
                ),
                SigningOperatorConfig(
                    address: "http://localhost:9002",
                    identifier: "0000000000000000000000000000000000000000000000000000000000000002",
                    identityPublicKeyHex: ""
                ),
                SigningOperatorConfig(
                    address: "http://localhost:9003",
                    identifier: "0000000000000000000000000000000000000000000000000000000000000003",
                    identityPublicKeyHex: ""
                ),
            ]
        }
    }

    var signingOperatorAddresses: [String] {
        signingOperators.map(\.address)
    }

    var networkString: String {
        switch network {
        case .mainnet: return "mainnet"
        case .regtest: return "regtest"
        }
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

    public var sspIdentityPublicKey: Data {
        switch network {
        case .mainnet:
            return Data(hexString: "023e33e2920326f64ea31058d44777442d97d7d5cbfcf54e3060bc1695e5261c93")!
        case .regtest:
            return Data(hexString: "022bf283544b16c0622daecb79422007d167eca6ce9f0c98c0c49833b1f7170bfe")!
        }
    }
}
