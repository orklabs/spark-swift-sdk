import Foundation
import CryptoKit

/// A parsed Bitcoin transaction. Parsing is fully bounds-checked and never traps on malformed
/// input; every structural problem surfaces as `SparkError.malformedTransaction`.
///
/// This replaces the ad-hoc offset arithmetic the SDK previously used on transaction bytes
/// received from operators, the SSP, and the block explorer.
struct RawTransaction: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        /// Previous output's txid in internal (little-endian) byte order.
        var previousTxid: Data
        var previousIndex: UInt32
        var scriptSig: Data
        var sequence: UInt32
        var witness: [Data]

        init(previousTxid: Data, previousIndex: UInt32, scriptSig: Data = Data(),
             sequence: UInt32 = 0xFFFF_FFFF, witness: [Data] = []) {
            self.previousTxid = previousTxid
            self.previousIndex = previousIndex
            self.scriptSig = scriptSig
            self.sequence = sequence
            self.witness = witness
        }
    }

    struct Output: Equatable, Sendable {
        var value: UInt64
        var scriptPubKey: Data
    }

    var version: UInt32
    var inputs: [Input]
    var outputs: [Output]
    var locktime: UInt32
    /// `true` when the bytes carried the segwit marker and flag. Preserved so that
    /// re-serialisation reproduces the input format.
    var hasWitnessSerialization: Bool

    /// Sanity caps so a hostile response cannot make the parser allocate absurd amounts before
    /// the byte-level bounds checks fire.
    private static let maxItems = 100_000

    static func parse(_ data: Data, context: String = "transaction") throws -> RawTransaction {
        var reader = ByteReader(data, context: context)
        let version = try reader.readUInt32LE()

        var witnessSerialization = false
        var inputCount = try reader.readVarInt()
        if inputCount == 0, reader.remaining > 0 {
            let flag = try reader.readByte()
            guard flag == 0x01 else {
                throw SparkError.malformedTransaction("\(context): unknown segwit flag \(flag)")
            }
            witnessSerialization = true
            inputCount = try reader.readVarInt()
        }
        guard inputCount <= UInt64(maxItems) else {
            throw SparkError.malformedTransaction("\(context): implausible input count \(inputCount)")
        }

        var inputs: [Input] = []
        inputs.reserveCapacity(Int(inputCount))
        for _ in 0..<inputCount {
            let txid = try reader.readBytes(32)
            let index = try reader.readUInt32LE()
            let script = try reader.readVarBytes()
            let sequence = try reader.readUInt32LE()
            inputs.append(Input(previousTxid: txid, previousIndex: index, scriptSig: script, sequence: sequence))
        }

        let outputCount = try reader.readVarInt()
        guard outputCount <= UInt64(maxItems) else {
            throw SparkError.malformedTransaction("\(context): implausible output count \(outputCount)")
        }
        var outputs: [Output] = []
        outputs.reserveCapacity(Int(outputCount))
        for _ in 0..<outputCount {
            let value = try reader.readUInt64LE()
            let script = try reader.readVarBytes()
            outputs.append(Output(value: value, scriptPubKey: script))
        }

        if witnessSerialization {
            for i in 0..<inputs.count {
                let itemCount = try reader.readVarInt()
                guard itemCount <= UInt64(maxItems) else {
                    throw SparkError.malformedTransaction("\(context): implausible witness item count \(itemCount)")
                }
                var items: [Data] = []
                for _ in 0..<itemCount {
                    items.append(try reader.readVarBytes())
                }
                inputs[i].witness = items
            }
        }

        let locktime = try reader.readUInt32LE()
        try reader.expectEnd()

        return RawTransaction(
            version: version,
            inputs: inputs,
            outputs: outputs,
            locktime: locktime,
            hasWitnessSerialization: witnessSerialization
        )
    }

    /// Serialise. `includeWitness` is only honoured when the transaction uses witness
    /// serialisation; the non-witness form is what the txid commits to.
    func serialized(includeWitness: Bool) -> Data {
        var out = Data()
        var v = version.littleEndian
        out.append(Data(bytes: &v, count: 4))
        let withWitness = includeWitness && hasWitnessSerialization
        if withWitness {
            out.append(contentsOf: [0x00, 0x01])
        }
        out.append(encodeVarInt(UInt64(inputs.count)))
        for input in inputs {
            out.append(input.previousTxid)
            var idx = input.previousIndex.littleEndian
            out.append(Data(bytes: &idx, count: 4))
            out.append(encodeVarInt(UInt64(input.scriptSig.count)))
            out.append(input.scriptSig)
            var seq = input.sequence.littleEndian
            out.append(Data(bytes: &seq, count: 4))
        }
        out.append(encodeVarInt(UInt64(outputs.count)))
        for output in outputs {
            var value = output.value.littleEndian
            out.append(Data(bytes: &value, count: 8))
            out.append(encodeVarInt(UInt64(output.scriptPubKey.count)))
            out.append(output.scriptPubKey)
        }
        if withWitness {
            for input in inputs {
                out.append(encodeVarInt(UInt64(input.witness.count)))
                for item in input.witness {
                    out.append(encodeVarInt(UInt64(item.count)))
                    out.append(item)
                }
            }
        }
        var lt = locktime.littleEndian
        out.append(Data(bytes: &lt, count: 4))
        return out
    }

    /// Transaction id in internal (little-endian) byte order — the form used in input prevouts.
    var txid: Data {
        let stripped = serialized(includeWitness: false)
        let first = Data(CryptoKit.SHA256.hash(data: stripped))
        return Data(CryptoKit.SHA256.hash(data: first))
    }

    /// Transaction id as the conventional display hex (big-endian).
    var txidHex: String {
        Data(txid.reversed()).hexString
    }

    func output(at vout: UInt32) throws -> Output {
        guard vout < UInt32(outputs.count) else {
            throw SparkError.malformedTransaction("vout \(vout) out of range: transaction has \(outputs.count) output(s)")
        }
        return outputs[Int(vout)]
    }

    /// nSequence of the first input. Spark encodes leaf timelocks here.
    var firstInputSequence: UInt32 {
        get throws {
            guard let first = inputs.first else {
                throw SparkError.malformedTransaction("transaction has no inputs")
            }
            return first.sequence
        }
    }

    /// Whether two txids refer to the same transaction, accepting either byte order.
    /// Mirrors the operators' accept-both tolerance for ids that arrive as display hex.
    static func txidMatches(_ a: Data, _ b: Data) -> Bool {
        guard a.count == 32, b.count == 32 else { return false }
        return a == b || a == Data(b.reversed())
    }
}
