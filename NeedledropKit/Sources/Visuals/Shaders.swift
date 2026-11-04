/// Built-in scene shaders, compiled at runtime with `makeLibrary(source:)` — the same path
/// Claude-generated shaders will take in the art-director milestone.
///
/// Everything here is low-frequency on purpose: soft gradients, big shapes, no fine
/// texture. It renders at 480 lines and has to survive composite video on a big TV.
enum Shaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // Must match `SceneUniforms` in Swift (all float4s, so layout is unambiguous).
    struct Uniforms {
        float4 frame;   // resolution.x, resolution.y, flow (integrated time), brightness
        float4 audio;   // bass, mids, highs, level
        float4 rhythm;  // beat, unused, mix (0 = previous slot, 1 = current), coverAmount
        float4 slots;   // hasArt0, hasArt1, hasMask0, hasMask1
        float4 style;   // background (0 = paper, 1 = smoke), cover centre x (uv), cover size (frame heights), unused
        // Two lyric lines printed on the scene. a: centre.xy, half size.xy (height units, x
        // across aspect); b: angle, opacity, blur (mip level), unused.
        float4 ink0a;
        float4 ink0b;
        float4 ink1a;
        float4 ink1b;
        float4 ink2a;   // the now-playing caption, printed the same way
        float4 ink2b;
        float4 crease[3]; // normal.xy, offset (dot(q, normal) > offset = past it), active
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

    /// Printed in the palette's darkest or lightest colour, whichever stands out from the paper.
    float3 inkColor(float3 paper, constant float4 *pal) {
        float lum = dot(paper, float3(0.2126, 0.7152, 0.0722));
        return lum > 0.4 ? pal[0].rgb * 0.85 : mix(pal[5].rgb, float3(1.0), 0.45);
    }

    // --- Paper: a sheet folded along a few long creases (geometry from FoldLayout) ---

    /// Strip index at q: how many creases q is past. Strips alternate mountain / valley.
    int stripAt(float2 q, constant Uniforms &u) {
        int k = 0;
        for (int i = 0; i < 3; i++) {
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
            float2 m = u.crease[min(k, 2)].xy;
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

    float3 slotColor(float2 uv, constant Uniforms &u, constant float4 *pal,
                     texture2d<float> art, texture2d<float> mask, float hasArt, float hasMask, sampler s,
                     texture2d<float> ink0, texture2d<float> ink1, texture2d<float> ink2) {
        float3 base;
        if (u.style.x < 0.5) {
            base = paper(uv, u, pal, ink0, ink1, ink2);
        } else {
            base = paletteBleed(uv, u, pal);
            base = mix(base, inkColor(base, pal), inkAt(uv, u, ink0, ink1, ink2) * 0.92);
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

    // Upscale the low-res scene to the drawable. Bilinear is already soft at 480 lines,
    // which is what we want for composite.
    fragment float4 present_fragment(VOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(scene.sample(s, in.uv).rgb, 1.0);
    }
    """#
}
