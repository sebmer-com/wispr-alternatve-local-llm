# Trigger- und Output-Landkarte

Stand: 2026-06-18. Grundlage ist der aktuelle Working Tree von `local-audio`, insbesondere `README.md`, `features.md`, `appBehavior.md`, `config/config.json`, `app/Sources/*` und die statischen Tests in `tests/`.

Wichtig: `app/Sources/HermesAgentRunner.swift` hat aktuell uncommitted Änderungen. Diese Datei ist in der Auswertung so berücksichtigt, wie sie im Working Tree vorliegt.

## Kurzfazit

Die App hat sechs normale Nutzer-Triggerfamilien:

1. `Command + Option` für lokale Diktat-Paste.
2. `Command + Option`, dann `Option` zuerst loslassen, für lokale Zwei-Schritt-Kommandos über den Command-LLM.
3. `Command + Option`, dann `Command` zuerst loslassen, für Hermes-Agent-Anweisungen.
4. `Control + Option` für Markdown-Dump.
5. `Control + Option`, dann `Control` zuerst loslassen, für Zwei-Schritt-Kommandos in den Markdown-Dump.
6. Optionaler Bluetooth-Key für ESP32/Bluetooth-Tastaturausgabe, standardmäßig deaktiviert.

Zusätzlich gibt es Terminal-Kommandos im laufenden App-Prozess (`go`, `stop`, `status`, `help`, `quit`) und direkte CLI-Testeingaben (`--test-command-information`/`--test-command`, `--test-bluetooth-keyboard`).

## Default-Konfiguration

Aus `config/config.json`:

```json
{
  "asr": {
    "model_version": "v3",
    "language": "de"
  },
  "llm_output": {
    "paste": "clipboard",
    "dump": "dump",
    "bluetooth": "bluetooth-keyboard"
  },
  "local_llm": {
    "provider": "openai_compatible",
    "model": "gpt-5.4-mini",
    "base_url": "https://api.openai.com/v1",
    "api_key_env": "OPENAI_API_KEY"
  }
}
```

Damit ist die Command-LLM-Schicht aktuell ein generischer OpenAI-kompatibler Chat-Completions-Client. Der alte MLX/Bonsai-Weg existiert weiter als konfigurierbarer Fallback über `local_llm.provider: "mlx"`, Azure DeepSeek als explizites Hosted-Preset.

## Trigger-Matrix

| Trigger | User-Eingabe | Interne Aktion | Default-Output |
| --- | --- | --- | --- |
| `Command + Option` halten, beide loslassen | Ein Audioschnipsel | ASR, Text-Replacements, direkte Ausgabe | `llm_output.paste` -> `clipboard` |
| `Command + Option`, `Option` zuerst loslassen, danach `Command` loslassen | Information + gesprochenes Kommando | ASR fuer beide Segmente, Skill-Auswahl, Command-LLM, Fallbacks | `llm_output.paste` -> `clipboard` |
| `Command + Option`, `Command` zuerst loslassen, danach `Option` loslassen | Information + Hermes-Anweisung | ASR, Screenshot-Kontext, Clipboard-Kontext, Hermes-Session, Ergebnisrueckgabe | Paste in Original-App oder Clipboard-Fallback |
| `Control + Option` halten, beide loslassen | Ein Audioschnipsel | ASR, Text-Replacements, Markdown-Dump | `llm_output.dump` -> `dump` |
| `Control + Option`, `Control` zuerst loslassen, danach `Option` loslassen | Information + gesprochenes Kommando | ASR fuer beide Segmente, Skill-Auswahl, Command-LLM, Fallbacks | `llm_output.dump` -> `dump` |
| Konfigurierten Bluetooth-Key halten und loslassen | Ein Audioschnipsel | ASR, Text-Replacements, konfigurierte Bluetooth-Route | `llm_output.bluetooth`; standardmäßig deaktiviert/lokal |
| Terminal `go` | Typed command im App-Terminal | Continuous Dump startet Aufnahme ohne Watchdog | Noch kein Output |
| Terminal `stop` | Typed command im App-Terminal | Stoppt Continuous Dump, transkribiert komplettes Segment | Markdown-Dump |
| Terminal `status` | Typed command im App-Terminal | Gibt Recording-Status aus | Console |
| Terminal `help`/`?` | Typed command im App-Terminal | Zeigt Terminal-Kommandos | Console |
| Terminal `quit`/`exit` | Typed command im App-Terminal | Stoppt Continuous Dump und beendet App | Prozessende |
| CLI `--test-command-information T --test-command T` | Textargumente statt Audio | Testet CommandResultGenerator ohne ASR | `[result] ...` auf stdout |
| CLI `--test-bluetooth-keyboard T` | Textargument statt Audio | Sendet Text direkt an ESP32 | `[bluetooth-keyboard] ...` auf stdout |

