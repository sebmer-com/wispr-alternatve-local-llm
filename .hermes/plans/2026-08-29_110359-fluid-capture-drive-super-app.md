# Fluid Apple-Capture Share MVP – Research- und Implementierungsplan

> **Für Hermes/Coding Agent:** Dieses Dokument beschreibt bewusst ein minimales MVP. Fluid zeichnet selbst weder Screenshots noch Videos auf. Es beobachtet ausschließlich Apples konfigurierten Screenshot-Ordner und bietet danach einen expliziten Google-Drive-Share an.

**Goal:** Nach einem mit macOS aufgenommenen Screenshot oder Screen Recording zehn Sekunden lang eine minimalistische Fluid-Karte mit `Share` und `×` zeigen; `Share` komprimiert die Datei, lädt sie in den konfigurierten Google-Drive-Ordner, setzt die gewünschte Linkfreigabe und kopiert den verifizierten Drive-Link. Dieselbe Aktion soll für vorhandene Dateien im Finder als Quick Action verfügbar sein.

**Architecture:** Apples Screenshot-App bleibt vollständig für Aufnahme, Auswahl, Fenster, Bildschirm und Video zuständig. Fluid beobachtet den bereits von macOS verwendeten Ordner per FSEvents, klassifiziert nur neue stabile Bild-/Videodateien, zeigt ein nicht-fokussierendes `NSPanel` und führt bei Zustimmung eine kleine Upload-Pipeline aus. Finder-Dateien werden über eine installierte Quick Action an denselben `share-file`-Entry-Point übergeben.

**Tech Stack:** Swift 6, AppKit, FSEvents, UniformTypeIdentifiers, ImageIO, AVFoundation, URLSession, OAuth 2.0 + PKCE, Google Drive API v3, macOS Keychain, XCTest.

---

## 1. Produktentscheidung

### Gewähltes MVP

Fluid ersetzt die macOS-Screenshot-App **nicht**.

Der Nutzer verwendet weiterhin:

- `Shift-Command-3` für den gesamten Bildschirm,
- `Shift-Command-4` für Auswahl/Fenster,
- `Shift-Command-5` für Apples Screenshot- und Screen-Recording-Oberfläche.

Apple erlaubt in der Screenshot-App die Auswahl des Speicherorts und speichert fertige Aufnahmen dort als Datei.[16] Fluid beobachtet nur diesen Ordner und fragt danach:

```text
┌──────────────────────────────────────────┐
│ [Vorschau]  Screenshot / Video           │
│             645 KB · gerade eben         │
│                                          │
│                         [Share]   [×]     │
└──────────────────────────────────────────┘
```

Die Karte erscheint oben rechts, bleibt zehn Sekunden sichtbar und verschwindet danach folgenlos.

### Verhalten

- `Share`: komprimieren → in Drive hochladen → Linkfreigabe setzen → Read-back → Link ins Clipboard.
- `×`: Karte schließen; lokale Datei bleibt unverändert.
- Timeout nach zehn Sekunden: entspricht `×`; keine Cloud-Aktion.
- Klick auf die Vorschau: Datei per Quick Look öffnen.
- Mehrere schnelle Screenshots: Karten nicht übereinander stapeln; eine kleine FIFO-Queue anzeigen, maximal drei wartende Items.
- Ein bereits durch Fluid verarbeitetes File wird nicht erneut automatisch angeboten.
- Eine manuelle Finder-Aktion darf es bewusst erneut teilen oder den vorhandenen Link erneut kopieren.

### Nach erfolgreichem Share

Dieselbe Karte wechselt kurz in:

```text
┌──────────────────────────────────────────┐
│ ✓ In Google Drive geteilt                │
│ Link wurde kopiert                       │
│                         [Öffnen]   [×]    │
└──────────────────────────────────────────┘
```

Nach weiteren fünf Sekunden automatisch schließen.

### Bei Fehler

