# App Behavior

- `Command + Option`: record while both keys are held. System audio is muted while recording. If both keys are released together, transcribe and paste locally through `llm_output.paste`.
- Bluetooth push-to-talk: disabled by default. If enabled in setup, the configured key records while held and delivers the transcript through `llm_output.bluetooth` when released.
- `Command + Option`, then release `Option` while still holding `Command`: finish the information recording and immediately start recording a local command.
- Release `Command`: transcribe both recordings, select matching local skills from `skills/*/SKILL.md`, run registered tool output such as Munich weather when selected, send the information, skill context, and command to the configured command LLM, then deliver the result through `llm_output.paste`. If the command segment is missing or empty, deliver the information transcript through the same configured output.
- `Command + Option`, then release `Command` while still holding `Option`: finish the information recording and immediately start recording a Hermes Agent instruction.
- Release `Option`: transcribe both recordings, enqueue the information transcript and Hermes instruction, immediately open or reuse a real Hermes/Poseidon Terminal session with `hermes --resume <session_id>`, visibly paste and submit the full prompt there, and keep new recordings available while Hermes works in that foreground UI. The final response is exported from the same session with `hermes sessions export --session-id ... -` and then pasted back into the original app or copied to the clipboard. Semantic follow-up/revision/reset/standalone decisions are delegated to Hermes, not local keyword filters. The old `tail -f` log Terminal and hidden user-turn `hermes chat -Q ... -q` path are not used as the completion UI.
- `Control + Option`: record while both keys are held. If both keys are released together, transcribe and deliver the raw text through `llm_output.dump`.
- `Control + Option`, then release `Control` while still holding `Option`: finish the dump information recording and immediately start recording a command.
- Release `Option`: transcribe both dump recordings, select matching local skills, send the information, skill context, and command to the configured command LLM, then deliver the result through `llm_output.dump`. If the command segment is missing or empty, deliver the information transcript through the same configured output.
- `llm_output.paste`, `llm_output.dump`, and `llm_output.bluetooth` accept `clipboard`, `dump`, or `bluetooth-keyboard`; defaults keep Command + Option local and leave Bluetooth disabled.
- Terminal command `go`: start continuous recording inside the running app.
- Terminal command `stop`: stop continuous recording, transcribe the full segment, and append it to the configured Obsidian daily note.
- Terminal command input supports Tab autocomplete for `go`, `stop`, `status`, `help`, and `quit`.
- Terminal continuous dump does not transcribe or write partial data before `stop`.
