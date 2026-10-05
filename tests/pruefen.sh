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
bestanden=0 gescheitert=0 aktuell=""

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

# ---------- Ablauf ----------

filter="${1:-}"
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  case "$t" in *"$filter"*) ;; *) continue;; esac
  aktuell="${t#test_}"
  "$t"
done

echo
if [ "$gescheitert" -eq 0 ]; then
  echo "$bestanden Prüfungen bestanden"
else
  echo "$bestanden bestanden, $gescheitert gescheitert"
  exit 1
fi
