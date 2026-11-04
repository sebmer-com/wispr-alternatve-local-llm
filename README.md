# FluidAudio Push To Talk

FluidAudio Push To Talk is a native macOS 14+ voice-dictation app for Apple Silicon. Audio transcription runs locally with FluidAudio/CoreML. Two-stage spoken commands use OpenAI, Cerebras, or Anthropic, selected during setup. Fresh setup defaults to GPT-6 Luna (`gpt-6-luna`) through an existing Hermes OpenAI Codex subscription login; no app API key is needed for that path.

## Features

- Local push-to-talk transcription and paste.
- Two-stage command flow: dictate information, release `Option`, dictate an instruction, then release `Command`.
- Up to five optional screenshots, captured explicitly with physical `P` during the first `Command + Option` or `Control + Option` segment.
- Configurable OpenAI model, default `gpt-6-luna`, via Hermes login or the native Responses API.
- Optional Anthropic model, default `claude-haiku-5-5`, via Hermes OAuth or the native Messages API.
- Cerebras Chat Completions with `qwen-3.8-27b` and an API key.
- `Control + Option` selectable as Markdown Dump or one-segment Hermes Agent mode, plus optional ESP32 Bluetooth output.

See [appBehavior.md](appBehavior.md) for exact shortcut behavior.

## Install

