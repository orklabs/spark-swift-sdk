// swiftlint:disable line_length — specification test vectors are long single tokens
import Foundation
import Testing
@testable import SparkSDK

/// BOLT-11 decoding against the specification's test vectors, plus the client-side checks on
/// lightning sends and SSP-created invoices.
@Suite("BOLT-11 invoices")
struct Bolt11InvoiceTests {

    static let specPaymentHash = "0001020304050607080900010203040506070809000102030405060708090102"
    static let specTimestamp: UInt64 = 1_496_314_658

    static let donation = "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"
    static let coffee2500u = "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
    static let list20m = "lnbc20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqhp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqs9qrsgq7ea976txfraylvgzuxs8kgcw23ezlrszfnh8r6qtfpr6cxga50aj6txm9rxrydzd06dfeawfk6swupvz4erwnyutnjq7x39ymw6j38gp7ynn44"
    static let testnet20m = "lntb20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygshp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqfpp3x9et2e20v6pu37c5d9vax37wxq72un989qrsgqdj545axuxtnfemtpwkc45hx9d2ft7x04mt8q7y6t0k2dge9e7h8kpy9p34ytyslj3yu569aalz2xdk8xkd7ltxqld94u8h2esmsmacgpghe9k8"
    static let pico = "lnbc9678785340p1pwmna7lpp5gc3xfm08u9qy06djf8dfflhugl6p7lgza6dsjxq454gxhj9t7a0sd8dgfkx7cmtwd68yetpd5s9xar0wfjn5gpc8qhrsdfq24f5ggrxdaezqsnvda3kkum5wfjkzmfqf3jkgem9wgsyuctwdus9xgrcyqcjcgpzgfskx6eqf9hzqnteypzxz7fzypfhg6trddjhygrcyqezcgpzfysywmm5ypxxjemgw3hxjmn8yptk7untd9hxwg3q2d6xjcmtv4ezq7pqxgsxzmnyyqcjqmt0wfjjq6t5v4khxsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygsxqyjw5qcqp2rzjq0gxwkzc8w6323m55m4jyxcjwmy7stt9hwkwe2qxmy8zpsgg7jcuwz87fcqqeuqqqyqqqqlgqqqqn3qq9q9qrsgqrvgkpnmps664wgkp43l22qsgdw4ve24aca4nymnxddlnp8vh9v2sdxlu5ywdxefsfvm0fq3sesf08uf6q9a2ke0hc9j6z6wlxg5z5kqpu2v9wz"
    static let upper25m = "LNBC25M1PVJLUEZPP5QQQSYQCYQ5RQWZQFQQQSYQCYQ5RQWZQFQQQSYQCYQ5RQWZQFQYPQDQ5VDHKVEN9V5SXYETPDEESSP5ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYG3ZYGS9Q5SQQQQQQQQQQQQQQQQSGQ2A25DXL5HRNTDTN6ZVYDT7D66HYZSYHQS4WDYNAVYS42XGL6SGX9C4G7ME86A27T07MDTFRY458RTJR0V92CNMSWPSJSCGT2VCSE3SGPZ3UAPA"
    static let metadata10m = "lnbc10m1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdp9wpshjmt9de6zqmt9w3skgct5vysxjmnnd9jx2mq8q8a04uqsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9q2gqqqqqqsgq7hf8he7ecf7n4ffphs6awl9t6676rrclv9ckg3d3ncn7fct63p6s365duk5wrk202cfy3aj5xnnp5gs3vrdvruverwwq7yzhkf5a3xqpd05wjc"

    @Test("Specification vectors decode with the right network, amount, hash and timestamp")
    func specVectors() throws {
        let donation = try Bolt11Invoice.decode(Self.donation)
        #expect(donation.network == .mainnet)
        #expect(donation.amountMsat == nil)
        #expect(donation.amountSatsRoundedUp == nil)
        #expect(donation.paymentHash.hexString == Self.specPaymentHash)
        #expect(donation.timestamp == Self.specTimestamp)
        #expect(donation.expirySeconds == 3600)
        #expect(donation.paymentSecret?.hexString == String(repeating: "11", count: 32))
        #expect(donation.description == "Please consider supporting this project")

        let coffee = try Bolt11Invoice.decode(Self.coffee2500u)
        #expect(coffee.amountMsat == 250_000_000)
        #expect(coffee.amountSatsRoundedUp == 250_000)
        #expect(coffee.expirySeconds == 60)
        #expect(coffee.description == "1 cup coffee")
        #expect(coffee.expiresAt == Date(timeIntervalSince1970: TimeInterval(Self.specTimestamp + 60)))

        let list = try Bolt11Invoice.decode(Self.list20m)
        #expect(list.amountMsat == 2_000_000_000)
        #expect(list.amountSatsRoundedUp == 2_000_000)
        #expect(list.paymentHash.hexString == Self.specPaymentHash)

        let testnet = try Bolt11Invoice.decode(Self.testnet20m)
        #expect(testnet.network == .testnet)
        #expect(testnet.amountMsat == 2_000_000_000)

        let pico = try Bolt11Invoice.decode(Self.pico)
        #expect(pico.amountMsat == 967_878_534)
        #expect(pico.amountSatsRoundedUp == 967_879)
        #expect(pico.paymentHash.hexString == "462264ede7e14047e9b249da94fefc47f41f7d02ee9b091815a5506bc8abf75f")
        #expect(pico.timestamp == 1_572_468_703)
        #expect(pico.expirySeconds == 604_800)

        let upper = try Bolt11Invoice.decode(Self.upper25m)
        #expect(upper.amountMsat == 2_500_000_000)
        #expect(upper.paymentHash.hexString == Self.specPaymentHash)

        let withMetadata = try Bolt11Invoice.decode(Self.metadata10m)
        #expect(withMetadata.amountMsat == 1_000_000_000)

        // Surrounding whitespace is tolerated.
        #expect(try Bolt11Invoice.decode("  \(Self.coffee2500u)\n") == coffee)
    }

