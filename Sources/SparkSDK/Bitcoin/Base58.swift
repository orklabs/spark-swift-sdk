import Foundation
import CryptoKit

/// Base58 and Base58Check decoding (legacy P2PKH / P2SH addresses).
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let alphabetMap: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        return map
    }()

    /// Decode a base58 string to bytes, preserving leading zero bytes.
    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty, string.count <= 128 else { return nil }
        var bytes: [UInt8] = []  // big-endian magnitude
        for c in string {
            guard let digit = alphabetMap[c] else { return nil }
            var carry = Int(digit)
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                carry += 58 * Int(bytes[i])
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let leadingOnes = string.prefix { $0 == "1" }.count
        return Data(repeating: 0, count: leadingOnes) + Data(bytes)
    }

    /// Decode a Base58Check string, verifying the 4-byte double-SHA256 checksum.
    /// Returns the payload including its version byte.
    static func decodeCheck(_ string: String) -> Data? {
        guard let decoded = decode(string), decoded.count >= 5 else { return nil }
        let payload = decoded.prefix(decoded.count - 4)
        let checksum = decoded.suffix(4)
        let first = Data(CryptoKit.SHA256.hash(data: payload))
        let second = Data(CryptoKit.SHA256.hash(data: first))
        guard second.prefix(4) == checksum else { return nil }
        return Data(payload)
    }
}
