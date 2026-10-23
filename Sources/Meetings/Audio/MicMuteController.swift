import Combine
import CoreAudio
import Foundation

/// System-wide microphone mute. Mutes the default input device at the CoreAudio level,
/// so every app (Google Meet, Zoom, Teams, …) receives silence regardless of which one is in
/// front. Uses the device's mute control when it has one, otherwise drops its input volume to
/// zero and restores it on unmute.
///
/// The meeting app's own mute state is untouched: participants see you as unmuted but hear
/// nothing.
@MainActor
final class MicMuteController: ObservableObject {
    static let shared = MicMuteController()

    @Published private(set) var isMuted = false

    private enum Method: String, Codable { case muteControl, volume }

    /// Persisted so a crash while muted can be undone on the next launch.
    private struct MuteState: Codable {
        var deviceUID: String
        var method: Method
        var previousVolumes: [UInt32: Float32]
    }

    private static let stateKey = "micMuteState"
    private var state: MuteState?
    private var mutedDevice: AudioObjectID?
    private var listenersInstalled = false
    private var deviceMuteListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?

    private init() {}

    // MARK: - Public

    func toggle() {
        isMuted ? unmute() : mute()
    }

    func mute() {
        guard !isMuted else { return }
        installDefaultDeviceListener()
        guard let device = Self.defaultInputDevice() else {
            log("❌ Mute failed: no default input device")
            return
        }
        guard let newState = Self.apply(mute: true, to: device) else {
            log("❌ Mute failed: \(Self.name(of: device)) has no mute or volume control")
            return
        }
        state = newState
        mutedDevice = device
        persist()
        watchHardwareMute(on: device)
        isMuted = true
        log("🔇 Microphone muted (\(Self.name(of: device)), \(newState.method.rawValue))")
    }

    func unmute() {
        guard isMuted else { return }
        if let device = mutedDevice, let state { Self.restore(state, on: device) }
        stopWatchingHardwareMute()
        state = nil
        mutedDevice = nil
        persist()
        isMuted = false
        log("🎤 Microphone unmuted")
    }

    /// Call at launch: undo a mute left behind by a crash or force-quit.
    func restoreLeftoverMute() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let leftover = try? JSONDecoder().decode(MuteState.self, from: data) else { return }
        if let device = Self.device(uid: leftover.deviceUID) {
            Self.restore(leftover, on: device)
            log("🎤 Restored microphone left muted by a previous session (\(Self.name(of: device)))")
        }
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
    }

    /// Call at quit so the mic is never left muted.
    func unmuteForQuit() {
        if isMuted { unmute() }
    }

    // MARK: - Device changes

    /// If the default input changes while muted (e.g. headset plugged in), move the mute to the
    /// new device so the user stays muted.
    private func installDefaultDeviceListener() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultInputChanged() }
        }
    }

    private func defaultInputChanged() {
        guard isMuted, let newDevice = Self.defaultInputDevice(), newDevice != mutedDevice else { return }
        if let old = mutedDevice, let state { Self.restore(state, on: old) }
        stopWatchingHardwareMute()
        if let newState = Self.apply(mute: true, to: newDevice) {
            state = newState
            mutedDevice = newDevice
            persist()
            watchHardwareMute(on: newDevice)
            log("🔇 Default input changed; mute moved to \(Self.name(of: newDevice))")
        } else {
            state = nil
            mutedDevice = nil
            persist()
            isMuted = false
            log("⚠️ Default input changed to \(Self.name(of: newDevice)), which can't be muted; microphone is live")
        }
    }

    /// Keep `isMuted` in sync when the device is unmuted elsewhere (e.g. the hardware mute
    /// button on a conference speaker, or Audio MIDI Setup).
    private func watchHardwareMute(on device: AudioObjectID) {
        guard state?.method == .muteControl else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isMuted, self.mutedDevice == device else { return }
                if Self.readMute(device) == false {
                    log("🎤 Microphone unmuted outside Glimpse")
                    self.stopWatchingHardwareMute()
                    self.state = nil
                    self.mutedDevice = nil
                    self.persist()
                    self.isMuted = false
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block) == noErr {
            deviceMuteListener = (device, block)
        }
    }

    private func stopWatchingHardwareMute() {
        guard let (device, block) = deviceMuteListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, block)
        deviceMuteListener = nil
    }

    private func persist() {
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
        }
        UserDefaults.standard.synchronize()
    }

    // MARK: - CoreAudio

    /// Elements to act on: the main element if it has the control, otherwise each channel.
    private static func elements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        if isSettable(device, selector, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...max(1, inputChannelCount(device))).map(UInt32.init).filter { isSettable(device, selector, $0) }
    }

    private static func apply(mute: Bool, to device: AudioObjectID) -> MuteState? {
        guard let uid = uid(of: device) else { return nil }
        let muteElements = elements(device, kAudioDevicePropertyMute)
        if !muteElements.isEmpty {
            var value: UInt32 = mute ? 1 : 0
            let ok = muteElements.allSatisfy { set(device, kAudioDevicePropertyMute, $0, &value) }
            if ok { return MuteState(deviceUID: uid, method: .muteControl, previousVolumes: [:]) }
        }
        let volumeElements = elements(device, kAudioDevicePropertyVolumeScalar)
        guard !volumeElements.isEmpty else { return nil }
        var previous: [UInt32: Float32] = [:]
        for el in volumeElements {
            var v: Float32 = 0
            if get(device, kAudioDevicePropertyVolumeScalar, el, &v) { previous[el] = v }
            var zero: Float32 = 0
            _ = set(device, kAudioDevicePropertyVolumeScalar, el, &zero)
        }
        return MuteState(deviceUID: uid, method: .volume, previousVolumes: previous)
    }

    private static func restore(_ state: MuteState, on device: AudioObjectID) {
        switch state.method {
        case .muteControl:
            var zero: UInt32 = 0
            for el in elements(device, kAudioDevicePropertyMute) { _ = set(device, kAudioDevicePropertyMute, el, &zero) }
        case .volume:
            for (el, v) in state.previousVolumes {
                var value = v > 0 ? v : 0.75
                _ = set(device, kAudioDevicePropertyVolumeScalar, el, &value)
            }
        }
    }

    static func readMute(_ device: AudioObjectID) -> Bool? {
        var v: UInt32 = 0
        return get(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, &v) ? v != 0 : nil
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func allDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(uid: String) -> AudioObjectID? {
        allDevices().first { self.uid(of: $0) == uid }
    }

    private static func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uid(of device: AudioObjectID) -> String? { stringProperty(device, kAudioDevicePropertyDeviceUID) }
    static func name(of device: AudioObjectID) -> String { stringProperty(device, kAudioObjectPropertyName) ?? "input device" }

    private static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    private static func get<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) } == noErr
    }

    private static func set<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &addr, 0, nil, size, $0) } == noErr
    }
}
