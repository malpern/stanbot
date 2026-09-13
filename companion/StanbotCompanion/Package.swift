// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StanbotCompanion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StanbotCompanion", targets: ["StanbotCompanion"])],
    targets: [.executableTarget(name: "StanbotCompanion")]
)
