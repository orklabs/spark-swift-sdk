import Foundation

/// Bech32 (BIP-173) and Bech32m (BIP-350) encoding and decoding.
///
/// Used for Spark addresses, token identifiers, Bitcoin segwit addresses, and BOLT-11 invoices.
/// The decoder enforces the character-set, case, and checksum rules of both BIPs; callers decide
/// which encoding they require for a given payload.
enum Bech32 {
    enum Encoding: Sendable, Equatable {
        case bech32
        case bech32m
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charsetMap: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in charset.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    private static let bech32Const: UInt32 = 1
    private static let bech32mConst: UInt32 = 0x2bc830a3

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 where ((b >> i) & 1) != 0 {
                chk ^= gen[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result: [UInt8] = []
        for c in hrp.unicodeScalars { result.append(UInt8(c.value >> 5)) }
        result.append(0)
        for c in hrp.unicodeScalars { result.append(UInt8(c.value & 31)) }
        return result
    }

    private static func checksumConstant(_ encoding: Encoding) -> UInt32 {
        switch encoding {
        case .bech32: return bech32Const
        case .bech32m: return bech32mConst
        }
    }

    private static func createChecksum(_ hrp: String, _ data: [UInt8], encoding: Encoding) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let polymodValue = polymod(values) ^ checksumConstant(encoding)
        return (0..<6).map { UInt8((polymodValue >> (5 * (5 - $0))) & 31) }
    }

    /// Encode 5-bit words with the given checksum variant. The HRP is emitted as given.
    static func encode(hrp: String, data: [UInt8], encoding: Encoding) -> String {
        let combined = data + createChecksum(hrp, data, encoding: encoding)
        var result = hrp + "1"
        for d in combined {
            result.append(charset[Int(d)])
        }
        return result
    }

    /// Decode a bech32 or bech32m string and report which checksum matched.
    ///
    /// - Parameter maxLength: BIP-173 caps addresses at 90 characters. Pass `nil` for payloads
    ///   without a length limit (BOLT-11 invoices, Spark addresses).
    static func decode(_ string: String, maxLength: Int? = 90) throws -> (hrp: String, data: [UInt8], encoding: Encoding) {
        if let maxLength, string.count > maxLength {
            throw SparkError.invalidResponse("Bech32 string longer than \(maxLength) characters")
        }
        let hasLower = string.contains { $0.isLowercase }
        let hasUpper = string.contains { $0.isUppercase }
        if hasLower && hasUpper {
            throw SparkError.invalidResponse("Bech32 string mixes upper and lower case")
        }
        let lower = string.lowercased()
        guard let sepIndex = lower.lastIndex(of: "1") else {
            throw SparkError.invalidResponse("No separator in bech32 string")
        }
        let hrp = String(lower[lower.startIndex..<sepIndex])
        guard !hrp.isEmpty else {
            throw SparkError.invalidResponse("Empty human-readable part in bech32 string")
        }
        for scalar in hrp.unicodeScalars where scalar.value < 33 || scalar.value > 126 {
            throw SparkError.invalidResponse("Invalid character in bech32 human-readable part")
        }
        let dataStr = lower[lower.index(after: sepIndex)...]
        guard dataStr.count >= 6 else {
            throw SparkError.invalidResponse("Bech32 data too short")
        }

        var data: [UInt8] = []
        data.reserveCapacity(dataStr.count)
        for c in dataStr {
            guard let val = charsetMap[c] else {
                throw SparkError.invalidResponse("Invalid bech32 character: \(c)")
            }
            data.append(val)
        }

        let check = polymod(hrpExpand(hrp) + data)
        let encoding: Encoding
        if check == bech32mConst {
            encoding = .bech32m
        } else if check == bech32Const {
            encoding = .bech32
        } else {
            throw SparkError.invalidResponse("Invalid bech32 checksum")
        }
        return (hrp, Array(data.dropLast(6)), encoding)
    }

    /// Convert between bit widths (e.g. 8-bit bytes to 5-bit words and back).
    static func convertBits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc: Int = 0
        var bits: Int = 0
        var result: [UInt8] = []
        let maxv = (1 << toBits) - 1
        for value in data {
            guard Int(value) >> fromBits == 0 else { return nil }
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0 {
            return nil
        }
        return result
    }

    static func toWords(_ data: Data) -> [UInt8] {
        convertBits(Array(data), fromBits: 8, toBits: 5, pad: true) ?? []
    }

    static func fromWords(_ words: [UInt8]) -> Data? {
        guard let bytes = convertBits(words, fromBits: 5, toBits: 8, pad: false) else { return nil }
        return Data(bytes)
    }
}

/// Bech32m-only conveniences for Spark addresses and token identifiers.
enum Bech32m {
    /// Encode data as a bech32m string. Spark payloads have no length limit.
    static func encode(hrp: String, data: [UInt8], limit: Int = 1024) -> String {
        Bech32.encode(hrp: hrp, data: data, encoding: .bech32m)
    }

    /// Decode a string that must carry a bech32m checksum. Returns (hrp, 5-bit words).
    static func decodeBech32m(_ str: String) throws -> (hrp: String, data: [UInt8]) {
        let (hrp, data, encoding) = try Bech32.decode(str, maxLength: nil)
        guard encoding == .bech32m else {
            throw SparkError.invalidResponse("Invalid bech32m checksum")
        }
        return (hrp, data)
    }

    static func convertBits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        Bech32.convertBits(data, fromBits: fromBits, toBits: toBits, pad: pad)
    }

    static func toWords(_ data: Data) -> [UInt8] {
        Bech32.toWords(data)
    }

    static func fromWords(_ words: [UInt8]) -> Data? {
        Bech32.fromWords(words)
    }
}
