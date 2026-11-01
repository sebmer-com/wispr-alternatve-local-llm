# Trigger- und Output-Landkarte

## Trigger-Matrix

| Trigger | Verarbeitung | Ausgabe |
| --- | --- | --- |
| `Command + Option` halten, beide loslassen | Ein Segment lokal transkribieren | `llm_output.paste` |
| Waehrend des ersten `Command + Option`- oder `Control + Option`-Segments physisches `P` tippen | Einen Vollbild-Screenshot vormerken; null bis fuenf moeglich | Noch keine Ausgabe |
| `Option` zuerst loslassen, danach `Command` | Zwei Segmente und die explizit aufgenommenen Bilder an den ausgewaehlten Provider senden | Erfolgreiche Antwort ueber `llm_output.paste` |
| `Command` zuerst loslassen, danach `Option` | Normales lokales Diktat beenden; kein Hermes-Trigger | `llm_output.paste` |
| `Control + Option`, Modus `dump` | Ein Segment lokal transkribieren; Bilder dauerhaft kopieren | Markdown mit relativen Bild-Embeds |
| `Control` zuerst loslassen, Modus `dump` | Zwei-Schritt-Dump ueber den ausgewaehlten Provider; Bilder nicht an Provider senden | Provider-Ergebnis plus Bilder in Markdown |
| `Control + Option`, Modus `hermes` | Ein gesprochenes Segment plus native `/image`-Attachments an sichtbare Hermes-Session | Original-App oder Clipboard |
| Konfigurierter Bluetooth-Key | Lokale Transkription und unveraenderte Bluetooth-Route | `llm_output.bluetooth` |
| Terminal `go` / `stop` | Kontinuierliche Aufnahme starten / stoppen | Markdown-Dump |

## `P`-Capture

- Aktiv waehrend des ersten Segments von `Command + Option` und `Control + Option`.
- Ein physischer Key-down erzeugt genau einen Capture-Task.
- Auto-Repeat wird ignoriert; erst physischer Key-up setzt den Latch zurueck.
- Behandelte `P`-Key-down- und Key-up-Events werden geschluckt.
- Die Reihenfolge bleibt erhalten; nach fuenf Bildern wird jeder weitere Capture ignoriert.
- Null Bilder sind gueltig. Beim Wechsel ins zweite Segment gibt es keinen automatischen Screenshot.
- Paste-Commands senden Bilder an den Provider. Dump-Commands archivieren sie nur in Markdown. Hermes haengt sie vor dem Prompt nativ an.
- Die temporaeren Vollbild-PNGs werden nach Erfolg, gesicherter Fehler-Retention, Abbruch, lokalem Diktat und beim Aufraeumen veralteter Dateien geloescht.

## Control-Option-Auswahl

`control_option_mode` ist `dump` oder `hermes`. Fehlende Legacy-Werte und neue Konfigurationen verwenden `dump`.

- `dump`: Dauerhafte Bilder liegen unter `attachments/YYYY-MM-DD/` relativ zur Note und werden als `![Screenshot N](...)` eingebettet.
- `hermes`: Genau ein Transkript wird zur Instruction. Geordnete Bilder werden mit `/image "<absoluter Pfad>"` angehaengt, bevor der Prompt gesendet wird.
- OpenClaw ist keine angebotene Runtime; `hermes claw` ist nur ein Migrationswerkzeug.

## Provider-, Login- und Modellauswahl

`command_provider`, `command_auth` und `command_model` waehlen Provider, Anmeldung und exakte Modell-ID getrennt. Neue Installationen verwenden `openai` / `hermes` / `gpt-6-luna` ohne App-API-Key. Bestehende Konfigurationen ohne `command_auth` behalten `api_key`; explizit gespeicherte Modelle werden nicht ersetzt.

- `openai` mit `hermes`: vorhandener Hermes-Login `openai-codex`, konfiguriertes `gpt-*`-Modell; Standard `gpt-6-luna`.
- `openai` mit `api_key`: native Responses API, konfiguriertes Modell, Reasoning `low`, Text-Verbosity `low`, `store: false`, Bilder mit `detail: low`.
- `anthropic` mit `hermes`: vorhandener Hermes-Anthropic-OAuth-Login und konfiguriertes `claude-*`-Modell; Standard `claude-haiku-5-5`.
- `anthropic` mit `api_key`: native Messages API und `ANTHROPIC_API_KEY`; Haiku 5.5 mit adaptivem Thinking und Effort `low`. Nur finale Textbloecke werden ausgeliefert.
- `cerebras`: nur `api_key`, Chat Completions mit `qwen-3.8-27b`, niedriger Reasoning-Aufwand, 4096 Completion-Tokens und geordnete Bild-Data-URLs.