    @Test("Specification's invalid invoices are rejected")
    func specInvalid() {
        let invalid = [
            // Bech32 checksum is invalid.
            "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpquwpc4curk03c9wlrswe78q4eyqc7d8d0xqzpuyk0sg5g70me25alkluzd2x62aysf2pyy8edtjeevuv4p2d5p76r4zkmneet7uvyakky2zr4cusd45tftc9c5fh0nnqpnl2jfll544esqchsrnt",
            // Malformed bech32 string (no 1)
            "pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpquwpc4curk03c9wlrswe78q4eyqc7d8d0xqzpuyk0sg5g70me25alkluzd2x62aysf2pyy8edtjeevuv4p2d5p76r4zkmneet7uvyakky2zr4cusd45tftc9c5fh0nnqpnl2jfll544esqchsrny",
            // Malformed bech32 string (mixed case)
            "LNBC2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpquwpc4curk03c9wlrswe78q4eyqc7d8d0xqzpuyk0sg5g70me25alkluzd2x62aysf2pyy8edtjeevuv4p2d5p76r4zkmneet7uvyakky2zr4cusd45tftc9c5fh0nnqpnl2jfll544esqchsrny",
            // String is too short.
            "lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6na6hlh",
            // Invalid multiplier
            "lnbc2500x1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpusp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9qrsgqrrzc4cvfue4zp3hggxp47ag7xnrlr8vgcmkjxk3j5jqethnumgkpqp23z9jclu3v0a7e0aruz366e9wqdykw6dxhdzcjjhldxq0w6wgqcnu43j",
            // Invalid sub-millisatoshi precision.
            "lnbc2500000001p1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpusp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9qrsgq0lzc236j96a95uv0m3umg28gclm5lqxtqqwk32uuk4k6673k6n5kfvx3d2h8s295fad45fdhmusm8sjudfhlf6dcsxmfvkeywmjdkxcp99202x",
            "",
            "lnbc",
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
        ]
        for invoice in invalid {
            #expect(throws: SparkError.self, Comment(rawValue: String(invoice.prefix(24)))) {
                _ = try Bolt11Invoice.decode(invoice)
            }
        }
    }

    /// Re-encode a valid invoice's data part under a different human-readable part so the
    /// checksum is valid and only the prefix under test changes.
    private func withHRP(_ hrp: String, from invoice: String, encoding: Bech32.Encoding = .bech32) throws -> String {
        let (_, words, _) = try Bech32.decode(invoice, maxLength: nil)
        return Bech32.encode(hrp: hrp, data: words, encoding: encoding)
    }

    @Test("Hostile amounts throw instead of overflowing, and other prefixes are refused")
    func hostileHRPs() throws {
        let base = Self.coffee2500u
        for hrp in [
            "lnbc9223372036854775807m",      // Int64.max × 1e8 — trapped in the old parser
            "lnbc18446744073709551615",      // UInt64.max BTC
            "lnbc99999999999999999999u",     // more than 19 digits
            "lnbc21000001",                  // more than the supply
            "lnbc0250u", "lnbc0",            // leading zero / zero
            "lnbc25.0m", "lnbc-1m", "lnbc2500um",
            "lnxx2500u", "ln2500u", "bc2500u",
        ] {
            #expect(throws: SparkError.self, Comment(rawValue: hrp)) {
                _ = try Bolt11Invoice.decode(try withHRP(hrp, from: base))
            }
        }
        // Boundary: the whole supply in BTC decodes, one satoshi above it does not.
        #expect(try Bolt11Invoice.decode(try withHRP("lnbc21000000", from: base)).amountMsat == 21_000_000 * 100_000_000_000)
        #expect(try Bolt11Invoice.decode(try withHRP("lnbc1", from: base)).amountMsat == 100_000_000_000)
        #expect(try Bolt11Invoice.decode(try withHRP("lnbc10n", from: base)).amountMsat == 1_000)
        #expect(try Bolt11Invoice.decode(try withHRP("lnbc10p", from: base)).amountMsat == 1)
        // Currency prefixes, longest match first.
        #expect(try Bolt11Invoice.decode(try withHRP("lnbcrt2500u", from: base)).network == .regtest)
        #expect(try Bolt11Invoice.decode(try withHRP("lntbs2500u", from: base)).network == .signet)
        #expect(try Bolt11Invoice.decode(try withHRP("lntb2500u", from: base)).network == .testnet)
        // A bech32m checksum is not a BOLT-11 invoice.
        #expect(throws: SparkError.self) { _ = try Bolt11Invoice.decode(try withHRP("lnbc2500u", from: base, encoding: .bech32m)) }
    }

    @Test("Network matching against the wallet's network")
    func networkMatching() throws {
        let mainnet = try Bolt11Invoice.decode(Self.coffee2500u)
        #expect(mainnet.belongs(to: .mainnet))
        #expect(!mainnet.belongs(to: .regtest))
        let regtest = try Bolt11Invoice.decode(try withHRP("lnbcrt2500u", from: Self.coffee2500u))
        #expect(regtest.belongs(to: .regtest))
        #expect(!regtest.belongs(to: .mainnet))
        let testnet = try Bolt11Invoice.decode(Self.testnet20m)
        #expect(!testnet.belongs(to: .mainnet))
        #expect(!testnet.belongs(to: .regtest))
    }
}