Terminal-Aliase: `record go`, `recording go`, `record stop`, `recording stop`, `record status`, `recording status`.

## Hotkey-Details

### Paste Mode

- Config: `hotkeys.paste` ist `Command + Option`.
- Ablauf: Aufnahme startet beim gedrueckten Modifier-Chord. Beim gemeinsamen Loslassen wird transkribiert.
- Danach werden `config/textReplacements.json`-Ersetzungen angewendet.
- Ausgabe laeuft ueber `llm_output.paste`, standardmaessig `clipboard`.
- Clipboard-Paste fuegt aktuell ein trailing space hinzu, sendet `Cmd+V` und stellt die alte Zwischenablage nach `restore_clipboard_delay` wieder her.

### Paste Command Mode

- Einstieg: `Command + Option` halten, dann `Option` loslassen, waehrend `Command` gehalten bleibt.
- Die App beendet damit das Informationssegment und startet nach `0.15s` Grace-Zeit das Kommandosegment.
- Beim Loslassen von `Command` werden beide Segmente transkribiert.
- Danach:
  - Skill-Auswahl aus `skills/*/SKILL.md`.
  - Optionaler Tool-Output.
  - Command-LLM mit Prompt aus `config/promptConfig.json`.
  - Ausgabe ueber `llm_output.paste`.
- Wenn das Kommandosegment leer ist, wird die Information als Fallback ausgegeben.
- Wenn der Command-LLM deaktiviert oder nicht erreichbar ist, nutzt die App Skill-Tool-Fallbacks oder den Informationstext.

### Hermes Agent Mode

- Einstieg: `Command + Option` halten, dann `Command` loslassen, waehrend `Option` gehalten bleibt.
- Die App beendet das Informationssegment, versucht einen Screenshot-Kontext aufzunehmen und startet das Hermes-Anweisungssegment.
- Beim Loslassen von `Option` werden Information und Hermes-Anweisung transkribiert.
- Hermes bekommt:
  - Informationstranskript.
  - Anweisungstranskript.
  - aktuellen Clipboard-Text, begrenzt auf 20.000 Zeichen.
  - Screenshot-Pfad, falls Screen-Recording-Berechtigung vorhanden ist.
  - eine eindeutige `LOCAL_AUDIO_HERMES_RUN_...` Run-ID.
- Die Entscheidung, ob die Anweisung Follow-up, Revision, Reset oder Standalone ist, wird explizit Hermes ueberlassen. Lokal gibt es dafuer keine Keyword-Klassifikation.
- Der Job wird in `hermesJobQueue` seriell abgearbeitet, damit named-session-Reihenfolge erhalten bleibt.
- Ergebnisrueckgabe:
  - Wenn die urspruengliche Ziel-App noch verfuegbar ist, wird sie aktiviert und das Hermes-Ergebnis ueber den Paste-Output eingefuegt.
  - Wenn die Ziel-App nicht verfuegbar ist, wird das Ergebnis in die Zwischenablage kopiert.

Aktueller Working-Tree-Hinweis: `HermesAgentRunner.swift` foregroundet momentan eine Terminal-Session mit `hermes --resume <sessionID>`, pastet den Prompt sichtbar per System Events hinein und pollt danach `hermes sessions export --session-id <id> -` nach der Antwort zur Run-ID. Die aktuell geaenderte `tests/hermes_shortcut_static_case.py` passt zu diesem Vertrag: sichtbare Foreground-Session, Prompt-Paste in Terminal, Session-Export-Polling, Run-ID-Korrelation und Screenshot-Kontext im Prompt statt hidden `hermes chat --image`. Diese Hermes-Aenderungen sind im Working Tree noch uncommitted.

