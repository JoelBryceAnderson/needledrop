import Foundation

/// Records whatever the input hears between Start and Stop (a vinyl podcast, a DJ set, a
/// whole side without splitting), independent of side detection and the track archive.
///
/// `recorder` is attached to every pipeline as an observer, so a recording carries on across
/// input restarts. While recording, raw float audio goes to `Recordings/.incoming`. Stop encodes
/// it in the archive format to `Recordings/Recording <date>.<ext>` and deletes the raw file.
/// After a crash, `recoverOrphans` keeps the raw file instead.
public actor ManualRecording {
    public nonisolated let recorder = SideRecorder(preRoll: 1)

    public struct Saved: Sendable {
        public var url: URL
        public var duration: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case nothingRecorded
        case encoding(String, rawKeptAt: URL?)

        public var description: String {
            switch self {
            case .nothingRecorded: "Nothing was recorded (no audio arrived)"
            case .encoding(let message, let raw):
                "Couldn't encode the recording (\(message))" + (raw.map { "; the raw audio is at \($0.path)" } ?? "")
            }
        }
    }

    private var current: (root: URL, started: Date)?

    public init() {}

    public var startedAt: Date? { current?.started }

    public static func folder(root: URL) -> URL {
        root.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Starts recording now (no pre-roll). Does nothing if already recording.
    public func start(root: URL, at date: Date = Date()) throws {
        guard current == nil else { return }
        let incoming = Self.folder(root: root).appendingPathComponent(".incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        recorder.begin(writingTo: incoming.appendingPathComponent("\(UUID().uuidString).caf"),
                       from: .greatestFiniteMagnitude)
        current = (root, date)
    }

    /// Stops and encodes. Needs audio to be flowing (the recorder finishes on the analysis
    /// thread), so stop before switching to an input that never delivers any.
    public func stop(format: ArchiveFormat, bitDepth: Int = 24) async throws -> Saved {
        guard let (root, started) = current else { throw Failure.nothingRecorded }
        current = nil
        guard let side = await recorder.finish() else { throw Failure.nothingRecorded }
        let folder = Self.folder(root: root)
        let name = "Recording \(Archiver.stamp(started))"
        let destination = Archiver.unique(folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
        var tags = TrackTags(title: name, artist: "Needledrop")
        tags.album = "Recordings"
        tags.year = Calendar.current.component(.year, from: started)
        do {
            _ = try await TrackEncoder.encode(from: side.url, start: 0, end: side.duration, to: destination,
                                              format: format, bitDepth: bitDepth, tags: tags)
            try? FileManager.default.removeItem(at: side.url)
            return Saved(url: destination, duration: side.duration)
        } catch {
            // Keep the audio: move the raw file next to where the encoded one would have gone.
            let raw = Archiver.unique(folder.appendingPathComponent("\(name).caf"))
            let kept = (try? FileManager.default.moveItem(at: side.url, to: raw)) != nil ? raw : side.url
            throw Failure.encoding("\(error)", rawKeptAt: kept)
        }
    }

    /// Raw recordings a crash left behind, moved to `Recordings/` as "Recovered recording …".
    @discardableResult
    public static func recoverOrphans(root: URL) -> [URL] {
        Archiver.recoverOrphans(root: folder(root: root), into: ".", prefix: "Recovered recording")
    }
}
