import CoreAudio

struct AudioDeviceInfo: Identifiable, Equatable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    var id: String { uid }

    static var systemDefault: AudioDeviceInfo {
        AudioDeviceInfo(
            deviceID: AudioDeviceID(kAudioObjectUnknown),
            uid: "",
            name: NSLocalizedString("System Default", comment: "FDD output device picker — follow system audio output")
        )
    }
}

enum AudioDeviceList {
    /// 出力ストリームを持つデバイス一覧。先頭は systemDefault。
    static func outputDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else {
            return [.systemDefault]
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return [.systemDefault]
        }

        var result: [AudioDeviceInfo] = [.systemDefault]
        for deviceID in deviceIDs {
            guard isOutputDevice(deviceID),
                  let uid = deviceUID(deviceID),
                  let name = deviceName(deviceID),
                  !isInternalVirtualDevice(uid: uid) else { continue }
            result.append(AudioDeviceInfo(deviceID: deviceID, uid: uid, name: name))
        }
        return result
    }

    /// UID から AudioDeviceID を解決する。デバイスが見つからなければ nil。
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        // CoreAudio は qualifier に CFStringRef*（ポインタのポインタ）を要求する。
        // withUnsafePointer(to: &cfUID) で変数のアドレスを渡すことで CFStringRef* になる。
        var cfUID: CFString = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeRawPointer(ptr),
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// CoreAudio が内部で作る仮想デバイスを除外する。
    /// CADefaultDeviceAggregate など UID が "CADefaultDevice" で始まるものは
    /// ユーザーが選択できない内部デバイスで、設定すると不安定になる。
    private static func isInternalVirtualDevice(uid: String) -> Bool {
        uid.hasPrefix("CADefaultDevice")
    }

    private static func isOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfRef) == noErr else { return nil }
        return cfRef?.takeRetainedValue() as String?
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfRef) == noErr else { return nil }
        return cfRef?.takeRetainedValue() as String?
    }
}
