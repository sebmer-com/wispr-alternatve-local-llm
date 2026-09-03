# Test Plan

This plan covers the three-provider command architecture, selectable `Control + Option` mode, Markdown image attachments, one-segment Hermes, and explicit `P` screenshot workflow. Physical hotkeys, microphone capture, foreground paste, permissions, Hermes Terminal control, and Bluetooth still need manual macOS verification.

## Automated Suite

```bash
python3 tests/run_all.py
```

Without live API checks:

```bash
python3 tests/run_all.py --skip-llm
```

Optional five-image live checks for OpenAI, Cerebras, and Gemini:

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```

Report every skipped live check explicitly. Do not put keys, screenshots, or transcript content in test output.

## Required Automated Coverage

### Build and Configuration

- Swift build and Swift tests pass.
- Checked-in JSON parses and defaults `command_provider` to `openai`.
- Checked-in JSON defaults `control_option_mode` to `dump`; missing legacy values decode as `dump` and `hermes_agent.enabled` is not written.
- `AppConfig` encodes and decodes `openai`, `cerebras`, and `gemini`.
- Installed config may override the repository default without changing tracked config.
- Setup asks for provider choice, only the selected provider's hidden key, and Markdown Dump or Hermes for `Control + Option`.
- Updating one key preserves the other key and enforces `.env` mode `0600`.

### OpenAI Client

- Uses only `https://api.openai.com/v1/responses` and `gpt-5.6-luna`.
- Sends `reasoning.effort: low`, `text.verbosity: low`, and `store: false` without an artificial output-token cap.
- Supports zero images.
- Encodes one through five ordered PNGs as Base64 `input_image` parts with `detail: low`.
- Decodes output and handles incomplete or empty responses as errors.
- Retries HTTP `429`, `5xx`, and timeout once.

### Cerebras Client

- Uses only `https://api.cerebras.ai/v1/chat/completions` and `gemma-4-31b`.
- Supports zero images and preserves one-to-five image order in Chat Completions content parts.
- Decodes output and handles malformed or empty responses as errors.
- Retries HTTP `429`, `5xx`, and timeout once.

### Gemini Client

- Uses only `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent` and `gemini-3.5-flash`.
- Sends the API key in the `x-goog-api-key` header, never as an `Authorization` bearer token.
- Supports zero images.
- Encodes one through five ordered PNGs as Base64 `inlineData` parts, with no data-URL prefix, alongside the text part, preserving capture order.
- Decodes the joined candidate text and handles a malformed or empty payload as an error.
- Treats a populated `promptFeedback.blockReason`, or a `finishReason` other than `STOP`/`MAX_TOKENS`, as a distinct blocked-content error rather than a transport failure.
- Retries HTTP `429`, `5xx`, and timeout once.

### Provider Isolation

- Runtime constructs only the provider selected by `command_provider`.
- No request failure invokes the other provider.
- `CommandResultGenerator` propagates provider errors instead of returning the information transcript.
- Runtime logs the provider failure and delivers no command output.
- An empty instruction remains a pre-request information-transcript fallback.

### Structured Diagnostics

- OpenAI, Cerebras, and Gemini use one logical request ID across summary, attempt, retry, and terminal records.
- Request summary asserts provider/model, system/user/total prompt character counts, image count, payload bytes, payload build milliseconds, and timeout.
- Per-image records assert path, bytes, MIME, Base64 character count, and SHA-256 without raw Base64.
- Attempt results assert `attempt=n/max`, duration, outcome, HTTP status, response bytes, and `x-request-id`/`request-id` metadata.
- Retry records distinguish `timeout`, `http_429`, and `http_5xx`.
- Terminal timeout asserts `NSError` domain `NSURLErrorDomain` and code `-1001`.
- Captured logs never contain the API key, `Authorization` value, or raw Base64 content.

### Failed Command Store

- A provider, Hermes, Markdown, or delivery failure writes `turn.json` and ordered image copies under `last-failed-command/`.
- The manifest preserves timestamp, provider/model, information, command, error, and image filename/bytes/SHA-256 metadata.
- Root permissions are `0700`; `turn.json` and retained images are `0600`.
- A newer failure replaces the previous turn through a staged backup-and-promote flow; startup recovery restores a valid backup after an interrupted promotion.
- Only successful provider or Hermes response plus successful delivery clears the bundle.
- Local dictation and empty-command fallback do not clear it.

### Physical `P` Hotkey

