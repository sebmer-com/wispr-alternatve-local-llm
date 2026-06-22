#!/usr/bin/env python3
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"


def main() -> int:
    source = APP_RUNTIME.read_text(encoding="utf-8")
    checks = [
        (
            "AVAudioRecorderDelegate",
            "audio recorder must use AVAudioRecorder for stable macOS headset capture",
        ),
        (
            "struct RecordingCapture",
            "audio recorder must return capture metadata for diagnostics",
        ),
        (
            "struct DeliveryTiming",
            "app must track delivery timing from first button press to paste/dump completion",
        ),
        (
            "frameCount: AVAudioFramePosition",
            "audio recorder must track captured frame count",
        ),
        (
            "peakAmplitude",
            "audio recorder must track peak level for silent-input diagnostics",
        ),
        (
            "minimumTranscribableFrames: AVAudioFramePosition = 3_200",
            "audio recorder must skip recordings too short for reliable ASR",
        ),
        (
            "minimumRestartDelay: TimeInterval = 0.35",
            "audio recorder must include an AirPods-safe restart cooldown",
        ),
        (
            "ensureMicrophonePermission()",
            "audio recorder must check microphone permission before capture",
        ),
        (
            "AVCaptureDevice.requestAccess(for: .audio)",
            "audio recorder must request microphone permission on first use",
        ),
        (
            "microphone permission is required",
            "audio recorder must explain missing microphone permission",
        ),
        (
            "audio input device:",
            "audio recorder must log the selected input device for headset diagnostics",
        ),
        (
            "AVFormatIDKey: Int(kAudioFormatMPEG4AAC)",
            "audio recorder must record compact AAC/M4A files",
        ),
        (
            "AVSampleRateKey: 44_100",
            "audio recorder must request a stable recorder sample rate",
        ),
        (
            "AVNumberOfChannelsKey: 1",
            "audio recorder must record mono audio",
        ),
        (
            "recorder.prepareToRecord()",
            "audio recorder must prepare capture before recording",
        ),
        (
            "recorder.record()",
            "audio recorder must check the AVAudioRecorder start result",
        ),
        (
            "scheduleWatchdog(for: token)",
            "audio recorder must start the watchdog for each recording",
        ),
        (
            "maxRecordingDuration",
            "audio recorder must define a maximum recording duration",
        ),
        (
            "captureMetadata(url: url)",
            "audio recorder must report file metadata before transcription",
        ),
        (
            "recording captured:",
            "audio recorder must log capture metadata before transcription",
        ),
        (
            "activeInteractionStartedAt = Date()",
            "app must start end-to-end latency timing at the first hotkey recording start",
        ),
        (
            "activeAudioDuration += try audioDuration(url: url)",
            "app must accumulate audio duration for latency comparison",
        ),
        (
            "try await deliverResult(",
            "plain transcription must use the configured output router",
        ),
        (
            "self.logDeliveryTiming(timing, delivery: \"pasted\")",
            "app must log timing after paste delivery",
        ),
        (
            "latency \\(delivery): audio \\(formatSeconds(audioDuration)), end-to-end",
            "app must log audio duration and end-to-end delivery time together",
        ),
        (
            "recording skipped: too short for transcription",
            "audio recorder must skip very short files before ASR",
        ),
        (
            "ASR rejected audio:",
            "transcriber must include audio metadata when FluidAudio rejects a file",
        ),
        (
            "path \\(url.path)",
            "transcriber must include the rejected recording path for debugging",
        ),
        (
            "final class SingleInstanceLock",
            "app must prevent duplicate hotkey monitors from competing for microphone input",
        ),
        (
            "flock(fd, LOCK_EX | LOCK_NB)",
            "single-instance lock must fail fast when another app instance is already running",
        ),
        (
            "RuntimeState.shared.instanceLock",
            "single-instance lock must be retained for the app lifetime",
        ),
        (
            'environment["LOCALPTT_COLOR"] == "1"',
            "console colors must support an explicit app override when the host sets NO_COLOR",
        ),
    ]

    failed = False
    for needle, message in checks:
        if needle not in source:
            print(f"audio recorder regression: {message}", file=sys.stderr)
            failed = True

    forbidden = [
        "AVAudioEngine",
        "AudioUnitSetProperty(",
        "kAudioOutputUnitProperty_CurrentDevice",
        ".AVAudioEngineConfigurationChange",
        "installTap(onBus:",
        "AudioFileSink",
        "tapBufferSize",
        "handleAudioConfigurationChange",
        "rebuildActiveEngineIfNeeded",
        "audio device configuration changed during recording; rebuilding input route",
        "audio input refreshed after configuration change",
        "audio input refresh failed after configuration change",
        "let format = input.outputFormat(forBus: 0)",
        "format: format",
        "setFile(_ file: AVAudioFile)",
        "bufferSize: 4096",
        "tapBufferSize: AVAudioFrameCount = 512",
        "private var armedEngine: AVAudioEngine?",
        "try takeArmedEngine() ?? makePreparedEngine()",
        "func arm() throws",
        "try recorder.arm()",
        "audio recorder armed for immediate capture",
        "makeStartedEngine()",
        "keepWarmOrStop(engine)",
        "armedEngine = engine",
        "ignoreInitialConfigurationChanges()",
        "ignoreConfigurationChangesUntil",
        "configurationChangedDuringRecording",
    ]
    for needle in forbidden:
        if needle in source:
            print(f"audio recorder regression: forbidden old engine/HAL pattern remains: {needle}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("audio recorder static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
