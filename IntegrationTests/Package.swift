// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IntegrationTests",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [],
    dependencies: [
        .package(path: "../"),
        // .package(url: "https://github.com/automerge/automerge-repo-swift.git", branch: "main"),
        // Distributed Tracing
        // .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.0.0"),
        // Testing Tracing
        .package(url: "https://github.com/heckj/DistributedTracer", branch: "main"),
        // this ^^ brings in a MASSIVE cascade of dependencies
    ],
    targets: [
        .testTarget(
            name: "AutomergeRepoIntegrationTests",
            dependencies: [
                .product(name: "AutomergeRepo", package: "automerge-repo-swift"),
                .product(name: "DistributedTracer", package: "DistributedTracer"),
            ]
        ),
    ]
)
