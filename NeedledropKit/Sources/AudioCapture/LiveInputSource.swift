import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// Captures from a hardware input via AVAudioEngine and writes into the ring buffer.
///
/// Never plays anything out — the input node is tapped and nothing is connected to the
/// output. Survives the interface being unplugged: it reports `.waitingForDevice` and
/// rebuilds the engine when the device reappears or the HAL reconfigures it.
public final class LiveInputSource: AudioSource, @unchecked Sendable {
    /// `nil` follows the system default input.
    public let preferredDeviceUID: String?
    public var displayName: String {
        preferredDeviceUID.flatMap { AudioDeviceCatalog.device(uid: $0)?.name } ?? "System default input"
    }

    // All mutable state below is confined to `control`.
    private let control = DispatchQueue(label: "needledrop.capture.control")
    private var engine: AVAudioEngine?
    private var currentDeviceID: AudioDeviceID?
    private var ring: AudioRingBuffer?
    private var status: (@Sendable (SourceStatus) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var halListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    public init(deviceUID: String?) {
        preferredDeviceUID = deviceUID
    }

    public func start(writingTo ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) {
        control.sync {
            self.ring = ring
            self.status = status
            isStarted = true
            installHALListeners()
            rebuildEngine()
        }
    }

    public func stop() {
        control.sync {
            isStarted = false
            removeHALListeners()
            teardownEngine()
        }
    }

    // MARK: - Engine lifecycle (on `control`)

    private func rebuildEngine() {
        teardownEngine()
        guard isStarted, let ring, let status else { return }

        let device = preferredDeviceUID.map(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultInputDevice()
        guard let device else {
            status(.waitingForDevice(preferredDeviceUID.map { "device \($0)" } ?? "a default input device"))
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if preferredDeviceUID != nil {
            guard let unit = input.audioUnit else {
                status(.failed("Input node has no audio unit"))
                return
            }
            var id = device.id
            let err = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard err == noErr else {
                status(.failed("Couldn't select \(device.name) (OSStatus \(err))"))
                return
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status(.waitingForDevice("\(device.name) (no input channels)"))
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            ring.write(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.rebuildEngine() }
        }

        // Report the format before the first buffer lands so the consumer can configure itself.
        status(.running(CaptureFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)),
                        sourceName: device.name))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            status(.failed("Couldn't start \(device.name): \(error.localizedDescription)"))
            return
        }
        self.engine = engine
        currentDeviceID = device.id
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        currentDeviceID = nil
    }

    // MARK: - Hot-plug

    private static let watchedSelectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    private func installHALListeners() {
        guard halListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        for selector in Self.watchedSelectors {
            var address = AudioDeviceCatalog.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        }
        halListener = listener
    }

    private func removeHALListeners() {
        guard let halListener else { return }
        for selector in Self.watchedSelectors {
            var address = AudioDeviceCatalog.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, halListener)
        }
        self.halListener = nil
    }

    /// Runs on `control` (the queue the listener was registered with).
    private func devicesChanged() {
        guard isStarted else { return }
        let wanted = preferredDeviceUID.map(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultInputDevice()
        let healthy = engine?.isRunning == true && wanted?.id == currentDeviceID
        if !healthy { rebuildEngine() }
    }
}
