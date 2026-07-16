// swift-tools-version: 5.10
import PackageDescription

// AppUI — mobileLLM's "on-device intelligence" design system. Pure SwiftUI, no MLX and no runtime
// deps: colour/scale/motion tokens plus the small set of controls (Chip, Segmented, StudioButton,
// studioCard, toastBanner) in mobileLLM's ink-wash palette (水墨) with the seal's cinnabar accent.
let package = Package(
    name: "AppUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AppUI", targets: ["AppUI"]),
    ],
    targets: [
        .target(name: "AppUI"),
        .testTarget(name: "AppUITests", dependencies: ["AppUI"]),
    ]
)
