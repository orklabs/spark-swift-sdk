// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SparkSDK",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SparkSDK", targets: ["SparkSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.1.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/GigaBitcoin/secp256k1.swift.git", exact: "0.18.0"),
    ],
    targets: [
        .binaryTarget(
            name: "spark_frostFFI",
            path: "Frameworks/spark_frostFFI.xcframework"
        ),
        .target(
            name: "SparkSDK",
            dependencies: [
                "spark_frostFFI",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "secp256k1", package: "secp256k1.swift"),
            ],
            path: "Sources/SparkSDK"
        ),
        .testTarget(
            name: "SparkSDKTests",
            dependencies: ["SparkSDK"],
            path: "Tests/SparkSDKTests"
        ),
    ]
)
