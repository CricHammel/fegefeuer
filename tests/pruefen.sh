#!/usr/bin/env bash
#
# tests/pruefen.sh -- Regressionstests fuer fegefeuer
#
# Jeder Test laeuft in einer eigenen Sandbox: ein frisches HOME und ein
# eigener Datenort (FEGEFEUER_DATEN). Weder dein Home noch deine echte
# kandidaten.tsv werden angefasst. Die Sandbox liegt unter mktemp und wird
# am Ende geloescht.
#
#   tests/pruefen.sh            alle Tests
#   tests/pruefen.sh apply      nur Tests, deren Name "apply" enthaelt
#
# Ein Test ist eine Funktion test_<name>. Zu jedem behobenen Fehler gehoert
# einer, der ihn nachstellt -- geschrieben, bevor der Fehler behoben war.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Ueber cd und pwd geglaettet: $TMPDIR endet unter macOS auf /, und ein HOME
# mit // darin vergliche sich nicht mit den Pfaden, die das Skript bildet.
WURZEL="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fegefeuer-test.XXXXXX")" && pwd)"
trap 'rm -rf "$WURZEL"' EXIT

T=$'\t'
bestanden=0 gescheitert=0 uebersprungen=0 aktuell=""

# ---------- Werkzeuge fuer die Tests ----------

# Legt die Sandbox des laufenden Tests an: $H ist sein HOME, $D sein Datenort,
# $Q seine Quarantaene.
sandbox() {
  H="$WURZEL/$aktuell/home"
  D="$WURZEL/$aktuell/daten"
  Q="$H/.fegefeuer"
  mkdir -p "$H" "$D"
}

# fegefeuer in der Sandbox aufrufen. Eingaben kommen ueber stdin, die
# Ausgabe ohne Farbcodes nach stdout.
ff() {
  HOME="$H" FEGEFEUER_DATEN="$D" FEGEFEUER_FORTSCHRITT=0 \
    bash "$REPO/fegefeuer.sh" "$@" 2>&1 | sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
}

# Eine Zeile in die Kandidatenliste der Sandbox schreiben.
# kb darf leer sein -- das kommt vor, wenn `du` an einem Pfad scheitert.
# Ohne Gruppenschluessel bildet jeder Eintrag seine eigene Gruppe.
kandidat() {   # kandidat <status> <kategorie> <kb> <pfad> [gruppe]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "2026-01-01" "$4" "Testeintrag" "${5:-$4}" "test" >> "$D/kandidaten.tsv"
}

status_von() {   # status_von <pfad> -> Status aus der Kandidatenliste
  awk -F'\t' -v p="$1" '$5==p { print $1; exit }' "$D/kandidaten.tsv"
}

stapel() { ls "$Q" 2>/dev/null | grep -v '^_' | head -1; }

pruefe() {   # pruefe <beschreibung> <befehl ...>
  local text="$1"; shift
  if "$@"; then
    bestanden=$((bestanden + 1))
  else
    gescheitert=$((gescheitert + 1))
    printf '  ✗ %s: %s\n' "$aktuell" "$text"
  fi
}

ueberspringen() {   # ueberspringen <grund>
  uebersprungen=$((uebersprungen + 1))
  printf '  – %s: übersprungen (%s)\n' "$aktuell" "$1"
}

# Die Video-Tests brauchen ffmpeg wie video selbst. Fehlt es, werden sie
# uebersprungen statt rot.
hat_ffmpeg() { command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; }

# Ein kurzes Testvideo mit Ton. Zusaetzliche Ausgabeoptionen (Metadaten
# etwa) gehen an ffmpeg durch. Nahezu verlustfrei kodiert, damit jede
# Neukodierung kleiner wird. TESTVIDEO_GROESSE setzt die Aufloesung.
testvideo() {   # testvideo <datei> [ffmpeg-ausgabeoptionen ...]
  local ziel="$1"; shift
  ffmpeg -v error -f lavfi -i "testsrc2=size=${TESTVIDEO_GROESSE:-640x360}:rate=30" -f lavfi -i sine=frequency=440 \
    -t 3 -c:v libx264 -crf 10 -c:a aac -shortest "$@" -y "$ziel"
}

