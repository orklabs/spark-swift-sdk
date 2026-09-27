import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
@testable import SparkSDK

/// `ProtoHash` against the operators' cross-language vectors, which the Go operators, the
/// TypeScript SDK and the Rust token primitives all check: `spark/testdata/*.json` in
/// buildonspark/spark @ 0b3a32a, copied unchanged into `Vectors/`.
@Suite("Protohash")
struct ProtoHashTests {
    struct Vector {
        let name: String
        let expectedHash: String
        /// The case's message, as canonical Protobuf JSON.
        let json: String
    }

    static func vectors(_ file: String, message key: String) throws -> [Vector] {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Vectors"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["testCases"] as? [[String: Any]])
        return try cases.map { testCase in
            let message = try #require(testCase[key])
            return Vector(
                name: try #require(testCase["name"] as? String),
                expectedHash: try #require(testCase["expectedHash"] as? String),
                json: try #require(String(bytes: try JSONSerialization.data(withJSONObject: message), encoding: .utf8))
            )
        }
    }

    @Test("Partial token transactions")
    func partialTokenTransactions() throws {
        let vectors = try Self.vectors("partial_token_transaction_hash_cases", message: "partialTokenTransaction")
        #expect(vectors.count == 4)
        for vector in vectors {
            let transaction = try SparkToken_PartialTokenTransaction(jsonString: vector.json)
            #expect(try ProtoHash.hash(transaction).hexString == vector.expectedHash, Comment(rawValue: vector.name))
        }
    }

    @Test("V3 token transactions, hashed as the partial or the final transaction")
    func tokenTransactionsV3() throws {
        let vectors = try Self.vectors("token_transaction_v3_hash_cases", message: "tokenTransaction")
        #expect(vectors.count == 13)
        for vector in vectors {
            let transaction = try SparkToken_TokenTransaction(jsonString: vector.json)
            let hash = vector.name.contains("partial")
                ? try ProtoHash.hash(Self.partial(transaction))
                : try ProtoHash.hash(Self.final(transaction))
            #expect(hash.hexString == vector.expectedHash, Comment(rawValue: vector.name))
        }
    }

    @Test("Spark invoice fields")
    func sparkInvoiceFields() throws {
        let vectors = try Self.vectors("invoice_hash_cases", message: "sparkInvoiceFields")
        #expect(vectors.count == 12)
        for vector in vectors {
            let fields = try Spark_SparkInvoiceFields(jsonString: vector.json)
            #expect(try ProtoHash.hash(fields).hexString == vector.expectedHash, Comment(rawValue: vector.name))
        }
    }

    @Test("A default scalar is left out even when set; a set message is hashed even when empty")
    func presence() throws {
        var explicitZero = SparkToken_TokenOutput()
        explicitZero.ownerPublicKey = Data(repeating: 2, count: 33)
        explicitZero.withdrawBondSats = 0
        explicitZero.tokenIdentifier = Data()
        var unset = SparkToken_TokenOutput()
        unset.ownerPublicKey = Data(repeating: 2, count: 33)
        #expect(try ProtoHash.hash(explicitZero) == ProtoHash.hash(unset))

        var withEmptyMetadata = SparkToken_PartialTokenTransaction()
        withEmptyMetadata.tokenTransactionMetadata = SparkToken_TokenTransactionMetadata()
        #expect(try ProtoHash.hash(withEmptyMetadata) != ProtoHash.hash(SparkToken_PartialTokenTransaction()))
    }

    @Test("Hashes by the rules: an empty message, a Timestamp, and list order")
    func rules() throws {
        let sha = { (data: Data) in Data(SHA256.hash(data: data)) }
        let zeroInt = sha(Data("i".utf8) + Data(count: 8))
        #expect(try ProtoHash.hash(SparkToken_TokenTransferInput()) == sha(Data("d".utf8)))
        #expect(try ProtoHash.hash(Google_Protobuf_Timestamp(seconds: 0, nanos: 0)) == sha(Data("l".utf8) + zeroInt + zeroInt))

        var ascending = SparkToken_TokenTransactionMetadata()
        ascending.sparkOperatorIdentityPublicKeys = [Data([2]), Data([3])]
        var descending = ascending
        descending.sparkOperatorIdentityPublicKeys.reverse()
        #expect(try ProtoHash.hash(ascending) != ProtoHash.hash(descending))
    }

