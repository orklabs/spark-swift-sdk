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
