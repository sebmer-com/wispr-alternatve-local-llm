import CoreAudio
import Foundation

struct AudioInputDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32
    let inputChannels: UInt32
    let nominalSampleRate: Double
    let isDefault: Bool

    var summary: String {
        let uidPart = uid.isEmpty ? "no uid" : uid
        let defaultPart = isDefault ? ", default" : ""
        return "\(name) (\(transportDisplayName), \(inputChannels) ch, \(Int(nominalSampleRate)) Hz, \(uidPart)\(defaultPart))"
    }

    private var transportDisplayName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        default:
            return fourCharacterCode(transportType)
        }
    }

    private func fourCharacterCode(_ value: UInt32) -> String {
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let text = String(bytes: scalars, encoding: .macOSRoman) ?? "\(value)"
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(value)" : text
    }
}

enum AudioInputDevices {
    static func resolve(config: AudioInputConfig) throws -> AudioInputDeviceInfo {
        let uid = config.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = allInputDevices()

        if !uid.isEmpty {
            guard let device = devices.first(where: { $0.uid == uid }) else {
                throw CliError.invalidValue("configured audio_input.device_uid was not found: \(uid)")
            }
            return device
        }

        if !name.isEmpty {
            guard let device = devices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name) || $0.uid.localizedCaseInsensitiveContains(name)
            }) else {
                throw CliError.invalidValue("configured audio_input.device_name was not found: \(name)")
            }
            return device
        }

        if let defaultID = defaultInputDeviceID(),
           let device = info(for: defaultID),
           device.inputChannels > 0 {
            return device
        }

        guard let first = devices.first else {
            throw CliError.invalidValue("no usable audio input device found")
        }
        return first
    }

    static func allInputDevices() -> [AudioInputDeviceInfo] {
        let defaultID = defaultInputDeviceID()
        return allDeviceIDs()
            .compactMap { info(for: $0, defaultID: defaultID) }
            .filter { $0.inputChannels > 0 }
            .sorted {
                if $0.isDefault != $1.isDefault {
                    return $0.isDefault
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func info(for deviceID: AudioDeviceID) -> AudioInputDeviceInfo? {
        info(for: deviceID, defaultID: defaultInputDeviceID())
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else {
            return []
        }
        return devices.filter { $0 != 0 }
    }

    private static func info(for deviceID: AudioDeviceID, defaultID: AudioDeviceID?) -> AudioInputDeviceInfo? {
        let inputChannels = inputChannelCount(deviceID: deviceID)
        guard inputChannels > 0 else {
            return nil
        }
        return AudioInputDeviceInfo(
            id: deviceID,
            name: stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Audio Device \(deviceID)",
            uid: stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "",
            transportType: uint32Property(deviceID: deviceID, selector: kAudioDevicePropertyTransportType) ?? 0,
            inputChannels: inputChannels,
            nominalSampleRate: doubleProperty(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0,
            isDefault: defaultID == deviceID
        )
    }

    private static func inputChannelCount(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return 0
        }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPointer) == noErr else {
            return 0
        }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value?.takeUnretainedValue() as String? : nil
    }

    private static func uint32Property(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func doubleProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }
        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
