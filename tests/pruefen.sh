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

# Ein mdfind, das nur die uebergebenen Bundle-IDs als installierte App kennt.
# Ohne IDs kennt es keine -- so verhaelt sich ein abgeschalteter Index.
# Liegt im selben bin wie falsches_df: PATH="$(falsches_mdfind ...):$PATH" ff ...
falsches_mdfind() {   # falsches_mdfind [bundle-id ...] -> Verzeichnis mit dem mdfind
  local bin="$WURZEL/$aktuell/bin" liste="$WURZEL/$aktuell/mdfind_ids"
  mkdir -p "$bin"
  printf '%s\n' "$@" > "$liste"
  cat > "$bin/mdfind" <<MDFIND
#!/bin/bash
while IFS= read -r id; do
  [ -n "\$id" ] || continue
  case "\$*" in *"'\$id'"*) echo "/Applications/\$id.app"; exit 0;; esac
done < "$liste"
exit 0
MDFIND
  chmod +x "$bin/mdfind"
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

# Ob eine App installiert ist, fragt scan Spotlight. Ist der Index aus oder
# kaputt, findet Spotlight nichts -- und jeder Library-Ordner galt als Rest
# einer deinstallierten App.
test_scan_ohne_spotlight() {
  sandbox
  mkdir -p "$H/Library/Application Support/com.example.tool"
  local bin; bin="$(falsches_mdfind)"
  local ausgabe; ausgabe="$(PATH="$bin:$PATH" ff scan)"
  pruefe "kein App-Rest vorgeschlagen" \
    nicht grep -q 'com.example.tool' "$D/kandidaten.tsv"
  pruefe "scan nennt den Grund" enthaelt "$ausgabe" "Spotlight"
}

# Gegenprobe: Mit funktionierendem Spotlight wird weiter unterschieden
test_scan_mit_spotlight() {
  sandbox
  mkdir -p "$H/Library/Application Support/com.example.weg" "$H/Library/Application Support/com.example.da"
  local bin; bin="$(falsches_mdfind com.apple.finder com.example.da)"
  PATH="$bin:$PATH" ff scan > /dev/null
  pruefe "Rest einer fehlenden App vorgeschlagen" \
    gleich "$(status_von "$H/Library/Application Support/com.example.weg")" neu
  pruefe "Ordner einer installierten App nicht" \
    nicht grep -q 'com.example.da' "$D/kandidaten.tsv"
}

# Pakete -- Apps, virtuelle Maschinen, Projekte -- sind fuer den Finder eine
# Datei. Eine einzelne Datei daraus zu verschieben beschaedigt das Paket:
# die Festplatte einer VM als "gross", eine Bibliothek in zwei Apps als
# "Dublette". scan geht nicht mehr hinein und zeigt grosse Pakete als Ganzes.
test_scan_paket_als_ganzes() {
  sandbox
  local vm="$H/VMs/Windows.utm" a1="$H/Applications/Foo.app" a2="$H/Applications/Bar.app"
  mkdir -p "$vm/Data" "$a1/Contents/Frameworks" "$a2/Contents/Frameworks" "$H/Dokumente"
  dd if=/dev/zero of="$vm/Data/disk.img" bs=1m count=210 2>/dev/null
  head -c 4096 /dev/urandom > "$a1/Contents/Frameworks/lib.dylib"
  cp "$a1/Contents/Frameworks/lib.dylib" "$a2/Contents/Frameworks/lib.dylib"
  head -c 4096 /dev/urandom > "$H/Dokumente/x.bin"; cp "$H/Dokumente/x.bin" "$H/Dokumente/y.bin"
  ff scan --dubletten-ab 1k > /dev/null
  pruefe "VM erscheint als Ganzes unter gross" \
    gleich "$(awk -F'\t' -v p="$vm" '$5==p { print $1 "/" $2 }' "$D/kandidaten.tsv")" "neu/gross"
  pruefe "ihre Festplatte nicht einzeln" nicht grep -q 'disk.img' "$D/kandidaten.tsv"
  pruefe "keine Dublette aus App-Paketen" nicht grep -q 'lib.dylib' "$D/kandidaten.tsv"
  pruefe "kleine Pakete erscheinen nicht" nicht grep -q 'Foo.app' "$D/kandidaten.tsv"
  pruefe "Gegenprobe: Dublette außerhalb gefunden" gleich "$(status_von "$H/Dokumente/x.bin")" neu
}

