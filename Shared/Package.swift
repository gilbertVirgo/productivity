// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "StintData", targets: ["StintData"]),
    ],
    dependencies: [.package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0")],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .target(name: "StintData", dependencies: ["Core", .product(name: "Supabase", package: "supabase-swift")]),
        .testTarget(name: "StintDataTests", dependencies: ["StintData"]),
    ]
)
