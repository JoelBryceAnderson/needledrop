# Needledrop

Drop the needle and the TV comes alive. See the project brief for the full vision; this
README covers how the code is laid out and how to work on it.

**Status: Milestone 8 (Ready for daily use).**
- **Setup:** a setup assistant (gain, level calibration, output latency, launch at login).
- **Recovery:** after stalls, sleep and crashes.
- **Without a turntable:** inputs for this Mac's audio, Apple Music and Spotify, song files, and naming a track by hand.
- **CI** on every PR.

Setup checklist: [docs/FIRST-RUN.md](docs/FIRST-RUN.md). Before that, **Milestone 7 (Polish)**:
- **Typewriter lyrics:** words print one at a time, timed by syllables and nudged onto the beat.
- **Cover modes:** the cover can dissolve into paper shards on transients, or become a virtual record (spinning at 33⅓ or 45, with a tonearm that tracks the side).
- **Side end:** the picture winds down like a record slowing and prints "Side A complete — flip for side B".
- **Idle:** the screen becomes a drifting wall of every album you've played.
- **Settings:** now in tabs.

Before that, **Milestone 6 (Art director)**: On a new album, Claude looks at the cover and sets
the record's look: palette, background (paper folds, Googie, or its own shader), fold
composition, motion and typography. Custom shaders are compiled and test-rendered in a
sandbox before they're shown. One request per album, cached. Before that, **Milestone 5 (Memory)**: Every side is recorded (with pre-roll), split into
tracks at gaps and track changes, encoded losslessly (ALAC or FLAC) with full tags and
artwork, and filed under `~/Music/Needledrop/Artist/Album/`. Repeat plays keep only the
best recording, and a SQLite library logs every play. Before that, **Milestone 4 (Voice)**: Time-synced lyrics from LRCLIB drift across the screen,
timed to what the room hears (with an output-latency setting for AirPlay). Before that,
**Milestone 3 (Eyes v1)**: On top of M1's ears and M2's brain, the TV now shows a
Metal scene: a palette-bleed field in the album's colours, and the cover itself as a "living
cover" whose subject floats off its background with the bass. Albums crossfade into each
other, and the picture fades to black when the turntable goes quiet.

## Layout

```
needledrop/
├── project.yml              xcodegen spec → Needledrop.xcodeproj (generated, not committed)
├── Makefile                 test / app / synth / analyze / play / listen
├── App/Needledrop/          SwiftUI shell: menu bar item, settings, full-screen visuals window
├── NeedledropKit/           Swift package with the engine, one target per module
│   ├── Sources/
│   │   ├── AudioCapture/    device catalog (CoreAudio), AVAudioEngine input, lock-free SPSC ring buffer
│   │   ├── SignalAnalysis/  FFT, band energies, RMS/peak/clip, flatness, spectral flux, onsets, tempo + beat clock
│   │   ├── Recognition/     ShazamKit + scripted recognizers, matching-window gate, playback clock
│   │   ├── Metadata/        iTunes lookup/search, hi-res artwork, disk cache
│   │   ├── ArtDirector/     Claude style specs (raw HTTP Messages API), validation, per-album cache, keychain key
│   │   ├── Archive/         side recorder, track splitter, ALAC/FLAC encoder + tags, GRDB library
│   │   ├── Lyrics/          LRC parser, LRCLIB provider with disk cache
│   │   ├── Visuals/         Metal renderer (runtime-compiled MSL), palettes, audio drive, scene director
│   │   ├── SessionState/    side detector + session machine (idle → listening → recognizing → playing ⇄ betweenTracks → sideEnded)
│   │   ├── Pipeline/        AnalysisCore, ListeningPipeline (thread, snapshot, events), Engine (actor that runs it all)
│   │   ├── ReplayHarness/   file replay source, offline runner, synthetic sides, track sidecars, side report
│   │   └── needledrop-replay/  CLI
│   └── Tests/               ring buffer, DSP, side detector, end-to-end replay
├── Fixtures/                generated/recorded test audio (WAVs git-ignored)
└── docs/DECISIONS.md        design decisions and answers to the brief's open questions
```

