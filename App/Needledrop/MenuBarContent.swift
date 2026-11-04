import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Text(model.log.last?.text ?? "Starting…")
        Divider()
        Button("Show Visuals") { model.presentVisuals() }
        Button(model.settings.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
            .keyboardShortcut("f", modifiers: [.command, .control])
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Needledrop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