@Suite("Lightning send and receive validation")
struct LightningValidatorTests {

    @Test("Payment amount comes from the invoice, or from the caller only for amountless invoices")
    func amountResolution() throws {
        #expect(try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: 250_000_000, requestedAmountSats: nil) == 250_000)
        #expect(try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: 250_000_000, requestedAmountSats: 250_000) == 250_000)
        #expect(try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: 1_500, requestedAmountSats: nil) == 2)
        #expect(try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: nil, requestedAmountSats: 500) == 500)

        #expect(throws: SparkError.self) { _ = try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: 250_000_000, requestedAmountSats: 1) }
        #expect(throws: SparkError.self) { _ = try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: nil, requestedAmountSats: nil) }
        #expect(throws: SparkError.self) { _ = try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: nil, requestedAmountSats: 0) }
        #expect(throws: SparkError.self) { _ = try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: nil, requestedAmountSats: -5) }
        #expect(throws: SparkError.self) { _ = try LightningValidator.resolvePaymentAmountSats(invoiceAmountMsat: 0, requestedAmountSats: nil) }
    }

    @Test("An SSP-created invoice must carry our payment hash, amount and network")
    func createdInvoiceVerification() throws {
        let hash = Data(hexString: Bolt11InvoiceTests.specPaymentHash)!
        let ok = try LightningValidator.verifyCreatedInvoice(
            encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: Bolt11InvoiceTests.specPaymentHash,
            expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .mainnet
        )
        #expect(ok.amountMsat == 250_000_000)
        // The SSP's reported hash is optional and case-insensitive.
        _ = try LightningValidator.verifyCreatedInvoice(
            encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: nil,
            expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .mainnet
        )
        _ = try LightningValidator.verifyCreatedInvoice(
            encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: Bolt11InvoiceTests.specPaymentHash.uppercased(),
            expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .mainnet
        )
        // Amountless invoice for an amountless request.
        _ = try LightningValidator.verifyCreatedInvoice(
            encodedInvoice: Bolt11InvoiceTests.donation, reportedPaymentHashHex: nil,
            expectedPaymentHash: hash, expectedAmountSats: 0, network: .mainnet
        )

        let wrongHash = Data(repeating: 0xAB, count: 32)
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: nil, expectedPaymentHash: wrongHash, expectedAmountSats: 250_000, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: wrongHash.hexString, expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: nil, expectedPaymentHash: hash, expectedAmountSats: 250_001, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: nil, expectedPaymentHash: hash, expectedAmountSats: 0, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.donation, reportedPaymentHashHex: nil, expectedPaymentHash: hash, expectedAmountSats: 100, network: .mainnet)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: Bolt11InvoiceTests.coffee2500u, reportedPaymentHashHex: nil, expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .regtest)
        }
        #expect(throws: SparkError.self) {
            _ = try LightningValidator.verifyCreatedInvoice(encodedInvoice: "garbage", reportedPaymentHashHex: nil, expectedPaymentHash: hash, expectedAmountSats: 250_000, network: .mainnet)
        }
    }

    @Test("Resumable transfer ids must be UUIDs and are normalised to lower case")
    func transferIds() throws {
        #expect(try LightningValidator.normalizeTransferId(nil) == nil)
        #expect(try LightningValidator.normalizeTransferId("0190A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B") == "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        #expect(throws: SparkError.self) { _ = try LightningValidator.normalizeTransferId("not-a-uuid") }
        #expect(throws: SparkError.self) { _ = try LightningValidator.normalizeTransferId("") }
    }
}
