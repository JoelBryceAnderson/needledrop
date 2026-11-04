/// Built-in scene shaders, compiled at runtime with `makeLibrary(source:)` — the same path
/// Claude-generated shaders will take in the art-director milestone.
///
/// Everything here is low-frequency on purpose: soft gradients, big shapes, no fine
/// texture. It renders at 480 lines and has to survive composite video on a big TV.
enum Shaders {
    /// The scene source with Claude's body in the custom slot (nil: the default body).
    static func source(customBody: String?) -> String {
        guard let customBody,
              let begin = source.range(of: "// CUSTOM-BODY\n"),
              let end = source.range(of: "// CUSTOM-BODY-END") else { return source }
        return source.replacingCharacters(in: begin.upperBound..<end.lowerBound, with: customBody + "\n")
    }

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // Must match `SceneUniforms` in Swift (all float4s, so layout is unambiguous).
    struct Uniforms {
        float4 frame;   // resolution.x, resolution.y, flow (integrated time), brightness
        float4 audio;   // bass, mids, highs, level
        float4 rhythm;  // beat, unused, mix (0 = previous slot, 1 = current), coverAmount
        float4 slots;   // hasArt0, hasArt1, hasMask0, hasMask1
        float4 style;   // background (0 paper, 1 smoke, 2 googie, 3 custom, 4 collage, 5 risograph), cover centre x (uv), cover size (frame heights), ink tone on flat backgrounds (1 dark, 2 light)
        // Two lyric lines printed on the scene. a: centre.xy, half size.xy (height units, x
        // across aspect); b: angle, opacity, blur (mip level), tone (1 dark, 2 light; 0 = choose).
        float4 ink0a;
        float4 ink0b;
        float4 ink1a;
        float4 ink1b;
        float4 ink2a;   // the now-playing caption, printed the same way
        float4 ink2b;
        float4 inkWords; // typewriter: words in slot 0, words shown in slot 0, same for slot 1
        float4 crease[4]; // normal.xy, offset (dot(q, normal) > offset = past it), active
        float4 fold;    // tilt (radians), accent strip, palette swap 0…1, palette mute 0…1
        float4 cover;   // mode (0 living, 1 dissolve, 2 record), dissolve amount, record angle, side progress
        float4 scene;   // wind-down (0…1), cover centre y (uv), cover rotation (radians), cover visibility
        float4 light;   // xyz
        float4 palette0[6];
        float4 palette1[6];
        // The camera over the background: rows of a homography from the screen (scene units,
        // centred) to the background plane (scene units). Perspective tilts live here.
        float4 camera[3];
        float4 strip;   // the now-playing strip's backing: min.xy, max.xy (screen, scene units); 0 = none
        // Timed effects from the track's score, 0…1 each (see Effects.swift).
        float4 effects0;     // crease snap, light sweep, flash, (ink bleed: applied to the ink on the CPU)
        float4 effects1;     // (word swell: CPU), letterbox, duotone, (shake: CPU)
        float4 effectsPhase; // light sweep progress 0…1, unused…
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // --- Noise ---------------------------------------------------------------

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) {
            v += a * vnoise(p);
            p = p * 2.03 + 17.1;
            a *= 0.5;
        }
        return v;
    }

    // Palettes arrive sorted dark → light; sweep up and back down so neighbouring
    // values are always similar colours (no hard seams, no wrap from light to dark).
    float3 paletteAt(constant float4 *pal, float t) {
        float x = 1.0 - abs(1.0 - 2.0 * fract(t * 0.5));  // 0 → 1 → 0
        x *= 5.0;
        int i = min(int(x), 4);
        float f = smoothstep(0.0, 1.0, x - float(i));
        return mix(pal[i].rgb, pal[i + 1].rgb, f);
    }

    // --- Palette bleed: lava-lamp domain-warped flow in the album's colours ---

    float3 paletteBleed(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float aspect = u.frame.x / u.frame.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0) * 1.5;
        float t = u.frame.z;
        float2 q = float2(fbm(p + t), fbm(p + float2(5.2, 1.3) - t));
        float warp = 1.3 + 1.6 * u.audio.x;
        float2 r = float2(fbm(p + warp * q + float2(1.7, 9.2) + 0.15 * t),
                          fbm(p + warp * q + float2(8.3, 2.8) - 0.12 * t));
        float v = fbm(p + warp * r);
        float3 c = paletteAt(pal, v * 1.6 + 0.07 * t);
        float glow = 0.5 + 0.7 * smoothstep(0.35, 0.85, v);
        c *= glow + 0.25 * u.audio.x + 0.12 * u.rhythm.x;
        // Mids lift saturation a touch; highs add a slow sheen (no fine detail).
        float grey = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(grey), c, 1.1 + 0.3 * u.audio.y);
        c += 0.06 * u.audio.z * smoothstep(0.55, 0.9, fbm(p * 0.7 - t * 0.5));
        return max(c, 0.0);
    }

    float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }

    // --- The camera --------------------------------------------------------------

    /// Screen uv → background uv, through the choreographer's camera.
    float2 toWorld(float2 uv, constant Uniforms &u) {
        float aspect = u.frame.x / u.frame.y;
        float3 q = float3(uv.x * aspect - aspect * 0.5, uv.y - 0.5, 1.0);
        float3 h = float3(dot(u.camera[0].xyz, q), dot(u.camera[1].xyz, q), dot(u.camera[2].xyz, q));
        float2 w = h.xy / max(h.z, 1e-3);
        return float2(w.x / aspect, w.y);
    }

    /// How far the plane recedes at this pixel (1 = at rest): the far side of a tilted sheet
    /// sits a little in shadow, which is most of what sells the depth.
    float cameraDepth(float2 uv, constant Uniforms &u) {
        float aspect = u.frame.x / u.frame.y;
        float3 q = float3(uv.x * aspect - aspect * 0.5, uv.y - 0.5, 1.0);
        return max(dot(u.camera[2].xyz, q), 1e-3);
    }

    // --- Lyrics as ink on the paper ---------------------------------------------

    /// `words` > 0: only the first `shown` words print (the word index is in red).
    float inkLine(float2 q, float4 a, float4 b, texture2d<float> tex, sampler s, float words, float shown) {
        if (b.y < 0.001) return 0.0;
        float2 d = q - a.xy;
        float c = cos(-b.x), sn = sin(-b.x);
        float2 local = float2(c * d.x - sn * d.y, sn * d.x + c * d.y);
        float2 t = local / (2.0 * a.zw) + 0.5;
        float4 texel = tex.sample(s, t, level(b.z));
        float visible = 1.0;
        if (words > 0.5) {
            float index = texel.r / max(texel.a, 0.001) * words - 0.5;
            visible = clamp(shown - index, 0.0, 1.0);
        }
        return texel.a * visible * b.y;
    }

    /// Ink coverage at scene uv: both lyric slots (one can soak out as the next soaks in)
    /// and the caption.
    /// Lyrics are printed on the background (`wuv`, so the camera moves over them); the
    /// caption is a title card and stays put on screen (`suv`).
    float inkAt(float2 wuv, float2 suv, constant Uniforms &u, texture2d<float> ink0, texture2d<float> ink1,
                texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float2 q = float2(wuv.x * aspect, wuv.y);
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s, u.inkWords.x, u.inkWords.y);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s, u.inkWords.z, u.inkWords.w);
        float a2 = inkLine(float2(suv.x * aspect, suv.y), u.ink2a, u.ink2b, ink2, s, 0.0, 0.0);
        return 1.0 - (1.0 - a0) * (1.0 - a1) * (1.0 - a2);
    }

    /// The centre (uv) of whichever line has the most ink at `uv`, so a line can take one
    /// ink colour throughout instead of flipping where it crosses light and dark shapes.
    /// The tone of whichever line has the most ink at this pixel.
    float dominantTone(float2 wuv, float2 suv, constant Uniforms &u, texture2d<float> ink0, texture2d<float> ink1,
                       texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float2 q = float2(wuv.x * aspect, wuv.y);
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s, u.inkWords.x, u.inkWords.y);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s, u.inkWords.z, u.inkWords.w);
        float a2 = inkLine(float2(suv.x * aspect, suv.y), u.ink2a, u.ink2b, ink2, s, 0.0, 0.0);
        return a0 >= a1 && a0 >= a2 ? u.ink0b.w : (a1 >= a2 ? u.ink1b.w : u.ink2b.w);
    }

    /// A blurred copy of the lyric lines in the colour opposite their ink (not the strip's
    /// words, which have their backing).
    float4 inkHalo(float2 wuv, float2 suv, constant Uniforms &u, constant float4 *pal, texture2d<float> ink0,
                   texture2d<float> ink1, texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float2 q = float2(wuv.x * aspect, wuv.y);
        float4 b0 = u.ink0b, b1 = u.ink1b;
        b0.z += 2.5;
        b1.z += 2.5;
        float h0 = min(1.0, inkLine(q, u.ink0a, b0, ink0, s, 0.0, 0.0) * 2.2);
        float h1 = min(1.0, inkLine(q, u.ink1a, b1, ink1, s, 0.0, 0.0) * 2.2);
        float tone = h0 >= h1 ? u.ink0b.w : u.ink1b.w;
        // Dark words get a light halo; light words a dark one.
        float3 colour = tone < 1.5 ? mix(pal[5].rgb, float3(1.0), 0.6) : pal[0].rgb * 0.6;
        return float4(colour, max(h0, h1));
    }

    /// In background uv, like `toWorld`.
    float2 inkCentre(float2 wuv, float2 suv, constant Uniforms &u, texture2d<float> ink0, texture2d<float> ink1,
                     texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float2 q = float2(wuv.x * aspect, wuv.y);
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s, u.inkWords.x, u.inkWords.y);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s, u.inkWords.z, u.inkWords.w);
        float a2 = inkLine(float2(suv.x * aspect, suv.y), u.ink2a, u.ink2b, ink2, s, 0.0, 0.0);
        if (a2 > a0 && a2 > a1) return toWorld(float2(u.ink2a.x / aspect, u.ink2a.y), u);
        float2 c = a0 >= a1 ? u.ink0a.xy : u.ink1a.xy;
        return float2(c.x / aspect, c.y);
    }

    /// Printed in the palette's darkest or lightest colour, whichever stands out from the paper.
    float3 inkColor(float3 paper, constant float4 *pal) {
        float lum = dot(paper, float3(0.2126, 0.7152, 0.0722));
        return lum > 0.4 ? pal[0].rgb * 0.85 : mix(pal[5].rgb, float3(1.0), 0.45);
    }

    /// A soft dark band behind the now-playing strip, so the small words read on any paper.
    float3 stripBacking(float3 c, float2 suv, constant Uniforms &u) {
        if (u.strip.z <= u.strip.x) return c;
        float2 p = float2(suv.x * u.frame.x / u.frame.y, suv.y);
        float2 centre = (u.strip.xy + u.strip.zw) * 0.5, extent = (u.strip.zw - u.strip.xy) * 0.5;
        float2 d = abs(p - centre) - (extent - 0.02);
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - 0.02;
        return c * (1.0 - 0.6 * (1.0 - smoothstep(-0.006, 0.012, dist)));
    }

    /// A line's ink: its tone was chosen once, when it was placed (1 dark, 2 light), so it
    /// never flickers as the paper's light moves; 0 falls back to choosing against `paper`.
    float3 toneColor(float tone, float3 paper, constant float4 *pal) {
        if (tone < 0.5) return inkColor(paper, pal);
        return tone < 1.5 ? pal[0].rgb * 0.85 : mix(pal[5].rgb, float3(1.0), 0.45);
    }

    // --- Paper: a sheet folded along a few long creases (geometry from FoldLayout) ---

    /// Strip index at q: how many creases q is past. Strips alternate mountain / valley.
    int stripAt(float2 q, constant Uniforms &u) {
        int k = 0;
        for (int i = 0; i < 4; i++) {
            float4 c = u.crease[i];
            if (c.w > 0.5 && dot(q, c.xy) > c.z) k++;
        }
        return k;
    }

    /// The sheet's colour at q (scene units), lit by its folds.
    float3 sheetAt(float2 q, constant Uniforms &u, constant float4 *pal) {
        // Crease snap: the folds flip over, mountains becoming valleys, and back.
        float tilt = u.fold.x * (1.0 - 2.0 * u.effects0.x);
        float3 sheet = max(pal[3].rgb, float3(0.12));
        float3 accent = max(pal[4].rgb, float3(0.12));
        // The score's palette moves: swap the two (fold.z), drain the colour (fold.w).
        float3 swapped = mix(sheet, accent, u.fold.z);
        accent = mix(accent, sheet, u.fold.z);
        sheet = swapped;
        float3 greyS = float3(dot(sheet, float3(0.2126, 0.7152, 0.0722)));
        float3 greyA = float3(dot(accent, float3(0.2126, 0.7152, 0.0722)));
        sheet = mix(sheet, greyS, u.fold.w * 0.75);
        accent = mix(accent, greyA, u.fold.w * 0.75);
        float2 m = u.crease[0].xy;  // the creases run (nearly) parallel
        int k = stripAt(q, u);
        float sgn = (k & 1) == 0 ? 1.0 : -1.0;
        float3 n = normalize(float3(m * sin(tilt) * sgn, cos(tilt)));
        float lit = 0.38 + 0.85 * max(0.0, dot(n, u.light.xyz));
        // Light sweep: a soft band of light crossing the folds.
        if (u.effects0.y > 0.001) {
            float aspect = u.frame.x / u.frame.y;
            float a = dot(float2(0.0), m), b = dot(float2(aspect, 0.0), m), c = dot(float2(0.0, 1.0), m), d = dot(float2(aspect, 1.0), m);
            float lo = min(min(a, b), min(c, d)) - 0.3, hi = max(max(a, b), max(c, d)) + 0.3;
            float along = dot(q, m) - mix(lo, hi, u.effectsPhase.x);
            lit += 0.5 * u.effects0.y * exp(-along * along / 0.03);
        }
        // One sheet colour, with the album's second colour on one strip for an accent.
        return (k == int(u.fold.y) ? accent : sheet) * lit;
    }

    /// Letterbox: black bars closing in from top and bottom, under the ink and the strip.
    float3 letterbox(float3 c, float2 suv, constant Uniforms &u) {
        float h = 0.13 * u.effects1.y;
        if (h < 0.001) return c;
        float px = 1.5 / u.frame.y;
        float bar = max(1.0 - smoothstep(h - px, h + px, suv.y), smoothstep(1.0 - h - px, 1.0 - h + px, suv.y));
        return mix(c, float3(0.015), bar);
    }

    /// xyz: the ink colour, w: coverage. Each line takes one colour, chosen against the paper
    /// at its centre, so it doesn't flip where it crosses light and dark strips.
    float4 inkOn(float2 q, float2 suv, constant Uniforms &u, constant float4 *pal,
                 texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s, u.inkWords.x, u.inkWords.y);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s, u.inkWords.z, u.inkWords.w);
        float a2 = inkLine(float2(suv.x * aspect, suv.y), u.ink2a, u.ink2b, ink2, s, 0.0, 0.0);
        float a = 1.0 - (1.0 - a0) * (1.0 - a1) * (1.0 - a2);
        if (a < 0.001) return float4(0.0);
        float3 under;
        float tone;
        if (a0 >= a1 && a0 >= a2) {
            under = sheetAt(u.ink0a.xy, u, pal);
            tone = u.ink0b.w;
        } else if (a1 >= a2) {
            under = sheetAt(u.ink1a.xy, u, pal);
            tone = u.ink1b.w;
        } else {
            float2 w = toWorld(float2(u.ink2a.x / aspect, u.ink2a.y), u);
            under = sheetAt(float2(w.x * aspect, w.y), u, pal);
            tone = u.ink2b.w;
        }
        return float4(toneColor(tone, under, pal), a);
    }

    float3 paperSample(float2 suv, constant Uniforms &u, constant float4 *pal,
                       texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        float aspect = u.frame.x / u.frame.y;
        float2 wuv = toWorld(suv, u);
        float2 q = float2(wuv.x * aspect, wuv.y);
        float3 c = stripBacking(letterbox(sheetAt(q, u, pal), suv, u), suv, u);
        float4 ink = inkOn(q, suv, u, pal, ink0, ink1, ink2);
        return mix(c, ink.rgb, ink.a * 0.92);
    }

    float3 paper(float2 uv, constant Uniforms &u, constant float4 *pal,
                 texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        // 4× supersampling: clean creases and letters at 480 lines.
        const float2 offsets[4] = { float2(-0.25, -0.25), float2(0.25, -0.25), float2(-0.25, 0.25), float2(0.25, 0.25) };
        float3 sum = float3(0.0);
        for (int s = 0; s < 4; s++) {
            sum += paperSample(uv + offsets[s] / u.frame.xy, u, pal, ink0, ink1, ink2);
        }
        return sum * 0.25;
    }

    // --- Googie: mid-century atomic-age shapes in flat colour ---------------------

    float modPositive(float x, float y) { return x - y * floor(x / y); }

    /// n-pointed star, outer radius r, sharpness m in [2, n].
    float sdStar(float2 p, float r, int n, float m) {
        float an = 3.141593 / float(n);
        float en = 3.141593 / m;
        float2 acs = float2(cos(an), sin(an));
        float2 ecs = float2(cos(en), sin(en));
        float bn = modPositive(atan2(p.x, p.y), 2.0 * an) - an;
        p = length(p) * float2(cos(bn), abs(sin(bn)));
        p -= r * acs;
        p += ecs * clamp(-dot(p, ecs), 0.0, r * acs.y / ecs.y);
        return length(p) * sign(p.x);
    }

    float smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    float3 googie(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float aspect = u.frame.x / u.frame.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float t = u.frame.z;
        float px = 1.5 / u.frame.y;
        float bass = u.audio.x, beat = u.rhythm.x;
        // Cream ground, warmed by the album's lightest colour.
        float3 col = mix(float3(0.95, 0.91, 0.82), pal[5].rgb, 0.25);
        // Kidney shapes drifting slowly behind everything.
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float2 c = float2(sin(t * 0.07 + fi * 2.1) * aspect * 0.35, cos(t * 0.05 + fi * 1.7) * 0.28);
            float2 q = rot2(p - c, t * 0.03 + fi);
            float d = smin(length(q - float2(-0.09, 0.0)) - 0.15, length(q - float2(0.1, 0.03)) - 0.12, 0.08);
            d = max(d, -(length(q - float2(0.01, 0.13)) - 0.07));
            col = mix(col, pal[2 + i % 2].rgb, 1.0 - smoothstep(-px, px, d));
        }
        // Boomerangs (crescents), wheeling.
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float2 c = float2(sin(t * 0.11 + fi * 1.3 + 0.5) * aspect * 0.42, sin(t * 0.09 + fi * 2.4) * 0.36);
            float2 q = rot2(p - c, t * (0.15 + 0.05 * fi) + fi * 1.57);
            float r = 0.075 + 0.02 * fi;
            float d = max(length(q) - r, -(length(q - float2(0.035, 0.03)) - r * 0.92));
            col = mix(col, pal[1].rgb, 1.0 - smoothstep(-px, px, d));
        }
        // Starbursts: swell with bass, flash on the beat.
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float2 c = (float2(hash21(float2(fi, 3.1)), hash21(float2(fi, 7.7))) - 0.5) * float2(aspect * 0.9, 0.85);
            c += 0.03 * float2(sin(t * 0.2 + fi), cos(t * 0.17 + fi));
            float size = (0.035 + 0.03 * hash21(float2(fi, 1.9))) * (1.0 + 0.35 * bass + 0.25 * beat);
            float d = sdStar(rot2(p - c, t * 0.2 * (fi - 2.0)), size, 8, 3.0);
            float3 star = (i % 2 == 0) ? pal[4].rgb : pal[0].rgb;
            col = mix(col, star, 1.0 - smoothstep(-px, px, d));
        }
        // An atom: three orbit rings round a nucleus (lines kept thick enough for 480i).
        float2 nucleus = float2(aspect * 0.36, -0.3) + 0.02 * float2(sin(t * 0.3), cos(t * 0.27));
        for (int k = 0; k < 3; k++) {
            float2 q = rot2(p - nucleus, float(k) * 1.047 + t * 0.1);
            float d = abs(length(q * float2(1.0, 2.6)) - 0.11) / 2.0 - 0.004;
            col = mix(col, pal[0].rgb, 1.0 - smoothstep(-px, px, d));
        }
        float dn = length(p - nucleus) - 0.02 * (1.0 + 0.5 * beat);
        return mix(col, pal[3].rgb, 1.0 - smoothstep(-px, px, dn));
    }

    // --- Custom: Claude's fragment body goes between the CUSTOM-BODY markers ----------

    float3 customScene(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float2 resolution = u.frame.xy;
        float aspect = resolution.x / resolution.y;
        float time = u.frame.z;
        float bass = u.audio.x, mids = u.audio.y, highs = u.audio.z, level = u.audio.w;
        float beat = u.rhythm.x;
        {
    // CUSTOM-BODY
            return paletteBleed(uv, u, pal) + 0.0 * (aspect + time + bass + mids + highs + level + beat + resolution.x);
    // CUSTOM-BODY-END
        }
    }

    // --- Living cover: artwork with the subject floating off its background ---

    struct Cover {
        float3 color;
        float inside;
        float shadow;
    };

    Cover livingCover(float2 uv, constant Uniforms &u, texture2d<float> art, texture2d<float> mask,
                      float hasMask, sampler s) {
        float aspect = u.frame.x / u.frame.y;
        // Wherever the choreographer has put it, turned a little.
        float2 p = rot2((uv - float2(u.style.y, u.scene.y)) * float2(aspect, 1.0), -u.scene.z);
        float size = u.style.z * (1.0 + 0.005 * u.rhythm.x);
        float2 c = p / size + 0.5;

        float flow = u.frame.z;
        float2 drift = float2(sin(flow * 0.9), cos(flow * 0.7));
        float push = 0.01 + 0.015 * u.audio.x;
        float2 bgUV = (c - 0.5) * 0.95 + 0.5 - drift * 0.006;
        float2 fgUV = (c - 0.5) / (1.0 + push) + 0.5 + drift * 0.012;

        float3 bg = art.sample(s, bgUV).rgb;
        float3 fg = art.sample(s, fgUV).rgb;
        float m = hasMask > 0.5 ? mask.sample(s, fgUV).r : 0.0;
        // Background recedes (darker) as bass pushes the layers apart.
        float3 col = mix(bg * (1.0 - hasMask * (0.12 + 0.15 * u.audio.x)), fg, m);

        // Dissolve: the cover in triangular paper shards that fly out on transients. For each
        // nearby shard, undo its offset and see whether this pixel lands inside it.
        float shards = u.cover.y;
        if (u.cover.x > 0.5 && u.cover.x < 1.5 && shards > 0.001) {
            const float n = 7.0;
            float2 cell = floor(c * n);
            bool hit = false;
            float3 shardColor = float3(0.0);
            float2 shardUV = c;
            for (int j = -2; j <= 2 && !hit; j++) {
                for (int i = -2; i <= 2 && !hit; i++) {
                    float2 g = cell + float2(i, j);
                    if (any(g < 0.0) || any(g >= n)) continue;
                    for (int t = 0; t < 2 && !hit; t++) {
                        float2 h = float2(hash21(g * 1.7 + float(t) * 13.1), hash21(g * 2.3 + float(t) * 7.9));
                        float2 offset = (normalize(h - 0.5 + 0.001) + (g + 0.5) / n - 0.5) * shards * (0.08 + 0.14 * h.x);
                        float2 local = (c - offset) * n - g;   // shard's own cell coordinates
                        bool inShard = t == 0 ? (local.x >= 0.0 && local.y >= 0.0 && local.x + local.y <= 1.0)
                                              : (local.x <= 1.0 && local.y <= 1.0 && local.x + local.y >= 1.0);
                        if (inShard) {
                            hit = true;
                            shardUV = c - offset;
                            // Each shard catches the light a little differently, like folded paper.
                            shardColor = art.sample(s, shardUV).rgb * (1.0 + (h.y - 0.5) * 0.35 * shards);
                        }
                    }
                }
            }
            Cover o;
            o.color = shardColor;
            o.inside = hit ? 1.0 : 0.0;
            o.shadow = 0.0;
            return o;
        }

        // Virtual record: a flat LP spinning in the cover's place, the art as its label, and a
        // tonearm moving inwards across the side.
        if (u.cover.x > 1.5) {
            float2 q = c - 0.5;
            float r = length(q);
            float angle = u.cover.z;
            float3 vinyl = float3(0.055, 0.055, 0.065);
            // Wide groove bands (fine grooves would vanish at 480 lines).
            float bands = smoothstep(0.35, 0.65, 0.5 + 0.5 * sin(r * 70.0));
            vinyl += 0.025 * bands * step(0.2, r);
            vinyl += 0.05 * step(0.32, r) * step(r, 0.335);   // the gap between tracks
            // The sheen stays put while the disc turns, which is what reads as spinning.
            float a = atan2(q.y, q.x);
            vinyl += 0.12 * pow(abs(cos(a - 0.8)), 24.0) * smoothstep(0.2, 0.25, r);
            // The label: the cover, turning with the record.
            float2 lq = rot2(q, angle) / 0.34 + 0.5;
            float3 label = art.sample(s, lq).rgb;
            float3 col = r < 0.17 ? label : vinyl;
            col = mix(col, float3(0.02), 1.0 - smoothstep(0.009, 0.013, r));   // spindle hole
            // Tonearm: pivot top-right, stylus on the record at a radius set by side progress.
            float2 pivot = float2(0.47, -0.44);
            float armLength = 0.72;
            float sr = mix(0.46, 0.2, clamp(u.cover.w, 0.0, 1.0));
            float dpc = length(pivot);
            float along = (sr * sr - armLength * armLength + dpc * dpc) / (2.0 * dpc);
            float across = sqrt(max(sr * sr - along * along, 0.0));
            float2 axis = pivot / dpc;
            float2 stylus = axis * along + float2(-axis.y, axis.x) * across;
            float2 pa = q - pivot, ba = stylus - pivot;
            float hseg = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float arm = length(pa - ba * hseg) - 0.012;
            float head = length(q - stylus) - 0.028;
            float weight = length(q - pivot) - 0.045;
            float3 metal = mix(float3(0.82), u.palette0[5].rgb, 0.3);
            float tonearm = min(min(arm, head), weight);
            col = mix(col, metal, 1.0 - smoothstep(0.0, 0.006, tonearm));
            Cover o;
            o.color = col;
            o.inside = max(1.0 - smoothstep(0.495, 0.5, r), 1.0 - smoothstep(0.0, 0.006, tonearm));
            o.shadow = (1.0 - smoothstep(0.49, 0.56, length(c - float2(0.515, 0.53)))) * 0.55;
            return o;
        }

        // Rounded square with a soft shadow, in cover units.
        float2 d = abs(c - 0.5) - (0.5 - 0.035);
        float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - 0.035;
        // A card lying on the paper: short shadow, offset away from the light.
        float2 ds = abs(c - float2(0.515, 0.53)) - (0.5 - 0.035);
        float shadowDist = length(max(ds, 0.0)) + min(max(ds.x, ds.y), 0.0) - 0.035;
        Cover o;
        o.color = col;
        o.inside = 1.0 - smoothstep(0.0, 0.008, dist);
        o.shadow = (1.0 - smoothstep(-0.01, 0.05, shadowDist)) * 0.55;
        return o;
    }

    // --- Cut-paper collage: big torn shapes in the album's colours, layered with shadows ---

    float sdBox(float2 p, float2 b) {
        float2 d = abs(p) - b;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }

    float3 collage(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float aspect = u.frame.x / u.frame.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float t = u.frame.z;
        float px = 1.5 / u.frame.y;
        // A cream ground with a little tooth.
        float3 col = mix(float3(0.93, 0.9, 0.84), pal[5].rgb, 0.3) * (0.97 + 0.03 * vnoise(p * 90.0));
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float2 h = float2(hash21(float2(fi, 1.3)), hash21(float2(fi, 8.1)));
            float2 c = (h - 0.5) * float2(aspect * 0.9, 0.8) + 0.03 * float2(sin(t * 0.06 + fi), cos(t * 0.05 + fi * 1.7));
            c += 0.006 * u.rhythm.x * float2(cos(fi), sin(fi));  // a nudge on the beat
            float a = (hash21(float2(fi, 4.4)) - 0.5) * 1.2 + 0.02 * sin(t * 0.04 + fi);
            float2 size = float2(0.16 + 0.22 * hash21(float2(fi, 2.2)), 0.1 + 0.16 * hash21(float2(fi, 6.6)));
            float2 q = rot2(p - c, a);
            // Torn edges: the outline wanders a little, finer along the tear.
            float tear = (vnoise(q * 18.0 + fi * 7.0) - 0.5) * 0.018 + (vnoise(q * 60.0 + fi) - 0.5) * 0.005;
            float d = sdBox(q, size) + tear;
            // The shadow first (offset away from the light), then the piece.
            float ds = sdBox(rot2(p - c - float2(0.012, 0.018), a), size) + tear;
            col *= 1.0 - 0.28 * (1.0 - smoothstep(-0.005, 0.03, ds));
            float3 piece = pal[(i % 5)].rgb * (0.96 + 0.04 * vnoise(q * 70.0));
            col = mix(col, piece, 1.0 - smoothstep(-px, px, d));
        }
        return col;
    }

    // --- Risograph: two inks printed slightly out of register, with a coarse grain ---

    float3 risograph(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float aspect = u.frame.x / u.frame.y;
        float2 p = (uv - 0.5) * float2(aspect, 1.0);
        float t = u.frame.z;
        float px = 1.5 / u.frame.y;
        // Two plates: big soft forms, each its own drum.
        float2 shift = float2(0.008 + 0.006 * u.audio.x, -0.005);  // misregistration, breathing with the bass
        float a = smoothstep(0.48, 0.52 + px, fbm(p * 1.4 + float2(t * 0.05, 0.0)));
        float b = 1.0 - smoothstep(0.3 - px, 0.3 + px, length(p - shift - float2(0.25 * sin(t * 0.07), 0.1 * cos(t * 0.05))));
        b = max(b, smoothstep(0.55, 0.57, fbm((p - shift) * 2.1 - float2(0.0, t * 0.04))));
        // Halftone-ish grain: ink coverage thins in a coarse random pattern (dots of ~4 px at 480 lines).
        float grain = hash21(floor(uv * u.frame.xy / 3.0));
        a *= 0.82 + 0.18 * step(0.25, grain);
        b *= 0.82 + 0.18 * step(0.3, fract(grain * 7.13));
        float3 paperTone = mix(float3(0.95, 0.93, 0.88), pal[5].rgb, 0.15);
        float3 inkA = pal[1].rgb, inkB = pal[4].rgb;
        // Inks multiply, as they do on the page.
        float3 col = paperTone * mix(float3(1.0), inkA, a * 0.9);
        return col * mix(float3(1.0), inkB, b * 0.85);
    }

    float3 flatBackground(int background, float2 uv, constant Uniforms &u, constant float4 *pal) {
        return background == 1 ? paletteBleed(uv, u, pal)
             : background == 2 ? googie(uv, u, pal)
             : background == 4 ? collage(uv, u, pal)
             : background == 5 ? risograph(uv, u, pal)
             : customScene(uv, u, pal);
    }

    float3 slotColor(float2 uv, constant Uniforms &u, constant float4 *pal,
                     texture2d<float> art, texture2d<float> mask, float hasArt, float hasMask, sampler s,
                     texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        float3 base;
        int background = int(u.style.x + 0.5);
        if (background == 0) {
            base = paper(uv, u, pal, ink0, ink1, ink2);
        } else {
            float2 wuv = toWorld(uv, u);
            base = stripBacking(letterbox(flatBackground(background, wuv, u, pal), uv, u), uv, u);
            // Busy grounds: a soft halo in the opposite tone keeps every line readable over
            // whatever it crosses. Each line (and the strip) keeps its own tone.
            float4 halo = inkHalo(wuv, uv, u, pal, ink0, ink1, ink2);
            base = mix(base, halo.rgb, halo.a * 0.55);
            float ink = inkAt(wuv, uv, u, ink0, ink1, ink2);
            if (ink > 0.001) {
                float3 under = flatBackground(background, inkCentre(wuv, uv, u, ink0, ink1, ink2), u, pal);
                base = mix(base, toneColor(dominantTone(wuv, uv, u, ink0, ink1, ink2), under, pal), ink * 0.92);
            }
        }
        // The receding side of a tilted plane falls into shadow; the near side lifts a touch.
        base *= clamp(1.0 - (1.0 - cameraDepth(uv, u)) * 0.9, 0.7, 1.12);
        float amount = u.rhythm.w * hasArt * u.scene.w;
        if (amount > 0.001) {
            Cover cv = livingCover(uv, u, art, mask, hasMask, s);
            base *= 1.0 - cv.shadow * (1.0 - cv.inside) * amount;
            base = mix(base, cv.color, cv.inside * amount);
        }
        return base;
    }

    fragment float4 scene_fragment(VOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> art0 [[texture(0)]],
                                   texture2d<float> mask0 [[texture(1)]],
                                   texture2d<float> art1 [[texture(2)]],
                                   texture2d<float> mask1 [[texture(3)]],
                                   texture2d<float> ink0 [[texture(4)]],
                                   texture2d<float> ink1 [[texture(5)]],
                                   texture2d<float> ink2 [[texture(6)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float3 col = slotColor(in.uv, u, u.palette0, art0, mask0, u.slots.x, u.slots.z, s, ink0, ink1, ink2);
        if (u.rhythm.z < 0.999) {
            float3 prev = slotColor(in.uv, u, u.palette1, art1, mask1, u.slots.y, u.slots.w, s, ink0, ink1, ink2);
            col = mix(prev, col, u.rhythm.z);
        }
        // Duotone: everything down to the palette's darkest and lightest colours.
        if (u.effects1.z > 0.001) {
            float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
            float3 two = mix(u.palette0[0].rgb * 0.9, mix(u.palette0[5].rgb, float3(1.0), 0.2), smoothstep(0.12, 0.6, lum));
            col = mix(col, two, u.effects1.z);
        }
        // Flash: the frame floods with light and fades.
        col = mix(col, mix(u.palette0[5].rgb, float3(1.0), 0.6), u.effects0.z * 0.75);
        float2 v = in.uv - 0.5;
        col *= 1.0 - dot(v, v) * 0.7;
        // Side over: the picture settles, losing some colour and light as it stops.
        float wind = u.scene.x;
        float grey = dot(col, float3(0.2126, 0.7152, 0.0722));
        col = mix(col, float3(grey), wind * 0.55) * (1.0 - 0.25 * wind);
        col *= u.frame.w;
        return float4(col, 1.0);
    }

    // The custom background alone, for ShaderValidator (no cover, ink or vignette).
    fragment float4 custom_probe_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        return float4(customScene(in.uv, u, u.palette0), 1.0);
    }

    // Upscale the low-res scene to the drawable. Bilinear is already soft at 480 lines,
    // which is what we want for composite.
    fragment float4 present_fragment(VOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(scene.sample(s, in.uv).rgb, 1.0);
    }
    """#
}