# Python-Umgebungen enthalten oft dieselben Bibliotheken. Eine davon zu
# verschieben macht die Umgebung kaputt -- wie node_modules bleiben sie
# aus der Dublettensuche heraus.
test_scan_venv_ohne_dubletten() {
  sandbox
  local d1="$H/p1/.venv/lib/python3.12/site-packages/np" d2="$H/p2/venv/lib/python3.12/site-packages/np"
  local d3="$H/p3/umgebung/lib/python3.12/site-packages/np"
  mkdir -p "$d1" "$d2" "$d3"
  head -c 4096 /dev/urandom > "$d1/core.so"; cp "$d1/core.so" "$d2/core.so"; cp "$d1/core.so" "$d3/core.so"
  ff scan --dubletten-ab 1k > /dev/null
  pruefe "keine Dublette aus Python-Umgebungen" nicht grep -q 'core.so' "$D/kandidaten.tsv"
}

# Gegenstueck in apply, fuer Listen aus einem frueheren scan
test_apply_paketinhalt_geschuetzt() {
  sandbox
  local app="$H/Applications/Foo.app" vm="$H/VMs/Alt.utm"
  mkdir -p "$app/Contents" "$vm/Data"
  echo x > "$app/Contents/Info.plist"; echo x > "$vm/Data/disk.img"
  kandidat go gross 300 "$app/Contents/Info.plist"
  kandidat go gross 300 "$vm"
  echo j | ff apply > /dev/null
  pruefe "Datei in einem Paket bleibt" test -f "$app/Contents/Info.plist"
  pruefe "ein Paket als Ganzes wandert" nicht test -e "$vm"
}

test_video_scan_ohne_pakete() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film/Urlaub.fcpbundle/Media"
  rohvideo "$H/Film/Urlaub.fcpbundle/Media/clip.mov"
  cp "$H/Film/Urlaub.fcpbundle/Media/clip.mov" "$H/Film/einzeln.mov"
  ff video scan "$H/Film" > /dev/null
  pruefe "Video außerhalb vermessen" grep -q 'einzeln.mov' "$D/video-kandidaten.tsv"
  pruefe "Video im Final-Cut-Projekt nicht" nicht grep -q 'fcpbundle' "$D/video-kandidaten.tsv"
}

# Node-Versionen unter nvm anlegen
nvm_versionen() {   # nvm_versionen <version ...>
  local v
  for v in "$@"; do mkdir -p "$H/.nvm/versions/node/$v/bin"; done
  mkdir -p "$H/.nvm/alias/lts"
}

node_kandidaten() {   # -> vorgeschlagene Node-Versionen, eine Zeile
  awk -F'\t' '$2=="toolchain" && $5 ~ /\.nvm\/versions\/node\// { n=$5; sub(/.*\//, "", n); print n }' \
    "$D/kandidaten.tsv" 2>/dev/null | sort | tr '\n' ' '
}

# Vorgeschlagen wurden alle Versionen ausser der neuesten -- auch die, die
# nvm als Standard eingestellt hat und die jede neue Shell benutzt.
test_scan_nvm_standard_bleibt() {
  sandbox
  nvm_versionen v18.20.0 v20.11.0 v22.1.0
  echo 20 > "$H/.nvm/alias/default"
  ff scan > /dev/null
  pruefe "nur die alte, nicht die Standardversion" gleich "$(node_kandidaten)" "v18.20.0 "
}

# nvm legt "lts/*" als Kette von Aliasen an: lts/* -> lts/iron -> v20...
test_scan_nvm_lts_alias() {
  sandbox
  nvm_versionen v18.20.0 v20.11.0 v22.1.0
  echo 'lts/*' > "$H/.nvm/alias/default"
  echo 'lts/iron' > "$H/.nvm/alias/lts/*"
  echo 'v20.11.0' > "$H/.nvm/alias/lts/iron"
  ff scan > /dev/null
  pruefe "lts-Kette aufgelöst, Standard bleibt" gleich "$(node_kandidaten)" "v18.20.0 "
}

