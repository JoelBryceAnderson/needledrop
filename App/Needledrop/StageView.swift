import MetalKit
import SwiftUI
import Visuals

/// What the TV shows: the Metal scene (lyrics and the now-playing caption are printed into
/// it) and, optionally, the debug overlay on top.
struct StageView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if let renderer = model.renderer {
                MetalView(renderer: renderer)
            } else {
                Color.black
            }
            // After the scene has faded out (≈20 s + 4 s), the idle screen.
            if model.settings.idleScreen == .libraryWall {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let idle = model.idleSince.map { context.date.timeIntervalSince($0) > 25 } ?? false
                    ZStack {
                        // Inserted fresh each time, so it shows the latest plays.
                        if idle {
                            LibraryWallView(library: model.library).transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 2.5), value: idle)
                }
            }
            if model.settings.showDebugOverlay {
                DebugOverlayView(model: model)
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
        .onKeyPress("d") {
            model.toggleDebugOverlay()
            return .handled
        }
        .onKeyPress("l") {
            model.toggleLyrics()
            return .handled
        }
        .onKeyPress("a") {
            model.toggleCover()
            return .handled
        }
    }
}

private struct MetalView: NSViewRepresentable {
    let renderer: VisualsRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        renderer.configure(view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
