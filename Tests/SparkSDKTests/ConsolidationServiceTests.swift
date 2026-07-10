import Foundation
import Testing
@testable import SparkSDK

@Test("Binary decomposition yields the minimal power-of-two leaf set")
func binaryDecomposition() {
    #expect(SparkWallet.binaryDecomposition(of: 0) == [])
    #expect(SparkWallet.binaryDecomposition(of: 1) == [1])
    #expect(SparkWallet.binaryDecomposition(of: 121) == [64, 32, 16, 8, 1])
    #expect(SparkWallet.binaryDecomposition(of: 72965) == [65536, 4096, 2048, 1024, 256, 4, 1])
    #expect(SparkWallet.binaryDecomposition(of: 72965).reduce(0, +) == 72965)
}

@Test("P2TR address encoding matches the BIP-86 reference vector")
func p2trAddressEncoding() throws {
    // BIP-86 first receive address: output key -> bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr
    let script = Data(hexString: "5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c")!
    let address = try SparkWallet.p2trAddress(pkScript: script, network: "mainnet")
    #expect(address == "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")
    #expect(throws: SparkError.self) {
        _ = try SparkWallet.p2trAddress(pkScript: Data([0x00, 0x14]), network: "mainnet")
    }
}
