# FluidAudio Push To Talk

FluidAudio Push To Talk is a native macOS 14+ voice-dictation app for Apple Silicon. Audio transcription runs locally with FluidAudio/CoreML. Two-stage spoken commands use OpenAI, Cerebras, or Gemini, selected during setup.

## Features

- Local push-to-talk transcription and paste.
- Two-stage command flow: dictate information, release `Option`, dictate an instruction, then release `Command`.
- Up to five optional screenshots, captured explicitly with physical `P` during the first `Command + Option` or `Control + Option` segment.
- OpenAI Responses with `gpt-5.6-luna`, low reasoning, and low-detail images.
- Cerebras Chat Completions with `gemma-4-31b`.
- Gemini `generateContent` with `gemini-3.5-flash`.
- `Control + Option` selectable as Markdown Dump or one-segment Hermes Agent mode, plus optional ESP32 Bluetooth output.

See [appBehavior.md](appBehavior.md) for exact shortcut behavior.

## Install

Run this on the target Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/sebmer-com/wispr-alternatve-local-llm/main/github-install.sh | bash -s -- --reset-state --setup
```

For an existing checkout:

```bash
./install.sh --reset-state --setup
```

The installer builds the app, links `fluid-push-to-talk` into `~/.local/bin`, opens setup, runs `config doctor`, and restarts the app. Both commands above reset installed state; use them only when that is intended.

## Setup and Provider Selection

The setup wizard asks for:

1. Transcription language.
2. Paste shortcut.
3. Command provider: OpenAI, Cerebras, or Gemini.
4. The selected provider's API key, entered without echo.
5. `Control + Option`: Markdown Dump or Hermes Agent.

The checked-in `config/config.json` defaults to `command_provider: "openai"`. The installed user config on this Mac overrides that value to `cerebras`; this local choice is not committed to the repository.

Secrets are stored in `.env` beside the active user config, normally `~/.config/fluid-push-to-talk/.env`, with permissions `0600`:

- OpenAI reads `OPENAI_API_KEY`.
- Cerebras reads `CEREBRAS_API_KEY`.
- Gemini reads `GEMINI_API_KEY`.

Changing providers does not delete the other key. At request time the app calls only the selected provider; it never falls back across providers.

Configure advanced Hermes, continuous Dump, and Bluetooth behavior separately with:

```bash
fluid-push-to-talk config
```

## Daily Use

```bash
./restart.sh
./stop.sh
```

Default shortcut behavior:

- `Command + Option`: hold both keys to record; release both to transcribe locally and paste.
- During that first recording, tap physical `P` zero to five times to capture ordered full-desktop screenshots.
- Release `Option` while holding `Command`: start the spoken instruction. No screenshot is captured automatically.
- Release `Command`: send both transcripts and the captured images to the selected provider, then paste a successful result.
- Release `Command` first while holding `Option`: finish normal local dictation; this gesture no longer starts Hermes.
- `Control + Option` in Markdown mode: speak once and release to append the transcript and captured screenshots to the configured note. Releasing `Control` first retains the two-stage provider command, but its screenshots are archived only in Markdown and are not sent to the provider.
- `Control + Option` in Hermes mode: speak one instruction, optionally capture screenshots with `P`, and release either modifier to open the visible Hermes session. Hermes receives the images through native `/image` attachments.
- Configured Bluetooth key: use the unchanged ESP32 keyboard path.

The `P` key works during the first `Command + Option` or `Control + Option` recording. A physical key latch ignores auto-repeat; `keyUp` rearms the next capture. The app swallows the matching `P` key events so they do not reach the foreground app. A sixth capture is ignored.

With zero `P` presses, the command request contains no images. Releasing both modifiers without entering command mode discards and deletes any captured command screenshots.

## Command Providers

### OpenAI

- Endpoint: `https://api.openai.com/v1/responses`
- Model: `gpt-5.6-luna`
- Reasoning effort: `low`
- Text verbosity: `low`
- Image input: Base64 PNG `input_image` entries with `detail: low`
- Response storage: disabled

### Cerebras

- Endpoint: `https://api.cerebras.ai/v1/chat/completions`
- Model: `gemma-4-31b`
- Image input: ordered Base64 data URLs in Chat Completions content parts

### Gemini

- Endpoint: `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent`
- Model: `gemini-3.5-flash`
- Auth header: `x-goog-api-key` (not Bearer auth)
- Image input: ordered Base64 `inlineData` parts alongside the text part, no data-URL prefix

