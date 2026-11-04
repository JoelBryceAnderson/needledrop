// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeedledropKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "NeedledropKit",
            targets: ["AudioCapture", "SignalAnalysis", "Recognition", "Metadata", "SessionState", "Pipeline", "ReplayHarness", "Visuals", "Lyrics", "Archive", "ArtDirector"]
        ),
        .executable(name: "needledrop-replay", targets: ["needledrop-replay"]),
    ],
    dependencies: [
        // SQLite for the library (see docs/DECISIONS.md).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Device selection, engine lifecycle, lock-free ring buffer.
        .target(name: "AudioCapture"),
        // FFT, band energies, RMS, onsets, tempo. Pure DSP — no AVFoundation.
        .target(name: "SignalAnalysis"),
        // ShazamKit (and scripted) recognition, playback clock.
        .target(name: "Recognition", dependencies: ["AudioCapture"]),
        // Album/track info and artwork from the iTunes API, cached on disk.
        .target(name: "Metadata", dependencies: ["Recognition"]),
        // Time-synced lyrics from LRCLIB, LRC parsing.
        .target(name: "Lyrics", dependencies: ["Metadata"]),
        // Side recording, track splitting, lossless encoding + tags, the library database.
        .target(name: "Archive", dependencies: [
            "AudioCapture", "Recognition", "Metadata",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        // Side detector + session state machine (idle → … → playing(track) → … → sideEnded).
        .target(name: "SessionState", dependencies: ["SignalAnalysis", "Recognition"]),
        // Metal renderer, palettes, scene transitions. Shaders compile at runtime from source.
        .target(name: "Visuals", dependencies: ["SignalAnalysis"]),
        // Claude as art director: style specs and custom shaders per album.
        .target(name: "ArtDirector", dependencies: ["Visuals"]),
        // Wires capture → analysis → session → recognition → metadata, live or offline.
        .target(name: "Pipeline", dependencies: ["AudioCapture", "SignalAnalysis", "Recognition", "Metadata", "Lyrics", "SessionState", "Archive"]),
        // Feed recorded/synthetic audio through the pipeline as if it were live.
        .target(name: "ReplayHarness", dependencies: ["AudioCapture", "SignalAnalysis", "Recognition", "Metadata", "Lyrics", "SessionState", "Pipeline"]),
        .executableTarget(name: "needledrop-replay", dependencies: ["ReplayHarness", "Pipeline", "AudioCapture", "Visuals"]),

        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "SignalAnalysisTests", dependencies: ["SignalAnalysis", "ReplayHarness"]),
        .testTarget(name: "SessionStateTests", dependencies: ["SessionState", "SignalAnalysis", "Recognition"]),
        .testTarget(name: "RecognitionTests", dependencies: ["Recognition"]),
        .testTarget(name: "VisualsTests", dependencies: ["Visuals", "SignalAnalysis"]),
        .testTarget(name: "LyricsTests", dependencies: ["Lyrics", "Metadata"]),
        .testTarget(name: "ArchiveTests", dependencies: ["Archive", "Recognition", "Metadata", "ReplayHarness"]),
        .testTarget(name: "ArtDirectorTests", dependencies: ["ArtDirector", "Visuals"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata", "Recognition"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "ReplayHarness", "SessionState", "AudioCapture", "Recognition", "Metadata"]),
    ]
)
