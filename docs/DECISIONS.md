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

## Made in Milestone 2

**The session machine is a pure reducer driven by audio time; the `Engine` actor runs it.**
Inputs are side events, 4 Hz ticks from the pipeline, matches and track durations. Outputs
are effects: open/close a matching window, track changed. With no clocks or I/O in the
machine, the brief's state machine is unit-tested directly. Because time is audio time, a
40× replay gives the same transitions as real time.

**Matching windows, not continuous matching.** Shazam is fed only while a window is open
(15 s maximum). Windows open at side start, after a gap, every 25 s while a track plays, and
3 s after the track's known end (from the iTunes duration). That's enough to catch segues and
correct drift without streaming to ShazamKit all side long. After 45 s with no match the track
is marked unidentified, and the visuals carry on audio-reactively; retries continue every 30 s.

**Playback clock:** anchors from matches. The rate is 1 + Shazam frequency skew until
anchors span 40 s, then a least-squares slope (clamped ±6%). Corrections under 3 s are
slewed in over 2 s so lyrics never jump. Bigger ones snap, because that means the needle was moved.
Confidence falls with staleness and with the size of the last correction.

**Recognition results go through the pipeline's event stream** (`ListeningPipeline.post`),
not a separate stream. With two streams, a match could be applied after the gap that
followed it whenever the consumer lagged.

**`.finished` is reported only after the ring buffer drains.** Before this, the end of a
replay (including the side end in its trailing silence) could be lost.

**Metadata:** iTunes lookup by Apple Music ID, falling back to a scored search that
prefers exact title and artist and the original album over compilations. Album names are
stripped of "(Remastered)"/"(Deluxe)" suffixes. Artwork is the 1200×1200 rendition, cached per
album, and all metadata is cached on disk, so a familiar record never hits the network.

## Made in Milestone 3

**Render at 480 lines, scale up bilinearly.** The scene goes to an `rgba16Float` texture
480 px tall, with its width following the display's aspect. A second pass upscales it to
the drawable. This answers the "crisp at composite" open question: designing at the
resolution that actually reaches the TV keeps detail honest, and the upscale is naturally
soft. `internalHeight` is a property, so an HDMI TV could use native resolution later.

**Shaders compile from source at runtime** (`makeLibrary(source:)`), the same path
Claude-generated shaders will take in M6. The renderer test compiles them, renders frames
offscreen and checks the output isn't black, white or flat. That's the beginning of the M6
shader validator.

**Living cover uses Vision's foreground-instance mask, not a depth model.** It runs offline
and ships with the OS. It produces two layers (subject and background), and the bass
pushes them apart. Covers with no clear subject (typography, abstract art) get no mask and
drift as a whole. A Core ML depth model (Depth Anything) is still the upgrade path if
two-layer parallax looks too flat on real covers.

**Palette gradients run in lightness order and sweep back and forth.** In dominance order,
adjacent palette entries can be cream and black, which drew thin dark veins: exactly the
fine detail composite turns to mush.

**Audio drive is auto-gained per band.** Each band is scaled against its own decaying peak
(24 dB range, 6 dB/s release), and anything under −60 dB is zero. Quiet records move the
picture as much as loud ones, and groove noise between tracks stays dark.

**Transitions run on wall-clock time; looks are per album.** Tracks from the same album
don't crossfade. A new album crossfades over 3 s. The picture holds for 20 s after the
music stops (a flip, a lift), then fades out over 4 s. Text (the lower-third caption) is a
SwiftUI overlay for now. Lyrics in M4 will move text into Metal, as recommended below.

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