All three clients accept zero through five images in capture order. If the selected provider returns an error after its own retry handling, the app logs the failure and produces no command output. It does not call another provider and does not paste the information transcript as an error fallback. An empty spoken instruction remains a pre-request case and delivers the information transcript locally.

Every provider request emits structured diagnostics under one logical `request_id`. Request fields are `provider`, `model`, `prompt_chars`, `system_prompt_chars`, `user_prompt_chars`, `image_count`, `timeout_seconds`, `payload_bytes`, and `build_duration_ms`. Each image adds `index`, `path`, `bytes`, `mime`, `base64_chars`, and `sha256`. Attempt/result fields include `attempt=n/max`, `outcome`, `duration_ms`, `http_status`, `response_bytes`, and `response_request_id`; retries add `retry_reason`, and terminal failures add `error_domain` plus `error_code`.

Timeouts are visible as a failed attempt, `retry_reason=timeout` when another attempt is allowed, the next `attempt=n/max`, and a terminal failure record if the retry also fails. Diagnostics never include API keys, the `Authorization` header, or raw Base64 image content. Prompt text is represented by character counts rather than copied into request logs.

## Screenshot Privacy and Cleanup

Screenshots are opt-in: no mode captures one unless the user presses `P` during a supported first recording. Each capture contains the visible full desktop and may include sensitive content. Paste commands send them to the selected provider; Dump commands archive them only in Markdown; Hermes attaches them natively to the visible agent turn.

Successful Markdown dumps copy screenshots permanently to `attachments/YYYY-MM-DD/` beside the note and append portable relative `![Screenshot N](...)` links. These attachment copies are user data and are never removed by temporary screenshot cleanup.

Temporary PNG files are removed after successful delivery, provider errors, abandoned command flows, normal dictation completion, and other cleanup paths. The app also removes stale screenshot files on startup. Screen & System Audio Recording permission is required for `P` capture; a failed capture simply leaves that image out of the request.

### Last failed command

A provider, Hermes, Markdown, or delivery failure is retained locally at:

```text
~/Library/Application Support/fluid-push-to-talk/last-failed-command/
```

The directory contains `turn.json` plus copies of captured images. `turn.json` records the timestamp, provider/model, information transcript, spoken command, error, and image metadata. This bundle is sensitive: the directory uses mode `0700`, and the manifest and image copies use `0600`.

A newer failed interaction replaces the previous bundle. The bundle is cleared only after a later provider or Hermes response is successfully delivered. Normal dictation and an empty command do not clear it. Retained image copies survive ordinary screenshot cleanup specifically so the failed turn can be diagnosed.

## Configuration

Installed files:

```text
~/.config/fluid-push-to-talk/config.json
~/.config/fluid-push-to-talk/.env
```

Checked-in defaults:

```text
config/config.json
config/promptConfig.json
config/textReplacements.json
```

Inspect or repair setup:

```bash
fluid-push-to-talk config
fluid-push-to-talk config show
fluid-push-to-talk config doctor
```

## macOS Permissions

Enable permissions for the terminal app that launches the binary:

- Microphone
- Accessibility
- Input Monitoring
- Screen & System Audio Recording for every explicit `P` capture
- Full Disk Access when a Markdown target uses protected or cloud storage

Fully quit and reopen the terminal app after changing permissions.

## Build and Test

```bash
cd app
swift build
```

```bash
python3 tests/run_all.py
```

Without live API credentials:

```bash
python3 tests/run_all.py --skip-llm
```

Optional five-image live checks for all configured credentials:

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```

## Useful Run Options

```bash
app/.build/debug/fluid-push-to-talk --model-version v2 --language en
app/.build/debug/fluid-push-to-talk --config config/config.json
app/.build/debug/fluid-push-to-talk --save-recordings
app/.build/debug/fluid-push-to-talk --language auto
app/.build/debug/fluid-push-to-talk --test-bluetooth-keyboard "Bluetooth-Test"
app/.build/debug/fluid-push-to-talk \
  --test-hermes-instruction "Schreibe das auf Niederländisch" \
  --test-hermes-image screenshot.png
```

The Hermes diagnostic uses the real visible `HermesAgentRunner`: it validates or recreates the persistent session, opens or focuses the matching Terminal tab, submits native `/image` attachments before the prompt, and prints the response exported from that same session.
