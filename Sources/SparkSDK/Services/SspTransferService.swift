import Foundation

extension SparkWallet {

    /// Get a transfer from the SSP along with its associated user request.
    ///
    /// This is the way to match lightning invoice payments to transfers.
    /// The SSP tracks the higher-level operation (lightning receive/send, coop exit, etc.)
    /// and can tell you which invoice a transfer is associated with.
    ///
    /// - Parameter id: The transfer's spark ID.
    /// - Returns: The transfer with its user request, or `nil` if not found.
    public func getTransferFromSsp(id: String) async throws -> TransferWithUserRequest? {
        let transfers = try await getTransfersFromSsp(ids: [id])
        return transfers.first
    }

    /// Get multiple transfers from the SSP along with their associated user requests.
    public func getTransfersFromSsp(ids: [String]) async throws -> [TransferWithUserRequest] {
        let response = try await sspClient.executeRaw(
            query: GraphQLMutations.getTransfers,
            variables: ["transfer_spark_ids": ids] as [String: any Sendable]
        )

        guard let transfers = response["transfers"] as? [[String: Any]] else {
            return []
        }

        return transfers.compactMap { Self.parseTransferWithUserRequest($0) }
    }

    private static func parseTransferWithUserRequest(_ json: [String: Any]) -> TransferWithUserRequest? {
        guard let sparkId = json["transfer_spark_id"] as? String else { return nil }

        var totalAmountSats: Int64? = nil
        if let amountObj = json["transfer_total_amount"] as? [String: Any],
           let value = amountObj["currency_amount_original_value"] as? Int64 {
            let unit = amountObj["currency_amount_original_unit"] as? String ?? ""
            if unit == "MILLISATOSHI" {
                totalAmountSats = (value + 999) / 1000
            } else {
                totalAmountSats = value
            }
        }

        var userRequest: UserRequest? = nil
        if let reqJson = json["transfer_user_request"] as? [String: Any],
           let typename = reqJson["__typename"] as? String {
            userRequest = parseUserRequest(reqJson, typename: typename)
        }

        return TransferWithUserRequest(
            sparkId: sparkId,
            totalAmountSats: totalAmountSats,
            userRequest: userRequest
        )
    }

    private static func parseUserRequest(_ json: [String: Any], typename: String) -> UserRequest {
        switch typename {
        case "LightningReceiveRequest":
            var encodedInvoice: String? = nil
            var paymentHash: String? = nil
            var amountSats: Int64? = nil
            var memo: String? = nil

            if let invoiceObj = json["lightning_receive_request_invoice"] as? [String: Any] {
                encodedInvoice = invoiceObj["invoice_encoded_invoice"] as? String
                paymentHash = invoiceObj["invoice_payment_hash"] as? String
                memo = invoiceObj["invoice_memo"] as? String
                if let amountObj = invoiceObj["invoice_amount"] as? [String: Any],
                   let value = amountObj["currency_amount_original_value"] as? Int64 {
                    let unit = amountObj["currency_amount_original_unit"] as? String ?? ""
                    amountSats = unit == "MILLISATOSHI" ? (value + 999) / 1000 : value
                }
            }

            return .lightningReceive(LightningReceiveInfo(
                id: json["lightning_receive_request_id"] as? String ?? "",
                status: json["lightning_receive_request_status"] as? String ?? "",
                encodedInvoice: encodedInvoice,
                paymentHash: paymentHash,
                amountSats: amountSats,
                memo: memo,
                paymentPreimage: json["lightning_receive_request_payment_preimage"] as? String
            ))

        case "LightningSendRequest":
            var feeSats: Int64? = nil
            if let feeObj = json["lightning_send_request_fee"] as? [String: Any],
               let value = feeObj["currency_amount_original_value"] as? Int64 {
                let unit = feeObj["currency_amount_original_unit"] as? String ?? ""
                feeSats = unit == "MILLISATOSHI" ? (value + 999) / 1000 : value
            }

            return .lightningSend(LightningSendInfo(
                id: json["lightning_send_request_id"] as? String ?? "",
                status: json["lightning_send_request_status"] as? String ?? "",
                encodedInvoice: json["lightning_send_request_encoded_invoice"] as? String,
                feeSats: feeSats,
                idempotencyKey: json["lightning_send_request_idempotency_key"] as? String,
                paymentPreimage: json["lightning_send_request_payment_preimage"] as? String
            ))

        case "CoopExitRequest":
            return .coopExit(CoopExitInfo(
                id: json["coop_exit_request_id"] as? String ?? "",
                status: json["coop_exit_request_status"] as? String ?? "",
                coopExitTxid: json["coop_exit_request_coop_exit_txid"] as? String
            ))

        case "LeavesSwapRequest":
            return .leavesSwap(LeavesSwapInfo(
                id: json["leaves_swap_request_id"] as? String ?? "",
                status: json["leaves_swap_request_status"] as? String ?? ""
            ))

        case "ClaimStaticDeposit":
            return .claimStaticDeposit(ClaimStaticDepositInfo(
                id: json["claim_static_deposit_id"] as? String ?? "",
                status: json["claim_static_deposit_status"] as? String ?? "",
                transactionId: json["claim_static_deposit_transaction_id"] as? String,
                outputIndex: json["claim_static_deposit_output_index"] as? Int
            ))

        default:
            return .unknown(typename)
        }
    }
}