# Laesst sich der Standard nicht bestimmen, lieber kein Vorschlag als ein
# falscher.
test_scan_nvm_standard_unklar() {
  sandbox
  nvm_versionen v18.20.0 v22.1.0
  echo v16 > "$H/.nvm/alias/default"
  local ausgabe; ausgabe="$(ff scan)"
  pruefe "keine Node-Version vorgeschlagen" gleich "$(node_kandidaten)" ""
  pruefe "scan nennt den Grund" enthaelt "$ausgabe" "Standardversion"
}

# Gegenprobe: Ohne eingestellten Standard bleibt es beim bisherigen Verhalten
test_scan_nvm_ohne_standard() {
  sandbox
  nvm_versionen v18.20.0 v20.11.0 v22.1.0
  ff scan > /dev/null
  pruefe "alle ausser der neuesten" gleich "$(node_kandidaten)" "v18.20.0 v20.11.0 "
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

# --auf begrenzte die Hoehe -- nach der Drehung, die ffmpeg beim Dekodieren
# vornimmt, also bei Hochkant-Videos die lange Seite. Ein Handyvideo mit
# 1080x1920 wurde mit --auf 720p zu 404x720 statt 720x1280.
test_video_verkleinert_hochkant() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  TESTVIDEO_GROESSE=1920x1080 testvideo "$H/Film/quer.mp4"
  ffmpeg -v error -display_rotation 90 -i "$H/Film/quer.mp4" -c copy -y "$H/Film/hoch.mov"
  rm "$H/Film/quer.mp4"
  video_freigeben "$H/Film/hoch.mov"
  echo j | ff video run --profil sparsam --auf 720p > /dev/null
  pruefe "kodiert und geprüft" gleich "$(video_status "$H/Film/hoch.mov")" fertig
  pruefe "kurze Seite auf 720, hochkant bleibt hochkant" \
    gleich "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$H/Film/hoch.mp4" 2>/dev/null)" "720,1280"
}

# Die Schaetzung rechnete mit der Hoehe aus der Liste. Ein hochkant
# gespeichertes Video schrumpfte dort auf ein Drittel der Bildpunkte eines
# gleich grossen querformatigen -- die Auswahl nannte zu kleine Zahlen.
test_video_schaetzung_hochkant() {
  sandbox
  local quer hoch
  printf 'go\t%s\tnein\th264\t1920\t1080\t30\t60\t999999\t999999\t0.5\tlohnt\t0\t0\n' "$H/q.mp4" > "$D/video-kandidaten.tsv"
  quer="$(echo n | ff video run --profil sparsam --auf 720p | grep 'etwa')"
  printf 'go\t%s\tnein\th264\t1080\t1920\t30\t60\t999999\t999999\t0.5\tlohnt\t0\t0\n' "$H/h.mp4" > "$D/video-kandidaten.tsv"
  hoch="$(echo n | ff video run --profil sparsam --auf 720p | grep 'etwa')"
  pruefe "hochkant und quer werden gleich geschätzt" gleich "$hoch" "$quer"
}

# Pakete ohne eigene Endung: Git-Repositories und Geraete-Backups. Eine
# einzelne Packdatei oder Backup-Datei zu verschieben macht das Ganze kaputt.
test_scan_git_und_backup_als_ganzes() {
  sandbox
  local git="$H/Projekt/.git" bak="$H/Library/Application Support/MobileSync/Backup/0000-ABC"
  mkdir -p "$git/objects/pack" "$bak/3f"
  dd if=/dev/zero of="$git/objects/pack/pack-abc.pack" bs=1m count=210 2>/dev/null
  dd if=/dev/zero of="$bak/3f/3f9a1c" bs=1m count=210 2>/dev/null
  ff scan > /dev/null
  pruefe "keine Packdatei einzeln" nicht grep -q 'pack-abc.pack' "$D/kandidaten.tsv"
  pruefe "keine Backup-Datei einzeln" nicht grep -q '3f9a1c' "$D/kandidaten.tsv"
  pruefe "Repository als Ganzes unter gross" gleich "$(status_von "$git")" neu
  pruefe "Backup als Ganzes unter gross" gleich "$(status_von "$bak")" neu
}

