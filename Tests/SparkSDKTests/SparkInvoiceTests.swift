import Foundation
import Testing
@testable import SparkSDK

/// A Spark invoice is a Spark address whose payload also carries invoice fields. The SDK decodes
/// the whole payload, as the reference SDK's `decodeSparkAddress` does, and refuses to pay an
/// invoice as a plain address. Vectors from the reference SDK's `address.test.ts`.
@Suite("Spark invoices")
struct SparkInvoiceTests {
    static let regtestAddress = "sparkrt1pgssx5us3wkqjza8g80xz3a9gznx25msq6g3ty8exfym9q3ahcv86vsnxxdy83"
    static let legacyRegtestAddress = "sprt1pgssx63fa5g6uyv450rajp5ndwy9laxzpsp9e37su58jddmcdsvhgm5n7y0ud6"
    static let mainnetAddress = "spark1pgss9qg3vdslzmt2name9v550skuvlu6lj5xt9sly90k7p0gxughlqv023jqmc"
    static let legacyMainnetAddress = "sp1pgssxwh6hznfdc3c0cuqrhgttder539d52a0rqcf34amge69huh664gd2ew787"
    /// A signed regtest invoice for 1000 units of a token, with memo, sender and expiry.
    static let tokensInvoice = "sparkrt1pgssx5us3wkqjza8g80xz3a9gznx25msq6g3ty8exfym9q3ahcv86vsnzfmssqgjzqqejtaxmwj8ms9rn58574nvlq4j5zr5v4ehgnt9d4hnyggr2wgghtqfpwn5rhnpg7j5pfn92dcqdyg4jrunyjdjsg7muxraxgfn5rqgandgr3sxzrqdmew8qydzvz3qpylysylkgcaw9vpm2jzspls0qtr5kfmlwz244rvuk25w5w2sgc2pyqsraqdyp8tf57a6cn2egttaas9ms3whssenmjqt8wag3lgyvdzjskfeupt8xwwdx4agxdm9f0wefzj28jmdxqeudwcwdj9vfl9sdr65x06r0tasf5fwz2" // swiftlint:disable:this line_length
    static let vectorIdentity = "0353908bac090ba741de6147a540a665537006911590f93249b2823dbe187d3213"

    /// An unsigned invoice for `amountSats` to `identityPublicKey`, as a payee would publish one.
    static func satsInvoice(identityPublicKey: Data, amountSats: UInt64, network: SparkNetwork) throws -> String {
        var payload = Spark_SparkAddress()
        payload.identityPublicKey = identityPublicKey
        payload.sparkInvoiceFields.version = 1
        payload.sparkInvoiceFields.id = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        payload.sparkInvoiceFields.satsPayment.amount = amountSats
        return Bech32m.encode(hrp: SparkAddress.hrp(for: network), data: Bech32.toWords(try payload.serializedData()))
    }

