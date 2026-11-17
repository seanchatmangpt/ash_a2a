// swift-tools-version:5.9
// SA2A native approver (RFC-SA2A-007 E-I WYSIWYS). Independent of the Elixir build:
// nothing in mix.exs references this directory.
import PackageDescription

// SwiftUI targets exist only where SwiftUI does; Linux builds Core, the CLI and the tests.
#if os(Linux)
let uiProducts = [Product]()
let uiTargets = [Target]()
#else
let uiProducts: [Product] = [
    .library(name: "SA2AApproverUI", targets: ["SA2AApproverUI"]),
    .executable(name: "SA2AApproverMac", targets: ["SA2AApproverMac"]),
]
let uiTargets: [Target] = [
    .target(name: "SA2AApproverUI", dependencies: ["SA2AApproverCore"]),
    .executableTarget(name: "SA2AApproverMac", dependencies: ["SA2AApproverCore", "SA2AApproverUI"]),
]
#endif

let package = Package(
    name: "sa2a-approver",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SA2AApproverCore", targets: ["SA2AApproverCore"]),
        .executable(name: "sa2a-approver", targets: ["sa2a-approver"]),
    ] + uiProducts,
    dependencies: [
        // CryptoKit is Apple-only; on Linux the same P256/SHA256 API comes from swift-crypto
        // (module `Crypto`). The Secure Enclave signer stays macOS/iOS-only (see Signer.swift).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.9.1"),
    ],
    targets: [
        .target(
            name: "SA2AApproverCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))]),
        .executableTarget(name: "sa2a-approver", dependencies: ["SA2AApproverCore"]),
        // iOS app shell: source only; built by an Xcode iOS app target (see docs/how-to/approver-apps.md).
        .testTarget(
            name: "SA2AApproverCoreTests",
            dependencies: [
                "SA2AApproverCore",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            resources: [.copy("Fixtures")]
        ),
    ] + uiTargets
)
