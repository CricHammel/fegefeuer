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
| `toolchain` | alte Node-Versionen (außer der neuesten und der nvm-Standardversion), veraltete Playwright-Browser |
| `gross` | Einzeldateien und Pakete (Apps, VMs, Projekte) über 200 MB |
| `dublette` | inhaltsgleiche Dateien (SHA-1, Mindestgröße einstellbar) |

Ob eine App noch installiert ist, entscheidet nicht der Ordnername, sondern
eine Spotlight-Abfrage nach der Bundle-ID (`mdfind kMDItemCFBundleIdentifier`).
Eine frühere Namensheuristik hielt VLC und iTerm für deinstalliert.

Das setzt voraus, dass Spotlight funktioniert. Ist der Index aus oder
kaputt, verneint jede Abfrage — und jeder Ordner in `~/Library` sähe
verwaist aus. Deshalb fragt `scan` vorher nach Apps, die jedes macOS
mitbringt (Finder, Safari, TextEdit). Findet Spotlight keine davon, wird
der Schritt übersprungen und `mdutil -s /` zum Nachsehen vorgeschlagen; die
übrigen Schritte laufen weiter.

Geprüft werden nur **Ordner**. App-Daten liegen in Ordnern; eine Datei mit
Punkt im Namen ist fast immer ein Dateiname, keine Bundle-ID. Sonst gälten
`fsck_hfs.log` in `~/Library/Logs` oder `default.store` in
`~/Library/Application Support` als Reste nicht installierter Programme.
Ausgenommen sind `.savedState` und `.binarycookies` — die zwei Formen, die
als Datei auftreten und sehr wohl eine Bundle-ID tragen.

Bei Node bleibt neben der neuesten Version auch die, die nvm als Standard
eingestellt hat (`~/.nvm/alias/default`) — mit ihr läuft jede neue Shell,
auch wenn sie nicht die neueste ist. Aliase wie `20`, `node` oder `lts/*`
werden so aufgelöst, wie nvm es tut. Passt der Standard zu keiner
installierten Version, schlägt `scan` gar keine Node-Version vor.

Die Mindestgröße für den Dublettenvergleich lässt sich setzen — hashen kostet
Zeit, und unter einer gewissen Größe lohnt die Mühe selten:

```bash
./fegefeuer.sh scan --dubletten-ab 10M
```

Ohne Angabe gilt 1 MB. Erlaubt sind `500k`, `10M`, `2G` oder eine nackte Zahl
als Bytes; Groß- und Kleinschreibung der Einheit ist egal.

Das war nicht immer so. `find` unter macOS kennt nur `k`, `M` und `G`, und
`10m` ließ es mit einer Fehlermeldung scheitern, die nie zu sehen war — der
Scan meldete dann schlicht „0 Dateien“. Die Einheit wird deshalb angeglichen,
und ob `find` die Angabe versteht, wird vorab geprüft.

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

Früher bestimmte die Sortierung, welche Datei als Original galt. Bei
`Datei`/`Datei2` traf das zufällig zu, bei `Kopie von X` neben `X` hätte es
genau die falsche behalten.

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

Diese Benennung gilt nur für App-Reste. Alle anderen Gruppen heißen nach
ihrem Pfad (`~/.cache`), Dubletten nach Anzahl und Dateiname (`2× Datei.bin`).
Früher wurde jeder Name mit Punkt in Hersteller und Produkt zerlegt — aus
`~/.nvm/versions/node/v16.20.2` wurde „~/ · 2“, und `gruppen` warf zwei
Node-Versionen mit diesem Namen in eine Zeile.

Die Tastenbelegung steht bei **jeder** Frage, nicht nur einmal im Kopf — wer
150 Dubletten durchgeht, soll nicht raten müssen.

`q` unterbricht jederzeit, der Stand bleibt erhalten. Strg-C ebenso: Was bis
dahin entschieden ist, wird gespeichert, bevor das Skript endet. Bereits entschiedene
Einträge werden nie erneut gefragt, und eine Gruppenantwort überschreibt sie
nicht.

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

## Fortschritt

