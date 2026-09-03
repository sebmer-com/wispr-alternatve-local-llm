# Trigger- und Output-Landkarte

Stand: 2026-08-24

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

`control_option_mode` ist `dump` oder `hermes`. Fehlende Legacy-Werte verwenden `dump`; die installierte User-Config auf diesem Mac waehlt `hermes`.

- `dump`: Dauerhafte Bilder liegen unter `attachments/YYYY-MM-DD/` relativ zur Note und werden als `![Screenshot N](...)` eingebettet.
- `hermes`: Genau ein Transkript wird zur Instruction. Geordnete Bilder werden mit `/image "<absoluter Pfad>"` angehaengt, bevor der Prompt gesendet wird.
- OpenClaw ist keine angebotene Runtime; `hermes claw` ist nur ein Migrationswerkzeug.

## Provider-Auswahl

`command_provider` ist eines von:

- `openai`: `https://api.openai.com/v1/responses`, `gpt-5.6-luna`, Reasoning `low`, Text-Verbosity `low`, `store: false`, Bilder mit `detail: low`.
- `cerebras`: `https://api.cerebras.ai/v1/chat/completions`, `gemma-4-31b`, geordnete Bild-Data-URLs.
- `gemini`: `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent`, `gemini-3.5-flash`, Auth-Header `x-goog-api-key` statt Bearer, geordnete `inlineData`-Bildteile ohne Data-URL-Praefix.

Der Repository-Default ist `openai`. Die installierte User-Config auf diesem Mac ueberschreibt ihn mit `cerebras`. Setup schreibt nur die Auswahl in die User-Config und aktualisiert nur den dazugehoerigen Key in der benachbarten `.env`:

- OpenAI: `OPENAI_API_KEY`
- Cerebras: `CEREBRAS_API_KEY`
- Gemini: `GEMINI_API_KEY`

Ein Request verwendet ausschließlich den ausgewaehlten Provider. Nach einem Provider-Fehler gibt es weder einen Aufruf eines anderen Providers noch Informationstext als Output. Eine leere Anweisung wird vor dem Request erkannt und liefert weiterhin die Information lokal aus.

## Request-Diagnose

OpenAI, Cerebras und Gemini schreiben dasselbe strukturierte, schluesselwertbasierte Logformat. Eine logische `request_id` verbindet:

- Request: Provider, Modell, gesamte/System/User-Prompt-Zeichen, Bildanzahl, Payload-Bytes, Build-Dauer in ms und Timeout.
- Bild: Index, lokaler Pfad, Bytes, MIME, Base64-Zeichenanzahl und SHA-256.
- Versuch: `attempt=n/max`, Start, Dauer, Outcome, HTTP-Status, Response-Bytes und Provider-Request-ID aus `x-request-id` oder `request-id`.
- Retry: Grund `timeout`, `http_429` oder `http_5xx`.
- Terminaler Fehler: `NSError`-Domain und numerischer Code.

Die Logs enthalten keinen API-Key, keinen `Authorization`-Header und keinen rohen Base64-Inhalt. Beim Timeout sind der fehlgeschlagene Versuch, `retry_reason=timeout`, der naechste Versuch und gegebenenfalls der terminale Fehler unter derselben logischen ID sichtbar.

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

Optionale Live-Checks fuer alle drei Provider mit fuenf Bildern:

```bash
python3 tests/run_all.py --skip-llm --live-multi-image
```