# Ein Video als freigegeben in die Videoliste der Sandbox eintragen, mit den
# Spalten, die video scan schreibt.
video_freigeben() {   # video_freigeben <pfad>
  local p="$1" masse dauer kb
  masse="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$p" | cut -d, -f1,2)"
  dauer="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$p")"
  kb="$(du -sk "$p" | cut -f1)"
  printf 'go\t%s\tnein\th264\t%s\t%s\t30\t%s\t%s\t%s\t0.5\tlohnt\t0\t0\n' \
    "$p" "${masse%,*}" "${masse#*,}" "$dauer" "$kb" "$kb" >> "$D/video-kandidaten.tsv"
}

# Ein unkomprimiertes Video: schnell erzeugt und ueber den 20 MB, ab denen
# video scan sucht (640x360, 3 s, rund 40 MB).
rohvideo() {   # rohvideo <datei.mov>
  ffmpeg -v error -f lavfi -i testsrc2=size=640x360:rate=30 -t 3 \
    -c:v rawvideo -pix_fmt uyvy422 -y "$1"
}

# Ein df, das der Reihe nach die uebergebenen freien KB meldet -- einen Wert
# je Aufruf, der letzte gilt fuer alle weiteren. Die Sandbox legt es vorne
# in den PATH: PATH="$(falsches_df ...):$PATH" ff ...
falsches_df() {   # falsches_df <kb> [kb ...] -> Verzeichnis mit dem df
  local bin="$WURZEL/$aktuell/bin" zaehler="$WURZEL/$aktuell/df_aufrufe"
  mkdir -p "$bin"
  printf '%s\n' "$@" > "$WURZEL/$aktuell/df_werte"
  : > "$zaehler"
  cat > "$bin/df" <<DF
#!/bin/bash
echo x >> "$zaehler"
n=\$(wc -l < "$zaehler")
frei=\$(sed -n "\${n}p" "$WURZEL/$aktuell/df_werte")
[ -n "\$frei" ] || frei=\$(tail -1 "$WURZEL/$aktuell/df_werte")
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/test 999999999 0 \$frei 1% /"
DF
  chmod +x "$bin/df"
  printf '%s' "$bin"
}

video_status() {   # video_status <pfad> -> Status aus der Videoliste
  awk -F'\t' -v p="$1" '$2==p { print $1; exit }' "$D/video-kandidaten.tsv"
}

nicht() { ! "$@"; }
gleich() { [ "$1" = "$2" ]; }
enthaelt() { case "$1" in *"$2"*) return 0;; esac; return 1; }

# ---------- Tests ----------

test_daten_ort_aus_umgebung() {
  sandbox
  mkdir -p "$H/Library/Caches/foo"
  kandidat neu cache 10 "$H/Library/Caches/foo"
  ff mark cache go > /dev/null
  pruefe "mark schreibt in die Liste unter FEGEFEUER_DATEN" gleich "$(status_von "$H/Library/Caches/foo")" go
  pruefe "Arbeitsverzeichnis liegt im Datenort" test -d "$D/.arbeit"
}

test_apply_schutzliste() {
  sandbox
  mkdir -p "$H/.ssh"
  kandidat go cache 10 "$H/.ssh"
  echo j | ff apply > /dev/null
  pruefe "geschützter Ordner bleibt liegen" test -d "$H/.ssh"
  pruefe "geschützter Eintrag wird auf keep gesetzt" gleich "$(status_von "$H/.ssh")" keep
}

# Die Liste ist nach Kategorie sortiert, und "gross" kommt vor "toolchain".
# Eine grosse Datei in einem freigegebenen Ordner wanderte deshalb zuerst --
# und der Ordner danach in die von ihr angelegte Huelle: chromium-1/chromium-1.
test_apply_kind_vor_elternordner() {
  sandbox
  local p="$H/Library/Caches/ms-playwright/chromium-1"
  mkdir -p "$p/sub"
  echo inhalt > "$p/andere.txt"
  echo gross > "$p/sub/Framework"
  kandidat go gross 5 "$p/sub/Framework"
  kandidat go toolchain 10 "$p"
  echo j | ff apply > /dev/null
  local s; s="$(stapel)"
  local qp="$Q/$s/Library/Caches/ms-playwright/chromium-1"
  pruefe "nicht in sich selbst verschachtelt" nicht test -e "$qp/chromium-1"
  pruefe "Ordner liegt vollständig in der Quarantäne" test -f "$qp/andere.txt"
  pruefe "die Datei darin auch" test -f "$qp/sub/Framework"
  pruefe "nur der Ordner steht im Manifest" gleich "$(wc -l < "$Q/$s/_manifest.tsv" | tr -d ' ')" 1

  ff restore "$s" > /dev/null
  pruefe "restore bringt den Ordner zurück" test -f "$p/andere.txt"
  pruefe "restore bringt die Datei darin zurück" test -f "$p/sub/Framework"
  pruefe "der Stapel ist danach leer und entfernt" nicht test -d "$Q/$s"
}

