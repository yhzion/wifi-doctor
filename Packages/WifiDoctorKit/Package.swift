// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WifiDoctorKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WifiDoctorCore", targets: ["WifiDoctorCore"]),
        .library(name: "WifiDoctorProbes", targets: ["WifiDoctorProbes"]),
    ],
    targets: [
        .target(name: "WifiDoctorCore",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "WifiDoctorProbes",
                dependencies: ["WifiDoctorCore"],
                linkerSettings: [
                    .linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation"),
                    .linkedFramework("SystemConfiguration"), .linkedFramework("Network"),
                    .linkedFramework("AppKit"),
                ]),
        .testTarget(name: "WifiDoctorCoreTests", dependencies: ["WifiDoctorCore"]),
        .testTarget(name: "WifiDoctorProbesTests", dependencies: ["WifiDoctorProbes"]),
        .testTarget(name: "WifiDoctorProbesSmokeTests", dependencies: ["WifiDoctorProbes"]),
    ],
    swiftLanguageModes: [.v6]
)
