# Local Audio Hermes Session Fixes Implementation Plan

> **For Hermes:** Do not implement until the user explicitly approves this plan. The current turn is planning only.

**Goal:** Fix the Hermes voice shortcut so it behaves like a real conversational Hermes session, does not block new recordings while Hermes is running, and only foregrounds Hermes when the run is finished.

**Architecture:** Split the current synchronous `HermesAgentRunner.run(...)` path into a background job model. The push-to-talk app should only use voice for capture/transcription; Hermes execution should happen asynchronously in its own queue/process, with each completed result delivered later. For an actual chat session, use Hermes' interactive CLI session model (`hermes -c local-audio-voice-agent`) for the user-facing Terminal, and use `hermes -c local-audio-voice-agent -z` only for non-interactive voice-submitted turns where we need a final result to paste back.

**Tech Stack:** Swift, macOS Process/AppleScript, Hermes CLI (`-c`, `-z`, interactive `hermes -c <name>`), existing FluidAudio transcription pipeline.

---

## Findings from Hermes repo/docs

- `hermes -z <prompt>` is explicitly a scripted one-shot mode: it prints only the final response to stdout and exits. Source: `~/.hermes/hermes-agent/hermes_cli/oneshot.py`.
- `hermes -c <session_name>` resumes the most recent session with that title/name and starts an interactive CLI/TUI chat. Docs confirm `-c "my project"` resumes the most recent named lineage.
- Therefore the current implementation (`hermes -c local-audio-voice-agent -z ...`) is good for a voice-submitted single turn, but it is not itself a live chat window. To give the user a real session they can chat with, the app must separately open an interactive `hermes -c local-audio-voice-agent` Terminal session.

---

## The three approved behavior points

### 1. Do not block new recordings while Hermes is running

Current bug:
- `AppRuntime.stopAndRunHermesAgent(...)` sets `transcribing = true` before transcription and keeps it true until the entire Hermes process finishes.
- `handleFlags(...)` begins with `guard !transcribing else { return }`, so while Hermes is running, all new shortcut captures are ignored.

Desired behavior:
- `transcribing` should only block microphone capture while audio transcription is actively happening.
- Once the Hermes instruction audio has been transcribed and the Hermes job has been queued/launched, `transcribing` must be reset to false.
- Hermes jobs should run independently in the background, so the user can immediately dictate another normal transcript or submit another Hermes turn.
- Use a serial Hermes job queue by default to preserve conversation order for the shared `local-audio-voice-agent` session. Multiple voice submissions while Hermes is busy should queue, not get dropped.

Implementation outline:
- Add a lightweight `HermesVoiceJob` model containing information transcript, instruction transcript, timing snapshot, and log/run id.
- In `stopAndRunHermesAgent(...)`, after both audio segments are transcribed, enqueue a Hermes job and immediately reset `transcribing = false` on `stateQueue`.
- Move `hermesRunner.run(...)` and result delivery into a separate background task/queue that does not affect recording eligibility.
- Add logs like `Hermes job queued (#N)` and `Hermes job running (#N)` so it is obvious whether a run is pending.

Files likely to change:
- `app/Sources/AppRuntime.swift`
- `app/Sources/HermesAgentRunner.swift`
- Possibly create `app/Sources/HermesVoiceJobQueue.swift` if the queue logic is cleaner outside `AppRuntime`.

Validation:
- Static regression: ensure `stopAndRunHermesAgent` clears `transcribing` before awaiting Hermes completion.
- Unit/static test: ensure new recordings are not gated by an active Hermes job flag.
- Manual test: start a long Hermes voice instruction, then immediately use Command+Option for normal dictation; recording should start.

---

### 2. Do not pop Terminal in the user's face on submit; foreground only when Hermes is finished

Current bug:
- `HermesAgentRunner.run(...)` calls `openTerminalLog(logURL)` before starting Hermes and again after output.
- That steals focus right after the user submits the voice instruction.

Desired behavior:
- On voice submit: do not activate Terminal.
- While Hermes is running: log in the background only.
- When Hermes completes: then foreground the result/session window once, so the user sees it only at the useful moment.
- If the user disables foregrounding in config, never activate Terminal.

Implementation outline:
- Split `openTerminalLog(...)` into separate methods:
  - `appendLog(...)` only writes in background.
  - `foregroundCompletion(...)` activates Terminal only after success/failure.