Die langen Schritte melden, wie weit sie sind — das Sammeln der Prüfsummen,
das Vermessen der Videos, das Kodieren und die Prüfung danach:

```
  ██████████░░░░░░░░░░░░   46%  kodiere  noch 3:20
```

Die Anzeige geht auf **stderr**, nicht auf stdout. Das ist kein Detail: Die
Prüfung wird als `grund="$(video_pruefen …)"` aufgerufen, und ein Balken auf
stdout landete prompt im Rückgabewert — die Ausgabe meldete daraufhin
„SSIM 0,000". Auf stderr bleiben Pipelines und Logdateien sauber.

Ohne Terminal erscheint nichts. `FEGEFEUER_FORTSCHRITT=1` erzwingt die
Anzeige, `=0` schaltet sie ab.

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

Ebenso `--zusammenfuehren`: Es holt nur zurück, was am Ziel fehlt. Liegt dort
von einer Datei schon eine eigene Fassung, bleibt die alte im Stapel und im
Manifest. Früher wurde der Stapelordner nach dem Ergänzen komplett entfernt —
mitsamt genau diesen alten Fassungen.

Dasselbe gilt in der Gegenrichtung. `apply` arbeitet die Freigaben nach Pfad
ab, damit ein Ordner vor allem wandert, was in ihm liegt, und es mitnimmt.
Früher galt die Reihenfolge der Liste: Eine große Datei in einem
freigegebenen Playwright-Build ging zuerst, der Build landete danach in
`chromium-1/chromium-1`, und `restore` holte nur die Datei zurück. Ist der
Zielpfad im Stapel trotzdem belegt, verweigert `apply` den Eintrag.

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

Dafür hält das Manifest jedes Stapels die Kategorie fest. Stapel aus älteren
Versionen haben diese Spalte nicht. Ihre Einträge gelten als unbekannt und
werden von `--wieder-da` nicht angefasst — die Kategorie aus dem Pfad zu
raten ginge schief, weil App-Reste auch in `~/Library/Caches` liegen.

Beide verlangen, dass du `LOESCHEN` tippst.

Liegen in den fälligen Stapeln Originale neu kodierter Videos, nennt `purge`
sie vorher eigens. An ihrem Platz liegt nur noch die verlustbehaftete neue
Fassung. `pruefen` und `purge --wieder-da` hielten sie schon immer heraus,
das gewöhnliche `purge` löschte sie dagegen mit, ohne sie zu erwähnen.

`purge` misst, was tatsächlich verschwunden ist, statt den Erfolg
vorauszusetzen. Bleibt etwas liegen, sagt es das und nennt den Grund — meist
Dateien, die ein Programm mit erhöhten Rechten angelegt hat und die nur mit
`sudo` zu entfernen sind. Tauchen während des Löschens neue Dateien auf (etwa
`.DS_Store`), räumt es sie weg und versucht es ein zweites Mal.


### Die Schutzliste

Diese Pfade lehnt `apply` ab, selbst wenn sie als Kandidat markiert sind:

- `~/Library/Keychains` — Passwörter
- `~/Library/Mail`, `~/Library/Messages`, `~/Library/Containers/com.apple.mail*`
- `~/Library/Mobile Documents` — iCloud Drive
- Foto-Mediatheken (`*.photoslibrary`), wo immer sie liegen
- `~/Library/Application Support/AddressBook` — Kontakte
- `~/Library/Group Containers/group.com.apple.notes*` — Notizen
- `~/Library/Group Containers/UBF8T346G9.*` und alles mit `OneDrive` im Pfad
- Cloud-Ordner: `~/Library/CloudStorage` (Dropbox, Google Drive, Box und
  andere File-Provider) sowie die älteren Orte `~/Dropbox`, `~/Google Drive`,
  `~/Box`, `~/pCloud Drive`
- `~/Library/Metadata` — Spotlight-Index
- `~/Library/Preferences/ByHost` — rechnergebundene Einstellungen
- `~/.ssh`, `~/.gnupg`
- `~/*.7z`
- `~/.fegefeuer` und das Arbeitsverzeichnis `.arbeit` — fegefeuer findet sich
  nicht selbst