For a new checkout on the target Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/sebmer-com/wispr-alternatve-local-llm/main/github-install.sh | bash -s -- --setup --no-launch
```

For an existing checkout, including upgrades:

```bash
./install.sh --no-launch
```

The installer builds the app and links `fluid-push-to-talk` into `~/.local/bin`. Existing config and `.env` are preserved unless explicitly reset. `--setup` opens onboarding and runs `config doctor`; `--no-launch` prevents startup after setup. **Do not use `--reset-state` for upgrades:** it deletes installed configuration and credentials. Reconfigure deliberately without resetting:

```bash
fluid-push-to-talk setup
```

After configuration and permissions are ready, use `./restart.sh` to start the app.

## Setup and Provider Selection

The setup wizard asks for:

1. Transcription language.
2. Paste shortcut.
3. Command provider, in order: **1 OpenAI, 2 Cerebras, 3 Anthropic**.
4. For OpenAI or Anthropic, authentication: **1 Existing Hermes login, 2 API key**, then an exact command model ID. Cerebras stays API-key-only with `qwen-3.8-27b`.
5. The selected provider's hidden API key, **only** when `api_key` authentication is selected.
6. `Control + Option`: Markdown Dump or Hermes Agent.

Fresh defaults are `command_provider: "openai"`, `command_auth: "hermes"`, and `command_model: "gpt-6-luna"`. Transcription defaults to the system language; `Control + Option` defaults to Markdown Dump. Existing configs missing `command_auth` retain `api_key` behavior for compatibility, not an automatic subscription migration. A model saved explicitly remains selected until changed.

### OpenAI: existing Hermes subscription login (default)

Install or update a compatible [Hermes runtime](https://hermes-agent.nousresearch.com/docs/) separately. Check its OpenAI Codex login and add one only if needed:

```bash
hermes auth status openai-codex
hermes auth add openai-codex
```

In app setup select **OpenAI → Existing Hermes login → `gpt-6-luna`**. A ChatGPT/Codex subscription login is **not** a public OpenAI API key. Access depends on the account's plan, model entitlements, workspace restrictions, and current usage/rate limits; a subscription does not guarantee access to every API model ID.

The app's model-only bridge uses the existing Hermes authentication and token refresh, inherits `HERMES_HOME` when set, and leaves Hermes' default model unchanged. Hermes owns its credentials and runtime updates; do not copy OAuth tokens or auth files into this app's `.env`. The bridge performs inference without an agent loop or tools. It is separate from the visible `Control + Option` Hermes Agent mode, whose sessions and hotkeys are unchanged.

### Anthropic: optional Haiku

**Cost warning:** Claude is not included in a ChatGPT subscription. Per the [Hermes provider documentation](https://hermes-agent.nousresearch.com/docs/integrations/providers), Anthropic OAuth requires **Claude Max plus purchased extra usage credits**; it consumes those extra credits, not the base Max allowance. Claude Pro is not supported by that OAuth path. Review account access and billing before signing in:

```bash
hermes auth add anthropic --type oauth
```

Then select **Anthropic → Existing Hermes login → `claude-haiku-5-5`** in app setup. This is the app's configured Haiku default, not a guarantee that the selected account/catalog exposes it. Verify the exact ID and access; if unavailable, select an accessible compatible model explicitly.

**Alternative: separate API billing.** Select **Anthropic → API key**, enter the exact model ID and a Claude Console key. This native Messages API path uses `ANTHROPIC_API_KEY` and is billed independently of any subscription. OpenAI likewise offers an explicit API-key option using `OPENAI_API_KEY`; Cerebras uses `CEREBRAS_API_KEY`. All native API requests are usage-based billed. No request switches authentication or providers automatically, including after a quota, login, model, or billing error.

### Change the model or authentication

Run `fluid-push-to-talk setup`, or run `fluid-push-to-talk config` and choose **Edit core setup**. Select the provider, authentication method, and exact model ID together; the optional-features editor is for Hermes Agent details, continuous Dump, Bluetooth, and paths. You may also edit the active app `config.json` directly. Minimal examples below are alternatives; merge the three fields into your existing config rather than discarding hotkeys or other settings.

Default subscription path:

```json
{
  "command_provider": "openai",
  "command_auth": "hermes",
  "command_model": "gpt-6-luna"
}
```

Explicit usage-billed OpenAI API path:

```json
{
  "command_provider": "openai",
  "command_auth": "api_key",
  "command_model": "gpt-6-luna"
}
```

Optional Haiku with Hermes OAuth:

```json
{
  "command_provider": "anthropic",
  "command_auth": "hermes",
  "command_model": "claude-haiku-5-5"
}
```

Optional Haiku with a separately billed API key:

```json
{
  "command_provider": "anthropic",
  "command_auth": "api_key",
  "command_model": "claude-haiku-5-5"
}
```

Cerebras API path:

```json
{
  "command_provider": "cerebras",
  "command_auth": "api_key",
  "command_model": "qwen-3.8-27b"
}
```

For API-key mode, keys come from the process environment or `.env` beside the active config, normally `~/.config/fluid-push-to-talk/.env`, with permissions `0600`. See [.env.example](.env.example); it is unnecessary for the default Hermes login path. Saving one provider's key preserves unrelated keys. Never put credentials in `config.json`.

After a change:

```bash
fluid-push-to-talk config show
fluid-push-to-talk config doctor
./restart.sh
```

Doctor checks the selected authentication and, for Hermes, the provider's model catalog. Catalog membership or a valid login is **not an inference test**: availability can remain unknown, and a real request can still fail due to access, limits, or service conditions. Doctor does not justify claiming the model works or silently substituting another one.

Official references: [OpenAI models](https://developers.openai.com/api/docs/models), [OpenAI subscription versus API authentication](https://developers.openai.com/codex/auth), [Anthropic model IDs](https://platform.claude.com/docs/en/about-claude/models/overview), [Haiku 5.5 thinking migration](https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide), [Anthropic API authentication](https://platform.claude.com/docs/en/api/overview), and [Hermes providers and subscription requirements](https://hermes-agent.nousresearch.com/docs/integrations/providers).

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

### OpenAI with `api_key`

- Endpoint: `https://api.openai.com/v1/responses`
- Model: configured `command_model`, default `gpt-6-luna`
- Reasoning effort: `low`
- Text verbosity: `low`
- Image input: Base64 PNG `input_image` entries with `detail: low`
- Response storage: disabled

### Anthropic with `api_key`

- Endpoint: `https://api.anthropic.com/v1/messages`
- Model: configured `command_model`, default `claude-haiku-5-5`; account/model access must be checked separately.
- Text and ordered Base64 PNG image inputs use the native Messages format.
- Haiku 5.5 uses adaptive thinking with low effort; only final text blocks are delivered, never thinking or partial answers.
- Authentication: `ANTHROPIC_API_KEY`; requests are usage-based billed.

### Hermes authentication for OpenAI or Anthropic

