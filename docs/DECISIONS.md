# Decisions

## Made in Milestone 1

**One Swift package with a target per module, plus an xcodegen app project.** You get
module boundaries and `swift test` without a workspace with many packages. The app needs
a real bundle (mic usage string, entitlements, and an App ID for ShazamKit), so it lives in
a generated Xcode project that depends on the package. The generated `.xcodeproj` isn't committed.

**Not sandboxed.** The archive writes to external drives and NAS paths. Under the sandbox
that means security-scoped bookmarks and re-prompts. This is a personal appliance, so it
uses hardened runtime with the `audio-input` entitlement and no sandbox.

**Side detection uses the 100 Hz – 5 kHz band, median-filtered, gated by spectral flatness.**
The band excludes rumble and most hiss. A 300 ms median removes crackle and the needle-drop
thump. Flatness tells groove noise (≈0.35–0.56) from music (≲0.1), so loud surface noise
can't start a side either. A needle lift is a fast drop *to below the surface-noise floor*.
That's how a song that stops on a hit (a fast drop back to groove noise) is told apart from the
needle coming up. All thresholds can be changed live in Settings and from the CLI.

**Tempo uses multi-band spectral flux plus autocorrelation, with a prior centred on 120 BPM.**
With flux over the whole band, a snare backbeat dominates and the tempo comes out halved.
Averaging flux within lows, mids and highs separately fixes that. The beat clock is a simple
PLL nudged by onsets. It's good enough to drive visuals, not to do beat-matching.

**Ring buffer drops a whole block on overflow and counts it.** It never blocks the capture
thread. It holds about 21 s at 48 kHz, so overflow means the analysis thread stalled. The count
shows on the overlay in red. Replay waits for space instead of dropping.

## Recommendations for the open questions

**SwiftData vs GRDB → GRDB.** The library is relational (album ← tracks ← recordings ← plays),
needs dedup queries ("best recording of this pressing"), and is written from actors off the
main thread. SwiftData's `ModelContext` isolation and migrations get in the way there. GRDB gives
SQL, observation for the library wall, and predictable migrations. It's the only third-party
dependency this needs.

**Depth for living cover → Core ML Depth Anything V2 Small**, run once per album and cached as
a 16-bit PNG. Vision has no general monocular depth request for flat artwork. It's a one-off cost
of a few hundred ms on Apple silicon.

**Low-res output → render at a fixed 640×480 (or 720×480) offscreen and scale up with a soft filter.**
Composite can't show more detail than that anyway, and rendering at that size lets you design for
exactly what reaches the TV and keeps fps headroom. Add a slight blur/bloom pass before output so
edges don't shimmer. Make the internal resolution a setting so an HDMI TV later can use native resolution.

**33⅓ vs 45 → compare how fast `matchOffset` advances against wall clock across re-matches.**
Shazam matches the audio content, so the ratio of offset change to elapsed time ≈ 1.0 at the right
speed. Playing a 45 at 33⅓ gives ≈ 0.74 (and the match usually fails). Lock in the RPM after
two re-matches agree; use the manual override when there are no matches.

**Lyrics → Metal.** Kinetic type that swells with RMS, smears and blends with the scene has to
composite inside the renderer. Rasterise glyph atlases with Core Text (or SDF for big sizes) and
animate them in shaders. A SwiftUI overlay would mean two compositors and no shader effects on the text.
