import Foundation
import HomeLink
import Network
import Synchronization
import Testing
import Visuals
@testable import Lights

@Suite struct HomeColorTests {
    @Test func primariesAndGreys() {
        let red = HomeColor(LightState(color: RGB(1, 0, 0), brightness: 0.5))
        #expect(abs(red.hue) < 0.01 && abs(red.saturation - 100) < 0.01 && red.brightness == 50 && red.on)
        let green = HomeColor(LightState(color: RGB(0, 1, 0), brightness: 1))
        #expect(abs(green.hue - 120) < 0.01 && green.brightness == 100)
        let blue = HomeColor(LightState(color: RGB(0, 0, 1), brightness: 1))
        #expect(abs(blue.hue - 240) < 0.01)
        let magenta = HomeColor(LightState(color: RGB(1, 0, 0.5), brightness: 1))
        #expect(abs(magenta.hue - 330) < 0.01, "\(magenta)")
        let grey = HomeColor(LightState(color: RGB(0.5, 0.5, 0.5), brightness: 1))
        #expect(grey.saturation == 0 && grey.hue == 0)
    }

    @Test func dimButOnNeverRoundsToZero() {
        #expect(HomeColor(LightState(color: RGB(1, 1, 1), brightness: 0.006)).brightness == 1)
        let off = HomeColor(.off)
        #expect(!off.on && off.brightness == 0)
    }

    @Test func closeIgnoresHueOfNearWhites() {
        let a = HomeColor(hue: 10, saturation: 3, brightness: 60, on: true)
        let b = HomeColor(hue: 200, saturation: 4, brightness: 60, on: true)
        #expect(a.close(to: b))
        let c = HomeColor(hue: 359.5, saturation: 80, brightness: 60, on: true)
        let d = HomeColor(hue: 0.5, saturation: 80, brightness: 60, on: true)
        #expect(c.close(to: d), "hue wraps")
        #expect(!c.close(to: HomeColor(hue: 20, saturation: 80, brightness: 60, on: true)))
        #expect(!c.close(to: HomeColor(hue: 359.5, saturation: 80, brightness: 61, on: true)))
    }
}

@Suite struct HomeLightOutputTests {
    final class Sink: HomeCommandSink {
        let sent = Mutex<[([String], HomeColor)]>([])
        func set(lights: [String], color: HomeColor) { sent.withLock { $0.append((lights, color)) } }
    }

    @Test func twoASecondAndNothingUnchanged() {
        let sink = Sink()
        let output = HomeLightOutput(sink: sink, lights: ["a", "b"])
        #expect(!output.pulses)
        // A changing colour every frame for 3 s at 30 fps.
        for frame in 0..<90 {
            let t = Double(frame) / 30
            output.send(LightState(color: RGB(1, Float(frame) / 90, 0), brightness: 0.7), now: t)
        }
        let count = sink.sent.withLock { $0.count }
        #expect((6...7).contains(count), "\(count)")
        #expect(sink.sent.withLock { $0.allSatisfy { $0.0 == ["a", "b"] } })

        // Holding one colour sends it once.
        let steady = Sink()
        let still = HomeLightOutput(sink: steady, lights: ["a"])
        for frame in 0..<90 { still.send(LightState(color: RGB(0.2, 0.4, 1), brightness: 0.5), now: Double(frame) / 30) }
        #expect(steady.sent.withLock { $0.count } == 1)
    }

    @Test func closedOutputSendsNothing() async {
        let sink = Sink()
        let output = HomeLightOutput(sink: sink, lights: ["a"])
        await output.close()
        output.send(LightState(color: RGB(1, 0, 0), brightness: 1), now: 0)
        #expect(sink.sent.withLock { $0.isEmpty })
    }
}

@Suite struct HomeLinkTests {
    @Test func framerSplitsAndWaitsForTheRest() {
        var framer = LineFramer()
        #expect(framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(framer.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(framer.append(Data()).isEmpty)
    }

    @Test func messagesRoundTrip() throws {
        let requests: [HomeRequest] = [.list, .set(lights: ["x"], color: HomeColor(hue: 30, saturation: 50, brightness: 70, on: true))]
        for request in requests {
            let line = try HomeLink.encode(request)
            #expect(line.last == 0x0A)
            #expect(try HomeLink.decode(HomeRequest.self, from: line.dropLast()) == request)
        }
        let event = HomeEvent.catalog(authorization: .authorized,
                                      lights: [HomeLight(id: "1", name: "Lamp", room: "Den", home: "Home")],
                                      rooms: [HomeRoom(id: "r", name: "Den", home: "Home", lights: ["1"])])
        #expect(try HomeLink.decode(HomeEvent.self, from: HomeLink.encode(event).dropLast()) == event)
    }

    @Test func roomTargetsResolveAgainstTheCatalog() {
        let rooms = [HomeRoom(id: "r", name: "Den", home: "Home", lights: ["1", "2"])]
        #expect(HomeTarget.room(id: "r", name: "Den").lights(in: rooms) == ["1", "2"])
        #expect(HomeTarget.room(id: "gone", name: "Old").lights(in: rooms).isEmpty)
        #expect(HomeTarget.light(id: "9", name: "Lamp").lights(in: rooms) == ["9"])
    }

    /// The server and a client (as the helper connects) over a real Unix socket.
    @Test func serverTalksOverAUnixSocket() async throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("nd-test-\(UUID().uuidString.prefix(8)).sock")
        let events = AsyncStream<HomeEvent>.makeStream()
        let server = HomeLinkServer(socketPath: path, onEvent: { events.continuation.yield($0) })
        try server.start()
        defer { server.stop() }

        let client = NWConnection(to: .unix(path: path), using: .tcp)
        let received = AsyncStream<Data>.makeStream()
        let queue = DispatchQueue(label: "test.client")
        client.start(queue: queue)
        @Sendable func receive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, _ in
                if let data { received.continuation.yield(data) }
                if !complete { receive() }
            }
        }
        receive()
        defer { client.cancel() }

        client.send(content: try HomeLink.encode(HomeEvent.hello(version: HomeLink.version)), completion: .idempotent)
        // Ends both streams if nothing arrives, so a broken link fails instead of hanging.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            events.continuation.finish()
            received.continuation.finish()
        }
        defer { deadline.cancel() }
        var iterator = events.stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .hello(version: HomeLink.version))

        let color = HomeColor(hue: 10, saturation: 90, brightness: 40, on: true)
        server.set(lights: ["a"], color: color)
        var framer = LineFramer()
        var lines: [Data] = []
        var dataIterator = received.stream.makeAsyncIterator()
        while lines.isEmpty, let chunk = await dataIterator.next() {
            lines += framer.append(chunk)
        }
        try #require(!lines.isEmpty)
        #expect(try HomeLink.decode(HomeRequest.self, from: lines[0]) == .set(lights: ["a"], color: color))
    }
}