```text
┌──────────────────────────────────────────┐
│ Upload fehlgeschlagen                    │
│ Keine Internetverbindung                 │
│                    [Erneut] [Details] [×]│
└──────────────────────────────────────────┘
```

Das lokale Original wird niemals gelöscht.

---

## 2. Bestätigter lokaler Zustand

Auf diesem Mac ist aktuell konfiguriert:

```text
com.apple.screencapture location = ~/Documents/Screens
style = selection
target = file
video = 1
```

Der Ordner existiert:

```text
/Users/sebastianmertens/Documents/Screens
```

Der vom Nutzer gezeigte aktuelle Screenshot liegt bereits dort:

```text
/Users/sebastianmertens/Documents/Screens/Screenshot 2026-08-29 at 11.22.50.png
```

Größe bei der Analyse: 644.870 Bytes.

Ein realer Apple-Screenshot auf diesem Mac trägt folgende Metadaten:

```text
kMDItemContentType = public.png
com.apple.metadata:kMDItemIsScreenCapture
com.apple.metadata:kMDItemScreenCaptureType = selection
com.apple.metadata:kMDItemScreenCaptureGlobalRect
```

Diese Metadaten sind besser zur Klassifikation geeignet als der lokalisierte Dateiname `Screenshot …`.

### Konsequenz

Der MVP darf `~/Documents/Screens` als automatisch entdeckten Vorschlag verwenden. Er soll den Pfad jedoch nicht hart codieren:

1. `defaults read com.apple.screencapture location` beim Start lesen.
2. Pfad normalisieren und Existenz prüfen.
3. In Fluid Settings anzeigen.
4. Nutzer kann einen anderen Watch-Ordner auswählen.
5. Bei Änderung der Apple-Location Hinweis anzeigen und die neue Location zur Übernahme anbieten.

Da Fluid derzeit nicht als sandboxed App-Store-App gebaut wird, ist ein Security-Scoped Bookmark für den ersten lokalen Build nicht zwingend. Die Folder-Abstraktion soll trotzdem so gestaltet werden, dass Sandboxing später möglich bleibt.

---

## 3. Was der Screenshot des Nutzers zeigt

Der Screenshot zeigt einen Finder-Rechtsklick auf eine Datei. Im Kontextmenü sind unter anderem sichtbar:

- `Quick Look`
- `Copy`
- `Share…`
- `Quick Actions > Customise…`

Das bestätigt zwei sinnvolle Integrationswege:

### MVP: Finder Quick Action „Share with Fluid“

Eine macOS Quick Action kann in Finder verfügbar gemacht und über `~/Library/Services/*.workflow` beziehungsweise später über Shortcuts bereitgestellt werden. Automator-Workflows lassen sich außerdem in Shortcuts importieren.[19]

Gewünschtes Kontextmenü:

```text
Quick Actions
  Share with Fluid
```

Die Quick Action akzeptiert:

- PNG
- JPEG/JPG
- HEIC
- MOV
- MP4

und ruft auf:

```bash
fluid-push-to-talk share-file "$selected_file"
```

Der Command verwendet exakt dieselbe Kompressions-, Upload- und Linklogik wie die Zehn-Sekunden-Karte.

### Später optional: echter Eintrag im Systemmenü `Share…`

Eine macOS Share Extension erscheint in der systemeigenen Share-Oberfläche und kann Attachments wie Bilder oder Videos übernehmen.[20] Das wäre die sauberste Integration direkt unter `Share…`, erfordert aber:

- eine richtige `.app`-Bundle-Struktur,
- ein zusätzliches Xcode Share-Extension-Target,
- App Groups oder eine andere sichere Kommunikation zwischen Extension und Host,
- Signing/Entitlements/Packaging.

Das ist **nicht** Teil des absoluten MVP. Auf der analysierten Maschine ist aktuell nur die Command Line Tools Toolchain aktiv; `xcodebuild` kann ohne aktive vollständige Xcode-Installation kein Extension-Target bauen. Die Finder Quick Action ist deshalb der schnellere erste Weg.

