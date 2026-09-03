# App Behavior

## Shortcut State Transitions

| Input | Result |
| --- | --- |
| Hold `Command + Option`, release both | Transcribe one segment locally and deliver through `llm_output.paste`. |
| Tap physical `P` while the first `Command + Option` or `Control + Option` recording is active | Capture one ordered full-desktop screenshot; maximum five. |
| Release `Option` while holding `Command` | Finish the information segment and start the instruction segment. No automatic screenshot occurs. |
| Release `Command` after the transition | Send both transcripts plus zero to five captured images to the selected provider and deliver only a successful response. |
| Release `Command` first while holding `Option` | Finish normal local dictation; Hermes no longer uses this gesture. |
| Hold and release `Control + Option` in `dump` mode | Append the local transcript and captured images to Markdown. |
| Release `Control` first in `dump` mode | Enter the two-stage Dump command path; images are archived in Markdown but not sent to the provider. |
| Hold and release `Control + Option` in `hermes` mode | Send one spoken instruction and captured images to the visible Hermes session. |
| Hold and release the configured Bluetooth key | Use the unchanged Bluetooth output path. |

## `P` Screenshot Contract

- `P` is recognized during first-segment `.recordingInformation` for `.paste` and `.dump`, never Bluetooth.
- One physical key-down schedules one screenshot. Auto-repeat is ignored.
- The matching key-up clears the latch and rearms capture.
- Handled `P` key-down and key-up events do not reach the foreground app.
- Captures stay ordered and stop at five; the sixth request is ignored.
- Pressing `P` is optional. Paste commands send images to the provider, Dump archives them only in Markdown, and Hermes attaches them with native `/image` commands.
- Transitioning to the instruction segment never triggers a screenshot itself.
- Leaving the flow through local dictation, completion, error, or cancellation cleans temporary images.

## Provider Behavior

`command_provider` selects exactly one client:

- `openai`: Responses API, `gpt-5.6-luna`, `reasoning.effort: low`, `text.verbosity: low`, `store: false`, and `detail: low` image inputs.
- `cerebras`: Chat Completions, `gemma-4-31b`, with ordered image data URLs.
- `gemini`: `generateContent`, `gemini-3.5-flash`, the `x-goog-api-key` header instead of Bearer auth, and ordered `inlineData` image inputs.

The repository default is `openai`; this Mac's installed user config overrides it to `cerebras`. Keys come from the process environment or `.env` beside the active config.

If a provider request fails, the app emits no command result. It does not call another provider and does not deliver the information transcript as a provider-error fallback. If the instruction is empty before any request, it still delivers the information transcript.

## Diagnostics and Failed-Turn Lifecycle

For all three providers, one logical `request_id` connects the request summary, image metadata, every attempt, retry decision, and terminal failure. Logs expose prompt lengths, image path/size/MIME/Base64 length/SHA-256, payload size/build time, configured timeout, attempt `n/max`, duration/outcome, HTTP status, response bytes, provider request ID, retry reason, and final `NSError` domain/code. They exclude API keys, `Authorization`, and raw Base64 content.

On provider, Hermes, Markdown, or delivery failure, the app writes the newest failed turn to `~/Library/Application Support/fluid-push-to-talk/last-failed-command/`. The `0700` directory contains a `0600` `turn.json` and `0600` copies of captured images. A later failure replaces it through a staged backup-and-promote flow; startup recovery restores a valid backup after an interrupted promotion.

The retained turn is cleared only after a later provider or Hermes response is delivered successfully. Local dictation, an empty command, and other unrelated flows do not clear it. A timeout retry remains visible as two attempt records joined by the same logical request ID and a `retry_reason=timeout` record.

## Control + Option and Unchanged Paths

- `control_option_mode` is `dump` or `hermes`; missing legacy values default to `dump`.
- Markdown mode stores images under `attachments/YYYY-MM-DD/` beside the note and appends relative standard Markdown embeds after the text.
- Hermes mode uses one transcript as the instruction, preserves Clipboard/session context, attaches images in order, and returns through the original app or Clipboard.
- Continuous `go`/`stop` remains independent and text-only.
- Bluetooth capture, serial transport, and delivery routing remain unchanged.
- System audio ducking remains active during push-to-talk recording.
