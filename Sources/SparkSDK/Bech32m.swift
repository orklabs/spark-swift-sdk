import Foundation

/// Bech32m encoding/decoding for Spark addresses and Bitcoin addresses.
enum Bech32m {
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private static let charsetArray = Array(charset)
    private static let charsetMap: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in charset.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    private static let bech32mConst: UInt32 = 0x2bc830a3

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 {
                if ((b >> i) & 1) != 0 {
                    chk ^= gen[i]
                }
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

    private static func createChecksum(_ hrp: String, _ data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let polymodValue = polymod(values) ^ bech32mConst
        var checksum: [UInt8] = []
        for i in 0..<6 {
            checksum.append(UInt8((polymodValue >> (5 * (5 - i))) & 31))
        }
        return checksum
    }

    private static func verifyChecksum(_ hrp: String, _ data: [UInt8]) -> Bool {
        return polymod(hrpExpand(hrp) + data) == bech32mConst
    }

    /// Encode data as bech32m string
    static func encode(hrp: String, data: [UInt8], limit: Int = 1024) -> String {
        let checksum = createChecksum(hrp, data)
        let combined = data + checksum
        var result = hrp + "1"
        for d in combined {
            result.append(charsetArray[Int(d)])
        }
        return result
    }

    /// Decode a bech32/bech32m string. Returns (hrp, data) where data is 5-bit values.
    static func decodeBech32m(_ str: String) throws -> (hrp: String, data: [UInt8]) {
        let lower = str.lowercased()
        guard let sepIndex = lower.lastIndex(of: "1") else {
            throw SparkError.invalidResponse("No separator in bech32m string")
        }
        let hrp = String(lower[lower.startIndex..<sepIndex])
        let dataStr = String(lower[lower.index(after: sepIndex)...])
        guard dataStr.count >= 6 else {
            throw SparkError.invalidResponse("Bech32m data too short")
        }

        var data: [UInt8] = []
        for c in dataStr {
            guard let val = charsetMap[c] else {
                throw SparkError.invalidResponse("Invalid bech32m character: \(c)")
            }
            data.append(val)
        }

        guard verifyChecksum(hrp, data) else {
            throw SparkError.invalidResponse("Invalid bech32m checksum")
        }

        return (hrp, Array(data.dropLast(6)))
    }

    /// Convert between bit widths (e.g., 8-bit to 5-bit or vice versa)
    static func convertBits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc: Int = 0
        var bits: Int = 0
        var result: [UInt8] = []
        let maxv = (1 << toBits) - 1
        for value in data {
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

    /// Convert bytes to 5-bit words for bech32m encoding
    static func toWords(_ data: Data) -> [UInt8] {
        convertBits(Array(data), fromBits: 8, toBits: 5, pad: true) ?? []
    }

    /// Convert 5-bit words back to bytes
    static func fromWords(_ words: [UInt8]) -> Data? {
        guard let bytes = convertBits(words, fromBits: 5, toBits: 8, pad: false) else { return nil }
        return Data(bytes)
    }

    /// Decode a Bitcoin segwit address (bech32/bech32m) to (witnessVersion, program)
    static func decode(_ address: String) throws -> (UInt8, Data) {
        let (hrp, data) = try decodeBech32m(address)
        guard !data.isEmpty else {
            throw SparkError.invalidResponse("Empty bech32m data")
        }
        let witnessVersion = data[0]
        guard let program = fromWords(Array(data.dropFirst())) else {
            throw SparkError.invalidResponse("Invalid witness program")
        }
        _ = hrp // validated by checksum
        return (witnessVersion, program)
    }
}
