import CoreAudio
import Foundation

public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
}

/// Thin wrapper over the CoreAudio HAL for enumerating and configuring input devices.
public enum AudioDeviceCatalog {
    public static func inputDevices() -> [AudioInputDevice] {
        let ids: [AudioDeviceID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap(makeDevice).filter { $0.inputChannelCount > 0 }
    }

    public static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    /// Whether the device is still there (it reports false while it's being unplugged).
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        let alive: UInt32 = read(id, kAudioDevicePropertyDeviceIsAlive, initial: 0) ?? 0
        return alive != 0
    }

    static func uid(of id: AudioDeviceID) -> String? { readString(id, kAudioDevicePropertyDeviceUID) }

    public static func defaultInputDevice() -> AudioInputDevice? {
        guard let id: AudioDeviceID = read(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: 0
        ), id != 0 else { return nil }
        return makeDevice(id)
    }

    public static func setNominalSampleRate(_ rate: Double, deviceUID uid: String) throws {
        guard let device = device(uid: uid) else { throw CatalogError.deviceNotFound(uid) }
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw CatalogError.coreAudio(status) }
    }

    public enum CatalogError: Error, CustomStringConvertible {
        case deviceNotFound(String)
        case coreAudio(OSStatus)

        public var description: String {
            switch self {
            case .deviceNotFound(let uid): "Audio device \(uid) not found"
            case .coreAudio(let status): "CoreAudio error \(status)"
            }
        }
    }

    // MARK: - HAL plumbing

    private static func makeDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = readString(id, kAudioObjectPropertyName) ?? uid
        let rate: Float64 = read(id, kAudioDevicePropertyNominalSampleRate, initial: 0) ?? 0
        let ranges: [AudioValueRange] = readArray(id, kAudioDevicePropertyAvailableNominalSampleRates)
        let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        let available = standardRates.filter { r in ranges.contains { $0.mMinimum <= r && r <= $0.mMaximum } }
        return AudioInputDevice(
            id: id, uid: uid, name: name,
            inputChannelCount: inputChannelCount(id),
            nominalSampleRate: rate,
            availableSampleRates: available
        )
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var actual = size
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &actual, buffer.baseAddress!)
            initialized = status == noErr ? Int(actual) / MemoryLayout<T>.stride : 0
        }
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
