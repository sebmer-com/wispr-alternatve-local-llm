import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import AudioToolbox
import Darwin
import FluidAudio
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RecordingCapture {
    let url: URL?
    let fileCreated: Bool
    let frameCount: AVAudioFramePosition
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let peakAmplitude: Float

    var duration: TimeInterval {
        guard sampleRate > 0 else {
            return 0
        }
        return TimeInterval(frameCount) / sampleRate
    }

    var peakDescription: String {
        guard peakAmplitude > 0 else {
            return "-inf dBFS"
        }
        return String(format: "%.1f dBFS", 20 * log10(Double(peakAmplitude)))
    }

    var summary: String {
        "\(formatSeconds(duration)), \(frameCount) frames, \(channelCount) ch, \(Int(sampleRate)) Hz, peak \(peakDescription)"
    }
}

struct DeliveryTiming {
    let startedAt: Date
    let audioDuration: TimeInterval

    func summary(delivery: String, completedAt: Date = Date()) -> String {
        let elapsed = completedAt.timeIntervalSince(startedAt)
        let overhead = max(0, elapsed - audioDuration)
        return "latency \(delivery): audio \(formatSeconds(audioDuration)), end-to-end \(formatSeconds(elapsed)), overhead \(formatSeconds(overhead))"
    }
}

private final class MicrophonePermissionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false

    func set(_ value: Bool) {
        lock.withLock {
            granted = value
        }
    }

    func get() -> Bool {
        lock.withLock {
            granted
        }
    }
}

final class AudioRecorder: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let audioInput: AudioInputConfig
    private let lock = NSLock()
    private let minimumTranscribableFrames: AVAudioFramePosition = 3_200
    private let maxRecordingDuration: TimeInterval = 300
    private let minimumRestartDelay: TimeInterval = 0.35
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var recordingStartedAt: Date?
    private var recording = false
    private var recordingToken = UUID()
    private var lastStopUptime: TimeInterval = 0
    private var peakPower: Float = -160

    init(audioInput: AudioInputConfig = AudioInputConfig()) {
        self.audioInput = audioInput
    }

    var isRecording: Bool {
        lock.withLock { recording }
    }

    func start(usesWatchdog: Bool = true) throws {
        try ensureMicrophonePermission()
        waitForRestartCooldown()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid_ptt_\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let token = lock.withLock {
            guard !recording else {
                return nil as UUID?
            }
            recording = true
            currentURL = url
            recordingStartedAt = Date()
            peakPower = -160
            let token = UUID()
            recordingToken = token
            return token
        }
        guard let token else {
            return
        }

        do {
            let recorder = try makePreparedRecorder(url: url)
            guard recorder.record() else {
                failStart(recorder: recorder, url: url)
                throw CliError.invalidValue("audio recorder returned false when starting capture")
            }
            lock.withLock {
                self.recorder = recorder
            }
        } catch {
            failStart(recorder: nil, url: url)
            throw error
        }
        if usesWatchdog {
            scheduleWatchdog(for: token)
        }
    }

    private func ensureMicrophonePermission() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let result = MicrophonePermissionResult()
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                result.set(allowed)
                semaphore.signal()
            }
            semaphore.wait()
            guard result.get() else {
                throw microphonePermissionError()
            }
        case .denied, .restricted:
            throw microphonePermissionError()
        @unknown default:
            throw microphonePermissionError()
        }
    }

    private func microphonePermissionError() -> CliError {
        CliError.invalidValue(
            "microphone permission is required. Open System Settings > Privacy & Security > Microphone and enable Terminal or fluid-push-to-talk."
        )
    }

    private func waitForRestartCooldown() {
        let sinceStop = ProcessInfo.processInfo.systemUptime - lastStopUptime
        guard sinceStop < minimumRestartDelay else {
            return
        }
        Thread.sleep(forTimeInterval: minimumRestartDelay - sinceStop)
    }

    private func makePreparedRecorder(url: URL) throws -> AVAudioRecorder {
        if let inputDevice = try? AudioInputDevices.resolve(config: audioInput) {
            log("audio input device: \(inputDevice.summary)")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            throw CliError.invalidValue("audio recorder could not prepare microphone capture")
        }
        log("audio input format: 1 ch, 44100 Hz, AAC")
        return recorder
    }

    private func failStart(recorder: AVAudioRecorder?, url: URL) {
        recorder?.stop()
        lock.withLock {
            if currentURL == url {
                recording = false
                recordingStartedAt = nil
                currentURL = nil
                self.recorder = nil
            }
        }
        lastStopUptime = ProcessInfo.processInfo.systemUptime
        try? FileManager.default.removeItem(at: url)
    }

    func stop() -> URL? {
        stopInternal(reason: nil)
    }

    private func stopInternal(reason: String?) -> URL? {
        lock.lock()
        guard recording else {
            lock.unlock()
            return nil
        }
        recording = false
        let recorder = self.recorder
        let url = currentURL
        self.recorder = nil
        currentURL = nil
        recordingStartedAt = nil
        lock.unlock()

        if let recorder {
            recorder.updateMeters()
            peakPower = max(peakPower, recorder.peakPower(forChannel: 0))
            recorder.stop()
        }
        lastStopUptime = ProcessInfo.processInfo.systemUptime

        guard let url else {
            log("recording skipped: recorder returned no capture URL")
            return nil
        }

        if let reason {
            log("recording stopped: \(reason)")
        }
        guard let capture = captureMetadata(url: url) else {
            log("recording skipped: no audio file captured")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if !capture.fileCreated {
            log("recording skipped: no audio file captured")
            return nil
        }
        log("recording captured: \(capture.summary)")
        guard capture.frameCount >= minimumTranscribableFrames else {
            log("recording skipped: too short for transcription (\(capture.summary))")
            if let url = capture.url {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }
        return capture.url
    }

    private func scheduleWatchdog(for token: UUID) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maxRecordingDuration) { [weak self] in
            guard let self else {
                return
            }
            let shouldStop = self.lock.withLock {
                self.recording && self.recordingToken == token
            }
            guard shouldStop else {
                return
            }
            _ = self.stopInternal(reason: "exceeded \(Int(self.maxRecordingDuration)) seconds")
        }
    }

    private func captureMetadata(url: URL) -> RecordingCapture? {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return RecordingCapture(
                url: url,
                fileCreated: false,
                frameCount: 0,
                sampleRate: 0,
                channelCount: 0,
                peakAmplitude: 0
            )
        }
        return RecordingCapture(
            url: url,
            fileCreated: true,
            frameCount: file.length,
            sampleRate: file.fileFormat.sampleRate,
            channelCount: file.fileFormat.channelCount,
            peakAmplitude: Self.amplitude(fromPeakPower: peakPower)
        )
    }

    private static func amplitude(fromPeakPower power: Float) -> Float {
        guard power.isFinite, power > -160 else {
            return 0
        }
        return pow(10, power / 20)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else {
            return
        }
        fputs("recording failed: AVAudioRecorder finished unsuccessfully\n", stderr)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        fputs("recording encode error: \(error?.localizedDescription ?? "unknown")\n", stderr)
    }
}

