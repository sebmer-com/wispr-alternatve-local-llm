# Features

## Local Dictation

- Records while the configured hotkey is held and transcribes with FluidAudio/CoreML.
- Applies replacements from `config/textReplacements.json` before delivery or command generation.
- Supports multilingual v3 and English v2 ASR plus explicit or automatic language selection.
- `Command + Option` released together stays local and delivers through `llm_output.paste`.

## Two-Stage Command Mode

- Releasing `Option` while holding `Command` finishes the information segment and starts the spoken instruction segment.
- Releasing `Command` transcribes both segments and sends them to the selected command provider.
- OpenAI uses the Responses API with `gpt-5.6-luna`, low reasoning, low text verbosity, `store: false`, and low-detail images.
- Cerebras uses Chat Completions with `gemma-4-31b`.
- Gemini uses `generateContent` with `gemini-3.5-flash` and the `x-goog-api-key` header instead of Bearer auth.
- The checked-in default is OpenAI; an installed user config may override it. This Mac's installed config selects Cerebras.
- A provider error produces no command output. There is no cross-provider or transcript fallback after a request error.
- An empty instruction skips the request and delivers the information transcript.

## Safe Request Diagnostics

- All three provider clients assign one logical request ID and emit structured request, image, attempt, retry, and terminal-failure records.
- Request records include provider/model, prompt character counts, image count, payload bytes, build duration, and timeout.
- Image records include ordered index, local path, byte count, MIME type, Base64 character count, and SHA-256.
- Attempt records include attempt number/maximum, duration, outcome, HTTP status, response bytes, and provider request ID.
- Retry records expose `timeout`, `http_429`, or `http_5xx`; terminal records include `NSError` domain and code.
- Logs never contain an API key, `Authorization` header, or raw Base64 body.

## Failed Command Retention

- Provider, Hermes, Markdown, and delivery failures replace `~/Library/Application Support/fluid-push-to-talk/last-failed-command/` with the newest failed turn through a staged, crash-recoverable promotion.
- `turn.json` stores provider/model, information, command, error, timestamp, and retained-image metadata; copied images sit beside it.
- Directory permissions are `0700`; manifest and image files are `0600`.
- Only a later successful provider or Hermes response plus successful delivery clears the bundle.
- Normal dictation and empty-command information fallback leave it untouched.

## Explicit Multi-Image Context

- While the first `Command + Option` or `Control + Option` recording is active, each physical `P` press captures one full-desktop screenshot.
- Zero images is valid; no screenshot is captured automatically when command mode starts.
- Capture order is preserved and at most five images are sent. A sixth press is ignored.
- A key-down latch ignores keyboard auto-repeat. The physical `P` key-up resets the latch for the next capture.
- Handled `P` key-down and key-up events are swallowed during capture mode.
- Screenshot permission or capture failure omits that image without stopping audio recording.
- Temporary images are deleted on success, failure, cancellation, normal dictation, and stale-file cleanup.

## Setup

- Guided setup asks for language, paste shortcut, OpenAI, Cerebras, or Gemini, the selected provider's hidden key, and the `Control + Option` mode.
- Writes `command_provider` to user config and preserves the other providers' keys in the adjacent `.env` file.
- Uses `OPENAI_API_KEY` for OpenAI, `CEREBRAS_API_KEY` for Cerebras, and `GEMINI_API_KEY` for Gemini.
- Keeps API keys out of JSON and enforces `.env` mode `0600`.

## Selectable Control + Option Mode

- `control_option_mode: dump` writes one transcript plus zero to five screenshots to Markdown.
- Permanent PNGs live under the note-relative `attachments/YYYY-MM-DD/` folder and appear as portable relative Markdown image links.
- The two-stage Dump command sends text only to the selected provider, then archives its result plus the captured screenshots in Markdown.
- `control_option_mode: hermes` sends one spoken instruction plus ordered native `/image` attachments to the visible Hermes session and returns the result to the original app or Clipboard.
- The old Command-first Hermes continuation gesture is removed.
- Terminal `go` and `stop` retain independent text-only continuous Markdown recording; `status`, `help`, and `quit` retain Tab completion.

## Optional Hermes Agent

- Hermes retains its persistent named session, current Clipboard context, visible Terminal execution, response export, and serialized job queue.
- OpenClaw is not offered because no independent OpenClaw runtime contract is installed.

## Optional Bluetooth Keyboard

- The configured Bluetooth hotkey records locally and routes through `llm_output.bluetooth`.
- The Swift ESP32 `KBD1` implementation and `--test-bluetooth-keyboard TEXT` diagnostic remain unchanged.

## Output and Recording

- Paste, dump, and Bluetooth routes independently support `clipboard`, `dump`, and `bluetooth-keyboard`.
- Clipboard delay and restoration remain configurable.
- Temporary WAV recordings are removed unless `--save-recordings` is enabled.
