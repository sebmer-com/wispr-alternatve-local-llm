# FluidAudio Push To Talk

Native macOS push-to-talk dictation using FluidAudio/CoreML.

Hold `Command + Option` to record and paste the transcription locally into the focused field. System audio is muted while push-to-talk recording is active and restored after capture.
Bluetooth/ESP32 keyboard output is disabled by default. Enable it in `setup`, then enter a shortcut key such as `f18` or press Enter to use the setup default.
Release `Option` first while still holding `Command` to record a follow-up command; releasing `Command` then generates and pastes a local LLM result.
Release `Command` first while still holding `Option` to record a Hermes Agent instruction; releasing `Option` then opens or reuses a real Hermes/Poseidon Terminal session in the foreground, visibly pastes and submits the full prompt there, keeps new recordings available while Hermes runs, and later delivers the answer exported from that same session back to the original app or clipboard. Hermes decides semantically whether a voice turn is follow-up, revision, reset, or standalone; local-audio does not use keyword filters for that.
Hold `Control + Option` to record and append the transcript to your configured Obsidian daily note. Release `Control` first while still holding `Option` to record a follow-up command; releasing `Option` then uses the LLM and dumps the generated result.
After starting the app with `./restart.sh`, type `go` in the app Terminal for continuous daily-note dumping and `stop` to stop it. Press Tab to autocomplete terminal commands.

See [appBehavior.md](appBehavior.md) for the short behavior reference.

By default the app reads:

```text
~/.config/fluid-push-to-talk/config.json
```

The checked-in default config lives at:

```text
config/config.json
```

LLM prompts are kept outside the Swift code in:

```text
config/promptConfig.json
```

Fast post-ASR spelling replacements are configured in:

```text
config/textReplacements.json
```

Each replacement is loaded once at startup and applied in memory after transcription, before paste, dump, or command generation.

## Text Output

All finished texts, including normal one-step dictation and two-step command results, have a configurable output per hotkey flow:

```json
"llm_output": {
  "paste": "clipboard",
  "dump": "dump",
  "bluetooth": "clipboard"
},
"bluetooth_keyboard": {
  "port": null,
  "chunk_size": 32
}
```

Each `llm_output` value can be `clipboard`, `dump`, or `bluetooth-keyboard`. `Command + Option` remains local; the separate `bluetooth` route stays inactive until setup writes `hotkeys.bluetooth.enabled: true` with a configured key. Set `port` to a specific `/dev/cu.usbmodem...` or `/dev/cu.usbserial...` path when more than one matching serial device is connected; otherwise the app detects the single matching port automatically.

The Bluetooth hotkey is disabled by default with `hotkeys.bluetooth.enabled: false` and an empty `hotkeys.bluetooth.keys` list. In setup, enable Bluetooth and enter a supported key such as `f18`, `right_shift`, or `right_option`; pressing Enter uses the setup default `right_shift`.

Bluetooth keyboard output implements the ESP32 `KBD1` serial protocol directly in Swift at 115200 baud. It checks the BLE connection, transfers UTF-8 text in CRC32-protected chunks, waits for firmware completion, and never launches `keyboard-cli` as a subprocess.

Test the configured ESP32 connection without loading the ASR model:

```bash
app/.build/debug/fluid-push-to-talk --test-bluetooth-keyboard "Bluetooth-Test"
```

## Build

```bash
cd app
swift build
```

## Setup And Config

```bash
curl -fsSL https://raw.githubusercontent.com/sebmer-com/wispr-alternatve-local-llm/main/github-install.sh | bash -s -- --reset-state --setup
```

The GitHub installer clones or updates the public fork into `~/.local/share/fluid-push-to-talk/source`, builds the Swift package, links `~/.local/bin/fluid-push-to-talk`, resets local state when requested, and opens the interactive setup wizard. API tokens are stored in `~/.config/fluid-push-to-talk/.env`, never in JSON config.

For a local checkout:

```bash
./install.sh --reset-state --setup
```

Inspect or repair an existing setup:

```bash
app/.build/debug/fluid-push-to-talk config
app/.build/debug/fluid-push-to-talk config show
app/.build/debug/fluid-push-to-talk config doctor
app/.build/debug/fluid-push-to-talk config reset --yes
```