test_apply_behaltenes_im_ordner() {
  sandbox
  local p="$H/Library/Caches/ms-playwright"
  mkdir -p "$p/chromium-1" "$p/chromium-2"
  kandidat go cache 20 "$p"
  kandidat keep toolchain 10 "$p/chromium-1"
  local ausgabe; ausgabe="$(echo j | ff apply)"
  pruefe "Ordner mit Behaltenem bleibt liegen" test -d "$p/chromium-2"
  pruefe "das Behaltene auch" test -d "$p/chromium-1"
  pruefe "apply nennt den Grund" enthaelt "$ausgabe" "das du behalten wolltest"
}

# "mark gross go" kann auch die behaltene Kopie einer Dublette freigeben.
# apply muss die ganze Gruppe dann in Ruhe lassen.
test_apply_letzte_dublette_bleibt() {
  sandbox
  mkdir -p "$H/a" "$H/b"
  echo gleich > "$H/a/film.bin"; echo gleich > "$H/b/film.bin"
  printf 'keep\tdublette\t300\t2026-01-01\t%s\tTest\tdub-1\t2x film.bin\n' "$H/a/film.bin" >> "$D/kandidaten.tsv"
  printf 'go\tdublette\t300\t2026-01-01\t%s\tTest\tdub-1\t2x film.bin\n' "$H/b/film.bin" >> "$D/kandidaten.tsv"
  kandidat go gross 300 "$H/a/film.bin"
  echo j | ff apply > /dev/null
  pruefe "die behaltene Kopie bleibt" test -f "$H/a/film.bin"
  pruefe "die freigegebene wandert" nicht test -e "$H/b/film.bin"
}

test_apply_abbruch_ohne_stapel() {
  sandbox
  mkdir -p "$H/Library/Caches/foo"
  kandidat go cache 10 "$H/Library/Caches/foo"
  local ausgabe; ausgabe="$(echo n | ff apply)"
  pruefe "meldet den Abbruch" enthaelt "$ausgabe" "Abgebrochen"
  pruefe "legt keinen leeren Stapel an" gleich "$(stapel)" ""
  pruefe "lässt den Ordner liegen" test -d "$H/Library/Caches/foo"
}

# IFS=Tab fasst aufeinanderfolgende Tabs zusammen: Ein leeres Groessenfeld
# schob den Pfad in die Spalte davor, und apply hielt die Begruendung fuer
# den Pfad.
test_apply_leeres_groessenfeld() {
  sandbox
  local p="$H/Library/Caches/foo"
  mkdir -p "$p"
  kandidat go cache "" "$p"
  echo j | ff apply > /dev/null
  local s; s="$(stapel)"
  pruefe "Eintrag ohne Größe wird verschoben" nicht test -e "$p"
  pruefe "und liegt in der Quarantäne" test -d "$Q/$s/Library/Caches/foo"
  pruefe "Manifest hat fünf Spalten mit Größe 0" \
    gleich "$(awk -F'\t' '{ print NF "/" $3 "/" $4 "/" $5 }' "$Q/$s/_manifest.tsv" 2>/dev/null)" "5/0/verschoben/cache"
}

