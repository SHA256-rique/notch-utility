import Foundation
import CoreAudio
import IOKit
import IOKit.graphics
import AudioToolbox
import AppKit
import Combine

/// System volume and display brightness, for the Sound & Light widget.
///
/// ## Volume: CoreAudio, not AppleScript
/// The lazy implementation is `osascript -e "set volume output volume 50"`.
/// That spawns a process, loads the AppleScript runtime and requires an Apple
/// Events entitlement prompt -- per adjustment, while the user is dragging a
/// slider. `AudioObjectSetPropertyData` on the default output device is a direct
/// call into coreaudiod with none of that.
///
/// We also register an **AudioObjectPropertyListener** rather than polling, so
/// pressing the hardware volume keys updates our slider without a timer.
///
/// ## Brightness: the honest situation
/// There is no public API to set display brightness. Three paths exist:
///   1. `IODisplayGetFloatParameter`/`IODisplaySetFloatParameter` on an
///      `IODisplayConnect` service. Works on Intel Macs and most external
///      displays. Returns nothing on Apple Silicon internal panels.
///   2. `DisplayServices.framework` (`DisplayServicesGetBrightness` /
///      `DisplayServicesSetBrightness`) -- private, but it is what works on
///      Apple Silicon internal displays.
///   3. Shelling out to `brightness` or similar -- rejected on the same grounds
///      as everything else in this codebase.
///
/// We try (2) via `dlopen` first and fall back to (1). Both are resolved at
/// runtime; if neither is available the widget hides its brightness row rather
/// than showing a dead slider. Linking a private framework at build time would
/// mean the whole app fails to launch the day Apple renames it.
@MainActor
final class SoundLightController: ObservableObject {
    static let shared = SoundLightController()

    @Published var volume: Float = 0.5
    @Published var isMuted: Bool = false
    @Published var brightness: Float = 0.5
    @Published private(set) var brightnessAvailable = false

    private var deviceID = AudioDeviceID(0)
    private var listenerInstalled = false
    private var isApplyingFromSystem = false

    // DisplayServices symbols, resolved lazily.
    private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var dsGet: DSGet?
    private var dsSet: DSSet?

    private init() {}

    // MARK: - Lifecycle (widget appear/disappear)

    func activate() {
        deviceID = Self.defaultOutputDevice()
        readVolumeFromSystem()
        resolveBrightness()
        readBrightnessFromSystem()
        installVolumeListener()
    }

    func deactivate() {
        removeVolumeListener()
    }

    // MARK: - Volume

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private func readVolumeFromSystem() {
        guard deviceID != 0 else { return }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(deviceID, &Self.volumeAddress, 0, nil, &size, &value) == noErr {
            isApplyingFromSystem = true
            volume = value
            isApplyingFromSystem = false
        }
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &Self.muteAddress, 0, nil, &muteSize, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    /// Called from the slider's onChange. The guard stops a feedback loop: the
    /// listener fires on our own write, which would otherwise set `volume`
    /// again mid-drag and make the knob stutter.
    func setVolume(_ newValue: Float) {
        guard !isApplyingFromSystem, deviceID != 0 else { return }
        var value = max(0, min(1, newValue))
        AudioObjectSetPropertyData(deviceID, &Self.volumeAddress, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
        if isMuted && value > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != 0 else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &Self.muteAddress, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    private func installVolumeListener() {
        guard deviceID != 0, !listenerInstalled else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(deviceID, &Self.volumeAddress, { _, _, _, ctx in
            guard let ctx else { return noErr }
            let controller = Unmanaged<SoundLightController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { controller.readVolumeFromSystem() }
            return noErr
        }, context)
        listenerInstalled = (status == noErr)
    }

    private func removeVolumeListener() {
        guard listenerInstalled, deviceID != 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(deviceID, &Self.volumeAddress, { _, _, _, _ in noErr }, context)
        listenerInstalled = false
    }

    // MARK: - Brightness

    private func resolveBrightness() {
        guard dsGet == nil else { return }
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let g = dlsym(handle, "DisplayServicesGetBrightness"),
               let s = dlsym(handle, "DisplayServicesSetBrightness") {
                dsGet = unsafeBitCast(g, to: DSGet.self)
                dsSet = unsafeBitCast(s, to: DSSet.self)
            }
        }
    }

    private func readBrightnessFromSystem() {
        let display = CGMainDisplayID()
        if let dsGet {
            var value: Float = 0
            if dsGet(display, &value) == 0 {
                brightness = value
                brightnessAvailable = true
                return
            }
        }
        if let value = IOKitBrightness.read() {
            brightness = value
            brightnessAvailable = true
            return
        }
        brightnessAvailable = false
    }

    func setBrightness(_ newValue: Float) {
        let clamped = max(0, min(1, newValue))
        if let dsSet, dsSet(CGMainDisplayID(), clamped) == 0 { return }
        IOKitBrightness.write(clamped)
    }
}

/// The IOKit fallback path. Split out so the DisplayServices path above reads
/// cleanly and so this can be deleted wholesale if Apple ever ships a public API.
private enum IOKitBrightness {
    private static func service() -> io_service_t {
        // IODisplayConnect is the legacy display-parameter service. It is empty
        // on Apple Silicon internal panels, which is exactly why DisplayServices
        // is tried first.
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
    }

    static func read() -> Float? {
        let svc = service()
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var value: Float = 0
        guard IODisplayGetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, &value) == KERN_SUCCESS else { return nil }
        return value
    }

    static func write(_ value: Float) {
        let svc = service()
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        IODisplaySetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, value)
    }
}
