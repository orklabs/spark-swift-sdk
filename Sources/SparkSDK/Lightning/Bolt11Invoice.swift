import Foundation

/// A decoded BOLT-11 payment request.
///
/// The decoder follows the reader rules of BOLT-11: bech32 checksum, all-lower or all-upper
/// case, a recognised currency prefix, an integer amount with an optional `m`/`u`/`n`/`p`
/// multiplier (`p` amounts must be a multiple of 10), and tagged fields whose lengths are
/// validated. Amount arithmetic is overflow-checked so a hostile string throws instead of
/// trapping. The signature is not verified here; the SSP and operators verify it before
/// anything is paid.
struct Bolt11Invoice: Sendable, Equatable {
    enum Network: Sendable, Equatable {
        case mainnet, testnet, signet, regtest
    }

    let network: Network
    /// 32-byte payment hash (tag `p`).
    let paymentHash: Data
    /// Amount in millisatoshi, `nil` for an amountless invoice.
    let amountMsat: UInt64?
    /// Invoice creation time (seconds since the Unix epoch).
    let timestamp: UInt64
    /// Seconds after `timestamp` until the invoice expires (tag `x`, default 3600).
    let expirySeconds: UInt64
    /// Payment secret (tag `s`), if present.
    let paymentSecret: Data?
    /// Short description (tag `d`), if present.
    let description: String?

    var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) + TimeInterval(expirySeconds))
    }

    /// Whether this invoice belongs to the wallet's network.
    func belongs(to network: SparkNetwork) -> Bool {
        switch (self.network, network) {
        case (.mainnet, .mainnet), (.regtest, .regtest): return true
        default: return false
        }
    }

    // MARK: - Decoding

    private static let signatureWords = 104   // 65 bytes
    private static let timestampWords = 7

    static func decode(_ invoice: String) throws -> Bolt11Invoice {
        let trimmed = invoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let hrp: String
        let words: [UInt8]
        let encoding: Bech32.Encoding
        do {
            (hrp, words, encoding) = try Bech32.decode(trimmed, maxLength: nil)
        } catch let error as SparkError {
            throw SparkError.invalidInvoice(error.localizedDescription)
        }
        guard encoding == .bech32 else {
            throw SparkError.invalidInvoice("BOLT-11 invoices use the bech32 checksum, not bech32m")
        }
        let (network, amountMsat) = try parseHRP(hrp)

        guard words.count >= timestampWords + signatureWords else {
            throw SparkError.invalidInvoice("data part too short (\(words.count) words)")
        }
        var timestamp: UInt64 = 0
        for w in words[0..<timestampWords] { timestamp = (timestamp << 5) | UInt64(w) }

        let fields = Array(words[timestampWords..<(words.count - signatureWords)])
        var paymentHash: Data?
        var paymentSecret: Data?
        var expiry: UInt64?
        var description: String?

        var pos = 0
        while pos + 3 <= fields.count {
            let type = fields[pos]
            let length = Int(fields[pos + 1]) * 32 + Int(fields[pos + 2])
            pos += 3
            guard pos + length <= fields.count else {
                throw SparkError.invalidInvoice("tagged field \(type) runs past the end of the invoice")
            }
            let data = Array(fields[pos..<pos + length])
            pos += length

            switch type {
            case 1 where length == 52:   // p: payment hash
                if paymentHash == nil { paymentHash = bytes(fromWords: data, count: 32) }
            case 16 where length == 52:  // s: payment secret
                if paymentSecret == nil { paymentSecret = bytes(fromWords: data, count: 32) }
            case 6:                      // x: expiry
                guard length <= 12 else { throw SparkError.invalidInvoice("expiry field too long") }
                var value: UInt64 = 0
                for w in data { value = (value << 5) | UInt64(w) }
                expiry = value
            case 13:                     // d: description
                if let bytes = Bech32.convertBits(data, fromBits: 5, toBits: 8, pad: false) {
                    description = String(decoding: bytes, as: UTF8.self)
                }
            default:
                continue                 // unknown or wrongly-sized fields are skipped (BOLT-11)
            }
        }
        guard pos == fields.count else {
            throw SparkError.invalidInvoice("trailing bytes after the last tagged field")
        }
        guard let paymentHash else {
            throw SparkError.invalidInvoice("missing payment hash (p field)")
        }

        return Bolt11Invoice(
            network: network,
            paymentHash: paymentHash,
            amountMsat: amountMsat,
            timestamp: timestamp,
            expirySeconds: expiry ?? 3600,
            paymentSecret: paymentSecret,
            description: description
        )
    }

    /// `ln` + currency + optional amount + optional multiplier.
    private static func parseHRP(_ hrp: String) throws -> (Network, UInt64?) {
        guard hrp.hasPrefix("ln") else {
            throw SparkError.invalidInvoice("not a lightning invoice (prefix '\(hrp)')")
        }
        let rest = hrp.dropFirst(2)
        let network: Network
        let amountPart: Substring
        // Longest prefixes first: "bcrt" before "bc", "tbs" before "tb".
        if rest.hasPrefix("bcrt") { network = .regtest; amountPart = rest.dropFirst(4) }
        else if rest.hasPrefix("tbs") { network = .signet; amountPart = rest.dropFirst(3) }
        else if rest.hasPrefix("tb") { network = .testnet; amountPart = rest.dropFirst(2) }
        else if rest.hasPrefix("bc") { network = .mainnet; amountPart = rest.dropFirst(2) }
        else { throw SparkError.invalidInvoice("unknown currency prefix '\(hrp)'") }

        if amountPart.isEmpty { return (network, nil) }

        var digits = amountPart
        var multiplier: Character? = nil
        if let last = digits.last, !last.isNumber {
            multiplier = last
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw SparkError.invalidInvoice("malformed amount '\(amountPart)'")
        }
        guard digits.first != "0" else {
            throw SparkError.invalidInvoice("amount has a leading zero")
        }
        guard digits.count <= 19, let number = UInt64(digits), number > 0 else {
            throw SparkError.invalidInvoice("amount '\(amountPart)' is out of range")
        }

        // msat per unit: BTC = 1e11, m = 1e8, u = 1e5, n = 1e2, p = 1e-1.
        let msat: UInt64
        switch multiplier {
        case nil:
            msat = try checkedMultiply(number, 100_000_000_000, amountPart)
        case "m":
            msat = try checkedMultiply(number, 100_000_000, amountPart)
        case "u":
            msat = try checkedMultiply(number, 100_000, amountPart)
        case "n":
            msat = try checkedMultiply(number, 100, amountPart)
        case "p":
            guard number % 10 == 0 else {
                throw SparkError.invalidInvoice("pico-bitcoin amount '\(amountPart)' has sub-millisatoshi precision")
            }
            msat = number / 10
        default:
            throw SparkError.invalidInvoice("invalid amount multiplier '\(multiplier!)'")
        }
        return (network, msat)
    }

    private static func checkedMultiply(_ a: UInt64, _ b: UInt64, _ amount: Substring) throws -> UInt64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, product <= 21_000_000 * 100_000_000 * 1_000 else {
            throw SparkError.invalidInvoice("amount '\(amount)' exceeds the total bitcoin supply")
        }
        return product
    }

    /// Fixed-size byte field carried as 5-bit words (trailing padding bits are ignored).
    private static func bytes(fromWords words: [UInt8], count: Int) -> Data? {
        guard let bytes = Bech32.convertBits(words, fromBits: 5, toBits: 8, pad: true), bytes.count >= count else {
            return nil
        }
        return Data(bytes.prefix(count))
    }
}

