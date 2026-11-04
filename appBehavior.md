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

Each command selects one explicit `command_provider`, `command_auth`, and `command_model` combination:

- `openai`: default model `gpt-6-luna`. `hermes` authentication uses the existing Hermes `openai-codex` login. `api_key` uses the native Responses API with the configured model, `reasoning.effort: low`, `text.verbosity: low`, `store: false`, and `detail: low` image inputs.
- `anthropic`: default model `claude-haiku-5-5`. `hermes` uses the existing Hermes Anthropic OAuth login; `api_key` uses the native Messages API with `ANTHROPIC_API_KEY`, the configured model, and ordered image inputs. The default ID does not guarantee model/account access.
- `cerebras`: Chat Completions, `qwen-3.8-27b`, low reasoning, 4096 completion tokens including reasoning, with ordered image data URLs. Missing answer text and token-limit truncation fail without delivery.

Fresh defaults are `openai` / `hermes` / `gpt-6-luna`, with no app API key. Legacy configs missing `command_auth` keep `api_key` behavior; explicitly saved model IDs are not replaced automatically. Cerebras remains API-key-only. Change provider/auth/model together through `fluid-push-to-talk setup` or `fluid-push-to-talk config` → Edit core setup, or edit app config JSON; see [README](README.md#setup-and-provider-selection) for explicit examples and official references.

Hermes authentication requires a compatible existing Hermes runtime, delegates credentials and refresh to Hermes, inherits `HERMES_HOME`, and does not copy secrets or change Hermes' default model. This command bridge performs direct inference without agent/tools; it is distinct from the visible Hermes Agent shortcut. Exact same-provider `gpt-*` and `claude-*` model IDs are supported; selection does not prove account access. A subscription login is not a public API key, and account access and limits still apply. Anthropic OAuth requires Claude Max plus purchased extra usage credits, not the base Max allowance. Native OpenAI, Anthropic, and Cerebras API-key requests are separately usage-based billed; keys come from the environment or `.env` beside the active config. No automatic paid/authentication fallback is allowed.

`config doctor` checks selected authentication and the Hermes model catalog, not necessarily a live inference request. Availability can be unknown; login/catalog checks must not be presented as proof the model works.

If a provider request fails, the app emits no command result. It does not call another provider, switch authentication, or deliver the information transcript as a provider-error fallback. If the instruction is empty before any request, it still delivers the information transcript.

## Diagnostics and Failed-Turn Lifecycle

Command diagnostics use one logical `request_id` to connect the request summary, image metadata, attempts, retry decisions, and terminal failure. Native HTTP logs expose prompt lengths, image path/size/MIME/Base64 length/SHA-256, payload size/build time, configured timeout, attempt `n/max`, duration/outcome, HTTP status, response bytes, provider request ID, retry reason, and final `NSError` domain/code. Logs exclude API keys, OAuth tokens, `Authorization`, and raw Base64 content; bridge logs must follow the same secret-safe boundary without claiming native HTTP fields are always available.

On provider, Hermes, Markdown, or delivery failure, the app writes the newest failed turn to `~/Library/Application Support/fluid-push-to-talk/last-failed-command/`. The `0700` directory contains a `0600` `turn.json` and `0600` copies of captured images. A later failure replaces it through a staged backup-and-promote flow; startup recovery restores a valid backup after an interrupted promotion.

The retained turn is cleared only after a later provider or Hermes response is delivered successfully. Local dictation, an empty command, and other unrelated flows do not clear it. A timeout retry remains visible as two attempt records joined by the same logical request ID and a `retry_reason=timeout` record.

## Control + Option and Unchanged Paths

- `control_option_mode` is `dump` or `hermes`; missing legacy values default to `dump`.
- Markdown mode stores images under `attachments/YYYY-MM-DD/` beside the note and appends relative standard Markdown embeds after the text.
- Hermes mode uses one transcript as the instruction, preserves Clipboard/session context, attaches images in order, and returns through the original app or Clipboard.
- Continuous `go`/`stop` remains independent and text-only.
- Bluetooth capture, serial transport, and delivery routing remain unchanged.
- System audio ducking remains active during push-to-talk recording.