actor FluidTranscriber {
    private let manager = AsrManager(config: .default)
    private var decoderState = TdtDecoderState.make()
    private var language: Language?
    private let minimumTranscribableFrames: AVAudioFramePosition = 3_200

    func prepare(modelVersion: String, language: String) async throws {
        self.language = language == "auto" ? nil : Language(rawValue: language)
        let version: AsrModelVersion = modelVersion == "v2" ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(version: version)
        try await manager.loadModels(models)
        decoderState = TdtDecoderState.make()
    }

    func transcribe(url: URL) async throws -> String {
        let metadata = try audioFileMetadata(url: url)
        guard metadata.frameCount >= minimumTranscribableFrames else {
            throw CliError.invalidValue("audio file too short for transcription: \(metadata.summary), path \(url.path)")
        }
        var state = decoderState
        do {
            let result = try await manager.transcribe(
                url,
                decoderState: &state,
                language: language
            )
            decoderState = TdtDecoderState.make()
            return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        } catch {
            decoderState = TdtDecoderState.make()
            throw CliError.invalidValue("ASR rejected audio: \(metadata.summary), path \(url.path), error \(error)")
        }
    }

    private func audioFileMetadata(url: URL) throws -> RecordingCapture {
        let file = try AVAudioFile(forReading: url)
        return RecordingCapture(
            url: url,
            fileCreated: true,
            frameCount: file.length,
            sampleRate: file.fileFormat.sampleRate,
            channelCount: file.fileFormat.channelCount,
            peakAmplitude: 0
        )
    }
}

final class PasteboardTyper: @unchecked Sendable {
    private let pasteDelay: TimeInterval
    private let restoreClipboard: Bool
    private let restoreClipboardDelay: TimeInterval

    init(
        pasteDelay: TimeInterval,
        restoreClipboard: Bool,
        restoreClipboardDelay: TimeInterval
    ) {
        self.pasteDelay = pasteDelay
        self.restoreClipboard = restoreClipboard
        self.restoreClipboardDelay = restoreClipboardDelay
    }

    func paste(_ text: String) {
        let textToPaste = Self.withTrailingSpace(text)
        let pasteboard = NSPasteboard.general
        let previousText = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(textToPaste, forType: .string)

        Thread.sleep(forTimeInterval: pasteDelay)
        sendCommandV()

        guard restoreClipboard, let previousText else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreClipboardDelay) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(previousText, forType: .string)
        }
    }

    static func withTrailingSpace(_ text: String) -> String {
        guard let last = text.last else {
            return text
        }
        guard !last.isWhitespace else {
            return text
        }
        return text + " "
    }

    private func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeForV: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForV, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

final class PushToTalkController: @unchecked Sendable {
    private let options: Options
    private let recorder: AudioRecorder
    private let transcriber: FluidTranscriber
    private let typer: PasteboardTyper
    private let dumper: MarkdownDumper
    private let bluetoothKeyboard: BluetoothKeyboardOutput
    private let commandGenerator: CommandResultGenerator
    private let hermesRunner: HermesAgentRunner
    private let llmReadinessMonitor: LocalLLMReadinessMonitor
    private let textReplacer: TextReplacementService
    private let audioDucker = SystemAudioDucker()
    private let stateQueue = DispatchQueue(label: "fluid-push-to-talk.state")
    private let hermesJobQueue = DispatchQueue(label: "fluid-push-to-talk.hermes-jobs")
    private let hermesJobIDLock = NSLock()
    private let commandModeGrace: TimeInterval = 0.15
    private var recordingState = RecordingState.idle
    private var transcribing = false
    private var nextHermesJobID = 1
    private var pendingContinuation: DispatchWorkItem?
    private var pendingHermesContinuation: DispatchWorkItem?
    private var audioDuckingActive = false
    private var activeInteractionStartedAt: Date?
    private var activeInteractionTargetBundleIdentifier: String?
    private var activeAudioDuration: TimeInterval = 0
    private var continuousDumpActive = false

    init(
        options: Options,
        recorder: AudioRecorder,
        transcriber: FluidTranscriber,
        typer: PasteboardTyper,
        dumper: MarkdownDumper,
        bluetoothKeyboard: BluetoothKeyboardOutput,
        commandGenerator: CommandResultGenerator,
        llmReadinessMonitor: LocalLLMReadinessMonitor
    ) {
        self.options = options
        self.recorder = recorder
        self.transcriber = transcriber
        self.typer = typer
        self.dumper = dumper
        self.bluetoothKeyboard = bluetoothKeyboard
        self.commandGenerator = commandGenerator
        hermesRunner = HermesAgentRunner(config: options.config.hermesAgent)
        self.llmReadinessMonitor = llmReadinessMonitor
        textReplacer = TextReplacementService(config: options.config.textReplacements)
    }

    func handle(flags: CGEventFlags) {
        stateQueue.async {
            self.handleFlags(flags)
        }
    }

    func handleBluetoothChord(isPressed: Bool) {
        stateQueue.async {
            self.handleBluetoothChordLocked(isPressed: isPressed)
        }
    }