- alles **innerhalb** eines Pakets (siehe unten) — das Paket selbst darf
  als Ganzes wandern
- alles außerhalb von `~`

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

Dasselbe gilt für zwei Arten von Ordnern, die der Finder nicht als Paket
zeigt: **Git-Repositories** (`.git` im Projekt wie ein nacktes `projekt.git`)
und **Geräte-Backups** unter `~/Library/Application Support/MobileSync/Backup`.
Eine einzelne Packdatei aus `.git/objects/pack` macht den Verlauf unlesbar,
eine einzelne der Tausenden Hash-Dateien eines iPhone-Backups das ganze
Backup unbrauchbar. Früher erschienen beide unter `gross`, sobald eine Datei
darin über 200 MB lag. Jetzt zeigt `scan` das Repository oder das Backup als
Ganzes. Ein altes iPhone-Backup ist oft der größte Brocken auf der Platte.

Die Listen stehen in `lib/schutz.sh` (`PAKET_ENDUNGEN`, `PAKET_ORTE`).
Foto-Mediatheken sind auch Pakete, stehen aber ganz unter Schutz.

Aus demselben Grund lässt die Dublettensuche Python-Umgebungen aus (`venv`,
`.venv`, `site-packages`), wie schon `node_modules`. Große Dateien darin,
etwa Modelle, erscheinen weiter unter `gross`.

### Woher die Einträge stammen

Die zwei wichtigsten Einträge kamen aus Beinahe-Unfällen. Der Dublettensucher
meldete 2,44 GB doppelte Dateien in einem OneDrive-Ordner — lokal gelöscht
hätte das die Dateien serverseitig für alle Kollegen entfernt. Und
`~/Library/Metadata` erzeugt massenhaft Schein-Dubletten, weil Spotlight
identische Journale in parallelen Pipelines führt. Der Dublettensucher lässt
`~/Library` inzwischen komplett aus.

Dass das Fegefeuer selbst auf der Liste steht, ist kein Formalismus. Ohne den
Eintrag fand der Dublettensucher eine Datei im Fegefeuer als Kopie ihrer
letzten echten Fassung. Wer die aus dem Fegefeuer behielt, schickte die echte
hinterher, und `purge` hätte nach sieben Tagen beide gelöscht.

Geschützte Pfade fallen aus, *bevor* Dubletten gruppiert werden. Bleibt von
einer Gruppe nur eine Datei übrig, ist sie keine Dublette mehr und taucht
nicht auf.

Die Liste steht in `lib/schutz.sh` (Funktion `ist_geschuetzt`) und will
angepasst werden, wenn dein Rechner andere heikle Orte hat.

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

`brew uninstall --cask` entfernt nur die App, nicht ihre Daten in
`~/Library`. Die findet der nächste `scan` als App-Rest, und sie gehen den
üblichen Weg durch das Fegefeuer.

Welche Programme installiert sind, sagt `brew list`, nicht
`brew info --installed`. Letzteres ließ AlDente weg: Die App läuft, aber ihr
Eintrag im Caskroom ist unvollständig. Solche Fälle werden angezeigt und
markiert, weil `brew uninstall` an ihnen scheitern kann.

Die Cask-Daten liefert Homebrew als JSON. Gelesen wird es mit JavaScript über
`osascript`, das jeder Mac mitbringt — `jq` oder Python wären zusätzliche
Voraussetzungen.

## Videos neu kodieren

```bash
./fegefeuer.sh video scan [verzeichnis]   # vermessen, nichts anfassen
./fegefeuer.sh video review               # auswählen
./fegefeuer.sh video run                  # kodieren, prüfen, Original sichern
```

`video run` ohne `--profil` fragt nach und zeigt dabei die Zahlen für **deine**
gerade ausgewählten Dateien, nicht allgemeine Richtwerte:

```
Womit kodieren?  Zahlen für deine 17 ausgewählten Dateien:

  1) schnell   VideoToolbox q60       9,71 GB → 2,62 GB    7,09 GB gespart   ~17 min
     Hardware-Chip des Macs, rund fünfmal schneller
  2) sparsam   x265 veryfast crf24    9,71 GB → 1,90 GB    7,81 GB gespart   ~76 min
     rechnet auf allen Kernen, Ergebnis rund ein Viertel kleiner
```

