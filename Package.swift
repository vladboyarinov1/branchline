// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Branchline",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .executableTarget(name: "Branchline", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "BranchlineTests", dependencies: ["Branchline"])
    ]
)