    private func handleFlags(_ flags: CGEventFlags) {
        guard !transcribing else {
            return
        }
        guard !continuousDumpActive else {
            return
        }

        let action = options.config.hotkeys.action(for: flags)

        switch recordingState {
        case .idle:
            cancelPendingContinuation()
            if let action {
                startRecording(state: .recordingInformation(action: action), label: "\(action.displayName) information")
            }
        case let .recordingInformation(activeAction):
            guard activeAction != .bluetooth else {
                return
            }
            let continuation = options.config.hotkeys.isContinuationPressed(for: activeAction, in: flags)
            let hermesContinuation = options.config.hermesAgent.enabled
                && options.config.hotkeys.isHermesAgentContinuationPressed(for: activeAction, in: flags)
            if continuation {
                cancelPendingHermesContinuation()
                scheduleContinuationConfirmation(for: activeAction)
                return
            }
            if hermesContinuation {
                cancelPendingCommandContinuation()
                scheduleHermesContinuationConfirmation(for: activeAction)
                return
            }
            if action != activeAction, !continuation, !hermesContinuation {
                cancelPendingContinuation()
                recordingState = .idle
                stopAndTranscribe(action: activeAction)
            }
        case let .recordingInstruction(activeAction, informationURL):
            cancelPendingContinuation()
            if !options.config.hotkeys.isContinuationPressed(for: activeAction, in: flags) {
                recordingState = .idle
                stopAndGenerateCommandResult(action: activeAction, informationURL: informationURL)
            }
        case let .recordingHermesInstruction(informationURL, screenshotURL):
            cancelPendingContinuation()
            if !options.config.hermesAgent.enabled
                || !options.config.hotkeys.isHermesAgentContinuationPressed(for: .paste, in: flags) {
                recordingState = .idle
                stopAndRunHermesAgent(informationURL: informationURL, screenshotURL: screenshotURL)
            }
        }
    }

    private func handleBluetoothChordLocked(isPressed: Bool) {
        guard !transcribing, !continuousDumpActive else {
            return
        }

        switch recordingState {
        case .idle where isPressed:
            startRecording(
                state: .recordingInformation(action: .bluetooth),
                label: "bluetooth information"
            )
        case .recordingInformation(action: .bluetooth) where !isPressed:
            recordingState = .idle
            stopAndTranscribe(action: .bluetooth)
        default:
            return
        }
    }

    func startContinuousDump() {
        stateQueue.async {
            self.startContinuousDumpLocked()
        }
    }

    func stopContinuousDump() {
        stateQueue.async {
            self.stopContinuousDumpLocked()
        }
    }

    func printContinuousDumpStatus() {
        stateQueue.async {
            if self.continuousDumpActive {
                log("continuous dump is recording")
            } else {
                log("continuous dump is stopped")
            }
        }
    }

    private func startContinuousDumpLocked() {
        guard options.config.dump.enabled, options.config.continuousDump.enabled else {
            fputs("continuous dump is disabled in config\n", stderr)
            return
        }
        guard !continuousDumpActive else {
            log("continuous dump is already recording")
            return
        }
        guard case .idle = recordingState, !transcribing, !recorder.isRecording else {
            fputs("continuous dump start skipped: another recording or transcription is active\n", stderr)
            return
        }

        do {
            try recorder.start(usesWatchdog: false)
            beginAudioDuckingIfNeeded()
            continuousDumpActive = true
            log("continuous dump started. Type stop to transcribe and write to Obsidian.")
        } catch {
            continuousDumpActive = false
            fputs("continuous dump recording failed: \(error)\n", stderr)
        }
    }

    private func stopContinuousDumpLocked() {
        guard continuousDumpActive else {
            log("continuous dump is already stopped")
            return
        }

        continuousDumpActive = false
        let url = recorder.stop()
        endAudioDuckingIfNeeded()
        log("continuous dump stopped; transcribing...")

        if let url {
            processContinuousDumpRecording(url: url)
        }
    }

