import Foundation
import SignalAnalysis
import Synchronization
import Testing
import Visuals
@testable import Lights

@Suite struct HueColorTests {
    @Test func primariesLandNearTheirCorners() {
        let red = HueColor.xy(RGB(1, 0, 0), gamut: .c)
        #expect(abs(red.x - 0.64) < 0.06 && abs(red.y - 0.33) < 0.03, "\(red)")
        let green = HueColor.xy(RGB(0, 1, 0), gamut: .c)
        #expect(abs(green.x - 0.30) < 0.02 && abs(green.y - 0.60) < 0.02, "\(green)")
        let blue = HueColor.xy(RGB(0, 0, 1), gamut: .c)
        #expect(Gamut.c.contains(blue))
        #expect(abs(blue.x - 0.15) < 0.01 && abs(blue.y - 0.06) < 0.02, "\(blue)")
    }

    @Test func whiteAndBlackAreD65() {
        let white = HueColor.xy(RGB(1, 1, 1))
        #expect(abs(white.x - 0.3127) < 0.002 && abs(white.y - 0.3290) < 0.002)
        #expect(HueColor.xy(RGB(0, 0, 0)) == XY.white)
        let grey = HueColor.xy(RGB(0.3, 0.3, 0.3))
        #expect(abs(grey.x - 0.3127) < 0.002)
    }

    @Test func outOfGamutColoursMoveToTheNearestEdge() {
        // sRGB green is outside gamut B (whose green corner is 0.409, 0.518).
        let raw = XY(0.30, 0.60)
        #expect(!Gamut.b.contains(raw))
        let clamped = Gamut.b.clamp(raw)
        #expect(Gamut.b.contains(XY(clamped.x - 1e-4 * (clamped.x - 0.33), clamped.y - 1e-4 * (clamped.y - 0.33))))
        #expect(clamped != raw)
        // Inside: unchanged.
        #expect(Gamut.b.clamp(XY(0.4, 0.35)) == XY(0.4, 0.35))
        // Far outside below the blue corner: the corner itself.
        let corner = Gamut.c.clamp(XY(0.10, 0.0))
        #expect(abs(corner.x - Gamut.c.blue.x) < 0.02 && abs(corner.y - Gamut.c.blue.y) < 0.02)
    }

    @Test func gamutsByName() {
        #expect(Gamut.named("A") == .a)
        #expect(Gamut.named("b") == .b)
        #expect(Gamut.named(nil) == .c)
        #expect(Gamut.named("other") == .c)
    }

    @Test func mixingIsInLinearLight() {
        let mid = HueColor.mix(RGB(1, 0, 0), RGB(0, 0, 1), 0.5)
        // Gamma-space mixing would give 0.5; linear-light mixing is brighter.
        #expect(mid.r > 0.7 && mid.b > 0.7 && mid.g == 0)
        #expect(HueColor.mix(RGB(0.2, 0.4, 0.6), RGB(1, 1, 1), 0) == RGB(HueColor.encoded(HueColor.linear(0.2)),
                                                                          HueColor.encoded(HueColor.linear(0.4)),
                                                                          HueColor.encoded(HueColor.linear(0.6))))
    }

    @Test func pskDecodesFromHex() {
        let credentials = HueCredentials(appKey: "k", clientKey: "00ff10A0")
        #expect(credentials.psk == Data([0x00, 0xFF, 0x10, 0xA0]))
        #expect(HueCredentials(appKey: "k", clientKey: "abc").psk == nil)
        #expect(HueCredentials(appKey: "k", clientKey: "zz").psk == nil)
        #expect(HueCredentials(appKey: "k", clientKey: nil).psk == nil)
    }
}

@Suite struct PulseEnvelopeTests {
    @Test func shapeRisesSoftlyThenDecays() {
        #expect(PulseEnvelope.shape(-0.1) == 0)
        #expect(PulseEnvelope.shape(0) == 0)
        #expect(abs(PulseEnvelope.shape(PulseEnvelope.attack) - 1) < 1e-9)
        #expect(PulseEnvelope.shape(PulseEnvelope.attack / 2) > 0.3)
        #expect(PulseEnvelope.shape(1.0) < 0.1)
        var previous = 1.0
        for t in stride(from: PulseEnvelope.attack, through: 1.5, by: 0.05) {
            let v = PulseEnvelope.shape(t)
            #expect(v <= previous)
            previous = v
        }
    }

