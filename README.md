# Needledrop

Drop the needle and the TV comes alive. See the project brief for the full vision; this
README covers how the code is laid out and how to work on it.

**Status: Milestone 1 (Ears).** Audio capture, live analysis, side start/gap/end
detection, a TV-scaled debug overlay, settings, and a replay harness.

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
│   │   ├── SessionState/    side detector (idle → arming → playing ⇄ quiet → ended)
│   │   ├── Pipeline/        AnalysisCore (deterministic, per hop) + ListeningPipeline (thread, snapshot, events)
│   │   ├── ReplayHarness/   file replay source, offline runner, synthetic side generator, side report
│   │   └── needledrop-replay/  CLI
│   └── Tests/               ring buffer, DSP, side detector, end-to-end replay
├── Fixtures/                generated/recorded test audio (WAVs git-ignored)
└── docs/DECISIONS.md        design decisions and answers to the brief's open questions
```

Later milestones add `Recognition`, `Metadata`, `Lyrics`, `ArtDirector`, `Visuals`, and
`Archive` as further targets in the same package.

### Data flow

```
LiveInputSource ─┐                                   ┌─▶ snapshot()  (UI pulls at display rate)
                 ├─▶ AudioRingBuffer ─▶ analysis ─▶ AnalysisCore ─┤
FileReplaySource ┘    (lock-free)       thread     (features +    └─▶ events  (AsyncStream)
                                                    side detector)
OfflineReplay ─────────────────────────────────────▶ AnalysisCore   (tests / CLI, as fast as possible)
```

- The capture tap only writes into the ring buffer. It never locks or allocates.
- Timestamps are **audio time** (frames consumed ÷ sample rate), not wall time. Replay at
  any speed gives identical results, and the tests check that the live and offline paths agree.
- The UI never gets pushed per-hop updates. The overlay reads one `PipelineSnapshot` per frame.

## Working on it

```bash
make test                      # 33 tests: DSP, detector, ring buffer, end-to-end replay
make synth                     # writes Fixtures/synthetic-side.wav (3 tracks, known BPMs and gaps)
make analyze                   # offline: sides, gaps, per-track tempo (~75× real time in debug)
make analyze FILE=~/side-a.wav ARGS="--timeline out.csv"   # per-hop features to tune thresholds
make play                      # real-time through the live ring-buffer path
make devices                   # list inputs + UIDs
make listen ARGS="--device <uid>"   # live input, terminal meter (Terminal needs mic permission)
make run                       # build and open the app
```

In the app, **Settings › Input › Replay a Recording…** loops a file through the full live
path, so you can work on the visuals without the turntable running. Esc or ⌃⌘F toggles full
screen. Pick the TV under **Settings › Visuals › Display**.

### Tuning side detection with a real record

1. Record a side with your interface (QuickTime or any recorder; 24-bit WAV), including the lead-in and some run-out.
2. Run `make analyze FILE=… ARGS="--timeline t.csv"` and look at `music_db` / `flatness` in the lead-in, the gaps, and the music.
3. Set the start threshold between the lead-in noise and the music, and the stop threshold just above the gap noise. Use the CLI flags or the live sliders in Settings, which show the same gated level with the threshold lines drawn over it.

### Signing

Set `DEVELOPMENT_TEAM` in `project.yml`. Ad-hoc builds run, but macOS asks for microphone
permission again after every rebuild, and ShazamKit (M2) needs a real team and App ID.
