#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"
HOTKEYS = REPO_ROOT / "app" / "Sources" / "Config" / "HotkeysConfig.swift"
APP_CONFIG = REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift"
CONFIG_WIZARD = REPO_ROOT / "app" / "Sources" / "CLI" / "ConfigWizard.swift"
HERMES_RUNNER = REPO_ROOT / "app" / "Sources" / "HermesAgentRunner.swift"
DUCKER = REPO_ROOT / "app" / "Sources" / "SystemAudioDucker.swift"
CONFIG = REPO_ROOT / "config" / "config.json"


def main() -> int:
    runtime = APP_RUNTIME.read_text(encoding="utf-8")
    hotkeys = HOTKEYS.read_text(encoding="utf-8")
    app_config = APP_CONFIG.read_text(encoding="utf-8")
    wizard = CONFIG_WIZARD.read_text(encoding="utf-8")
    hermes = HERMES_RUNNER.read_text(encoding="utf-8")
    ducker = DUCKER.read_text(encoding="utf-8")
    config = json.loads(CONFIG.read_text(encoding="utf-8"))

    checks = [
        ("SystemAudioDucker", runtime, "runtime must own a system audio ducker"),
        ("beginAudioDuckingIfNeeded()", runtime, "recording start must engage audio ducking"),
        ("endAudioDuckingIfNeeded()", runtime, "recording stop/failure must release audio ducking"),
        ("case recordingHermesInstruction", hotkeys, "hotkey state must include Hermes instruction recording"),
        ("isHermesAgentContinuationPressed", hotkeys, "hotkeys must detect Command-first/Option-held Hermes gesture"),
        ("scheduleHermesContinuationConfirmation", runtime, "runtime must grace-confirm Hermes continuation"),
        ("stopAndRunHermesAgent", runtime, "runtime must route Hermes recordings separately from local command mode"),
        ("enqueueHermesAgentJob", runtime, "Hermes runs must be queued outside the transcription gate"),
        ("runHermesQueuedJob", runtime, "queued Hermes jobs must execute independently after transcription finishes"),
        ("hermesJobQueue", runtime, "Hermes jobs must run serially to preserve named-session order"),
        ("HermesAgentRunner", hermes, "Hermes runner service must exist"),
        ("ensureNamedVoiceSession", hermes, "Hermes runner must resolve the persistent local-audio Hermes session before use"),
        ("hermes-voice-session.json", hermes, "Hermes runner must persist the actual Hermes session ID returned by chat mode"),
        ("extractSessionID", hermes, "Hermes runner must capture the session_id emitted by Hermes chat mode"),
        ("sessionID", hermes, "Hermes runner must return the exact Hermes session ID for foreground resume"),
        ("findNamedVoiceSessionID", hermes, "Hermes runner must reuse named Hermes sessions without a hidden user turn"),
        ("sessions", hermes, "Hermes runner must use Hermes session commands for reuse, export, and bootstrap metadata"),
        ("currentClipboardText", hermes, "Hermes runner must read clipboard text for prompt context"),
        ("Current clipboard text", hermes, "Hermes prompt must include clipboard text"),
        ("Local Audio run ID", hermes, "Hermes prompt must include a unique run ID"),
        ("Screenshot context", hermes, "Hermes prompt must include captured screenshot context"),
        ("captureHermesScreenContext", runtime, "Hermes agent mode must capture screen context when entering instruction mode"),
        ("CGPreflightScreenCaptureAccess", runtime, "Hermes screenshot capture must preflight Screen Recording permission"),
        ("CGRequestScreenCaptureAccess", runtime, "Hermes screenshot capture must request Screen Recording permission when needed"),
        ("printTerminalScreenRecordingFirstRunHintIfNeeded", runtime, "Hermes Agent startup must warn first-time users about Terminal Screen Recording permission"),
        ("screen-recording-terminal-hint-shown", runtime, "Terminal Screen Recording startup hint must be shown only once"),
        ("Screen & System Audio Recording", runtime, "Terminal Screen Recording startup hint must name the macOS Privacy Settings pane"),
        ("openScreenRecordingSettings", runtime, "Terminal Screen Recording startup hint must open the relevant Privacy Settings pane"),
        ('tell application "Terminal"', hermes, "Hermes runner must manage a Terminal session"),
        ('tell application "System Events"', hermes, "Hermes runner must paste into the foreground Hermes Terminal session"),
        ('keystroke "v" using command down', hermes, "Hermes runner must paste the full prompt visibly"),
        ("key code 36", hermes, "Hermes runner must press Enter after visible prompt paste"),
        ("foregroundSessionAndSubmit", hermes, "Hermes runner must run the voice job in a foreground Hermes session"),
        ("foregroundInteractiveSession", hermes, "Hermes runner must foreground a real interactive Hermes session"),
        ("__LOCAL_AUDIO_HERMES_SESSION__", hermes, "interactive Hermes session must write a stable scrollback marker"),
        ("hermes-terminal-session.json", hermes, "interactive Hermes session must persist a reusable Terminal handle"),
        ("contents of tab", hermes, "interactive Hermes session must search scrollback, not only tab title"),
        ('"sessions", "export"', hermes, "Dual delivery must poll the visible Hermes session export"),
        ('"--session-id"', hermes, "Hermes session export must target the exact visible session"),
        ("decodeSessionExport", hermes, "Hermes runner must parse the visible session export"),
        ("runID", hermes, "Hermes runner must correlate exported messages by run ID"),
        ("selected tab", hermes, "interactive Hermes session must reuse existing Terminal tabs"),
        ("struct AudioDuckingConfig", app_config, "config must expose audio ducking"),
        ("struct HermesAgentConfig", app_config, "config must expose Hermes agent settings"),
        ("Enable Hermes Agent?", wizard, "setup wizard must let users enable or disable Hermes Agent"),
        ("Hermes Agent Trigger", wizard, "setup wizard must explain the Hermes trigger"),
        ("tryBeginCoreAudio", ducker, "ducker must attempt CoreAudio mute/volume"),
        ("tryBeginAppleScript", ducker, "ducker must include AppleScript fallback"),
    ]

    failed = False
    for needle, source, message in checks:
        if needle not in source:
            print(f"Hermes shortcut regression: {message}", file=sys.stderr)
            failed = True


    if "tail -n 200" in hermes or "foregroundTerminalLog" in hermes:
        print("Hermes shortcut regression: completion UI must be a real Hermes session, not a tail -f log", file=sys.stderr)
        failed = True
    run_block = hermes[hermes.find("func run(information:"):hermes.find("private static func makeRunID")]
    if "foregroundSessionAndSubmit" not in run_block or "waitForAssistantOutput" not in run_block:
        print("Hermes shortcut regression: HermesAgentRunner.run must foreground Hermes and then wait on that visible session", file=sys.stderr)
        failed = True
    forbidden_run_fragments = ['"chat"', '"-Q"', '"--continue"', '"-q"', '"--image"']
    for forbidden in forbidden_run_fragments:
        if forbidden in run_block:
            print("Hermes shortcut regression: HermesAgentRunner.run must not execute the user turn through hidden Hermes chat query mode", file=sys.stderr)
            failed = True
            break

    job_block = runtime[runtime.find("private func runHermesQueuedJob"):runtime.find("private func deliverInformationFallback")]
    deliver_index = job_block.find("deliverResult")
    runner_index = job_block.find("hermesRunner.run")
    if deliver_index == -1 or runner_index == -1 or deliver_index < runner_index:
        print("Hermes shortcut regression: Hermes job must run the foreground Hermes session before dual delivery", file=sys.stderr)
        failed = True
    if "foregroundInteractiveSession(sessionID: hermesResult.sessionID)" in job_block:
        print("Hermes shortcut regression: runtime must not foreground Hermes only after result delivery", file=sys.stderr)
        failed = True
    if "ensureInteractiveSessionInBackground" in job_block:
        print("Hermes shortcut regression: voice-job completion must not leave Hermes hidden after result delivery", file=sys.stderr)
        failed = True
    if "activateOriginalTargetIfPossible" not in job_block:
        print("Hermes shortcut regression: clipboard paste must reactivate original target before delivery", file=sys.stderr)
        failed = True


    transition_block = runtime[runtime.find("private func confirmHermesContinuation"):runtime.find("private func captureHermesScreenContext")]
    capture_index = transition_block.find("captureHermesScreenContext")
    state_index = transition_block.find("recordingHermesInstruction")
    if capture_index == -1 or state_index == -1 or state_index < capture_index:
        print("Hermes shortcut regression: screen context must be captured when Option-only Hermes instruction mode starts", file=sys.stderr)
        failed = True
    if "screenshotURL: screenshotURL" not in job_block or "hermesRunner.run" not in job_block:
        print("Hermes shortcut regression: captured screenshot URL must be passed through to Hermes runner", file=sys.stderr)
        failed = True

    startup_block = runtime[runtime.find("private static func loadAndRun"):runtime.find("final class RuntimeState")]
    if "ensureHermesInteractiveSessionInBackground" in startup_block or "foregroundInteractiveSession" in startup_block:
        print("Hermes shortcut regression: app startup must not open or foreground Hermes before a voice result exists", file=sys.stderr)
        failed = True
    if "if options.config.hermesAgent.enabled" not in startup_block or "let hermesHint = options.config.hermesAgent.enabled" not in startup_block:
        print("Hermes shortcut regression: startup must hide Hermes hints when Hermes is disabled", file=sys.stderr)
        failed = True

    flags_block = runtime[runtime.find("private func handleFlags"):runtime.find("private func handleBluetoothChordLocked")]
    if "options.config.hermesAgent.enabled\n                && options.config.hotkeys.isHermesAgentContinuationPressed" not in flags_block:
        print("Hermes shortcut regression: Hermes continuation must be gated by hermes_agent.enabled", file=sys.stderr)
        failed = True

    hermes_block = runtime[runtime.find("private func stopAndRunHermesAgent"):runtime.find("private func deliverInformationFallback")]
    enqueue_index = hermes_block.find("enqueueHermesAgentJob")
    reset_index = hermes_block.find("self.transcribing = false", enqueue_index)
    runner_index = hermes_block.find("hermesRunner.run")
    if enqueue_index == -1 or reset_index == -1:
        print("Hermes shortcut regression: Hermes path must reset transcribing immediately after enqueue", file=sys.stderr)
        failed = True
    if runner_index != -1 and (reset_index == -1 or runner_index < reset_index):
        print("Hermes shortcut regression: stopAndRunHermesAgent must not await Hermes before releasing transcribing", file=sys.stderr)
        failed = True


    foreground_block = hermes[hermes.find("private func foregroundSessionAndSubmit"):hermes.find("private func copyPromptToClipboard")]
    if "interactiveSessionCommand" not in foreground_block or "sessionID: sessionID" not in foreground_block:
        print("Hermes shortcut regression: foreground voice run must open the exact Hermes session with --resume", file=sys.stderr)
        failed = True
    for required in ['tell application "System Events"', 'keystroke "v" using command down', "key code 36"]:
        if required not in foreground_block:
            print("Hermes shortcut regression: foreground voice run must paste and submit the prompt in Terminal", file=sys.stderr)
            failed = True
            break
    if '"chat"' in foreground_block or '"-Q"' in foreground_block or '"-q"' in foreground_block:
        print("Hermes shortcut regression: foreground voice run must not execute through hidden Hermes chat query mode", file=sys.stderr)
        failed = True

    export_block = hermes[hermes.find("private func exportAssistantOutput"):hermes.find("private func decodeSessionExport")]
    if '"sessions", "export"' not in export_block or '"--session-id"' not in export_block:
        print("Hermes shortcut regression: dual delivery must poll the visible Hermes session export", file=sys.stderr)
        failed = True
    if '"chat"' in export_block:
        print("Hermes shortcut regression: dual delivery must not start a second Hermes chat call", file=sys.stderr)
        failed = True

    prompt_block = hermes[hermes.find("private static func makePrompt"):hermes.find("private func currentClipboardText")]
    if "Decide semantically" not in prompt_block or "follow-up" not in prompt_block or "standalone" not in prompt_block:
        print("Hermes shortcut regression: Hermes prompt must delegate follow-up/reset semantics to the LLM", file=sys.stderr)
        failed = True
    forbidden_local_classifiers = [
        '.contains("follow', '.contains("weiter', '.contains("noch',
        '.contains("reset', '.contains("new task', '.contains("standalone',
        'range(of: "follow', 'range(of: "weiter', 'range(of: "reset',
    ]
    for forbidden in forbidden_local_classifiers:
        if forbidden in hermes or forbidden in runtime:
            print("Hermes shortcut regression: local keyword filters must not classify follow-up/reset semantics", file=sys.stderr)
            failed = True
            break
    if "do script" not in hermes or "if reusedExistingTab is false" not in hermes:
        print("Hermes shortcut regression: Terminal must run do script only when no reusable session exists", file=sys.stderr)
        failed = True
    if "--resume" not in hermes:
        print("Hermes shortcut regression: voice-job completion must foreground the exact returned Hermes session", file=sys.stderr)
        failed = True

    if config.get("audio_ducking", {}).get("enabled") is not True:
        print("Hermes shortcut regression: audio_ducking.enabled must default true", file=sys.stderr)
        failed = True
    if config.get("hermes_agent", {}).get("session_name") != "local-audio-voice-agent":
        print("Hermes shortcut regression: Hermes session name default changed", file=sys.stderr)
        failed = True

    if failed:
        return 1
    print("Hermes shortcut static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