    /// Feeds beats at `bpm` for `seconds` at 50 Hz and counts pulse starts.
    private func pulses(bpm: Double, seconds: Double) -> Int {
        var envelope = PulseEnvelope()
        let period = 60 / bpm
        var count = 0
        var previous = 0.0
        var rising = false
        for i in 0..<Int(seconds * 50) {
            let now = Double(i) / 50
            let age = now.truncatingRemainder(dividingBy: period)
            let v = envelope.update(now: now, beatAge: age, strength: 1)
            if v > previous + 1e-6, !rising { count += 1; rising = true }
            if v < previous - 1e-6 { rising = false }
            previous = v
        }
        return count
    }

    @Test func followsModerateTempos() {
        #expect((19...21).contains(pulses(bpm: 120, seconds: 10)))
    }

    @Test func neverMoreThanTwoAndAHalfPulsesASecond() {
        // 200 bpm would be 3.3 a second: it pulses every other beat instead.
        let count = pulses(bpm: 200, seconds: 10)
        #expect(count <= 25, "\(count)")
        #expect(count >= 15)
    }

    @Test func noBeatNoPulse() {
        var envelope = PulseEnvelope()
        for i in 0..<100 {
            #expect(envelope.update(now: Double(i) / 50, beatAge: nil, strength: 1) == 0)
        }
    }
}

@Suite struct LightShowTests {
    private let paletteA = Palette(colors: [RGB(0.05, 0.05, 0.1), RGB(0.2, 0.1, 0.1), RGB(0.3, 0.2, 0.2),
                                            RGB(0.8, 0.2, 0.1), RGB(0.9, 0.8, 0.3), RGB(0.98, 0.97, 0.95)])
    private let paletteB = Palette(colors: [RGB(0.02, 0.05, 0.1), RGB(0.05, 0.1, 0.3), RGB(0.1, 0.2, 0.4),
                                            RGB(0.1, 0.4, 0.8), RGB(0.3, 0.8, 0.9), RGB(0.95, 0.97, 0.99)])

    @Test func sheetAndAccentMatchTheShader() {
        // Shuffled order: the shader sorts dark → light and takes [3] and [4].
        let shuffled = Palette(colors: [paletteA.colors[5], paletteA.colors[3], paletteA.colors[0],
                                        paletteA.colors[4], paletteA.colors[1], paletteA.colors[2]])
        let (sheet, accent) = LightShow.sheetAndAccent(shuffled)
        #expect(sheet == paletteA.colors[3])
        #expect(accent == paletteA.colors[4])
    }

    @Test func restsOnTheSheetColourWhenQuiet() {
        var show = LightShow()
        let config = LightShowConfig(brightness: 0.8, pulse: 1, motion: 1)
        var state = LightState.off
        for i in 0..<50 {
            state = show.update(LightShowInput(palette: paletteA, active: true), config: config, now: Double(i) / 25)
        }
        let expected = HueColor.xy(paletteA.colors[3])
        let got = HueColor.xy(state.color)
        #expect(abs(got.x - expected.x) < 0.01 && abs(got.y - expected.y) < 0.01)
        #expect(state.brightness > 0.3 && state.brightness <= 0.8)
    }

