import SwiftUI

@main
struct NeedledropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model)
        }
        Window("What's Playing?", id: "whats-playing") {
            WhatsPlayingView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Controls") {
                WhatsPlayingButton()
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            Image(systemName: "record.circle")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.launch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