- Remove the pre-run Terminal activation.
- On completion, foreground either:
  1. the real interactive Hermes session window (preferred; see point 3), or
  2. a completion log window if interactive session launch is disabled/unavailable.
- Include success/failure status in the log before foregrounding.

Files likely to change:
- `app/Sources/HermesAgentRunner.swift`
- `app/Sources/Config/AppConfig.swift` if adding more precise config names, e.g. `foreground_on_completion`.
- `config/config.json`

Validation:
- Static regression: `HermesAgentRunner.run(...)` must not call Terminal activation before the Hermes process finishes.
- Manual test: submit Hermes instruction while focused in another app; focus should remain there until Hermes completes.

---

### 3. Provide a real interactive Hermes session that the user can chat with

Current mismatch:
- `hermes -c local-audio-voice-agent -z <prompt>` resumes/updates a named session, but it is one-shot and exits.
- The Terminal window currently tails a log, not a real Hermes chat UI.
- User wants a real Hermes session where they can keep chatting after voice submission.

Desired behavior:
- Voice submissions should still be possible as one-shot turns with `hermes -c local-audio-voice-agent -z ...`, because the app needs final stdout to paste/deliver.
- Separately, the app should maintain/open a real interactive Hermes Terminal session with `hermes -c local-audio-voice-agent` so the user can continue chatting manually.
- The interactive session should not pop immediately on submit. It should be opened or foregrounded only after completion, unless already open.
- Avoid opening duplicate Hermes Terminal tabs on every voice submission.

Implementation outline:
- Add a session-window controller in `HermesAgentRunner` or a new `HermesTerminalSessionController`:
  - Detect whether a Terminal tab/process already runs `hermes -c local-audio-voice-agent`.
  - If not present, launch it in Terminal with command:
    `cd <workdir> && hermes -c local-audio-voice-agent`
  - If present, foreground the existing window/tab on completion.
- Continue to submit voice turns with one-shot:
  `hermes -c local-audio-voice-agent -z <prompt>`
  because docs/source confirm this is the clean programmatic path that returns only final text.
- After the one-shot finishes, foreground/open the interactive session so the user can chat further in the actual Hermes REPL/TUI.
- Do not try to inject the prompt into an already-running interactive Hermes terminal via keystrokes; that is fragile and would conflict with the user typing. Use `-z` for voice turns and `-c` interactive for human follow-up.

Files likely to change:
- `app/Sources/HermesAgentRunner.swift`
- Possibly create `app/Sources/HermesTerminalSessionController.swift`
- `app/Sources/Config/AppConfig.swift`
- `config/config.json`
- Docs/tests.

Validation:
- `hermes -c local-audio-voice-agent -z 'Reply exactly: OK'` still returns `OK`.
- After a voice Hermes job completes, a Terminal tab is opened/foregrounded running an interactive `hermes -c local-audio-voice-agent` session, not `tail -f`.
- Repeating voice submissions should reuse/foreground the same session window, not create unbounded duplicate tabs.

---

## Tests to add/update

- Update `tests/hermes_shortcut_static_case.py`:
  - assert no pre-run Terminal activation.
  - assert a background/queued Hermes job path exists.
  - assert `transcribing` is released before awaiting Hermes completion.
  - assert interactive `hermes -c local-audio-voice-agent` launch path exists separately from `-z`.
- Add/extend CLI/help/docs assertions for the new behavior wording.
- Run:
  - `cd app && swift build`
  - `python3 tests/run_all.py --skip-llm`
  - `hermes -c local-audio-voice-agent -z 'Reply exactly: OK'`

---

## Risks / open questions

- Terminal tab reuse via AppleScript can be brittle. The safe first implementation can avoid duplicate tabs by tracking a sentinel/process command and only creating a new tab if no matching `hermes -c local-audio-voice-agent` process exists.
- If an interactive Hermes session is open while a `-z` one-shot writes to the same named session, Hermes' session DB should handle named resume, but concurrent access/order should be serialized on the local-audio side to avoid racing messages.
- Foregrounding only on completion is clear for long tasks, but for very short replies the Terminal may appear quickly. That is acceptable because it is completion, not submit-time focus theft.

---

## Approval checkpoint

No code should be changed until the user approves these three behavior points.