Für Skripte nimmt `--profil schnell` oder `--profil sparsam` die Frage vorweg.
Einen stillen Standardwert gibt es bewusst nicht — wer nichts angibt und
nichts eingeben kann, bekommt einen Fehler statt einer stillschweigend
getroffenen Entscheidung.

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

Vier Profile, alle an derselben 4K60-Stelle gemessen:

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

### Zusätzlich verkleinern

```bash
./fegefeuer.sh video run --profil sparsam --auf 1080p
```

Das ist der größte Hebel überhaupt: 4K auf 1080p bringt **9 %** der
Ausgangsgröße statt 20 %, bei SSIM 0,975 gegen das 4K-Original. Videos, die
schon kleiner sind, werden nicht hochskaliert.

Begrenzt wird die **kurze Seite**: 1080p heißt 1920×1080 quer und 1080×1920
hochkant. Früher begrenzte `--auf` die Höhe, und zwar nach der Drehung, die
ffmpeg beim Dekodieren vornimmt. Ein hochkant gefilmtes Handyvideo mit
1080×1920 wurde so mit `--auf 720p` zu 404×720, also einem Drittel der
gewollten Bildpunkte. Die Schätzung in der Auswahl rechnete dagegen mit den
ungedrehten Maßen und nannte andere Zahlen, als dann herauskamen.

Es ist bewusst kein Profil, sondern eine eigene Option. Ein Profil wählt, wie
sorgfältig kodiert wird — die Auflösung zu verringern wirft dagegen
Bildinformation weg, die nie wiederkommt. Das soll man ausdrücklich tun
müssen. Die Prüfung skaliert für den Vergleich wieder hoch, misst also, was
tatsächlich verloren ging.

### Was sich nicht lohnt

Zwei naheliegende Ideen habe ich vermessen und verworfen:

- **10 Bit**: 2,2-fache Rechenzeit für 0,7 % kleinere Dateien.
- **Bildrate halbieren**: nur 13 % Gewinn. Bei halber Bildrate liegen
  aufeinanderfolgende Bilder weiter auseinander, jedes einzelne kostet dadurch
  mehr — der Effekt frisst die Ersparnis fast auf. Für so wenig die flüssige
  Bewegung aufzugeben lohnt nicht.
- **Langsamere x265-Presets**: `medium` braucht doppelt so lange wie
  `veryfast` bei praktisch gleichem Ergebnis.

### Die Prüfung

Kodiert wird in eine Nebendatei. Erst wenn sie **alle** Prüfungen besteht,
wandert das Original ins Fegefeuer und die neue Fassung nimmt seinen Platz
ein. Fällt eine durch, wird die neue Datei verworfen und das Original bleibt
unberührt. Lässt sich die neue Fassung nicht an den Platz legen, kommt das
Original zurück.

Der freie Platz wird **vor jeder Datei** geprüft, nicht einmal vorab. Die
Originale bleiben bis `purge` auf derselben Platte, und jede neue Fassung
kommt hinzu — auf einer fast vollen Platte lief ein langer Lauf früher in den
Platzmangel. Gebraucht wird die Größe des Originals plus 1 GB Luft; reicht
das nicht, endet der Lauf, und die übrigen Videos bleiben freigegeben.

ZIPs mit mehr als einer Datei fasst `video` nicht an. Aus ihnen würde nur
die erste Datei kodiert, die neue Fassung ersetzte aber das ganze ZIP — die
übrigen Dateien lägen danach nur noch im Fegefeuer, bis `purge` sie löscht.
Ordner und die Beigaben des Finders (`__MACOSX`, `.DS_Store`) zählen nicht.

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

Die SSIM-Untergrenze liegt bei 0,90. Gemessene Werte echter Kodierungen lagen
zwischen 0,93 bei viel Bewegung und 0,99 bei ruhigen Aufnahmen, eine
absichtlich zerstörte Fassung kam auf 0,87 — der Abstand ist also knapp.
Lieber einmal zu viel ablehnen: Das Original bleibt dabei unangetastet, es
entfällt nur die Ersparnis. Mit `FEGEFEUER_SSIM_MIN` lässt sich die Grenze
verschieben.

