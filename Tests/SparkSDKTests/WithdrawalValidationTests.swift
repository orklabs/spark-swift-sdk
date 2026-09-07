import Foundation
import Testing
@testable import SparkSDK

/// Pins the client-side checks on the SSP's cooperative-exit response — the checks that stop a
/// misbehaving or impersonated SSP from taking leaves in exchange for an exit transaction that
/// does not pay the user.
@Suite("Cooperative exit validation")
struct WithdrawalValidationTests {

    private let payoutAddress = "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0"
    private let payoutScript = Data(hexString: "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
    private let sspScript = Data(hexString: "0014")! + Data(repeating: 0x99, count: 20)

    /// An exit transaction paying `payoutSats` to the user plus change to the SSP.
    private func exitTransaction(payoutSats: UInt64, payTo script: Data? = nil) -> RawTransaction {
        RawTransaction(
            version: 2,
            inputs: [RawTransaction.Input(previousTxid: Data(repeating: 0xAB, count: 32), previousIndex: 0)],
            outputs: [
                RawTransaction.Output(value: 50_000, scriptPubKey: sspScript),
                RawTransaction.Output(value: payoutSats, scriptPubKey: script ?? payoutScript),
            ],
            locktime: 0,
            hasWitnessSerialization: true
        )
    }

    /// A connector transaction spending `parentTxid` with one output per leaf plus the SSP's.
    private func connectorTransaction(spending parentTxid: Data, leafCount: Int) -> RawTransaction {
        RawTransaction(
            version: 2,
            inputs: [RawTransaction.Input(previousTxid: parentTxid, previousIndex: 1)],
            outputs: (0..<(leafCount + 1)).map { _ in RawTransaction.Output(value: 330, scriptPubKey: sspScript) },
            locktime: 0,
            hasWitnessSerialization: false
        )
    }

    private func validate(
        exit: RawTransaction, connector: RawTransaction, txidHex: String? = nil,
        address: String? = nil, minimumPayout: Int64 = 9_000, leafCount: Int = 2, network: SparkNetwork = .mainnet
    ) throws -> CoopExitValidator.ValidatedExit {
        try CoopExitValidator.validate(
            rawCoopExitTransactionHex: exit.serialized(includeWitness: true).hexString,
            rawConnectorTransactionHex: connector.serialized(includeWitness: true).hexString,
            coopExitTxidHex: txidHex ?? exit.txidHex,
            payoutAddress: address ?? payoutAddress,
            minimumPayoutSats: minimumPayout,
            leafCount: leafCount,
            network: network
        )
    }

    @Test("A consistent SSP response is accepted and yields the exit txid in internal order")
    func acceptsConsistentResponse() throws {
        let exit = exitTransaction(payoutSats: 9_000)
        let connector = connectorTransaction(spending: exit.txid, leafCount: 2)
        let validated = try validate(exit: exit, connector: connector)
        #expect(validated.exitTxid == exit.txid)
        #expect(validated.exitTxid == Data(Data(hexString: exit.txidHex)!.reversed()))
        #expect(validated.payoutVout == 1)
        #expect(validated.payoutSats == 9_000)
        #expect(validated.connectorTx == connector)

        // A payout above the minimum is fine; a txid given in internal byte order is fine too.
        _ = try validate(exit: exitTransaction(payoutSats: 20_000), connector: connectorTransaction(spending: exitTransaction(payoutSats: 20_000).txid, leafCount: 2))
        _ = try validate(exit: exit, connector: connector, txidHex: exit.txid.hexString)
    }

    @Test("An exit transaction that underpays or pays someone else is refused")
    func refusesBadPayout() throws {
        let short = exitTransaction(payoutSats: 8_999)
        #expect(throws: SparkError.self) {
            _ = try validate(exit: short, connector: connectorTransaction(spending: short.txid, leafCount: 2))
        }
        let elsewhere = exitTransaction(payoutSats: 9_000, payTo: Data(hexString: "5120")! + Data(repeating: 0x42, count: 32))
        #expect(throws: SparkError.self) {
            _ = try validate(exit: elsewhere, connector: connectorTransaction(spending: elsewhere.txid, leafCount: 2))
        }
        // Right address, wrong network for the wallet.
        let exit = exitTransaction(payoutSats: 9_000)
        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connectorTransaction(spending: exit.txid, leafCount: 2), network: .regtest)
        }
        // Several outputs to the address are summed per output, not across outputs.
        var split = exitTransaction(payoutSats: 4_500)
        split.outputs.append(RawTransaction.Output(value: 4_500, scriptPubKey: payoutScript))
        #expect(throws: SparkError.self) {
            _ = try validate(exit: split, connector: connectorTransaction(spending: split.txid, leafCount: 2))
        }
    }

    @Test("The reported txid must match the raw exit transaction")
    func refusesTxidMismatch() throws {
        let exit = exitTransaction(payoutSats: 9_000)
        let connector = connectorTransaction(spending: exit.txid, leafCount: 2)
        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connector, txidHex: String(repeating: "ab", count: 32))
        }
        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connector, txidHex: "not hex")
        }
        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connector, txidHex: exit.txidHex + "00")
        }
    }

    @Test("The connector transaction must spend the exit transaction and carry one output per leaf")
    func refusesUnboundConnector() throws {
        let exit = exitTransaction(payoutSats: 9_000)
        let other = connectorTransaction(spending: Data(repeating: 0x77, count: 32), leafCount: 2)
        #expect(throws: SparkError.self) { _ = try validate(exit: exit, connector: other) }

        var noInputs = connectorTransaction(spending: exit.txid, leafCount: 2)
        noInputs.inputs = []
        #expect(throws: SparkError.self) { _ = try validate(exit: exit, connector: noInputs) }

        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connectorTransaction(spending: exit.txid, leafCount: 1), leafCount: 2)
        }
        #expect(throws: SparkError.self) {
            _ = try validate(exit: exit, connector: connectorTransaction(spending: exit.txid, leafCount: 3), leafCount: 2)
        }
        // Reversed byte order in the connector's prevout is tolerated, like the operators do.
        let reversed = connectorTransaction(spending: Data(exit.txid.reversed()), leafCount: 2)
        _ = try validate(exit: exit, connector: reversed)
    }

    @Test("Garbage transaction hex and bad addresses are refused without signing")
    func refusesMalformedInput() throws {
        let exit = exitTransaction(payoutSats: 9_000)
        let connector = connectorTransaction(spending: exit.txid, leafCount: 2)
        #expect(throws: SparkError.self) {
            _ = try CoopExitValidator.validate(
                rawCoopExitTransactionHex: "zz", rawConnectorTransactionHex: connector.serialized(includeWitness: true).hexString,
                coopExitTxidHex: exit.txidHex, payoutAddress: payoutAddress, minimumPayoutSats: 9_000, leafCount: 2, network: .mainnet
            )
        }
        #expect(throws: SparkError.self) {
            _ = try CoopExitValidator.validate(
                rawCoopExitTransactionHex: exit.serialized(includeWitness: true).hexString, rawConnectorTransactionHex: "0100",
                coopExitTxidHex: exit.txidHex, payoutAddress: payoutAddress, minimumPayoutSats: 9_000, leafCount: 2, network: .mainnet
            )
        }
        #expect(throws: SparkError.self) { _ = try validate(exit: exit, connector: connector, address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5") }
        #expect(throws: SparkError.self) { _ = try validate(exit: exit, connector: connector, minimumPayout: 0) }
    }

    @Test("The fee cap is the SSP quote bounded by the caller's maximum")
    func feeCap() throws {
        #expect(try CoopExitValidator.resolveFeeCap(quotedFeeSats: 100, maxFeeSats: nil, amountSats: 1_000) == 100)
        #expect(try CoopExitValidator.resolveFeeCap(quotedFeeSats: 100, maxFeeSats: 200, amountSats: 1_000) == 200)
        #expect(try CoopExitValidator.resolveFeeCap(quotedFeeSats: 0, maxFeeSats: nil, amountSats: 1) == 0)

        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 201, maxFeeSats: 200, amountSats: 1_000) }
        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 1_000, maxFeeSats: nil, amountSats: 1_000) }
        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 10, maxFeeSats: 5_000, amountSats: 1_000) }
        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: -1, maxFeeSats: nil, amountSats: 1_000) }
        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 1, maxFeeSats: -1, amountSats: 1_000) }
        #expect(throws: SparkError.self) { _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 1, maxFeeSats: nil, amountSats: 0) }

        do {
            _ = try CoopExitValidator.resolveFeeCap(quotedFeeSats: 300, maxFeeSats: 250, amountSats: 1_000)
            Issue.record("expected feeExceedsLimit")
        } catch SparkError.feeExceedsLimit(let fee, let max) {
            #expect(fee == 300)
            #expect(max == 250)
        }
    }

    @Test("Exact leaf selection never overshoots the requested amount")
    func exactSelection() throws {
        func leaf(_ id: String, _ sats: Int64) -> SparkLeaf {
            SparkLeaf(id: id, treeID: "t", valueSats: sats, status: "AVAILABLE", node: Spark_TreeNode())
        }
        let leaves = [leaf("a", 100_000), leaf("b", 8_192), leaf("c", 1_024), leaf("d", 512)]
        // The old greedy `selectLeaves` would hand the 100k leaf to the SSP for a 1k withdrawal.
        #expect(try SparkWallet.selectLeaves(leaves, amountSats: 1_000).map(\.id) == ["a"])
        // Exact selection either finds the exact denominations or reports that a swap is needed.
        #expect(SparkWallet.tryExactSelection(leaves, amountSats: 1_000) == nil)
        #expect(SparkWallet.tryExactSelection(leaves, amountSats: 1_536)?.map(\.id) == ["c", "d"])
        #expect(SparkWallet.tryExactSelection(leaves, amountSats: 109_728)?.map(\.id) == ["a", "b", "c", "d"])
        if let picked = SparkWallet.tryExactSelection(leaves, amountSats: 9_216) {
            #expect(picked.reduce(0) { $0 + $1.valueSats } == 9_216)
        } else {
            Issue.record("expected an exact selection")
        }
    }
}

