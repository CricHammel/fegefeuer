# fegefeuer

Speicherplatz auf einem Mac zurückgewinnen, ohne beim Löschen zu raten.

Das Werkzeug sucht nach Dateien, die vermutlich weg können, legt sie dir zur
Entscheidung vor und **verschiebt sie dann ins Fegefeuer statt sie zu löschen**.
Dort harren sie aus, bis feststeht, ob sie gebraucht werden: `restore` erlöst
sie, `purge` spricht das endgültige Urteil. Und weil im Fegefeuer das *Fegen*
steckt, ist der Name für ein Aufräumwerkzeug nur halb geliehen.

Es ist absichtlich kein Cleaner mit Knopf. Die Erfahrung, aus der es entstand:
Deinstallations-Reste in `~/Library` sahen nach viel aus — 284 Ordner — brachten
aber nur 0,54 GB. Der Platz lag in wenigen großen Klumpen, die kein Cleaner
gefunden hatte: ein verwaister iCloud-Klon von 4,9 GB, 4,7 GB Aerial-Videos,
drei Generationen Playwright-Browser. Deshalb zeigt das Skript Größen und
Gründe und lässt dich entscheiden.

## Voraussetzungen

macOS und die mitgelieferte Bash 3.2 — mehr nicht. Alle benutzten Werkzeuge
(`awk`, `mdfind`, `shasum`, `stat`, `rsync` …) gehören zum System. Homebrew
wird nur für den Unterbefehl `brew` gebraucht und sonst nicht vermisst.

Beim Start prüft das Skript, ob es auf macOS läuft und ob alles Nötige da ist.

## Ablauf

```bash
./fegefeuer.sh scan       # Platte durchsuchen, Kandidaten sammeln
./fegefeuer.sh gruppen    # Überblick: was steht an?
./fegefeuer.sh review     # entscheiden
./fegefeuer.sh apply      # in die Quarantäne verschieben
                           # ... ein paar Tage normal arbeiten ...
./fegefeuer.sh pruefen    # was ist von selbst zurückgekommen?
./fegefeuer.sh purge      # endgültig löschen
```

### Was gesucht wird

| Kategorie | Was das ist |
|---|---|
| `app-rest` | Ordner in `~/Library`, zu denen keine installierte App mehr existiert |
| `cache` | Caches, die sich selbst neu aufbauen |
| `toolchain` | alte Node-Versionen, veraltete Playwright-Browser |
| `gross` | Einzeldateien über 200 MB |
| `dublette` | inhaltsgleiche Dateien (SHA-1 über alles ab 1 MB) |

Ob eine App noch installiert ist, entscheidet nicht der Ordnername, sondern
eine Spotlight-Abfrage nach der Bundle-ID (`mdfind kMDItemCFBundleIdentifier`).
Eine frühere Namensheuristik hielt VLC und iTerm für deinstalliert.

### Durchsicht

Ein Programm verstreut seine Reste über viele Ordner — WhatsApp über 20,
BlockerX über 26. `review` fasst sie zusammen, sodass eine Frage genügt:

```
[1/80] khanov · blockerx — 24 Einträge, 756 KB
     268 KB  Containers/com.khanov.BlockerX.SafariExtension      2024-06-13
     128 KB  Containers/com.khanov.BlockerX.MacWidget            2024-06-13
  … und 18 weitere
  j=alle weg  n=alle behalten  e=einzeln  o=Finder  s=später  q=Ende
```

Der Gruppenname nennt Hersteller **und** Produkt, weil die Bundle-ID oft nur
den Entwickler verrät (`com.khanov.BlockerX`). Hersteller mit mehreren
Produkten werden getrennt gehalten — `microsoft · powerpoint`,
`microsoft · sharepoint` und `microsoft · teams` sind drei Entscheidungen,
keine einzige.

`q` unterbricht jederzeit, der Stand bleibt erhalten. Bereits entschiedene
Einträge werden nie erneut gefragt, und eine Gruppenantwort überschreibt sie
nicht.

Für ganze Kategorien geht es auch ohne Einzelfragen:

```bash
./fegefeuer.sh zeigen cache      # erst ansehen
./fegefeuer.sh mark cache go     # dann pauschal freigeben
```

## Das Sicherheitsnetz

**Nichts wird beim Aufräumen gelöscht.** `apply` verschiebt nach
`~/.fegefeuer/<datum>/` und legt ein Manifest an, das jeden Ursprungsort
festhält. `restore` bringt alles dorthin zurück.

