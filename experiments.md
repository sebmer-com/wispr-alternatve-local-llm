# Multi-Image Provider Benchmarks

Stand der Messungen: 2026-08-24

Historische Gemma-4-Messungen; seit 2026-09-14 verwendet der Cerebras-Client `qwen-3.8-27b`. Die folgenden Latenzen gelten nicht fuer Qwen.

## Gemessene Ergebnisse

| Bilder | OpenAI `gpt-5.6-luna` | Cerebras `gemma-4-31b` |
| ---: | ---: | ---: |
| 2 | 7.49 s | 4.77 s |
| 5 | 17.94 s | 9.03 s |

Diese Werte sind beobachtete End-to-End-Latenzen der Multi-Image-Checks, keine garantierten Servicezeiten. Sie belegen, dass beide Clients mehrere geordnete Bilder verarbeiten; sie entscheiden nicht automatisch, welcher Provider fuer einen User ausgewaehlt wird.

## Request-Profile der historischen Messungen

- OpenAI: Responses API, `gpt-5.6-luna`, Reasoning `low`, Text-Verbosity `low`, `detail: low`, `store: false`.
- Cerebras: Chat Completions, `gemma-4-31b`.
- Null bis fuenf Bilder pro Command, in Capture-Reihenfolge.
- Keine automatische Bildaufnahme; nur physische `P`-Taps im ersten `Command + Option`-Segment zaehlen.
- Kein Cross-Provider-Fallback und kein Output nach Provider-Fehler.

## Interpretation

Cerebras war in diesen Messungen schneller:

- Zwei Bilder: 2.72 s schneller als OpenAI.
- Fuenf Bilder: 8.91 s schneller als OpenAI.

Die Latenz steigt bei beiden Providern mit der Bildanzahl deutlich. Deshalb bleiben Bilder optional und auf fuenf begrenzt. Der Repository-Default bleibt OpenAI; die lokale User-Config dieses Macs nutzt Cerebras.

## Guardrails fuer weitere Messungen

- Gleiches Prompt-, Bild-, Netzwerk- und Output-Ziel fuer beide Provider verwenden.
- Mindestens zehn Durchlaeufe je Fall erfassen und Median sowie p95 berichten.
- Null-, Zwei- und Fuenf-Bild-Faelle getrennt messen.
- Provider-Fehler separat ausweisen; sie duerfen keinen zweiten Provider-Request ausloesen.
- Keine API-Keys, Prompts, Transkripte oder Screenshot-Inhalte in Logs oder Ergebnisdateien speichern.
- Temporaere Bilder nach jedem Erfolg und Fehler pruefbar entfernen.

## Diagnosefelder fuer Benchmarks

Die strukturierten Provider-Logs liefern ohne Request-Body-Inhalte:

- logische Request-ID, Provider/Modell und Prompt-Zeichenanzahlen;
- Bildpfad, Bytes, MIME, Base64-Laenge und SHA-256 pro Bild;
- Payload-Bytes, Build-Dauer und konfigurierten Timeout;
- Versuch `n/max`, Dauer, HTTP-Status, Response-Bytes und Provider-Request-ID;
- Retry-Grund sowie terminale `NSError`-Domain und Code.

Damit lassen sich Build-, Netzwerk-, Retry- und Response-Zeit getrennt vergleichen. Besonders bei Timeout-Messungen muessen erster Versuch, `retry_reason=timeout`, zweiter Versuch und terminales Ergebnis dieselbe logische Request-ID tragen.

API-Key, `Authorization` und rohe Base64-Daten duerfen niemals in Benchmark-Artefakte gelangen. Das lokale `last-failed-command`-Bundle ist ebenfalls kein Benchmark-Artefakt: Es enthaelt sensible Transkripte und Bildkopien, liegt mit `0700`/`0600` unter `~/Library/Application Support/fluid-push-to-talk/last-failed-command/`, wird durch einen neueren Fehler ersetzt und erst nach erfolgreicher Provider-Antwort plus erfolgreicher Delivery geloescht. Normales Diktat und leere Commands duerfen es nicht veraendern.