@Suite("Spendable leaf selection")
struct SpendableLeafTests {
    private func leaf(_ id: String, sats: Int64, timelock: UInt32) -> SparkLeaf {
        let refund = RawTransaction(
            version: 2,
            inputs: [RawTransaction.Input(previousTxid: Data(repeating: 1, count: 32), previousIndex: 0, sequence: (1 << 30) | timelock)],
            outputs: [RawTransaction.Output(value: UInt64(sats), scriptPubKey: Data([0x51, 0x20]) + Data(repeating: 2, count: 32))],
            locktime: 0, hasWitnessSerialization: false
        )
        var node = Spark_TreeNode()
        node.id = id
        node.refundTx = refund.serialized(includeWitness: true)
        return SparkLeaf(id: id, treeID: "t", valueSats: sats, status: "AVAILABLE", node: node)
    }

    @Test("Leaves at or below the timelock floor are never selected for spending")
    func floorLeavesExcluded() {
        let leaves = [leaf("stuck0", sats: 8, timelock: 0), leaf("stuck100", sats: 8, timelock: 100),
                      leaf("ok200", sats: 8, timelock: 200), leaf("ok2000", sats: 2, timelock: 2000)]
        #expect(SparkWallet.movableLeaves(leaves).map(\.id) == ["ok200", "ok2000"])
        // The greedy exact selection over movable leaves finds the healthy 8 + 2 for a 10-sat send.
        #expect(SparkWallet.tryExactSelection(SparkWallet.movableLeaves(leaves), amountSats: 10)?.map(\.id) == ["ok200", "ok2000"])
        var empty = Spark_TreeNode()
        empty.id = "garbage"
        #expect(SparkWallet.movableLeaves([SparkLeaf(id: "garbage", treeID: "t", valueSats: 5, status: "AVAILABLE", node: empty)]).isEmpty)
    }

    @Test("Renewal candidates: [100, 200) renewable, below 100 stuck, 200 and above healthy")
    func renewalCandidates() {
        let leaves = [leaf("a", sats: 1, timelock: 0), leaf("b", sats: 1, timelock: 99), leaf("c", sats: 1, timelock: 100),
                      leaf("d", sats: 1, timelock: 199), leaf("e", sats: 1, timelock: 200), leaf("f", sats: 1, timelock: 2000)]
        let (renewable, stuck) = SparkWallet.renewalCandidates(leaves)
        #expect(renewable.map(\.id) == ["c", "d"])
        #expect(stuck.map(\.id) == ["a", "b"])
    }
}
