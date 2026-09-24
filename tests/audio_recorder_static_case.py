#!/usr/bin/env python3
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"
APP_CONFIG = REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift"
OPTIONS = REPO_ROOT / "app" / "Sources" / "CLI" / "Options.swift"
CHECKED_IN_CONFIG = REPO_ROOT / "config" / "config.json"
QWEN3_WORKER = REPO_ROOT / "app" / "Sources" / "ASR" / "Qwen3ASRWorker.swift"


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
            "try await manager.transcribe(\n                url,",
            "transcriber must pass the whole recording to FluidAudio's chunked long-audio path",
        ),
        (
            "version = .ultra",
            "transcriber must load Parakeet Ultra for the default ASR model version",
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
        "maxRecordingDuration",
        "scheduleWatchdog",
        "usesWatchdog",
        "recording stopped: exceeded",
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
            print(f"audio recorder regression: forbidden pattern remains (old engine/HAL or recording time limit): {needle}", file=sys.stderr)
            failed = True

    asr_default_checks = [
        (APP_CONFIG, 'var modelVersion = "ultra"', "AsrConfig must default to Parakeet Ultra"),
        (CHECKED_IN_CONFIG, '"model_version": "ultra"', "checked-in config must default to Parakeet Ultra"),
        (OPTIONS, '["ultra", "v3", "v2", Qwen3ASRWorker.modelVersion].contains(options.config.asr.modelVersion)', "CLI must accept ultra, v3, v2, and qwen3-asr-1.7b"),
        (QWEN3_WORKER, 'static let modelVersion = "qwen3-asr-1.7b"', "Qwen3 worker must own the qwen3-asr-1.7b config value"),
        (QWEN3_WORKER, 'static let modelID = "Qwen/Qwen3-ASR-1.7B"', "Qwen3 worker must load Qwen3-ASR-1.7B"),
        (QWEN3_WORKER, 'static let packageRequirement = "mlx-qwen3-asr==0.4.4"', "Qwen3 worker must pin the MLX package"),
        (QWEN3_WORKER, "attributes: [.posixPermissions: 0o600]", "Qwen3 temporary audio must be private"),
        (QWEN3_WORKER, "try? FileManager.default.removeItem(at: url)", "Qwen3 temporary audio must be deleted after every request"),
        (APP_RUNTIME, "try await qwen3Worker.transcribe(samples: samples)", "transcriber must route qwen3-asr-1.7b recordings to the Qwen3 worker"),
    ]
    for path, needle, message in asr_default_checks:
        if needle not in path.read_text(encoding="utf-8"):
            print(f"audio recorder regression: {message}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("audio recorder static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
