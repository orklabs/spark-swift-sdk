import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
@testable import SparkSDK

/// The reference SDK's known-answer vectors for V2 token transaction hashes
/// (`token-hashing.test.ts`, on the operators' Go test data), and the operators' rules for invoice
/// attachments (`TestHashTokenTransactionV2UniqueHash`).
@Suite("Token transaction hash vectors")
struct TokenHashVectorTests {
    static func key(_ second: UInt8, last: UInt8 = 46) -> Data {
        Data([0x02, second, 155, 208, 90, 72, 211, 120, 244, 69, 99, 28, 101, 149, 222, 123,
              50, 252, 63, 99, 54, 137, 226, 7, 224, 163, 122, 93, 248, 42, 159, 173, last])
    }

    /// Two regtest invoices whose ids (01992fa6… and 01992fac…) sort the other way from their
    /// strings.
    static let invoices = [
        "sparkrt1pgssx5us3wkqjza8g80xz3a9gznx25msq6g3ty8exfym9q3ahcv86vsnzfmssqgjzqqejtaxmwj8ms9rn58574nvlq4j5zr5v4ehgnt9d4hnyggr2wgghtqfpwn5rhnpg7j5pfn92dcqdyg4jrunyjdjsg7muxraxgfn5rqgandgr3sxzrqdmew8qydzvz3qpylysylkgcaw9vpm2jzspls0qtr5kfmlwz244rvuk25w5w2sgc2pyqsraqdyp8tf57a6cn2egttaas9ms3whssenmjqt8wag3lgyvdzjskfeupt8xwwdx4agxdm9f0wefzj28jmdxqeudwcwdj9vfl9sdr65x06r0tasf5fwz2", // swiftlint:disable:this line_length
        "sparkrt1pgssx5us3wkqjza8g80xz3a9gznx25msq6g3ty8exfym9q3ahcv86vsnzfmqsqgjzqqejtavuhf8n5uh9a74zw66kqaz5zr5v4ehgnt9d4hnyggr2wgghtqfpwn5rhnpg7j5pfn92dcqdyg4jrunyjdjsg7muxraxgfn5zcglrwcr3sxzzqt3wrjrgnq5gqf8eyp8ajx8t3tqw65s5q0urczca9jwlmsj4dgm89j4r4rj5zxzsfqyqlgrfqw9ucldgmfzs5zmkekj90thwzmn6ps55gdjnz23aarjkf245608yg0v2x6xdpdrz6m8xjlhtru0kygcu4zhqwlth9duadfqpruuzx4tc7fdckn", // swiftlint:disable:this line_length
    ]

    /// The vectors' transfer: one input, one output, one operator, regtest, created at 100 ms.
    static func transfer(invoices: [String]) -> SparkToken_TokenTransaction {
        var spend = SparkToken_TokenOutputToSpend()
        spend.prevTokenTransactionHash = Data(SHA256.hash(data: Data("previous transaction".utf8)))
        spend.prevTokenTransactionVout = 0
        var input = SparkToken_TokenTransferInput()
        input.outputsToSpend = [spend]

        var output = SparkToken_TokenOutput()
        output.id = "db1a4e48-0fc5-4f6c-8a80-d9d6c561a436"
        output.ownerPublicKey = key(25)
        output.tokenPublicKey = key(242, last: 45)
        output.tokenAmount = encodeUInt128(1000)
        output.revocationCommitment = key(100)
        output.withdrawBondSats = 10_000
        output.withdrawRelativeBlockLocktime = 100

        var tx = SparkToken_TokenTransaction()
        tx.version = 2
        tx.tokenInputs = .transferInput(input)
        tx.tokenOutputs = [output]
        tx.sparkOperatorIdentityPublicKeys = [key(200)]
        tx.network = .regtest
        tx.expiryTime = Google_Protobuf_Timestamp(seconds: 0, nanos: 0)
        tx.clientCreatedTimestamp = Google_Protobuf_Timestamp(seconds: 0, nanos: 100_000_000)
        tx.invoiceAttachments = invoices.map { invoice in
            var attachment = SparkToken_InvoiceAttachment()
            attachment.sparkInvoice = invoice
            return attachment
        }
        return tx
    }

    @Test("Transfer without invoice attachments")
    func transfer() throws {
        let expected = Data([
            28, 151, 252, 16, 41, 53, 194, 50, 190, 167, 55, 2, 43, 179, 179, 255,
            117, 150, 148, 29, 158, 203, 107, 193, 82, 1, 77, 95, 41, 168, 208, 179,
        ])
        #expect(try hashTokenTransactionV2(Self.transfer(invoices: []), partialHash: false) == expected)
    }

    @Test("Transfer with two invoice attachments, hashed in invoice-id order whatever order they come in")
    func transferWithInvoices() throws {
        let expected = Data([
            0xb0, 0x98, 0xdc, 0x22, 0x8a, 0x0d, 0x82, 0x64, 0x25, 0x4a, 0x2d, 0xef,
            0x34, 0x42, 0x5c, 0xab, 0xe2, 0x23, 0x0d, 0x4f, 0x7b, 0xa4, 0x3c, 0xf2,
            0xa3, 0x2c, 0x27, 0xf0, 0x31, 0xae, 0x08, 0x83,
        ])
        #expect(try hashTokenTransactionV2(Self.transfer(invoices: Self.invoices), partialHash: false) == expected)
        #expect(try hashTokenTransactionV2(Self.transfer(invoices: Self.invoices.reversed()), partialHash: false) == expected)
    }

    @Test("An attachment that is not a Spark invoice cannot be hashed", arguments: [
        "",
        "invalid",
        SparkAddress.encode(identityPublicKey: key(25), network: .regtest),  // an address, not an invoice
    ])
    func invalidAttachment(invoice: String) {
        #expect(throws: SparkError.self) {
            try hashTokenTransactionV2(Self.transfer(invoices: [invoice]), partialHash: false)
        }
    }
}
