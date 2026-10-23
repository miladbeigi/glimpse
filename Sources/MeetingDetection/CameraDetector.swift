import CoreMediaIO
import Foundation

/// Reports whether any camera is streaming, via CoreMediaIO's
/// `kCMIODevicePropertyDeviceIsRunningSomewhere`. Asymmetric: camera ON signals a meeting and
/// vetoes end detection; camera OFF says nothing. No permission required.
public final class CameraDetector: @unchecked Sendable {
    public init() {}

    public func check() -> SignalState {
        let devices = Self.videoDeviceIDs()
        guard !devices.isEmpty else { return .unknown }
        for device in devices where Self.isRunningSomewhere(device) {
            return .active
        }
        return .inactive
    }

    private static func videoDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        status = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used, &ids)
        guard status == noErr else { return [] }
        return ids
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running)
        return status == noErr && running != 0
    }
}
