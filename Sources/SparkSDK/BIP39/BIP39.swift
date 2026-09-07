import Foundation
import CryptoKit

/// BIP-39 mnemonic validation (English wordlist).
///
/// A mnemonic must be 12, 15, 18, 21 or 24 lower-case English words separated by single
/// spaces, and its embedded checksum must match. Without this check a mistyped phrase silently
/// derives a different, empty wallet — and funds deposited to it can only be recovered with the
/// exact typo.
enum BIP39 {
    private static let index: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, word) in BIP39Wordlist.english.enumerated() { map[word] = i }
        return map
    }()

    static let validWordCounts: Set<Int> = [12, 15, 18, 21, 24]

    /// Throws `SparkError.invalidMnemonic` describing the first problem found.
    static func validate(_ mnemonic: String) throws {
        let normalized = mnemonic.decomposedStringWithCompatibilityMapping
        let words = normalized.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard validWordCounts.contains(words.count) else {
            throw SparkError.invalidMnemonic("expected 12, 15, 18, 21 or 24 words separated by single spaces, got \(words.count)")
        }
        var indices: [Int] = []
        indices.reserveCapacity(words.count)
        for (position, word) in words.enumerated() {
            guard let i = index[word] else {
                if word.isEmpty {
                    throw SparkError.invalidMnemonic("empty word at position \(position + 1) (double space or leading/trailing space)")
                }
                if index[word.lowercased()] != nil {
                    throw SparkError.invalidMnemonic("word \(position + 1) must be lower case")
                }
                throw SparkError.invalidMnemonic("word \(position + 1) is not in the BIP-39 English wordlist")
            }
            indices.append(i)
        }

        // Concatenate 11-bit indices; the last count/3 bits are the checksum of the entropy.
        let totalBits = words.count * 11
        let checksumBits = words.count / 3
        let entropyBits = totalBits - checksumBits
        var bits = [Bool]()
        bits.reserveCapacity(totalBits)
        for i in indices {
            for shift in stride(from: 10, through: 0, by: -1) {
                bits.append((i >> shift) & 1 == 1)
            }
        }
        var entropy = Data(count: entropyBits / 8)
        for bit in 0..<entropyBits where bits[bit] {
            entropy[bit / 8] |= UInt8(0x80 >> (bit % 8))
        }
        let hash = Data(CryptoKit.SHA256.hash(data: entropy))
        for bit in 0..<checksumBits {
            let expected = (hash[bit / 8] >> (7 - UInt8(bit % 8))) & 1 == 1
            guard bits[entropyBits + bit] == expected else {
                throw SparkError.invalidMnemonic("checksum mismatch — one or more words are wrong")
            }
        }
    }

    static func isValid(_ mnemonic: String) -> Bool {
        (try? validate(mnemonic)) != nil
    }
}
