# Local Audio Hermes Shortcuts Implementation Plan

> **For Hermes:** After approval, use the coding-agent-cli-operations skill and run Codex in `/Users/sebastianmertens/local-audio` for the implementation, then verify diffs and tests directly.

**Goal:** Add two Elson-inspired features to `local-audio`: automatic system-audio muting while push-to-talk is held, and a new Hermes Agent shortcut flow where releasing Command while keeping Option held records an instruction and sends the resulting task to Hermes.

**Architecture:** Keep the current local dictation and local command-generation paths intact. Add a separate audio-ducking service modeled after Elson's robust `SystemAudioDucker`, and add a distinct `.hermesAgent` recording state/route so Hermes agent mode does not break the existing two-step local LLM command mode. Hermes execution should use the documented CLI one-shot/session-resume entrypoints and optionally foreground a Terminal transcript window.

**Tech Stack:** Swift Package Manager macOS CLI app, CoreAudio, AppleScript via `/usr/bin/osascript`, Hermes CLI (`hermes -z`, `hermes -c`, `hermes chat --continue`), existing Python static tests under `tests/`.

---

## Current context discovered

- `local-audio` is cloned at `/Users/sebastianmertens/local-audio` and has been fast-forward pulled to `9b9f647 added .env.example`.
- Codex CLI is installed: `/opt/homebrew/bin/codex`, version `codex-cli 0.130.0`.
- Elson source exists at `/Users/sebastianmertens/Documents/GitHub/elson.ai`.
- Relevant Elson implementation:
  - `/Users/sebastianmertens/Documents/GitHub/elson.ai/Elson/Services/SystemAudioDucker.swift`
  - It tries CoreAudio mute/volume first, AppleScript mute/volume second, then output-device switching, and restores saved state on end.
- Relevant local-audio implementation:
  - `/Users/sebastianmertens/local-audio/app/Sources/AppRuntime.swift`
  - `/Users/sebastianmertens/local-audio/app/Sources/Config/HotkeysConfig.swift`
  - `/Users/sebastianmertens/local-audio/app/Sources/Config/AppConfig.swift`
- Existing local-audio shortcut state machine:
  - `Command + Option` starts `.paste` information recording.
  - Existing continuation for `.paste` is Command-only, i.e. release Option first while holding Command, then it records a local LLM command.
  - `Control + Option` starts `.dump`.
  - `Right Shift` is Bluetooth-only.
- Hermes CLI docs/installed help confirm:
  - Programmatic one-shot: `hermes -z "prompt"` prints only final response text.
  - Session continuation: `hermes -c "session name"` / `hermes chat --continue "session name"` resumes by name.
  - Interactive Terminal/TUI can be launched with `hermes`, `hermes --cli`, or `hermes --tui`.

---

## Desired behavior

### Feature 1: mute music/system audio while shortcut is held

When a user starts any push-to-talk capture, local-audio should immediately mute/duck system output so background music does not leak into the microphone. When recording ends or fails, output state must be restored exactly.

Scope:
- Apply to normal paste, dump, Bluetooth, command/instruction, and continuous-dump recordings unless disabled in config.
- Restore on every stop path, error path, empty recording path, and Ctrl+C/process termination where feasible.
- Default enabled, because the user asked for this behavior.

### Feature 2: Hermes Agent flow via Command-release + Option-held

For `Command + Option` only:
- Holding `Command + Option`: records the information/context segment as today.
- Releasing **Command first** while still holding Option: stop information segment, immediately start recording a Hermes instruction segment.
- Releasing Option: stop instruction segment, transcribe both segments, build a Hermes prompt, and send it to Hermes.

Keep existing behavior:
- Releasing **Option first** while holding Command should keep the current local command-generation path unless we explicitly decide to replace it later.
- Simple release of both keys should still paste raw dictation.

Hermes behavior:
- Use a stable session name, e.g. `local-audio-voice-agent`, so repeated agent-mode shortcut invocations continue the same Hermes conversation unless Hermes/session state decides otherwise.
- Use `hermes -c "local-audio-voice-agent" -z <prompt>` for reliable programmatic output capture.
- Show/foreground a Terminal window for visibility. The first implementation should create a Terminal transcript/log window that shows the sent prompt and final Hermes output. A later enhancement can keep a truly interactive Hermes TUI open, but direct stdin-driving prompt_toolkit from Swift is fragile.
- Return Hermes final output through the configured local-audio output path, initially clipboard/paste for `.paste`.

---

## Step-by-step plan

### Task 1: Add a robust SystemAudioDucker to local-audio

**Objective:** Port/adapt Elson's system audio muting logic into local-audio with local naming/logging and without Elson app dependencies.

**Files:**
- Create: `app/Sources/SystemAudioDucker.swift`
- Reference only: `/Users/sebastianmertens/Documents/GitHub/elson.ai/Elson/Services/SystemAudioDucker.swift`

