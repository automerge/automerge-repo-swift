// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IntegrationTests",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [],
    dependencies: [
        .package(path: "../"),
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
