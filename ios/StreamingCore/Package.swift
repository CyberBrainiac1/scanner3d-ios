// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScannerStreamingCore",
    platforms: [.iOS("18.6"), .macOS(.v13)],
    products: [.library(name: "ScannerStreamingCore", targets: ["ScannerStreamingCore"])],
    targets: [
        .target(name: "ScannerStreamingCore"),
        .testTarget(name: "ScannerStreamingCoreTests", dependencies: ["ScannerStreamingCore"],
                    resources: [.copy("Fixtures")])
    ]
)
