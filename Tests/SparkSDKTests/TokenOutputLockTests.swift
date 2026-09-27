import Foundation
import GRPCCore
import Testing
@testable import SparkSDK

/// Which token outputs a send may pick, as the reference SDK's `TokenOutputManager` decides it:
/// only AVAILABLE ones, and none another send from the wallet has picked in the last 30 s.
@Suite("Token output locks")
struct TokenOutputLockTests {
    typealias Output = SparkToken_OutputWithPreviousTransactionData

    static func output(
        vout: UInt32,
        amount: UInt128 = 100,
        status: SparkToken_TokenOutputStatus = .available,
        owner: Data = Data(repeating: 0x02, count: 33)
    ) -> Output {
        var output = Output()
        output.output.ownerPublicKey = owner
        output.output.tokenIdentifier = Data(repeating: 0x01, count: 32)
        output.output.tokenAmount = encodeUInt128(amount)
        output.output.status = status
        output.previousTransactionHash = Data(repeating: 0xAA, count: 32)
        output.previousTransactionVout = vout
        return output
    }

    static func keys(_ outputs: [Output]) -> [String] {
        outputs.map(TokenOutputLocks.key)
    }

    @Test("Only AVAILABLE outputs are offered, and the picked ones are not offered again")
    func availableOnly() throws {
        let locks = TokenOutputLocks()
        let outputs = [Self.output(vout: 0), Self.output(vout: 1, status: .pendingOutbound), Self.output(vout: 2)]
        let first = try locks.acquire(outputs) { Array($0.prefix(1)) }
        #expect(Self.keys(first) == Self.keys([outputs[0]]))
        let rest = try locks.acquire(outputs) { $0 }
        #expect(Self.keys(rest) == Self.keys([outputs[2]]))
        #expect(try locks.acquire(outputs) { $0 }.isEmpty)
    }

    @Test("A lock ends after its expiry")
    func expiry() async throws {
        let locks = TokenOutputLocks(expiry: .milliseconds(100))
        let outputs = [Self.output(vout: 0)]
        #expect(try locks.acquire(outputs) { $0 }.count == 1)
        #expect(try locks.acquire(outputs) { $0 }.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try locks.acquire(outputs) { $0 }.count == 1)
    }

    @Test("An output the operators report pending loses its lock, and can be picked once available again")
    func pendingEndsLock() throws {
        let locks = TokenOutputLocks()
        #expect(try locks.acquire([Self.output(vout: 0)]) { $0 }.count == 1)
        #expect(try locks.acquire([Self.output(vout: 0, status: .pendingOutbound)]) { $0 }.isEmpty)
        // The pending transaction expired: the operators report the output AVAILABLE again.
        #expect(try locks.acquire([Self.output(vout: 0)]) { $0 }.count == 1)
    }

    @Test("A pick that fails locks nothing")
    func failedPick() throws {
        let locks = TokenOutputLocks()
        let outputs = [Self.output(vout: 0)]
        #expect(throws: SparkError.self) {
            _ = try locks.acquire(outputs) { try SparkWallet.selectTokenOutputs($0, amount: 500, strategy: .smallFirst) }
        }
        #expect(try locks.acquire(outputs) { $0 }.count == 1)
    }

    @Test("Concurrent picks never share an output")
    func concurrentPicks() async throws {
        let locks = TokenOutputLocks()
        let outputs = (0..<50).map { Self.output(vout: UInt32($0)) }
        let picked = try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0..<50 {
                group.addTask { Self.keys(try locks.acquire(outputs) { Array($0.prefix(1)) }) }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        #expect(picked.count == 50)
        #expect(Set(picked).count == 50)
    }
}

/// Sends against the operator stand-in, whose `start_transaction` records the outputs each
/// transaction spends and then refuses it.
extension TokenOutputLockTests {
    static let tokenIdentifier = Data(repeating: 0x01, count: 32)

    /// Outputs of `amounts`, owned by `wallet`, with `statuses` (AVAILABLE when not given).
    static func walletOutputs(
        _ wallet: SparkWallet,
        amounts: [UInt128],
        statuses: [SparkToken_TokenOutputStatus] = []
    ) throws -> [Output] {
        let owner = try #require(Data(hexString: wallet.identityPublicKeyHex))
        return amounts.enumerated().map { index, amount in
            output(vout: UInt32(index), amount: amount, status: index < statuses.count ? statuses[index] : .available, owner: owner)
        }
    }

    /// Sends 100 of the test token from `wallet` to itself.
    static func send(from wallet: SparkWallet) async throws {
        let token = try encodeBech32mTokenIdentifier(tokenIdentifier, network: .regtest)
        _ = try await wallet.transferTokens(tokenIdentifier: token, tokenAmount: 100, receiverSparkAddress: wallet.getSparkAddress())
    }

    @Test("A send skips outputs the operators report pending", .timeLimit(.minutes(1)))
    func sendSkipsPending() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            let outputs = try Self.walletOutputs(wallet, amounts: [100, 100], statuses: [.pendingOutbound, .available])
            await state.setTokenOutputs(outputs)
            await #expect(throws: RPCError.self) { try await Self.send(from: wallet) }
            #expect(await state.startedSpends == [Self.keys([outputs[1]])])
        }
    }

    @Test("A send does not pick the outputs of one that may still be in flight", .timeLimit(.minutes(1)))
    func sendsDoNotShareOutputs() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            let outputs = try Self.walletOutputs(wallet, amounts: [100, 100])
            await state.setTokenOutputs(outputs)
            let token = try encodeBech32mTokenIdentifier(Self.tokenIdentifier, network: .regtest)
            // The first send's start fails, but the operators may hold it: its output stays locked.
            await #expect(throws: RPCError.self) { try await Self.send(from: wallet) }
            await #expect(throws: RPCError.self) {
                _ = try await wallet.burnTokens(tokenIdentifier: token, tokenAmount: 100)
            }
            #expect(await state.startedSpends == [Self.keys([outputs[0]]), Self.keys([outputs[1]])])
            // Nothing left to pick: refused before anything reaches the operators.
            await #expect(throws: SparkError.self) { try await Self.send(from: wallet) }
            #expect(await state.startedSpends.count == 2)
        }
    }

    @Test("Concurrent sends spend different outputs", .timeLimit(.minutes(1)))
    func concurrentSends() async throws {
        let state = FakeOperatorState { _ in false }
        try await withFakeOperator(state) { wallet in
            await state.setTokenOutputs(try Self.walletOutputs(wallet, amounts: [100, 100]))
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<2 {
                    group.addTask { try? await Self.send(from: wallet) }
                }
            }
            let spends = await state.startedSpends
            #expect(spends.count == 2)
            #expect(Set(spends.flatMap { $0 }).count == 2)
        }
    }
}
