import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Owns the visuals window: borderless and covering the chosen display (the TV), or a
/// normal window for development. Follows displays as they come and go.
@MainActor
final class PresentationController {
    var onDisplaysChanged: (() -> Void)?
    /// The green button, ⌃⌘F and View › Enter Full Screen land here: Needledrop's own
    /// full screen (borderless over the chosen display), not a macOS full-screen Space.
    var onToggleFullScreen: (() -> Void)?

    private var window: VisualsWindow?
    private var cursorTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplaysChanged?() }
        }
    }

    /// The configured display if attached (matched by ID, then by name), else the main one.
    static func screen(displayID: UInt32?, displayName: String?) -> NSScreen {
        NSScreen.screens.first { $0.displayID == displayID }
            ?? NSScreen.screens.first { $0.localizedName == displayName }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    func present<Content: View>(_ content: Content, displayID: UInt32?, displayName: String?, fullScreen: Bool) {
        let screen = Self.screen(displayID: displayID, displayName: displayName)
        let window = self.window ?? VisualsWindow()
        self.window = window
        window.onToggleFullScreen = { [weak self] in self?.onToggleFullScreen?() }

        if fullScreen {
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
            // Hide the menu bar and Dock only when we're covering the screen they're on.
            NSApp.presentationOptions = screen == NSScreen.screens.first ? [.autoHideMenuBar, .autoHideDock] : []
            startHidingCursor()
        } else {
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.title = "Needledrop"
            let size = NSSize(width: 960, height: 540)
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
            // Shows the green full-screen button; VisualsWindow routes it to our own mode.
            window.collectionBehavior = [.fullScreenPrimary]
            NSApp.presentationOptions = []
            stopHidingCursor()
        }
        // Attach after sizing, and let the window size the view (not the other way round):
        // the overlay fills whatever it's given and has no meaningful ideal size.
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startHidingCursor() {
        guard cursorTimer == nil else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func stopHidingCursor() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }
}

/// Borderless windows can't become key by default; we want Esc / ⌘F to reach it.
final class VisualsWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
    }

    var onToggleFullScreen: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The green button and ⌃⌘F: switch to (or out of) the borderless presentation rather
    /// than a macOS full-screen Space, which can't follow the TV or hide the cursor.
    override func toggleFullScreen(_ sender: Any?) {
        if let onToggleFullScreen { onToggleFullScreen() } else { super.toggleFullScreen(sender) }
    }
}
