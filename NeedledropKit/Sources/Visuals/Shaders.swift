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
        float4 style;   // background (0 paper, 1 smoke, 2 googie, 3 custom), cover centre x (uv), cover size (frame heights), unused
        // Two lyric lines printed on the scene. a: centre.xy, half size.xy (height units, x
        // across aspect); b: angle, opacity, blur (mip level), unused.
        float4 ink0a;
        float4 ink0b;
        float4 ink1a;
        float4 ink1b;
        float4 ink2a;   // the now-playing caption, printed the same way
        float4 ink2b;
        float4 crease[4]; // normal.xy, offset (dot(q, normal) > offset = past it), active
        float4 fold;    // tilt (radians), accent strip, unused, unused
        float4 light;   // xyz
        float4 palette0[6];
        float4 palette1[6];
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

    // --- Lyrics as ink on the paper ---------------------------------------------

    float inkLine(float2 q, float4 a, float4 b, texture2d<float> tex, sampler s) {
        if (b.y < 0.001) return 0.0;
        float2 d = q - a.xy;
        float c = cos(-b.x), sn = sin(-b.x);
        float2 local = float2(c * d.x - sn * d.y, sn * d.x + c * d.y);
        float2 t = local / (2.0 * a.zw) + 0.5;
        return tex.sample(s, t, level(b.z)).a * b.y;
    }

    /// Ink coverage at scene uv: both lyric slots (one can soak out as the next soaks in)
    /// and the caption.
    float inkAt(float2 uv, constant Uniforms &u, texture2d<float> ink0, texture2d<float> ink1,
                texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 q = float2(uv.x * u.frame.x / u.frame.y, uv.y);
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s);
        float a2 = inkLine(q, u.ink2a, u.ink2b, ink2, s);
        return 1.0 - (1.0 - a0) * (1.0 - a1) * (1.0 - a2);
    }

    /// The centre (uv) of whichever line has the most ink at `uv`, so a line can take one
    /// ink colour throughout instead of flipping where it crosses light and dark shapes.
    float2 inkCentre(float2 uv, constant Uniforms &u, texture2d<float> ink0, texture2d<float> ink1,
                     texture2d<float> ink2) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float aspect = u.frame.x / u.frame.y;
        float2 q = float2(uv.x * aspect, uv.y);
        float a0 = inkLine(q, u.ink0a, u.ink0b, ink0, s);
        float a1 = inkLine(q, u.ink1a, u.ink1b, ink1, s);
        float a2 = inkLine(q, u.ink2a, u.ink2b, ink2, s);
        float2 c = a0 >= a1 && a0 >= a2 ? u.ink0a.xy : (a1 >= a2 ? u.ink1a.xy : u.ink2a.xy);
        return float2(c.x / aspect, c.y);
    }

    /// Printed in the palette's darkest or lightest colour, whichever stands out from the paper.
    float3 inkColor(float3 paper, constant float4 *pal) {
        float lum = dot(paper, float3(0.2126, 0.7152, 0.0722));
        return lum > 0.4 ? pal[0].rgb * 0.85 : mix(pal[5].rgb, float3(1.0), 0.45);
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

    float3 paper(float2 uv, constant Uniforms &u, constant float4 *pal,
                 texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        float aspect = u.frame.x / u.frame.y;
        float3 light = u.light.xyz;
        float tilt = u.fold.x;
        float3 sheet = max(pal[3].rgb, float3(0.12));
        float3 accent = max(pal[4].rgb, float3(0.12));
        // 4× supersampling: clean creases and letters at 480 lines.
        const float2 offsets[4] = { float2(-0.25, -0.25), float2(0.25, -0.25), float2(-0.25, 0.25), float2(0.25, 0.25) };
        float3 sum = float3(0.0);
        for (int s = 0; s < 4; s++) {
            float2 suv = uv + offsets[s] / u.frame.xy;
            float2 q = float2(suv.x * aspect, suv.y);
            int k = stripAt(q, u);
            float2 m = u.crease[0].xy;  // the creases run (nearly) parallel
            float sgn = (k % 2 == 0) ? 1.0 : -1.0;
            float3 n = normalize(float3(m * sin(tilt) * sgn, cos(tilt)));
            float lit = 0.38 + 0.85 * max(0.0, dot(n, light));
            // One sheet colour, with the album's second colour on one strip for an accent.
            float3 c = (k == int(u.fold.y) ? accent : sheet) * lit;
            // Ink is chosen against the lit paper, so it reads on bright and shadowed strips.
            float ink = inkAt(suv, u, ink0, ink1, ink2);
            c = mix(c, inkColor(c, pal), ink * 0.92);
            sum += c;
        }
        return sum * 0.25;
    }

    // --- Googie: mid-century atomic-age shapes in flat colour ---------------------

    float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }

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
        // Centred, or moved aside to leave a field for lyrics (animated by the renderer).
        float2 p = (uv - float2(u.style.y, 0.5)) * float2(aspect, 1.0);
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

    float3 flatBackground(int background, float2 uv, constant Uniforms &u, constant float4 *pal) {
        return background == 1 ? paletteBleed(uv, u, pal)
             : background == 2 ? googie(uv, u, pal)
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
            base = flatBackground(background, uv, u, pal);
            float ink = inkAt(uv, u, ink0, ink1, ink2);
            if (ink > 0.001) {
                // One ink colour per line, chosen against the background at its centre.
                float3 under = flatBackground(background, inkCentre(uv, u, ink0, ink1, ink2), u, pal);
                base = mix(base, inkColor(under, pal), ink * 0.92);
            }
        }
        float amount = u.rhythm.w * hasArt;
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
        float2 v = in.uv - 0.5;
        col *= 1.0 - dot(v, v) * 0.7;
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
