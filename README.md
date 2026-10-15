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

## Was es bewusst nicht tut

- Es löscht nichts ohne Wartezeit und Bestätigung.
- Es fasst nichts außerhalb des Home-Verzeichnisses an.
- Es entscheidet nicht, welche von zwei inhaltsgleichen Dateien die richtige
  ist — das weißt nur du.
- Es räumt keine Cloud-Ordner auf. Was dort verschwindet, verschwindet auf
  dem Server, bei geteilten Ordnern für alle. Die Scans gehen gar nicht erst
  hinein: Schon das Hashen einer nur online liegenden Datei lädt sie herunter.

## Voraussetzungen

macOS und die mitgelieferte Bash 3.2 — mehr nicht. Alle benutzten Werkzeuge
(`awk`, `mdfind`, `shasum`, `stat`, `rsync` …) gehören zum System. Homebrew
braucht nur der Unterbefehl `brew`, `ffmpeg` nur der Unterbefehl `video`.
Beim Start prüft das Skript, ob es auf macOS läuft und ob alles Nötige da ist.

`fegefeuer.sh` findet seine Module über das eigene Verzeichnis. Ein Aufruf
über einen Symlink, etwa aus `~/bin`, funktioniert deshalb nicht; dafür einen
Alias oder eine kleine Weiterleitung anlegen.

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