### Kein Finder Sync im MVP

Finder Sync kann Kontextmenüs und Badges in überwachten Ordnern ergänzen, ist laut Apple aber primär für Apps gedacht, die lokale Ordner mit einer Remote-Quelle synchronisieren.[21] Für „diese einzelne Datei jetzt teilen“ wäre es schwerer als eine Quick Action und unnötig.

---

## 4. Watcher-Design

Apple File System Events liefert Benachrichtigungen, wenn sich Inhalte einer Verzeichnishierarchie ändern.[17] Ein Event bedeutet allerdings nur „hier hat sich etwas geändert“, nicht „ein Screenshot ist vollständig geschrieben“.

### Ablauf

1. Beim Start bestehende Dateien als Baseline erfassen, aber nie rückwirkend anbieten.
2. `FSEventStream` auf den Watch-Ordner starten.
3. Bei Event nur neue oder geänderte reguläre Dateien betrachten.
4. Dateiendung und UTI validieren.
5. Schreibabschluss abwarten:
   - 300 ms warten,
   - Dateigröße lesen,
   - weitere 300 ms warten,
   - Dateigröße erneut lesen,
   - nur fortfahren, wenn beide Werte identisch und größer als null sind,
   - maximal zehn Versuche.
6. Für Bilder Apple-Screenshot-Metadaten/xattr prüfen.
7. Videos aus dem dedizierten `Screens`-Ordner akzeptieren, wenn UTI Movie ist und das File nach Watcher-Start erstellt wurde.
8. Fingerprint bilden und deduplizieren.
9. Zehn-Sekunden-Karte anzeigen.

### Unterstützte Dateien

```swift
enum ShareableMediaKind: String, Codable {
    case image
    case video
}

let imageTypes: Set<UTType> = [.png, .jpeg, .heic]
let videoTypes: Set<UTType> = [.quickTimeMovie, .mpeg4Movie]
```

### Dedupe

Fingerprint im MVP:

```text
standardized path + creation date + byte count
```

Persistieren in:

```text
~/Library/Application Support/fluid-push-to-talk/capture-share/history.json
```

Nicht die gesamte Datei hashen, bevor der Nutzer `Share` drückt; das wäre für große Videos unnötige I/O. Für den Drive-Upload kann später ein SHA-256 für Idempotenz berechnet werden.

### Ordneränderung

Alle 60 Sekunden oder nach Wake:

1. aktuellen `com.apple.screencapture location`-Wert lesen,
2. mit konfiguriertem Watch-Ordner vergleichen,
3. bei Abweichung nur einmal benachrichtigen,
4. nie still den Watch-Ordner wechseln.

---

## 5. Zehn-Sekunden-Karte

### Technische Form

- AppKit `NSPanel`
- `styleMask`: `.nonactivatingPanel`, `.borderless`
- Floating, aber nicht so hoch wie System-Passwort-/Permission-Dialoge
- keine Aktivierung und kein Fokusdiebstahl
- auf dem Bildschirm mit Mauszeiger oder dem aktiven Finder-Fenster
- Position: oben rechts mit 16–20 pt Abstand zur sichtbaren Screen-Fläche
- Thumbnail asynchron laden
- Countdown intern, visuell nur als schmale dezente Progress-Linie

### Zustände

```swift
enum ShareCardState {
    case awaitingDecision(remainingSeconds: Int)
    case compressing(progress: Double?)
    case uploading(progress: Double)
    case settingPermission
    case verifying
    case completed(shareURL: URL)
    case failed(message: String, retryable: Bool)
}
```

### Interaktionen

`Share`:

- Countdown stoppen.
- Button gegen Spinner/Progress austauschen.
- X bleibt verfügbar und cancelt Upload/Export, löscht aber nie das Original.

`×`:

- UI sofort schließen.
- Pending Work abbrechen.
- Datei als „dismissed“ markieren, damit sie nicht beim nächsten Watcher-Event erneut erscheint.