# Gegenstueck in apply, fuer Listen aus einem frueheren scan
test_apply_git_und_backup_inhalt_geschuetzt() {
  sandbox
  local pack="$H/Projekt/.git/objects/pack/pack-abc.pack"
  local datei="$H/Library/Application Support/MobileSync/Backup/0000-ABC/3f/3f9a1c"
  mkdir -p "$(dirname "$pack")" "$(dirname "$datei")"
  echo x > "$pack"; echo x > "$datei"
  kandidat go gross 300 "$pack"
  kandidat go gross 300 "$datei"
  echo j | ff apply > /dev/null
  pruefe "Packdatei bleibt" test -f "$pack"
  pruefe "Backup-Datei bleibt" test -f "$datei"
}

# Das Original wanderte ins Fegefeuer, die Manifestzeile kam aber erst, als
# auch die neue Fassung lag. Endete das Skript dazwischen, lag das Original
# ohne Eintrag im Stapel: restore fand es nicht, purge loeschte es.
# Ein mv, das beim Ablegen der neuen Fassung das Skript beendet, stellt das nach.
test_video_run_abbruch_nach_sicherung() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/a.mp4"
  video_freigeben "$H/Film/a.mp4"
  local bin="$WURZEL/$aktuell/bin"
  mkdir -p "$bin"
  cat > "$bin/mv" <<'MV'
#!/bin/bash
case "$1" in */video_arbeit/neu.mp4) kill -9 "$PPID"; exit 1;; esac
exec /bin/mv "$@"
MV
  chmod +x "$bin/mv"
  # Die Meldung der Shell ueber den beendeten Prozess ist hier gewollt
  { echo j | PATH="$bin:$PATH" ff video run --profil sparsam; } > /dev/null 2>&1
  local s; s="$(stapel)"
  pruefe "Original liegt im Stapel" test -f "$Q/$s/Film/a.mp4"
  pruefe "und steht im Manifest" grep -q "$H/Film/a.mp4" "$Q/$s/_manifest.tsv"
  ff restore "$s" > /dev/null
  pruefe "restore bringt es zurück" test -f "$H/Film/a.mp4"
}

# Gegenprobe zum frueh geschriebenen Manifest: Laesst sich die neue Fassung
# nicht ablegen, kommt das Original zurueck -- und sein Eintrag muss wieder
# verschwinden, sonst stuende ein "ersetzt" ohne Datei im Stapel.
test_video_run_ablegen_misslingt() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/a.mp4"
  video_freigeben "$H/Film/a.mp4"
  local bin="$WURZEL/$aktuell/bin"
  mkdir -p "$bin"
  cat > "$bin/mv" <<'MV'
#!/bin/bash
case "$1" in */video_arbeit/neu.mp4) exit 1;; esac
exec /bin/mv "$@"
MV
  chmod +x "$bin/mv"
  local ausgabe; ausgabe="$(echo j | PATH="$bin:$PATH" ff video run --profil sparsam)"
  pruefe "meldet den Fehler" enthaelt "$ausgabe" "neue Fassung liess sich nicht ablegen"
  pruefe "Original wieder am Platz" test -f "$H/Film/a.mp4"
  pruefe "kein Stapel übrig" gleich "$(stapel)" ""
}

# Kameras wie GoPro legen eine Timecode-Spur an, die auf Bild und Ton
# verweist. ffprobe ab Version 8 zeigt das als Stream-Gruppe und fuehrt die
# Tonspur darin ein zweites Mal auf, dazu eine Leerzeile. Die Pruefung zaehlte
# Zeilen und lehnte ab: "Tonspur fehlt (2 statt 3)" -- bei je einer Tonspur.
# Eine solche Datei laesst sich mit ffmpeg nicht erzeugen. Ein vorgeschaltetes
# ffprobe gibt deshalb fuer das Original aus, was ffprobe 9 bei einer echten
# GoPro-Datei ausgibt: die Tonspur in der Gruppe, eine Leerzeile, die Tonspur.
test_video_timecode_spur() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/gopro.mov"
  video_freigeben "$H/Film/gopro.mov"
  local bin="$WURZEL/$aktuell/bin" echt; echt="$(command -v ffprobe)"
  mkdir -p "$bin"
  cat > "$bin/ffprobe" <<FFPROBE
#!/bin/bash
ausgabe="\$("$echt" "\$@")"
case "\$*" in
  *"-select_streams a"*gopro.mov*) printf '%s\n\n' "\$(printf '%s\n' "\$ausgabe" | grep .)";;
