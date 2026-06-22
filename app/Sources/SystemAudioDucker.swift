import CoreAudio
import Foundation
import OSLog

final class SystemAudioDucker {
    private static let logger = Logger(subsystem: "fluid-push-to-talk", category: "SystemAudioDucker")

    private enum Mode {
        case coreAudio
        case appleScript
        case outputDeviceSwitch
    }

    private struct SavedState {
        var mode: Mode
        var deviceID: AudioDeviceID
        var muteMain: UInt32?
        var volumes: [UInt32: Float32]
        var scriptMuted: Bool?
        var scriptVolume: Int?
        var previousDefaultOutputDeviceID: AudioDeviceID?
    }

    private let lock = NSLock()
    private var saved: SavedState?

    func begin() {
        lock.lock()
        defer { lock.unlock() }

        guard saved == nil else { return }

        var defaultDeviceIsSettable = true
        if let defaultID = Self.defaultOutputDeviceID() {
            let name = Self.deviceName(deviceID: defaultID) ?? "unknown"
            let builtIn = Self.isBuiltIn(deviceID: defaultID)
            let settable = Self.hasSettableMuteOrVolume(deviceID: defaultID)
            defaultDeviceIsSettable = settable
            Self.logger.notice("Default output device: \(defaultID, privacy: .public) (\(name, privacy: .public)) builtIn=\(builtIn, privacy: .public) settableMuteOrVol=\(settable, privacy: .public)")
        }

        if let state = Self.tryBeginCoreAudio() {
            saved = state
            Self.logger.notice("Engaged via CoreAudio")
            return
        }

        // If the current device doesn't support software volume/mute, AppleScript "set volume"
        // often reports success but does not affect the actual output. Prefer device switching then.
        if defaultDeviceIsSettable {
            if let state = Self.tryBeginAppleScript() {
                saved = state
                Self.logger.notice("Engaged via AppleScript")
                return
            }
        }

        if let state = Self.tryBeginOutputDeviceSwitch() {
            saved = state
            let name = Self.deviceName(deviceID: state.deviceID) ?? "unknown"
            Self.logger.notice("Switched output to: \(state.deviceID, privacy: .public) (\(name, privacy: .public))")
            Self.logger.notice("Engaged via output device switch")
            return
        }

        Self.logger.error("Could not engage (no supported mute/volume controls)")
    }

    func end() {
        lock.lock()
        let state = saved
        saved = nil
        lock.unlock()

        guard let state else { return }

        switch state.mode {
        case .coreAudio:
            if let muteMain = state.muteMain {
                _ = Self.setMute(deviceID: state.deviceID, element: kAudioObjectPropertyElementMain, value: muteMain)
            }

            for (element, volume) in state.volumes {
                _ = Self.setVolumeScalar(deviceID: state.deviceID, element: element, value: volume)
            }

        case .appleScript:
            if let muted = state.scriptMuted {
                _ = Self.setMutedAppleScript(muted)
            }
            if let volume = state.scriptVolume {
                _ = Self.setOutputVolumeAppleScript(volume)
            }

        case .outputDeviceSwitch:
            if let previousDevice = state.previousDefaultOutputDeviceID {
                _ = Self.setDefaultOutputDeviceID(previousDevice)
            }
            if let muteMain = state.muteMain {
                _ = Self.setMute(deviceID: state.deviceID, element: kAudioObjectPropertyElementMain, value: muteMain)
            }
            for (element, volume) in state.volumes {
                _ = Self.setVolumeScalar(deviceID: state.deviceID, element: element, value: volume)
            }
        }
    }

    private static func tryBeginCoreAudio() -> SavedState? {
        guard let deviceID = Self.defaultOutputDeviceID() else { return nil }

        var volumes: [UInt32: Float32] = [:]
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            if let v = Self.getVolumeScalar(deviceID: deviceID, element: element) {
                volumes[element] = v
            }
        }

        let muteMain = Self.getMute(deviceID: deviceID, element: kAudioObjectPropertyElementMain)

        var didApply = false

        if let _ = muteMain, Self.setMute(deviceID: deviceID, element: kAudioObjectPropertyElementMain, value: 1) {
            didApply = true
        } else {
            for element in [1, 2] as [UInt32] {
                if let _ = Self.getMute(deviceID: deviceID, element: element),
                   Self.setMute(deviceID: deviceID, element: element, value: 1) {
                    didApply = true
                }
            }
        }

        for element in volumes.keys {
            if Self.setVolumeScalar(deviceID: deviceID, element: element, value: 0) {
                didApply = true
            }
        }

        guard didApply else { return nil }

        // Verify that at least one output control actually changed.
        var verified = false
        if let mute = Self.getMute(deviceID: deviceID, element: kAudioObjectPropertyElementMain), mute == 1 {
            verified = true
        }
        if !verified {
            for element in volumes.keys {
                if let v = Self.getVolumeScalar(deviceID: deviceID, element: element), v <= 0.001 {
                    verified = true
                    break
                }
            }
        }
        guard verified else { return nil }