Timeout:

- wie Dismiss behandeln.
- keine Notification-Center-Historie erzeugen.

Thumbnail:

- `QLPreviewPanel` oder Quick Look öffnen.
- Countdown pausiert während Quick Look nicht; Simplizität vor Sonderlogik.

### Queue

- maximal eine sichtbare Karte.
- maximal drei weitere neue Assets in FIFO.
- bei mehr als vier schnellen Captures: älteste wartende Karte überspringen und nur in History als `notPresentedQueueFull` notieren.
- kein Kartenstapel wie bei großen Screenshot-Tools.

---

## 6. Google-Drive-Flow

### Einmaliges Setup

1. `Connect Google Drive`.
2. OAuth im Systembrowser.
3. Authorization Code + PKCE.
4. Refresh Token ausschließlich im Keychain speichern.
5. Foto-Zielordner wählen.
6. Video-Zielordner wählen; darf derselbe Ordner sein.
7. Share Visibility auswählen:
   - `Restricted`
   - `Anyone with the link can view`

Google empfiehlt für installierte Apps den Systembrowser, PKCE sowie Access-/Refresh-Tokens; installierte Apps können kein Client-Secret zuverlässig geheim halten.[13]

Der Desktop-Google-Picker arbeitet im Systembrowser und erlaubt für diesen Flow den `drive.file`-Scope.[14]

### Empfohlener Default für dieses Produkt

Da der Nutzer den Button ausdrücklich mit „Share“ bezeichnet und einen direkt weitergebbaren Link erwartet:

```text
Anyone with the link can view
```

als bewusst bestätigte einmalige Setup-Option. Die UI muss klar erklären, dass jede Person mit dem Link die Datei ansehen kann.

### Upload

- Bilder unter 5 MB: Multipart Upload.
- Videos und größere Bilder: Resumable Upload.
- Google beschreibt Simple Upload für kleine Medien bis 5 MB und bietet Multipart/Resumable für Metadaten beziehungsweise größere oder unterbrechbare Uploads.[10]
- Zielordner-ID als `parents` setzen.
- stabile `appProperties.fluidCaptureID` setzen.
- bei Retry zuerst nach dieser ID suchen, um Duplikate zu vermeiden.

### Permission und Read-back

1. Upload abschließen.
2. Bei Public-Link-Modus `permissions.create(type=anyone, role=reader)`.
3. `files.get(fields=id,name,size,mimeType,parents,webViewLink,permissions)`.
4. File-ID, Größe, Parent und Permission prüfen.
5. Erst danach `webViewLink` ins Clipboard kopieren.

Drive-Permissions unterscheiden unter anderem `anyone` sowie Rollen wie `reader`.[11]

### Ohne Drive-Setup

Klick auf `Share` zeigt innerhalb derselben Karte:

```text
Google Drive ist noch nicht verbunden
[Verbinden] [×]
```

Nach erfolgreichem Setup soll der ursprüngliche Share automatisch fortgesetzt werden.

---

## 7. Kompression

Das lokale Original in `~/Documents/Screens` bleibt immer unverändert. Nur eine temporäre Cloud-Ableitung wird komprimiert.

### Bilder

MVP-Algorithmus:

1. Wenn Datei bereits ≤ 500 KB ist: Original direkt uploaden.
2. Sonst lange Kante auf maximal 1920 px reduzieren.
3. Screenshot ohne Alpha: JPEG Quality 0,72.
4. Bild mit echter Transparenz: PNG zunächst behalten; nur downscalen.
5. Wenn Output > 750 KB: Quality 0,62.
6. Wenn Output > 750 KB: lange Kante auf 1600 px.
7. Wenn komprimierte Datei größer als Original: Original verwenden.

Warum kein striktes 500-KB-Limit: UI-Screenshots mit kleiner Schrift dürfen nicht bis zur Unlesbarkeit komprimiert werden. 500 KB ist ein Ziel, 750 KB eine weiche Obergrenze.

