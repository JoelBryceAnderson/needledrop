import AudioCapture
import Foundation
import Recognition
import SessionState
import SignalAnalysis
import Synchronization

public enum PipelineEvent: Sendable, Equatable {
    case source(SourceStatus)
    case side(SideEvent)
    /// Every `tickInterval` of audio: lets session logic run on audio time, so replay at
    /// any speed behaves identically.
    case tick(time: Double, phase: SidePhase)
    /// Posted by observers (recognition) so everything arrives on one ordered stream.
    case recognition(RecognitionEvent)
}

/// Everything the UI needs for one frame. The renderer pulls this at display rate via
/// `ListeningPipeline.snapshot()`; nothing is pushed to the main thread per hop.
public struct PipelineSnapshot: Sendable {
    public static let historySeconds = 10.0
    public static let historyRate = 30.0

    public var sourceName: String?
    public var sourceStatus: SourceStatus?
    public var format: CaptureFormat?
    public var features = AudioFeatures()
    /// dBFS per display band with peak-fall smoothing.
    public var spectrum: [Float] = Array(repeating: -120, count: FeatureExtractor.displayBandCount)
    public var phase: SidePhase = .idle
    public var gatedLevelDB: Float = -120
    public var gatedFlatness: Float = 1
    public var config = SideDetectorConfig()
    /// Gated music-band level, oldest first, `historyRate` values per second.
    public var levelHistory: [Float] = Array(repeating: -120, count: Int(historySeconds * historyRate))
    public var peakHoldDB: Float = -120
    public var lastClipTime: Double?
    public var lastBeatTime: Double?
    public var droppedFrames = 0
    public var recentEvents: [SideEvent] = []

    public init() {}
}

/// Drains the ring buffer on a dedicated thread, runs `AnalysisCore`, and publishes a
/// snapshot plus an event stream. The capture thread only ever touches the ring buffer.
public final class ListeningPipeline: @unchecked Sendable {
    public static let tickInterval = 0.25

    public let events: AsyncStream<PipelineEvent>
    /// Receive every analysed hop on the analysis thread (recognition, archive).
    public let observers: [any AudioObserver]

    private let ring = AudioRingBuffer(channelCount: 2, minimumCapacity: 1 << 20)  // ~21 s at 48 kHz
    private let continuation: AsyncStream<PipelineEvent>.Continuation
    private let shared: Mutex<PipelineSnapshot>
    private let pendingFormat = Mutex<CaptureFormat?>(nil)
    private let pendingConfig = Mutex<SideDetectorConfig?>(nil)
    private let history = Mutex(FeatureHistory())
    private let running = Atomic<Bool>(false)
    private let sourceFinished = Atomic<Bool>(false)
    private var source: (any AudioSource)?
    private var thread: Thread?

    // Owned by the analysis thread.
    private var core: AnalysisCore?
    private var config: SideDetectorConfig
    private var working = PipelineSnapshot()
    private var historyAccumulator = 0.0
    private var nextTick = 0.0

