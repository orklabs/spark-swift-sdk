import Foundation
import GRPCCore

/// Status of a Spark invoice.
public struct SparkInvoiceStatus: Sendable {
    public let invoice: String
    public let status: String
    /// Transfer ID (hex) if the invoice has been paid with a sats transfer.
    public let satsTransferId: String?
    /// Token transaction hash (hex) if the invoice has been paid with a token transfer.
    public let tokenTransactionHash: String?
}

extension SparkWallet {

    /// Query the status of Spark invoices and get associated transfer IDs.
    ///
    /// This is the primary way to match Spark invoices to the transfers that paid them.
    public func querySparkInvoices(
        invoices: [String],
        limit: Int64 = 0,
        offset: Int64 = 0
    ) async throws -> [SparkInvoiceStatus] {
        let client = try await getCoordinatorClient()
        let metadata = try await getAuthMetadata(for: config.coordinatorAddress)

        var request = Spark_QuerySparkInvoicesRequest()
        request.invoice = invoices
        if limit > 0 { request.limit = limit }
        if offset > 0 { request.offset = offset }

        let response = try await client.query_spark_invoices(
            request: ClientRequest(message: request, metadata: metadata)
        )

        return response.invoiceStatuses.map { invoiceResp in
            var satsTransferId: String? = nil
            var tokenTxHash: String? = nil

            switch invoiceResp.transferType {
            case .satsTransfer(let sats):
                if !sats.transferID.isEmpty {
                    satsTransferId = sats.transferID.hexString
                }
            case .tokenTransfer(let token):
                if !token.finalTokenTransactionHash.isEmpty {
                    tokenTxHash = token.finalTokenTransactionHash.hexString
                }
            default:
                break
            }

            return SparkInvoiceStatus(
                invoice: invoiceResp.invoice,
                status: "\(invoiceResp.status)",
                satsTransferId: satsTransferId,
                tokenTransactionHash: tokenTxHash
            )
        }
    }
}