### Videos

MVP-Default:

```text
1280×720 max
30 fps max
H.264
2,5 Mbit/s Video
128 kbit/s AAC Audio
MP4
Optimize for network use
```

Rechnerischer Zielwert: ungefähr 19,71 MB pro Minute ohne Container-Overhead.

Optionales Setting:

- `Small`: 480p, ca. 8,46 MB/min
- `Balanced`: 720p, ca. 19,71 MB/min

Kein 1080p-Preset im ersten MVP-Menü.

### Temporäre Dateien

```text
~/Library/Application Support/fluid-push-to-talk/capture-share/staging/<asset-id>/
```

- Verzeichnis 0700.
- Dateien 0600.
- nach erfolgreichem Upload + Read-back löschen.
- bei Fehler für Retry behalten.
- nach sieben Tagen ohne offenen Retry automatisch entfernen.

---

## 8. Minimale Codearchitektur

### Bestehende Dateien ändern

- Modify: `app/Sources/AppRuntime.swift`
  - Watcher und minimale AppKit-Shell nach Single-Instance-Setup starten.
  - bestehende Voice-State-Machine nicht ändern.
- Modify: `app/Sources/Config/AppConfig.swift`
  - `captureShare`-Config rückwärtskompatibel ergänzen.
- Modify: `app/Sources/CLI/Options.swift`
  - `share-file PATH` ergänzen.
- Modify: `app/Sources/CLI/ConfigWizard.swift`
  - Watch-Folder, Drive-Verbindung und Zielordner konfigurieren/prüfen.
- Modify: `config/config.json`
  - keine persönlichen Pfade oder Folder-IDs committen.
- Modify: `README.md`, `appBehavior.md`, `AGENTS.md`
  - Watcher-, Upload-, Token- und Original-Retention-Vertrag dokumentieren.
- Modify: `install.sh`, `github-install.sh`
  - Finder Quick Action installieren/aktualisieren.

### Neue Dateien

```text
app/Sources/CaptureShare/ShareableAsset.swift
app/Sources/CaptureShare/AppleCaptureFolderResolver.swift
app/Sources/CaptureShare/AppleCaptureFolderWatcher.swift
app/Sources/CaptureShare/ShareableFileClassifier.swift
app/Sources/CaptureShare/ShareHistoryStore.swift
app/Sources/CaptureShare/ShareCoordinator.swift
app/Sources/CaptureShare/ImageCompressor.swift
app/Sources/CaptureShare/VideoTranscoder.swift
app/Sources/CaptureShare/GoogleDriveOAuthClient.swift
app/Sources/CaptureShare/GoogleDrivePickerClient.swift
app/Sources/CaptureShare/GoogleDriveUploader.swift
app/Sources/CaptureShare/GoogleDriveCredentialStore.swift
app/Sources/CaptureShare/ShareCardPanelController.swift
app/Sources/CaptureShare/ShareCardView.swift
app/Sources/CaptureShare/QuickLookPresenter.swift
app/Sources/CaptureShare/ClipboardWriter.swift
app/Resources/FinderQuickActions/Share with Fluid.workflow/...
app/Tests/AppleCaptureFolderResolverTests.swift
app/Tests/AppleCaptureFolderWatcherTests.swift
app/Tests/ShareableFileClassifierTests.swift
app/Tests/ShareHistoryStoreTests.swift
app/Tests/ShareCoordinatorTests.swift
app/Tests/ImageCompressorTests.swift
app/Tests/VideoTranscoderTests.swift
app/Tests/GoogleDriveOAuthClientTests.swift
app/Tests/GoogleDriveUploaderTests.swift
app/Tests/ShareCardStateTests.swift
```

### Config