        return SavedState(
            mode: .coreAudio,
            deviceID: deviceID,
            muteMain: muteMain,
            volumes: volumes,
            scriptMuted: nil,
            scriptVolume: nil
            ,
            previousDefaultOutputDeviceID: nil
        )
    }

    private static func tryBeginAppleScript() -> SavedState? {
        guard let priorVolume = Self.getOutputVolumeAppleScript() else { return nil }
        let priorMuted = Self.getMutedAppleScript()

        guard Self.setMutedAppleScript(true) || Self.setOutputVolumeAppleScript(0) else { return nil }
        _ = Self.setOutputVolumeAppleScript(0)

        // Verify
        let mutedNow = Self.getMutedAppleScript()
        let volumeNow = Self.getOutputVolumeAppleScript()
        Self.logger.notice("AppleScript volume: \(priorVolume, privacy: .public) -> \(volumeNow ?? -1, privacy: .public), muted: \(String(describing: priorMuted), privacy: .public) -> \(String(describing: mutedNow), privacy: .public)")
        guard mutedNow == true || volumeNow == 0 else { return nil }

        return SavedState(
            mode: .appleScript,
            deviceID: 0,
            muteMain: nil,
            volumes: [:],
            scriptMuted: priorMuted,
            scriptVolume: priorVolume
            ,
            previousDefaultOutputDeviceID: nil
        )
    }

    private static func tryBeginOutputDeviceSwitch() -> SavedState? {
        guard let currentDefault = Self.defaultOutputDeviceID() else { return nil }
        guard let alternative = Self.findMuteCapableOutputDevice(excluding: currentDefault) else { return nil }
        guard Self.setDefaultOutputDeviceID(alternative) else { return nil }

        var volumes: [UInt32: Float32] = [:]
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            if let v = Self.getVolumeScalar(deviceID: alternative, element: element) {
                volumes[element] = v
            }
        }
        let muteMain = Self.getMute(deviceID: alternative, element: kAudioObjectPropertyElementMain)

        var didApply = false
        if let _ = muteMain, Self.setMute(deviceID: alternative, element: kAudioObjectPropertyElementMain, value: 1) {
            didApply = true
        }
        for element in volumes.keys {
            if Self.setVolumeScalar(deviceID: alternative, element: element, value: 0) {
                didApply = true
            }
        }
        guard didApply else {
            _ = Self.setDefaultOutputDeviceID(currentDefault)
            return nil
        }

        return SavedState(
            mode: .outputDeviceSwitch,
            deviceID: alternative,
            muteMain: muteMain,
            volumes: volumes,
            scriptMuted: nil,
            scriptVolume: nil,
            previousDefaultOutputDeviceID: currentDefault
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    @discardableResult
    private static func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject), &address, &settable) == noErr,
              settable.boolValue
        else { return false }

        var d = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &d
        )
        return status == noErr
    }

    private static func findMuteCapableOutputDevice(excluding excluded: AudioDeviceID) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        // Prefer built-in, otherwise first mute/volume-settable output device.
        var bestBuiltIn: AudioDeviceID?
        var bestAny: AudioDeviceID?

        for device in devices where device != 0 && device != excluded {
            guard hasOutputChannels(deviceID: device) else { continue }

            let hasSettable = hasSettableMuteOrVolume(deviceID: device)
            guard hasSettable else { continue }

            if bestAny == nil { bestAny = device }
            if isBuiltIn(deviceID: device) { bestBuiltIn = device; break }
        }

        return bestBuiltIn ?? bestAny
    }

    private static func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }

        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr) == noErr else { return false }
        let bufferListPtr = ptr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        return buffers.contains(where: { $0.mNumberChannels > 0 })
    }

    private static func hasSettableMuteOrVolume(deviceID: AudioDeviceID) -> Bool {
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

        for element in elements {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &muteAddr) {
                var settable = DarwinBoolean(false)
                if AudioObjectIsPropertySettable(deviceID, &muteAddr, &settable) == noErr, settable.boolValue {
                    return true
                }
            }

            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &volAddr) {
                var settable = DarwinBoolean(false)
                if AudioObjectIsPropertySettable(deviceID, &volAddr, &settable) == noErr, settable.boolValue {
                    return true
                }
            }
        }

        return false
    }

    private static func isBuiltIn(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value == kAudioDeviceTransportTypeBuiltIn
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeUnretainedValue() else { return nil }
        return name as String
    }

    private static func getMute(deviceID: AudioDeviceID, element: UInt32) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setMute(deviceID: AudioDeviceID, element: UInt32, value: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
            return false
        }

        var v = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &v)
        return status == noErr
    }

    private static func getVolumeScalar(deviceID: AudioDeviceID, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setVolumeScalar(deviceID: AudioDeviceID, element: UInt32, value: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
            return false
        }

        var v = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &v)
        return status == noErr
    }

    private static func runAppleScript(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let out = Pipe()
        task.standardOutput = out
        let err = Pipe()
        task.standardError = err

        do {
            try task.run()
        } catch {
            logger.error("AppleScript failed to start: \(String(describing: error), privacy: .public)")
            return nil
        }

        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.error("AppleScript failed (status=\(task.terminationStatus, privacy: .public)): \(errStr, privacy: .public)")
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func getOutputVolumeAppleScript() -> Int? {
        guard let s = runAppleScript("output volume of (get volume settings)") else { return nil }
        return Int(s)
    }

    @discardableResult
    private static func setOutputVolumeAppleScript(_ volume: Int) -> Bool {
        runAppleScript("set volume output volume \(max(0, min(100, volume)))") != nil
    }

    private static func getMutedAppleScript() -> Bool? {
        guard let s = runAppleScript("output muted of (get volume settings)") else { return nil }
        return s.lowercased() == "true"
    }

    @discardableResult
    private static func setMutedAppleScript(_ muted: Bool) -> Bool {
        runAppleScript("set volume output muted \(muted ? "true" : "false")") != nil
    }
}
