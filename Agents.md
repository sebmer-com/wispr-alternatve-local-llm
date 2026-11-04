# Repository Agent Guide

## Product and priorities

`fluid-push-to-talk` is a native macOS 14+ voice-dictation app for Apple Silicon. Audio is recorded and transcribed locally with FluidAudio/CoreML. Normal dictation is local; two-stage commands use the configured OpenAI, Cerebras, or Anthropic provider and explicit authentication method.

Prioritize:

1. Correct hotkey, physical-key latch, recording, and cleanup transitions.
2. Low perceived latency without losing spoken audio.
3. Safe handling of audio, transcripts, screenshots, and credentials.
4. Strict provider isolation and explicit failure behavior.
5. Reliable optional Dump, Hermes, and Bluetooth paths.

Do not add dependencies unless explicitly required. Prefer small, reversible changes.

## Repository map

- `app/Sources/AppRuntime.swift`: recorder, ASR, state machine, `P` key capture, delivery, terminal commands, and process lifecycle.
- `app/Sources/Config/`: config schema, provider selection, hotkeys, prompts, language, and replacements.
- `app/Sources/OpenAI/CommandLLMClient.swift`: shared command-provider interface.
- `app/Sources/OpenAI/OpenAIResponsesClient.swift`: configured-model Responses request and low-detail multi-image encoding.
- `app/Sources/Anthropic/AnthropicMessagesClient.swift`: configured-model native Messages request and image encoding.
- `app/Sources/Command/HermesCommandClient.swift`: model-only subscription client and bridge lifecycle.
- `scripts/run-hermes-bridge.sh`, `scripts/hermes_command_bridge.py`: existing Hermes runtime discovery, authentication/catalog checks, and direct inference without an agent or tools.
- `app/Sources/Cerebras/CerebrasChatCompletionsClient.swift`: Qwen 3.8 27B Chat Completions request and multi-image encoding.
- `app/Sources/CommandResultGenerator.swift`: shared command prompt generation and provider-error propagation.
- `app/Sources/Command/CommandRequestDiagnostics.swift`: secret-safe structured request, image, attempt, retry, and terminal logs.
- `app/Sources/Command/FailedCommandTurnStore.swift`: protected last-failed-command manifest and image retention.
- `app/Sources/HermesAgentRunner.swift`: visible one-segment Hermes execution with ordered native image attachments.
- `app/Sources/MarkdownDumper.swift`: transactional Markdown entries and permanent note-relative image attachments.
- `app/Sources/BluetoothKeyboardOutput.swift`: ESP32 serial keyboard protocol.
- `app/Tests/`: injected-session request, provider, image-order, retry, and error tests.
- `tests/`: source/CLI regressions and optional live provider checks.

## Provider contract

- `command_provider` accepts `openai`, `cerebras`, or `anthropic`; `command_auth` accepts `hermes` or `api_key`; `command_model` is the exact model ID. `effectiveCommandModel` is the explicit configured string, not a hidden fixed-model override.
- Fresh defaults are OpenAI, Hermes authentication, and `gpt-6-luna`, with no app API key. Missing legacy `command_auth` decodes as `api_key` for compatibility. Do not overwrite an explicitly saved model or silently migrate existing authentication.
- OpenAI API-key mode uses Responses with the configured model, low reasoning, low text verbosity, `store: false`, and low-detail images. Subscription mode maps to Hermes `openai-codex`, not the public API-key endpoint.
- Anthropic defaults to `claude-haiku-5-5` with either Hermes `anthropic` authentication or a separately billed native Messages API key. The default ID is not proof of account access or catalog availability.
- Cerebras is fixed to Chat Completions, `qwen-3.8-27b`, low reasoning, and 4096 completion tokens including reasoning. Missing answer text and token-limit truncation must fail without delivering reasoning or partial answers.
- Cerebras supports only `api_key`. In native API-key mode, resolve only the selected provider's key (`OPENAI_API_KEY`, `CEREBRAS_API_KEY`, or `ANTHROPIC_API_KEY`) from the environment or `.env` beside the active config. Native requests are usage-based billed, independent of subscriptions.
- Hermes mode requires an existing compatible Hermes installation. Delegate credential ownership, token refresh, and runtime updates to Hermes, inherit `HERMES_HOME`, and never copy tokens into app config or `.env`. Use direct model inference with no agent/tools; do not alter Hermes' default model or the visible Hermes Agent mode. Accept exact same-provider `gpt-*` or `claude-*` IDs without silently substituting a default; preserve model identity checks.
- A subscription is not a public API key. Check account entitlements and limits. Anthropic OAuth requires Claude Max plus purchased extra usage credits, not the included Max allowance; warn about costs before login. Never assume Claude is included with ChatGPT.
- Doctor checks auth and the Hermes provider catalog, not necessarily inference. Report unknown availability honestly; neither login nor catalog membership proves a request works.
- Never call another provider or switch to paid/API-key authentication after an error. A provider error must propagate to runtime and produce no command delivery or transcript fallback output.
- Preserve the information transcript only for pre-request cases such as an empty instruction.