```swift
struct CaptureShareConfig: Codable {
    var enabled = true
    var watchAppleScreenshotLocation = true
    var overrideWatchFolder = ""
    var promptDurationSeconds = 10
    var imageDriveFolderID = ""
    var imageDriveFolderName = ""
    var videoDriveFolderID = ""
    var videoDriveFolderName = ""
    var shareVisibility = DriveShareVisibility.anyoneWithLinkReader
    var videoPreset = VideoCloudPreset.balanced720p
}
```

Persönliche Folder-IDs gehören nur in die installierte Config, nie ins Repository.

---

## 9. Bite-Sized Implementierungsplan

### Task 1: Capture-Share-Config

**Objective:** Rückwärtskompatible Settings ohne Verhaltensänderung einführen.

**Files:**

- Modify: `app/Sources/Config/AppConfig.swift`
- Modify: `config/config.json`
- Test: `app/Tests/AppConfigCaptureShareTests.swift`

**Steps:**

1. Failing Decode-Tests für fehlende und vollständige `capture_share`-Config schreiben.
2. Tests ausführen und Failure bestätigen.
3. Enums und `CaptureShareConfig` implementieren.
4. Defaults konservativ laden.
5. Tests ausführen.
6. Commit: `feat: add capture share configuration`.

### Task 2: Apple-Screenshot-Ordner auflösen

**Objective:** `~/Documents/Screens` automatisch erkennen, aber nicht hart codieren.

**Files:**

- Create: `AppleCaptureFolderResolver.swift`
- Test: `AppleCaptureFolderResolverTests.swift`

**Steps:**

1. Command-Runner injizierbar machen.
2. Tests für `~/Documents/Screens`, fehlenden Default und Override schreiben.
3. Resolver implementieren.
4. Pfad expandieren, normalisieren und Verzeichnis prüfen.
5. Tests ausführen.
6. Commit: `feat: resolve Apple capture folder`.

### Task 3: File-Klassifikation und Stabilität

**Objective:** Nur fertige Bilder/Videos akzeptieren.

**Files:**

- Create: `ShareableAsset.swift`
- Create: `ShareableFileClassifier.swift`
- Test: `ShareableFileClassifierTests.swift`

**Steps:**

1. Fixtures für PNG/JPEG/HEIC/MOV/MP4/TXT/partial file erstellen.
2. Tests für UTI, xattr und stabile Größe schreiben.
3. Stabilitäts-Polling über injizierbare Clock/FileSystem implementieren.
4. Dedupe-Key erzeugen.
5. Tests ausführen.
6. Commit: `feat: classify completed Apple captures`.

### Task 4: FSEvents Watcher

**Objective:** Nur neue Files nach Start liefern.

**Files:**

- Create: `AppleCaptureFolderWatcher.swift`
- Test: `AppleCaptureFolderWatcherTests.swift`

**Steps:**

1. Test für Baseline schreiben.
2. Test für neue Datei genau einmal schreiben.
3. Test für Burst-Events/Dedupe schreiben.
4. FSEventStream-Adapter implementieren.
5. Sleep/Wake-Restart und Folder Change behandeln.
6. Tests ausführen.
7. Commit: `feat: watch Apple screenshot folder`.

### Task 5: Zehn-Sekunden-Karte

**Objective:** Minimalistische nicht-fokussierende Share-Entscheidung zeigen.

**Files:**

- Create: `ShareCardPanelController.swift`
- Create: `ShareCardView.swift`
- Create: `QuickLookPresenter.swift`
- Test: `ShareCardStateTests.swift`

**Steps:**

1. Pure State-Machine-Tests für Countdown, Share, Dismiss, Success und Error.
2. State Model implementieren.
3. NSPanel oben rechts implementieren.
4. Thumbnail, `Share`, `×` und Progress-Linie hinzufügen.
5. Quick-Look-Klick ergänzen.
6. Manuell prüfen, dass kein Fokus gestohlen wird.
7. Commit: `feat: show capture share prompt`.

### Task 6: Bildkompression

**Objective:** Große Screenshots als kleine Cloud-Ableitung erzeugen.

**Files:**

