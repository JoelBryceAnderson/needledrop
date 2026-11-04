import AudioCapture
import Foundation
import Pipeline
import ReplayHarness
import SessionState
import SignalAnalysis
import ImageIO
import Metal
import UniformTypeIdentifiers
import Visuals

let usage = """
    needledrop-replay — run audio through the Needledrop pipeline without a turntable.

    USAGE
      needledrop-replay analyze <file> [options]   Offline, as fast as possible; prints sides & tracks
      needledrop-replay play <file> [--speed N] [options]
                                                   Real-time through the live ring-buffer path
      needledrop-replay synth <out.wav> [--sample-rate HZ] [--seed N]
                                                   Write a synthetic side with known ground truth
      needledrop-replay still <out.png> [--art cover.jpg] [--lyric "text"] [--style paper|smoke] [--no-cover]
                               [--seconds S] [--size WxH]
                                                   Render visuals offscreen with synthetic music
      needledrop-replay devices                    List audio input devices
      needledrop-replay listen [--device UID] [options]
                                                   Live input, prints events and a level meter

    DETECTOR OPTIONS
      --start-db DB  --stop-db DB  --max-flatness F  --start-hold S
      --side-end S   --gap-min S   --lift-floor DB   --lift-confirm S
      --timeline out.csv    (analyze) write per-hop features
    """

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@MainActor func detectorConfig() -> SideDetectorConfig {
    var c = SideDetectorConfig()
    if let v = option("--start-db").flatMap(Float.init) { c.startThresholdDB = v }
    if let v = option("--stop-db").flatMap(Float.init) { c.stopThresholdDB = v }
    if let v = option("--max-flatness").flatMap(Float.init) { c.maxMusicFlatness = v }
    if let v = option("--start-hold").flatMap(Double.init) { c.startHold = v }
    if let v = option("--side-end").flatMap(Double.init) { c.sideEndSilence = v }
    if let v = option("--gap-min").flatMap(Double.init) { c.gapMinimum = v }
    if let v = option("--lift-floor").flatMap(Float.init) { c.needleLiftFloorDB = v }
    if let v = option("--lift-confirm").flatMap(Double.init) { c.needleLiftConfirm = v }
    return c
}

func clock(_ t: Double) -> String {
    let minutes = Int(t) / 60
    return String(format: "%02d:%04.1f", minutes, t - Double(minutes * 60))
}

func describe(_ event: SideEvent) -> String {
    switch event {
    case .sideStarted(let t):
        "\(clock(t))  ▶ side started"
    case .gapStarted(let t):
        "\(clock(t))  … quiet"
    case .trackGap(let start, let end, let abrupt):
        "\(clock(start))  ‖ gap \(String(format: "%.1f", end - start)) s → next track at \(clock(end))\(abrupt ? " (abrupt stop)" : "")"
    case .sideEnded(let start, let end, let reason):
        "\(clock(end))  ■ side ended (\(reason == .runout ? "run-out" : "needle lift")) — side length \(clock(end - start))"
    }
}

func printReport(_ report: SideReport) {
    for (s, side) in report.sides.enumerated() {
        print("\nSide \(s + 1): \(clock(side.start)) – \(side.end.map(clock) ?? "…")")
        for (t, track) in side.tracks.enumerated() {
            let tempo = track.tempo.map { String(format: "%5.1f BPM", $0) } ?? "    – BPM"
            let clip = track.clippedSamples > 0 ? "  ⚠︎ \(track.clippedSamples) clipped samples" : ""
            print(String(format: "  %2d  %@ – %@  %@  peak %5.1f dBFS%@",
                         t + 1, clock(track.start), clock(track.end), tempo, track.peakDB, clip))
        }
    }
}