# Was in einem freigegebenen Ordner liegt, wandert mit und wird nicht mehr
# gefragt. Beim einzelnen Durchgehen einer Gruppe (e) merkte sich review den
# freigegebenen Ordner aber nicht -- sein Inhalt kam trotzdem noch dran.
test_review_einzeln_freigegebener_ordner() {
  sandbox
  local app="$H/Library/Application Support/com.foo.app"
  mkdir -p "$app/Cache" "$H/Library/Caches/com.foo.app"
  kandidat neu app-rest 1000 "$app" foo
  kandidat neu app-rest 500 "$H/Library/Caches/com.foo.app" foo
  kandidat neu cache 10 "$app/Cache"
  # e = einzeln, dann j fuer den Ordner, n fuer den Cache-Ordner der App.
  # Danach ist die Eingabe zu Ende; eine weitere Frage hiesse q.
  printf 'e\nj\nn\n' | ff review > /dev/null
  pruefe "der freigegebene Ordner ist go" gleich "$(status_von "$app")" go
  pruefe "der abgelehnte ist keep" gleich "$(status_von "$H/Library/Caches/com.foo.app")" keep
  pruefe "was im freigegebenen liegt, wandert ohne Frage mit" gleich "$(status_von "$app/Cache")" go
}

# Kein Fehler, sondern Absicherung: Die uebrigen Wege zu einer Freigabe
# laufen jetzt ueber dieselbe Funktion und sollen sich verhalten wie vorher.
test_review_gruppe_und_dublette() {
  sandbox
  local app="$H/Library/Application Support/com.foo.app"
  mkdir -p "$app/Cache" "$H/Library/Caches/com.foo.app" "$H/a" "$H/b"
  echo gleich > "$H/a/f.bin"; echo gleich > "$H/b/f.bin"
  kandidat neu app-rest 1000 "$app" foo
  kandidat neu app-rest 500 "$H/Library/Caches/com.foo.app" foo
  kandidat neu dublette 300 "$H/a/f.bin" dub-1
  kandidat neu dublette 300 "$H/b/f.bin" dub-1
  kandidat neu cache 10 "$app/Cache"
  # j = ganze Gruppe weg, 2 = von den Dubletten die zweite behalten
  printf 'j\n2\n' | ff review > /dev/null
  pruefe "Gruppe: erster Eintrag go" gleich "$(status_von "$app")" go
  pruefe "Gruppe: zweiter Eintrag go" gleich "$(status_von "$H/Library/Caches/com.foo.app")" go
  pruefe "Inhalt des freigegebenen Ordners ohne Frage go" gleich "$(status_von "$app/Cache")" go
  pruefe "von den Dubletten genau eine behalten, eine frei" \
    gleich "$(status_von "$H/a/f.bin") $(status_von "$H/b/f.bin")" "go keep"
}

# Das Muster */.photoslibrary/* traf nie: Die Mediathek heisst
# "Photos Library.photoslibrary", vor dem Punkt steht kein Schraegstrich.
# Mediatheken wurden komplett gehasht, und ausserhalb von ~/Pictures
# schuetzte sie nichts.
test_scan_fotomediathek_ausserhalb_bilder() {
  sandbox
  local m="$H/Archiv/Alt.photoslibrary/originals" d="$H/Dokumente"
  mkdir -p "$m" "$d"
  head -c 4096 /dev/urandom > "$m/a.jpg"; cp "$m/a.jpg" "$m/b.jpg"
  mkfile -n 201m "$m/film.mov"
  # Gegenprobe: dasselbe ausserhalb der Mediathek wird gefunden
  head -c 4096 /dev/urandom > "$d/x.bin"; cp "$d/x.bin" "$d/y.bin"
  mkfile -n 201m "$d/gross.bin"
  ff scan --dubletten-ab 1k > /dev/null
  pruefe "Gegenprobe: Dublette außerhalb gefunden" gleich "$(status_von "$d/x.bin")" neu
  pruefe "Gegenprobe: große Datei außerhalb gefunden" gleich "$(status_von "$d/gross.bin")" neu
  pruefe "nichts aus der Mediathek in der Liste" \
    gleich "$(grep -c 'photoslibrary' "$D/kandidaten.tsv")" 0
}

test_apply_fotomediathek_geschuetzt() {
  sandbox
  local m="$H/Archiv/Alt.photoslibrary"
  mkdir -p "$m/originals"
  echo bild > "$m/originals/a.jpg"
  kandidat go gross 300 "$m/originals/a.jpg"
  kandidat go app-rest 10 "$m"
  echo j | ff apply > /dev/null
  pruefe "Datei in einer Mediathek bleibt" test -f "$m/originals/a.jpg"
  pruefe "die Mediathek selbst bleibt" test -d "$m"
}