    public init(config: SideDetectorConfig = SideDetectorConfig(), observers: [any AudioObserver] = []) {
        self.config = config
        self.observers = observers
        var initial = PipelineSnapshot()
        initial.config = config
        working = initial
        shared = Mutex(initial)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit { stop() }

    public func snapshot() -> PipelineSnapshot {
        shared.withLock { $0 }
    }

    /// Features `delay` seconds behind the newest (up to `FeatureHistory.maximumDelay`).
    public func features(delayedBy delay: Double) -> (features: AudioFeatures, beatAge: Double?) {
        history.withLock { $0.features(delayedBy: delay) }
    }

    /// Adds an event to the stream, in order with the pipeline's own events when called
    /// from the analysis thread.
    public func post(_ event: PipelineEvent) {
        continuation.yield(event)
    }

    public func updateConfig(_ config: SideDetectorConfig) {
        pendingConfig.withLock { $0 = config }
    }

    public func start(source: any AudioSource) throws {
        precondition(!running.load(ordering: .acquiring), "pipeline already started")
        self.source = source
        shared.withLock { $0.sourceName = source.displayName }
        running.store(true, ordering: .releasing)

        let thread = Thread { [self] in self.analysisLoop() }
        thread.name = "needledrop.analysis"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        do {
            try source.start(writingTo: ring) { [weak self] status in self?.sourceStatusChanged(status) }
        } catch {
            running.store(false, ordering: .releasing)
            throw error
        }
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        source?.stop()
        source = nil
        continuation.finish()
    }

    private func sourceStatusChanged(_ status: SourceStatus) {
        if case .running(let format, _) = status {
            pendingFormat.withLock { $0 = format }
        }
        shared.withLock { $0.sourceStatus = status }
        if status == .finished {
            // Reported by the analysis thread once everything buffered has been analysed.
            sourceFinished.store(true, ordering: .releasing)
        } else {
            continuation.yield(.source(status))
        }
    }

    // MARK: - Analysis thread

    private func analysisLoop() {
        var scratch: UnsafeMutablePointer<Float>?
        var scratchSize = 0
        defer { scratch?.deallocate() }

        while running.load(ordering: .acquiring) {
            if let format = pendingFormat.withLock({ f -> CaptureFormat? in defer { f = nil }; return f }) {
                configure(for: format)
            }
            if let newConfig = pendingConfig.withLock({ c -> SideDetectorConfig? in defer { c = nil }; return c }) {
                config = newConfig
                core?.detector.config = newConfig
                working.config = newConfig
            }
            guard let core else {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            let hop = core.hopSize
            if scratchSize != hop {
                scratch?.deallocate()
                scratch = .allocate(capacity: hop * 2)
                scratchSize = hop
            }
            guard let buffer = scratch, ring.read(frameCount: hop, into: buffer) else {
                if sourceFinished.exchange(false, ordering: .acquiringAndReleasing) {
                    continuation.yield(.source(.finished))
                }
                Thread.sleep(forTimeInterval: 0.003)
                continue
            }
            let (features, sideEvents) = core.process(left: buffer, right: buffer + hop)
            for observer in observers {
                observer.observe(left: buffer, right: buffer + hop, frameCount: hop,
                                 endTime: features.time, sampleRate: core.parameters.sampleRate)
            }
            publish(features, sideEvents, core: core)
        }
    }

    private func configure(for format: CaptureFormat) {
        if let core {
            if core.parameters.sampleRate == format.sampleRate { return }
            // Format changed (device reconnected at another rate): anything still buffered
            // is in the old format. On first configure the buffer already holds new audio.
            ring.discardAll()
        }
        let core = AnalysisCore(sampleRate: format.sampleRate, config: config)
        self.core = core
        nextTick = 0
        working.format = format
        working.phase = core.detector.phase
    }

    private func publish(_ features: AudioFeatures, _ sideEvents: [SideEvent], core: AnalysisCore) {
        let hopDuration = core.parameters.hopDuration
        history.withLock { $0.append(features) }
        working.features = features
        working.phase = core.detector.phase
        working.gatedLevelDB = core.detector.gatedLevelDB
        working.gatedFlatness = core.detector.gatedFlatness
        working.droppedFrames = ring.droppedFrameCount

        // Bars jump up instantly and fall at 30 dB/s — readable on a TV.
        let fall = Float(30 * hopDuration)
        for (i, value) in core.extractor.displaySpectrum.enumerated() {
            working.spectrum[i] = max(value, working.spectrum[i] - fall)
        }
        let peakDB = decibels(features.peak)
        working.peakHoldDB = max(peakDB, working.peakHoldDB - Float(20 * hopDuration))
        if features.clippedSamples > 0 { working.lastClipTime = features.time }
        if features.beat { working.lastBeatTime = features.time }

        historyAccumulator += hopDuration * PipelineSnapshot.historyRate
        while historyAccumulator >= 1 {
            historyAccumulator -= 1
            working.levelHistory.removeFirst()
            working.levelHistory.append(core.detector.gatedLevelDB)
        }

        for event in sideEvents {
            working.recentEvents.append(event)
            if working.recentEvents.count > 20 { working.recentEvents.removeFirst() }
            continuation.yield(.side(event))
        }
        if features.time >= nextTick {
            nextTick = features.time + Self.tickInterval
            continuation.yield(.tick(time: features.time, phase: core.detector.phase))
        }
        let snapshot = working
        shared.withLock { current in
            // Source fields are written from the source's thread; keep them.
            let status = current.sourceStatus, name = current.sourceName
            current = snapshot
            current.sourceStatus = status
            current.sourceName = name
        }
    }
}
