import CryptoKit
import Foundation
import SwiftProtobuf

/// The operators' deterministic hash of a protobuf message (`spark/common/protohash`, an object
/// hash over field numbers), which V3 token transactions are signed and identified by.
///
/// A message hashes as `SHA256("d" ‖ key ‖ value ‖ …)` over its fields in field-number order,
/// each key being `SHA256("i" ‖ field number as big-endian u64)`. Values hash by type: integers
/// and enums `SHA256("i" ‖ big-endian u64)`, `true` `SHA256("b" ‖ "1")`, strings
/// `SHA256("u" ‖ UTF-8)`, bytes `SHA256("r" ‖ bytes)`, doubles `SHA256("f" ‖ IEEE-754 bits)`,
/// repeated fields `SHA256("l" ‖ element hashes)` in order, nested messages recursively, and a
/// Timestamp or Duration as the list of its seconds and nanos. A scalar field holding its
/// default (0, false, "", no bytes) or an empty repeated field is left out, even when it was set
/// explicitly; a message field that is set is always hashed, even when empty.
///
/// Only what Spark's hashed messages use is supported: maps, groups and well-known types other
/// than Timestamp and Duration throw rather than risk a hash the operators would not compute.
enum ProtoHash {
    static func hash<M: Message>(_ message: M) throws -> Data {
        try hashMessage(message)
    }

    static func hashMessage<M: Message>(_ message: M) throws -> Data {
        switch M.protoMessageName {
        case Google_Protobuf_Timestamp.protoMessageName, Google_Protobuf_Duration.protoMessageName:
            var seconds: Int64 = 0
            var nanos: Int32 = 0
            if let timestamp = message as? Google_Protobuf_Timestamp {
                (seconds, nanos) = (timestamp.seconds, timestamp.nanos)
            } else if let duration = message as? Google_Protobuf_Duration {
                (seconds, nanos) = (duration.seconds, duration.nanos)
            }
            return list([int(seconds), int(Int64(nanos))])
        case let name where name.hasPrefix("google.protobuf."):
            throw SparkError.invalidArgument("protohash: \(name) is not supported")
        default:
            var visitor = FieldHasher()
            try message.traverse(visitor: &visitor)
            var data = Data("d".utf8)
            for field in visitor.fields.sorted(by: { $0.number < $1.number }) {
                data.append(int(Int64(field.number)))
                data.append(field.hash)
            }
            return Data(SHA256.hash(data: data))
        }
    }

    static func tagged(_ tag: String, _ bytes: Data) -> Data {
        Data(SHA256.hash(data: Data(tag.utf8) + bytes))
    }

    static func int(_ value: Int64) -> Data {
        uint(UInt64(bitPattern: value))
    }

