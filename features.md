# Features

## Native Push-To-Talk Dictation

- Records audio on macOS while the configured hotkey chord is held.
- Uses FluidAudio/CoreML ASR for local transcription.
- Applies configured post-ASR spelling replacements from `config/textReplacements.json` before paste, dump, or command generation.
- Defaults to the multilingual `v3` ASR model with German language hint.
- Supports `--model-version v2|v3` and `--language CODE|auto` runtime overrides.

## Paste Mode

- `Command + Option` records dictated speech while both keys are held.
- Releasing both keys together transcribes the recording and uses the configured `llm_output.paste` method.
- Clipboard paste behavior is configurable, including paste delay and clipboard restoration.

## Bluetooth Keyboard Mode

- Disabled by default until enabled in setup.
- The setup wizard accepts a configured Bluetooth key such as `f18` or `right_shift`; pressing Enter uses the setup default.
- Holding the configured Bluetooth key starts push-to-talk recording, and releasing it sends the transcript through the configured Bluetooth route.
- `Command + Option` remains dedicated to local clipboard paste.

## Paste Command Mode

- `Command + Option`, then releasing `Option` while holding `Command`, records an information segment and immediately starts a command segment.
- Releasing `Command` transcribes both segments.
- The app sends the information, optional skill context, and command to the configured local LLM.
- Command generation uses one generic prompt shape for every request: task first, then the information to work with.
- If the command segment is empty, the app pastes the information transcript.
- If the LLM is unavailable, the app falls back to relevant skill output or the information transcript.

## Markdown Dump Mode

- `Control + Option` records dictated speech while both keys are held.
- Releasing both keys together transcribes the recording and uses the configured `llm_output.dump` method.
- The dump target, date placeholder, append behavior, and timestamp inclusion are configurable.

## Continuous Markdown Dump Mode

- After starting the app with `./restart.sh`, type `go` in the app Terminal to begin continuous recording.
- Type `stop` in the app Terminal to stop recording, transcribe the full segment, and append it to the configured Obsidian daily note.
- Press Tab in the app Terminal to autocomplete `go`, `stop`, `status`, `help`, and `quit`.
- Continuous terminal recording does not transcribe or write partial data before `stop`.

## Markdown Dump Command Mode

- `Control + Option`, then releasing `Control` while holding `Option`, records an information segment and immediately starts a command segment.
- Releasing `Option` transcribes both segments.
- The app sends the information, optional skill context, and command to the configured local LLM.
- The generated result is appended to the configured Markdown daily note.
- If the command segment is empty, the app appends the information transcript.

## Command LLM Integration

- Uses the OpenAI-compatible Chat Completions schema for command transformations by default.
- Supports generic `base_url`, `model`, and `OPENAI_API_KEY` configuration through the setup wizard.
- Keeps Azure DeepSeek available as an explicit hosted-provider preset.
- Keeps the MLX Swift Examples `llm-tool chat` client available as a configurable fallback provider.
- Supports configurable provider, endpoint, API key environment variable, temperature, max tokens, timeout, model, and enable/disable flag.
- `local_llm.command_generation_enabled` can disable LLM generation for two-step commands while preserving skill/tool fallback behavior.
- Loads LLM system and user prompt templates from `promptConfig.json`.
- Console output logs the exact prompt sent to the command LLM.
- Console output reports the configured LLM, readiness status, selected skills, request start, and response latency.
- Startup output begins with the app version.

## Configurable Text Output

- Routes normal transcripts and two-step command results independently for local paste, dump, and Bluetooth hotkeys.
- Supports `clipboard`, `dump`, and `bluetooth-keyboard` output methods.
- Preserves the existing clipboard paste and Markdown dump defaults.
- Implements the ESP32 `KBD1` serial protocol directly in Swift without launching an external process.
- Auto-detects one `/dev/cu.usbmodem*` or `/dev/cu.usbserial*` device, with an explicit port override for multi-device systems.
- Keeps the serial connection open and performs transfer work away from the LLM and main queues.
- Provides `--test-bluetooth-keyboard TEXT` for a direct connection and typing check without ASR startup.

## Local Skills

- Fast generic skill selection scans `skills/*/SKILL.md` before each two-step command LLM request.
- Selection uses standard skill frontmatter: `name` and `description`.
- The command and information transcripts are scored against skill metadata.
- The best matching skill instructions are injected as `Skill context`.
- Command-result behavior is core software, not a selectable skill.
- The app does not execute arbitrary commands from selected skills.
- Registered runtime tools can attach tool output.
- Existing selectable skills: `tasks` and `greet`.

## Recording Management

- Temporary WAV recordings are removed by default.
- `--save-recordings` keeps recordings.
- `--output-dir PATH` controls where saved recordings are written.

## Install And Launch

- `install.sh` copies the default config to `~/.config/fluid-push-to-talk/config.json`.
- `install.sh` also runs `swift build`.
- `fluid-push-to-talk setup` opens the guided onboarding wizard.
- `fluid-push-to-talk config`, `config show`, and `config doctor` manage installed configuration.
- `launch.sh` runs the built debug binary and forwards CLI arguments.
- The binary includes `--test-command-information` and `--test-command` for command-result regression tests without loading the ASR model.

## macOS Permissions

- Requires Microphone permission for audio capture.
- Requires Accessibility and Input Monitoring permissions for paste/hotkey behavior.
