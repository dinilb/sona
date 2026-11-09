// swift-tools-version: 6.2
import PackageDescription

// Build everything (app bundle included) with `make`. See README.md.
let package = Package(
    name: "Sona",
    // iOS: the iPhone app (ios/) uses NotesKit and SonaEngine, so its notes are the Mac's notes.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The app binary is SonaApp here and Contents/MacOS/Sona in the bundle (macOS disks are
        // case-insensitive, so "Sona" and the CLI's "sona" can't sit side by side in one folder).
        .executable(name: "SonaApp", targets: ["SonaApp"]),
        .executable(name: "sona", targets: ["SonaCLI"]),
        .executable(name: "sona-mcp", targets: ["sona-mcp"]),
        .executable(name: "sona-live-bench", targets: ["LiveBench"]),
        // For the iPhone app's Xcode project.
        .library(name: "NotesKit", targets: ["NotesKit"]),
        .library(name: "SonaEngine", targets: ["SonaEngine"]),
    ],
    dependencies: [
        // Pinned to a main-branch commit (24 Oct 2026). The last tag, v0.9.1, is from Jan 2026
        // and predates the offline VBx diarizer API used here.
        // Traits: only "Diarizer", so TTS and the NeMo text-normalization binary aren't linked.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "1b0ed50d686873128a4129b3510ce3914c849bab",
            traits: ["Diarizer"]
        ),
        // Sparkle: the Mac app's updater (signed updates from the appcast on the project site). The one dependency
        // that touches the network besides the model download, and only after the user agrees to update checks.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Plain files: settings, paths, writing and reading notes, the MCP server. No dependencies (just the system SQLite),
        // so sona-mcp starts instantly and never links any audio code.
        .target(
            name: "NotesKit",
            // The system SQLite, for the FTS5 search index.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Audio to notes: VAD, conversation splitting, the crash-safe spool, Parakeet + diarization.
        .target(
            name: "SonaEngine",
            dependencies: ["NotesKit", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "SonaCLI",
            dependencies: ["NotesKit", "SonaEngine"]
        ),
        .executableTarget(
            name: "sona-mcp",
            dependencies: ["NotesKit"]
        ),
        // The app: menu bar, window, live transcript, dictation, always-on notes.
        .executableTarget(
            name: "SonaApp",
            dependencies: ["NotesKit", "SonaEngine", "LiveCore", .product(name: "Sparkle", package: "Sparkle")],
            // FoundationModels (MacTitles) is macOS 26 and later: weak-linked, so the app still launches on macOS 14
            // and MacTitles does nothing there. Check with `otool -l`: LC_LOAD_WEAK_DYLIB.
            // The rpath finds Sparkle.framework where scripts/build.sh puts it, in Contents/Frameworks.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        // Live transcript: Parakeet Unified streaming, the mic at hardware-buffer size and the rules for keeping
        // it open, speakers, latency measurement.
        .target(
            name: "LiveCore",
            dependencies: ["NotesKit", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        // The latency bench, with the engines the app doesn't ship (Parakeet EOU, Apple's) for comparison.
        .executableTarget(
            name: "LiveBench",
            dependencies: ["LiveCore", "NotesKit", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "LiveCoreTests",
            dependencies: ["LiveCore"]
        ),
        .testTarget(
            name: "SonaEngineTests",
            dependencies: ["SonaEngine"]
        ),
        .testTarget(
            name: "NotesKitTests",
            dependencies: ["NotesKit"]
        ),
    ]
)