/// Client-side checks around lightning payments and invoices.
enum LightningValidator {

    /// Resolve the amount to pay: the invoice amount (rounded up to whole sats), or the caller's
    /// amount for an amountless invoice. A caller amount that contradicts the invoice is refused.
    static func resolvePaymentAmountSats(invoiceAmountMsat: UInt64?, requestedAmountSats: Int64?) throws -> Int64 {
        if let invoiceAmountMsat {
            let sats = (invoiceAmountMsat + 999) / 1000
            guard sats > 0, sats <= UInt64(Int64.max) else {
                throw SparkError.invalidInvoice("invoice amount \(invoiceAmountMsat) msat is out of range")
            }
            if let requestedAmountSats, requestedAmountSats != Int64(sats) {
                throw SparkError.invalidArgument(
                    "amountSats (\(requestedAmountSats)) does not match the invoice amount (\(sats) sats); omit it for invoices that carry an amount"
                )
            }
            return Int64(sats)
        }
        guard let requestedAmountSats else {
            throw SparkError.invalidArgument("the invoice has no amount; pass amountSats")
        }
        guard requestedAmountSats > 0 else {
            throw SparkError.invalidArgument("amountSats must be positive, got \(requestedAmountSats)")
        }
        return requestedAmountSats
    }

    /// Verify that an invoice the SSP created is the one we asked for: same network, same payment
    /// hash, same amount. Run before preimage shares are stored and before the invoice is shown.
    static func verifyCreatedInvoice(
        encodedInvoice: String,
        reportedPaymentHashHex: String?,
        expectedPaymentHash: Data,
        expectedAmountSats: Int64,
        network: SparkNetwork
    ) throws -> Bolt11Invoice {
        let invoice = try Bolt11Invoice.decode(encodedInvoice)
        guard invoice.belongs(to: network) else {
            throw SparkError.untrustedResponse("SSP returned an invoice for \(invoice.network), wallet is on \(network)")
        }
        guard invoice.paymentHash == expectedPaymentHash else {
            throw SparkError.untrustedResponse("SSP invoice payment hash \(invoice.paymentHash.hexString) does not match ours \(expectedPaymentHash.hexString)")
        }
        if let reportedPaymentHashHex, reportedPaymentHashHex.lowercased() != expectedPaymentHash.hexString {
            throw SparkError.untrustedResponse("SSP reported payment hash \(reportedPaymentHashHex) does not match ours \(expectedPaymentHash.hexString)")
        }
        if expectedAmountSats == 0 {
            if let amountMsat = invoice.amountMsat {
                throw SparkError.untrustedResponse("SSP invoice carries an amount (\(amountMsat) msat) but an amountless invoice was requested")
            }
        } else {
            let expectedMsat = UInt64(expectedAmountSats).multipliedReportingOverflow(by: 1000)
            guard !expectedMsat.overflow, invoice.amountMsat == expectedMsat.partialValue else {
                throw SparkError.untrustedResponse("SSP invoice amount \(invoice.amountMsat.map(String.init) ?? "none") msat does not match the requested \(expectedAmountSats) sats")
            }
        }
        return invoice
    }

    /// Lower-cased UUID for a caller-supplied transfer id used to resume a lightning send.
    static func normalizeTransferId(_ transferId: String?) throws -> String? {
        guard let transferId else { return nil }
        guard let uuid = UUID(uuidString: transferId) else {
            throw SparkError.invalidArgument("transferId must be a UUID, got '\(transferId)'")
        }
        return uuid.uuidString.lowercased()
    }
}
