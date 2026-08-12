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
    name: "PVCore4DO",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
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
        .package(name: "PVPrimitives", path: "../../PVPrimitives/"),
        .package(name: "PVNetplay", path: "../../PVNetplay"),

        .package(url: "https://github.com/Provenance-Emu/SwiftGenPlugin.git", from: "1.1.3"),
        .package(url: "https://github.com/OlehKulykov/PLzmaSDK.git",
                 revision: "1.2.5"),
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
                "PVPrimitives",
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
                "PV4DO_libchdr",
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
                /// SPM resolves `headerSearchPath` from this target’s folder (`Sources/PVFreeDOGameCoreBridge/`), not the package root.
                .headerSearchPath("../../ThirdParty/libchdr/include"),
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
        // MARK: --------- libchdr (CHD) — vendored copy; target names prefixed so they do not clash with Mednafen’s `libchdr` / `zstd` in the workspace graph ---------- //
        .target(
            name: "PV4DO_libchdr",
            dependencies: ["PV4DO_zstd", "PLzmaSDK"],
            path: "ThirdParty/libchdr",
            exclude: [
                // No ".git" here: unlike Mednafen's libchdr, which is a real git
                // submodule and therefore has a .git file to exclude, this is a
                // vendored copy committed directly into this repo. SwiftPM treats an
                // exclude that resolves to a missing path as an error
                // ("Invalid Exclude ... File not found") and aborts package-graph
                // resolution, so listing .git here broke any cold resolve of the
                // workspace. It only appeared to work while a cached graph survived.
                ".github",
                "CMakeLists.txt",
                "README.md",
                "LICENSE.txt",
                "pkg-config.pc.in",
                "deps",
                "src/link.T"
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("deps"),
                .headerSearchPath("deps/lzma-24.05/include"),
                .define("HAVE_ZLIB", to: "1"),
                .define("HAVE_FLAC", to: "1")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "PV4DO_zstd",
            path: "ThirdParty/libchdr/deps/zstd-1.5.6/lib",
            exclude: [
                "compress",
                "dictBuilder",
                "deprecated",
                "legacy"
            ],
            sources: ["common", "decompress"],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath("."),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_STATIC_LINKING_ONLY", to: "1")
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