    @Test("Known addresses decode to their identity keys and carry no invoice")
    func knownAddresses() throws {
        #expect(try SparkAddress.decode(Self.regtestAddress, network: .regtest).hexString == Self.vectorIdentity)
        #expect(try SparkAddress.decode(Self.legacyRegtestAddress, network: .regtest).hexString
                == "036a29ed11ae1195a3c7d906936b885ff4c20c025cc7d0e50f26b7786c19746e93")
        _ = try SparkAddress.decode(Self.mainnetAddress, network: .mainnet)
        _ = try SparkAddress.decode(Self.legacyMainnetAddress, network: .mainnet)
        let payload = try SparkAddress.decodePayload(Self.regtestAddress, network: .regtest)
        #expect(payload.invoiceFields == nil)
        #expect(payload.signature == nil)
    }

    @Test("A Spark invoice decodes to its fields, as in the reference SDK's vector")
    func invoiceFields() throws {
        let payload = try SparkAddress.decodePayload(Self.tokensInvoice, network: .regtest)
        #expect(payload.identityPublicKey.hexString == Self.vectorIdentity)
        let fields = try #require(payload.invoiceFields)
        #expect(fields.version == 1)
        #expect(fields.id.hexString == "01992fa6dba47dc0a39d0f4f566cf82b")
        guard case .tokensPayment(let tokens)? = fields.paymentType else {
            Issue.record("the vector is a tokens invoice")
            return
        }
        #expect(tokens.tokenIdentifier.hexString == "093e4813f6463ae2b03b548500fe0f02c74b277f70955a8d9cb2a8ea39504614")
        #expect(tokens.amount == Data([0x03, 0xE8]))
        #expect(fields.memo == "testMemo")
        #expect(fields.senderPublicKey.hexString == Self.vectorIdentity)
        // 2025-09-09T18:09:48.419Z
        #expect(fields.expiryTime.seconds == 1_757_441_388)
        #expect(fields.expiryTime.nanos == 419_000_000)
        #expect(payload.signature?.hexString == "9d69a7bbac4d5942d7dec0bb845d784333dc80b3bba88fd046345285939e0567"
                + "339cd357a8337654bdd948a4a3cb6d3033c6bb0e6c8ac4fcb068f5433f437afb")
    }

    @Test("A Spark invoice is refused where a Spark address is expected")
    func invoiceIsNotAnAddress() throws {
        do {
            _ = try SparkAddress.decode(Self.tokensInvoice, network: .regtest)
            Issue.record("a Spark invoice was accepted as a Spark address")
        } catch SparkError.invalidAddress(let reason) {
            #expect(reason.contains("Spark invoice"))
        }
        let key = try #require(Data(hexString: Self.vectorIdentity))
        let sats = try Self.satsInvoice(identityPublicKey: key, amountSats: 1_000, network: .mainnet)
        #expect(try SparkAddress.decodePayload(sats, network: .mainnet).invoiceFields?.satsPayment.amount == 1_000)
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(sats, network: .mainnet) }
        // Invoice fields with nothing set still make an invoice.
        var empty = Spark_SparkAddress()
        empty.identityPublicKey = key
        empty.sparkInvoiceFields = Spark_SparkInvoiceFields()
        let emptyInvoice = Bech32m.encode(hrp: "spark", data: Bech32.toWords(try empty.serializedData()))
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(emptyInvoice, network: .mainnet) }
    }

    @Test("The payload is decoded whole: field order is free, the key must be a curve point, junk is refused")
    func payloadDecoding() throws {
        let key = try #require(Data(hexString: Self.vectorIdentity))
        func address(_ payload: Data) -> String {
            Bech32m.encode(hrp: "spark", data: Bech32.toWords(payload))
        }
        // Identity key after an unknown field: still a plain address.
        let reordered = Data([0x78, 0x01, 0x0a, 33]) + key
        #expect(try SparkAddress.decode(address(reordered), network: .mainnet) == key)
        // x beyond the field prime: not a point.
        let offCurve = Data([0x0a, 33, 0x02]) + Data(repeating: 0xFF, count: 32)
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(address(offCurve), network: .mainnet) }
        // A truncated field.
        let truncated = Data([0x0a, 33]) + key.prefix(20)
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(address(truncated), network: .mainnet) }
        // No identity key at all.
        #expect(throws: SparkError.self) { _ = try SparkAddress.decode(address(Data([0x78, 0x01])), network: .mainnet) }
    }

    @Test("Sending or transferring tokens to a Spark invoice is refused before any network call",
          .timeLimit(.minutes(1)))
    func sendToInvoice() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            let invoice = try Self.satsInvoice(
                identityPublicKey: try #require(Data(hexString: Self.vectorIdentity)), amountSats: 10, network: .regtest
            )
            await #expect(throws: SparkError.self) { _ = try await wallet.send(receiverSparkAddress: invoice, amountSats: 10) }
            let token = try encodeBech32mTokenIdentifier(Data(repeating: 0x42, count: 32), network: .regtest)
            await #expect(throws: SparkError.self) {
                _ = try await wallet.transferTokens(tokenIdentifier: token, tokenAmount: 10, receiverSparkAddress: invoice)
            }
        }
        #expect(await state.methods.isEmpty)
    }
}
