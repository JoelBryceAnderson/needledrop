# Milestone 10 plan: a bigger procedural toolkit for Claude

> **Status:** sections 1, 2 (the first 8 effects), 3 (collage, risograph) and the library-driven
> schema from section 4 are built. Every theme now places lyrics by reading a probe render of
> the background. Still to do: the rest of the effect library, the legibility render check per
> line start, per-section style changes, and GIF/MP4 preview export.

Goal: give Claude many more effects and styles to choose from, and let it place effects at exact
moments in a song. The engine keeps its guarantees: lyrics stay legible, nothing crops, and the
picture holds still while a line is up unless an effect is meant to land on that line.

## 1. Timed effects in the track score

A new `effects` list in `TrackScore`, next to keyframes. Each effect is anchored to the song so it
survives clock drift:

- **Anchors:** a lyric line (`at_line`, optionally a word within it), a beat count from that line
  (`+N beats`), or a section boundary. Raw seconds are only for instrumental passages.
- **Fields:** `effect` (from the library below), `intensity`, `duration_beats`, and `scope`
  (background, ink, strip, whole frame).
- **Dry run:** checked like keyframes. An effect must not hurt the legibility of a line it
  overlaps, must fit the TV's frame-time budget, and must not stack too many effects at once.

## 2. Effect library (procedural, all cheap at 480 lines)

Each is a small shader stage with a 0–1 envelope driven by the score, the beat and the audio:

- **Paper:** crease snap (one fold flips on the beat), crumple and unfold, tear along a crease,
  fold-in (a strip folds over to cover and reveal), paper grain or deckle edges, shadow sweep.
- **Light:** light sweep across the folds, flash on a hit, slow sunrise or dimming, colour wash
  from one edge.
- **Ink:** a line bleeds and spreads, splits along its crease, a word swells on the beat, scatter
  into fragments as the line exits, stamp (a word lands hard).
- **Motion accents:** beat pulse in fold depth, camera shake (one bar, gentle), slow dolly between
  keyframes, a whip-pan cut for a drop.
- **Palette:** invert, duotone, posterise, the palette cycling through its colours over a bar.
- **Frame:** letterbox in and out (a cinematic bridge), vignette swell, film-grain or VHS-tracking
  texture (subtle, since composite already adds noise), split screen for call-and-response lines.

## 3. More styles per album

- New backgrounds alongside paper, googie and custom: cut-paper collage (layered shapes with
  shadows), risograph (two inks misregistered), Bauhaus geometry, ink-wash, mosaic tiles, neon.
- Style parameters Claude can set per album: grain, edge softness, shadow depth, ink texture, type
  pairing (title vs lyric), and caption style.
- Per-section style changes in the score (for example, a chorus switches to duotone).

## 4. Making it robust

- One declarative `Effect` protocol: parameters with ranges, envelope, cost estimate, and what it
  may touch. The schema Claude sees is generated from it, so the prompt, the validator and the
  renderer can never disagree.
- An effect budget per frame (estimated GPU milliseconds) enforced by the dry run and at runtime.
  Over budget, the lowest-priority effect drops.
- A legibility check: render the frame offscreen at each lyric line's start and measure text
  contrast against its background; reject effects that push it below a threshold.
- A preview CLI: `needledrop-replay still --lrc --score` already renders scored frames. Add
  `--effects-only` contact sheets and a short GIF or MP4 export for review.
- Royalty-free demo songs (`.lrc` plus generated audio) as fixtures for each effect.

## 5. Order of work

1. The `Effect` protocol, envelope plumbing, budget and schema generation.
2. The first 8 effects (crease snap, light sweep, flash, ink bleed, word swell, letterbox,
   duotone, camera shake), with tests and previews.
3. Score `effects` with anchors, dry-run checks and a prompt update.
4. Two new backgrounds (cut-paper collage, risograph) and per-section style changes.
5. The rest of the library, guided by what reads best on the TV.