`command_auth: "hermes"` selects the model-only bridge rather than the native API-key clients above. OpenAI maps to Hermes provider `openai-codex`; Anthropic maps to `anthropic`. The bridge uses the exact configured same-provider model ID (`gpt-*` or `claude-*`), forwards ordered images, and delegates credential refresh to the existing Hermes runtime. It never starts an agent or tools, changes Hermes' default model, or falls back to an API key or another provider.

### Cerebras with `api_key`

- Endpoint: `https://api.cerebras.ai/v1/chat/completions`
- Model: `qwen-3.8-27b`
- Reasoning: `low`; `max_completion_tokens: 4096` covers reasoning plus answer text.
- Missing answer text and token-limit truncation are explicit errors; reasoning and partial answers are never delivered.
- Image input: ordered Base64 data URLs in Chat Completions content parts

Command clients accept zero through five images in capture order. If the selected provider returns an error after its own retry handling, the app logs the failure and produces no command output. It does not call another provider or switch authentication, and does not paste the information transcript as an error fallback. An empty spoken instruction remains a pre-request case and delivers the information transcript locally.

Command diagnostics use one logical `request_id`. Native HTTP request fields are `provider`, `model`, `prompt_chars`, `system_prompt_chars`, `user_prompt_chars`, `image_count`, `timeout_seconds`, `payload_bytes`, and `build_duration_ms`. Each image adds `index`, `path`, `bytes`, `mime`, `base64_chars`, and `sha256`. Attempt/result fields include `attempt=n/max`, `outcome`, `duration_ms`, `http_status`, `response_bytes`, and `response_request_id`; retries add `retry_reason`, and terminal failures add `error_domain` plus `error_code`. Bridge requests share the secret-safe diagnostic boundary but do not necessarily expose native HTTP fields.

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

Run these commands from the repository root. The macOS GitHub Actions workflow runs the full offline suite, including XCTest, without provider credentials:

```bash
(cd app && swift build)
```

```bash
python3 tests/run_all.py
```

Full regression suite without live LLM requests (still builds the app and runs Swift/XCTest tests):

```bash
python3 tests/run_all.py --skip-llm
```

On macOS, the default suite's `swift test` requires full Xcode with XCTest. Command Line Tools alone can build the app but fail with `no such module 'XCTest'`. For a Command Line Tools-only check, explicitly skip XCTest:

```bash
python3 tests/run_all.py --skip-llm --skip-xctest
```

That is a reduced check, not a passing full suite. Focused offline checks for the bridge, subscription setup, and production Swift clients:

```bash
python3 tests/hermes_bridge_case.py -v
python3 tests/subscription_setup_case.py -v
python3 tests/subscription_client_case.py -v
```

These focused checks do not replace the full suite. The standalone client harness compiles production clients with `swiftc` without XCTest or credentials. No successful build, suite run, or live inference is implied by these instructions.

Opt-in end-to-end subscription checks use the selected Hermes login and send only synthetic text plus five generated PNGs; these are not part of the default offline runner. They consume provider usage; Anthropic requires the extra-credit billing described above:

```bash
python3 tests/hermes_subscription_live_case.py --provider openai
python3 tests/hermes_subscription_live_case.py --provider anthropic
```

Optional five-image live checks for the configured OpenAI and Cerebras **API-key** credentials (usage-based billed; not subscription validation):

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```

## Useful Run Options

`--model-version` selects the local transcription model, not the command LLM. Change the command model through setup or app config JSON as described above.

```bash
app/.build/debug/fluid-push-to-talk --model-version v2 --language en
app/.build/debug/fluid-push-to-talk --model-version qwen3-asr-1.7b
app/.build/debug/fluid-push-to-talk --config config/config.json
app/.build/debug/fluid-push-to-talk --save-recordings
app/.build/debug/fluid-push-to-talk --language auto
app/.build/debug/fluid-push-to-talk --test-bluetooth-keyboard "Bluetooth-Test"
app/.build/debug/fluid-push-to-talk \
  --test-hermes-instruction "Schreibe das auf Niederländisch" \
  --test-hermes-image screenshot.png
```

The Hermes diagnostic uses the real visible `HermesAgentRunner`: it validates or recreates the persistent session, opens or focuses the matching Terminal tab, submits native `/image` attachments before the prompt, and prints the response exported from that same session.
