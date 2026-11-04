import Metadata
import Pipeline
import Recognition
import SessionState
import SignalAnalysis
import SwiftUI

/// Milestone 1 "Ears" screen. Pulls a pipeline snapshot every display frame. Designed for
/// 480i on a big TV: black background, thick shapes, large type, nothing hairline-thin.
struct DebugOverlayView: View {
    let model: AppModel

    var body: some View {
        TimelineView(.animation) { _ in
            let snapshot = model.pipeline.snapshot()
            let session = model.engine.session()
            GeometryReader { geometry in
                let u = min(geometry.size.width / 64, geometry.size.height / 40)
                OverlayLayout(snapshot: snapshot, session: session, metadata: model.metadata,
                              artwork: model.artwork, recording: model.engine.isRecording, log: model.log, u: u)
                    .padding(u * 2)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Color.black.opacity(0.6))
    }
}

private struct OverlayLayout: View {
    let snapshot: PipelineSnapshot
    let session: SessionSnapshot
    let metadata: TrackMetadata?
    let artwork: NSImage?
    let recording: Bool
    let log: [LogEntry]
    let u: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: u) {
            header
            Text(sourceLine)
                .font(.system(size: u * 1.4, weight: .medium, design: .rounded))
                .foregroundStyle(snapshot.droppedFrames > 0 ? .red : .gray)
            HStack(spacing: u * 2) {
                NowPlayingCard(session: session, metadata: metadata, artwork: artwork,
                               now: snapshot.features.time, u: u)
                SpectrumBars(spectrum: snapshot.spectrum)
            }
            .frame(maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: u * 2) {
                BandMeters(bands: snapshot.features.bands, u: u)
                LevelMeter(snapshot: snapshot, u: u)
                    .frame(width: u * 18)
            }
            .frame(height: u * 4.5)
            LevelHistory(snapshot: snapshot, u: u)
                .frame(height: u * 4.5)
            VStack(alignment: .leading, spacing: u * 0.2) {
                ForEach(log.suffix(2)) { entry in
                    Text(entry.text).lineLimit(1)
                }
            }
            .font(.system(size: u * 1.3, weight: .medium, design: .rounded))
            .foregroundStyle(.gray)
            .frame(height: u * 3, alignment: .bottom)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(phaseText.label)
                .font(.system(size: u * 3, weight: .heavy, design: .rounded))
                .foregroundStyle(phaseText.color)
            Spacer()
            if recording {
                Text("● REC")
                    .font(.system(size: u * 1.8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                    .padding(.trailing, u)
            }
            BeatDot(snapshot: snapshot, u: u)
            Text(snapshot.features.tempo.map { String(format: "%.0f BPM", $0) } ?? "— BPM")
                .font(.system(size: u * 3, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private var sourceLine: String {
        var parts = [snapshot.sourceName ?? "No input"]
        switch snapshot.sourceStatus {
        case .running(let format, _): parts.append(format.description)
        case .waitingForDevice(let what): parts.append("waiting for \(what)")
        case .failed(let message): parts.append(message)
        case .finished: parts.append("finished")
        case nil: break
        }
        if snapshot.droppedFrames > 0 { parts.append("\(snapshot.droppedFrames) frames dropped") }
        return parts.joined(separator: "  ·  ")
    }

    private var phaseText: (label: String, color: Color) {
        let now = snapshot.features.time
        let elapsed = session.clock.map { formatDuration($0.position(at: now)) } ?? ""
        switch session.phase {
        case .idle:
            return ("WAITING FOR NEEDLE", .gray)
        case .listening:
            return ("LISTENING…", .yellow)
        case .recognizing:
            return ("RECOGNIZING…", .yellow)
        case .playing:
            return session.unidentified ? ("PLAYING  ·  UNKNOWN", .green) : ("PLAYING  \(elapsed)", .green)
        case .betweenTracks:
            return ("BETWEEN TRACKS", .cyan)
        case .sideEnded:
            return ("SIDE COMPLETE — FLIP IT", .orange)
        }
    }
}

/// Artwork, title/artist/album, and the playback clock with its confidence.
private struct NowPlayingCard: View {
    let session: SessionSnapshot
    let metadata: TrackMetadata?
    let artwork: NSImage?
    let now: Double
    let u: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: u * 1.5) {
            ZStack {
                RoundedRectangle(cornerRadius: u * 0.6).fill(Color.white.opacity(0.08))
                if let artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: session.isRecognizing ? "waveform" : "record.circle")
                        .font(.system(size: u * 5))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: u * 12, height: u * 12)
            .clipShape(RoundedRectangle(cornerRadius: u * 0.6))

            VStack(alignment: .leading, spacing: u * 0.5) {
                Text(title)
                    .font(.system(size: u * 2.2, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(session.track?.artist ?? " ")
                    .font(.system(size: u * 1.7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Text(albumLine)
                    .font(.system(size: u * 1.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.gray)
                Spacer(minLength: 0)
                if let clock = session.clock {
                    progress(clock)
                    Text(clockLine(clock))
                        .font(.system(size: u * 1.2, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.gray)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: u * 36, height: u * 12)
    }

    private var title: String {
        if let track = session.track { return track.title }
        if session.unidentified { return "Unknown record" }
        return session.isRecognizing ? "Listening…" : " "
    }

    private var albumLine: String {
        guard let metadata else { return " " }
        var parts: [String] = []
        if let album = metadata.album { parts.append(album) }
        if let year = metadata.year { parts.append(String(year)) }
        if let n = metadata.trackNumber {
            parts.append(metadata.trackCount.map { "track \(n)/\($0)" } ?? "track \(n)")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func progress(_ clock: PlaybackClock) -> some View {
        let position = clock.position(at: now)
        let fraction = metadata?.duration.map { min(1, max(0, position / $0)) }
        return VStack(alignment: .leading, spacing: u * 0.3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color.white).frame(width: g.size.width * (fraction ?? 0))
                }
            }
            .frame(height: u * 0.6)
            Text("\(formatDuration(position)) / \(metadata?.duration.map(formatDuration) ?? "–:––")")
                .font(.system(size: u * 1.4, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private func clockLine(_ clock: PlaybackClock) -> String {
        let confidence = Int((clock.confidence(at: now) * 100).rounded())
        let speed = (clock.rate - 1) * 100
        return String(format: "sync %d%%  ·  speed %+.2f%%  ·  ×%d", confidence, speed, session.matchCount)
    }
}

/// 0…1 for a dB value over a fixed meter range.
private func meterPosition(_ db: Float, floor: Float = -80) -> CGFloat {
    CGFloat(max(0, min(1, (db - floor) / -floor)))
}

private struct SpectrumBars: View {
    let spectrum: [Float]

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(spectrum.count)
            let slot = size.width / count
            for (i, db) in spectrum.enumerated() {
                // Per-band power in a 40-band split sits ~15 dB under full-band level.
                let h = meterPosition(db + 10, floor: -70) * size.height
                let rect = CGRect(x: CGFloat(i) * slot + slot * 0.12, y: size.height - h,
                                  width: slot * 0.76, height: h)
                let hue = 0.62 - 0.62 * Double(i) / Double(count)
                context.fill(Path(roundedRect: rect, cornerRadius: slot * 0.2),
                             with: .color(Color(hue: hue, saturation: 0.85, brightness: 1)))
            }
        }
    }
}

private struct BandMeters: View {
    let bands: BandEnergies
    let u: CGFloat

    var body: some View {
        HStack(spacing: u) {
            ForEach(Array(zip(["SUB", "BASS", "MID", "HIGH"], bands.asArray)), id: \.0) { name, value in
                VStack(spacing: u * 0.3) {
                    GeometryReader { g in
                        let h = meterPosition(decibels(value), floor: -70) * g.size.height
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: u * 0.4).fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: u * 0.4).fill(Color.white).frame(height: h)
                        }
                    }
                    Text(name)
                        .font(.system(size: u * 1.2, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }
        }
    }
}

/// Peak/RMS bar with peak hold and a clip lamp that stays lit for two seconds.
struct LevelMeter: View {
    let snapshot: PipelineSnapshot
    let u: CGFloat

    var body: some View {
        let clipping = snapshot.lastClipTime.map { snapshot.features.time - $0 < 2 } ?? false
        VStack(alignment: .leading, spacing: u * 0.4) {
            HStack {
                Text(String(format: "PEAK %.1f dB", snapshot.peakHoldDB))
                    .font(.system(size: u * 1.2, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.gray)
                Spacer()
                Text("CLIP")
                    .font(.system(size: u * 1.2, weight: .heavy, design: .rounded))
                    .padding(.horizontal, u * 0.5)
                    .background(RoundedRectangle(cornerRadius: u * 0.3).fill(clipping ? Color.red : Color.white.opacity(0.08)))
                    .foregroundStyle(clipping ? .white : .gray)
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: u * 0.4).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: u * 0.4).fill(Color.green.opacity(0.5))
                        .frame(width: meterPosition(decibels(snapshot.features.peak)) * w)
                    RoundedRectangle(cornerRadius: u * 0.4).fill(Color.green)
                        .frame(width: meterPosition(decibels(snapshot.features.rms)) * w)
                    Rectangle().fill(Color.white)
                        .frame(width: u * 0.3)
                        .offset(x: meterPosition(snapshot.peakHoldDB) * w - u * 0.15)
                }
            }
        }
    }
}

/// Ten seconds of the gated music-band level the side detector actually decides on,
/// with its thresholds drawn across.
struct LevelHistory: View {
    let snapshot: PipelineSnapshot
    let u: CGFloat

    var body: some View {
        Canvas { context, size in
            let floor: Float = -80
            func y(_ db: Float) -> CGFloat { size.height * (1 - meterPosition(db, floor: floor)) }

            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: u * 0.5),
                         with: .color(.white.opacity(0.06)))
            let history = snapshot.levelHistory
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, db) in history.enumerated() {
                path.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(history.count - 1), y: y(db)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            context.fill(path, with: .color(.white.opacity(0.35)))

            let c = snapshot.config
            for (db, color) in [(c.startThresholdDB, Color.green), (c.stopThresholdDB, .orange), (c.needleLiftFloorDB, .red)] {
                let line = Path(CGRect(x: 0, y: y(db) - u * 0.15, width: size.width, height: u * 0.3))
                context.fill(line, with: .color(color))
            }
        }
    }
}

private struct BeatDot: View {
    let snapshot: PipelineSnapshot
    let u: CGFloat

    var body: some View {
        let flash = snapshot.lastBeatTime.map { max(0, 1 - (snapshot.features.time - $0) / 0.18) } ?? 0
        Circle()
            .fill(Color.white.opacity(0.15 + 0.85 * flash))
            .frame(width: u * 2.2, height: u * 2.2)
            .padding(.trailing, u)
    }
}
