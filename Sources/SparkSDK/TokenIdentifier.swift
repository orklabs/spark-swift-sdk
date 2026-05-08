import Foundation

/// Bech32m-encoded token identifier (e.g. `btkn1...` for mainnet, `btknrt1...` for regtest).
public typealias Bech32mTokenIdentifier = String

/// Network prefix mapping for token identifiers.
enum TokenIdentifierPrefix {
    static func prefix(for network: SparkNetwork) -> String {
        switch network {
        case .mainnet: return "btkn"
        case .regtest: return "btknrt"
        }
    }

    static func network(for prefix: String) -> SparkNetwork? {
        switch prefix {
        case "btkn": return .mainnet
        case "btknrt": return .regtest
        case "btknt", "btkns", "btknl": return nil // testnet/signet/local not supported yet
        default: return nil
        }
    }
}

/// Encode a raw 32-byte token identifier to Bech32m format.
public func encodeBech32mTokenIdentifier(_ rawIdentifier: Data, network: SparkNetwork) throws -> Bech32mTokenIdentifier {
    guard rawIdentifier.count == 32 else {
        throw SparkError.invalidResponse("Token identifier must be 32 bytes, got \(rawIdentifier.count)")
    }
    let hrp = TokenIdentifierPrefix.prefix(for: network)
    let words = Bech32m.toWords(rawIdentifier)
    return Bech32m.encode(hrp: hrp, data: words, limit: 500)
}

/// Decode a Bech32m token identifier back to raw 32 bytes.
public func decodeBech32mTokenIdentifier(_ bech32mIdentifier: Bech32mTokenIdentifier, network: SparkNetwork? = nil) throws -> (tokenIdentifier: Data, network: SparkNetwork) {
    let (hrp, data) = try Bech32m.decodeBech32m(bech32mIdentifier)

    if let network = network {
        let expectedPrefix = TokenIdentifierPrefix.prefix(for: network)
        guard hrp == expectedPrefix else {
            throw SparkError.invalidResponse("Invalid token identifier prefix: expected '\(expectedPrefix)', got '\(hrp)'")
        }
    }

    guard let detectedNetwork = TokenIdentifierPrefix.network(for: hrp) else {
        throw SparkError.invalidResponse("Unknown token identifier prefix: '\(hrp)'")
    }

    guard let rawBytes = Bech32m.fromWords(data) else {
        throw SparkError.invalidResponse("Failed to decode token identifier words")
    }

    guard rawBytes.count == 32 else {
        throw SparkError.invalidResponse("Token identifier must be 32 bytes, got \(rawBytes.count)")
    }

    return (rawBytes, detectedNetwork)
}