### Markdown Dump Mode

- Config: `hotkeys.dump` ist `Control + Option`.
- Gemeinsames Loslassen schreibt die rohe Transkription in den konfigurierten Markdown-Pfad.
- Default-Ziel ist eine Obsidian Daily Note mit Platzhalter `YYYY-MM-DD`.
- `dump.append` steuert Append vs. Replace.
- `dump.include_timestamp` fuegt standardmaessig einen Timestamp im Format `yyyy-MM-dd HH:mm` ein.

### Markdown Dump Command Mode

- Einstieg: `Control + Option` halten, dann `Control` loslassen, waehrend `Option` gehalten bleibt.
- Danach wird ein zweites Segment als Kommando aufgenommen.
- Beim Loslassen von `Option` laufen Skill-Auswahl und Command-LLM wie im Paste Command Mode.
- Ausgabe laeuft ueber `llm_output.dump`, standardmaessig Markdown-Dump.

### Bluetooth Keyboard Mode

- Config-Default: `hotkeys.bluetooth.enabled` ist `false` und `hotkeys.bluetooth.keys` ist `[]`.
- Bluetooth wird erst behandelt, wenn der User es im Setup aktiviert, wodurch `enabled: true` geschrieben wird, und einen Key eingibt oder Enter fuer den Setup-Default `right_shift` drueckt.
- Der konfigurierte Bluetooth-Key wird nur genommen, wenn nicht gleichzeitig andere Modifier aktiv sind.
- Ausgabe laeuft standardmaessig lokal ueber `clipboard`; bei aktiviertem Bluetooth setzt das Setup `llm_output.bluetooth` auf `bluetooth-keyboard`.
- Technisch ist das kein externer `keyboard-cli`, sondern Swift spricht direkt mit dem ESP32 ueber USB-Serial.

## Output-Methoden

Jeder Flow (`paste`, `dump`, `bluetooth`) kann eine dieser Ausgaben bekommen:

```json
"clipboard"
"dump"
"bluetooth-keyboard"
```

### `clipboard`

- Schreibt Text in die macOS-Zwischenablage.
- Sendet `Cmd+V`.
- Haengt ein Leerzeichen an, wenn der Text nicht mit Whitespace endet.
- Kann alte Clipboard-Inhalte wiederherstellen.
- Wird ignoriert, wenn `paste.enabled` false ist.

### `dump`

- Schreibt Text in `dump.markdown_file`.
- Erstellt fehlende Zielordner.
- Ersetzt `YYYY-MM-DD` und `yyyy-MM-dd` durch das lokale Tagesdatum.
- Fuegt je nach Config Timestamp und Leerzeilen ein.
- Wird ignoriert, wenn `dump.enabled` false ist.

### `bluetooth-keyboard`

- Nutzt `bluetooth_keyboard.port`, falls gesetzt.
- Sonst Auto-Detection: genau ein `/dev/cu.usbmodem*` oder `/dev/cu.usbserial*`.
- Bei 0 oder mehreren passenden Ports muss `bluetooth_keyboard.port` explizit gesetzt werden.
- Protokoll: `KBD1` bei 115200 Baud.
- Ablauf:
  - `STATUS` prueft BLE-Verbindung und Busy-Status.
  - `TYPE_CHUNKED <bytes> <crc32> <chunk_size>` startet Transfer.
  - Payload wird in UTF-8-Chunks uebertragen.
  - Firmware antwortet mit `READY`, `RECEIVED`, `QUEUED`, `DONE`.
- Default-Chunk-Size ist `32`, firmware-kompatibel.
- Der ESP32 haengt per USB am Mac und tippt per Bluetooth in das Zielgeraet.

## Command-LLM

### OpenAI-Compatible Default