- Create: `ImageCompressor.swift`
- Test: `ImageCompressorTests.swift`

**Steps:**

1. Golden Fixtures und Byte-/Dimensionstests.
2. Alpha-Erkennung.
3. Downscale und JPEG-Qualitätsstufen.
4. „Original ist kleiner“-Fallback.
5. Visuelle Fixture-Prüfung.
6. Commit: `feat: compress shared screenshots`.

### Task 7: Video-Transcoding

**Objective:** Apple-MOVs in 480p/720p-MP4-Ableitungen umwandeln.

**Files:**

- Create: `VideoTranscoder.swift`
- Test: `VideoTranscoderTests.swift`

**Steps:**

1. 5–10-Sekunden-Testvideo erzeugen.
2. Tests für Auflösung, FPS, Codec, Audio und Cancellation.
3. AVAssetReader/Writer-Transcoder implementieren.
4. `.partial` + atomic rename.
5. Abspielbarkeit mit `ffprobe`/AVAsset prüfen.
6. Commit: `feat: transcode shared recordings`.

### Task 8: Google OAuth und Folder Picker

**Objective:** Drive sicher verbinden und zwei Zielordner wählen.

**Files:**

- Create: `GoogleDriveOAuthClient.swift`
- Create: `GoogleDrivePickerClient.swift`
- Create: `GoogleDriveCredentialStore.swift`
- Tests: passende Testfiles

**Steps:**

1. PKCE/State-Tests.
2. Keychain-Abstraktion.
3. Systembrowser-Callback.
4. `drive.file`-Picker.
5. Bild-/Videofolder persistieren.
6. Disconnect/Reauth.
7. Commit: `feat: connect Google Drive for capture sharing`.

### Task 9: Upload, Permission und Read-back

**Objective:** Erst einen verifizierten Link als Erfolg melden.

**Files:**

- Create: `GoogleDriveUploader.swift`
- Create: `ShareCoordinator.swift`
- Tests: `GoogleDriveUploaderTests.swift`, `ShareCoordinatorTests.swift`

**Steps:**

1. URLProtocol-Fixtures für Multipart, Resumable, 401, 403, 429 und 5xx.
2. Multipart Upload.
3. Resumable Upload + Progress/Retry/Cancel.
4. Anyone-reader Permission.
5. Files Read-back.
6. Link in Clipboard.
7. Idempotenz über `fluidCaptureID`.
8. Commit: `feat: upload captures and copy Drive links`.

### Task 10: Finder Quick Action

**Objective:** Rechtsklick-Dateien über `Quick Actions > Share with Fluid` teilen.

**Files:**

- Modify: `app/Sources/CLI/Options.swift`
- Create: Workflow-Resource
- Modify: Installer
- Test: CLI parsing + installer idempotency

**Steps:**

1. `share-file PATH` Parse-Tests.
2. Command vor normalem Daemon-Single-Instance-Start routen.
3. Mehrfachauswahl ablehnen oder nacheinander verarbeiten; MVP bevorzugt genau eine Datei.
4. Quick Action Workflow erzeugen.
5. atomar nach `~/Library/Services/Share with Fluid.workflow` installieren.
6. Installer-Re-run ohne Duplikat testen.
7. Finder-Kontextmenü manuell prüfen.
8. Commit: `feat: add Finder Share with Fluid action`.

### Task 11: Runtime-Integration und Regression

**Objective:** Watcher starten, ohne Voice-Flows zu verändern.

**Files:**

- Modify: `AppRuntime.swift`
- Modify: Docs und Installer

**Steps:**

1. Watcher nach Single-Instance-Lock und Config-Load starten.
2. UI auf MainActor, I/O/Compression/Network außerhalb Main Thread.
3. vorhandene Voice-Tests ausführen.
4. echter Apple-Screenshot-End-to-End.
5. echtes Screen Recording-End-to-End.
6. Finder Quick Action End-to-End.
7. Commit: `feat: integrate Apple capture sharing`.

