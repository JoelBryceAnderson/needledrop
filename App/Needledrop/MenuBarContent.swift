import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Text(model.log.last?.text ?? "Starting…")
        Divider()
        if let started = model.recordingStartedAt {
            Text("● Recording since \(started.formatted(date: .omitted, time: .shortened))")
        }
        Button("Show Visuals") { model.presentVisuals() }
        Button(model.settings.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [.command, .control])
        Button(model.settings.showDebugOverlay ? "Hide Debug Overlay" : "Show Debug Overlay") { model.toggleDebugOverlay() }
            .keyboardShortcut("d", modifiers: [.command, .control])
        Toggle("Lyrics", isOn: Binding(get: { model.settings.showLyrics }, set: { _ in model.toggleLyrics() }))
            .keyboardShortcut("l", modifiers: [.command, .control])
        Toggle("Album Art", isOn: Binding(get: { model.settings.showCover }, set: { _ in model.toggleCover() }))
            .keyboardShortcut("a", modifiers: [.command, .control])
        WhatsPlayingButton()
        Toggle("Recognise Records", isOn: Binding(
            get: { model.recognitionOn },
            set: { on in Task { await model.setRecognitionOn(on) } }
        ))
        RecordButton(model: model)
        Button("Set Up Turntable…") { model.showSetup() }
        Button("Re-roll Album Look") { model.rerollAlbumLook() }
            .disabled(model.currentAlbumKey == nil)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Needledrop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Start/Stop Recording (⌃⌘R): records whatever the input hears until stopped.
struct RecordButton: View {
    let model: AppModel

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : model.savingRecording ? "Saving Recording…" : "Start Recording") {
            Task { await model.toggleRecording() }
        }
        .keyboardShortcut("r", modifiers: [.command, .control])
        .disabled(model.savingRecording || model.settings.input == .systemAudio)
    }
}