# ffmpeg dreht beim Kodieren, was die Kamera nur als Drehung vermerkt hat.
# Die Pruefung verglich die ungedrehten Masse des Originals mit der gedrehten
# neuen Fassung, skalierte falsch, und der SSIM-Filter brach ab -- jedes
# hochkant gefilmte Handyvideo fiel durch.
test_video_hochkant() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/quer.mp4"
  ffmpeg -v error -display_rotation 90 -i "$H/Film/quer.mp4" -c copy -y "$H/Film/hoch.mov"
  rm "$H/Film/quer.mp4"
  video_freigeben "$H/Film/hoch.mov"
  echo j | ff video run --profil sparsam > /dev/null
  pruefe "hochkant kodiert und geprüft" gleich "$(video_status "$H/Film/hoch.mov")" fertig
  pruefe "neue Fassung liegt am Platz" test -f "$H/Film/hoch.mp4"
}

# Kein Fehler, sondern Absicherung: Die Pruefung bringt eine verkleinerte
# Fassung fuer den Vergleich auf das Mass des Originals. Das lief vorher
# ueber eigene Masse und jetzt ueber scale=rw:rh -- es soll weiter gehen.
test_video_verkleinert() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  TESTVIDEO_GROESSE=1920x1080 testvideo "$H/Film/gross.mp4"
  video_freigeben "$H/Film/gross.mp4"
  echo j | ff video run --profil sparsam --auf 720p > /dev/null
  pruefe "verkleinert kodiert und geprüft" gleich "$(video_status "$H/Film/gross.mp4")" fertig
  pruefe "neue Fassung hat 720 Zeilen" \
    gleich "$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$H/Film/gross.mp4" 2>/dev/null)" 720
}

# Gegenprobe zur SSIM-Messung: Mit einer unerreichbaren Schwelle muss die
# Pruefung ablehnen. Verglich der Filter etwa das Original mit sich selbst,
# kaeme immer 1,0 heraus, und jede Kodierung bestuende.
test_video_pruefung_lehnt_ab() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/a.mp4"
  video_freigeben "$H/Film/a.mp4"
  local ausgabe
  ausgabe="$(echo j | FEGEFEUER_SSIM_MIN=0.99999 ff video run --profil sparsam)"
  pruefe "nennt die Bildqualität als Grund" enthaelt "$ausgabe" "Bildqualität zu weit weg"
  pruefe "Original bleibt am Platz" test -f "$H/Film/a.mp4"
  pruefe "bleibt freigegeben" gleich "$(video_status "$H/Film/a.mp4")" go
  pruefe "kein Stapel angelegt" gleich "$(stapel)" ""
}

# Ohne Vorkehrung schrieb ffmpeg weder Aufnahmeort noch Aufnahmedatum der
# Kamera in die neue Datei, und die Datei trug das heutige Datum. Nach
# purge waeren beide endgueltig verloren.
test_video_metadaten_bleiben() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  local alt="$H/Film/urlaub.mov" neu="$H/Film/urlaub.mp4"
  testvideo "$alt" -movflags use_metadata_tags \
    -metadata "com.apple.quicktime.location.ISO6709=+50.1109+008.6821/" \
    -metadata "com.apple.quicktime.creationdate=2019-07-14T18:03:00+0200" \
    -metadata "creation_time=2019-07-14T16:03:00Z"
  touch -t 201907141803 "$alt"
  video_freigeben "$alt"
  echo j | ff video run --profil sparsam > /dev/null
  local tags; tags="$(ffprobe -v error -show_entries format_tags -of default=nw=1 "$neu" 2>/dev/null)"
  pruefe "kodiert" gleich "$(video_status "$alt")" fertig
  pruefe "Aufnahmeort bleibt" enthaelt "$tags" "location.ISO6709=+50.1109+008.6821/"
  pruefe "Aufnahmedatum der Kamera bleibt" enthaelt "$tags" "creationdate=2019-07-14T18:03:00"
  pruefe "Änderungsdatum der Datei bleibt" gleich "$(stat -f '%Sm' -t '%Y-%m-%d' "$neu" 2>/dev/null)" 2019-07-14
  pruefe "Erstellungsdatum der Datei bleibt" gleich "$(stat -f '%SB' -t '%Y-%m-%d' "$neu" 2>/dev/null)" 2019-07-14
}