**Auf einen belegten Pfad wird nie verschoben.** Wenn ein Cache sich
inzwischen selbst neu aufgebaut hat, würde ein naives `mv` bei Ordnern
verschachteln (`ms-playwright/ms-playwright`) und bei Dateien die frische
Fassung überschreiben — beides ohne Fehlermeldung. `restore` überspringt
solche Pfade und bietet zwei bewusste Alternativen:

```bash
./fegefeuer.sh restore <stapel>                    # belegte Pfade in Ruhe lassen
./fegefeuer.sh restore <stapel> --zusammenfuehren  # Ordner nur ergänzen
./fegefeuer.sh restore <stapel> --ersetzen         # alte Fassung zurück,
                                                    # aktuelle wird beiseitegelegt
```

Auch `--ersetzen` löscht nichts: die verdrängte Fassung landet in
`~/.fegefeuer/_verdraengt-<datum>/`.

**Ein freigegebener Ordner nimmt nichts Behaltenes mit.** Wenn du
`~/Library/Caches/ms-playwright` freigibst, darin aber `chromium-1234`
ausdrücklich behalten wolltest, würde `mv` den Unterordner kommentarlos
mitverschieben. `apply` erkennt das, überspringt den Elternordner und sagt
dir, welcher Unterordner im Weg steht.

**`pruefen` macht aus dem Warten eine Beobachtung.** Es teilt die Quarantäne
in das, was am Originalort wieder aufgetaucht ist — das System hat den Ersatz
also selbst geliefert, die alte Kopie ist entbehrlich — und das, was
verschwunden geblieben ist und dir nicht gefehlt hat.

```bash
./fegefeuer.sh purge --wieder-da   # nur das nachweislich Entbehrliche
./fegefeuer.sh purge               # ganze Stapel ab 7 Tagen
```

Beide verlangen, dass du `LOESCHEN` tippst.

### Die Schutzliste

Diese Pfade lehnt `apply` ab, selbst wenn sie als Kandidat markiert sind:

- `~/Library/Keychains` — Passwörter
- `~/Library/Mail`, `~/Library/Messages`, `~/Library/Containers/com.apple.mail*`
- `~/Library/Mobile Documents` — iCloud Drive
- `~/Pictures/*.photoslibrary`
- `~/Library/Application Support/AddressBook` — Kontakte
- `~/Library/Group Containers/group.com.apple.notes*` — Notizen
- `~/Library/Group Containers/UBF8T346G9.*` und alles mit `OneDrive` im Pfad
- `~/Library/Metadata` — Spotlight-Index
- `~/Library/Preferences/ByHost` — rechnergebundene Einstellungen
- `~/.ssh`, `~/.gnupg`
- `~/*.7z`
- alles außerhalb von `~`

Die zwei wichtigsten Einträge kamen aus Beinahe-Unfällen. Der Dublettensucher
meldete 2,44 GB doppelte Dateien in einem OneDrive-Ordner — lokal gelöscht
hätte das die Dateien serverseitig für alle Kollegen entfernt. Und
`~/Library/Metadata` erzeugt massenhaft Schein-Dubletten, weil Spotlight
identische Journale in parallelen Pipelines führt. Der Dublettensucher lässt
`~/Library` inzwischen komplett aus.

Die Liste steht in der Funktion `ist_geschuetzt` und will angepasst werden,
wenn dein Rechner andere heikle Orte hat.

## Homebrew

```bash
brew cleanup                 # alte Versionen, risikolos
./fegefeuer.sh brew
```

Homebrew wird nicht in die Quarantäne verschoben — dort ist `brew uninstall`
das richtige Werkzeug, und `brew install` macht es rückgängig. Der Unterbefehl
zeigt, was du selbst installiert hast (`brew leaves`), und schreibt eine
Vorschlagsliste `brew-vorschlag.sh`. Zeilen löschen, die bleiben sollen, dann
ausführen.

Die lohnendsten Fäden sind die, an denen ein kleines Paket ein großes mitzieht:
`powershell` allein hält 669 MB `dotnet` fest.

## Videos neu kodieren

> Auf dem Branch `video-neukodierung`.

```bash
./fegefeuer.sh video scan [verzeichnis]   # vermessen, nichts anfassen
./fegefeuer.sh video review               # auswählen
./fegefeuer.sh video run --profil sparsam # kodieren, prüfen, Original sichern
```

Videos sind ein Sonderfall und deshalb ein eigener Unterbefehl: Neukodieren
*verschiebt* nichts, es **erzeugt eine neue, verlustbehaftete Datei**. Ein `go`
in `kandidaten.tsv` bedeutet immer nur „verschieben"; diese Bedeutung soll es
behalten.