- Master-Gate: Command-Generierung ist nur aktiv, wenn `local_llm.enabled` und `local_llm.command_generation_enabled` beide true sind.
- Provider: `openai_compatible`.
- Modell: `gpt-5.4-mini` oder ein anderer exakter Provider-Modell-Slug.
- Base URL: OpenAI-kompatible Provider-Basis, z.B. `https://api.openai.com/v1`; der Client normalisiert auf `/chat/completions`.
- API-Key:
  - kommt standardmaessig aus `OPENAI_API_KEY`.
  - alternativ aus `local_llm.dotenv_file`, default `.env`.
  - wird nicht in JSON erwartet.
- Request:
  - `Authorization: Bearer <key>`.
  - `api-key: <key>`.
  - `temperature: 0`.
  - `max_tokens: 128`.
  - `request_timeout_seconds: 15`.
  - `timeout_seconds: 30`.
  - `max_retries: 1`.
- Kein Warm-up noetig; `LocalLLMReadinessMonitor` markiert Remote-Provider direkt als bereit.

### MLX / Bonsai Fallback

- Provider: `mlx`.
- Erwartetes Modell: `prism-ml/Ternary-Bonsai-8B-mlx-2bit`.
- Nutzt `llm-tool chat` direkt, falls vorhanden, sonst `mlx-run llm-tool`.
- Fuehrt Warm-up durch, damit Zwei-Schritt-Kommandos schneller reagieren.
- Reset pro Request ueber `/reset`, damit keine Chat-History zwischen Kommandos leakt.

### Prompt-Form

`config/promptConfig.json` definiert:

- System-Prompt: transformiere Information nach Task, nutze Tool-Output, kurz bleiben, nur Ergebnis ausgeben.
- User-Prompt ohne Skill-Kontext:

```text
Do:
{{command}}

Text:
{{information}}
```

- User-Prompt mit Skill-Kontext ergaenzt `Context: {{skill_context}}`.

## Skills und Tool-Ausgabe

Die App scannt `skills/*/SKILL.md` aus dem konfigurierten `skills.directory`.

Aktueller checked-in Default zeigt auf:

```text
/Users/dominik/git/local-audio/skills
```

Im aktuellen Repo-Pfad liegen aber:

```text
/Users/sebastianmertens/local-audio/skills
```

Wenn die installierte Config nicht angepasst ist, kann die App also an den lokalen Repo-Skills vorbeischauen.

### Auswahl

- Metadata-Auswahl: Tokens aus `command + information` gegen Skill-`name` und `description`.
- Config:
  - `skills.max_selected`: `2`.
  - `skills.minimum_score`: `2`.
- Wenn die Metadata-Auswahl leer ist und Triggerwoerter wie `skill`, `task`, `todo`, `aufgabe`, `greet`, `wetter`, `weather` auftauchen, darf der Command-LLM eine JSON-Liste exakter Skill-Namen auswaehlen.

### Aktuell vorhandene Skills

| Skill | Zweck | Tool | Fallback/Final |
| --- | --- | --- | --- |
| `tasks` | Aufgabe in Obsidian Daily Note schreiben | `skills/tasks/scripts/add_task.py` | `tool_fallback: true`, `tool_final_result: true` |
| `greet` | Demo-Greeting, spricht via macOS `say` | `skills/greet/scripts/greet.py` | kein Fallback, kein Final Result |

Die Tool-Umgebung bekommt u.a.:

- `FLUID_SKILL_NAME`
- `FLUID_SKILL_COMMAND`
- `FLUID_SKILL_INFORMATION`
- `FLUID_OBSIDIAN_DAILY_NOTE`

Die App fuehrt nicht beliebige Anweisungen aus dem Skill-Text aus. Ausgefuehrt wird nur ein explizit im Skill-Frontmatter registriertes `tool`.

## Weitere Eingabequellen

Neben Audio und Terminal-Kommandos gibt es weitere Datenquellen:

- Clipboard: nur im Hermes-Agent-Kontext aktiv eingebunden.
- Screenshot: nur im Hermes-Agent-Modus, wenn macOS Screen Recording erlaubt ist.
- `.env`: nur fuer Azure-Key-Aufloesung.
- Config-Dateien: `config.json`, `promptConfig.json`, `textReplacements.json`.
- Gespeicherte WAVs: optional, wenn `recordings.save` true ist.
- `SelectedTextGoogleSearcher.swift`: Code fuer `Cmd+C`-Auswahl und Google-Suche in Chrome existiert, aber im aktuellen Runtime-Code wurde kein Trigger gefunden.

