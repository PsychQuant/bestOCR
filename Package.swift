// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "bestocr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bestocr", targets: ["bestocr"]),
        .executable(name: "bestocr-mcp", targets: ["bestocr-mcp"]),
        .library(name: "BestOCRKit", targets: ["BestOCRKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/PsychQuant/ocr-swift.git", from: "0.2.1"),
        .package(url: "https://github.com/PsychQuant/pdf-to-latex-swift.git", from: "0.1.0"),
        // MCP surface — same SDK family as bestASR / the che-mcps servers
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            .upToNextMinor(from: "0.12.0")),
    ],
    targets: [
        .target(
            name: "BestOCRKit",
            dependencies: [
                .product(name: "OCRCore", package: "ocr-swift"),
                .product(name: "PDFToLaTeXCore", package: "pdf-to-latex-swift"),
            ]
        ),
        .executableTarget(
            name: "bestocr",
            dependencies: [
                "BestOCRKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "BestOCRMCPCore",
            dependencies: [
                "BestOCRKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "bestocr-mcp", dependencies: ["BestOCRMCPCore"]),
        .testTarget(name: "BestOCRKitTests", dependencies: ["BestOCRKit"]),
        .testTarget(name: "BestOCRMCPCoreTests", dependencies: ["BestOCRMCPCore"]),
    ]
)
