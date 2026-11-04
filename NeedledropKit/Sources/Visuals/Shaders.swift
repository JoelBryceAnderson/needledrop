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
        float4 rhythm;  // beat, lyricsPresence (cover makes room), mix (0 = previous slot, 1 = current), coverAmount
        float4 slots;   // hasArt0, hasArt1, hasMask0, hasMask1
        float4 style;   // background (0 = paper, 1 = smoke), unused…
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

    // --- Paper: one sheet folded into big flat planes, each lit by its own angle ---

    // Lattice vertex g: wanders slowly; z is fold height. Jitter + drift stay under 0.5,
    // so triangles never flip over each other.
    float3 paperVertex(int2 g, float flow, float bass) {
        float2 gf = float2(g);
        float2 h = float2(hash21(gf + 0.37), hash21(gf + 4.1));
        float2 drift = float2(sin(flow * 0.35 + h.x * 6.283), cos(flow * 0.29 + h.y * 6.283)) * 0.12;
        float2 xy = gf + (h - 0.5) * 0.55 + drift;
        // Alternate ridges and valleys like a folded sheet; the folds slowly open and
        // close across the paper, and bass deepens them a little.
        float ridge = ((g.x + g.y) & 1) == 0 ? 0.5 : -0.5;
        float fold = 0.55 + 0.45 * sin(flow * 0.18 + gf.x * 0.45 - gf.y * 0.3);
        float z = (ridge * 1.3 * fold + (vnoise(gf * 0.4 + flow * 0.06) - 0.5) * 0.5) * (1.0 + 0.35 * bass);
        return float3(xy, z);
    }

    float edgeSide(float2 p, float2 a, float2 b) {
        return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    }

    bool inTriangle(float2 p, float3 a, float3 b, float3 c) {
        float d1 = edgeSide(p, a.xy, b.xy), d2 = edgeSide(p, b.xy, c.xy), d3 = edgeSide(p, c.xy, a.xy);
        bool negative = d1 < 0.0 || d2 < 0.0 || d3 < 0.0;
        bool positive = d1 > 0.0 || d2 > 0.0 || d3 > 0.0;
        return !(negative && positive);
    }

    float3 paperFacet(float3 a, float3 b, float3 c, float3 light, constant float4 *pal) {
        float3 n = normalize(cross(b - a, c - a));
        if (n.z < 0.0) n = -n;
        // One or two sheets of paper (mid and light palette entries) in big regions: the
        // light and the creases carry the picture, not a colour mosaic.
        float2 centre = (a.xy + b.xy + c.xy) / 3.0;
        int index = vnoise(centre * 0.12 + 3.1) > 0.62 ? 4 : 3;
        float3 base = max(pal[index].rgb, float3(0.12));
        float lit = max(0.0, dot(n, light));
        return base * (0.42 + 0.8 * lit);
    }

    float3 paperSample(float2 p, float flow, float bass, float3 light, constant float4 *pal) {
        int2 c = int2(floor(p));
        float3 v[4][4];
        for (int j = 0; j < 4; j++)
            for (int i = 0; i < 4; i++)
                v[j][i] = paperVertex(c + int2(i - 1, j - 1), flow, bass);
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float3 a = v[j][i], b = v[j][i + 1], d = v[j + 1][i], e = v[j + 1][i + 1];
                bool flip = hash21(float2(c + int2(i - 1, j - 1)) + 9.7) > 0.5;
                float3 t0 = flip ? e : d;
                if (inTriangle(p, a, b, t0)) return paperFacet(a, b, t0, light, pal);
                float3 s0 = flip ? a : b;
                if (inTriangle(p, s0, e, d)) return paperFacet(s0, e, d, light, pal);
            }
        }
        return pal[3].rgb;
    }

    float3 paper(float2 uv, constant Uniforms &u, constant float4 *pal) {
        float aspect = u.frame.x / u.frame.y;
        const float rows = 3.4;
        float flow = u.frame.z;
        // The light swings slowly across the sheet, so folds catch and lose it.
        float3 light = normalize(float3(0.55 * cos(flow * 0.11), -0.5 + 0.12 * sin(flow * 0.07), 0.75));
        float2 p = uv * float2(aspect, 1.0) * rows + 7.0;
        float px = rows / u.frame.y;
        // 4× supersampling: clean creases at 480 lines.
        float3 sum = float3(0.0);
        sum += paperSample(p + float2(-0.25, -0.25) * px, flow, u.audio.x, light, pal);
        sum += paperSample(p + float2( 0.25, -0.25) * px, flow, u.audio.x, light, pal);
        sum += paperSample(p + float2(-0.25,  0.25) * px, flow, u.audio.x, light, pal);
        sum += paperSample(p + float2( 0.25,  0.25) * px, flow, u.audio.x, light, pal);
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
        // With lyrics up, the cover shrinks a little and rises to leave the lower band free.
        float lyrics = u.rhythm.y;
        float2 p = (uv - float2(0.5, 0.5 - 0.075 * lyrics)) * float2(aspect, 1.0);
        float size = mix(0.64, 0.54, lyrics) * (1.0 + 0.005 * u.rhythm.x);
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
                     texture2d<float> art, texture2d<float> mask, float hasArt, float hasMask, sampler s) {
        float3 base = u.style.x < 0.5 ? paper(uv, u, pal) : paletteBleed(uv, u, pal);
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
                                   texture2d<float> mask1 [[texture(3)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float3 col = slotColor(in.uv, u, u.palette0, art0, mask0, u.slots.x, u.slots.z, s);
        if (u.rhythm.z < 0.999) {
            float3 prev = slotColor(in.uv, u, u.palette1, art1, mask1, u.slots.y, u.slots.w, s);
            col = mix(prev, col, u.rhythm.z);
        }
        float2 v = in.uv - 0.5;
        col *= 1.0 - dot(v, v) * 0.7;
        col *= u.frame.w;
        return float4(col, 1.0);
    }

    // --- Lyrics: one textured quad per line, alpha-blended (premultiplied) over the scene ---

    struct TextUniforms {
        float4 rect;   // centre.x, centre.y, half width, half height (scene uv, y down)
        float4 style;  // opacity, glow, unused, unused
        float4 color;
    };

    struct TOut {
        float4 position [[position]];
        float2 tex;
    };

    vertex TOut text_vertex(uint vid [[vertex_id]], constant TextUniforms &t [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        float2 tex = corner * 1.3 - 0.15;              // overscan so shadow and glow aren't clipped
        float2 uv = t.rect.xy + (tex * 2.0 - 1.0) * t.rect.zw;
        TOut o;
        o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        o.tex = tex;
        return o;
    }

    fragment float4 text_fragment(TOut in [[stage_in]], constant TextUniforms &t [[buffer(0)]],
                                  texture2d<float> text [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float a = text.sample(s, in.tex).a;
        // Blurred mips stand in for a drop shadow and a soft glow: cheap and smooth at 480 lines.
        float shadow = text.sample(s, in.tex + float2(0.0, 0.035), level(3.0)).a;
        float glow = text.sample(s, in.tex, level(4.5)).a;
        float3 rgb = t.color.rgb * a + (1.0 - a) * t.color.rgb * glow * t.style.y;
        float alpha = a + (1.0 - a) * max(shadow * 0.9, glow * t.style.y * 0.4);
        return float4(rgb, alpha) * t.style.x;
    }

    // Upscale the low-res scene to the drawable. Bilinear is already soft at 480 lines,
    // which is what we want for composite.
    fragment float4 present_fragment(VOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(scene.sample(s, in.uv).rgb, 1.0);
    }
    """#
}
