# Wispr Flow Alternative for Mac: Local LLM Voice Dictation

FluidAudio Push To Talk is a native macOS voice dictation app for Apple Silicon Macs. It is built for people who want a fast Wispr Flow alternative with local transcription, local-first command mode, and control over where text is sent.

Hold a shortcut, speak, and the app pastes the transcript into the focused field. On Mac M chips, speech recognition runs locally with FluidAudio/CoreML. Command mode can use an OpenAI-compatible API, a local LM Studio server, or the MLX/Bonsai local LLM fallback.

## Why Use It

- Local macOS dictation for Mac M1, M2, M3, and M4 chips.
- Push-to-talk paste into any focused app.
- Optional two-step command mode: dictate context, then speak an instruction and paste the LLM result.
- Setup supports OpenAI-compatible APIs, Local LM Studio, Azure, and Local MLX/Bonsai.
- Optional Obsidian daily-note dumping, Hermes Agent handoff, and ESP32 Bluetooth keyboard output.

See [appBehavior.md](appBehavior.md) for the detailed shortcut behavior.

## Install

Run this on the Mac where you want to use dictation:

```bash
curl -fsSL https://raw.githubusercontent.com/sebmer-com/wispr-alternatve-local-llm/main/github-install.sh | bash -s -- --reset-state --setup
```

The installer clones or updates the app, builds the Swift package, links `fluid-push-to-talk` into `~/.local/bin`, opens the setup wizard, runs `config doctor`, and restarts the app when setup finishes. API keys are written to `~/.config/fluid-push-to-talk/.env`, not to JSON config.

For an existing local checkout:

```bash
./install.sh --reset-state --setup
```

## Choose Your LLM During First Setup

The initial install command above opens setup automatically. Pick the LLM path there:

- **Simple Setup:** fastest start. Uses an OpenAI-compatible API and asks for the API token.
- **Advanced Setup > Local LM Studio:** use a local OpenAI-compatible server at `http://localhost:1234/v1`.
- **Advanced Setup > Local MLX/Bonsai:** use the local MLX fallback with `llm-tool` or `mlx-run` and the default `prism-ml/Ternary-Bonsai-8B-mlx-2bit` model.
- **Advanced Setup > Disabled:** keep normal local transcription and turn off command generation.

The first install script configures the LLM choice in the same setup flow. It does not install LM Studio or external MLX tooling for you; install those first if you want a fully local command LLM on the first run. Normal dictation still works without any command LLM.

## Daily Use

Start or restart the app:

```bash
./restart.sh
```

Stop it:

```bash
./stop.sh
```

Default shortcuts:

- `Command + Option`: hold to record, release to paste the transcript.
- Release `Option` first while still holding `Command`: record a follow-up command, then release `Command` to paste the LLM result.
- `Control + Option`: hold to record and append to the configured Markdown daily note.
- In the app Terminal, type `go` for continuous daily-note dumping and `stop` to stop it.

Only one app instance can run at a time. After testing hotkeys, stop the app with `./stop.sh` if you need to release the microphone and single-instance lock.

## Configuration

Main config:

```text
~/.config/fluid-push-to-talk/config.json
```

Checked-in defaults:

```text
config/config.json
config/promptConfig.json
config/textReplacements.json
```

Inspect or repair a setup:

```bash
fluid-push-to-talk config
fluid-push-to-talk config show
fluid-push-to-talk config doctor
fluid-push-to-talk config reset --yes
```

The command LLM config uses the OpenAI-compatible Chat Completions shape:

```json
{
  "provider": "openai_compatible",
  "base_url": "https://api.openai.com/v1",
  "model": "gpt-5.4-mini",
  "api_key_env": "OPENAI_API_KEY"
}
```

For local servers, set `base_url` to the server root, usually ending in `/v1`. The app appends `/chat/completions` when needed.

## Skills

Two-step command mode can add skill context before calling the LLM. Skills live in `skills/*/SKILL.md` and use standard Codex skill frontmatter:

```markdown
---
name: skill-name
description: Use when ...
---
```

The app does not execute arbitrary commands from skill files. Only registered runtime tools can run.

## macOS Permissions

Enable these permissions for the terminal app that runs `fluid-push-to-talk`, such as Terminal, iTerm, or VS Code:

- `System Settings > Privacy & Security > Microphone`
- `System Settings > Privacy & Security > Accessibility`
- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Privacy & Security > Full Disk Access` if your dump target is in OneDrive, iCloud, or Obsidian storage

Fully quit and reopen the terminal app after changing permissions.

## Build

```bash
cd app
swift build
```

Useful run options:

```bash
# English-only ASR model
app/.build/debug/fluid-push-to-talk --model-version v2 --language en

# Use another config file
app/.build/debug/fluid-push-to-talk --config config/config.json

# Keep recorded audio files
app/.build/debug/fluid-push-to-talk --save-recordings

# Let FluidAudio infer language/script behavior
app/.build/debug/fluid-push-to-talk --language auto
```

The first run downloads and compiles the FluidAudio ASR models. By default the checked-in config uses the multilingual v3 model with a German language hint.

## Bluetooth Keyboard Output

Bluetooth/ESP32 keyboard output is disabled by default. Enable it in Advanced Setup, then choose a shortcut key such as `f18`, `right_shift`, or `right_option`.

Test the configured ESP32 connection without loading the ASR model:

```bash
app/.build/debug/fluid-push-to-talk --test-bluetooth-keyboard "Bluetooth-Test"
```

## Tests

Run the full automated suite after every software change:

```bash
python3 tests/run_all.py
```

Use `python3 tests/run_all.py --skip-llm` only when running in an environment without Metal/MLX access.
