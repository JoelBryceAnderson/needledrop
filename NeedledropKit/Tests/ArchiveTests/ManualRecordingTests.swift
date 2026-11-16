import AVFAudio
@testable import Archive
import Foundation
import Testing

@Suite struct ManualRecordingTests {
    private let rate = 48_000.0
    private let hop = 1024

    /// Feeds a 440 Hz tone to the recorder until `done` is true (stop needs audio flowing).
    private func feed(_ recording: ManualRecording, seconds: Double, from t0: Double) -> Double {
        var t = t0
        let tone = (0..<hop).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.25 }
        for _ in 0..<Int(seconds * rate) / hop {
            t += Double(hop) / rate
            tone.withUnsafeBufferPointer { recording.recorder.observe(left: $0.baseAddress!, right: $0.baseAddress!,
                                                                      frameCount: hop, endTime: t, sampleRate: rate) }
        }
        return t
    }

    @Test func recordsBetweenStartAndStopAndEncodesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = ManualRecording()
        var t = feed(recording, seconds: 1, from: 0)  // before Start: not recorded
        try await recording.start(root: root, at: Date(timeIntervalSince1970: 1_800_000_000))
        t = feed(recording, seconds: 2, from: t)
        let stop = Task { try await recording.stop(format: .alac) }
        while !Task.isCancelled {
            t = feed(recording, seconds: 0.1, from: t)
            if let saved = try? await withTimeout(stop) { return try check(saved, root: root) }
        }
    }

    private func withTimeout(_ task: Task<ManualRecording.Saved, any Error>) async throws -> ManualRecording.Saved? {
        try await Task.sleep(for: .milliseconds(20))
        return try await withThrowingTaskGroup(of: ManualRecording.Saved?.self) { group in
            group.addTask { try await task.value }
            group.addTask { try await Task.sleep(for: .milliseconds(30)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func check(_ saved: ManualRecording.Saved, root: URL) throws {
        #expect(saved.url.deletingLastPathComponent().lastPathComponent == "Recordings")
        #expect(saved.url.pathExtension == "m4a")
        #expect(saved.url.lastPathComponent.hasPrefix("Recording "))
        // Two seconds recorded, plus whatever arrived while stopping; nothing from before Start.
        #expect(saved.duration > 1.95 && saved.duration < 2.5)  // 93 hops = 1.98 s
        let file = try AVAudioFile(forReading: saved.url)
        #expect(file.fileFormat.sampleRate == 48_000 && file.fileFormat.channelCount == 2)
        let incoming = ManualRecording.folder(root: root).appendingPathComponent(".incoming")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: incoming.path))?.isEmpty ?? true)  // raw deleted
    }

    @Test func stoppingWithoutStartingFails() async {
        await #expect(throws: ManualRecording.Failure.self) { try await ManualRecording().stop(format: .alac) }
    }

    @Test func aCrashLeavesTheRawAudioRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manual-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = ManualRecording.folder(root: root).appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: incoming.appendingPathComponent("x.caf"))
        let recovered = ManualRecording.recoverOrphans(root: root)
        #expect(recovered.count == 1)
        #expect(recovered.first?.lastPathComponent.hasPrefix("Recovered recording ") == true)
        #expect(recovered.first?.standardizedFileURL.deletingLastPathComponent().lastPathComponent == "Recordings")
    }
}
