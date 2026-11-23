import AudioCapture
import AVKit
import SwiftUI

/// Where the turntable pass-through plays, and (for AirPlay) which speakers.
struct PassThroughOutputRows: View {
    let model: AppModel

    var body: some View {
        Picker("Play to", selection: Binding(
            get: { model.settings.passThroughOutput },
            set: { output in
                model.settings.passThroughOutput = output
                // AirPlay buffers about 2 s: start the picture somewhere near what the room hears.
                if output == .airPlay, model.settings.outputLatency < 1 { model.settings.outputLatency = 2 }
                Task { await model.restartInput() }
            }
        )) {
            Text("This Mac's output").tag(PassThrough.Output.thisMac)
            Text("AirPlay speakers (several at once)").tag(PassThrough.Output.airPlay)
        }
        .help("This Mac's output follows the Sound setting: its speakers, or one AirPlay speaker. AirPlay speakers plays to every speaker you tick, in sync.")
        if model.settings.passThroughOutput == .airPlay {
            AirPlaySpeakersRow()
        }
    }
}

/// The chosen speakers, with the system AirPlay button to change them.
private struct AirPlaySpeakersRow: View {
    @State private var names = AirPlayRoute.shared.speakerNames
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speakers")
                Spacer()
                Text(names.isEmpty ? "None chosen" : names.joined(separator: " + "))
                    .foregroundStyle(names.isEmpty ? .orange : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                if AirPlayRoute.shared.isAvailable {
                    AirPlayButton().frame(width: 28, height: 22)
                }
            }
            Text(AirPlayRoute.shared.isAvailable
                 ? "Click the AirPlay button and tick every speaker that should play (tick them all for the whole house). macOS forgets the choice when Needledrop quits, so pick them again after a relaunch. Set Output latency (Display) to match: HomePods are usually 2–2.5 s."
                 : "This version of macOS doesn't let Needledrop group AirPlay speakers, so it plays to this Mac's output instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: AirPlayRoute.speakersDidChange)) { _ in refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        let now = AirPlayRoute.shared.speakerNames
        if now != names { names = now }
    }
}

/// The system AirPlay picker, pointed at the pass-through's speaker group so it's multi-select.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        AirPlayRoute.shared.attach(picker: picker)
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {}
}
