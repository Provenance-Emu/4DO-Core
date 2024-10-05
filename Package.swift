// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

enum Sources {
    static let libfreedo: [String] = [
        "DSP.cpp",
        "DiagPort.cpp",
        "Iso.cpp",
        "Madam.cpp",
        "SPORT.cpp",
        "XBUS.cpp",
        "_3do_sys.cpp",
        "arm.cpp",
        "bitop.cpp",
        "Clio.cpp",
        "frame.cpp",
        "quarz.cpp",
        "vdlp.cpp"
    ]

    static let libcue: [String] = [
        "cd.c",
        "cdtext.c",
        "cue_parser.c",
        "cue_scanner.c",
        "rem.c",
        "time.c"
    ]
}

let package = Package(
    name: "PVFreeDO",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .tvOS("15.4"),
        .watchOS(.v9),
        .macOS(.v11),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "PVFreeDO",
            targets: ["PVFreeDOGameCore"]),
        .library(
            name: "PVFreeDO-Dynamic",
            type: .dynamic,
            targets: ["PVFreeDOGameCore"]),
        .library(
            name: "PVFreeDO-Static",
            type: .static,
            targets: ["PVFreeDOGameCore"]),
    ],
    dependencies: [
        .package(path: "../../PVCoreBridge"),
        .package(path: "../../PVCoreObjCBridge"),
        .package(path: "../../PVPlists"),
        .package(path: "../../PVEmulatorCore"),
        .package(path: "../../PVSupport"),
        .package(path: "../../PVAudio"),
        .package(path: "../../PVLogging"),
        .package(path: "../../PVObjCUtils"),

        .package(url: "https://github.com/Provenance-Emu/SwiftGenPlugin.git", branch: "develop"),
    ],
    targets: [
        
        // MARK: --------- PVFreeDO Core ---------- //

        .target(
            name: "PVFreeDOGameCore",
            dependencies: [
                "PVEmulatorCore",
                "PVCoreBridge",
                "PVCoreObjCBridge",
                "PVLogging",
                "PVAudio",
                "PVSupport",
                "libfreedo",
                "PVFreeDOGameCoreBridge",
                "PVFreeDOGameCoreOptions"
            ],
            resources: [
                .process("Resources/Core.plist")
            ],
            cSettings: [
                .unsafeFlags(["-fmodules", "-fcxx-modules"]),
                .define("INLINE", to: "inline"),
                .define("USE_STRUCTS", to: "1"),
                .define("__LIBRETRO__", to: "1"),
                .define("HAVE_COCOATOUCH", to: "1"),
                .define("__GCCUNIX__", to: "1"),
                .headerSearchPath("../virtualjaguar-libretro/src"),
                .headerSearchPath("../virtualjaguar-libretro/src/m68000"),
                .headerSearchPath("../virtualjaguar-libretro/libretro-common"),
                .headerSearchPath("../virtualjaguar-libretro/libretro-common/include"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ],
            plugins: [
                .plugin(name: "SwiftGenPlugin", package: "SwiftGenPlugin")
            ]
        ),

        // MARK: --------- PVFreeDO Bridge ---------- //

        .target(
            name: "PVFreeDOGameCoreBridge",
            dependencies: [
                "libfreedo",
                "PVEmulatorCore",
                "PVCoreBridge",
                "PVCoreObjCBridge",
                "PVSupport",
                "PVPlists",
                "PVObjCUtils",
                "PVFreeDOGameCoreOptions"
            ],
            cSettings: [
                .unsafeFlags(["-fmodules", "-fcxx-modules"]),
                .define("INLINE", to: "inline"),
                .define("USE_STRUCTS", to: "1"),
                .define("__LIBRETRO__", to: "1"),
                .define("HAVE_COCOATOUCH", to: "1"),
                .define("__GCCUNIX__", to: "1"),
            ]
        ),
        // MARK: ---------  Options  ---------- //
        .target(
            name: "PVFreeDOGameCoreOptions",
            dependencies: [
                "PVEmulatorCore",
                "PVCoreBridge",
                "PVLogging",
                "PVSupport",
                "libfreedo",
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        // MARK: --------- libfreedo ---------- //

        .target(
            name: "libfreedo",
            dependencies: ["libcue"],
            sources: Sources.libfreedo.map { "libfreedo/\($0)" },
            packageAccess: true,
            cSettings: [
                .unsafeFlags(["-fmodules", "-fcxx-modules"]),
                .define("INLINE", to: "inline"),
                .define("USE_STRUCTS", to: "1"),
                .define("__LIBRETRO__", to: "1"),
                .define("HAVE_COCOATOUCH", to: "1"),
                .define("__GCCUNIX__", to: "1"),
                .define("__fastcall", to: "", .when(platforms: [.iOS, .tvOS, .visionOS])), // Not supported on iOS
                .define("__fastcall__", to: "", .when(platforms: [.iOS, .tvOS, .visionOS])), // Not supported on iOS
                .headerSearchPath("virtualjaguar-libretro/src"),
                .headerSearchPath("src"),
                .headerSearchPath("libretro-common/include")
            ]
        ),

        // MARK: --------- libfreedo > libcue ---------- //

        .target(
            name: "libcue",
            sources: Sources.libcue.map { "libcue-1.4.0/src/libcue/\($0)" },
            packageAccess: false,
            cSettings: [
                .define("__fastcall", to: "", .when(platforms: [.iOS, .tvOS, .visionOS])), // Not supported on iOS
                .headerSearchPath("./include"),
                .headerSearchPath("./libcue-1.4.0/src/libcue"),
                .headerSearchPath("./libcue-1.4.0/"),
            ]
        ),
        // MARK: Tests
        .testTarget(
            name: "PVFreeDOTests",
            dependencies: [
                "PVFreeDOGameCore",
                "PVFreeDOGameCoreBridge",
                "libfreedo",
                "PVCoreBridge",
                "PVEmulatorCore"
            ],
            resources: [
                .copy("Resources/3DO 240p Calibration Suite V1C.iso")
            ]
        )
    ],
    swiftLanguageModes: [.v5, .v6],
    cLanguageStandard: .gnu17,
    cxxLanguageStandard: .gnucxx20
)
