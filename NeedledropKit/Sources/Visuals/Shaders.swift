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
        float size = mix(0.64, 0.54, lyrics) * (1.0 + 0.012 * u.rhythm.x);
        float2 c = p / size + 0.5;

        float flow = u.frame.z;
        float2 drift = float2(sin(flow * 2.1), cos(flow * 1.7));
        float push = 0.015 + 0.035 * u.audio.x;
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
        Cover o;
        o.color = col;
        o.inside = 1.0 - smoothstep(0.0, 0.008, dist);
        o.shadow = (1.0 - smoothstep(-0.02, 0.18, dist)) * 0.65;
        return o;
    }

    float3 slotColor(float2 uv, constant Uniforms &u, constant float4 *pal,
                     texture2d<float> art, texture2d<float> mask, float hasArt, float hasMask, sampler s) {
        float3 base = paletteBleed(uv, u, pal);
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
