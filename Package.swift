// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "iPhoneBridge",
    platforms: [.macOS(.v13)],
    targets: [
        // Headers and link flags come from Homebrew via pkg-config, so no paths are hard-coded.
        .systemLibrary(
            name: "CIMobileDevice",
            pkgConfig: "libimobiledevice-1.0",
            providers: [.brew(["libimobiledevice"])]
        ),
        .executableTarget(name: "iPhoneBridge", dependencies: ["CIMobileDevice"]),
    ]
)
