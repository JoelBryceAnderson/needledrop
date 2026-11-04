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

## Made in Milestone 4

**Output latency.** The room hears the record through TV → Apple TV → AirPlay →
HomePods, typically about 2 s after the Mac's interface does. The pipeline keeps the last
5 s of per-hop features (`FeatureHistory`). The visuals and lyrics read them at
"now − output latency", and the lyric position is taken from the playback clock at that
same delayed audio time. The latency is a setting (0–4 s), tuned by eye against the beat
dot. It defaults to 0 because it depends on the room.

**Lyrics are rendered in Metal, one texture per line.** Each line is set once with Core
Text (heavy rounded type, wrapping to two lines then shrinking), at twice the internal
resolution, and mipmapped. The shader takes its drop shadow and glow from the blurred mip
levels, so text composites into the scene and gets the same low-res treatment as
everything else. A glyph atlas is only needed for the per-word animation planned in M7.

**One kinetic style ("drift").** A line rises in over 0.4 s, floats, swells with level
and beat, then drifts up and dissolves over 0.5 s as the next line arrives. When a track
has synced lyrics, the cover shrinks and lifts to leave the lower band free, easing in
over about a second.

**LRCLIB:** an exact `get` (artist, title, album, duration) first; on a 404, a `search`
that prefers synced results within ±5 s of the track's length. Hits are cached forever,
"not found" for a week, and network errors aren't cached. Instrumentals show nothing. Plain
(unsynced) lyrics are fetched but not shown: a static block of text on a TV isn't the
experience. Lines are hidden while the playback clock's confidence is very low.

## Made in Milestone 5

**Recording is another observer on the analysis thread.** `SideRecorder` always keeps 6 s
of audio, so a recording starts 1 s before the detected side start (which is confirmed
~1.5 s after the music begins). It writes a float32 CAF at the source rate from a private
queue, so the analysis thread never waits on the disk. A 0.1 s RMS envelope is recorded
alongside, for splitting.

**Splitting** (`TrackSplitter`, pure, fixture-tested):
1. Cut at the middle of each detected gap.
2. Give each identified track the segment it was current in. A segment with no track whose
   neighbour should still be playing (by its iTunes length) was a quiet passage, so merge it
   back. Slow intros merge forward the same way.
3. A segment holding two tracks is a segue: split near the later track's clock start,
   snapped to the quietest point within ±4 s. With no ≥6 dB dip, the boundary is marked
   uncertain, which also goes in the file's comment tag.

**Encoding:** ALAC `.m4a` or FLAC at the source rate, with a 24-bit target and 5 ms fades at
the cuts. M4A gets iTunes atoms via an AVFoundation passthrough export. FLAC gets Vorbis
comments and a picture block written directly, because AVFoundation can't tag FLAC.

**Dedup ("keep best") is per track identity:** no clipping beats clipping, then the higher
RMS wins. A worse new recording is discarded; a better one replaces the old file. Unknown
tracks are always kept, under `Unknown/<date>/`.

**Plays are logged even with archiving off**, along with album artwork, for the library
wall in M7.

**GRDB** is the only third-party dependency (7.x). The schema is album, track, side,
recording and play, with migrations from v1.

## Made in Milestone 6

**Raw HTTP to the Messages API.** Swift has no official Anthropic SDK. Requests go to
`claude-opus-5-5` by default (configurable), with:
- adaptive thinking (the model default) at `effort: high`;
- the style spec as structured output (`output_config.format`, JSON schema);
- the cover as a base64 image block;
- server-side refusal fallbacks (`fallbacks: "default"`).

`stop_reason` is checked before anything is read: a refusal or `max_tokens` is an error,
never a half-read spec. The API key lives in the login keychain, with
`ANTHROPIC_API_KEY` as a development fallback.

**What Claude controls:**
- palette;
- background: paper, googie, or a custom shader;
- fold angle and count, which also set the lyric composition;
- motion: speed, bass response, beat response, turbulence;
- typography: font, weight, case, and ink or typewriter animation;
- mode weights;
- mood.

Anything the schema can't express (hex colours, ranges) is validated in Swift and clamped.

**The shader sandbox:** Claude writes only the body of `customScene(uv, u, pal)`, against a
fixed contract of variables and helper functions. The body is:
1. screened: under 6,000 characters; no preprocessor, resources, `while` or `goto`;
2. compiled with an 8 s timeout;
3. rendered through a probe fragment (the background alone) at three times and audio states,
   rejecting NaN or infinite values and frames that are black, white or flat;
4. timed at 854×480 against an 8 ms GPU budget.

A failed spec or shader goes back to Claude once, with the exact reason and its own reply
echoed (thinking blocks included). A second failure keeps the rest of the direction on paper.

**Budget:** one request per new album. Directions are cached on disk with their history.
Re-roll asks for something different, passing the earlier moods, unless the look is pinned.
The extracted-palette look shows immediately and crossfades to Claude's direction when it
arrives.

**Googie is a built-in background,** not just a prompt: kidney shapes, crescent boomerangs,
eight-point starbursts and an atom motif in flat palette colour, with geometric uppercase
type. The Theme setting (Auto / Paper / Googie / Smoke) forces a look or lets Claude choose.

## Made in Milestone 7

**Word-level lyrics without a glyph atlas.** Each line is still one texture, but word *i*
is drawn with red = (i + ½)/n. The shader prints only the first *k* words, with a
fractional *k* fading the current word in. `WordTiming` shares a line's time out by
syllable count, then snaps word starts within 120 ms onto the beat grid. The grid is
projected from the tracked tempo and the last beat, into track time via the playback clock.

**Dissolve:** the cover is a 7×7 grid of triangular shards. An onset scatters them by
half the music's level (at most 0.6); they settle with a 0.35 s decay, and a beat pulls
them home. The shader finds each pixel's shard by undoing nearby shards' offsets.
Deliberately restrained: it was frantic at full strength.

**Virtual record** is drawn in flat vector style:
- wide groove bands, since fine grooves vanish at 480i;
- a fixed sheen while the disc turns, which is what reads as spinning;
- the art as the centre label;
- a tonearm whose stylus moves from the outer edge inward over a typical 22-minute side.

RPM is a setting. "Auto" means 45 for singles and EPs (four tracks or fewer, or the album
name says so) and 33⅓ otherwise. Speed can't be inferred from Shazam, which matches the
music at either speed.

**Side end:** motion and spin ease to a stop over 3 s and the colour drains, then
"Side X complete / Flip for side Y" is printed like the caption. Sides count A, B, C…
within a sitting; a gap of more than 15 minutes starts again at A.

**Library wall:** a SwiftUI view, rebuilt each time it appears so it reflects the latest
plays. Big tiles in three rows drift slowly sideways, with play counts, "most spun this
month" and "on this day". It fades in 25 s into idle, after the scene has faded. The
"When idle" setting can choose plain black instead.

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
