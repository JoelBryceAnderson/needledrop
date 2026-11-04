// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeedledropKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "NeedledropKit",
            targets: ["AudioCapture", "SignalAnalysis", "SessionState", "Pipeline", "ReplayHarness"]
        ),
        .executable(name: "needledrop-replay", targets: ["needledrop-replay"]),
    ],
    targets: [
        // Device selection, engine lifecycle, lock-free ring buffer.
        .target(name: "AudioCapture"),
        // FFT, band energies, RMS, onsets, tempo. Pure DSP — no AVFoundation.
        .target(name: "SignalAnalysis"),
        // Side start/gap/end detection; grows into the full session state machine in M2.
        .target(name: "SessionState", dependencies: ["SignalAnalysis"]),
        // Wires capture → analysis → session, live or offline.
        .target(name: "Pipeline", dependencies: ["AudioCapture", "SignalAnalysis", "SessionState"]),
        // Feed recorded/synthetic audio through the pipeline as if it were live.
        .target(name: "ReplayHarness", dependencies: ["AudioCapture", "SignalAnalysis", "SessionState", "Pipeline"]),
        .executableTarget(name: "needledrop-replay", dependencies: ["ReplayHarness", "Pipeline", "AudioCapture"]),

        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "SignalAnalysisTests", dependencies: ["SignalAnalysis", "ReplayHarness"]),
        .testTarget(name: "SessionStateTests", dependencies: ["SessionState", "SignalAnalysis"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "ReplayHarness", "SessionState", "AudioCapture"]),
    ]
)