Milestone 7 adds polish on top of these as further targets in the same
package.

### Data flow

```
LiveInputSource ─┐                                   ┌─▶ snapshot()  (UI pulls at display rate)
                 ├─▶ AudioRingBuffer ─▶ analysis ─▶ AnalysisCore ─┤
FileReplaySource ┘    (lock-free)       thread     (features +    └─▶ events  (AsyncStream)
                                                    side detector)
OfflineReplay ─────────────────────────────────────▶ AnalysisCore   (tests / CLI, as fast as possible)

Engine (actor): pipeline events + ticks ─▶ SessionMachine ─▶ open/close matching windows
                                               ▲                 │
                RecognitionController ─────────┘ (matches,       ▼
                (AudioObserver on the analysis      in order)   MetadataResolver ─▶ artwork
                 thread → Shazam / scripted)
```

- The capture tap only writes into the ring buffer. It never locks or allocates.
- Timestamps are **audio time** (frames consumed ÷ sample rate), not wall time. Replay at
  any speed gives identical results, and the tests check that the live and offline paths agree.
- The UI never gets pushed per-hop updates. The overlay reads one `PipelineSnapshot` and
  one `SessionSnapshot` per frame.
- Recognition results are posted into the pipeline's own event stream, so session logic sees
  matches in order with the audio that produced them, even when replaying at 40×.
- Shazam is only fed during matching windows: when a side starts, after each gap, every 25 s
  to correct drift and catch segues, and just after the clock says a track should have ended.

## Working on it

```bash
make test                      # 100 tests: DSP, detector, session, clock, metadata, visuals, end-to-end replay
make synth                     # writes Fixtures/synthetic-side.wav (3 tracks, known BPMs and gaps)
make analyze                   # offline: sides, gaps, per-track tempo (~75× real time in debug)
make analyze FILE=~/side-a.wav ARGS="--timeline out.csv"   # per-hop features to tune thresholds
make play                      # real-time through the live ring-buffer path
make devices                   # list inputs + UIDs
make listen ARGS="--device <uid>"   # live input, terminal meter (Terminal needs mic permission)
make run                       # build and open the app
swift run --package-path NeedledropKit needledrop-replay still out.png --art cover.jpg --lyric "Some line"
                               # render the visuals offscreen to a PNG (no display needed)
```

In the app, **Settings › Input › Replay a Recording…** loops a file through the full live
path, so you can work on the visuals without the turntable running. If the file has a
`<name>.tracks.json` sidecar (`make synth` writes one), replay uses it instead of Shazam to
say what's playing. That exercises the clock, metadata and artwork offline and without
signing. Esc or ⌃⌘F toggles full
screen. **D** toggles the debug overlay over the visuals. Pick the TV under **Settings ›
Visuals › Display**.

### Tuning side detection with a real record

1. Record a side with your interface (QuickTime or any recorder; 24-bit WAV), including the lead-in and some run-out.
2. Run `make analyze FILE=… ARGS="--timeline t.csv"` and look at `music_db` / `flatness` in the lead-in, the gaps, and the music.
3. Set the start threshold between the lead-in noise and the music, and the stop threshold just above the gap noise. Use the CLI flags or the live sliders in Settings, which show the same gated level with the threshold lines drawn over it.

### Signing and ShazamKit

Recognition from real records needs a signed build with ShazamKit enabled:

1. Change `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to something you own, and set `DEVELOPMENT_TEAM`.
2. In the Apple Developer portal, go to Identifiers, open that App ID, and enable **ShazamKit** under App Services.
3. Run `make project` and build from Xcode.

Without this the app still runs, but every match attempt fails, and the overlay log shows
the ShazamKit error. Ad-hoc builds also re-prompt for microphone access after each rebuild.
