import CoreAudio
import Foundation

enum SystemAudioStatus {
    static func isDefaultOutputMuted() -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr else {
            return false
        }
        return muted != 0
    }

    @discardableResult
    static func setDefaultOutputMuted(_ muted: Bool) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value = muted ? UInt32(1) : UInt32(0)
        return AudioObjectSetPropertyData(deviceID,
                                          &address,
                                          0,
                                          nil,
                                          UInt32(MemoryLayout<UInt32>.size),
                                          &value) == noErr
    }

    static func defaultOutputVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &address) {
            if let volume = readVolume(deviceID, &address) {
                return volume
            }
        }
        for channel in UInt32(1)...2 {
            address.mElement = AudioObjectPropertyElement(channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if let volume = readVolume(deviceID, &address) {
                return volume
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func readVolume(_ deviceID: AudioObjectID,
                                   _ address: inout AudioObjectPropertyAddress) -> Float? {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address,
                                         0,
                                         nil,
                                         &size,
                                         &deviceID) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