    @Test func crossfadesBetweenAlbums() {
        var show = LightShow()
        let config = LightShowConfig(brightness: 0.8, pulse: 0, crossfade: 3)
        _ = show.update(LightShowInput(palette: paletteA, active: true), config: config, now: 0)
        let a = HueColor.xy(LightShow.normalized(paletteA.colors[3]))
        let b = HueColor.xy(LightShow.normalized(paletteB.colors[3]))
        var xs: [Double] = []
        for i in 1...100 {
            let state = show.update(LightShowInput(palette: paletteB, active: true), config: config, now: Double(i) * 0.04)
            xs.append(HueColor.xy(state.color).x)
        }
        // Starts at album A's colour, moves steadily, ends on album B's.
        #expect(abs(xs[0] - a.x) < 0.03)
        #expect(abs(xs.last! - b.x) < 0.01)
        let midway = xs[36]  // ~1.5 s in
        #expect(min(a.x, b.x) < midway && midway < max(a.x, b.x))
        for i in 1..<xs.count { #expect(abs(xs[i] - xs[i - 1]) < 0.03, "jump at \(i)") }
    }

    @Test func pulsesAreGentleAndFollowTheBeat() {
        var show = LightShow()
        let config = LightShowConfig(brightness: 0.8, pulse: 1, motion: 1)
        var brightness: [Double] = []
        for i in 0..<500 {
            let now = Double(i) / 50
            let age = now.truncatingRemainder(dividingBy: 0.5)  // 120 bpm
            var features = AudioFeatures(time: now, musicBandRMS: 0.1, tempo: 120)
            features.beat = age < 0.02
            brightness.append(show.update(LightShowInput(palette: paletteA, features: features, beatAge: age, active: true),
                                          config: config, now: now).brightness)
        }
        let settled = brightness.suffix(250)
        let peak = settled.max()!, trough = settled.min()!
        #expect(peak - trough > 0.1, "should visibly pulse")
        #expect((peak - trough) / peak <= PulseEnvelope.maxDepth + 0.01, "never deeper than the cap")
        #expect(peak <= 0.8 + 1e-9, "never brighter than the user's setting")
        // Never changes faster than the slew limit.
        for i in 1..<brightness.count {
            #expect(abs(brightness[i] - brightness[i - 1]) <= LightShow.maxSlew / 50 + 1e-9)
        }
    }

    @Test func stillMotionMeansNoPulses() {
        var show = LightShow()
        let config = LightShowConfig(brightness: 0.8, pulse: 1, motion: 0)
        var values: Set<Int> = []
        for i in 100..<400 {
            let now = Double(i) / 50
            let age = now.truncatingRemainder(dividingBy: 0.5)
            let state = show.update(LightShowInput(palette: paletteA, features: AudioFeatures(musicBandRMS: 0.1),
                                                   beatAge: age, active: true), config: config, now: now)
            if i > 200 { values.insert(Int(state.brightness * 1000)) }
        }
        #expect(values.count <= 2, "\(values)")
    }

    @Test func slowOutputsGetNoPulses() {
        #expect(LightShowConfig(pulse: 1, motion: 1, pulses: false).pulseAmount == 0)
        #expect(LightShowConfig(pulse: 0.6, motion: 0.5).pulseAmount == 0.3)
    }

    @Test func idleDimsAndStopsPulsing() {
        var show = LightShow()
        let config = LightShowConfig(brightness: 1, pulse: 1, motion: 1)
        var state = LightState.off
        for i in 0..<200 {
            let now = Double(i) / 50
            state = show.update(LightShowInput(palette: paletteA, beatAge: now.truncatingRemainder(dividingBy: 0.5), active: false),
                                config: config, now: now)
        }
        #expect(state.brightness < 0.7)
    }
}

@Suite struct RateLimiterTests {
    @Test func tenASecond() {
        var limiter = RateLimiter(rate: 10)
        var sent = 0
        for i in 0..<600 where limiter.tryAcquire(now: Double(i) / 60) { sent += 1 }  // 10 s at 60 Hz
        #expect((99...101).contains(sent), "\(sent)")
    }

    @Test func oneASecondForGroups() {
        var limiter = RateLimiter(rate: 1)
        var sent = 0
        for i in 0..<300 where limiter.tryAcquire(now: Double(i) / 30) { sent += 1 }  // 10 s
        #expect((10...11).contains(sent), "\(sent)")
    }

    @Test func doesNotSaveUpUnusedSends() {
        var limiter = RateLimiter(rate: 10)
        let first = limiter.tryAcquire(now: 0)
        // A minute of silence earns one send, not six hundred.
        let afterSilence = limiter.tryAcquire(now: 60)
        let straightAfter = limiter.tryAcquire(now: 60.01)
        #expect(first && afterSilence && !straightAfter)
    }
}

// MARK: - Fakes for the bridge

private final class FakeSink: LightCommandSink, @unchecked Sendable {
    let sent = Mutex<[(LightTarget, LightState, Double)]>([])
    func set(_ target: LightTarget, state: LightState, gamut: Gamut, transition: Double) async throws {
        sent.withLock { $0.append((target, state, transition)) }
    }
    var count: Int { sent.withLock { $0.count } }
    var all: [(LightTarget, LightState, Double)] { sent.withLock { $0 } }
}

private final class FakeTransport: HueTransport, @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var responses: [String: (Data, Int)] = [:]

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { requests.append(request) }
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        return lock.withLock { responses[key] } ?? (Data("{\"errors\":[],\"data\":[]}".utf8), 200)
    }
}