    private func scheduleContinuationConfirmation(for action: HotkeyAction) {
        guard pendingContinuation == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.confirmContinuation(for: action)
        }
        pendingContinuation = workItem
        stateQueue.asyncAfter(deadline: .now() + commandModeGrace, execute: workItem)
    }

    private func confirmContinuation(for action: HotkeyAction) {
        pendingContinuation = nil
        guard case let .recordingInformation(activeAction) = recordingState,
              activeAction == action else {
            return
        }
        guard let informationURL = recorder.stop() else {
            recordingState = .idle
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            return
        }
        addAudioDuration(from: informationURL, label: "information")
        do {
            try recorder.start()
            recordingState = .recordingInstruction(
                action: activeAction,
                informationURL: informationURL
            )
            log("recording command...")
        } catch {
            recordingState = .idle
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            fputs("recording failed: \(error)\n", stderr)
            try? preserveOrDeleteRecording(informationURL)
        }
    }

    private func scheduleHermesContinuationConfirmation(for action: HotkeyAction) {
        guard pendingHermesContinuation == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.confirmHermesContinuation(for: action)
        }
        pendingHermesContinuation = workItem
        stateQueue.asyncAfter(deadline: .now() + commandModeGrace, execute: workItem)
    }

    private func confirmHermesContinuation(for action: HotkeyAction) {
        pendingHermesContinuation = nil
        guard options.config.hermesAgent.enabled,
              action == .paste,
              case let .recordingInformation(activeAction) = recordingState,
              activeAction == action else {
            return
        }
        guard let informationURL = recorder.stop() else {
            recordingState = .idle
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            return
        }
        addAudioDuration(from: informationURL, label: "information")
        let screenshotURL = captureHermesScreenContext()
        do {
            try recorder.start()
            recordingState = .recordingHermesInstruction(
                informationURL: informationURL,
                screenshotURL: screenshotURL
            )
            log("recording Hermes instruction...")
        } catch {
            recordingState = .idle
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            fputs("Hermes instruction recording failed: \(error)\n", stderr)
            try? preserveOrDeleteRecording(informationURL)
            try? removeHermesScreenshot(screenshotURL)
        }
    }

    private func cancelPendingContinuation() {
        cancelPendingCommandContinuation()
        cancelPendingHermesContinuation()
    }

    private func cancelPendingCommandContinuation() {
        pendingContinuation?.cancel()
        pendingContinuation = nil
    }

    private func cancelPendingHermesContinuation() {
        pendingHermesContinuation?.cancel()
        pendingHermesContinuation = nil
    }

    private func startRecording(state: RecordingState, label: String) {
        do {
            activeInteractionStartedAt = Date()
            activeInteractionTargetBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            activeAudioDuration = 0
            try recorder.start()
            beginAudioDuckingIfNeeded()
            recordingState = state
            log("recording \(label)...")
            llmReadinessMonitor.warmUpInBackground(reason: "recording started")
        } catch {
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            fputs("recording failed: \(error)\n", stderr)
        }
    }

    private func beginAudioDuckingIfNeeded() {
        guard options.config.audioDucking.enabled, !audioDuckingActive else {
            return
        }
        audioDuckingActive = true
        audioDucker.begin()
    }

    private func endAudioDuckingIfNeeded() {
        guard audioDuckingActive else {
            return
        }
        audioDuckingActive = false
        audioDucker.end()
    }

    private func stopAndTranscribe(action: HotkeyAction?) {
        guard let url = recorder.stop() else {
            endAudioDuckingIfNeeded()
            resetDeliveryTiming()
            return
        }
        endAudioDuckingIfNeeded()
        addAudioDuration(from: url, label: "audio")
        let timing = deliveryTimingSnapshot()

        transcribing = true
        log("transcribing...")

        Task {
            do {
                let text = try await transcribeAndRewrite(url: url)
                log("\n[final] \(text.isEmpty ? "[no speech detected]" : text)\n")
                if let action, !text.isEmpty {
                    do {
                        try await deliverResult(
                            text,
                            action: action,
                            timing: timing,
                            logAsResult: false
                        )
                    } catch {
                        fputs("output delivery failed: \(error)\n", stderr)
                    }
                }
                try preserveOrDeleteRecording(url)
            } catch {
                fputs("transcription failed: \(error)\n", stderr)
            }

            stateQueue.async {
                self.transcribing = false
                self.resetDeliveryTiming()
            }
        }
    }

    private func stopAndGenerateCommandResult(action: HotkeyAction, informationURL: URL) {
        guard let commandURL = recorder.stop() else {
            endAudioDuckingIfNeeded()
            let timing = deliveryTimingSnapshot()
            transcribing = true
            log("no command recording found; transcribing information...")
            Task {
                let information = await transcribeSegment(url: informationURL, label: "information")
                await deliverInformationFallback(information, action: action, timing: timing)
                try? preserveOrDeleteRecording(informationURL)
                stateQueue.async {
                    self.transcribing = false
                    self.resetDeliveryTiming()
                }
            }
            return
        }
        endAudioDuckingIfNeeded()
        addAudioDuration(from: commandURL, label: "command")
        let timing = deliveryTimingSnapshot()

        transcribing = true
        log("transcribing information and command...")

        Task {
            let information = await transcribeSegment(url: informationURL, label: "information")
            let command = await transcribeSegment(url: commandURL, label: "command")

            log("\n[information] \(information.isEmpty ? "[no speech detected]" : information)\n")
            log("\n[command] \(command.isEmpty ? "[no speech detected]" : command)\n")

            if !command.isEmpty {
                do {
                    let result = try await commandGenerator.generate(
                        information: information,
                        command: command
                    )
                    if !result.isEmpty {
                        try await deliverResult(result, action: action, timing: timing)
                    }
                } catch {
                    fputs("command result failed: \(error)\n", stderr)
                }
            } else if !information.isEmpty {
                fputs(
                    "command segment was empty or invalid; using information transcript\n",
                    stderr
                )
                await deliverInformationFallback(information, action: action, timing: timing)
            } else {
                fputs("command result skipped: command and information segments were empty or invalid\n", stderr)
            }

            try? preserveOrDeleteRecording(informationURL)
            try? preserveOrDeleteRecording(commandURL)

            stateQueue.async {
                self.transcribing = false
                self.resetDeliveryTiming()
            }
        }
    }

    private func captureHermesScreenContext() -> URL? {
        let permissionGranted: Bool
        if CGPreflightScreenCaptureAccess() {
            permissionGranted = true
        } else {
            log("Hermes screenshot: requesting Screen Recording permission")
            permissionGranted = CGRequestScreenCaptureAccess()
        }
        guard permissionGranted else {
            fputs("Hermes screenshot unavailable: Screen Recording permission denied. Grant this app access in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch.\n", stderr)
            return nil
        }

        guard let image = CGWindowListCreateImage(
            CGRect.infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            fputs("Hermes screenshot unavailable: CGWindowListCreateImage returned nil\n", stderr)
            return nil
        }

        let dir = URL(fileURLWithPath: "~/Library/Application Support/fluid-push-to-talk/screenshots".expandingTilde, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("hermes-screen-\(Self.screenshotTimestamp()).png")
            try writePNG(image: image, to: url)
            log("Hermes screenshot captured: \(url.path)")
            return url
        } catch {
            fputs("Hermes screenshot unavailable: \(error)\n", stderr)
            return nil
        }
    }

    private static func screenshotTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private func writePNG(image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CliError.invalidValue("failed to create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CliError.invalidValue("failed to finalize PNG screenshot")
        }
    }

    private func removeHermesScreenshot(_ url: URL?) throws {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func stopAndRunHermesAgent(informationURL: URL, screenshotURL: URL?) {
        guard let instructionURL = recorder.stop() else {
            endAudioDuckingIfNeeded()
            transcribing = true
            log("no Hermes instruction recording found; transcribing information fallback...")
            Task {
                let information = await transcribeSegment(url: informationURL, label: "information")
                await deliverInformationFallback(information, action: .paste, timing: deliveryTimingSnapshot())
                try? preserveOrDeleteRecording(informationURL)
                try? removeHermesScreenshot(screenshotURL)
                stateQueue.async {
                    self.transcribing = false
                    self.resetDeliveryTiming()
                }
            }
            return
        }
        endAudioDuckingIfNeeded()
        addAudioDuration(from: instructionURL, label: "Hermes instruction")
        let timing = deliveryTimingSnapshot()
        let targetBundleIdentifier = deliveryTargetBundleIdentifierSnapshot()

        transcribing = true
        log("transcribing information and Hermes instruction...")

        Task {
            let information = await transcribeSegment(url: informationURL, label: "information")
            let instruction = await transcribeSegment(url: instructionURL, label: "Hermes instruction")

            log("\n[information] \(information.isEmpty ? "[no speech detected]" : information)\n")
            log("\n[hermes instruction] \(instruction.isEmpty ? "[no speech detected]" : instruction)\n")

            if !instruction.isEmpty {
                enqueueHermesAgentJob(
                    information: information,
                    instruction: instruction,
                    timing: timing,
                    targetBundleIdentifier: targetBundleIdentifier,
                    screenshotURL: screenshotURL
                )
            } else if !information.isEmpty {
                fputs("Hermes instruction was empty; using information transcript\n", stderr)
                await deliverInformationFallback(information, action: .paste, timing: timing)
                try? removeHermesScreenshot(screenshotURL)
            } else {
                fputs("Hermes agent skipped: information and instruction were empty or invalid\n", stderr)
                try? removeHermesScreenshot(screenshotURL)
            }

            try? preserveOrDeleteRecording(informationURL)
            try? preserveOrDeleteRecording(instructionURL)

            stateQueue.async {
                self.transcribing = false
                self.resetDeliveryTiming()
            }
        }
    }

    private func enqueueHermesAgentJob(
        information: String,
        instruction: String,
        timing: DeliveryTiming?,
        targetBundleIdentifier: String?,
        screenshotURL: URL?
    ) {
        hermesJobIDLock.lock()
        let jobID = nextHermesJobID
        nextHermesJobID += 1
        hermesJobIDLock.unlock()

        log("Hermes job #\(jobID) queued...")
        hermesJobQueue.async { [weak self] in
            guard let self else {
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await self.runHermesQueuedJob(
                    id: jobID,
                    information: information,
                    instruction: instruction,
                    timing: timing,
                    targetBundleIdentifier: targetBundleIdentifier,
                    screenshotURL: screenshotURL
                )
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    private func runHermesQueuedJob(
        id: Int,
        information: String,
        instruction: String,
        timing: DeliveryTiming?,
        targetBundleIdentifier: String?,
        screenshotURL: URL?
    ) async {
        defer {
            try? removeHermesScreenshot(screenshotURL)
        }
        log("Hermes job #\(id) running...")
        do {
            let hermesResult = try await hermesRunner.run(
                information: information,
                instruction: instruction,
                screenshotURL: screenshotURL
            )
            let result = hermesResult.output
            if !result.isEmpty {
                log("\n[hermes result #\(id)] \(result)\n")
                let targetAvailable = await activateOriginalTargetIfPossible(bundleIdentifier: targetBundleIdentifier)
                if targetAvailable {
                    try await deliverResult(result, action: .paste, timing: timing, logAsResult: false)
                } else {
                    await copyHermesResultToClipboard(result)
                    fputs("Hermes result copied to clipboard because the original paste target is unavailable\n", stderr)
                }
                log("Hermes job #\(id) completed from visible foreground session \(hermesResult.sessionID ?? "unknown")")
            } else {
                fputs("Hermes job #\(id) returned an empty result; see \(hermesResult.logURL.path)\n", stderr)
            }
        } catch {
            fputs("Hermes job #\(id) failed: \(error)\n", stderr)
        }
    }

    private func deliverInformationFallback(_ information: String, action: HotkeyAction, timing: DeliveryTiming?) async {
        guard !information.isEmpty else {
            return
        }
        do {
            try await deliverResult(information, action: action, timing: timing)
        } catch {
            fputs("fallback delivery failed: \(error)\n", stderr)
        }
    }

    private func deliverResult(
        _ result: String,
        action: HotkeyAction,
        timing: DeliveryTiming?,
        logAsResult: Bool = true
    ) async throws {
        if logAsResult {
            log("\n[result] \(result)\n")
        }
        let outputMethod = options.config.llmOutput.method(for: action)
        switch outputMethod {
        case .clipboard:
            guard options.config.paste.enabled else {
                return
            }
            await MainActor.run {
                self.typer.paste(result)
                self.logDeliveryTiming(timing, delivery: "pasted")
            }
        case .dump:
            guard options.config.dump.enabled else {
                return
            }
            let destination = try dumper.dumpRaw(result)
            log("dumped markdown to \(destination.path)")
            self.logDeliveryTiming(timing, delivery: "dumped")
        case .bluetoothKeyboard:
            let delivery = try await bluetoothKeyboard.send(result)
            log("typed \(delivery.byteCount) UTF-8 bytes through ESP32 on \(delivery.port)")
            if options.config.debug.enabled {
                log("ESP32 completion: \(delivery.completion)")
            }
            self.logDeliveryTiming(timing, delivery: "bluetooth-keyboard")
        }
    }

    private func addAudioDuration(from url: URL, label: String) {
        do {
            activeAudioDuration += try audioDuration(url: url)
        } catch {
            fputs("\(label) audio duration unavailable: \(error)\n", stderr)
        }
    }

    private func deliveryTimingSnapshot() -> DeliveryTiming? {
        guard let activeInteractionStartedAt else {
            return nil
        }
        return DeliveryTiming(
            startedAt: activeInteractionStartedAt,
            audioDuration: activeAudioDuration
        )
    }

    private func deliveryTargetBundleIdentifierSnapshot() -> String? {
        activeInteractionTargetBundleIdentifier
    }

    @MainActor
    private func activateOriginalTargetIfPossible(bundleIdentifier: String?) async -> Bool {
        guard let bundleIdentifier, bundleIdentifier != "com.apple.Terminal" else {
            return true
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            fputs("paste target unavailable; result copied to clipboard fallback may be needed\n", stderr)
            return false
        }
        app.activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 300_000_000)
        return true
    }

    @MainActor
    private func copyHermesResultToClipboard(_ result: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result, forType: .string)
    }

    private func resetDeliveryTiming() {
        activeInteractionStartedAt = nil
        activeInteractionTargetBundleIdentifier = nil
        activeAudioDuration = 0
    }

    private func audioDuration(url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else {
            return 0
        }
        return TimeInterval(file.length) / file.fileFormat.sampleRate
    }

    private func logDeliveryTiming(_ timing: DeliveryTiming?, delivery: String) {
        guard let timing else {
            return
        }
        log(timing.summary(delivery: delivery))
    }

    private func transcribeSegment(url: URL, label: String) async -> String {
        do {
            return try await transcribeAndRewrite(url: url)
        } catch {
            fputs("\(label) transcription failed: \(error)\n", stderr)
            return ""
        }
    }

    private func transcribeAndRewrite(url: URL) async throws -> String {
        let text = try await transcriber.transcribe(url: url)
        return textReplacer.rewrite(text)
    }

    private func processContinuousDumpRecording(url: URL) {
        Task {
            let text = await transcribeSegment(url: url, label: "continuous dump")

            if !text.isEmpty {
                do {
                    let destination = try dumper.dumpRaw(text)
                    log("continuous dump wrote transcript to \(destination.path)")
                } catch {
                    fputs("continuous dump failed: \(error)\n", stderr)
                }
            } else {
                log("continuous dump skipped: no speech detected")
            }

            try? preserveOrDeleteRecording(url)
        }
    }

    private func preserveOrDeleteRecording(_ url: URL) throws {
        if options.config.recordings.save {
            try FileManager.default.createDirectory(
                at: options.config.recordings.outputURL,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
            let destination = options.config.recordings.outputURL
                .appendingPathComponent("fluid_ptt_\(formatter.string(from: Date()))")
                .appendingPathExtension("wav")
            try FileManager.default.moveItem(at: url, to: destination)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

final class TerminalCommandReader: @unchecked Sendable {
    private let controller: PushToTalkController
    private let prompt = "> "
    private let completionCommands = ["go", "stop", "status", "help", "quit"]

    init(controller: PushToTalkController) {
        self.controller = controller
    }

    func start() {
        guard isatty(STDIN_FILENO) == 1 else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            self.printHelp()
            while let line = self.readCommandLine() {
                self.handle(line)
            }
        }
    }

    private func readCommandLine() -> String? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return nil
        }

        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        withUnsafeMutableBytes(of: &raw.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 1
            controlCharacters[Int(VTIME)] = 0
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            return nil
        }
        defer {
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
        }

        writeTerminal(prompt)
        var buffer = ""

        while true {
            guard let byte = readByte() else {
                return nil
            }

            switch byte {
            case 4:
                if buffer.isEmpty {
                    writeTerminal("\n")
                    return nil
                }
            case 9:
                applyCompletion(to: &buffer)
            case 10, 13:
                writeTerminal("\n")
                return buffer
            case 21:
                buffer.removeAll()
                redraw(buffer)
            case 27:
                discardEscapeSequence()
            case 127, 8:
                guard !buffer.isEmpty else {
                    continue
                }
                buffer.removeLast()
                redraw(buffer)
            default:
                guard byte >= 32 else {
                    continue
                }
                if let scalar = UnicodeScalar(Int(byte)) {
                    let character = Character(scalar)
                    buffer.append(character)
                    writeTerminal(String(character))
                }
            }
        }
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 1 {
                return byte
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    }

    private func applyCompletion(to buffer: inout String) {
        let lowercased = buffer.lowercased()
        let matches = completionCommands.filter { $0.hasPrefix(lowercased) }
        guard !matches.isEmpty else {
            writeTerminal("\u{7}")
            return
        }

        if matches.count == 1 {
            buffer = matches[0]
            redraw(buffer)
            return
        }

        let prefix = commonPrefix(in: matches)
        if prefix.count > buffer.count {
            buffer = prefix
            redraw(buffer)
            return
        }

        writeTerminal("\n\(matches.joined(separator: "  "))\n")
        redraw(buffer)
    }

    private func commonPrefix(in values: [String]) -> String {
        guard var prefix = values.first else {
            return ""
        }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix), !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        return prefix
    }

    private func discardEscapeSequence() {
        guard let next = readByte(), next == 91 else {
            return
        }
        _ = readByte()
    }

    private func redraw(_ buffer: String) {
        writeTerminal("\r\u{001B}[2K\(prompt)\(buffer)")
    }

    private func writeTerminal(_ text: String) {
        _ = text.withCString { pointer in
            Darwin.write(STDOUT_FILENO, pointer, strlen(pointer))
        }
    }

    private func handle(_ line: String) {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch command {
        case "go", "record go", "recording go":
            controller.startContinuousDump()
        case "stop", "record stop", "recording stop":
            controller.stopContinuousDump()
        case "status", "record status", "recording status":
            controller.printContinuousDumpStatus()
        case "help", "?":
            printHelp()
        case "quit", "exit":
            controller.stopContinuousDump()
            log("quitting app")
            exit(0)
        case "":
            return
        default:
            log("unknown command: \(line). Type help for terminal commands.")
        }
    }

    private func printHelp() {
        log(
            """
            Terminal commands: go, stop, status, help, quit. Press Tab to autocomplete.
            """
        )
    }
}

final class HotkeyMonitor: @unchecked Sendable {
    private let controller: PushToTalkController
    private let bluetoothKeysByCode: [CGKeyCode: HotkeyKey]
    private let hasRegularBluetoothKey: Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bluetoothHotkeyActive = false

    init(controller: PushToTalkController, hotkeys: HotkeysConfig) {
        self.controller = controller
        bluetoothKeysByCode = hotkeys.bluetooth.isEnabled ? hotkeys.bluetooth.keysByCode : [:]
        hasRegularBluetoothKey = hotkeys.bluetooth.isEnabled && hotkeys.bluetooth.hasRegularKey
    }

    func start() throws {
        PermissionHelper.requestAccessibilityPrompt()

        var mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if hasRegularBluetoothKey {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
            mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            PermissionHelper.openInputMonitoringSettings()
            throw CliError.invalidValue(PermissionHelper.permissionMessage())
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

enum PermissionHelper {
    static func requestAccessibilityPrompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func printTerminalScreenRecordingFirstRunHintIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }

        let dir = URL(fileURLWithPath: "~/Library/Application Support/fluid-push-to-talk".expandingTilde, isDirectory: true)
        let marker = dir.appendingPathComponent("screen-recording-terminal-hint-shown")
        guard !FileManager.default.fileExists(atPath: marker.path) else {
            return
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let message = """

        IMPORTANT: Hermes Agent screenshot context needs macOS Screen Recording permission.

        Because this dev build is launched from Terminal, grant Screen & System Audio Recording access to Terminal before using Hermes Agent screenshots:

        1. Open System Settings → Privacy & Security → Screen & System Audio Recording
        2. Enable Terminal
        3. Fully quit and reopen Terminal, then restart fluid-push-to-talk

        I will open the relevant Privacy Settings pane now. Without this permission Hermes still works, but it will not receive screenshots.
        """
        fputs("\(message)\n", stderr)
        openScreenRecordingSettings()
        try? "shown\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    static func openScreenRecordingSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func permissionMessage() -> String {
        """
        Could not create event tap.

        macOS is blocking the global hotkey listener.
        Enable permissions for the app that launched this command, usually Terminal, iTerm, or Visual Studio Code:

        1. System Settings > Privacy & Security > Accessibility
        2. System Settings > Privacy & Security > Input Monitoring
        3. Fully quit and reopen that app

        I opened the relevant System Settings pane. If Terminal is missing from the list, add:
        /Applications/Utilities/Terminal.app
        """
    }

    private static func openSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private extension HotkeyMonitor {
    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let bluetoothKey = bluetoothKeysByCode[keyCode] {
            switch type {
            case .flagsChanged where bluetoothKey.isModifier:
                return handleBluetoothKey(
                    event,
                    key: bluetoothKey,
                    isPressed: isBluetoothModifierPressed(event, key: bluetoothKey)
                )
            case .keyDown where !bluetoothKey.isModifier:
                return handleBluetoothKey(event, key: bluetoothKey, isPressed: true)
            case .keyUp where !bluetoothKey.isModifier:
                return handleBluetoothKey(event, key: bluetoothKey, isPressed: false)
            default:
                return false
            }
        }

        if type == .flagsChanged {
            controller.handle(flags: event.flags)
        }
        return false
    }

    func isBluetoothModifierPressed(_ event: CGEvent, key: HotkeyKey) -> Bool {
        if let deviceFlag = key.deviceFlag {
            return event.flags.contains(deviceFlag)
        }
        guard let modifierFlag = key.modifierFlag else {
            return false
        }
        return event.flags.contains(modifierFlag)
    }

    func handleBluetoothKey(_ event: CGEvent, key: HotkeyKey, isPressed: Bool) -> Bool {
        if isPressed {
            var conflictingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if let modifierFlag = key.modifierFlag {
                conflictingModifiers.remove(modifierFlag)
            }
            guard event.flags.intersection(conflictingModifiers).isEmpty else {
                return false
            }
            guard !bluetoothHotkeyActive else {
                return true
            }
            bluetoothHotkeyActive = true
            controller.handleBluetoothChord(isPressed: true)
            return true
        }

        guard bluetoothHotkeyActive else {
            return false
        }
        bluetoothHotkeyActive = false
        controller.handleBluetoothChord(isPressed: false)
        return true
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension AVAudioCommonFormat {
    var displayName: String {
        switch self {
        case .pcmFormatFloat32:
            return "Float32"
        case .pcmFormatFloat64:
            return "Float64"
        case .pcmFormatInt16:
            return "Int16"
        case .pcmFormatInt32:
            return "Int32"
        case .otherFormat:
            return "Other"
        @unknown default:
            return "Unknown"
        }
    }
}

final class SingleInstanceLock {
    private let fd: Int32

    init(name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).lock")
        fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CliError.invalidValue("failed to open app lock at \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CliError.invalidValue("another FluidAudio Push To Talk instance is already running")
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

@main
struct FluidPushToTalk {
    static func main() {
        log("FluidAudio Push To Talk \(AppInfo.version)")

        let options: Options
        do {
            options = try Options.parse(CommandLine.arguments)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }

        do {
            switch options.command {
            case .setup:
                try ConfigWizard.runSetup(configPath: options.configPath)
                return
            case .configMenu:
                try ConfigWizard.runConfigMenu(configPath: options.configPath)
                return
            case .configShow:
                try ConfigWizard.show(configPath: options.configPath)
                return
            case .configDoctor:
                try ConfigWizard.doctor(configPath: options.configPath)
                return
            case .configReset:
                try ConfigWizard.reset(configPath: options.configPath, confirmed: options.configResetConfirmed)
                return
            case .run:
                break
            }
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }

        if options.testCommandInformation != nil || options.testCommand != nil {
            Task {
                await runCommandResultTest(options: options)
            }
            RunLoop.current.run()
            return
        }

        if let text = options.testBluetoothKeyboardText {
            Task {
                await runBluetoothKeyboardTest(text: text, options: options)
            }
            RunLoop.current.run()
            return
        }

        do {
            RuntimeState.shared.instanceLock = try SingleInstanceLock(name: "fluid-push-to-talk")
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }

        logOutputConfiguration(options: options)
        log("loading FluidAudio ASR model \(options.config.asr.modelVersion)...")
        Task {
            await loadAndRun(options: options)
        }

        RunLoop.current.run()
    }

    private static func runCommandResultTest(options: Options) async {
        guard let information = options.testCommandInformation,
              let command = options.testCommand else {
            fputs("--test-command-information and --test-command must be used together\n", stderr)
            exit(1)
        }

        do {
            let llmClient = CommandLLMClientFactory.make(config: options.config.localLLM)
            let generator = CommandResultGenerator(config: options.config, llmClient: llmClient)
            let result = try await generator.generate(information: information, command: command)
            print("[result] \(result)")
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func logOutputConfiguration(options: Options) {
        let pasteOutput = options.config.llmOutput.paste
        let dumpOutput = options.config.llmOutput.dump
        let bluetoothOutput = options.config.llmOutput.bluetooth
        let bluetoothPort = options.config.bluetoothKeyboard.resolvedPort ?? "automatisch"
        let bluetoothLine: String
        if !options.config.hotkeys.bluetooth.isEnabled {
            bluetoothLine = "  Bluetooth: disabled"
        } else {
            bluetoothLine = "  \(options.config.hotkeys.bluetooth.displayName): \(bluetoothOutput.locationDisplayName) -> \(bluetoothOutput.destinationDisplayName)\(bluetoothOutput == .bluetoothKeyboard ? " (Port: \(bluetoothPort))" : "")"
        }
        let audioInput = (try? AudioInputDevices.resolve(config: options.config.audioInput).summary) ?? "nicht verfuegbar"
        log(
            """
            Output-Konfiguration: \(options.activeConfigURL.path)
              Audio Input: \(audioInput)
              \(options.config.hotkeys.paste.displayName): \(pasteOutput.locationDisplayName) -> \(pasteOutput.destinationDisplayName)\(pasteOutput == .bluetoothKeyboard ? " (Port: \(bluetoothPort))" : "")
              \(options.config.hotkeys.dump.displayName): \(dumpOutput.locationDisplayName) -> \(dumpOutput.destinationDisplayName)\(dumpOutput == .bluetoothKeyboard ? " (Port: \(bluetoothPort))" : "")
            \(bluetoothLine)
            """
        )
    }

    private static func runBluetoothKeyboardTest(text: String, options: Options) async {
        do {
            let delivery = try await BluetoothKeyboardOutput(config: options.config.bluetoothKeyboard).send(text)
            print("[bluetooth-keyboard] typed \(delivery.byteCount) UTF-8 bytes through \(delivery.port)")
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func loadAndRun(options: Options) async {
        do {
            let transcriber = FluidTranscriber()
            try await transcriber.prepare(
                modelVersion: options.config.asr.modelVersion,
                language: options.config.asr.language
            )
            log("FluidAudio ASR ready: model \(options.config.asr.modelVersion), language \(options.config.asr.language)")
            let llmClient = CommandLLMClientFactory.make(config: options.config.localLLM)
            let readinessMonitor = LocalLLMReadinessMonitor(config: options.config, llmClient: llmClient)
            let recorder = AudioRecorder(audioInput: options.config.audioInput)

            let controller = PushToTalkController(
                options: options,
                recorder: recorder,
                transcriber: transcriber,
                typer: PasteboardTyper(
                    pasteDelay: options.config.paste.pasteDelay,
                    restoreClipboard: options.config.paste.restoreClipboard,
                    restoreClipboardDelay: options.config.paste.restoreClipboardDelay
                ),
                dumper: MarkdownDumper(config: options.config),
                bluetoothKeyboard: BluetoothKeyboardOutput(config: options.config.bluetoothKeyboard),
                commandGenerator: CommandResultGenerator(config: options.config, llmClient: llmClient),
                llmReadinessMonitor: readinessMonitor
            )
            let monitor = HotkeyMonitor(controller: controller, hotkeys: options.config.hotkeys)
            let terminalCommandReader = TerminalCommandReader(controller: controller)

            try await MainActor.run {
                log("starting hotkey monitor...")
                try monitor.start()
                if options.config.hermesAgent.enabled {
                    PermissionHelper.printTerminalScreenRecordingFirstRunHintIfNeeded()
                }
                RuntimeState.shared.monitor = monitor
                RuntimeState.shared.terminalCommandReader = terminalCommandReader
                RuntimeState.shared.llmReadinessMonitor = readinessMonitor
                let bluetoothHint = !options.config.hotkeys.bluetooth.isEnabled
                    ? ""
                    : " Hold \(options.config.hotkeys.bluetooth.displayName) for Bluetooth."
                let hermesHint = options.config.hermesAgent.enabled
                    ? " release Command first while holding Option for Hermes Agent mode;"
                    : ""
                log(
                    "Hold \(options.config.hotkeys.paste.displayName) for local paste. Release Option first while holding Command for local command mode;\(hermesHint)\(bluetoothHint) Hold \(options.config.hotkeys.dump.displayName) to dump. Press Ctrl+C to quit."
                )
            }
            terminalCommandReader.start()
            readinessMonitor.warmUpInBackground(reason: "startup")
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}

final class RuntimeState: @unchecked Sendable {
    static let shared = RuntimeState()
    var instanceLock: SingleInstanceLock?
    var monitor: HotkeyMonitor?
    var terminalCommandReader: TerminalCommandReader?
    var llmReadinessMonitor: LocalLLMReadinessMonitor?

    private init() {}
}

func log(_ message: String) {
    print(ConsoleColor.colorized(message))
    fflush(stdout)
}

enum ConsoleColor {
    private static let reset = "\u{001B}[0m"
    private static let red = "\u{001B}[31m"
    private static let green = "\u{001B}[32m"
    private static let yellow = "\u{001B}[33m"
    private static let blue = "\u{001B}[34m"
    private static let magenta = "\u{001B}[35m"
    private static let cyan = "\u{001B}[36m"
    private static let dim = "\u{001B}[2m"

    static func colorized(_ message: String) -> String {
        guard shouldColor else {
            return message
        }

        let lowercased = message.lowercased()
        let color: String
        if lowercased.contains("failed")
            || lowercased.contains("error")
            || lowercased.contains("unavailable") {
            color = red
        } else if lowercased.contains("not ready")
            || lowercased.contains("fallback")
            || lowercased.contains("skipped") {
            color = yellow
        } else if lowercased.contains("[result]")
            || lowercased.contains("[final]")
            || lowercased.contains("ready")
            || lowercased.contains("dumped") {
            color = green
        } else if lowercased.contains("recording") {
            color = magenta
        } else if lowercased.contains("transcribing")
            || lowercased.contains("local mlx") {
            color = cyan
        } else if lowercased.contains("skill selection")
            || lowercased.contains("using skill") {
            color = dim
        } else {
            color = blue
        }

        return "\(color)\(message)\(reset)"
    }

    private static var shouldColor: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCALPTT_COLOR"] != "0" else {
            return false
        }
        if environment["LOCALPTT_COLOR"] == "1" {
            return isatty(STDOUT_FILENO) == 1
        }
        guard environment["NO_COLOR"] == nil else {
            return false
        }
        return isatty(STDOUT_FILENO) == 1
    }
}

func formatSeconds(_ seconds: TimeInterval) -> String {
    String(format: "%.2fs", seconds)
}

extension String {
    var expandingTilde: String {
        NSString(string: self).expandingTildeInPath
    }

    var isAbsolutePath: Bool {
        NSString(string: self).isAbsolutePath
    }

    var isOllamaStyleModelName: Bool {
        contains(":") && !contains("/")
    }
}