## Fallbacks und Fehlerverhalten

- Zu kurze oder leere Audioaufnahmen werden nicht transkribiert.
- ASR-Fehler liefern keinen Output fuer diesen Trigger.
- Leeres Kommandosegment: Information wird direkt ausgegeben.
- Command-LLM deaktiviert: Skill-Tool-Fallback oder Information.
- Command-LLM nicht erreichbar: Skill-Tool-Fallback oder Information.
- Hermes-Anweisung leer: Information wird per Paste-Fallback ausgegeben.
- Hermes-Screenshot fehlt: Hermes laeuft weiter mit `[No screenshot was captured.]`.
- Originale Paste-Ziel-App fehlt nach Hermes: Ergebnis wird in die Zwischenablage kopiert.
- Bluetooth:
  - kein USB-Serial-Port: Fehler mit Hinweis auf `bluetooth_keyboard.port`.
  - mehrere USB-Serial-Ports: Fehler mit Liste und Hinweis auf expliziten Port.
  - ESP32 nicht per Bluetooth verbunden: Fehler aus `STATUS`.
  - ESP32 busy oder Payload zu gross: Fehler vor Transfer.

## Launch- und Testwege

### Normale App

```bash
./launch.sh
```

Startet den gebauten Debug-Binary direkt. Wenn der Binary fehlt, bricht das Script mit Build-Hinweis ab.

### Restart

```bash
./restart.sh
```

Wenn nicht bereits in einem sichtbaren Terminal, oeffnet es Terminal per AppleScript und startet sich dort erneut. Danach:

1. `./stop.sh`
2. falls Binary fehlt: `swift build`
3. `./launch.sh`

### Stop

```bash
./stop.sh
```

Beendet laufende `fluid-push-to-talk`-Instanzen per `pkill`.

### Direkte CLI-Tests

```bash
app/.build/debug/fluid-push-to-talk \
  --test-command-information "..." \
  --test-command "..."
```

Testet Command-LLM/Skill/Fallback ohne ASR und ohne Hotkeys.

```bash
app/.build/debug/fluid-push-to-talk \
  --test-bluetooth-keyboard "Bluetooth-Test"
```

Testet ESP32-Ausgabe ohne ASR-Start.

## Dokumentations- und Test-Inkonsistenzen

1. `README.md` erwaehnt noch `weather-munich`; im aktuellen `skills/`-Ordner liegen dagegen nur `tasks` und `greet`.
2. `README.md`/`config/config.json` enthalten mehrere Pfade unter `/Users/dominik/...`; der aktuelle Workspace liegt unter `/Users/sebastianmertens/local-audio`.
3. `tests/test.md` enthaelt noch Bonsai/MLX-Formulierungen an Stellen, obwohl die aktuelle Default-Config Azure/DeepSeek verwendet.
4. Hermes ist aktuell konsistent zwischen geaendertem Runner, Runtime und geaenderter Static-Testdatei, aber diese Hermes-Aenderungen sind uncommitted und deshalb als Working-Tree-Zustand zu behandeln.

## Praktische Zusammenfassung fuer User-Output

Wenn man nur wissen will, wohin ein Nutzer etwas schicken kann:

- In ein lokales Textfeld: `Command + Option`, Output `clipboard`.
- In eine Markdown Daily Note: `Control + Option`, Output `dump`.
- Auf ein anderes Geraet per ESP32-Tastatur: Bluetooth im Setup aktivieren, Key setzen oder Enter fuer `right_shift`, Output `bluetooth-keyboard`.
- Als lokale Transformation: Zwei-Schritt-Flow mit `Command + Option`, Output standardmaessig `clipboard`.
- Als Markdown-Transformation: Zwei-Schritt-Flow mit `Control + Option`, Output standardmaessig `dump`.
- Als Agentenauftrag an Hermes/Poseidon: `Command + Option`, dann `Command` zuerst loslassen, Output zurueck in Original-App oder Clipboard-Fallback.
- Als kontinuierliche Daily-Note-Aufnahme: Terminal `go`, dann `stop`.