func writeTimeline(_ timeline: [AudioFeatures], to path: String) throws {
    var csv = "time,rms_db,peak_db,music_db,flatness,sub_db,bass_db,mids_db,highs_db,flux,onset,tempo,beat\n"
    for f in timeline {
        let bands = f.bands.asArray.map { String(format: "%.1f", decibels($0)) }.joined(separator: ",")
        csv += String(format: "%.4f,%.1f,%.1f,%.1f,%.3f,", f.time, decibels(f.rms), decibels(f.peak), f.musicBandDB, f.flatness)
        csv += bands + String(format: ",%.4f,%d,%@,%d\n", f.flux, f.onset ? 1 : 0, f.tempo.map { String(format: "%.1f", $0) } ?? "", f.beat ? 1 : 0)
    }
    try csv.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Prints events as they arrive and a one-line meter, until the source finishes or ^C.
func runLive(source: any AudioSource, config: SideDetectorConfig, stopWhenFinished: Bool) async throws {
    let pipeline = ListeningPipeline(config: config)
    try pipeline.start(source: source)
    let printer = Task {
        for await event in pipeline.events {
            switch event {
            case .side(let e): print("\r\u{1B}[K" + describe(e))
            case .source(.running(let format, let name)): print("\r\u{1B}[K● \(name) — \(format)")
            case .source(.waitingForDevice(let what)): print("\r\u{1B}[K… waiting for \(what)")
            case .source(.failed(let message)): print("\r\u{1B}[K✖ \(message)")
            case .source(.finished): if stopWhenFinished { return }
            case .tick, .recognition: break
            }
        }
    }
    let meter = Task {
        while !Task.isCancelled {
            let s = pipeline.snapshot()
            let level = max(-80, s.gatedLevelDB)
            let bar = String(repeating: "█", count: Int((level + 80) / 2.5))
            let tempo = s.features.tempo.map { String(format: "%5.1f BPM", $0) } ?? "    – BPM"
            let clip = s.lastClipTime.map { s.features.time - $0 < 2 } == true ? " CLIP" : ""
            let phase: String = switch s.phase {
            case .idle: "idle   "
            case .arming: "arming "
            case .playing: "playing"
            case .quiet: "quiet  "
            }
            FileHandle.standardOutput.write(Data(String(format: "\r\u{1B}[K%@  %@  %6.1f dB  flat %.2f  %@ %@%@",
                clock(s.features.time), phase, s.gatedLevelDB, s.gatedFlatness, tempo, bar, clip).utf8))
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    await printer.value
    meter.cancel()
    pipeline.stop()
    print("")
}

guard let command = arguments.first else {
    print(usage)
    exit(0)
}
arguments.removeFirst()

switch command {
case "analyze":
    let timelinePath = option("--timeline")
    let config = detectorConfig()
    guard let path = arguments.first else { fail("analyze needs a file") }
    let url = URL(fileURLWithPath: path)
    let started = Date()
    do {
        let result = try OfflineReplay.analyze(url: url, config: config, keepTimeline: true)
        let elapsed = Date().timeIntervalSince(started)
        print("\(url.lastPathComponent): \(result.format), \(clock(result.duration)) analysed in \(String(format: "%.2f", elapsed)) s (\(Int(result.duration / elapsed))× real time)")
        print("peak \(String(format: "%.1f", decibels(result.peak))) dBFS\(result.clippedSamples > 0 ? ", \(result.clippedSamples) clipped samples" : "")\n")
        if result.events.isEmpty { print("no sides detected — try lowering --start-db (see the --timeline CSV)") }
        result.events.map(describe).forEach { print($0) }
        printReport(SideReport(events: result.events, timeline: result.timeline))
        if let timelinePath {
            try writeTimeline(result.timeline, to: timelinePath)
            print("\ntimeline written to \(timelinePath)")
        }
    } catch {
        fail("\(error.localizedDescription)")
    }

case "play":
    let speed = option("--speed").flatMap(Double.init) ?? 1
    let config = detectorConfig()
    guard let path = arguments.first else { fail("play needs a file") }
    let source = FileReplaySource(url: URL(fileURLWithPath: path), speed: speed)
    try await runLive(source: source, config: config, stopWhenFinished: true)

case "synth":
    let sampleRate = option("--sample-rate").flatMap(Double.init) ?? 48_000
    let seed = option("--seed").flatMap(UInt64.init) ?? 1
    guard let path = arguments.first else { fail("synth needs an output path") }
    var side = SyntheticSide.demo(sampleRate: sampleRate)
    side.seed = seed
    let url = URL(fileURLWithPath: path)
    let truth = try side.write(to: url)
    print("wrote \(path): \(clock(truth.duration)), \(Int(sampleRate)) Hz, 24-bit stereo")
    for (i, t) in truth.tracks.enumerated() {
        print(String(format: "  track %d  %@ – %@  %.0f BPM", i + 1, clock(t.start), clock(t.end), t.bpm))
    }
    // Stand-in identities so replay in the app shows real metadata and artwork.
    let names = [("Dreams", "Fleetwood Mac"), ("Go Your Own Way", "Fleetwood Mac"), ("Songbird", "Fleetwood Mac")]
    let script = ReplayScript(tracks: zip(truth.tracks, names.cycled(truth.tracks.count)).map { t, n in
        .init(start: t.start, end: t.end, title: n.0, artist: n.1, offset: 30, rate: 1.003)
    })
    try script.write(for: url)
    print("wrote \(ReplayScript.sidecarURL(for: url).lastPathComponent) (scripted recognition for replay)")

case "still":
    let artPath = option("--art")
    let lyricText = option("--lyric")
    let seconds = option("--seconds").flatMap(Double.init) ?? 4
    let size = (option("--size") ?? "1280x720").split(separator: "x").compactMap { Int($0) }
    let noCover = arguments.contains("--no-cover")
    arguments.removeAll { $0 == "--no-cover" }
    let style = option("--style").flatMap(BackgroundStyle.init(rawValue:)) ?? .paper
    guard let path = arguments.first, size.count == 2 else { fail("still needs an output path (and --size WxH)") }

    let renderer = try VisualsRenderer()
    renderer.showCover = !noCover
    renderer.background = style
    if let artPath {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: artPath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("can't read \(artPath)") }
        let look = await AlbumLook.make(id: "still", artwork: image)
        print("palette: " + look.palette.colors.map { String(format: "#%02X%02X%02X", Int($0.r * 255), Int($0.g * 255), Int($0.b * 255)) }.joined(separator: " "))
        print("subject mask: \(look.subjectMask == nil ? "none" : "yes")")
        renderer.show(look, at: 0)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size[0], height: size[1], mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = renderer.device.makeTexture(descriptor: descriptor)!
    let queue = renderer.device.makeCommandQueue()!
    // Synthetic 120 BPM music: kick-driven bass, steady mids.
    for frame in 0..<Int(seconds * 60) {
        let t = Double(frame) / 60
        let beatAge = t.truncatingRemainder(dividingBy: 0.5)
        let kick = Float(exp(-beatAge / 0.12))
        let features = AudioFeatures(bands: BandEnergies(sub: 0.02 + 0.2 * kick, bass: 0.03 + 0.25 * kick, mids: 0.08, highs: 0.015),
                                     musicBandRMS: 0.1)
        let buffer = queue.makeCommandBuffer()!
        let input = VisualInput(features: features, beatAge: beatAge, active: true, lyricsAvailable: lyricText != nil,
                                lyric: lyricText.map { LyricFrame(id: 0, text: $0) })
        renderer.render(to: target, input: input, time: t, commandBuffer: buffer)
        buffer.commit()
        await buffer.completed()
    }
    var pixels = [UInt8](repeating: 0, count: size[0] * size[1] * 4)
    target.getBytes(&pixels, bytesPerRow: size[0] * 4, from: MTLRegionMake2D(0, 0, size[0], size[1]), mipmapLevel: 0)
    let context = CGContext(data: &pixels, width: size[0], height: size[1], bitsPerComponent: 8, bytesPerRow: size[0] * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fail("couldn't write \(path)") }
    print("wrote \(path)")

case "devices":
    let defaultUID = AudioDeviceCatalog.defaultInputDevice()?.uid
    for d in AudioDeviceCatalog.inputDevices() {
        let rates = d.availableSampleRates.map { "\(Int($0 / 1000))k" }.joined(separator: "/")
        print("\(d.uid == defaultUID ? "*" : " ") \(d.name) — \(d.inputChannelCount) ch @ \(Int(d.nominalSampleRate)) Hz [\(rates)]\n    uid: \(d.uid)")
    }

case "listen":
    let uid = option("--device")
    let config = detectorConfig()
    guard await MicrophoneAccess.request() else { fail("microphone access denied (System Settings › Privacy › Microphone)") }
    try await runLive(source: LiveInputSource(deviceUID: uid), config: config, stopWhenFinished: false)

default:
    print(usage)
    exit(1)
}

extension Array {
    func cycled(_ count: Int) -> [Element] {
        (0..<count).map { self[$0 % self.count] }
    }
}
