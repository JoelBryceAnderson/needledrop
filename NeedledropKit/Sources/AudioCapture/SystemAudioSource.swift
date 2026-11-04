import AudioToolbox
import CoreAudio
import Foundation

/// Captures what this Mac is playing (a browser, a music app…) through a Core Audio
/// process tap, so music that isn't on the turntable can drive the visuals. Needledrop
/// itself is excluded, so it never hears its own output.
///
/// macOS asks once for "System Audio Recording" (NSAudioCaptureUsageDescription).
@available(macOS 14.2, *)
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public var displayName: String { "This Mac's audio" }

    // State touched only on start/stop (serialised by `control`).
    private let control = DispatchQueue(label: "needledrop.systemaudio.control")
    private let ioQueue = DispatchQueue(label: "needledrop.systemaudio.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Preallocated deinterleave buffers for the IO block (never allocate there).
    private let maxFrames = 16_384
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    public init() {
        left = .allocate(capacity: maxFrames)
        right = .allocate(capacity: maxFrames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public enum Failure: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .coreAudio(let step, let status): "Couldn't capture this Mac's audio (\(step), OSStatus \(status))"
            }
        }
    }

    public func start(writingTo ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) throws {
        try control.sync {
            do {
                try startTap(ring: ring, status: status)
            } catch {
                teardown()
                throw error
            }
        }
    }

    public func stop() {
        control.sync { teardown() }
    }

    // MARK: - Tap + aggregate device

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure.coreAudio(step, status) }
    }

    private func startTap(ring: AudioRingBuffer, status: @escaping @Sendable (SourceStatus) -> Void) throws {
        // A stereo mix of every process except this one.
        let ownProcess = Self.processObject(pid: ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Needledrop"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

        // The tap is read through a private aggregate device clocked by the output device.
        guard let outputUID = Self.defaultOutputUID() else { throw Failure.coreAudio("default output device", -1) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Needledrop System Audio",
            kAudioAggregateDeviceUIDKey: "com.needledrop.systemaudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read tap format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { throw Failure.coreAudio("unexpected tap format", -2) }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)

        // Report the format before the first buffer lands.
        status(.running(CaptureFormat(sampleRate: format.mSampleRate, channelCount: min(2, channels)), sourceName: displayName))

        let left = self.left, right = self.right, maxFrames = self.maxFrames
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            if interleaved {
                let frames = min(maxFrames, Int(first.mDataByteSize) / (4 * max(1, channels)))
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
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start (is System Audio Recording allowed in Privacy & Security?)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - HAL lookups

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