Aenderungen erfolgen ueber `fluid-push-to-talk setup`, `config` → Edit core setup oder die App-Konfiguration. Nur API-Key-Modus fragt einen versteckten Key ab. Vorhandene Keys anderer Provider bleiben erhalten; siehe [README](README.md#setup-and-provider-selection) fuer JSON-Beispiele und Login-Anleitung.

Die Modell-Bridge verwendet Hermes-Anmeldung und Token-Refresh, respektiert `HERMES_HOME`, kopiert keine Tokens und aendert nicht das Hermes-Standardmodell. Sie startet keinen Agenten und keine Tools; der sichtbare Hermes-Agent-Hotkey bleibt separat.

Ein ChatGPT-Abo ist kein oeffentlicher API-Key und enthaelt kein Claude. Anthropic-OAuth benoetigt laut Hermes-Dokumentation Claude Max mit zusaetzlich gekauften Extra-Usage-Credits; API-Keys werden separat nach Nutzung abgerechnet. Es gibt keinen automatischen Provider-, Login- oder kostenpflichtigen Fallback. Modell-ID, Anmeldung und Live-Katalog ersetzen keinen Inferenztest; `config doctor` meldet den jeweils geprueften Umfang.

Nach einem Provider-Fehler gibt es keinen Informationstext als Ersatz-Output. Eine leere Anweisung wird vor dem Request erkannt und liefert weiterhin die Information lokal aus.

## Request-Diagnose

Native HTTP-Clients schreiben strukturierte, schluesselwertbasierte Logs. Eine logische `request_id` verbindet:

- Request: Provider, Modell, gesamte/System/User-Prompt-Zeichen, Bildanzahl, Payload-Bytes, Build-Dauer in ms und Timeout.
- Bild: Index, lokaler Pfad, Bytes, MIME, Base64-Zeichenanzahl und SHA-256.
- Versuch: `attempt=n/max`, Start, Dauer, Outcome, HTTP-Status, Response-Bytes und Provider-Request-ID aus `x-request-id` oder `request-id`.
- Retry: Grund `timeout`, `http_429` oder `http_5xx`.
- Terminaler Fehler: `NSError`-Domain und numerischer Code.

Die Logs enthalten keinen API-Key, kein OAuth-Token, keinen `Authorization`-Header und keinen rohen Base64-Inhalt. Die Bridge loggt nur sichere Request-Metadaten, nicht zwangslaeufig die nativen HTTP-Felder. Beim Timeout sind der fehlgeschlagene Versuch, `retry_reason=timeout`, der naechste Versuch und gegebenenfalls der terminale Fehler unter derselben logischen ID sichtbar.

## Letzter fehlgeschlagener Command

Provider-, Hermes-, Markdown- oder Delivery-Fehler schreiben:

```text
~/Library/Application Support/fluid-push-to-talk/last-failed-command/
├── turn.json
└── image-01.png ... image-05.png
```

`turn.json` enthaelt Zeitpunkt, Provider, Modell, Information, Command, Fehler und Metadaten der kopierten Bilder. Das Verzeichnis hat Modus `0700`; Manifest und Bildkopien haben `0600`. Ein neuer Fehler ersetzt den vorherigen Bundle-Inhalt.

Geloescht wird der Bundle erst, wenn ein spaeterer Provider- oder Hermes-Turn erfolgreich antwortet und sein Ergebnis erfolgreich ausgeliefert wurde. Normales Diktat und ein leerer Command loeschen ihn nicht. Die Retention-Kopien bleiben fuer die Diagnose erhalten, waehrend die regulaeren temporaeren Screenshot-Dateien bereinigt werden.

## Bild- und Datenschutzfluss

1. Der User tippt `P` bewusst waehrend der ersten Aufnahme.
2. Die App speichert den sichtbaren Desktop temporaer als PNG.
3. Paste-Command, Markdown oder Hermes verwenden die Bilder entsprechend dem konfigurierten Triggervertrag; Dump-Provider-Commands senden sie ausdruecklich nicht an den Provider.
4. Auf jedem Exit-Pfad werden regulaere temporaere Dateien geloescht; bei Fehlern bleiben nur die geschuetzten Kopien im Last-Failure-Bundle.

Screen & System Audio Recording ist nur fuer Bildaufnahme erforderlich. Ein fehlgeschlagener einzelner Capture fuegt kein Bild hinzu und stoppt die Audioaufnahme nicht.

## Unveraenderte Pfade

- Hermes behaelt Clipboard-Kontext, persistente Session, sichtbares Terminal und Rueckgabe zur Original-App.
- Kontinuierliches `go`/`stop` bleibt unabhaengig und textbasiert.
- Bluetooth-Hotkey, ESP32-Serial-Protokoll und Output-Routing bleiben unveraendert.
- `llm_output.paste`, `.dump` und `.bluetooth` akzeptieren weiter `clipboard`, `dump` oder `bluetooth-keyboard`.

## Direkte Tests

Command mit null oder mehreren `--test-command-image`-Argumenten:

```bash
app/.build/debug/fluid-push-to-talk \
  --test-command-information "..." \
  --test-command "..." \
  --test-command-image screenshot.png
```

Offline-Checks mit Command Line Tools (XCTest explizit ausgelassen; fuer die volle Swift-Testsuite wird Xcode benoetigt):

```bash
python3 tests/run_all.py --skip-llm --skip-xctest
```

Optionale Abo-Livetests mit synthetischem Text und fuenf generierten PNGs (verbrauchen Provider-Kontingent beziehungsweise Anthropic-Extra-Credits):

```bash
python3 tests/hermes_subscription_live_case.py --provider openai
python3 tests/hermes_subscription_live_case.py --provider anthropic
```

Optionale separat abgerechnete API-Key-Livetests fuer OpenAI und Cerebras mit fuenf Bildern:

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```