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
WURZEL="$(mktemp -d "${TMPDIR:-/tmp}/fegefeuer-test.XXXXXX")"
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
kandidat() {   # kandidat <status> <kategorie> <kb> <pfad>
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "2026-01-01" "$4" "Testeintrag" "$4" "test" >> "$D/kandidaten.tsv"
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
