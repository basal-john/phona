import CoreAudio
import Foundation

/// Silences whatever else is playing for as long as the microphone is capturing.
///
/// Music, a video in a browser tab or a voice on a call all reach the microphone through the
/// room, and the transcriber has no way to tell that speech apart from yours. It hears both
/// and writes down whichever it finds more convincing.
///
/// Muting the output device rather than pausing individual players is what makes this work
/// for every source. There is no macOS API to duck other applications, and pausing means
/// knowing every app that could be playing, which is not a list that can be written down.
///
/// Three ways to silence a device, tried in order, because they are not all available on
/// every one. Most built-in and USB outputs carry a mute control. Some, including a good
/// number of Bluetooth and aggregate devices, carry only a volume control, either one for
/// the device or one per channel. Whichever worked is what gets restored, and a device that
/// offers none of the three is left alone rather than half-set.
enum OutputMute {
    /// What was taken away, and therefore what has to be given back.
    ///
    /// Recorded against the device UID rather than its id, because ids are handed out afresh
    /// on every boot and this has to survive one.
    private struct Restore: Codable {
        let uid: String
        var mute: UInt32?
        var volume: Float32?
        var channels: [String: Float32]?
    }

    /// Written the moment the device is muted and cleared the moment it is restored.
    ///
    /// A crash between those two points would otherwise leave the Mac silent with nothing on
    /// screen to explain it and no obvious way back, since the user did not mute anything.
    /// Whatever is left here is put back at the next launch.
    private static let crashKey = "outputMuteRestore"

    private static var held: Restore?

    /// Mute the current output device, remembering what it was set to.
    ///
    /// Called when the first audio buffer arrives rather than when the key goes down, so the
    /// start cue is still audible and everything that actually reaches the recording is
    /// already quiet.
    static func engage() {
        guard held == nil, Settings.muteOthersWhileDictating else { return }
        guard let device = defaultOutput(), let uid = uid(of: device) else { return }

        var restore = Restore(uid: uid)

        var mute = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        if settable(device, &mute), let previous = readUInt32(device, &mute) {
            if previous == 1 { return }
            guard write(device, &mute, UInt32(1)) else { return }
            restore.mute = previous
            commit(restore)
            return
        }

        var main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        if settable(device, &main), let previous = readFloat(device, &main) {
            if previous == 0 { return }
            guard write(device, &main, Float32(0)) else { return }
            restore.volume = previous
            commit(restore)
            return
        }

        var levels: [String: Float32] = [:]
        for channel in stereoChannels(of: device) {
            var perChannel = address(kAudioDevicePropertyVolumeScalar, channel)
            guard settable(device, &perChannel),
                  let previous = readFloat(device, &perChannel),
                  write(device, &perChannel, Float32(0))
            else { continue }
            levels["\(channel)"] = previous
        }
        guard !levels.isEmpty else {
            Paths.log("output device \(uid) offers no mute or volume control, leaving it alone")
            return
        }
        restore.channels = levels
        commit(restore)
    }

    /// Put the output device back exactly as it was found.
    static func release() {
        guard let restore = held else { return }
        held = nil
        UserDefaults.standard.removeObject(forKey: crashKey)
        apply(restore)
    }

    /// Undo a mute that a crash or a force quit left in place.
    static func recoverFromInterruptedDictation() {
        guard let data = UserDefaults.standard.data(forKey: crashKey),
              let restore = try? JSONDecoder().decode(Restore.self, from: data)
        else { return }
        UserDefaults.standard.removeObject(forKey: crashKey)
        Paths.log("restoring output volume left muted by an interrupted dictation")
        apply(restore)
    }

    /// `PhonaApp --check-mute` mutes and restores the real device once, and says what it
    /// touched.
    ///
    /// Worth a flag of its own because a mistake in here leaves the Mac silent with nothing
    /// connecting the silence to a dictation, and because which of the three controls a
    /// device offers cannot be known without asking that device.
    static func report() {
        guard let device = defaultOutput(), let deviceUID = uid(of: device) else {
            print("no default output device")
            return
        }
        print("device       \(deviceUID)")
        print("mute_others  \(Settings.muteOthersWhileDictating)")
        print("before       \(state(of: device))")
        engage()
        print("engaged      \(state(of: device))   using \(held.map(control) ?? "nothing")")
        release()
        print("after        \(state(of: device))")
    }

    private static func state(of device: AudioDeviceID) -> String {
        var mute = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        var main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        let muted = readUInt32(device, &mute).map(String.init) ?? "n/a"
        let volume = readFloat(device, &main).map { String(format: "%.3f", $0) } ?? "n/a"
        let perChannel = stereoChannels(of: device).map { channel -> String in
            var a = address(kAudioDevicePropertyVolumeScalar, channel)
            return readFloat(device, &a).map { String(format: "%.3f", $0) } ?? "n/a"
        }
        return "mute=\(muted) volume=\(volume) channels=[\(perChannel.joined(separator: ", "))]"
    }

    private static func control(_ restore: Restore) -> String {
        if restore.mute != nil { return "the mute control" }
        if restore.volume != nil { return "the device volume" }
        if restore.channels != nil { return "the channel volumes" }
        return "nothing"
    }

    private static func commit(_ restore: Restore) {
        held = restore
        if let data = try? JSONEncoder().encode(restore) {
            UserDefaults.standard.set(data, forKey: crashKey)
        }
    }

    private static func apply(_ restore: Restore) {
        guard let device = device(withUID: restore.uid) else { return }
        if let previous = restore.mute {
            var mute = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
            _ = write(device, &mute, previous)
        }
        if let previous = restore.volume {
            var main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
            _ = write(device, &main, previous)
        }
        for (channel, previous) in restore.channels ?? [:] {
            guard let element = AudioObjectPropertyElement(channel) else { continue }
            var perChannel = address(kAudioDevicePropertyVolumeScalar, element)
            _ = write(device, &perChannel, previous)
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ element: AudioObjectPropertyElement)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func device(withUID wanted: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr
        else { return nil }
        return devices.first { uid(of: $0) == wanted }
    }

    /// The two elements a stereo device exposes its volume on, when it has no single control.
    private static func stereoChannels(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = address(kAudioDevicePropertyPreferredChannelsForStereo,
                              kAudioObjectPropertyElementMain)
        var pair: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair) == noErr else {
            return [1, 2]
        }
        return [pair.0, pair.1]
    }

    private static func settable(_ device: AudioDeviceID,
                                 _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var writable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &writable) == noErr else {
            return false
        }
        return writable.boolValue
    }

    private static func readUInt32(_ device: AudioDeviceID,
                                   _ address: inout AudioObjectPropertyAddress) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readFloat(_ device: AudioDeviceID,
                                  _ address: inout AudioObjectPropertyAddress) -> Float32? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func write(_ device: AudioDeviceID,
                              _ address: inout AudioObjectPropertyAddress,
                              _ value: UInt32) -> Bool {
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func write(_ device: AudioDeviceID,
                              _ address: inout AudioObjectPropertyAddress,
                              _ value: Float32) -> Bool {
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
