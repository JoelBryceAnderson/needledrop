import SwiftUI

/// Tell Needledrop what's playing, for music it can't recognise yet (no Shazam set up,
/// a stream, a rare pressing). It then fetches the cover, lyrics and look as for a match.
struct WhatsPlayingView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var artist = ""
    @State private var title = ""
    @State private var at = ""
    @State private var message: String?

    var body: some View {
        Form {
            TextField("Artist", text: $artist)
            TextField("Song", text: $title)
            TextField("At (optional)", text: $at, prompt: Text("e.g. 1:23 — leave empty if you started it from the beginning"))
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Set") { set() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(artist.trimmingCharacters(in: .whitespaces).isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func set() {
        Task {
            if let problem = await model.identify(artist: artist, title: title, at: at) {
                message = problem
            } else {
                artist = ""
                title = ""
                at = ""
                message = nil
                dismiss()
            }
        }
    }
}

/// Opens the What's Playing window (menu bar, Controls menu, Settings).
struct WhatsPlayingButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What's Playing…") {
            openWindow(id: "whats-playing")
            NSApp.activate()
        }
    }
}
