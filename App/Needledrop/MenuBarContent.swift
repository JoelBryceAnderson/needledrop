import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Text(model.log.last?.text ?? "Starting…")
        Divider()
        Button("Show Visuals") { model.presentVisuals() }
        Button(model.settings.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [.command, .control])
        Button(model.settings.showDebugOverlay ? "Hide Debug Overlay" : "Show Debug Overlay") { model.toggleDebugOverlay() }
            .keyboardShortcut("d", modifiers: [.command, .control])
        Toggle("Lyrics", isOn: Binding(get: { model.settings.showLyrics }, set: { _ in model.toggleLyrics() }))
            .keyboardShortcut("l", modifiers: [.command, .control])
        Toggle("Album Art", isOn: Binding(get: { model.settings.showCover }, set: { _ in model.toggleCover() }))
            .keyboardShortcut("a", modifiers: [.command, .control])
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Needledrop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
