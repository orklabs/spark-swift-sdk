import Foundation
import CryptoKit

// MARK: - Token Transaction Hashing (V2)

/// Hash a V2 token transaction. When `partialHash` is true, server-set fields
/// (output id, revocation commitment, withdraw bond/locktime, expiry) are omitted.
/// Mirrors the reference SDK's hashTokenTransactionV2 field by field; kept as one function so
/// the two stay easy to diff.
// swiftlint:disable:next cyclomatic_complexity function_body_length
func hashTokenTransactionV2(
    _ tx: SparkToken_TokenTransaction,
    partialHash: Bool
) throws -> Data {
    var allHashes: [Data] = []

    // Hash version (uint32 BE)
    allHashes.append(sha256(uint32BE(tx.version)))

    // Hash transaction type
    let txType: UInt32
    switch tx.tokenInputs {
    case .mintInput: txType = UInt32(SparkToken_TokenTransactionType.mint.rawValue)
    case .transferInput: txType = UInt32(SparkToken_TokenTransactionType.transfer.rawValue)
    case .createInput: txType = UInt32(SparkToken_TokenTransactionType.create.rawValue)
    default:
        throw SparkError.invalidResponse("Token transaction must have exactly one input type")
    }
    allHashes.append(sha256(uint32BE(txType)))

    // Hash token inputs based on type
    switch tx.tokenInputs {
    case .transferInput(let transferInput):
        guard !transferInput.outputsToSpend.isEmpty else {
            throw SparkError.invalidResponse("Outputs to spend cannot be empty")
        }
        // Hash outputs-to-spend length
        allHashes.append(sha256(uint32BE(UInt32(transferInput.outputsToSpend.count))))
        // Hash each output reference
        for output in transferInput.outputsToSpend {
            var data = Data()
            if !output.prevTokenTransactionHash.isEmpty {
                guard output.prevTokenTransactionHash.count == 32 else {
                    throw SparkError.invalidResponse("Invalid previous transaction hash length")
                }
                data.append(output.prevTokenTransactionHash)
            }
            data.append(uint32BE(output.prevTokenTransactionVout))
            allHashes.append(sha256(data))
        }

    case .mintInput(let mintInput):
        guard !mintInput.issuerPublicKey.isEmpty else {
            throw SparkError.invalidResponse("Issuer public key cannot be empty")
        }
        allHashes.append(sha256(mintInput.issuerPublicKey))
        if mintInput.hasTokenIdentifier {
            allHashes.append(sha256(mintInput.tokenIdentifier))
        } else {
            allHashes.append(sha256(Data(count: 32)))
        }

    case .createInput(let createInput):
        guard !createInput.issuerPublicKey.isEmpty else {
            throw SparkError.invalidResponse("Issuer public key cannot be empty")
        }
        allHashes.append(sha256(createInput.issuerPublicKey))

        let nameBytes = Data(createInput.tokenName.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 20 else {
            throw SparkError.invalidResponse("Token name must be 1-20 bytes")
        }
        allHashes.append(sha256(nameBytes))

        let tickerBytes = Data(createInput.tokenTicker.utf8)
        guard !tickerBytes.isEmpty, tickerBytes.count <= 6 else {
            throw SparkError.invalidResponse("Token ticker must be 1-6 bytes")
        }
        allHashes.append(sha256(tickerBytes))

        allHashes.append(sha256(uint32BE(createInput.decimals)))

        guard createInput.maxSupply.count == 16 else {
            throw SparkError.invalidResponse("Max supply must be exactly 16 bytes")
        }
        allHashes.append(sha256(createInput.maxSupply))

        allHashes.append(sha256(Data([createInput.isFreezable ? 1 : 0])))

        // Creation entity public key (only for final hash)
        if !partialHash && createInput.hasCreationEntityPublicKey {
            allHashes.append(sha256(createInput.creationEntityPublicKey))
        } else {
            allHashes.append(sha256(Data()))
        }

    default:
        throw SparkError.invalidResponse("Token transaction must have exactly one input type")
    }

    // Hash token outputs
    allHashes.append(sha256(uint32BE(UInt32(tx.tokenOutputs.count))))

    for output in tx.tokenOutputs {
        var data = Data()

        // Hash ID (only for final hash)
        if !partialHash && !output.id.isEmpty {
            data.append(Data(output.id.utf8))
        }

        if !output.ownerPublicKey.isEmpty {
            data.append(output.ownerPublicKey)
        }

        if !partialHash {
            if output.hasRevocationCommitment && !output.revocationCommitment.isEmpty {
                data.append(output.revocationCommitment)
            }
            data.append(uint64BE(output.withdrawBondSats))
            data.append(uint64BE(output.withdrawRelativeBlockLocktime))
        }

        // Token public key (33 zero bytes if absent)
        if output.hasTokenPublicKey && !output.tokenPublicKey.isEmpty {
            data.append(output.tokenPublicKey)
        } else {
            data.append(Data(count: 33))
        }

        // Token identifier (32 zero bytes if absent)
        if output.hasTokenIdentifier && !output.tokenIdentifier.isEmpty {
            data.append(output.tokenIdentifier)
        } else {
            data.append(Data(count: 32))
        }

        if !output.tokenAmount.isEmpty {
            data.append(output.tokenAmount)
        }

        allHashes.append(sha256(data))
    }

    // Hash sorted operator identity public keys
    let sortedPubKeys = tx.sparkOperatorIdentityPublicKeys.sorted { $0.lexicographicallyPrecedes($1) }
    allHashes.append(sha256(uint32BE(UInt32(sortedPubKeys.count))))
    for pubKey in sortedPubKeys {
        allHashes.append(sha256(pubKey))
    }

    // Hash network
    allHashes.append(sha256(uint32BE(UInt32(tx.network.rawValue))))

    // Hash client created timestamp (milliseconds as uint64 BE)
    let clientMs = UInt64(tx.clientCreatedTimestamp.seconds) * 1000
        + UInt64(tx.clientCreatedTimestamp.nanos / 1_000_000)
    allHashes.append(sha256(uint64BE(clientMs)))

    if !partialHash {
        // Hash expiry time (seconds as uint64 BE)
        let expirySecs = tx.hasExpiryTime ? UInt64(tx.expiryTime.seconds) : 0
        allHashes.append(sha256(uint64BE(expirySecs)))
    }

    // Hash invoice attachments (V2)
    let attachments = tx.invoiceAttachments
    allHashes.append(sha256(uint32BE(UInt32(attachments.count))))
    // Sort invoices by their raw string for deterministic ordering
    let sorted = attachments.sorted { $0.sparkInvoice < $1.sparkInvoice }
    for attachment in sorted {
        allHashes.append(sha256(Data(attachment.sparkInvoice.utf8)))
    }

    // Final hash of all concatenated hashes
    var concatenated = Data()
    for h in allHashes { concatenated.append(h) }
    return sha256(concatenated)
}

/// Hash an operator-specific token transaction signable payload.
func hashOperatorSpecificPayload(
    finalTokenTransactionHash: Data,
    operatorIdentityPublicKey: Data
) throws -> Data {
    guard finalTokenTransactionHash.count == 32 else {
        throw SparkError.invalidResponse("Final token transaction hash must be 32 bytes")
    }
    guard !operatorIdentityPublicKey.isEmpty else {
        throw SparkError.invalidResponse("Operator identity public key cannot be empty")
    }

    var allHashes: [Data] = []
    allHashes.append(sha256(finalTokenTransactionHash))
    allHashes.append(sha256(operatorIdentityPublicKey))

    var concatenated = Data()
    for h in allHashes { concatenated.append(h) }
    return sha256(concatenated)
}

// MARK: - Helpers

private func sha256(_ data: Data) -> Data {
    Data(CryptoKit.SHA256.hash(data: data))
}

private func uint32BE(_ value: UInt32) -> Data {
    var v = value.bigEndian
    return Data(bytes: &v, count: 4)
}

private func uint64BE(_ value: UInt64) -> Data {
    var v = value.bigEndian
    return Data(bytes: &v, count: 8)
}