    @Test("Well-known types the operators' hashed messages do not use are refused")
    func unsupported() {
        #expect(throws: SparkError.self) { try ProtoHash.hash(Google_Protobuf_BoolValue(false)) }
        #expect(throws: SparkError.self) { try ProtoHash.hash(Google_Protobuf_Struct()) }
        #expect(throws: SparkError.self) { try ProtoHash.hash(Google_Protobuf_Any()) }
    }
}

/// The operators' conversions from the legacy transaction shape (`ConvertV2TxShapeToPartial` and
/// `ConvertV2TxShapeToFinal` in `so/protoconverter`), which their V3 vectors hash through.
extension ProtoHashTests {
    static func metadata(_ legacy: SparkToken_TokenTransaction) -> SparkToken_TokenTransactionMetadata {
        var metadata = SparkToken_TokenTransactionMetadata()
        metadata.sparkOperatorIdentityPublicKeys = legacy.sparkOperatorIdentityPublicKeys
        metadata.network = legacy.network
        if legacy.hasClientCreatedTimestamp {
            metadata.clientCreatedTimestamp = legacy.clientCreatedTimestamp
        }
        metadata.invoiceAttachments = legacy.invoiceAttachments
        metadata.validityDurationSeconds = legacy.validityDurationSeconds
        return metadata
    }

    static func partialOutput(_ output: SparkToken_TokenOutput) -> SparkToken_PartialTokenOutput {
        var partial = SparkToken_PartialTokenOutput()
        partial.ownerPublicKey = output.ownerPublicKey
        partial.withdrawBondSats = output.withdrawBondSats
        partial.withdrawRelativeBlockLocktime = output.withdrawRelativeBlockLocktime
        partial.tokenIdentifier = output.tokenIdentifier
        partial.tokenAmount = output.tokenAmount
        return partial
    }

    static func partial(_ legacy: SparkToken_TokenTransaction) -> SparkToken_PartialTokenTransaction {
        var partial = SparkToken_PartialTokenTransaction()
        partial.version = legacy.version
        partial.tokenTransactionMetadata = metadata(legacy)
        if legacy.hasExecuteBefore {
            partial.executeBefore = legacy.executeBefore
        }
        switch legacy.tokenInputs {
        case .mintInput(let mint):
            partial.tokenInputs = .mintInput(mint)
        case .transferInput(let transfer):
            partial.tokenInputs = .transferInput(transfer)
        case .createInput(var create):
            create.clearCreationEntityPublicKey()   // server-set: not in a partial transaction
            partial.tokenInputs = .createInput(create)
        case nil:
            break
        }
        partial.partialTokenOutputs = legacy.tokenOutputs.map(partialOutput)
        return partial
    }

    static func final(_ legacy: SparkToken_TokenTransaction) -> SparkToken_FinalTokenTransaction {
        var final = SparkToken_FinalTokenTransaction()
        final.version = legacy.version
        final.tokenTransactionMetadata = metadata(legacy)
        if legacy.hasExecuteBefore {
            final.executeBefore = legacy.executeBefore
        }
        switch legacy.tokenInputs {
        case .mintInput(let mint): final.tokenInputs = .mintInput(mint)
        case .transferInput(let transfer): final.tokenInputs = .transferInput(transfer)
        case .createInput(let create): final.tokenInputs = .createInput(create)
        case nil: break
        }
        final.finalTokenOutputs = legacy.tokenOutputs.map { output in
            var finalOutput = SparkToken_FinalTokenOutput()
            finalOutput.partialTokenOutput = partialOutput(output)
            finalOutput.revocationCommitment = output.revocationCommitment
            return finalOutput
        }
        return final
    }
}
