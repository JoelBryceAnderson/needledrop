import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Owns the visuals window. Full screen is macOS's own: the window gets its own Space on
/// the chosen display (the TV), with the menu bar and Dock out of the way. Otherwise it's a
/// normal window for development. Follows displays as they come and go.
@MainActor
final class PresentationController {
    var onDisplaysChanged: (() -> Void)?
    /// The green button, ⌃⌘F and the F key land here, so the setting stays the source of truth.
    var onToggleFullScreen: (() -> Void)?
    /// The window left full screen some other way (say, its display went away).
    var onFullScreenEnded: (() -> Void)?

    private var window: VisualsWindow?
    private var cursorTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// What `present` asked for; `reconcile` moves the window there one transition at a time.
    private var wantFullScreen = false
    private var targetScreen: NSScreen?
    private var transitioning = false
    /// Leaving full screen on purpose (to change display or go windowed), not by surprise.
    private var expectingExit = false

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplaysChanged?() }
        })
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
        let isNew = window == nil
        let window = self.window ?? makeWindow()
        let screenChanged = targetScreen != screen
        wantFullScreen = fullScreen
        targetScreen = screen

        // Attach the view; let the window size it (not the other way round): the overlay
        // fills whatever it's given and has no meaningful ideal size.
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        if !window.isFullScreen, isNew || screenChanged { placeWindowed(window, on: screen) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Full-screen transitions need the window on screen first.
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }

    private func makeWindow() -> VisualsWindow {
        let window = VisualsWindow()
        window.onToggleFullScreen = { [weak self] in self?.onToggleFullScreen?() }
        window.onTransitionFailed = { [weak self] in
            self?.transitioning = false
            self?.expectingExit = false
        }
        self.window = window
        let center = NotificationCenter.default
        let events: [(Notification.Name, @MainActor (PresentationController) -> Void)] = [
            (NSWindow.willEnterFullScreenNotification, { $0.transitioning = true }),
            (NSWindow.willExitFullScreenNotification, { $0.transitioning = true }),
            (NSWindow.didEnterFullScreenNotification, { $0.didEnter() }),
            (NSWindow.didExitFullScreenNotification, { $0.didExit() }),
        ]
        for (name, handler) in events {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            })
        }
        return window
    }

    private func didEnter() {
        transitioning = false
        startHidingCursor()
        reconcile()
    }

    private func didExit() {
        transitioning = false
        stopHidingCursor()
        if !expectingExit, wantFullScreen {
            // Left full screen by some other route: follow it rather than fight it.
            wantFullScreen = false
            onFullScreenEnded?()
        }
        expectingExit = false
        reconcile()
    }

    /// One step towards the wanted state; the did-enter/exit notifications call back here.
    private func reconcile() {
        guard let window, let screen = targetScreen, !transitioning else { return }
        if window.isFullScreen {
            if !wantFullScreen || window.screen != screen {
                expectingExit = true
                window.nativeToggleFullScreen()
            }
        } else if wantFullScreen {
            // macOS makes the Space on whichever display the window is on.
            if window.screen != screen { placeWindowed(window, on: screen) }
            window.nativeToggleFullScreen()
        }
    }

    private func placeWindowed(_ window: NSWindow, on screen: NSScreen) {
        let size = NSSize(width: 960, height: 540)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
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

final class VisualsWindow: NSWindow, NSWindowDelegate {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = "Needledrop"
        isReleasedWhenClosed = false
        backgroundColor = .black
        collectionBehavior = [.fullScreenPrimary]
        delegate = self
    }

    var onToggleFullScreen: (() -> Void)?
    /// A full-screen transition didn't happen (there's no notification for this).
    var onTransitionFailed: (() -> Void)?

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { onTransitionFailed?() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { onTransitionFailed?() }

    var isFullScreen: Bool { styleMask.contains(.fullScreen) }

    /// The green button and ⌃⌘F go through the app's setting, which then calls
    /// `nativeToggleFullScreen`.
    override func toggleFullScreen(_ sender: Any?) {
        if let onToggleFullScreen { onToggleFullScreen() } else { super.toggleFullScreen(sender) }
    }

    func nativeToggleFullScreen() {
        super.toggleFullScreen(nil)
    }
}