    static func uint(_ value: UInt64) -> Data {
        tagged("i", withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    static func double(_ value: Double) -> Data {
        // -0.0 as 0.0, and every NaN as Go's `math.NaN()`.
        let bits = value.isNaN ? 0x7FF8_0000_0000_0001 : (value == 0 ? 0 : value.bitPattern)
        return tagged("f", withUnsafeBytes(of: bits.bigEndian) { Data($0) })
    }

    static func list(_ elements: [Data]) -> Data {
        Data(SHA256.hash(data: elements.reduce(into: Data("l".utf8)) { $0.append($1) }))
    }
}

/// Collects `(field number, value hash)` for the fields of one message that protohash includes.
private struct FieldHasher: Visitor {
    private(set) var fields: [(number: Int, hash: Data)] = []

    private mutating func add(_ number: Int, _ hash: Data) {
        fields.append((number, hash))
    }

    private mutating func addList(_ number: Int, _ elements: [Data]) {
        if !elements.isEmpty {
            add(number, ProtoHash.list(elements))
        }
    }

    // Singular fields. 32-bit, zigzag and fixed-width integers and floats reach these through
    // SwiftProtobuf's widening defaults, as Go widens them to 64 bits.

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {
        if value != 0 { add(fieldNumber, ProtoHash.double(value)) }
    }

    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {
        if value != 0 { add(fieldNumber, ProtoHash.int(value)) }
    }

    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        if value != 0 { add(fieldNumber, ProtoHash.uint(value)) }
    }

    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        if value { add(fieldNumber, ProtoHash.tagged("b", Data("1".utf8))) }
    }

    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        if !value.isEmpty { add(fieldNumber, ProtoHash.tagged("u", Data(value.utf8))) }
    }

    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        if !value.isEmpty { add(fieldNumber, ProtoHash.tagged("r", value)) }
    }

    mutating func visitSingularEnumField<E: Enum>(value: E, fieldNumber: Int) throws {
        if value.rawValue != 0 { add(fieldNumber, ProtoHash.int(Int64(value.rawValue))) }
    }

    mutating func visitSingularMessageField<M: Message>(value: M, fieldNumber: Int) throws {
        add(fieldNumber, try ProtoHash.hashMessage(value))
    }

    mutating func visitSingularGroupField<G: Message>(value: G, fieldNumber: Int) throws {
        throw SparkError.invalidArgument("protohash: group field \(fieldNumber) is not supported")
    }

    // Repeated fields hash as one list, elements in order and none left out. Packed fields reach
    // these through SwiftProtobuf's defaults.

    mutating func visitRepeatedFloatField(value: [Float], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.double(Double($0)) })
    }

    mutating func visitRepeatedDoubleField(value: [Double], fieldNumber: Int) throws {
        addList(fieldNumber, value.map(ProtoHash.double))
    }

    mutating func visitRepeatedInt32Field(value: [Int32], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.int(Int64($0)) })
    }

    mutating func visitRepeatedInt64Field(value: [Int64], fieldNumber: Int) throws {
        addList(fieldNumber, value.map(ProtoHash.int))
    }

    mutating func visitRepeatedUInt32Field(value: [UInt32], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.uint(UInt64($0)) })
    }

    mutating func visitRepeatedUInt64Field(value: [UInt64], fieldNumber: Int) throws {
        addList(fieldNumber, value.map(ProtoHash.uint))
    }

    mutating func visitRepeatedSInt32Field(value: [Int32], fieldNumber: Int) throws {
        try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSInt64Field(value: [Int64], fieldNumber: Int) throws {
        try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedFixed32Field(value: [UInt32], fieldNumber: Int) throws {
        try visitRepeatedUInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedFixed64Field(value: [UInt64], fieldNumber: Int) throws {
        try visitRepeatedUInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSFixed32Field(value: [Int32], fieldNumber: Int) throws {
        try visitRepeatedInt32Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedSFixed64Field(value: [Int64], fieldNumber: Int) throws {
        try visitRepeatedInt64Field(value: value, fieldNumber: fieldNumber)
    }

    mutating func visitRepeatedBoolField(value: [Bool], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.tagged("b", Data(($0 ? "1" : "0").utf8)) })
    }

    mutating func visitRepeatedStringField(value: [String], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.tagged("u", Data($0.utf8)) })
    }

    mutating func visitRepeatedBytesField(value: [Data], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.tagged("r", $0) })
    }

    mutating func visitRepeatedEnumField<E: Enum>(value: [E], fieldNumber: Int) throws {
        addList(fieldNumber, value.map { ProtoHash.int(Int64($0.rawValue)) })
    }

    mutating func visitRepeatedMessageField<M: Message>(value: [M], fieldNumber: Int) throws {
        addList(fieldNumber, try value.map { try ProtoHash.hashMessage($0) })
    }

    mutating func visitRepeatedGroupField<G: Message>(value: [G], fieldNumber: Int) throws {
        throw SparkError.invalidArgument("protohash: group field \(fieldNumber) is not supported")
    }

    // Maps are not in any message Spark hashes.

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        throw SparkError.invalidArgument("protohash: map field \(fieldNumber) is not supported")
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {
        throw SparkError.invalidArgument("protohash: map field \(fieldNumber) is not supported")
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        throw SparkError.invalidArgument("protohash: map field \(fieldNumber) is not supported")
    }

    // The operators hash the fields their descriptors declare: unknown fields and extensions are
    // not part of the hash.

    mutating func visitExtensionFields(fields: ExtensionFieldValueSet, start: Int, end: Int) throws {}

    mutating func visitUnknown(bytes: Data) throws {}
}
