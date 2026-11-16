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
                Button(delegate.model.settings.fullScreen ? "Exit Full Screen" : "Enter Full Screen") {
                    delegate.model.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                RecordButton(model: delegate.model)
                Button("Set Up Turntable…") { delegate.model.showSetup() }
            }
        }
        MenuBarExtra {
            MenuBarContent(model: delegate.model)
        } label: {
            // Red while recording, so it's obvious from across the room.
            if delegate.model.isRecording {
                Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.red, .primary)
            } else {
                Image(systemName: "record.circle")
            }
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

    /// Quitting mid-recording saves it first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording else { return .terminateNow }
        Task {
            await model.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