**Platz wird erst mit `purge` frei.** `apply` verschiebt nur, die Dateien
liegen danach weiter auf derselben Platte. Auf einer fast vollen Platte lohnt
es sich deshalb, mit `purge --wieder-da` früh zu löschen, was sich
nachweislich selbst ersetzt hat (siehe [Das Sicherheitsnetz](#das-sicherheitsnetz)).

| Befehl | |
|---|---|
| `scan [--dubletten-ab 10M]` | Platte durchsuchen, schreibt `kandidaten.tsv` und `bericht.md` |
| `gruppen [kategorie]` | offene Gruppen, größte zuerst |
| `review [kategorie]` | Kandidaten durchgehen und entscheiden |
| `zeigen [kategorie]` | alle Einträge mit ihrer Entscheidung |
| `mark <kategorie> <go\|keep\|neu> [--alle]` | eine ganze Kategorie auf einmal entscheiden |
| `apply` | Freigegebenes ins Fegefeuer verschieben |
| `list` | Stapel im Fegefeuer |
| `pruefen` | was am Originalort wieder aufgetaucht ist |
| `restore <stapel> [--zusammenfuehren\|--ersetzen]` | einen Stapel zurückholen |
| `purge [tage]` | Stapel endgültig löschen, Standard: älter als 7 Tage |
| `purge --wieder-da [stapel]` | nur nachgewachsene Caches und Toolchains löschen |
| `brew` | Homebrew durchleuchten, Deinstallations-Vorschlag schreiben |
| `video scan\|review\|run` | Videos vermessen, auswählen, neu kodieren |

### Was gesucht wird

| Kategorie | Was das ist |
|---|---|
| `app-rest` | Ordner in `~/Library`, zu denen keine installierte App mehr existiert |
| `cache` | Caches, die sich selbst neu aufbauen |
| `toolchain` | alte Node-Versionen (außer der neuesten und der nvm-Standardversion), veraltete Playwright-Browser |
| `gross` | Einzeldateien und [Pakete](#pakete) über 200 MB |
| `dublette` | inhaltsgleiche Dateien (SHA-1, Mindestgröße einstellbar) |

Ob eine App noch installiert ist, entscheidet nicht der Ordnername, sondern
eine Spotlight-Abfrage nach der Bundle-ID (`mdfind kMDItemCFBundleIdentifier`).
Der Name allein täuscht: Nach ihm sähen etwa VLC und iTerm deinstalliert aus.

Das setzt voraus, dass Spotlight funktioniert. Ist der Index aus oder
kaputt, verneint jede Abfrage — und jeder Ordner in `~/Library` sähe
verwaist aus. Deshalb fragt `scan` vorher nach Apps, die jedes macOS
mitbringt (Finder, Safari, TextEdit). Findet Spotlight keine davon, wird
der Schritt übersprungen und `mdutil -s /` zum Nachsehen vorgeschlagen; die
übrigen Schritte laufen weiter.

Geprüft werden nur **Ordner**, deren Name eine Bundle-ID ist. App-Daten liegen
in Ordnern; eine Datei mit Punkt im Namen ist fast immer ein Dateiname wie
`fsck_hfs.log`, keine Bundle-ID. Ausgenommen sind `.savedState` und
`.binarycookies` — die zwei Formen, die als Datei auftreten und sehr wohl eine
Bundle-ID tragen. Ordner mit schlichtem Namen (`Application Support/Slack`)
prüft `scan` nicht.

Bei Node bleibt neben der neuesten Version auch die, die nvm als Standard
eingestellt hat (`~/.nvm/alias/default`) — mit ihr läuft jede neue Shell,
auch wenn sie nicht die neueste ist. Aliase wie `20`, `node` oder `lts/*`
werden so aufgelöst, wie nvm es tut. Passt der Standard zu keiner
installierten Version, schlägt `scan` gar keine Node-Version vor.

Gehasht wird nur, was eine gleich große Partnerdatei hat — Dubletten sind
gleich groß. Das sind meist wenige Prozent der Dateien. Die Mindestgröße für
den Vergleich lässt sich setzen; unter einer gewissen Größe lohnt die Mühe
selten:

```bash
./fegefeuer.sh scan --dubletten-ab 10M
```

Ohne Angabe gilt 1 MB. Erlaubt sind `500k`, `10M`, `2G` oder eine nackte Zahl
als Bytes; Groß- und Kleinschreibung der Einheit ist egal.

### Dubletten: du wählst, welche bleibt

Bei inhaltsgleichen Dateien lautet die Frage nicht „weg oder nicht", sondern
„welche von diesen soll bleiben". Alle Kopien stehen nebeneinander:

```
[3/83] 3 gleiche Dateien · je 3 MB
  1  ~/Projekt/Datei.bin                    2024-03-01  ← älteste, Vorschlag
  2  ~/Projekt/Datei2.bin                   2025-10-01
  3  ~/Projekt/Kopie von Datei.bin          2026-01-01
  Welche soll bleiben? Die anderen wandern ins Fegefeuer.
  1-3=diese behalten  n=alle behalten  o=Finder  s=später  q=Ende
```

Vorgeschlagen wird die älteste — eine Kopie ist meist jünger als ihr Original.
Entscheiden musst du. Einen Griff, der alle löscht, gibt es hier nicht: Eine
Zahl behält genau diese Datei, `n` behält alle. Aus demselben Grund verweigert
`mark dublette go` den Dienst.

`apply` prüft das noch einmal über die ganze Liste. Eine Datei über 200 MB
steht oft zweimal darin, als Dublette und als `gross`, und `mark gross go`
würde sonst auch die behaltene Kopie losschicken. Deshalb gilt:

- Steht ein Pfad irgendwo auf „behalten“, bleibt er — egal, was eine andere
  Zeile zu ihm sagt.
- Bliebe von einer Gruppe keine Kopie übrig, wird keine davon angefasst, auch
  kein Ordner, der eine von ihnen enthält. Die Gruppe ist danach im `review`
  wieder offen.
- Beim erneuten Scan werden Entscheidungen je Kategorie und Pfad übernommen,
  nicht nur je Pfad. Sonst spränge die Antwort von der einen Zeile auf die
  andere.

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
keine einzige. Diese Benennung gilt nur für App-Reste. Alle anderen Gruppen
heißen nach ihrem Pfad (`~/.cache`), Dubletten nach Anzahl und Dateiname
(`2× Datei.bin`).

Die Tastenbelegung steht bei **jeder** Frage, nicht nur einmal im Kopf — wer
150 Dubletten durchgeht, soll nicht raten müssen.

`q` unterbricht jederzeit, der Stand bleibt erhalten. Strg-C ebenso: Was bis
dahin entschieden ist, wird gespeichert, bevor das Skript endet. Bereits
entschiedene Einträge werden nie erneut gefragt, und eine Gruppenantwort
überschreibt sie nicht.

### Wenn sich Kandidaten überlappen

Dieselben Bytes können mehrfach auffallen: `~/Library/Caches/Homebrew` landet
als Cache in der Liste, und die großen `.dmg`-Dateien darin noch einmal
einzeln als `gross`. In einem echten Lauf waren das 11 Einträge mit 3,16 GB,
die bereits im Elternordner steckten.

Damit geht fegefeuer so um:

- **Summen zählen jeden Platz einmal.** Was innerhalb eines anderen Kandidaten
  liegt, wird nicht addiert; der Bericht weist den Unterschied aus.
- **Beim Elternordner steht, was er mitnimmt** — „enthält 2 weitere Kandidaten
  (500 MB) — die wandern mit".
- **Gibst du den Elternordner frei, entfallen die Fragen danach.** Was darin
  liegt, wandert ohnehin mit und wird nicht noch einmal einzeln gefragt.
- **Umgekehrt geht auch:** Elternordner behalten, einzelne Dateien darin
  freigeben. Dann wird jede Datei gefragt und nur sie verschoben.
- **Behältst du etwas innerhalb eines freigegebenen Ordners**, verweigert
  `apply` den Elternordner und nennt den Grund — sonst nähme `mv` das
  Behaltene stillschweigend mit.

Für ganze Kategorien geht es auch ohne Einzelfragen:

```bash
./fegefeuer.sh zeigen cache      # erst ansehen
./fegefeuer.sh mark cache go     # dann pauschal freigeben
```

`mark` wirkt nur auf Einträge, die noch offen sind — was du schon einzeln
entschieden hast, bleibt, genau wie bei einer Gruppenantwort im `review`.
`--alle` überschreibt auch das, `mark cache neu` setzt die ganze Kategorie
zurück.

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

Auch `--ersetzen` löscht nichts: Die verdrängte Fassung landet in
`~/.fegefeuer/_verdraengt-<datum>/`. Und `--zusammenfuehren` holt nur zurück,
was am Ziel fehlt. Liegt dort von einer Datei schon eine eigene Fassung,
bleibt die alte im Stapel und im Manifest.

In der Gegenrichtung gilt dasselbe. `apply` arbeitet die Freigaben nach Pfad
ab: Ein Ordner wandert vor seinem Inhalt und nimmt ihn mit. Ist der Zielpfad
im Stapel trotzdem belegt, verweigert `apply` den Eintrag.

**Ein freigegebener Ordner nimmt nichts Behaltenes mit.** Wenn du
`~/Library/Caches/ms-playwright` freigibst, darin aber `chromium-1234`
ausdrücklich behalten wolltest, würde `mv` den Unterordner kommentarlos
mitverschieben. `apply` erkennt das, überspringt den Elternordner und sagt
dir, welcher Unterordner im Weg steht.

**`pruefen` macht aus dem Warten eine Beobachtung.** Es teilt die Quarantäne
in das, was am Originalort wieder aufgetaucht ist, und das, was verschwunden
geblieben ist und dir nicht gefehlt hat.

Was wieder aufgetaucht ist, bedeutet je nach Herkunft das Gegenteil. Ein
**Cache** oder eine **Toolchain**, die sich neu aufgebaut hat, ist entbehrlich —
das System hat den Ersatz selbst geliefert. Legt dagegen eine **App** ihren
Ordner neu an, wird sie offenbar doch benutzt, und die alten Daten im
Fegefeuer sind genau das, was ihr jetzt fehlt. `pruefen` führt diese Fälle
deshalb getrennt als „wieder angelegt“ und schlägt `restore --ersetzen` vor.

```bash
./fegefeuer.sh purge --wieder-da   # nur nachgewachsene Caches und Toolchains
./fegefeuer.sh purge               # ganze Stapel ab 7 Tagen
```

Dafür hält das Manifest jedes Stapels die Kategorie fest. Stapel ohne diese
Spalte stammen aus älteren Versionen; `pruefen` führt ihre Einträge eigens als
„Kategorie unbekannt“, und `--wieder-da` lässt sie aus — die Kategorie aus dem
Pfad zu raten ginge schief, weil App-Reste auch in `~/Library/Caches` liegen.

Wie alt ein Stapel ist, ergibt sich aus dem Zeitstempel in seinem Namen. Ihn
im Finder zu öffnen ändert daran nichts.

Beide verlangen, dass du `LOESCHEN` tippst. Liegen in den fälligen Stapeln
Originale neu kodierter Videos, nennt `purge` sie vorher eigens: An ihrem
Platz liegt nur noch die verlustbehaftete neue Fassung.

`purge` misst, was tatsächlich verschwunden ist, statt den Erfolg
vorauszusetzen. Bleibt etwas liegen, sagt es das und nennt den Grund — meist
Dateien, die ein Programm mit erhöhten Rechten angelegt hat und die nur mit
`sudo` zu entfernen sind. Tauchen während des Löschens neue Dateien auf (etwa
`.DS_Store`), räumt es sie weg und versucht es ein zweites Mal.

### Die Schutzliste

Diese Pfade lehnt `apply` ab, selbst wenn sie als Kandidat markiert sind:

- `~/Library/Keychains` — Passwörter
- `~/Library/Mail`, `~/Library/Messages`, `~/Library/Containers/com.apple.mail*`
- `~/Library/Application Support/AddressBook` — Kontakte
- `~/Library/Group Containers/group.com.apple.notes*` — Notizen
- Foto-Mediatheken (`*.photoslibrary`), wo immer sie liegen
- Cloud-Ordner, weil eine Löschung dort auf dem Server ankommt:
  `~/Library/Mobile Documents` (iCloud Drive), `~/Library/CloudStorage`
  (Dropbox, Google Drive, Box und andere File-Provider), die älteren Orte
  `~/Dropbox`, `~/Google Drive`, `~/Box`, `~/pCloud Drive`, außerdem
  `~/Library/Group Containers/UBF8T346G9.*` und alles mit `OneDrive` im Pfad
- `~/Library/Metadata` — der Spotlight-Index; er führt identische Journale in
  parallelen Pipelines und sähe voller Dubletten aus
- `~/Library/Preferences/ByHost` — rechnergebundene Einstellungen
- `~/.ssh`, `~/.gnupg`
- `~/*.7z`
- `~/.fegefeuer` und das Arbeitsverzeichnis `.arbeit` — sonst fände der
  Dublettensucher eine Datei im Fegefeuer als Kopie ihres Originals
- alles **innerhalb** eines Pakets (siehe unten) — das Paket selbst darf
  als Ganzes wandern
- alles außerhalb von `~`

Geschützte Pfade fallen aus, *bevor* Dubletten gruppiert werden. Bleibt von
einer Gruppe nur eine Datei übrig, ist sie keine Dublette mehr und taucht
nicht auf. Die Dublettensuche lässt `~/Library` ganz aus.

Die Liste steht in `lib/schutz.sh` (Funktion `ist_geschuetzt`) und will
angepasst werden, wenn dein Rechner andere heikle Orte hat.

### Pakete

Apps, virtuelle Maschinen und Projekte sind Ordner, die der Finder als eine
Datei zeigt: `.app`, `.pvm`, `.utm`, `.vmwarevm`, `.fcpbundle`, `.logicx`,
`.band`, `.imovielibrary`, `.musiclibrary`, `.sparsebundle`, `.xcarchive`.
Eine einzelne Datei daraus zu verschieben beschädigt das Paket — die
Festplatte einer VM als „große Datei“, eine Bibliothek, die zwei Apps gleich
mitbringen, als Dublette, ein Clip aus einem Final-Cut-Projekt als Video zum
Neukodieren. Keine der Suchen geht deshalb hinein. Ist ein Paket über 200 MB,
zeigt `scan` es als Ganzes unter `gross`; eine vergessene VM mit 60 GB soll
schließlich auffallen.

Wie Pakete behandelt werden zwei Arten von Ordnern, die der Finder nicht als
Paket zeigt: **Git-Repositories** (`.git` im Projekt wie ein nacktes
`projekt.git`) und **Geräte-Backups** unter
`~/Library/Application Support/MobileSync/Backup`. Eine einzelne Packdatei
aus `.git/objects/pack` macht den Verlauf unlesbar, eine einzelne der
Tausenden Hash-Dateien eines iPhone-Backups das ganze Backup unbrauchbar. Als
Ganzes ist ein altes iPhone-Backup dagegen oft der größte Brocken auf der
Platte.

Die Listen stehen in `lib/schutz.sh` (`PAKET_ENDUNGEN`, `PAKET_ORTE`).
Foto-Mediatheken sind auch Pakete, stehen aber ganz unter Schutz.

Aus demselben Grund lässt die Dublettensuche Python-Umgebungen aus (`venv`,
`.venv`, `site-packages`), wie auch `node_modules`. Große Dateien darin,
etwa Modelle, erscheinen weiter unter `gross`.

## Homebrew

```bash
brew cleanup                 # alte Versionen, risikolos
./fegefeuer.sh brew
```

Homebrew wird nicht in die Quarantäne verschoben — dort ist `brew uninstall`
das richtige Werkzeug, und `brew install` macht es rückgängig. Der Unterbefehl
zeigt, was du installiert hast, und schreibt eine Vorschlagsliste
`brew-vorschlag.sh`.

In der Liste steht jede Zeile auskommentiert. Was weg soll, schaltest du frei,
indem du das `#` am Zeilenanfang löschst — bei Formulas wie bei Programmen
gleich. Unverändert ausgeführt ändert die Datei nichts.

```bash
# brew uninstall powershell   # 744 MB (74 MB + 669 MB Abhaengigkeiten), installiert 2026-09-20
brew uninstall --cask arc     # 858 MB, zuletzt geoeffnet: unbekannt   ← freigeschaltet
```

### Formulas: nach dem, was wirklich frei wird

Gezeigt werden die Pakete, die du selbst installiert hast (`brew leaves`) —
und zwar mit dem Platz, den ihr Entfernen tatsächlich bringt: das Paket
selbst plus die Abhängigkeiten, die kein anderes Paket mehr braucht.

```
     744 MB  2026-09-20  powershell  davon 669 MB Abhängigkeiten
     371 MB  2026-08-26  openjdk@25
     208 MB  2026-09-04  freeciv     davon 123 MB Abhängigkeiten
```

Die eigene Größe allein täuscht: `powershell` belegt 74 MB und stünde damit
weit hinten, hält aber 669 MB `dotnet` fest. Abhängigkeiten, die sich zwei
Pakete teilen, zählen bei keinem von beiden — sie werden erst frei, wenn
beide gehen.

Am Ende der Liste steht `brew autoremove`; erst damit werden die
Abhängigkeiten tatsächlich entfernt. Weil es auch mitnimmt, was schon vorher
verwaist war, läuft es nur, wenn oben mindestens eine Zeile freigeschaltet
ist — die Datei prüft das an sich selbst.

### Programme (Casks): nach Größe und letzter Nutzung

Programme erscheinen nach Größe sortiert, mit dem Datum, an dem sie zuletzt
geöffnet wurden.

```
     2,2 GB  2026-09-28  docker-desktop
     885 MB  unbekannt   claude
          ?              nordvpn (ohne App — Größe unbekannt)
```

Das Datum stammt von Spotlight und ist nur in einer Richtung aussagekräftig.
Ein altes Datum ist ein brauchbares Signal; ab 90 Tagen wird es markiert.
„unbekannt“ heißt dagegen nicht unbenutzt — der Eintrag fehlt auch bei Apps,
die regelmäßig laufen. Betroffen sind vor allem solche, die sich selbst
aktualisieren; vermutlich geht er verloren, wenn sie ihr App-Bundle austauschen.

Programme, deren Eintrag im Caskroom unvollständig ist, erscheinen trotzdem
und sind markiert, weil `brew uninstall` an ihnen scheitern kann.

`brew uninstall --cask` entfernt nur die App, nicht ihre Daten in
`~/Library`. Die findet der nächste `scan` als App-Rest, und sie gehen den
üblichen Weg durch das Fegefeuer.

## Videos neu kodieren

```bash
./fegefeuer.sh video scan [verzeichnis]   # vermessen, nichts anfassen
./fegefeuer.sh video review               # auswählen
./fegefeuer.sh video run                  # kodieren, prüfen, Original sichern
```

Videos sind ein Sonderfall und deshalb ein eigener Unterbefehl: Neukodieren
*verschiebt* nichts, es **erzeugt eine neue, verlustbehaftete Datei**. Ein `go`
in `kandidaten.tsv` bedeutet immer nur „verschieben"; diese Bedeutung soll es
behalten.

**Dieser Unterbefehl braucht `ffmpeg` 7.1 oder neuer** (`brew install
ffmpeg`). Er ist der einzige Teil, der über die Bordmittel von macOS
hinausgeht, und prüft das beim Start.

### Was vorgeschlagen wird

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

ZIPs mit genau einer Videodatei werden zum Messen und Kodieren ausgepackt.
ZIPs mit mehr als einer Datei fasst `video` nicht an: Die neue Fassung
ersetzte sonst das ganze ZIP, und die übrigen Dateien lägen nur noch im
Fegefeuer. Ordner und die Beigaben des Finders (`__MACOSX`, `.DS_Store`)
zählen nicht.

### Profile

`video run` ohne `--profil` fragt nach und zeigt dabei die Zahlen für **deine**
gerade ausgewählten Dateien, nicht allgemeine Richtwerte:

```
Womit kodieren?  Zahlen für deine 17 ausgewählten Dateien:

  1) schnell   VideoToolbox q60       9,71 GB → 2,62 GB    7,09 GB gespart   ~17 min
     Hardware-Chip des Macs, mit Abstand am schnellsten
  …
  3) sparsam   x265 veryfast crf24    9,71 GB → 1,90 GB    7,81 GB gespart   ~76 min
     guter Mittelweg, überall abspielbar
  …
```

Für Skripte nimmt `--profil <name>` die Frage vorweg. Einen stillen
Standardwert gibt es bewusst nicht — wer nichts angibt und nichts eingeben
kann, bekommt einen Fehler statt einer stillschweigend getroffenen
Entscheidung.

Vier Profile, alle an derselben 4K60-Stelle auf einem M2 gemessen:

| Profil | Encoder | Ergebnis | Zeit | SSIM |
|---|---|---:|---:|---:|
| `schnell` | VideoToolbox q60 | 29 % | 1× | 0,986 |
| `av1` | SVT-AV1 crf32 | 27 % | 5× | **0,989** |
| `sparsam` | x265 `veryfast` crf24 | 20 % | 6× | 0,985 |
| `klein` | x265 `veryfast` crf28 | **13 %** | 5× | 0,979 |

Die Qualität liegt bei allen vier dicht beieinander; die Wahl ist keine
zwischen gut und schlecht, sondern zwischen Zeit und Platz.

`av1` ist der stärkste Kompromiss aus Qualität und Größe und dabei schneller
als x265 — der M2 dekodiert AV1 allerdings **nicht** in Hardware. Abspielen
kostet dadurch mehr Akku (2,8× statt 3,7× Echtzeit), und ältere Geräte spielen
es womöglich gar nicht ab. Die Auswahl weist darauf hin.

Vermessen und als Option verworfen:

- **10 Bit**: 2,2-fache Rechenzeit für 0,7 % kleinere Dateien.
- **Bildrate halbieren**: nur 13 % Gewinn. Bei halber Bildrate liegen
  aufeinanderfolgende Bilder weiter auseinander, jedes einzelne kostet dadurch
  mehr — der Effekt frisst die Ersparnis fast auf. Für so wenig die flüssige
  Bewegung aufzugeben lohnt nicht.
- **Langsamere x265-Presets**: `medium` braucht doppelt so lange wie
  `veryfast` bei praktisch gleichem Ergebnis.

### Zusätzlich verkleinern

```bash
./fegefeuer.sh video run --profil sparsam --auf 1080p
```

Das ist der größte Hebel überhaupt: 4K auf 1080p bringt **9 %** der
Ausgangsgröße statt 20 %, bei SSIM 0,975 gegen das 4K-Original. Begrenzt wird
die **kurze Seite**: 1080p heißt 1920×1080 quer und 1080×1920 hochkant.
Videos, die schon kleiner sind, werden nicht hochskaliert.

Es ist bewusst kein Profil, sondern eine eigene Option. Ein Profil wählt, wie
sorgfältig kodiert wird — die Auflösung zu verringern wirft dagegen
Bildinformation weg, die nie wiederkommt. Das soll man ausdrücklich tun
müssen. Die Prüfung skaliert für den Vergleich wieder hoch, misst also, was
tatsächlich verloren ging.

### Die Prüfung

Kodiert wird in eine Nebendatei. Erst wenn sie **alle** Prüfungen besteht,
wandert das Original ins Fegefeuer und die neue Fassung nimmt seinen Platz
ein. Fällt eine durch, wird die neue Datei verworfen und das Original bleibt
unberührt. Lässt sich die neue Fassung nicht an den Platz legen, kommt das
Original zurück.

| Prüfung | fängt ab |
|---|---|
| Laufzeit auf 0,5 s genau | abgeschnittene Aufnahmen |
| Tonspur vorhanden | stumme Filme, die erst Monate später auffallen |
| SSIM-Messung über die ganze Datei | Abbrüche, Beschädigungen, grobe Fehlkodierungen |
| kleiner als vorher | Kodierungen, die nichts bringen |

Die SSIM-Messung dekodiert beide Dateien vollständig und ersetzt damit
zugleich eine Prüflesung. Verglichen wird im Bild, wie ffmpeg es zeigt, also
bei Hochkant-Videos gedreht. Die Untergrenze liegt bei 0,90; echte
Kodierungen lagen zwischen 0,93 bei viel Bewegung und 0,99 bei ruhigen
Aufnahmen, eine absichtlich zerstörte Fassung bei 0,87. Lieber einmal zu viel
ablehnen: Das Original bleibt dabei unangetastet, es entfällt nur die
Ersparnis. Mit `FEGEFEUER_SSIM_MIN` lässt sich die Grenze verschieben.

Der freie Platz wird **vor jeder Datei** geprüft. Die Originale bleiben bis
`purge` auf derselben Platte, und jede neue Fassung kommt hinzu. Gebraucht
wird die Größe des Originals plus 1 GB Luft; reicht das nicht, endet der Lauf,
und die übrigen Videos bleiben freigegeben.

### Was die neue Fassung mitnimmt

Die Angaben der Kamera — Aufnahmeort, Aufnahmedatum, Gerät, auch Apples
eigene Felder (`com.apple.quicktime.*`) — gehen in die neue Datei über,
ebenso das Änderungs- und Erstellungsdatum der Datei, nach dem Finder und
Fotos sortieren. Alle Tonspuren bleiben erhalten.

Das Original landet mit einem Vermerk im Fegefeuer, der es von verschobenen
Dateien unterscheidet. Am Originalort liegt danach die neue Fassung — ohne den
Vermerk hielte `pruefen` das Original für „von selbst zurückgekehrt“ und
entbehrlich. So aber lassen `pruefen` und `purge --wieder-da` es aus.

## Einstellungen

| Umgebungsvariable | |
|---|---|
| `FEGEFEUER_DATEN=<ordner>` | wohin Kandidatenliste, Bericht und Arbeitsdateien kommen (Standard: neben dem Skript) |
| `FEGEFEUER_FORTSCHRITT=1` bzw. `=0` | Fortschrittsbalken erzwingen bzw. abschalten (Standard: nur am Terminal) |
| `FEGEFEUER_SSIM_MIN=0.90` | Untergrenze der Bildähnlichkeit bei `video run` |

Die langen Schritte — Durchsuchen, Prüfsummen, Vermessen, Kodieren, Prüfen —
zeigen einen Balken auf stderr, damit Pipelines und Logdateien sauber bleiben:

```
  ██████████░░░░░░░░░░░░   46%  kodiere  noch 3:20
```

## Dateien

| Datei | |
|---|---|
| `fegefeuer.sh` | Einstieg: Pfade, Module laden, Befehle verteilen, Hilfe |
| `lib/gemeinsam.sh` | Ausgabe, Fortschrittsanzeige, Umgebungsprüfung, Tastenbelegung |
| `lib/schutz.sh` | die Schutzliste und was die Scans auslassen |
| `lib/kandidaten.sh` | Helfer für `kandidaten.tsv` |
| `lib/scan.sh` | `scan` und der Bericht |
| `lib/review.sh` | `review`, `mark`, `zeigen`, `gruppen` |
| `lib/quarantaene.sh` | Manifest, `apply`, `list`, `restore`, `pruefen`, `purge` |
| `lib/brew.sh` | `brew` |
| `lib/video.sh` | `video scan`, `review`, `run` |
| `lib/gruppen.awk` | Gruppierung der Library-Reste nach Programm |
| `tests/pruefen.sh` | Regressionstests, jeder in einer eigenen Sandbox |
| `kandidaten.tsv` | deine Kandidaten und Entscheidungen *(nicht im Repo)* |
| `video-kandidaten.tsv` | vermessene Videos *(nicht im Repo)* |
| `bericht.md` | Übersicht nach jedem `scan` *(nicht im Repo)* |
| `brew-vorschlag.sh` | Deinstallations-Vorschlag von `brew` *(nicht im Repo)* |
| `.arbeit/` | Hashes und Zwischenstände *(nicht im Repo)* |

Alles, was Pfade dieses Rechners enthält, steht in `.gitignore`. Im Repo
liegen nur das Skript, seine Module und die Tests. Warum etwas so gebaut ist,
steht als Kommentar an der Stelle im Code.

## Tests

```bash
tests/pruefen.sh          # alle
tests/pruefen.sh apply    # nur die, deren Name "apply" enthält
```

Jeder Test bekommt ein frisches `HOME` und einen eigenen Datenort
(`FEGEFEUER_DATEN`) unter `mktemp`, baut sich seine Dateien selbst und räumt
am Ende alles weg. Dein Home und deine Kandidatenliste bleiben unberührt. Wie
das übrige Skript braucht das nur die Bordmittel von macOS; die Video-Tests
werden ohne `ffmpeg` übersprungen.

Zu jedem behobenen Fehler gehört ein Test, der ihn nachstellt — geschrieben,
bevor der Fehler behoben war, und zuerst rot.