**Implementation notes:**
- Copy the core design from Elson:
  - `begin()` saves prior state and mutes/sets volume to zero.
  - `end()` restores prior state.
  - Try CoreAudio first, AppleScript fallback, output-device switching last.
- Change logger/subsystem or use local `log(...)`/`fputs` style to match local-audio.
- Make it safe to call `begin()` repeatedly and `end()` repeatedly.

**Verification:**
- `cd app && swift build`
- Add/adjust a static test if the repository uses static Swift text checks for feature presence.

### Task 2: Add audio-ducking config

**Objective:** Make muting configurable and default-on.

**Files:**
- Modify: `app/Sources/Config/AppConfig.swift`
- Modify: `config/config.json`
- Modify if needed: `README.md`

**Implementation notes:**
- Add something like:
  - `struct AudioDuckingConfig: Decodable { var enabled = true }`
  - `var audioDucking = AudioDuckingConfig()`
  - Coding key `audio_ducking`
- In `config/config.json` add:
  - `"audio_ducking": { "enabled": true }`

**Verification:**
- `cd app && swift build`
- `./install.sh` should still copy config cleanly.
- `app/.build/debug/fluid-push-to-talk --help` should still work.

### Task 3: Wire audio ducking into recording lifecycle

**Objective:** Engage mute exactly when capture begins and release it when the recording segment is done or aborted.

**Files:**
- Modify: `app/Sources/AppRuntime.swift`

**Implementation notes:**
- Add `private let audioDucker = SystemAudioDucker()` to `PushToTalkController` or a small wrapper service.
- In `startRecording(...)` and `startContinuousDumpLocked()`, call `audioDucker.begin()` after recorder start succeeds, or before start if tests show lower latency and still safe.
- On all `recorder.stop()` paths, call `audioDucker.end()` immediately after recording stops and before transcription/LLM work.
- In two-step flows, decide whether to keep audio muted across the gap between info and instruction. Preferred: keep muted continuously from initial info start through instruction stop, to avoid music bleeding into the second segment.
- Ensure `audioDucker.end()` is called in catch/failure paths and when `confirmContinuation` fails to restart recording.

**Verification:**
- Static tests can assert `begin()`/`end()` calls exist in the expected lifecycle methods.
- Manual smoke: start app, hold shortcut while music plays, observe system output mutes and restores after release.

### Task 4: Extend the hotkey state model for Hermes Agent mode

**Objective:** Add a separate Hermes instruction state triggered by releasing Command first while holding Option.

**Files:**
- Modify: `app/Sources/Config/HotkeysConfig.swift`
- Modify: `app/Sources/AppRuntime.swift`

**Implementation notes:**
- Add state:
  - `case recordingHermesInstruction(informationURL: URL)` or `case recordingAgentInstruction(action: HotkeyAction, informationURL: URL)`.
- Add helper to `HotkeysConfig`:
  - Existing `.paste` continuation remains Command-only for local command generation.
  - New Hermes trigger for `.paste`: Option-only, i.e. `flags.contains(.maskAlternate)` and no Command/Control/Shift.
- In `.recordingInformation(.paste)`:
  - If Option-only after grace delay: stop info recording, start instruction recording, set Hermes state, log `recording Hermes instruction...`.
  - If Command-only after grace delay: preserve existing local command mode.
  - If neither: stop and transcribe/paste raw dictation.
- Add a separate grace work item or unify continuation confirmation so accidental simultaneous key-up does not falsely enter Hermes mode.

**Verification:**
- Add/adjust static tests for:
  - Command+Option -> both released => raw paste path.
  - Command+Option -> Option-only => Hermes path.
  - Command+Option -> Command-only => existing command path.
  - Control+Option behavior unchanged.

### Task 5: Add Hermes command runner service

**Objective:** Encapsulate Hermes CLI execution, prompt construction, output capture, and Terminal foreground display.

**Files:**
- Create: `app/Sources/HermesAgentRunner.swift`
- Modify: `app/Sources/Config/AppConfig.swift`
- Modify: `config/config.json`

**Implementation notes:**
- Add config, default values:
  - `hermes.enabled = true`
  - `hermes.executable = "hermes"`
  - `hermes.session_name = "local-audio-voice-agent"`
  - `hermes.workdir = "/Users/sebastianmertens"` or repo cwd, configurable
  - `hermes.foreground_terminal = true`
  - `hermes.timeout_seconds = 900`
- Runner should build a prompt like:
  - `Context transcript:\n<information>\n\nUser instruction:\n<command>\n\nRespond with the final answer/result. If tool use is needed, do it. Keep the answer concise unless the instruction asks otherwise.`
- Programmatic command should be one-shot and resumable:
  - `/usr/bin/env hermes -c local-audio-voice-agent -z <prompt>`