- Uses macOS keycode `35` for physical `P`.
- Accepts captures during first-segment paste and `Control + Option` recordings, but never Bluetooth.
- Ignores keyboard auto-repeat and uses key-up to reset the physical-key latch.
- Swallows handled key-down and key-up events.
- Preserves screenshot task order and caps the list at five.
- Does not capture automatically during the transition to instruction recording.
- Cleans screenshot files after local dictation, command completion, provider error, cancellation, and stale-file recovery.

### Markdown Images and Hermes

- Markdown dump supports zero, one, and five ordered images.
- Images are copied to `attachments/YYYY-MM-DD/` beside the note with collision-free filenames and relative `![Screenshot N](...)` embeds.
- A failed note write rolls back newly copied attachments while preserving the temporary sources for retention.
- A two-stage Dump command sends no images to OpenAI/Cerebras/Gemini but writes them beside the provider result.
- Hermes uses one speech segment and repeated native `/image` commands before the prompt; paths containing spaces remain intact.
- A stale stored session ID is rejected even when `hermes sessions export` exits zero with `Session not found`; the state is removed and a new named session is created.
- Terminal tab state and markers include the concrete session ID so a recreated session cannot reuse an obsolete visible tab.
- `--test-hermes-instruction` plus repeated `--test-hermes-image` exercises the real visible runner without microphone input.
- The old Command-first Hermes transition is absent, while visible session reuse, export, original-target delivery, timeout, cleanup, and failure retention remain covered.

### Existing Regressions

- Audio recorder stability, text replacement, and paste spacing.
- Command and Hermes hotkey transitions.
- Markdown and continuous Dump behavior.
- Bluetooth protocol and delivery.
- Installer, launch, CLI help, config doctor, and single-instance behavior.

## Manual macOS Checks

### No-Image Command

1. Start the app and focus a writable field.
2. Hold `Command + Option` and dictate information without pressing `P`.
3. Release `Option`, dictate the instruction, then release `Command`.
4. Confirm a successful result is delivered and no screenshot file was created.

### One and Five Images

1. Grant Screen & System Audio Recording permission to the launching terminal.
2. During the first `Command + Option` recording, tap and release physical `P` once.
3. Complete the instruction and confirm the selected provider receives one image.
4. Repeat with five deliberate `P` taps and confirm order is preserved.
5. Hold `P` and confirm auto-repeat creates no extra captures.
6. Attempt a sixth tap and confirm it is ignored.
7. Confirm temporary files are removed after completion.

### Scope and Cleanup

- Press `P` outside supported first recordings and confirm normal key behavior.
- Capture an image, release both modifiers for local dictation, and confirm the image is deleted without upload.
- Capture images, trigger a provider error, and confirm there is no pasted/dumped output and all images are deleted.
- Deny screenshot permission, press `P`, and confirm audio plus a zero-image command still work.

### Provider Selection and Failure

- Run setup for OpenAI and verify only `OPENAI_API_KEY` changes.
- Run setup for Cerebras and verify only `CEREBRAS_API_KEY` changes.
- Run setup for Gemini and verify only `GEMINI_API_KEY` changes.
- Confirm repository config still defaults to OpenAI while this Mac's installed config selects Cerebras.
- Force each provider to fail and confirm no cross-provider request and no transcript fallback occurs.
- Trigger a timeout and confirm attempt 1, `retry_reason=timeout`, attempt 2, and terminal domain/code remain correlated by one logical request ID.

### Retained Failure Bundle

1. Complete a provider, Hermes, or Markdown turn with screenshots and force request or delivery failure.
2. Confirm `~/Library/Application Support/fluid-push-to-talk/last-failed-command/turn.json` and the image copies exist.
3. Confirm directory mode `0700` and file modes `0600`.
4. Trigger a second failure and confirm it replaces the first bundle.
5. Perform local dictation and an empty-command fallback; confirm neither clears the bundle.
6. Complete and deliver a successful provider or Hermes turn; confirm the directory is removed.

### Control + Option Modes and Unchanged Features

- Select Markdown mode, record with 0/1/5 images, and verify the permanent files plus relative links in the note.
- In two-stage Markdown mode, verify the provider sees text only while the note receives the result and images.
- Select Hermes mode, record one instruction with 0/1/5 images, and verify native attachments, visible session, and result handoff.
- Release Command first during `Command + Option` and verify it performs local dictation rather than Hermes.
- Verify terminal `go`/`stop` remains text-only.
- Verify ESP32 Bluetooth typing and routing.
