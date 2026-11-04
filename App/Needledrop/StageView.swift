import Metadata
import MetalKit
import SwiftUI
import Visuals

/// What the TV shows: the Metal scene, a brief now-playing caption, and (optionally)
/// the debug overlay on top.
struct StageView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if let renderer = model.renderer {
                MetalView(renderer: renderer)
            } else {
                Color.black
            }
            if model.settings.showNowPlaying {
                NowPlayingCaption(model: model)
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

/// Lower-third caption: fades in when a track's metadata arrives, out after a few seconds.
private struct NowPlayingCaption: View {
    let model: AppModel
    private let visible = 8.0
    private let fade = 0.8

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                let u = min(geometry.size.width / 64, geometry.size.height / 40)
                if let since = model.nowPlayingSince, let info = model.metadata {
                    let age = context.date.timeIntervalSince(since)
                    let opacity = min(1, age / fade) * max(0, min(1, (visible - age) / fade))
                    if opacity > 0 {
                        caption(info, u: u)
                            .opacity(opacity)
                            .padding(.leading, u * 3)
                            .padding(.bottom, u * 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func caption(_ info: TrackMetadata, u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: u * 0.3) {
            Text(info.title)
                .font(.system(size: u * 2.6, weight: .heavy, design: .rounded))
            Text([info.artist, info.album].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.system(size: u * 1.6, weight: .semibold, design: .rounded))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: u * 0.6)
        .lineLimit(1)
    }
}
