# First run

A checklist for the first evening with the turntable, the Mac mini and the TV. Most of
it is a one-off.

## 1. Hook it up

```
Turntable (line out) ── RCA Y-split ─┬─ TV AV input (audio) → Apple TV → AirPlay → HomePods
                                     └─ USB audio interface → Mac mini
Mac mini HDMI → HDMI-to-AV converter → TV AV input (video)
```

- Use the turntable's **line** output (built-in preamp on), not phono, into the interface.
- Set the Mac's display for the converter to 720×480 (or the converter's native mode).
  Needledrop renders at 480 lines anyway.

## 2. Sign it, and turn on Shazam (once)

Recognition from the record itself needs a signed build with ShazamKit:

1. In `project.yml`, change the bundle ID to one you own and set `DEVELOPMENT_TEAM`.
2. developer.apple.com › Identifiers › your App ID › App Services › **ShazamKit**.
3. Run `make run-signed` (or `make project`, then build and run from Xcode).

Without this the app still works: visuals react to the music, and you can name tracks
(**What's Playing…**, ⌘K) or let Apple Music or Spotify say what's playing. Records just
aren't identified by ear.

## 3. Run the setup assistant

It opens on first launch with a live input (or menu bar › **Set Up Turntable…**):

1. **Input:** pick the USB interface. Allow microphone access when macOS asks.
2. **Gain:** play the loudest part of a record and adjust the interface gain until it
   says *Good level* (peaks around −9 dBFS, and the CLIP light stays off).
3. **Groove noise, music, needle up:** three short measurements that set where a side
   starts, where the quiet between tracks is, and what a lifted needle looks like.
4. **Output latency:** with HomePods over AirPlay, sound arrives about 2 s after the Mac
   hears it. Drag until the dot flashes with the beat you hear.
5. **Launch at login:** leave it on, so the Mac mini is an appliance.

## 4. Choose where records are archived

Settings › Archive: point it at the external drive or NAS. Sides are split into tracks
and saved as Apple Lossless (or FLAC), filed under `Album Artist/Album/`. A recording
interrupted by a crash or power cut is kept as `Sides/Recovered … .caf`.

## 5. Put the visuals on the TV

Settings › Visuals › Display: pick the converter's display, and turn on full screen.
Optionally add a Claude API key (Settings › Art Director) so each album gets its own look.

## Without a turntable

- **This Mac's audio:** YouTube, Spotify, anything the Mac plays. Allow *System Audio
  Recording* when asked. Streamed audio is never archived.
- **Apple Music / Spotify:** what they're playing is picked up automatically (allow
  "control Music" once, for lyric timing).
- **Replay a song file:** Settings › Listening › Replay a Recording… plays it through the
  Mac's speakers. Files with title and artist tags are identified from them.
- **Demo:** `make synth` writes a royalty-free side with its own cover and lyrics. Replay
  `Fixtures/synthetic-side.wav`.

## If something's off

| Symptom | Try |
|---|---|
| Nothing reacts | Settings › Listening meter: is anything arriving? Check the input and its permission. |
| Sides start on surface noise | Re-run setup; or raise *Start threshold* a few dB. |
| Tracks split in the wrong place | Lower *Track gap at least*, or check *Stop threshold* sits just above the quiet between tracks. |
| Lyrics early or late | Adjust *Output latency* (Settings › Visuals). |
| Wrong album identified | Use What's Playing… to correct it. |
| The TV goes to sleep | It shouldn't while music plays; check the converter's own power saving. |
| Audio stops after sleep | Needledrop restarts the input on wake and whenever audio stops arriving; if not, change input in Settings and back. |