## Shortcut and state-machine contract

| Input | Required behavior |
| --- | --- |
| Hold `Command + Option`, then release both together | Record one segment, transcribe locally, and deliver through `llm_output.paste`. Do not call a provider. |
| During that first segment, tap physical `P` | Capture one optional full-desktop screenshot. Accept at most five in capture order. |
| Release `Option` first while continuing to hold `Command` | Finish the information segment and immediately begin the spoken command segment. Do not capture an automatic screenshot. |
| Release `Command` after that transition | Send information, command, and zero to five screenshots to the selected provider; deliver only a successful response through `llm_output.paste`. |
| Release `Command` first while continuing to hold `Option` | Finish normal local dictation. Do not start Hermes. |
| Hold `Control + Option` in `dump` mode | Record one segment; `P` may capture up to five screenshots. Append text and permanent relative image attachments to Markdown. |
| Release `Control` first in `dump` mode | Start a second spoken provider command. Send text only to the provider; append the result plus captured images to Markdown. |
| Hold `Control + Option` in `hermes` mode | Record one instruction; `P` may capture up to five screenshots. Releasing either modifier sends the instruction and native `/image` attachments to Hermes. |
| Use the configured Bluetooth key | Record locally and deliver through `llm_output.bluetooth`. |
| Type terminal `go`, then `stop` | Run the independent continuous-recording Markdown Dump path. |

`control_option_mode` owns the `Control + Option` behavior. Markdown mode always writes Markdown; Hermes results return through the original paste target or Clipboard fallback.

## `P` screenshot invariants

- Capture only on physical `P` key-down during first-segment `Command + Option` or `Control + Option` recording.
- Ignore auto-repeat, swallow handled key-down/key-up events, and rearm only on physical key-up.
- Preserve capture order and accept at most five screenshots. Ignore additional capture requests.
- Zero images is valid. Never capture automatically when transitioning to the instruction segment.
- In Dump commands, archive images in Markdown but never send them to any command provider. In Hermes Agent mode, attach images in order using native `/image` commands before the prompt.
- Treat every full-desktop image as sensitive. Do not log image bytes or contents.
- Delete normal temporary images after success, errors, local-dictation exit, cancellation, and startup stale-file cleanup. On a failed provider/delivery turn, first copy its images into the protected last-failed-command bundle.

## Diagnostics and retention invariants

- Use one logical request ID across every log line for a provider request and its retries.
- Log only provider/model, prompt character counts, image path/bytes/MIME/Base64 length/SHA-256, payload bytes/build time, timeout, attempt `n/max`, duration/outcome, HTTP status, response bytes, provider request ID, retry reason, and terminal `NSError` domain/code.
- Never log API keys, OAuth tokens, `Authorization`, raw Base64 content, or complete request bodies. Do not replace safe prompt counts with raw prompt logging.
- Keep timeout retries observable: failed attempt, `retry_reason=timeout`, next attempt, and terminal identity if exhausted.
- Validate persisted Hermes session IDs by decoding an actual session export. Never trust exit status alone because Hermes may return `Session not found` with status zero.
- Bind reusable Terminal state and scrollback markers to the concrete validated Hermes session ID, not only the configured session name.
- Retain the newest failed provider, Hermes, Markdown, or delivery turn under `~/Library/Application Support/fluid-push-to-talk/last-failed-command/` as `turn.json` plus image copies.
- The retained directory must be `0700`; the manifest and image files must be `0600`.
- A new failure replaces the old bundle through staging, backup, promotion, and rollback. On startup, recover a valid backup or complete staging bundle after an interrupted promotion and remove orphan artifacts.
- Clear the retained bundle only after provider or Hermes response and delivery succeed. A successful response whose configured delivery is skipped is not success for retention purposes.
- Normal dictation, empty-command fallback, screenshot cleanup, and unrelated flows must not clear the retained bundle.
- Treat `turn.json` as sensitive because it contains information and command transcripts plus error details.

