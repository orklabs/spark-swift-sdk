import Foundation

/// Bitcoin address parsing with network enforcement.
///
/// Supports P2PKH and P2SH (Base58Check), P2WPKH and P2WSH (bech32, witness v0) and P2TR
/// (bech32m, witness v1), applying the BIP-173 / BIP-350 rules: v0 programs must use the bech32
/// checksum and be 20 or 32 bytes, v1 programs must use bech32m and be 32 bytes. Other witness
/// versions are refused so funds can never be sent to a script no wallet can spend today.
enum BitcoinAddress {
    enum Kind: Sendable, Equatable {
        case p2pkh, p2sh, p2wpkh, p2wsh, p2tr
    }

    struct Decoded: Sendable, Equatable {
        let kind: Kind
        let scriptPubKey: Data
    }

    private struct NetworkParams {
        let bech32HRP: String
        let p2pkhVersion: UInt8
        let p2shVersion: UInt8
    }

    private static func params(for network: SparkNetwork) -> NetworkParams {
        switch network {
        case .mainnet: return NetworkParams(bech32HRP: "bc", p2pkhVersion: 0x00, p2shVersion: 0x05)
        case .regtest: return NetworkParams(bech32HRP: "bcrt", p2pkhVersion: 0x6f, p2shVersion: 0xc4)
        }
    }

    /// The output script an address pays to. Throws `SparkError.invalidAddress` for anything that
    /// is not a well-formed address on `network`.
    static func scriptPubKey(for address: String, network: SparkNetwork) throws -> Data {
        try decode(address, network: network).scriptPubKey
    }

    static func decode(_ address: String, network: SparkNetwork) throws -> Decoded {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SparkError.invalidAddress("empty address") }
        let params = params(for: network)

        let lower = trimmed.lowercased()
        if lower.hasPrefix(params.bech32HRP + "1") {
            return try decodeSegwit(trimmed, expectedHRP: params.bech32HRP)
        }
        if lower.hasPrefix("bc1") || lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1") {
            throw SparkError.invalidAddress("address '\(trimmed)' is not for the \(network) network")
        }
        return try decodeBase58(trimmed, params: params, network: network)
    }

    private static func decodeSegwit(_ address: String, expectedHRP: String) throws -> Decoded {
        let hrp: String
        let words: [UInt8]
        let encoding: Bech32.Encoding
        do {
            (hrp, words, encoding) = try Bech32.decode(address, maxLength: 90)
        } catch let error as SparkError {
            throw SparkError.invalidAddress("'\(address)': \(error.localizedDescription)")
        }
        guard hrp == expectedHRP else {
            throw SparkError.invalidAddress("'\(address)' is not a \(expectedHRP) address")
        }
        guard let version = words.first else {
            throw SparkError.invalidAddress("'\(address)' has no witness version")
        }
        guard let program = Bech32.fromWords(Array(words.dropFirst())) else {
            throw SparkError.invalidAddress("'\(address)' has an invalid witness program encoding")
        }
        switch version {
        case 0:
            guard encoding == .bech32 else {
                throw SparkError.invalidAddress("'\(address)': witness v0 must use the bech32 checksum")
            }
            switch program.count {
            case 20: return Decoded(kind: .p2wpkh, scriptPubKey: Data([0x00, 0x14]) + program)
            case 32: return Decoded(kind: .p2wsh, scriptPubKey: Data([0x00, 0x20]) + program)
            default: throw SparkError.invalidAddress("'\(address)': witness v0 program must be 20 or 32 bytes")
            }
        case 1:
            guard encoding == .bech32m else {
                throw SparkError.invalidAddress("'\(address)': witness v1 must use the bech32m checksum")
            }
            guard program.count == 32 else {
                throw SparkError.invalidAddress("'\(address)': taproot program must be 32 bytes")
            }
            return Decoded(kind: .p2tr, scriptPubKey: Data([0x51, 0x20]) + program)
        default:
            throw SparkError.invalidAddress("'\(address)': unsupported witness version \(version)")
        }
    }

    private static func decodeBase58(_ address: String, params: NetworkParams, network: SparkNetwork) throws -> Decoded {
        guard let payload = Base58.decodeCheck(address) else {
            throw SparkError.invalidAddress("'\(address)' is not a valid Base58Check address")
        }
        guard payload.count == 21 else {
            throw SparkError.invalidAddress("'\(address)' has an unexpected payload length")
        }
        let version = payload[payload.startIndex]
        let hash = payload.dropFirst()
        switch version {
        case params.p2pkhVersion:
            return Decoded(kind: .p2pkh, scriptPubKey: Data([0x76, 0xa9, 0x14]) + hash + Data([0x88, 0xac]))
        case params.p2shVersion:
            return Decoded(kind: .p2sh, scriptPubKey: Data([0xa9, 0x14]) + hash + Data([0x87]))
        default:
            throw SparkError.invalidAddress("'\(address)' is not for the \(network) network")
        }
    }

    /// bech32m P2TR address for a 32-byte x-only output key.
    static func encodeP2TR(program: Data, network: SparkNetwork) throws -> String {
        guard program.count == 32 else {
            throw SparkError.invalidResponse("P2TR program must be 32 bytes")
        }
        guard let words = Bech32.convertBits(Array(program), fromBits: 8, toBits: 5, pad: true) else {
            throw SparkError.invalidResponse("Failed to encode P2TR program")
        }
        return Bech32.encode(hrp: params(for: network).bech32HRP, data: [0x01] + words, encoding: .bech32m)
    }

    /// P2TR address for an `OP_1 <32-byte>` output script.
    static func p2trAddress(scriptPubKey: Data, network: SparkNetwork) throws -> String {
        let bytes = [UInt8](scriptPubKey)
        guard bytes.count == 34, bytes[0] == 0x51, bytes[1] == 0x20 else {
            throw SparkError.invalidResponse("Output script is not P2TR (\(scriptPubKey.hexString))")
        }
        return try encodeP2TR(program: Data(bytes[2...]), network: network)
    }
}
