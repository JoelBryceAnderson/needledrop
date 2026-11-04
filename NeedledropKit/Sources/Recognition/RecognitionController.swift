import AudioCapture
import Foundation
import Synchronization

/// A recognition backend. All methods are called on the analysis thread, one at a time,
/// so implementations don't need their own locking for feed state.
public protocol TrackRecognizer: AnyObject, Sendable {
    /// Called once before any window, with where to send results (from any thread).
    func setHandler(_ handler: @escaping @Sendable (RecognizerResult) -> Void)
    /// A matching window opens. Start a fresh signature.
    func beginWindow(sampleRate: Double)
    /// Mono audio for the current window. `endTime` is the audio time after this block.
    func feed(_ mono: UnsafePointer<Float>, frameCount: Int, endTime: Double)
    func endWindow()
}

public enum RecognizerResult: Sendable {
    case match(TrackMatch)
    case error(String)
}

/// Gates audio into a recognizer only while a matching window is open, and stamps results
/// with audio time. Session logic decides when windows open (`setListening`); this class
/// keeps the recognizer itself off the main path and out of per-frame work.
public final class RecognitionController: AudioObserver, @unchecked Sendable {
    private let recognizer: any TrackRecognizer
    private let sink = Mutex<(@Sendable (RecognitionEvent) -> Void)?>(nil)
    private let wantsListening = Atomic<Bool>(false)
    private let requestedWindow = Atomic<Int>(0)
    private let latestTime = Mutex<Double>(0)

    // Analysis-thread state.
    private var openWindow: Int?
    private var mono: [Float] = []

    public init(recognizer: any TrackRecognizer) {
        self.recognizer = recognizer
        recognizer.setHandler { [weak self] result in self?.report(result) }
    }

    /// Where results go. A recognizer that answers synchronously inside `feed` (the
    /// scripted one) therefore reports in exact order with the hop that produced it.
    public func setSink(_ sink: @escaping @Sendable (RecognitionEvent) -> Void) {
        self.sink.withLock { $0 = sink }
    }

    private func report(_ result: RecognizerResult) {
        let event: RecognitionEvent = switch result {
        case .match(let match): .match(match, at: latestTime.withLock { $0 })
        case .error(let message): .error(message)
        }
        sink.withLock { $0 }?(event)
    }

    /// Opening always starts a *new* window (fresh signature), even if one is open.
    public func setListening(_ listening: Bool) {
        if listening { requestedWindow.add(1, ordering: .relaxed) }
        wantsListening.store(listening, ordering: .releasing)
    }

    public var isListening: Bool { wantsListening.load(ordering: .acquiring) }

    public func observe(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int,
                        endTime: Double, sampleRate: Double) {
        latestTime.withLock { $0 = endTime }
        guard wantsListening.load(ordering: .acquiring) else {
            if openWindow != nil {
                recognizer.endWindow()
                openWindow = nil
            }
            return
        }
        let requested = requestedWindow.load(ordering: .relaxed)
        if openWindow != requested {
            if openWindow != nil { recognizer.endWindow() }
            recognizer.beginWindow(sampleRate: sampleRate)
            openWindow = requested
        }
        if mono.count != frameCount { mono = [Float](repeating: 0, count: frameCount) }
        for i in 0..<frameCount { mono[i] = (left[i] + right[i]) * 0.5 }
        mono.withUnsafeBufferPointer { recognizer.feed($0.baseAddress!, frameCount: frameCount, endTime: endTime) }
    }
}