## Change rules

- Read the state machine, config, clients, tests, and user docs before changing behavior.
- Keep recording, continuation, screenshot, transcription, provider request, and delivery transitions serialized and race-free.
- Keep blocking screenshot, network, subprocess, and serial work off the main and hotkey queues.
- Never commit API keys, personal paths, screenshots, recordings, transcripts, or installed config.
- `.env` must preserve unrelated entries and remain mode `0600`.
- Update Codable config, setup, CLI help, tests, and docs together when provider behavior changes.
- Preserve Dump, Hermes, Bluetooth, and output-routing behavior unless explicitly in scope.
- Do not restore removed local command runtimes or runtime skills.
- Do not update FluidAudio or `Package.resolved` incidentally.
- Do not modify unrelated or untracked user files.

## Onboarding

- Ask for language, paste shortcut, provider, authentication, exact model ID, and `Control + Option` mode. Provider order is OpenAI, Cerebras, Anthropic; OpenAI/Anthropic auth order is existing Hermes login, API key. Cerebras retains its fixed API-key/model contract. Keep provider, authentication, and model distinct in labels and summaries.
- Ask for a hidden provider key only for `api_key`. Keep endpoints, reasoning, image detail, and retry policy out of onboarding; the model selector is intentional.
- Provider/auth/model changes belong in `setup`, `config` → Edit core setup, or app config JSON. There is no `--command-model` CLI flag. Preserve unrelated keys and all unrelated settings when saving.
- Document `hermes auth status openai-codex` and `hermes auth add openai-codex` for OpenAI; document `hermes auth add anthropic --type oauth` only after the Claude Max/extra-credit cost warning and with an explicit API-key alternative. See the official links in README; do not invent CLI commands or claim account access from defaults.
- Keep advanced Hermes settings, continuous Dump, and Bluetooth configuration in the optional editor; the primary `Control + Option` choice belongs in core onboarding.

## Validation

Run focused checks, then:

```bash
python3 tests/run_all.py
```

Full suite without live LLM requests (includes build and Swift/XCTest tests):

```bash
python3 tests/run_all.py --skip-llm
```

Full macOS `swift test` requires full Xcode with XCTest; Command Line Tools alone can fail with `no such module 'XCTest'` even when the app builds. Explicitly reduced Command Line Tools-only check:

```bash
python3 tests/run_all.py --skip-llm --skip-xctest
```

Focused offline checks, not replacements for the full suite:

```bash
python3 tests/hermes_bridge_case.py -v
python3 tests/subscription_setup_case.py -v
python3 tests/subscription_client_case.py -v
```

The standalone production-client harness uses `swiftc` without XCTest or credentials. Report toolchain blockers and skipped checks, not a passing default suite.

Opt-in subscription checks send only synthetic text and five generated PNGs through the selected Hermes login; these are not part of the default offline runner. They consume provider usage, including Anthropic extra credits when selected:

```bash
python3 tests/hermes_subscription_live_case.py --provider openai
python3 tests/hermes_subscription_live_case.py --provider anthropic
```

Optional usage-billed OpenAI/Cerebras API-key multi-image live checks (not subscription validation):

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```

Report skipped checks. Do not claim builds, Swift tests, live calls, lint, or formatting without fresh evidence.

Hotkey, screenshot, microphone, paste, Dump, Hermes, and Bluetooth changes also require a logged-in macOS smoke test.
Use `--test-hermes-instruction` with optional repeated `--test-hermes-image` for a reproducible visible Hermes text/image smoke without microphone input.

## Run and restart

- `cd app && swift build` performs a targeted build.
- `./launch.sh`, `./restart.sh`, and `./stop.sh` manage the app.
- After validated changes, run `./restart.sh` so the user can test.
- Never run a state-reset command without explicit authorization.
- For existing-checkout installation/upgrades, recommend `./install.sh --no-launch`; do not reset user state to upgrade or change providers/models.

## Completion report

Report changed files, validation evidence, skipped checks, restart status, and remaining manual verification.