@Suite struct RESTOutputTests {
    private func state(_ b: Double) -> LightState { LightState(color: RGB(1, 0.5, 0.2), brightness: b) }

    @Test func respectsTheLightRateAndSkipsUnchangedStates() async throws {
        let sink = FakeSink()
        let output = RESTLightOutput(sink: sink, targets: [(.light(id: "l1", name: "Strip"), .c)])
        #expect(output.pulses)
        // Two seconds at 60 Hz with a brightness that changes every frame.
        for i in 0..<120 {
            output.send(state(0.3 + 0.3 * Double(i % 2)), now: Double(i) / 60)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.count <= 21 && sink.count >= 10, "\(sink.count)")
        #expect(sink.all.allSatisfy { abs($0.2 - 0.1) < 1e-9 }, "fades over one command interval")

        // A steady state isn't resent.
        let steady = FakeSink()
        let quiet = RESTLightOutput(sink: steady, targets: [(.light(id: "l1", name: "Strip"), .c)])
        for i in 0..<60 {
            quiet.send(state(0.5), now: Double(i) / 60)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(steady.count == 1)
    }

    @Test func groupsGetOneCommandASecondAndNoPulses() async throws {
        let sink = FakeSink()
        let output = RESTLightOutput(sink: sink, targets: [(.group(groupedLightID: "g1", name: "Living room"), .c)])
        #expect(!output.pulses)
        for i in 0..<180 {
            output.send(state(Double(i % 50) / 100 + 0.2), now: Double(i) / 60)  // 3 s
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect((3...4).contains(sink.count), "\(sink.count)")
    }

    @Test func severalLightsShareTheBudget() async throws {
        let sink = FakeSink()
        let targets: [(target: LightTarget, gamut: Gamut)] = (0..<4).map { (.light(id: "l\($0)", name: "L\($0)"), .c) }
        let output = RESTLightOutput(sink: sink, targets: targets)
        #expect(!output.pulses, "2.5 updates a second each is too slow to pulse")
        for i in 0..<120 {
            output.send(state(0.2 + Double(i % 3) * 0.2), now: Double(i) / 60)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        let ids = sink.all.map { if case .light(let id, _) = $0.0 { id } else { "" } }
        #expect(ids.count <= 21)
        #expect(Set(ids).count == 4, "round-robin across the lights")
    }
}

@Suite struct HueClientTests {
    private let bridge = HueBridge(id: "001788FFFE123456", host: "192.0.2.10")

    @Test func pairingNeedsTheLinkButton() async throws {
        let transport = FakeTransport()
        transport.responses["POST /api"] = (Data(#"[{"error":{"type":101,"address":"","description":"link button not pressed"}}]"#.utf8), 200)
        let client = HueClient(bridge: bridge, transport: transport)
        await #expect(throws: HueError.linkButtonNotPressed) { try await client.pair() }

        transport.responses["POST /api"] = (Data(#"[{"success":{"username":"app-key","clientkey":"0011223344556677"}}]"#.utf8), 200)
        let credentials = try await client.pair()
        #expect(credentials == HueCredentials(appKey: "app-key", clientKey: "0011223344556677"))
        let body = try #require(transport.requests.last?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["generateclientkey"] as? Bool == true)
    }

    @Test func listsAreasGroupsAndColourLights() async throws {
        let transport = FakeTransport()
        transport.responses["GET /clip/v2/resource/light"] = (Data(#"""
        {"errors":[],"data":[
          {"id":"l1","metadata":{"name":"Strip"},"color":{"gamut_type":"C","gamut":{"red":{"x":0.6915,"y":0.3083},"green":{"x":0.17,"y":0.7},"blue":{"x":0.1532,"y":0.0475}}}},
          {"id":"l2","metadata":{"name":"White bulb"}}
        ]}
        """#.utf8), 200)
        transport.responses["GET /clip/v2/resource/room"] = (Data(#"""
        {"errors":[],"data":[{"id":"r1","metadata":{"name":"Living room"},"services":[{"rid":"g1","rtype":"grouped_light"}]}]}
        """#.utf8), 200)
        transport.responses["GET /clip/v2/resource/entertainment_configuration"] = (Data(#"""
        {"errors":[],"data":[{"id":"e1","metadata":{"name":"TV area"},"status":"inactive",
          "channels":[{"channel_id":0},{"channel_id":1}],"light_services":[{"rid":"l1","rtype":"light"}]}]}
        """#.utf8), 200)
        let client = HueClient(bridge: bridge, credentials: HueCredentials(appKey: "k", clientKey: nil), transport: transport)
        let resources = try await client.resources()
        #expect(resources.map(\.target) == [.entertainment(id: "e1", name: "TV area"),
                                            .group(groupedLightID: "g1", name: "Living room"),
                                            .light(id: "l1", name: "Strip")])
        #expect(resources[0].channels == [0, 1])
        #expect(resources[0].lights == ["l1"])
        #expect(resources[2].gamut == .c)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "hue-application-key") == "k" })
    }

    @Test func setSendsXYBrightnessAndDuration() async throws {
        let transport = FakeTransport()
        let client = HueClient(bridge: bridge, credentials: HueCredentials(appKey: "k", clientKey: nil), transport: transport)
        try await client.set(.light(id: "l1", name: "Strip"), state: LightState(color: RGB(1, 0, 0), brightness: 0.5),
                             gamut: .c, transition: 0.1)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/clip/v2/resource/light/l1")
        let json = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect((json["dimming"] as? [String: Any])?["brightness"] as? Double == 50)
        #expect((json["dynamics"] as? [String: Any])?["duration"] as? Int == 100)
        let xy = try #require((json["color"] as? [String: Any])?["xy"] as? [String: Double])
        #expect(abs(xy["x"]! - 0.64) < 0.06)

        try await client.set(.group(groupedLightID: "g1", name: "Room"), state: .off, transition: 1)
        #expect(transport.requests.last?.url?.path == "/clip/v2/resource/grouped_light/g1")
        let off = try #require(try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as? [String: Any])
        #expect((off["on"] as? [String: Bool])?["on"] == false)
        #expect(off["dimming"] == nil)
    }

    @Test func unauthorizedIsReported() async throws {
        let transport = FakeTransport()
        transport.responses["GET /clip/v2/resource/light"] = (Data(), 403)
        let client = HueClient(bridge: bridge, credentials: HueCredentials(appKey: "old", clientKey: nil), transport: transport)
        await #expect(throws: HueError.unauthorized) { let _: [LightDTO] = try await client.list("light") }
    }

    @Test func cloudDiscoveryParses() {
        let data = Data(#"[{"id":"001788FFFE123456","internalipaddress":"192.0.2.10","port":443}]"#.utf8)
        #expect(HueDiscovery.parseCloud(data) == [HueBridge(id: "001788fffe123456", host: "192.0.2.10")])
        #expect(HueDiscovery.parseCloud(Data("nope".utf8)).isEmpty)
    }
}

@Suite struct StreamMessageTests {
    @Test func encodesTheV2Format() {
        let area = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"
        let data = HueStreamMessage.encode(areaID: area, sequence: 7, channels: [
            (0, LightState(color: RGB(1, 1, 1), brightness: 1)),
            (3, LightState(color: RGB(1, 0, 0), brightness: 0.5)),
        ])
        #expect(data.count == 16 + 36 + 2 * 7)
        #expect(String(decoding: data.prefix(9), as: UTF8.self) == "HueStream")
        #expect(Array(data[9..<16]) == [0x02, 0x00, 7, 0x00, 0x00, 0x01, 0x00])
        #expect(String(decoding: data[16..<52], as: UTF8.self) == area)
        #expect(data[52] == 0)
        #expect(data[59] == 3)
        // Full brightness on channel 0, half on channel 3.
        #expect(data[57] == 0xFF && data[58] == 0xFF)
        let half = UInt16(data[64]) << 8 | UInt16(data[65])
        #expect(abs(Int(half) - 32767) <= 1)
    }
}