# find liefert relative Pfade, wenn es einen relativen Ordner bekommt. Die
# Schutzliste haelt alles, was nicht mit $HOME/ beginnt, fuer ausserhalb --
# video run uebersprang dann jede einzelne Datei als geschuetzt.
test_video_scan_relativer_pfad() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  rohvideo "$H/Film/roh.mov"
  ( cd "$H" && ff video scan Film > /dev/null )
  pruefe "Pfad steht absolut in der Liste" \
    gleich "$(cut -f2 "$D/video-kandidaten.tsv" 2>/dev/null)" "$H/Film/roh.mov"
}

# Aus einem ZIP wurde nur die erste Datei kodiert, ersetzt aber das ganze
# ZIP. Die uebrigen lagen danach nur noch im Fegefeuer -- bis purge.
test_video_scan_zip_mehrere_dateien() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  local z="$WURZEL/$aktuell/zip"
  mkdir -p "$H/Film" "$z"
  rohvideo "$z/a.mov"; cp "$z/a.mov" "$z/b.mov"
  ( cd "$z" && zip -q -0 "$H/Film/zwei.mov.zip" a.mov b.mov && zip -q -0 "$H/Film/eins.mov.zip" a.mov )
  local ausgabe; ausgabe="$(ff video scan "$H/Film")"
  pruefe "ZIP mit einer Datei wird vermessen" grep -q "eins.mov.zip" "$D/video-kandidaten.tsv"
  pruefe "ZIP mit zwei Dateien nicht" nicht grep -q "zwei.mov.zip" "$D/video-kandidaten.tsv"
  pruefe "scan nennt es" enthaelt "$ausgabe" "mehr als eine Datei"
}

# Dasselbe in video run, fuer Listen aus einem frueheren scan
test_video_run_zip_mehrere_dateien() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  local z="$WURZEL/$aktuell/zip" p="$H/Film/zwei.mov.zip"
  mkdir -p "$H/Film" "$z"
  rohvideo "$z/a.mov"; cp "$z/a.mov" "$z/b.mov"
  ( cd "$z" && zip -q -0 "$p" a.mov b.mov )
  printf 'go\t%s\tja\th264\t640\t360\t30\t3.0\t%s\t%s\t1\tlohnt\t0\t0\n' \
    "$p" "$(du -sk "$p" | cut -f1)" "$(du -sk "$p" | cut -f1)" >> "$D/video-kandidaten.tsv"
  local ausgabe; ausgabe="$(echo j | ff video run --profil sparsam)"
  pruefe "ZIP bleibt am Platz" test -f "$p"
  pruefe "bleibt freigegeben" gleich "$(video_status "$p")" go
  pruefe "run nennt den Grund" enthaelt "$ausgabe" "mehr als eine Datei"
  pruefe "kein Stapel angelegt" gleich "$(stapel)" ""
}

# Der Platz wurde einmal vorab geprueft. Die Originale bleiben aber im
# Fegefeuer auf derselben Platte, jede neue Fassung kommt hinzu -- auf einer
# fast vollen Platte lief der Lauf in den Platzmangel hinein.
test_video_run_platz_je_datei() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/a.mp4"; testvideo "$H/Film/b.mp4"
  video_freigeben "$H/Film/a.mp4"; video_freigeben "$H/Film/b.mp4"
  local bin; bin="$(falsches_df 5242880 1000)"
  local ausgabe; ausgabe="$(echo j | PATH="$bin:$PATH" ff video run --profil sparsam)"
  pruefe "erste Datei kodiert" gleich "$(video_status "$H/Film/a.mp4")" fertig
  pruefe "zweite nicht, der Platz reicht nicht mehr" gleich "$(video_status "$H/Film/b.mp4")" go
  pruefe "ihr Original bleibt am Platz" test -f "$H/Film/b.mp4"
  pruefe "run nennt den Grund" enthaelt "$ausgabe" "Zu wenig Platz"
}

# ---------- Ablauf ----------

filter="${1:-}"
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  case "$t" in *"$filter"*) ;; *) continue;; esac
  aktuell="${t#test_}"
  "$t"
done

echo
zusatz=""
[ "$uebersprungen" -gt 0 ] && zusatz=", $uebersprungen Tests übersprungen"
if [ "$gescheitert" -eq 0 ]; then
  echo "$bestanden Prüfungen bestanden$zusatz"
else
  echo "$bestanden bestanden, $gescheitert gescheitert$zusatz"
  exit 1
fi
