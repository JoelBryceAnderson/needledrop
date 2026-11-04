import Testing
@testable import Visuals

@Suite(.needsGPU) struct ShaderValidatorTests {
    private func outcome(_ body: String) async -> ShaderValidator.Outcome {
        await ShaderValidator.validate(body: body)
    }

    @Test(.needsRealGPUTiming) func acceptsAReasonableScene() async {
        let body = """
            float2 p = (uv - 0.5) * float2(aspect, 1.0);
            float r = length(p) - 0.25 * (1.0 + 0.3 * bass);
            float3 c = mix(pal[1].rgb, pal[4].rgb, smoothstep(0.0, 0.01, -r));
            return c + 0.1 * fbm(p * 3.0 + time * 0.2);
            """
        let result = await outcome(body)
        #expect(result == .valid, "\(result)")
    }

    @Test func reportsCompilerErrorsForClaudeToFix() async {
        guard case .invalid(let reason) = await outcome("return float3(undefinedThing);") else {
            Issue.record("should fail")
            return
        }
        #expect(reason.contains("compiler") && reason.contains("undefinedThing"))
    }

    @Test func rejectsNaNsBlacksWhitesAndFlats() async {
        #expect(await outcome("return float3(sqrt(-1.0 - bass));") != .valid)
        #expect(await outcome("return float3(0.0);") != .valid)
        #expect(await outcome("return float3(1.0);") != .valid)
        #expect(await outcome("return pal[3].rgb;") != .valid)
    }

    @Test func rejectsResourceAccessAndUnboundedLoops() async {
        #expect(await outcome("#define X 1\nreturn pal[3].rgb * uv.x;") != .valid)
        #expect(await outcome("float x = 0; while (x < 1) { x += 0.1; } return float3(x) * uv.x;") != .valid)
    }

    @Test(.needsRealGPUTiming) func rejectsShadersTooSlowForTheFrameBudget() async {
        let body = """
            float v = 0.0;
            for (int i = 0; i < 4000; i++) { v += fbm(uv * float(i % 7 + 1) + time); }
            return mix(pal[1].rgb, pal[4].rgb, fract(v * 0.001 + uv.x));
            """
        guard case .invalid(let reason) = await outcome(body) else {
            Issue.record("should be too slow")
            return
        }
        #expect(reason.contains("ms"))
    }
}

@Suite struct ShaderSourceTests {
    @Test func customBodyReplacesTheDefault() {
        let source = Shaders.source(customBody: "return float3(0.5);")
        #expect(source.contains("return float3(0.5);"))
        #expect(!source.contains("return paletteBleed(uv, u, pal) + 0.0"))
        #expect(Shaders.source(customBody: nil) == Shaders.source)
    }
}