---

## 10. Verifikation

### Automatisiert

```bash
cd /Users/sebastianmertens/Documents/GitHub/wispr-alternatve-local-llm/app
swift build
swift test
cd ..
python3 tests/run_all.py --skip-llm
git diff --check
```

### Manuelle MVP-Akzeptanz

#### Screenshot Watcher

1. `Shift-Command-4`.
2. Bereich aufnehmen.
3. File erscheint in `~/Documents/Screens`.
4. Fluid-Karte erscheint genau einmal oben rechts.
5. Nach zehn Sekunden ohne Aktion verschwindet sie.
6. File bleibt unverändert vorhanden.

#### Screenshot Share

1. neuen Screenshot erzeugen.
2. `Share` drücken.
3. Progress erscheint.
4. Drive-Link wird erst nach Upload, Permission und Read-back kopiert.
5. Link in privatem Browserfenster öffnen.
6. Bild ist lesbar und im konfigurierten Foto-Drive-Folder.

#### Video Share

1. `Shift-Command-5` und Apple Screen Recording starten.
2. 30 Sekunden aufnehmen und stoppen.
3. Karte erst nach fertigem File zeigen.
4. `Share` drücken.
5. MP4-Derivat ist maximal 720p und abspielbar.
6. Drive-Link funktioniert ohne Account, wenn `Anyone with link` gewählt wurde.
7. lokales MOV bleibt unverändert.

#### Finder Quick Action

1. vorhandenes Bild im Finder rechtsklicken.
2. `Quick Actions > Share with Fluid`.
3. Upload läuft über dieselbe Pipeline.
4. Link wird kopiert.
5. Unsupported TXT-Datei bietet die Action nicht an oder liefert eine klare Meldung.

#### Regression

- Command+Option local dictation
- zweistufiger Provider-Command
- Control+Option Dump
- Control+Option Hermes
- `P`-Screenshot 0/1/5/6
- App Startup und Single Instance

---

## 11. Explizit aus dem MVP entfernt

Diese Punkte aus der ersten Analyse werden nicht gebaut:

- eigene Screenshot-Aufnahme
- eigener Screen-Recorder
- eigene Aufnahme-Hotkeys
- Screenshot-/Video-Auswahl-UI
- lokaler Zielordner pro Medientyp; Apple speichert bereits lokal
- `localOnly/cloudOnly/localAndCloud`-Entscheidung je Aufnahme
- Capture History UI
- Annotation Editor
- Video Editor
- Webcam, Cursor Zoom, Transkription
- eigenes Backend oder eigene Viewer-Webseite
- Finder Sync Extension
- native Share Extension im ersten Release

Damit reduziert sich das Produkt auf einen klaren Job:

> **Apple nimmt auf. Fluid macht daraus auf Wunsch einen kleinen, teilbaren Google-Drive-Link.**

---

## 12. Spätere Erweiterungen, nur wenn das MVP genutzt wird

1. echte Share Extension unter Finders `Share…`.[20]
2. zuletzt geteilten Link bei erneutem Rechtsklick sofort kopieren.
3. kleine History der letzten zehn Links.
4. Drag-and-drop auf das Fluid-Menüleistenicon.
5. optionaler Auto-Share-Modus für einen dedizierten Unterordner.
6. eigene Share-Seite statt Google-Drive-Viewer.
7. Annotation/Video-Trim erst ganz am Ende.

---

## Sources

[10] https://developers.google.com/drive/api/guides/manage-uploads
[11] https://developers.google.com/drive/api/guides/manage-sharing
[13] https://developers.google.com/identity/protocols/oauth2/native-app
[14] https://developers.google.com/drive/picker/guides/overview
[16] https://support.apple.com/en-us/102646
[17] https://developer.apple.com/documentation/coreservices/file_system_events
[19] https://support.apple.com/guide/automator/use-a-quick-action-workflow-aut73234890a/mac
[20] https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html
[21] https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html
