// swift-tools-version:5.9
// On-device IPA signing for Ferry, built on zsign (MIT, see LICENSE-zsign).

import PackageDescription

let zsignSearchPaths: [String] = ["zsign", "zsign/common", "zsign/third-party/minizip"]

let package = Package(
    name: "ZSignKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ZSignKit", targets: ["ZSignKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", exact: "3.6.5000"),
    ],
    targets: [
        .target(
            name: "CZSign",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")],
            path: "Sources/CZSign",
            cSettings: zsignSearchPaths.map { CSetting.headerSearchPath($0) } + [
                .define("ZSIGN_IOS_APP"),
            ],
            cxxSettings: zsignSearchPaths.map { CXXSetting.headerSearchPath($0) } + [
                .define("ZSIGN_IOS_APP"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "ZSignKit",
            dependencies: ["CZSign"],
            path: "Sources/ZSignKit"
        ),
    ],
    cxxLanguageStandard: .cxx14
)
