import Archive
import AudioCapture
import Foundation
import Lyrics
import Metadata
import Recognition
import SessionState
import Synchronization

/// What the UI shows about the session. Pulled per frame like `PipelineSnapshot`.
public struct SessionSnapshot: Sendable {
    public var phase: SessionPhase = .idle
    public var track: TrackMatch?
    public var metadata: TrackMetadata?
    /// Lyrics for the current track, once fetched (nil while loading or if there are none).
    public var lyrics: Lyrics?
    public var clock: PlaybackClock?
    public var unidentified = false
    public var isRecognizing = false
    public var matchCount = 0
    public var lastRecognitionError: String?

    public init() {}

    /// Track position at audio time `t`, if known.
    public func position(at t: Double) -> Double? { clock?.position(at: t) }
}

public enum EngineEvent: Sendable {
    case pipeline(PipelineEvent)
    case trackChanged(TrackMatch?)
    /// Metadata (and artwork bytes, if any) for the current track.
    case metadata(TrackMetadata, artwork: Data?)
    case lyrics(Lyrics?)
    case archived(ArchiveReport)
    case recognitionError(String)
}

/// The running app's brain: owns the listening pipeline, feeds the session machine with
/// side events, ticks and recognitions (all in audio time), carries out its effects, and
/// resolves metadata for each new track.
public actor Engine {
    public nonisolated let pipeline: ListeningPipeline
    public nonisolated let events: AsyncStream<EngineEvent>
    public nonisolated let archiver: Archiver?

    private let recognition: RecognitionController
    private let metadata: MetadataResolver?
    private let lyricsProvider: LyricsProvider?
    private let continuation: AsyncStream<EngineEvent>.Continuation
    /// Archive events go through one stream so the archiver sees them in order.
    private let archiveEvents: AsyncStream<ArchiveEvent>
    private let archiveInbox: AsyncStream<ArchiveEvent>.Continuation
    private var lastTick = 0.0
    private let shared = Mutex(SessionSnapshot())
    private var machine: SessionMachine
    private var tasks: [Task<Void, Never>] = []

    public init(
        detector: SideDetectorConfig = SideDetectorConfig(),
        session: SessionConfig = SessionConfig(),
        recognizer: any TrackRecognizer,
        metadata: MetadataResolver?,
        lyrics: LyricsProvider? = nil,
        archiver: Archiver? = nil
    ) {
        let recognition = RecognitionController(recognizer: recognizer)
        self.recognition = recognition
        self.metadata = metadata
        lyricsProvider = lyrics
        self.archiver = archiver
        (archiveEvents, archiveInbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        machine = SessionMachine(config: session)
        let pipeline = ListeningPipeline(config: detector, observers: [recognition] + (archiver.map { [$0.recorder] } ?? []))
        self.pipeline = pipeline
        recognition.setSink { [weak pipeline] in pipeline?.post(.recognition($0)) }
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public nonisolated func session() -> SessionSnapshot {
        shared.withLock { $0 }
    }

    public func start(source: any AudioSource) throws {
        let pipelineEvents = pipeline.events
        tasks.append(Task { [weak self] in
            for await event in pipelineEvents { await self?.handle(event) }
            await self?.finish()
        })
        if let archiver {
            let inbox = archiveEvents
            tasks.append(Task { [weak self] in
                for await event in inbox {
                    if let report = await archiver.handle(event) { await self?.archived(report) }
                }
            })
        }
        try pipeline.start(source: source)
    }

    public nonisolated var isRecording: Bool { archiver?.recorder.isRecording ?? false }

    public func updateArchiveSettings(_ settings: ArchiveSettings) {
        archiveInbox.yield(.settings(settings))
    }

    private func archived(_ report: ArchiveReport) {
        continuation.yield(.archived(report))
    }

    public func stop() {
        pipeline.stop()
        recognition.setListening(false)
        archiver?.recorder.cancel()  // the archive task is cancelled below, so don't rely on .abandon
        archiveInbox.yield(.abandon)
        archiveInbox.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        continuation.finish()
    }

    // MARK: - Event handling

    private func handle(_ event: PipelineEvent) {
        continuation.yield(.pipeline(event))
        switch event {
        case .side(let side):
            switch side {
            case .sideStarted(let t): archiveInbox.yield(.sideStarted(at: t))
            case .trackGap(let start, let end, _): archiveInbox.yield(.gap(start...end))
            case .sideEnded(let start, let end, let reason): archiveInbox.yield(.sideEnded(start: start, end: end, reason: reason.rawValue))
            case .gapStarted: break
            }
            apply(.side(side))
        case .tick(let time, let phase):
            lastTick = time
            apply(.tick(time: time, detector: phase))
            if machine.phase == .playing, let track = machine.track, let clock = machine.clock {
                archiveInbox.yield(.trackSeen(track, clockStart: clock.trackStartTime, at: time))
            }
        case .recognition(.match(let match, let time)): apply(.match(match, at: time))
        case .recognition(.error(let message)):
            shared.withLock { $0.lastRecognitionError = message }
            continuation.yield(.recognitionError(message))
        case .source: break
        }
    }

    private func finish() {
        continuation.finish()
    }

    private func apply(_ input: SessionInput) {
        for effect in machine.handle(input) {
            switch effect {
            case .startRecognition:
                recognition.setListening(true)
            case .stopRecognition:
                recognition.setListening(false)
            case .trackChanged(let track):
                shared.withLock {
                    $0.metadata = nil
                    $0.lyrics = nil
                }
                continuation.yield(.trackChanged(track))
                if let track { resolveMetadata(for: track) }
            }
        }
        let machine = self.machine
        shared.withLock {
            $0.phase = machine.phase
            $0.track = machine.track
            $0.clock = machine.clock
            $0.unidentified = machine.unidentified
            $0.isRecognizing = machine.isRecognizing
            $0.matchCount = machine.matchCount
        }
    }

    private func resolveMetadata(for track: TrackMatch) {
        guard let metadata else { return }
        Task { [weak self] in
            let info = await metadata.resolve(track)
            let artwork = await metadata.artwork(for: info)
            await self?.metadataResolved(info, artwork: artwork, for: track)
        }
    }

    private func metadataResolved(_ info: TrackMetadata, artwork: Data?, for track: TrackMatch) {
        guard machine.track?.identity == track.identity else { return }  // already moved on
        shared.withLock { $0.metadata = info }
        continuation.yield(.metadata(info, artwork: artwork))
        archiveInbox.yield(.metadata(identity: track.identity, info, artwork: artwork))
        if let duration = info.duration {
            apply(.trackDuration(identity: track.identity, seconds: duration))
        }
        if let lyricsProvider {
            Task { [weak self] in
                let lyrics = await lyricsProvider.lyrics(for: info)
                await self?.lyricsResolved(lyrics, for: track)
            }
        }
    }

    private func lyricsResolved(_ lyrics: Lyrics?, for track: TrackMatch) {
        guard machine.track?.identity == track.identity else { return }
        shared.withLock { $0.lyrics = lyrics }
        continuation.yield(.lyrics(lyrics))
    }
}
