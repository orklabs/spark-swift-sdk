import Foundation
import CryptoKit

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

extension Date {
    var unixTimestamp: Int64 {
        Int64(timeIntervalSince1970)
    }
}

// MARK: - BIP-340 Tagged Hash (matching TS SDK's hashstructure.ts)

struct SparkHasher {
    private var data: Data

    init(tag: [String]) {
        // Serialize the tag: for each component, 8-byte BE length + UTF-8 bytes
        var tagData = Data()
        for component in tag {
            let componentBytes = Data(component.utf8)
            var length = UInt64(componentBytes.count).bigEndian
            tagData.append(Data(bytes: &length, count: 8))
            tagData.append(componentBytes)
        }
        // BIP-340 tagged hash: tagHash = SHA256(serializedTag), then prefix with tagHash || tagHash
        let tagHash = Data(CryptoKit.SHA256.hash(data: tagData))
        data = Data()
        data.append(tagHash)
        data.append(tagHash)
    }

    mutating func addBytes(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        data.append(Data(bytes: &length, count: 8))
        data.append(value)
    }

    mutating func addString(_ value: String) {
        addBytes(Data(value.utf8))
    }

    mutating func addUint32(_ value: UInt32) {
        // Promoted to uint64 big-endian per TS SDK
        var val = UInt64(value).bigEndian
        let valData = Data(bytes: &val, count: 8)
        addBytes(valData)
    }

    mutating func addUint64(_ value: UInt64) {
        // Length-prefixed uint64: 8-byte length prefix (always 8) + 8-byte value
        var valBE = value.bigEndian
        let valData = Data(bytes: &valBE, count: 8)
        addBytes(valData)
    }

    mutating func addMapStringToBytes(_ map: [String: Data]) {
        // Entry count as length-prefixed uint64 (matching C# AddUInt64)
        addUint64(UInt64(map.count))

        // Sort by key bytes (lexicographic on UTF-8)
        let sorted = map.sorted { Data($0.key.utf8).lexicographicallyPrecedes(Data($1.key.utf8)) }
        for (key, value) in sorted {
            addBytes(Data(key.utf8))
            addBytes(value)
        }
    }

    func hash() -> Data {
        Data(CryptoKit.SHA256.hash(data: data))
    }
}

// MARK: - Secp256k1 Scalar Arithmetic

/// secp256k1 curve order n
private let secp256k1N: [UInt64] = [
    0xBFD25E8CD0364141,
    0xBAAEDCE6AF48A03B,
    0xFFFFFFFFFFFFFFFE,
    0xFFFFFFFFFFFFFFFF,
]

private func parseScalar(_ data: Data) -> [UInt64] {
    var limbs: [UInt64] = [0, 0, 0, 0]
    for i in 0..<4 {
        var val: UInt64 = 0
        for j in 0..<8 { val = (val << 8) | UInt64(data[data.startIndex + i * 8 + j]) }
        limbs[3 - i] = val
    }
    return limbs
}

private func serializeScalar(_ limbs: [UInt64]) -> Data {
    var output = Data(count: 32)
    for i in 0..<4 {
        let val = limbs[3 - i]
        for j in 0..<8 { output[i * 8 + j] = UInt8((val >> (56 - j * 8)) & 0xFF) }
    }
    return output
}

/// Compute (a - b) mod n over the secp256k1 curve order
func subtractPrivateKeys(_ a: Data, _ b: Data) throws -> Data {
    // (n - b + a) mod n
    let aLimbs = parseScalar(a)
    let bLimbs = parseScalar(b)

    // Compute n - b
    var nMinusB: [UInt64] = [0, 0, 0, 0]
    var borrow: UInt64 = 0
    for i in 0..<4 {
        let (d1, b1) = secp256k1N[i].subtractingReportingOverflow(bLimbs[i])
        let (d2, b2) = d1.subtractingReportingOverflow(borrow)
        nMinusB[i] = d2
        borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
    }

    // Add a + (n - b)
    var result: [UInt64] = [0, 0, 0, 0]
    var carry: UInt64 = 0
    for i in 0..<4 {
        let (s1, c1) = aLimbs[i].addingReportingOverflow(nMinusB[i])
        let (s2, c2) = s1.addingReportingOverflow(carry)
        result[i] = s2
        carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
    }

    // Reduce mod n if needed
    var needsReduce = carry > 0
    if !needsReduce {
        for i in (0..<4).reversed() {
            if result[i] > secp256k1N[i] { needsReduce = true; break }
            if result[i] < secp256k1N[i] { break }
        }
    }

    if needsReduce {
        borrow = 0
        for i in 0..<4 {
            let (d1, b1) = result[i].subtractingReportingOverflow(secp256k1N[i])
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            result[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
    }

    return serializeScalar(result)
}

func decodeBase64URL(_ string: String) -> Data? {
    var s = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    switch s.count % 4 {
    case 2: s += "=="
    case 3: s += "="
    default: break
    }
    return Data(base64Encoded: s)
}