## Command LLM

The default config uses the OpenAI-compatible Chat Completions schema for two-step command generation:

```json
{
  "provider": "openai_compatible",
  "base_url": "https://api.openai.com/v1",
  "model": "gpt-5.4-mini",
  "api_key_env": "OPENAI_API_KEY"
}
```

For OpenAI-compatible providers, `base_url` is the provider root, usually ending in `/v1`; the app appends `/chat/completions` when needed. `model` is the exact provider model slug, such as `gpt-5.4-mini`, `openai/gpt-5.4-mini`, or a local model name.

Paste mode is unaffected when the command LLM is unavailable, dump mode writes the raw transcript, and the two-step command mode pastes the information transcript.

Dump mode only uses the command LLM when you use the two-step command gesture. Releasing `Control + Option` together writes the raw transcript immediately.

Set `local_llm.command_generation_enabled` to `false` to disable LLM generation for two-step commands while keeping the rest of the local LLM configuration intact. With this off, command mode falls back to selected skill tool output or the information transcript.

The old MLX/Bonsai client remains available behind `local_llm.provider: "mlx"` for fallback testing, and the Azure preset remains available as `local_llm.provider: "azure_openai"`. OpenAI-compatible endpoints can be configured with `local_llm.provider: "openai_compatible"` and `local_llm.base_url`; the app normalizes the base URL to `/chat/completions`.

Store hosted API keys in `.env`, not in JSON config:

```text
OPENAI_API_KEY=...
```

The app reads `local_llm.dotenv_file` relative to the active config file and falls back to the repository `.env` during local test runs.

## Skill Selection

Two-step command mode uses a fast local skill selector before calling the LLM. The app scans `skills/*/SKILL.md`, reads each skill's YAML frontmatter, scores the transcribed information and command against the skill `name` and `description`, and includes the best matching skill instructions as `Skill context`.

Every selectable skill must use this format:

```markdown
---
name: skill-name
description: Use when ...
---
```

The app does not execute arbitrary commands from skill instructions. Only registered runtime tools are executed; currently `weather-munich` can run its bundled Open-Meteo script and attach the result as tool output.

The default Markdown dump target is today's Obsidian daily note:

```text
~/Documents/Obsidian/Daily Notes/YYYY-MM-DD.md
```

`YYYY-MM-DD` and `yyyy-MM-dd` in `dump.markdown_file` are replaced with the current local date at write time.

Continuous dump mode uses the same daily note target. It records until you stop it, then transcribes the full recording locally and appends the transcript. Type these commands in the app Terminal:

```text
go
stop
```

Tab completion is available for `go`, `stop`, `status`, `help`, and `quit`.

## Run

```bash
./launch.sh
```

Stop the running app instance:

```bash
./stop.sh
```

Restart the app in the current terminal and keep console output visible:

```bash
./restart.sh
```

Only one app instance may run at a time. After live hotkey testing, stop it with `./stop.sh` so the single-instance lock and microphone are released.

The first run downloads and compiles the FluidAudio ASR models. By default this uses the multilingual v3 model with a German language hint.

Useful options:

```bash
# English-only model
.build/debug/fluid-push-to-talk --model-version v2 --language en

# Use another config file
.build/debug/fluid-push-to-talk --config ../config/config.json

# Keep the recorded audio files
.build/debug/fluid-push-to-talk --save-recordings

# Let FluidAudio infer language/script behavior
.build/debug/fluid-push-to-talk --language auto
```

## Tests

Run the full automated suite after every software change:

```bash
python3 tests/run_all.py
```

Use `python3 tests/run_all.py --skip-llm` only when running in an environment without Metal/MLX access.

## macOS Permissions

Enable permissions for the terminal app that runs the binary, for example Terminal, iTerm, or VS Code:

- `System Settings > Privacy & Security > Microphone`
- `System Settings > Privacy & Security > Accessibility`
- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Privacy & Security > Full Disk Access` if the dump target is in OneDrive/iCloud/Obsidian storage

Bluetooth keyboard output additionally requires the ESP32 keyboard firmware to be connected over USB and paired with the target computer over Bluetooth.

Fully quit and reopen the terminal app after changing permissions.