- Capture stdout as Hermes final response. Capture stderr separately for diagnostics.
- Do not pass secrets in command-line arguments except the user prompt. If prompt length becomes an issue, use stdin or a temp file wrapper script in a follow-up improvement.

**Terminal foreground display:**
- Use `osascript` to open/activate Terminal with a safe command that tails a local log file for the latest Hermes run or prints the result after completion.
- Safer first version:
  - Swift writes prompt/status/output to `~/Library/Application Support/fluid-push-to-talk/hermes-agent.log`.
  - Terminal command: `tail -f` that log, or `less +G`/`tail -n` after completion.
  - Activate Terminal after launching Hermes and again when output is ready.
- Avoid trying to drive a live interactive Hermes prompt from Swift initially; prompt_toolkit/TUI input automation is much more fragile than `hermes -z`.

**Verification:**
- Unit/static test can invoke runner with a fake executable (`/bin/echo`) or small shell script to avoid real Hermes network calls.
- Manual CLI smoke after build:
  - Run a fake/test command if config supports it.
  - Then real small Hermes prompt: `hermes -c local-audio-voice-agent -z "Reply with OK"`.

### Task 6: Route Hermes result into existing delivery path

**Objective:** After Hermes returns, deliver the result like a normal generated command result.

**Files:**
- Modify: `app/Sources/AppRuntime.swift`

**Implementation notes:**
- Add `stopAndRunHermesAgent(informationURL:commandURL:)` parallel to `stopAndGenerateCommandResult`.
- It should:
  1. Stop instruction recording.
  2. Transcribe information and instruction segments.
  3. Log `[information]`, `[hermes instruction]`.
  4. Call `HermesAgentRunner.run(...)`.
  5. Log `[hermes result]`.
  6. Deliver result through `deliverResult(result, action: .paste, timing: timing)`.
  7. Preserve/delete recordings as existing code does.
  8. Clear `transcribing`, reset timing, and restore audio ducking.
- If Hermes fails, paste/dump a clear error only if useful; otherwise log to stderr and keep the transcript in the Terminal/log.

**Verification:**
- Static tests for new state and route.
- Real smoke with a short Hermes prompt once user approves implementation.

### Task 7: Update docs/help text

**Objective:** Make the new gestures discoverable.

**Files:**
- Modify: `README.md`
- Modify: help text in `app/Sources/CLI/Options.swift` or wherever usage text is generated
- Modify: `appBehavior.md` if it contains shortcut reference

**Docs text should say:**
- Hold `Command + Option` to record/paste normal dictation.
- Release `Option` first while holding `Command` for existing local command rewrite.
- Release `Command` first while holding `Option` for Hermes Agent mode; release Option after speaking the instruction.
- Audio output is muted while recording and restored after capture.

**Verification:**
- `app/.build/debug/fluid-push-to-talk --help` contains updated shortcut copy.

### Task 8: Run full verification and restart app

**Objective:** Produce a working artifact, not just code.

**Commands:**
- `cd /Users/sebastianmertens/local-audio/app && swift build`
- `cd /Users/sebastianmertens/local-audio && python3 tests/run_all.py`
- If tests are too slow or require missing credentials, run `python3 tests/run_all.py --skip-llm` and report exactly why.
- `cd /Users/sebastianmertens/local-audio && ./restart.sh`
- Verify process is running with `pgrep -fl "fluid-push-to-talk|Fluid Push To Talk"`.

**Manual validation after restart:**
- Music playing + hold shortcut => audio mutes; release => audio restores.
- Command+Option normal release => normal paste.
- Command+Option, release Option first => current local command path still works.
- Command+Option, release Command first, speak Hermes instruction, release Option => Terminal foregrounds and Hermes output is delivered.

---

## Risks / tradeoffs / open questions

- The user's phrase says `Command loslasse und Option noch gehalten`; local-audio currently uses the opposite release order for local command mode. Plan preserves both: Command-first becomes Hermes, Option-first remains existing local command mode.
- CoreAudio muting differs by output device. Elson's fallback chain is robust, but output-device switching can be surprising. Keep logs and config toggle.
- `hermes -z` is reliable for capturing final output but not a true live interactive TUI. The first version should show a foreground Terminal log. A true persistent interactive Hermes Terminal can be added later if needed.
- Session continuity with `hermes -c local-audio-voice-agent` should work per CLI help, but exact title creation/lineage behavior must be verified during implementation.
- Passing long prompts as command-line arguments can hit shell/argv limits. If this becomes an issue, switch to stdin/temp-file wrapper.

---

## Approval checkpoint

Do not implement code until Sebastian approves this plan. After approval, run Codex in the local-audio repo for implementation, then independently inspect the diff, run Swift build + tests, restart the app, and report real output.
