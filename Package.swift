// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FreeMacMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FreeMacMonitor",
            path: "Sources/FreeMacMonitor",
            exclude: ["Resources"],      // copied to .app bundle by build.sh, not via SPM
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
