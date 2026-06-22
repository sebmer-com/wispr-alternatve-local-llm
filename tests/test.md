# Test Plan

This file tracks coverage for the current feature set. Automated checks are marked with commands; macOS hotkey and permission behavior requires manual verification in a logged-in desktop session.

## Automated Checks

Run the full automated suite after each software change:

```bash
python3 tests/run_all.py
```

Use `python3 tests/run_all.py --skip-llm` only in environments without Metal/MLX access. The skipped run is not a substitute for the full suite before considering a change complete.

### Swift Build

- Feature coverage: app compilation, config decoding types, FluidAudio integration references.
- Command:

```bash
cd app
swift build
```

- Expected result: build completes successfully.
- Latest result: pass on 2026-05-16 with no Swift warnings.

### Full Automated Suite

- Feature coverage: build, CLI help/version, config JSON, prompt JSON, skill frontmatter, audio recorder crash regression, generic skill tool calling, Bonsai generation speed, Bonsai command translation, and per-request chat history reset.
- Command:

```bash
python3 tests/run_all.py
```

- Expected result: all checks pass. The Bonsai translation check requires a non-sandboxed macOS session with MLX/Metal access.
- Latest result: pass on 2026-05-22 outside the sandbox; Bonsai speed regression reported 36.31 tokens/s and the translation regression completed in 1.98s.

### Audio Recorder Crash Regression

- Feature coverage: prevents AirPods/CoreAudio route rebuild crashes by requiring AVAudioRecorder capture without HAL input binding.
- Command:

```bash
python3 tests/audio_recorder_static_case.py
```

- Expected result: static checks pass and the old `format: format` tap pattern is absent.
- Latest result: pass on 2026-05-22.

### CLI Help

- Feature coverage: binary launch path and documented runtime options.
- Command:

```bash
app/.build/debug/fluid-push-to-talk --help
```

- Expected result: help output includes config path, ASR model/language overrides, paste controls, save-recordings, output directory options, and command-result test options.
- Latest result: pass on 2026-05-16.

### Version Output

- Feature coverage: startup logs always include the app version.
- Command:

```bash
app/.build/debug/fluid-push-to-talk --help
```

- Expected result: first output line starts with `FluidAudio Push To Talk`.
- Latest result: pass on 2026-05-16. Output starts with `FluidAudio Push To Talk 0.2.3`.

### Default Config Shape

- Feature coverage: app-readable JSON config for ASR, hotkeys, paste, recordings, dump, generic skills, and local LLM.
- Command:

```bash
python3 -m json.tool config/config.json >/dev/null
```

- Expected result: JSON parses successfully.
- Latest result: pass on 2026-05-16.

### Installed Config Shape

- Feature coverage: installed config used by default app launch.
- Command:

```bash
python3 -m json.tool ~/.config/fluid-push-to-talk/config.json >/dev/null
python3 -m json.tool ~/.config/fluid-push-to-talk/promptConfig.json >/dev/null
```

- Expected result: JSON parses successfully, uses MLX Swift `llm-tool chat` with `prism-ml/Ternary-Bonsai-8B-mlx-2bit`, and keeps LLM prompts in `promptConfig.json`.
- Latest result: pass on 2026-05-15.

### Skill Frontmatter

- Feature coverage: generic skill discovery and standard skill documentation.
- Command:

```bash
for file in skills/*/SKILL.md; do sed -n '1,4p' "$file"; done
```

- Expected result: every skill starts with YAML frontmatter containing `name` and `description`.
- Latest result: pass on 2026-05-15.

### Core Command Result Prompt Config

- Feature coverage: command-result behavior is built into the app, not discovered as a skill, and prompt text lives in `promptConfig.json`.
- Command:

```bash
test ! -e skills/command-result/SKILL.md
python3 -m json.tool config/promptConfig.json >/dev/null
```

- Expected result: the old command-result skill file is absent, prompt JSON parses, and command generation still builds.
- Latest result: pass on 2026-05-15.

### Generic Skill Tool Calling

- Feature coverage: generic skill discovery, generic tool execution from skill frontmatter, and tool fallback behavior.
- Command:

```bash
python3 tests/generic_tool_case.py
```

- Expected result: the `greet` skill is selected through generic metadata and returns its tool output with local LLM disabled.
- Latest result: pass on 2026-05-16.