Verglichen wird im Bild des Originals, so wie ffmpeg es zeigt. Hochkant
gefilmte Handyvideos tragen ihre Drehung nur als Vermerk, und ffmpeg dreht
beim Kodieren. Die Prüfung nahm früher die ungedrehten Maße aus `ffprobe`,
skalierte damit falsch und lehnte jedes dieser Videos ab.

### Was die neue Fassung mitnimmt

Die Angaben der Kamera — Aufnahmeort, Aufnahmedatum, Gerät, auch Apples
eigene Felder (`com.apple.quicktime.*`) — gehen in die neue Datei über,
ebenso das Änderungs- und Erstellungsdatum der Datei, nach dem Finder und
Fotos sortieren. Früher fehlte das alles: Die neue Fassung trug das heutige
Datum und keinen Ort mehr, und nach `purge` wäre beides endgültig verloren
gewesen.

Das Original landet mit einem Vermerk im Fegefeuer, der es von verschobenen
Dateien unterscheidet. Das ist wichtig: Am Originalort liegt danach die neue
Fassung, und ohne diesen Vermerk würde `pruefen` melden, die Datei sei „von
selbst zurückgekehrt" und die Quarantänekopie entbehrlich — worauf
`purge --wieder-da` ein unersetzliches Kameraoriginal gelöscht hätte.

**Dieser Unterbefehl braucht `ffmpeg` 7.1 oder neuer** (`brew install
ffmpeg`). Er ist der einzige Teil, der über die Bordmittel von macOS
hinausgeht, und prüft das beim Start — die Version nicht an der Nummer,
sondern daran, ob ffmpeg den Größenabgleich der Prüfung beherrscht.

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
| `video-kandidaten.tsv` | vermessene Videos *(nicht im Repo)* |
| `kandidaten.tsv` | deine Kandidaten und Entscheidungen *(nicht im Repo)* |
| `bericht.md` | Übersicht nach jedem `scan` *(nicht im Repo)* |
| `brew-vorschlag.sh` | Deinstallations-Vorschlag von `brew` *(nicht im Repo)* |
| `.arbeit/` | Hashes und Zwischenstände *(nicht im Repo)* |

Alles, was Pfade dieses Rechners enthält, steht in `.gitignore`. Im Repo
liegen nur das Skript, seine Module und die Tests.

Die erzeugten Dateien liegen neben dem Skript. `FEGEFEUER_DATEN=<ordner>`
legt sie woandershin; die Tests nutzen das, damit sie nie deine echte
Kandidatenliste überschreiben.

`fegefeuer.sh` findet die Module über sein eigenes Verzeichnis. Ein Aufruf
über einen Symlink, etwa aus `~/bin`, funktioniert deshalb nicht; dafür einen
Alias oder eine kleine Weiterleitung anlegen.

## Tests

```bash
tests/pruefen.sh          # alle
tests/pruefen.sh apply    # nur die, deren Name "apply" enthält
```

Jeder Test bekommt ein frisches `HOME` und einen eigenen Datenort unter
`mktemp`, baut sich seine Dateien selbst und räumt am Ende alles weg. Dein
Home und deine Kandidatenliste bleiben unberührt. Wie das übrige Skript
braucht das nur die Bordmittel von macOS.

Zu jedem behobenen Fehler gehört ein Test, der ihn nachstellt — geschrieben,
bevor der Fehler behoben war, und zuerst rot.

## Was es bewusst nicht tut

- Es löscht nichts ohne Wartezeit und Bestätigung.
- Es fasst nichts außerhalb des Home-Verzeichnisses an.
- Es entscheidet nicht, welche von zwei inhaltsgleichen Dateien die richtige
  ist — das weißt nur du.
- Es räumt keine Cloud-Ordner auf. Was dort verschwindet, verschwindet auf
  dem Server, bei geteilten Ordnern für alle. Die Scans gehen gar nicht erst
  hinein: Schon das Hashen einer nur online liegenden Datei lädt sie herunter.
