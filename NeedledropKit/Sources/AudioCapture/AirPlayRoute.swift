import AVFoundation
import AVKit
import Foundation
import os

private let routeLog = Logger(subsystem: "com.needledrop.Needledrop", category: "airplay")

/// The AirPlay 2 group the pass-through plays to: several speakers (HomePods) at once, in sync.
///
/// macOS has no public way for an app to send live audio to more than one AirPlay speaker: the
/// Core Audio AirPlay device takes one receiver at a time. This uses the private `AVOutputContext`
/// that Music uses instead (the approach of the MIT-licensed jgarms/airlift):
/// an `AVSampleBufferAudioRenderer` is attached to an audio output context, and the system
/// AirPlay picker is pointed at that context, so it offers multi-select AirPlay 2 speakers.
/// airplayd then owns the group, its buffering (≈ 2 s) and the sync between speakers.
///
/// Every private call is looked up at runtime and checked first, so if a macOS update removes one,
/// `isAvailable` goes false and the pass-through falls back to the Mac's own output.
/// Limits: speakers can only be chosen in the system picker (an unentitled app can't list or
/// select them itself), and the choice lasts only while the app runs.
public final class AirPlayRoute: @unchecked Sendable {
    public static let shared = AirPlayRoute()

    /// Posted on the main queue when the chosen speakers change.
    public static let speakersDidChange = Notification.Name("NeedledropAirPlaySpeakersDidChange")

    private let context: NSObject?
    private var observer: NSObjectProtocol?

    private init() {
        let cls = NSClassFromString("AVOutputContext") as? NSObject.Type
        context = Self.call(cls, "defaultSharedOutputContext") ?? Self.call(cls, "iTunesAudioContext")
        guard let context else {
            routeLog.error("No AVOutputContext: AirPlay speaker groups are unavailable on this macOS")
            return
        }
        routeLog.notice("AirPlay output context \(self.contextID ?? "?", privacy: .public)")
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVOutputContextOutputDevicesDidChangeNotification"), object: context, queue: .main
        ) { [weak self] _ in
            routeLog.notice("AirPlay speakers now: \(self?.speakerNames.joined(separator: ", ") ?? "", privacy: .public)")
            NotificationCenter.default.post(name: Self.speakersDidChange, object: nil)
        }
    }

    /// Whether this macOS still has the pieces (the context, and the renderer and picker hooks).
    public var isAvailable: Bool {
        context != nil
            && AVSampleBufferAudioRenderer.instancesRespond(to: Selector(("setOutputContext:")))
            && AVRoutePickerView.instancesRespond(to: Selector(("setOutputContextID:")))
    }

    var contextID: String? {
        Self.call(context, "ID") ?? Self.call(context, "contextID")
    }

    /// The speakers chosen in the picker, by name ("Kitchen", "Living Room").
    public var speakerNames: [String] {
        guard let context else { return [] }
        var devices: [NSObject] = Self.call(context, "outputDevices") ?? []
        if devices.isEmpty, let one: NSObject = Self.call(context, "outputDevice") { devices = [one] }
        return devices.compactMap { device in
            Self.call(device, "name") ?? Self.call(device, "deviceName")
        }
    }

    /// Points the system AirPlay picker at this group, so its speaker list is multi-select and
    /// what's ticked there is what the pass-through plays to.
    @MainActor @discardableResult
    public func attach(picker: AVRoutePickerView) -> Bool {
        guard let contextID, picker.responds(to: Selector(("setOutputContextID:"))) else { return false }
        picker.perform(Selector(("setOutputContextID:")), with: contextID)
        return true
    }

    /// Sends a renderer's audio to the group instead of the Mac's output.
    func attach(renderer: AVSampleBufferAudioRenderer) -> Bool {
        guard let context, renderer.responds(to: Selector(("setOutputContext:"))) else { return false }
        renderer.perform(Selector(("setOutputContext:")), with: context)
        return true
    }

    /// Calls a getter (or class method) with no arguments that returns an object, if the receiver
    /// has it. KVC isn't used: a missing key would raise an exception Swift can't catch.
    private static func call<T>(_ receiver: NSObject?, _ selector: String) -> T? {
        let sel = Selector((selector))
        guard let receiver, receiver.responds(to: sel) else { return nil }
        return receiver.perform(sel)?.takeUnretainedValue() as? T
    }

    private static func call<T>(_ receiver: NSObject.Type?, _ selector: String) -> T? {
        let sel = Selector((selector))
        guard let receiver, receiver.responds(to: sel) else { return nil }
        return receiver.perform(sel)?.takeUnretainedValue() as? T
    }
}
