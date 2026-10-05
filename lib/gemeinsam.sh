# lib/gemeinsam.sh -- Ausgabe, Umgebungspruefung, Fortschrittsanzeige und Tastenbelegung --
# was alle Befehle brauchen.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- Ausgabe ----------
rot=$'\033[31m'; gruen=$'\033[32m'; gelb=$'\033[33m'; blau=$'\033[34m'
fett=$'\033[1m'; grau=$'\033[90m'; aus=$'\033[0m'
info() { printf '%b\n' "$*"; }
titel() { printf '\n%b%b%b\n' "$fett$blau" "$*" "$aus"; }
warn() { printf '%s! %s%s\n' "$gelb" "$*" "$aus" >&2; }
fehler() { printf '%sFehler: %s%s\n' "$rot" "$*" "$aus" >&2; }

mb() { awk -v k="${1:-0}" 'BEGIN{ if (k>=1048576) printf "%.1f GB", k/1048576; else if (k>=1024) printf "%.0f MB", k/1024; else printf "%d KB", k }'; }

# ---------- Umgebung ----------
# Lieber sofort klar scheitern als mitten im Lauf.
pruefe_umgebung() {
  local fehlt=""
  if [ "$(uname -s)" != "Darwin" ]; then
    fehler "Dieses Skript ist für macOS gebaut (Library-Aufbau, mdfind, stat -f)."
    return 1
  fi
  local b
  for b in awk sed sort cut wc find xargs shasum du stat mv mkdir basename dirname mdfind; do
    command -v "$b" >/dev/null 2>&1 || fehlt="$fehlt $b"
  done
  if [ -n "$fehlt" ]; then
    fehler "Fehlende Werkzeuge:$fehlt"
    return 1
  fi
  return 0
}

# ---------- Fortschritt ----------
# Eine Zeile, die sich selbst ueberschreibt. Nur am Terminal -- in einer
# Pipeline oder einem Logfile waere das nur Rauschen.
FORTSCHRITT_BEGINN=0
FORTSCHRITT_LETZTE=0

# FEGEFEUER_FORTSCHRITT: 1 erzwingt die Anzeige, 0 schaltet sie ab,
# ohne Angabe entscheidet, ob die Ausgabe an einem Terminal haengt.
fortschritt_sichtbar() {
  case "${FEGEFEUER_FORTSCHRITT:-}" in
    1) return 0;;
    0) return 1;;
    *) [ -t 2 ];;
  esac
}

wiederhole() {   # wiederhole <anzahl> <zeichen>
  local n="$1" z="$2" ergebnis=""
  while [ "$n" -gt 0 ]; do ergebnis="$ergebnis$z"; n=$((n - 1)); done
  printf '%s' "$ergebnis"
}

fortschritt_start() { FORTSCHRITT_BEGINN="$(date +%s)"; FORTSCHRITT_LETZTE=0; }

fortschritt() {   # fortschritt <fertig> <gesamt> <text>
  fortschritt_sichtbar || return 0
  local fertig="$1" gesamt="$2" text="$3"
  [ "${gesamt:-0}" -gt 0 ] || return 0
  # Hoechstens einmal je Sekunde neu zeichnen, ausser beim letzten Schritt
  local jetzt; jetzt="$(date +%s)"
  if [ "$jetzt" = "$FORTSCHRITT_LETZTE" ] && [ "$fertig" -lt "$gesamt" ]; then return 0; fi
  FORTSCHRITT_LETZTE="$jetzt"

  local breite=22 voll anteil verstrichen rest=""
  [ "$fertig" -gt "$gesamt" ] && fertig="$gesamt"
  anteil=$(( fertig * 100 / gesamt ))
  voll=$(( fertig * breite / gesamt ))
  verstrichen=$(( jetzt - FORTSCHRITT_BEGINN ))
  if [ "$fertig" -gt 0 ] && [ "$verstrichen" -gt 3 ] && [ "$fertig" -lt "$gesamt" ]; then
    local uebrig=$(( verstrichen * gesamt / fertig - verstrichen ))
    [ "$uebrig" -gt 0 ] && rest="$(printf '  noch %d:%02d' $((uebrig / 60)) $((uebrig % 60)))"
  fi
  printf '\r  %s%s%s%s  %3d%%  %s%s%s\033[K' \
    "$blau" "$(wiederhole "$voll" '█')" "$(wiederhole $((breite - voll)) '░')" "$aus" \
    "$anteil" "$grau" "$text$rest" "$aus" >&2
}

fortschritt_offen() {   # wenn die Gesamtzahl nicht bekannt ist
  fortschritt_sichtbar || return 0
  local jetzt; jetzt="$(date +%s)"
  if [ "$jetzt" = "$FORTSCHRITT_LETZTE" ]; then return 0; fi
  FORTSCHRITT_LETZTE="$jetzt"
  printf '\r  %s%s%s\033[K' "$grau" "$1" "$aus" >&2
}

fortschritt_ende() { fortschritt_sichtbar && printf '\r\033[K' >&2; return 0; }

# Tastenbelegung an genau einer Stelle, damit sie am Prompt und in der
# Fehlermeldung nicht auseinanderlaufen. Sie steht bei jeder Frage -- wer
# 150 Dubletten durchgeht, soll nicht raten muessen, was gerade moeglich ist.
# Schreibt die uebergebenen Zeilen in eine Datei -- oder leert sie, wenn keine
# kommen. printf '%s\n' ohne Argumente schriebe eine Leerzeile.
# Aufruf mit einem Array unter set -u: zeilen_schreiben <datei> "${a[@]+"${a[@]}"}"
zeilen_schreiben() {   # zeilen_schreiben <datei> [zeile ...]
  local datei="$1"; shift
  if [ "$#" -eq 0 ]; then : > "$datei"; else printf '%s\n' "$@" > "$datei"; fi
}

TASTEN_ZULETZT=""
tasten() {   # tasten <einzug> <taste:bedeutung> ...
  local einzug="$1"; shift
  local zeile="" paar trenner="" kurz=""
  for paar in "$@"; do
    zeile="$zeile$trenner${fett}${paar%%:*}${aus}=${grau}${paar#*:}${aus}"
    kurz="$kurz${kurz:+ / }${paar%%:*}"
    trenner="  "
  done
  TASTEN_ZULETZT="$kurz"
  printf '%s%s\n' "$einzug" "$zeile"
}

# Hinweis nach einer ungueltigen Eingabe, gebildet aus den Tasten der zuletzt
# gezeigten Legende. Frueher stand er als eigener Text daneben -- eine neue
# Taste haette man an zwei Stellen eintragen muessen.
tasten_bitte() {   # tasten_bitte <einzug>
  printf '%s%sBitte %s%s\n' "$1" "$gelb" "$TASTEN_ZULETZT" "$aus"
}
