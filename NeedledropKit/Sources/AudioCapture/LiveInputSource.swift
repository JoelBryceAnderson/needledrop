import AudioToolbox
import CoreAudio
import Foundation

/// Captures from a hardware input (a USB interface, a microphone) straight from Core Audio
/// with an IO proc on the device, and writes into the ring buffer.
///
/// Not AVAudioEngine: retargeting an engine's input node at a device other than the system
/// default can leave it "running" with a tap that never fires — no audio at all from a USB
/// interface. Reading the device directly works for any input, the same way the system-audio
/// capture does. Never plays anything out. Survives the interface being unplugged: it reports
/// `.waitingForDevice` and starts again when the device reappears, the default input changes,
/// or the device changes sample rate.
public final class LiveInputSource: AudioSource, @unchecked Sendable {
    /// `nil` follows the system default input.
    public let preferredDeviceUID: String?
    public var displayName: String {
        preferredDeviceUID.flatMap { AudioDeviceCatalog.device(uid: $0)?.name } ?? "System default input"
    }

    // All mutable state below is confined to `control`.
    private let control = DispatchQueue(label: "needledrop.capture.control")
    private let ioQueue = DispatchQueue(label: "needledrop.capture.io", qos: .userInteractive)
    private var procID: AudioDeviceIOProcID?
    private var currentDeviceID: AudioDeviceID?
    private var ring: AudioRingBuffer?
    private var status: (@Sendable (SourceStatus) -> Void)?
    private var halListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false
    /// What the device was when capture started, to tell a real change from a notification
    /// that changes nothing (USB interfaces send those as IO starts).
    private var startedRate = 0.0
    private var startedChannels = 0
    /// A restart waiting for a burst of device notifications to settle (or a retry).
    private var pendingRestart: DispatchWorkItem?

    // Preallocated deinterleave buffers for the IO block (never allocate there).
    private let maxFrames = 16_384
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    public init(deviceUID: String?) {
        preferredDeviceUID = deviceUID
        left = .allocate(capacity: maxFrames)
        right = .allocate(capacity: maxFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public func start(writingTo ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) {
        control.sync {
            self.ring = ring
            self.status = status
            isStarted = true
            installHALListeners()
            rebuild()
        }
    }

    public func stop() {
        control.sync {
            isStarted = false
            removeHALListeners()
            teardown()
        }
    }

    // MARK: - Capture (on `control`)

    private func rebuild() {
        teardown()
        guard isStarted, let ring, let status else { return }

        let device = preferredDeviceUID.map(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultInputDevice()
        guard let device else {
            status(.waitingForDevice(preferredDeviceUID.map { "device \($0)" } ?? "a default input device"))
            return  // the device-list listener restarts it when one appears
        }
        guard device.inputChannelCount > 0, device.nominalSampleRate > 0 else {
            // Mid-reconfiguration a USB device can briefly report no channels: try again
            // shortly rather than waiting for a notification that may never come.
            status(.waitingForDevice("\(device.name) (no input channels)"))
            scheduleRestart(after: 1)
            return
        }

        // Report the format before the first buffer lands so the consumer can configure itself.
        status(.running(CaptureFormat(sampleRate: device.nominalSampleRate, channelCount: min(2, device.inputChannelCount)),
                        sourceName: device.name))

        // IO procs get the device's input as 32-bit float: either one interleaved buffer, or
        // one buffer per channel (or per stream). Take the first two channels; mono feeds both.
        let left = self.left, right = self.right, maxFrames = self.maxFrames
        var newProc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&newProc, device.id, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData, first.mDataByteSize > 0 else { return }
            let channels = max(1, Int(first.mNumberChannels))
            if channels > 1 || buffers.count == 1 {
                let frames = min(maxFrames, Int(first.mDataByteSize) / (4 * channels))
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    left[i] = samples[i * channels]
                    right[i] = channels > 1 ? samples[i * channels + 1] : samples[i * channels]
                }
                ring.write(frameCount: frames, channelCount: 2) { $0 == 0 ? UnsafePointer(left) : UnsafePointer(right) }
            } else {
                let frames = Int(first.mDataByteSize) / 4
                let l = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                let r = buffers.count > 1 ? buffers[1].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } ?? l : l
                ring.write(frameCount: frames, channelCount: 2) { $0 == 0 ? l : r }
            }
        }
        guard created == noErr, let newProc else {
            status(.failed("Couldn't open \(device.name) (OSStatus \(created))"))
            return
        }
        let started = AudioDeviceStart(device.id, newProc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device.id, newProc)
            status(.failed("Couldn't start \(device.name) (OSStatus \(started)); is microphone access allowed?"))
            return
        }
        procID = newProc
        currentDeviceID = device.id
        startedRate = device.nominalSampleRate
        startedChannels = device.inputChannelCount
        watchDevice(device.id)
    }

    private func teardown() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let currentDeviceID {
            unwatchDevice(currentDeviceID)
            if let procID {
                AudioDeviceStop(currentDeviceID, procID)
                AudioDeviceDestroyIOProcID(currentDeviceID, procID)
            }
        }
        procID = nil
        currentDeviceID = nil
    }

    // MARK: - Hot-plug and format changes

    private static let watchedSelectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    /// On the device itself: it went away, or its sample rate or stream layout changed.
    private static let deviceSelectors = [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate,
                                          kAudioDevicePropertyStreamConfiguration]

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

    private func watchDevice(_ id: AudioDeviceID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isStarted else { return }
            self.deviceChanged()
        }
        for selector in Self.deviceSelectors {
            var address = AudioDeviceCatalog.address(selector,
                                                     scope: selector == kAudioDevicePropertyStreamConfiguration
                                                         ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(id, &address, control, listener)
        }
        deviceListener = listener
    }

    private func unwatchDevice(_ id: AudioDeviceID) {
        guard let deviceListener else { return }
        for selector in Self.deviceSelectors {
            var address = AudioDeviceCatalog.address(selector,
                                                     scope: selector == kAudioDevicePropertyStreamConfiguration
                                                         ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(id, &address, control, deviceListener)
        }
        self.deviceListener = nil
    }

    /// The device sent a notification: restart only if it really changed (gone, or a different
    /// sample rate or channel count), once the burst of notifications has settled.
    private func deviceChanged() {
        guard let id = currentDeviceID else { return }
        let alive = AudioDeviceCatalog.isAlive(id)
        let now = AudioDeviceCatalog.device(uid: AudioDeviceCatalog.uid(of: id) ?? "")
        if alive, let now, now.nominalSampleRate == startedRate, now.inputChannelCount == startedChannels { return }
        scheduleRestart(after: 0.4)
    }

    private func scheduleRestart(after delay: Double) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.rebuild()
        }
        pendingRestart = work
        control.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs on `control` (the queue the listener was registered with).
    private func devicesChanged() {
        guard isStarted else { return }
        let wanted = preferredDeviceUID.map(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultInputDevice()
        if procID == nil || wanted?.id != currentDeviceID { rebuild() }
    }
}
