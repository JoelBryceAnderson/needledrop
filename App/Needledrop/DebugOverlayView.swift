import Pipeline
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
            GeometryReader { geometry in
                let u = min(geometry.size.width / 64, geometry.size.height / 40)
                OverlayLayout(snapshot: snapshot, log: model.log, u: u)
                    .padding(u * 2)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard model.settings.fullScreen else { return .ignored }
            model.toggleFullScreen()
            return .handled
        }
    }
}

private struct OverlayLayout: View {
    let snapshot: PipelineSnapshot
    let log: [LogEntry]
    let u: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: u) {
            header
            Text(sourceLine)
                .font(.system(size: u * 1.4, weight: .medium, design: .rounded))
                .foregroundStyle(snapshot.droppedFrames > 0 ? .red : .gray)
            SpectrumBars(spectrum: snapshot.spectrum)
                .frame(maxHeight: .infinity)
            HStack(alignment: .bottom, spacing: u * 2) {
                BandMeters(bands: snapshot.features.bands, u: u)
                LevelMeter(snapshot: snapshot, u: u)
                    .frame(width: u * 18)
            }
            .frame(height: u * 7)
            LevelHistory(snapshot: snapshot, u: u)
                .frame(height: u * 7)
            VStack(alignment: .leading, spacing: u * 0.2) {
                ForEach(log.suffix(3)) { entry in
                    Text(entry.text).lineLimit(1)
                }
            }
            .font(.system(size: u * 1.3, weight: .medium, design: .rounded))
            .foregroundStyle(.gray)
            .frame(height: u * 4.5, alignment: .bottom)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(phaseText.label)
                .font(.system(size: u * 3, weight: .heavy, design: .rounded))
                .foregroundStyle(phaseText.color)
            Spacer()
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
        switch snapshot.phase {
        case .idle:
            if case .sideEnded(_, let end, _)? = snapshot.recentEvents.last, now - end < 20 {
                return ("SIDE COMPLETE — FLIP IT", .orange)
            }
            return ("WAITING FOR NEEDLE", .gray)
        case .arming:
            return ("LISTENING…", .yellow)
        case .playing(let start):
            return ("SIDE PLAYING  \(formatDuration(now - start))", .green)
        case .quiet(let start, let since):
            let quiet = now - snapshot.config.smoothingWindow / 2 - since
            if quiet >= snapshot.config.gapMinimum {
                return (String(format: "BETWEEN TRACKS  %.0f s", quiet), .cyan)
            }
            return ("SIDE PLAYING  \(formatDuration(now - start))", .green)
        }
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
