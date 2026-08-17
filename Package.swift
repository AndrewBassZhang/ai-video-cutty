// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaPreview",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MediaPreview", targets: ["MediaPreview"])],
    targets: [
        .executableTarget(name: "MediaPreview"),
        .testTarget(name: "MediaPreviewTests", dependencies: ["MediaPreview"])
    ]
)
