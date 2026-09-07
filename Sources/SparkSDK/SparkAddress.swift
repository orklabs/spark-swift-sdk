import Foundation

/// Spark addresses: a bech32m encoding of the protobuf `SparkAddress { identity_public_key = 1 }`
/// payload under a network-specific human-readable part.
enum SparkAddress {
    /// Current prefixes, plus the legacy ones the reference SDK still accepts.
    private static let prefixes: [SparkNetwork: (current: String, legacy: String)] = [
        .mainnet: ("spark", "sp"),
        .regtest: ("sparkrt", "sprt"),
    ]

    static func hrp(for network: SparkNetwork) -> String {
        prefixes[network]!.current
    }

    static func encode(identityPublicKey: Data, network: SparkNetwork) -> String {
        // Protobuf wire encoding: field 1, wire type 2 (tag 0x0a), single-byte length, bytes.
        var payload = Data([0x0a, UInt8(identityPublicKey.count)])
        payload.append(identityPublicKey)
        return Bech32m.encode(hrp: hrp(for: network), data: Bech32m.toWords(payload))
    }

    /// The identity public key an address encodes. Throws `SparkError.invalidAddress` for a
    /// malformed address or one for another network.
    static func decode(_ address: String, network: SparkNetwork) throws -> Data {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let hrp: String
        let words: [UInt8]
        do {
            (hrp, words) = try Bech32m.decodeBech32m(trimmed)
        } catch let error as SparkError {
            throw SparkError.invalidAddress("'\(trimmed)': \(error.localizedDescription)")
        }
        let allowed = prefixes[network]!
        guard hrp == allowed.current || hrp == allowed.legacy else {
            throw SparkError.invalidAddress("'\(trimmed)' is not a \(network) Spark address (prefix '\(hrp)')")
        }
        guard let payload = Bech32m.fromWords(words) else {
            throw SparkError.invalidAddress("'\(trimmed)' has an invalid payload encoding")
        }
        // field 1 (identity_public_key), length-delimited, 33-byte compressed key
        guard payload.count >= 35, payload[payload.startIndex] == 0x0a, payload[payload.startIndex + 1] == 33 else {
            throw SparkError.invalidAddress("'\(trimmed)' does not start with a 33-byte identity public key")
        }
        let key = payload.subdata(in: (payload.startIndex + 2)..<(payload.startIndex + 35))
        guard key.first == 0x02 || key.first == 0x03 else {
            throw SparkError.invalidAddress("'\(trimmed)' carries an invalid compressed public key")
        }
        return key
    }
}