### OpenAI-Compatible Command LLM Smoke

- Feature coverage: configured command LLM availability for command modes.
- Command:

```bash
python3 tests/local_llm_speed_case.py
```

- Expected result: the app calls the configured OpenAI-compatible Chat Completions endpoint and receives `OK`.
- Latest result: live run requires `OPENAI_API_KEY`; use `OPENAI_BASE_URL` and `OPENAI_MODEL` to test another OpenAI-compatible router.

### Command LLM Provider Static Case

- Feature coverage: active command provider and model stay wired to the OpenAI-compatible default while MLX and Azure remain available as fallback/preset providers.
- Command:

```bash
python3 tests/local_llm_model_static_case.py
```

- Expected result: config uses `provider: openai_compatible`, `base_url`, `model`, and `OPENAI_API_KEY` without storing any secret value in JSON.
- Latest result: pass on 2026-06-18.

### Translation Command Case

- Feature coverage: German information plus German command asking for English translation.
- Command:

```bash
python3 tests/translation_case.py
```

- Expected result: output is an English translation, not the original German source, and the logged LLM request puts the command before the information.
- Latest result: live run requires `OPENAI_API_KEY`.


### Console Readiness Output

- Feature coverage: startup visibility and warm persistent session for the configured local LLM.
- Steps:
  1. Confirm the configured `local_llm.mlx_run` path is executable.
  2. Start the app with `./launch.sh`.
  3. Confirm the console prints the configured model, `loading local MLX llm-tool model once`, and `local MLX llm-tool ready` before the `Hold ... to paste` line.
- Latest result: pending manual verification in an interactive app run.

## Manual Checks

### Paste Mode

- Feature coverage: `Command + Option` recording, transcription, clipboard paste, clipboard restoration.
- Steps:
  1. Start the app with `./launch.sh`.
  2. Focus a writable text field.
  3. Hold `Command + Option`, dictate a short sentence, then release both keys.
  4. Confirm the transcribed text is pasted into the focused field.
- Latest result: pending.

### Paste Command Mode

- Feature coverage: two-segment paste workflow, local LLM command transformation, fallback behavior.
- Steps:
  1. Confirm the configured `local_llm.mlx_run` path is executable.
  2. Start the app with `./launch.sh`.
  3. Focus a writable text field.
  4. Hold `Command + Option`, dictate source information, release `Option` while holding `Command`, dictate a command, then release `Command`.
  5. Confirm the generated result is pasted.
  6. Repeat with `local_llm.enabled` set to `false` and confirm fallback text is pasted.
- Latest result: pending.

### Dump Mode

- Feature coverage: `Control + Option` recording, transcription, Markdown inbox append, timestamp behavior.
- Steps:
  1. Start the app with `./launch.sh`.
  2. Hold `Control + Option`, dictate a short note, then release both keys.
  3. Confirm the configured Markdown inbox receives a new entry.
- Latest result: pending.

### Dump Command Mode

- Feature coverage: two-segment dump workflow, local LLM command transformation, Markdown append.
- Steps:
  1. Confirm the configured `local_llm.mlx_run` path is executable.
  2. Start the app with `./launch.sh`.
  3. Hold `Control + Option`, dictate source information, release `Control` while holding `Option`, dictate a command, then release `Option`.
  4. Confirm the generated result is appended to the Markdown inbox.
- Latest result: pending.

### macOS Permissions

- Feature coverage: Microphone, Accessibility, and Input Monitoring requirements.
- Steps:
  1. Grant permissions to the terminal app that runs the binary.
  2. Fully quit and reopen that terminal app.
  3. Run paste and dump checks again.
- Latest result: pending.

### Recording Save Options

- Feature coverage: `--save-recordings` and `--output-dir`.
- Steps:
  1. Start the app with `./launch.sh --save-recordings --output-dir recordings-test`.
  2. Complete a short recording.
  3. Confirm an audio file is kept in `recordings-test`.
- Latest result: pending.

### Greet Skill

- Feature coverage: `greet` Codex skill and macOS text-to-speech through generic skill tool metadata.
- Steps:
  1. Run `FLUID_SKILL_INFORMATION='Dominik' python3 skills/greet/scripts/greet.py` in a logged-in macOS session.
  2. Confirm the greeting is audible and the script prints `Spoken: Hello Dominik`.
- Latest result: pending.