esac
printf '%s\n' "\$ausgabe"
FFPROBE
  chmod +x "$bin/ffprobe"
  local ausgabe; ausgabe="$(echo j | PATH="$bin:$PATH" ff video run --profil sparsam)"
  pruefe "keine falsche Tonspur-Meldung" nicht enthaelt "$ausgabe" "Tonspur fehlt"
  pruefe "kodiert und geprüft" gleich "$(video_status "$H/Film/gopro.mov")" fertig
}

# Stapel aus aelteren Versionen haben keine Kategorie im Manifest. pruefen
# fuehrte ihre wieder aufgetauchten Eintraege unter "kein Cache" -- auch den
# Homebrew-Cache. Die Kategorie ist aber unbekannt, nicht "kein Cache".
test_pruefen_ohne_kategorie() {
  sandbox
  local s="$Q/2026-01-01_120000"
  mkdir -p "$s/Library/Caches/Homebrew" "$H/Library/Caches/Homebrew"
  printf 'Library/Caches/Homebrew\t%s\t4000\tverschoben\n' "$H/Library/Caches/Homebrew" > "$s/_manifest.tsv"
  local ausgabe; ausgabe="$(ff pruefen)"
  pruefe "nennt die unbekannte Kategorie" enthaelt "$ausgabe" "Kategorie unbekannt"
  pruefe "nicht unter kein Cache" nicht enthaelt "$ausgabe" "kein Cache"
  ausgabe="$(echo n | ff purge --wieder-da)"
  pruefe "purge --wieder-da nennt sie ohne Kategorie" enthaelt "$ausgabe" "ohne Kategorie"
  pruefe "und nicht als keine Caches" nicht enthaelt "$ausgabe" "keine Caches"
  pruefe "und lässt sie liegen" test -d "$s/Library/Caches/Homebrew"
}

# Ein Stapel ohne Eintraege bleibt etwa nach einem Abbruch zurueck. pruefen
# zeigte fuer ihn eine leere Ueberschrift.
test_pruefen_leerer_stapel() {
  sandbox
  mkdir -p "$Q/2026-01-01_120000"
  : > "$Q/2026-01-01_120000/_manifest.tsv"
  local ausgabe; ausgabe="$(ff pruefen)"
  pruefe "kein leerer Stapel in der Ausgabe" nicht enthaelt "$ausgabe" "2026-01-01_120000"
}

# video run legte den Stapel vor dem ersten Video an. Endete der Lauf, bevor
# ein Original gesichert war -- Strg-C beim Kodieren --, blieb er leer liegen.
# Ein ffmpeg, das beim Kodieren das Skript beendet, stellt das nach.
test_video_run_abbruch_ohne_stapel() {
  sandbox
  hat_ffmpeg || { ueberspringen "kein ffmpeg"; return 0; }
  mkdir -p "$H/Film"
  testvideo "$H/Film/a.mp4"
  video_freigeben "$H/Film/a.mp4"
  local bin="$WURZEL/$aktuell/bin" echt; echt="$(command -v ffmpeg)"
  mkdir -p "$bin"
  cat > "$bin/ffmpeg" <<FFMPEG
#!/bin/bash
case "\$*" in *-progress*) kill -9 "\$PPID"; exit 1;; esac
exec "$echt" "\$@"
FFMPEG
  chmod +x "$bin/ffmpeg"
  { echo j | PATH="$bin:$PATH" ff video run --profil sparsam; } > /dev/null 2>&1
  pruefe "kein leerer Stapel" gleich "$(ls "$Q" 2>/dev/null)" ""
  pruefe "Original am Platz" test -f "$H/Film/a.mp4"
}

# purge --wieder-da laesst die Originale neu kodierter Videos aus, das
# gewoehnliche purge loeschte sie mit, ohne sie zu erwaehnen.
test_purge_nennt_videooriginale() {
  sandbox
  local s="$Q/2026-01-01_120000"
  mkdir -p "$s/Film"
  echo alt > "$s/Film/a.mov"
  printf 'Film/a.mov\t%s\t5000\tersetzt\tvideo\n' "$H/Film/a.mov" > "$s/_manifest.tsv"
  touch -t 202601011200 "$s"
  local ausgabe; ausgabe="$(echo n | ff purge)"
  pruefe "purge nennt die Videooriginale" enthaelt "$ausgabe" "das Original eines neu kodierten Videos"
  pruefe "nach Nein bleibt der Stapel" test -f "$s/Film/a.mov"
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
