import Foundation

/// Bounds-checked reader over raw bytes.
///
/// Every read throws `SparkError.malformedTransaction` instead of trapping when the input is
/// shorter than expected, so bytes received from an operator, the SSP, or a block explorer can
/// never crash the host application.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0
    private let context: String

    init(_ data: Data, context: String) {
        self.bytes = [UInt8](data)
        self.context = context
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw truncated(needed: 1) }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw truncated(needed: count) }
        let slice = Data(bytes[offset..<offset + count])
        offset += count
        return slice
    }

    mutating func readUInt16LE() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[b.startIndex]) | (UInt16(b[b.startIndex + 1]) << 8)
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let b = try readBytes(4)
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(b[b.startIndex + i]) << (8 * UInt32(i)) }
        return value
    }

    mutating func readUInt64LE() throws -> UInt64 {
        let b = try readBytes(8)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(b[b.startIndex + i]) << (8 * UInt64(i)) }
        return value
    }

    /// Bitcoin CompactSize integer.
    mutating func readVarInt() throws -> UInt64 {
        let first = try readByte()
        switch first {
        case 0..<0xFD: return UInt64(first)
        case 0xFD: return UInt64(try readUInt16LE())
        case 0xFE: return UInt64(try readUInt32LE())
        default: return try readUInt64LE()
        }
    }

    /// CompactSize length prefix followed by that many bytes. The length is checked against the
    /// bytes actually remaining before anything is allocated.
    mutating func readVarBytes() throws -> Data {
        let length = try readVarInt()
        guard length <= UInt64(remaining) else { throw truncated(needed: Int(min(length, UInt64(Int.max)))) }
        return try readBytes(Int(length))
    }

    func expectEnd() throws {
        guard isAtEnd else {
            throw SparkError.malformedTransaction("\(context): \(remaining) trailing byte(s) after the end of the transaction")
        }
    }

    private func truncated(needed: Int) -> SparkError {
        .malformedTransaction("\(context): truncated at byte \(offset), needed \(needed) more byte(s) but only \(remaining) remain")
    }
}

/// Bitcoin CompactSize encoding.
func encodeVarInt(_ value: UInt64) -> Data {
    if value < 0xFD {
        return Data([UInt8(value)])
    } else if value <= 0xFFFF {
        var out = Data([0xFD])
        var v = UInt16(value).littleEndian
        out.append(Data(bytes: &v, count: 2))
        return out
    } else if value <= 0xFFFF_FFFF {
        var out = Data([0xFE])
        var v = UInt32(value).littleEndian
        out.append(Data(bytes: &v, count: 4))
        return out
    } else {
        var out = Data([0xFF])
        var v = value.littleEndian
        out.append(Data(bytes: &v, count: 8))
        return out
    }
}