Entschieden wird über **bpp** — Datenmenge je Bildpunkt und Bild, also
Bitrate geteilt durch Auflösung mal Bildrate. Die Kennzahl ist über
Auflösungen hinweg vergleichbar: ein 720p-Video mit 10 Mbit/s ist
verschwenderischer als ein 4K-Video mit 83, weil es viel weniger Bildpunkte zu
beschreiben hat. Ab 0,10 bpp lohnt sich ein Eingriff, bei bereits sparsamen
Codecs (HEVC, AV1, VP9) erst ab 0,15.

Drei Fälle bleiben bewusst außen vor: Dateien unter der Schwelle, Dateien mit
weniger als 50 MB zu erwartendem Gewinn, und Zeitraffer unter 5 fps — dort
sagt bpp nichts Sinnvolles. Alle drei werden gezählt und benannt, nicht
stillschweigend übergangen.

Am Ende stehen zwei Profile mit gemessenen Zahlen, damit die Wahl zwischen
Tempo und Ersparnis auf Daten beruht und nicht auf einer nackten `-crf`-Zahl:

| Profil | Encoder | Ergebnis | Tempo |
|---|---|---|---|
| `schnell` | VideoToolbox q60 | ~32 % der Größe | 0,83× Echtzeit bei 4K60 |
| `sparsam` | x265 `veryfast` crf24 | ~23 % der Größe | 0,18× Echtzeit bei 4K60 |

Bei nahezu gleicher Qualität — SSIM 0,9855 gegen 0,9839, im direkten
Bildvergleich nicht unterscheidbar.

### Die Prüfung

Kodiert wird in eine Nebendatei. Erst wenn sie **alle** Prüfungen besteht,
wandert das Original ins Fegefeuer und die neue Fassung nimmt seinen Platz
ein. Fällt eine durch, wird die neue Datei verworfen und das Original bleibt
unberührt.

| Prüfung | fängt ab |
|---|---|
| Laufzeit auf 0,5 s genau | abgeschnittene Aufnahmen |
| Tonspur vorhanden | stumme Filme, die erst Monate später auffallen |
| vollständige SSIM-Messung | Abbrüche, Beschädigungen, grobe Fehlkodierungen |
| kleiner als vorher | Kodierungen, die nichts bringen |

Die SSIM-Messung läuft über die **ganze** Datei, nicht über Stichproben. Ein
erster Entwurf verglich drei Ausschnitte — an derselben Stelle ergab das
0,838 statt 0,948, weil `-ss` vor `-i` bei unterschiedlichen Keyframe-Rastern
nicht dasselbe Bild trifft. Gute Kodierungen wären so verworfen worden. Der
vollständige Durchlauf dekodiert beide Dateien ohnehin und ersetzt damit
zugleich die Prüflesung; er kostet rund die Hälfte der Kodierzeit beim
schnellen Profil und ein Zehntel beim sparsamen.

Das Original landet mit einem Vermerk im Fegefeuer, der es von verschobenen
Dateien unterscheidet. Das ist wichtig: Am Originalort liegt danach die neue
Fassung, und ohne diesen Vermerk würde `pruefen` melden, die Datei sei „von
selbst zurückgekehrt" und die Quarantänekopie entbehrlich — worauf
`purge --wieder-da` ein unersetzliches Kameraoriginal gelöscht hätte.

**Dieser Unterbefehl braucht `ffmpeg`** (`brew install ffmpeg`). Er ist der
einzige Teil, der über die Bordmittel von macOS hinausgeht, und prüft das beim
Start.

## Dateien

| Datei | |
|---|---|
| `fegefeuer.sh` | das Skript |
| `gruppen.awk` | Gruppierung der Library-Reste nach Programm |
| `video-kandidaten.tsv` | vermessene Videos *(nicht im Repo)* |
| `kandidaten.tsv` | deine Kandidaten und Entscheidungen *(nicht im Repo)* |
| `bericht.md` | Übersicht nach jedem `scan` *(nicht im Repo)* |
| `.arbeit/` | Hashes und Zwischenstände *(nicht im Repo)* |

Alles, was Pfade dieses Rechners enthält, steht in `.gitignore`. Im Repo
liegen nur das Skript und seine Gruppierungsregeln.

## Was es bewusst nicht tut

- Es löscht nichts ohne Wartezeit und Bestätigung.
- Es fasst nichts außerhalb des Home-Verzeichnisses an.
- Es entscheidet nicht, welche von zwei inhaltsgleichen Dateien die richtige
  ist — das weißt nur du.
- Es räumt keine Cloud-Ordner auf, deren Inhalt anderen gehört.
