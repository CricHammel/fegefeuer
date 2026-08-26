#!/usr/bin/env bash
#
# fegefeuer.sh — Festplatte aufräumen mit Sicherheitsnetz
#
# Nichts wird direkt gelöscht. Alles wandert zuerst ins Fegefeuer und harrt
# dort aus: "restore" erlöst, "purge" spricht das endgültige Urteil.
#
set -uo pipefail
IFS=$'\n\t'

BASIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARANTAENE="$HOME/.fegefeuer"
# Frueher hiess das Verzeichnis anders. Wer eine alte Quarantaene aus einem
# Backup zurueckspielt, soll sie nicht verlieren.
QUARANTAENE_ALT="$HOME/.aufraeumen-quarantaene"
KANDIDATEN="$BASIS/kandidaten.tsv"
BERICHT="$BASIS/bericht.md"
ARBEIT="$BASIS/.arbeit"

mkdir -p "$ARBEIT"
TILDE="~"

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

# ---------- Schutzliste ----------
# Diese Pfade werden NIE angefasst, egal was in der Kandidatenliste steht.
ist_geschuetzt() {
  local p="$1"
  case "$p" in
    "$HOME"/Library/Keychains*|\
    "$HOME"/Library/Mail*|\
    "$HOME"/Library/Messages*|\
    "$HOME"/Library/Mobile\ Documents*|\
    "$HOME"/Pictures/*.photoslibrary*|\
    "$HOME"/Library/Application\ Support/AddressBook*|\
    "$HOME"/Library/Group\ Containers/group.com.apple.notes*|\
    "$HOME"/Library/Containers/com.apple.mail*|\
    "$HOME"/.ssh*|\
    "$HOME"/.gnupg*|\
    "$HOME"/Library/Preferences/ByHost*|\
    "$HOME"/Library/Metadata*|\
    "$HOME"/Library/Group\ Containers/UBF8T346G9.*|\
    *OneDrive*|\
    *.noindex/*|\
    "$HOME"/*.7z|\
    "$HOME") return 0;;
  esac
  # Nie außerhalb des Home löschen
  case "$p" in
    "$HOME"/*) ;;
    *) return 0;;
  esac
  return 1
}

# ---------- App installiert? ----------
app_existiert() {
  mdfind "kMDItemCFBundleIdentifier == '$1'c" 2>/dev/null | grep -qiE '\.(app|appex)$'
}

status_setzen() {   # status_setzen <zeile> <neuer-status>
  printf '%s' "$1" | awk -F'\t' -v OFS='\t' -v st="$2" '{ $1=st; print }'
}

# Gruppenschluessel (Spalte 7) und lesbares Etikett (Spalte 8) vergeben
gruppen_zuordnen() {
  local awkdatei="$BASIS/gruppen.awk"
  [ -f "$awkdatei" ] || { warn "Gruppendefinition fehlt, ueberspringe Gruppierung."; return 0; }
  awk -f "$awkdatei" "$KANDIDATEN" "$KANDIDATEN" > "$KANDIDATEN.grp" \
    && mv "$KANDIDATEN.grp" "$KANDIDATEN"
}

schreibe_kandidaten() {
  if [ "$#" -eq 0 ]; then : > "$KANDIDATEN"; else printf '%s\n' "$@" > "$KANDIDATEN"; fi
}

kandidat_schreiben() {
  # kategorie, groesse_kb, mtime, pfad, begruendung
  printf 'neu\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$KANDIDATEN.tmp"
}

# ---------- scan ----------
befehl_scan() {
  : > "$KANDIDATEN.tmp"
  titel "1/5  Verwaiste App-Reste in ~/Library"
  local -a ordnerliste=("Application Support" "Caches" "Containers" "Group Containers" \
                        "Saved Application State" "HTTPStorages" "WebKit" "Application Scripts" "Logs")
  # Erst zaehlen, damit der Balken einen Bezugspunkt hat
  local zu_pruefen=0 o
  for o in "${ordnerliste[@]}"; do
    [ -d "$HOME/Library/$o" ] && zu_pruefen=$(( zu_pruefen + $(ls -1 "$HOME/Library/$o" 2>/dev/null | wc -l) ))
  done
  fortschritt_start
  local geprueft=0 gefunden=0 gesehen=0
  for ordner in "${ordnerliste[@]}"; do
    local voll="$HOME/Library/$ordner"
    [ -d "$voll" ] || continue
    for e in "$voll"/*; do
      [ -e "$e" ] || continue
      gesehen=$((gesehen + 1))
      fortschritt "$gesehen" "$zu_pruefen" "Library-Ordner gegen installierte Apps prüfen"
      local b; b="$(basename "$e")"
      case "$b" in com.apple.*|group.com.apple.*|.DS_Store) continue;; esac
      ist_geschuetzt "$e" && continue
      local id="$b"
      id="${id%.savedState}"; id="${id%.binarycookies}"
      id="$(printf '%s' "$id" | sed -E 's/^[A-Z0-9]{10}\.//; s/^group\.//')"
      case "$id" in com.apple.*) continue;; *.*) ;; *) continue;; esac
      geprueft=$((geprueft+1))
      local treffer="" probe="$id"
      while [ -n "$probe" ]; do
        if app_existiert "$probe"; then treffer="$probe"; break; fi
        case "$probe" in *.*) probe="${probe%.*}";; *) break;; esac
        case "$probe" in com|org|net|io|de|app|group|dk|ch|us|ai|me|co|eu) break;; esac
      done
      if [ -z "$treffer" ]; then
        gefunden=$((gefunden+1))
        kandidat_schreiben "app-rest" \
          "$(du -sk -x "$e" 2>/dev/null | cut -f1)" \
          "$(stat -f '%Sm' -t '%Y-%m-%d' "$e" 2>/dev/null)" \
          "$e" "keine App mit Bundle-ID '$id' installiert"
      fi
    done
  done
  fortschritt_ende
  info "  $geprueft geprüft, ${fett}$gefunden${aus} ohne zugehörige App"

  titel "2/5  Caches, die sich selbst neu aufbauen"
  local caches=(
    "$HOME/Library/Caches/ms-playwright|Playwright-Browser, werden bei Bedarf neu geladen"
    "$HOME/Library/Caches/Homebrew|Homebrew-Downloadcache"
    "$HOME/Library/Caches/tealdeer|tldr-Seiten, laden sich neu"
    "$HOME/.cache|allgemeiner Cache"
    "$HOME/Library/Caches/com.apple.cache_delete|macOS gibt das selbst frei"
  )
  for eintrag in "${caches[@]}"; do
    local p="${eintrag%%|*}" grund="${eintrag#*|}"
    [ -e "$p" ] || continue
    ist_geschuetzt "$p" && continue
    kandidat_schreiben "cache" \
      "$(du -sk -x "$p" 2>/dev/null | cut -f1)" \
      "$(stat -f '%Sm' -t '%Y-%m-%d' "$p" 2>/dev/null)" \
      "$p" "$grund"
  done
  info "  ${fett}$(( ${#caches[@]} ))${aus} Cache-Orte geprüft"

  titel "3/5  Alte Toolchain-Versionen"
  # node: alle außer der neuesten
  if [ -d "$HOME/.nvm/versions/node" ]; then
    local aktuell
    aktuell="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    for v in "$HOME/.nvm/versions/node"/*; do
      [ -d "$v" ] || continue
      [ "$(basename "$v")" = "$aktuell" ] && continue
      kandidat_schreiben "toolchain" \
        "$(du -sk -x "$v" 2>/dev/null | cut -f1)" \
        "$(stat -f '%Sm' -t '%Y-%m-%d' "$v" 2>/dev/null)" \
        "$v" "alte Node-Version (aktuell: $aktuell)"
    done
  fi
  # playwright: alte Browser-Builds
  if [ -d "$HOME/Library/Caches/ms-playwright" ]; then
    for familie in chromium chromium_headless_shell firefox webkit; do
      local neueste
      neueste="$(ls -1d "$HOME/Library/Caches/ms-playwright/$familie"-* 2>/dev/null | sort -V | tail -1)"
      for b in "$HOME/Library/Caches/ms-playwright/$familie"-*; do
        [ -d "$b" ] || continue
        [ "$b" = "$neueste" ] && continue
        kandidat_schreiben "toolchain" \
          "$(du -sk -x "$b" 2>/dev/null | cut -f1)" \
          "$(stat -f '%Sm' -t '%Y-%m-%d' "$b" 2>/dev/null)" \
          "$b" "alter Playwright-Build (neuester: $(basename "$neueste"))"
      done
    done
  fi
  info "  fertig"

  titel "4/5  Große Dateien (>200 MB)"
  fortschritt_start
  local n=0 durchsucht=0
  while IFS= read -r -d '' f; do
    durchsucht=$((durchsucht + 1))
    fortschritt_offen "durchsuche … $durchsucht Treffer geprüft"
    ist_geschuetzt "$f" && continue
    kandidat_schreiben "gross" \
      "$(du -sk "$f" 2>/dev/null | cut -f1)" \
      "$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)" \
      "$f" "große Einzeldatei — bitte einzeln prüfen"
    n=$((n+1))
  done < <(find "$HOME" -type f -size +200M \
             ! -path "*/Library/Mobile Documents/*" \
             ! -path "*/.photoslibrary/*" -print0 2>/dev/null)
  fortschritt_ende
  info "  ${fett}$n${aus} gefunden"

  titel "5/5  Doppelte Dateien (>1 MB, gleicher Inhalt)"
  local hashdatei="$ARBEIT/hashes.tsv"
  local dateiliste="$ARBEIT/hash_liste.txt"
  local rohhashes="$ARBEIT/hash_roh.txt"
  # ~/Library bleibt komplett aussen vor: dort liegen Systemindex und
  # OneDrive-Sync -- gleiche Inhalte sind da gewollt bzw. serverseitig.
  fortschritt_start
  fortschritt_offen "Dateien sammeln …"
  find "$HOME" -type f -size +1M \
    ! -path "$HOME/Library/*" ! -path "*/.Trash/*" ! -path "*/node_modules/*" \
    ! -path "*/.git/*" ! -path "*/.nvm/*" ! -path "*/.pyenv/*" ! -path "*/.m2/*" \
    ! -path "*/.cargo/*" ! -path "*/.photoslibrary/*" \
    -print0 2>/dev/null > "$dateiliste"
  local zu_hashen
  zu_hashen="$(tr -dc '\0' < "$dateiliste" | wc -c | tr -d ' ')"
  fortschritt_ende
  info "  ${grau}$zu_hashen Dateien werden geprüft${aus}"

  : > "$rohhashes"
  fortschritt_start
  xargs -0 -P 8 -n 200 shasum -a 1 < "$dateiliste" > "$rohhashes" 2>/dev/null &
  local hash_pid=$!
  while kill -0 "$hash_pid" 2>/dev/null; do
    fortschritt "$(wc -l < "$rohhashes" | tr -d ' ')" "$zu_hashen" "Prüfsummen berechnen"
    sleep 1
  done
  wait "$hash_pid" 2>/dev/null
  fortschritt "$zu_hashen" "$zu_hashen" "Prüfsummen berechnen"
  fortschritt_ende

  awk '{ print substr($0,1,40) "\t" substr($0,43) }' "$rohhashes" | sort > "$hashdatei"
  rm -f "$dateiliste" "$rohhashes"

  # Pro Gruppe bleibt die erste Datei unangetastet, die weiteren werden
  # vorgeschlagen -- welche Kopie wirklich weg soll, entscheidest du im review.
  local dubletten=0 h p original
  while IFS=$'\t' read -r h p original; do
    ist_geschuetzt "$p" && continue
    [ -e "$p" ] || continue
    kandidat_schreiben "dublette" \
      "$(du -sk "$p" 2>/dev/null | cut -f1)" \
      "$(stat -f '%Sm' -t '%Y-%m-%d' "$p" 2>/dev/null)" \
      "$p" "gleicher Inhalt wie ${original/#$HOME/$TILDE}"
    dubletten=$((dubletten + 1))
  done < <(awk -F'\t' '{ if ($1==letzter) print $0 "\t" ersterpfad; else { letzter=$1; ersterpfad=$2 } }' "$hashdatei")
  info "  ${fett}$dubletten${aus} ueberzaehlige Kopien"

  # Bestehende keep/go-Entscheidungen übernehmen
  if [ -s "$KANDIDATEN" ]; then
    # FILENAME statt NR==FNR: bei leerer erster Datei wuerde NR==FNR auf jede
    # Zeile der zweiten zutreffen und den gesamten neuen Scan verschlucken.
    awk -F'\t' -v OFS='\t' '
        FILENAME==ARGV[1] { if ($1!="neu") status[$5]=$1; next }
        { if ($5 in status) $1=status[$5]; print }' \
        "$KANDIDATEN" "$KANDIDATEN.tmp" > "$KANDIDATEN.neu"
    mv "$KANDIDATEN.neu" "$KANDIDATEN"
    rm -f "$KANDIDATEN.tmp"
    info "\n${grau}Frühere Entscheidungen wurden übernommen.${aus}"
  else
    mv "$KANDIDATEN.tmp" "$KANDIDATEN"
  fi
  sort -t$'\t' -k2,2 -k3,3nr "$KANDIDATEN" -o "$KANDIDATEN"
  gruppen_zuordnen

  bericht_schreiben
  titel "Ergebnis"
  info "  Kandidaten: $(wc -l < "$KANDIDATEN" | tr -d ' ')"
  info "  Gesamt:     $(awk -F'\t' '{s+=$3} END{print s}' "$KANDIDATEN" | { read -r k; mb "$k"; })"
  info "\n  Bericht:  $BERICHT"
  info "  Weiter:   ${fett}$0 review${aus}"
}

bericht_schreiben() {
  {
    echo "# Aufräum-Bericht"
    echo
    echo "Erstellt: $(date '+%d.%m.%Y %H:%M')"
    echo
    echo "| Kategorie | Einträge | Platz |"
    echo "|---|---:|---:|"
    awk -F'\t' '{n[$2]++; s[$2]+=$3} END{for (k in n) printf "%s\t%d\t%d\n", k, n[k], s[k]}' "$KANDIDATEN" \
      | sort -t$'\t' -k3,3nr \
      | while IFS=$'\t' read -r kat anz kb; do
          echo "| $kat | $anz | $(mb "$kb") |"
        done
    echo
    for kat in app-rest cache toolchain gross dublette; do
      local zeilen; zeilen="$(awk -F'\t' -v k="$kat" '$2==k' "$KANDIDATEN")"
      [ -z "$zeilen" ] && continue
      echo "## $kat"
      echo
      echo "| Größe | Geändert | Pfad | Grund |"
      echo "|---:|---|---|---|"
      printf '%s\n' "$zeilen" | sort -t$'\t' -k3,3nr | head -40 \
        | while IFS=$'\t' read -r st kt kb mt pfad grund grp etikett; do
            echo "| $(mb "$kb") | $mt | \`${pfad/#$HOME/$TILDE}\` | $grund |"
          done
      echo
    done
  } > "$BERICHT"
}

# ---------- review ----------
# Eintraege desselben Programms liegen ueber viele Library-Ordner verstreut.
# Sie werden zu einer Gruppe zusammengefasst und gemeinsam entschieden.
R_PUFFER=()
R_AUSGABE=()
R_ABBRUCH=0
R_NR=0
R_GESAMT=0

r_einzeln_fragen() {   # r_einzeln_fragen <zeile>  -> Antwort in R_ANTWORT
  local zeile="$1"
  local st kt kb mt pfad grund rest
  st="$(printf '%s' "$zeile" | cut -f1)"
  kb="$(printf '%s' "$zeile" | cut -f3)"
  mt="$(printf '%s' "$zeile" | cut -f4)"
  pfad="$(printf '%s' "$zeile" | cut -f5)"
  grund="$(printf '%s' "$zeile" | cut -f6)"
  printf '    %s%9s%s  %s\n' "$fett" "$(mb "$kb")" "$aus" "${pfad/#$HOME/$TILDE}"
  printf '    %s%s · %s%s\n' "$grau" "$grund" "$mt" "$aus"
  local antwort
  while true; do
    printf '    → '
    read -r antwort || antwort=q
    case "$antwort" in
      j|J|n|N|s|S|q|Q) R_ANTWORT="$antwort"; return 0;;
      "") R_ANTWORT=s; return 0;;
      o|O) open -R "$pfad" 2>/dev/null;;
      *) printf '    %sBitte j / n / o / s / q%s\n' "$gelb" "$aus";;
    esac
  done
}

r_gruppe_abschliessen() {
  local anzahl=${#R_PUFFER[@]}
  [ "$anzahl" -eq 0 ] && return 0
  local zeile st

  # Nach einem Abbruch nur noch unveraendert durchreichen
  if [ "$R_ABBRUCH" -eq 1 ]; then
    for zeile in "${R_PUFFER[@]}"; do R_AUSGABE+=("$zeile"); done
    return 0
  fi

  # Bereits entschiedene Eintraege bleiben unangetastet -- eine Gruppenantwort
  # wirkt ausschliesslich auf das, was noch offen ist.
  local -a offen=()
  local entschieden=0 offen_kb=0 kb
  for zeile in "${R_PUFFER[@]}"; do
    st="$(printf '%s' "$zeile" | cut -f1)"
    if [ "$st" = "neu" ]; then
      offen+=("$zeile")
      kb="$(printf '%s' "$zeile" | cut -f3)"
      offen_kb=$((offen_kb + kb))
    else
      entschieden=$((entschieden + 1))
      R_AUSGABE+=("$zeile")
    fi
  done
  local n_offen=${#offen[@]}
  [ "$n_offen" -eq 0 ] && return 0

  R_NR=$((R_NR + 1))
  local etikett grund1 pfad1 mt1
  etikett="$(printf '%s' "${offen[0]}" | cut -f8)"
  grund1="$(printf '%s' "${offen[0]}" | cut -f6)"
  pfad1="$(printf '%s' "${offen[0]}" | cut -f5)"
  mt1="$(printf '%s' "${offen[0]}" | cut -f4)"
  [ -n "$etikett" ] || etikett="$(basename "$pfad1")"

  # --- nur ein offener Eintrag: schlichte Ansicht ---
  if [ "$n_offen" -eq 1 ]; then
    printf '\n%s[%d/%d]%s %s%s%s\n' "$grau" "$R_NR" "$R_GESAMT" "$aus" "$fett" "$(mb "$offen_kb")" "$aus"
    printf '  %s\n' "${pfad1/#$HOME/$TILDE}"
    printf '  %s%s · geändert %s%s\n' "$grau" "$grund1" "$mt1" "$aus"
    if [ -d "$pfad1" ]; then
      printf '  %sInhalt: %s%s\n' "$grau" "$(ls -1 "$pfad1" 2>/dev/null | head -4 | tr '\n' ' ')" "$aus"
    fi
    [ "$entschieden" -gt 0 ] && printf '  %s(%d weitere Einträge dieser Gruppe hast du schon entschieden)%s\n' "$grau" "$entschieden" "$aus"
    local antwort
    while true; do
      printf '  → '
      read -r antwort || antwort=q
      case "$antwort" in
        j|J) R_AUSGABE+=("$(status_setzen "${offen[0]}" go)"); return 0;;
        n|N) R_AUSGABE+=("$(status_setzen "${offen[0]}" keep)"); return 0;;
        o|O) open -R "$pfad1" 2>/dev/null;;
        s|S|"") R_AUSGABE+=("${offen[0]}"); return 0;;
        q|Q) R_ABBRUCH=1; R_AUSGABE+=("${offen[0]}"); return 0;;
        *) printf '  %sBitte j / n / o / s / q%s\n' "$gelb" "$aus";;
      esac
    done
  fi

  # --- Gruppe: alle offenen Fundorte auf einen Blick ---
  printf '\n%s[%d/%d]%s %s%s%s %s— %d Einträge, %s%s\n' \
    "$grau" "$R_NR" "$R_GESAMT" "$aus" "$fett" "$etikett" "$aus" \
    "$grau" "$n_offen" "$(mb "$offen_kb")" "$aus"
  local gezeigt=0 pfad kurz mtime
  for zeile in "${offen[@]}"; do
    gezeigt=$((gezeigt + 1))
    if [ "$gezeigt" -gt 6 ]; then
      printf '  %s… und %d weitere%s\n' "$grau" "$((n_offen - 6))" "$aus"
      break
    fi
    kb="$(printf '%s' "$zeile" | cut -f3)"
    pfad="$(printf '%s' "$zeile" | cut -f5)"
    mtime="$(printf '%s' "$zeile" | cut -f4)"
    kurz="${pfad#$HOME/Library/}"
    printf '  %9s  %-56s %s%s%s\n' "$(mb "$kb")" "$kurz" "$grau" "$mtime" "$aus"
  done
  printf '  %s%s%s\n' "$grau" "$grund1" "$aus"
  [ "$entschieden" -gt 0 ] && printf '  %s(%d weitere Einträge dieser Gruppe hast du schon entschieden — die bleiben, wie sie sind)%s\n' "$grau" "$entschieden" "$aus"

  local antwort
  while true; do
    printf '  %sj%s=alle weg  %sn%s=alle behalten  %se%s=einzeln  %so%s=Finder  %ss%s=später  %sq%s=Ende\n' \
      "$fett" "$aus" "$fett" "$aus" "$fett" "$aus" "$fett" "$aus" "$fett" "$aus" "$fett" "$aus"
    printf '  → '
    read -r antwort || antwort=q
    case "$antwort" in
      j|J) for zeile in "${offen[@]}"; do R_AUSGABE+=("$(status_setzen "$zeile" go)"); done; return 0;;
      n|N) for zeile in "${offen[@]}"; do R_AUSGABE+=("$(status_setzen "$zeile" keep)"); done; return 0;;
      o|O) open -R "$pfad1" 2>/dev/null;;
      s|S|"") for zeile in "${offen[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
      q|Q) R_ABBRUCH=1; for zeile in "${offen[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
      e|E)
        printf '  %sGruppe %s einzeln:%s\n' "$grau" "$etikett" "$aus"
        for zeile in "${offen[@]}"; do
          if [ "$R_ABBRUCH" -eq 1 ]; then R_AUSGABE+=("$zeile"); continue; fi
          R_ANTWORT=""
          r_einzeln_fragen "$zeile"
          case "$R_ANTWORT" in
            j|J) R_AUSGABE+=("$(status_setzen "$zeile" go)");;
            n|N) R_AUSGABE+=("$(status_setzen "$zeile" keep)");;
            q|Q) R_ABBRUCH=1; R_AUSGABE+=("$zeile");;
            *)   R_AUSGABE+=("$zeile");;
          esac
        done
        return 0;;
      *) printf '  %sBitte j / n / e / o / s / q%s\n' "$gelb" "$aus";;
    esac
  done
}

befehl_review() {
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten. Erst '$0 scan' laufen lassen."; return 1; }
  # Aeltere Kandidatenlisten ohne Gruppenspalten nachruesten
  if [ "$(head -1 "$KANDIDATEN" | awk -F'\t' '{print NF}')" -lt 8 ]; then
    info "${grau}Ergänze Gruppenzuordnung …${aus}"
    gruppen_zuordnen
  fi

  local kat_filter="${1:-}"
  local gefiltert="$ARBEIT/review_teil.tsv"
  local rest="$ARBEIT/review_rest.tsv"
  if [ -n "$kat_filter" ]; then
    awk -F'\t' -v k="$kat_filter" '$2==k' "$KANDIDATEN" > "$gefiltert"
    awk -F'\t' -v k="$kat_filter" '$2!=k' "$KANDIDATEN" > "$rest"
    [ -s "$gefiltert" ] || { warn "Kategorie '$kat_filter' enthält nichts."; return 0; }
  else
    cp "$KANDIDATEN" "$gefiltert"
    : > "$rest"
  fi

  local sortiert="$ARBEIT/review_sortiert.tsv"
  # Nach Gruppengroesse absteigend: das Lohnende zuerst, Kleinkram zuletzt.
  # Nur offene Eintraege zaehlen fuer die Reihenfolge.
  awk -F'\t' 'NR==FNR { if ($1=="neu") summe[$7]+=$3; next } { print summe[$7]+0 "\t" $0 }' \
      "$gefiltert" "$gefiltert" \
    | sort -t$'\t' -k1,1nr -k8,8 -k4,4nr \
    | cut -f2- > "$sortiert"
  R_GESAMT="$(awk -F'\t' '$1=="neu"{print $7}' "$sortiert" | sort -u | wc -l | tr -d ' ')"
  [ "$R_GESAMT" -eq 0 ] && { info "Alles in dieser Auswahl ist bereits entschieden."; return 0; }

  info "\n${fett}Durchsicht${aus}  —  ${R_GESAMT} offene $([ "$R_GESAMT" -eq 1 ] && echo Gruppe || echo Gruppen)"
  info "${grau}Einträge desselben Programms sind zusammengefasst.${aus}"

  R_PUFFER=(); R_AUSGABE=(); R_ABBRUCH=0; R_NR=0
  local letzte="" zeile g
  while IFS= read -r zeile <&3; do
    g="$(printf '%s' "$zeile" | cut -f7)"
    if [ -n "$letzte" ] && [ "$g" != "$letzte" ]; then
      r_gruppe_abschliessen
      R_PUFFER=()
    fi
    letzte="$g"
    R_PUFFER+=("$zeile")
  done 3< "$sortiert"
  r_gruppe_abschliessen

  { printf '%s\n' "${R_AUSGABE[@]+"${R_AUSGABE[@]}"}" | grep -v '^$'; cat "$rest"; } \
    | sort -t$'\t' -k2,2 -k3,3nr > "$KANDIDATEN.tmp" && mv "$KANDIDATEN.tmp" "$KANDIDATEN"

  local zumweg
  zumweg="$(awk -F'\t' '$1=="go"{n++; s+=$3} END{printf "%d Einträge, ", n+0; print s+0}' "$KANDIDATEN")"
  local n_go="${zumweg%%,*}"
  local kb_go="${zumweg##* }"
  if [ "$R_ABBRUCH" -eq 1 ]; then
    info "\nGespeichert. Weiter mit: ${fett}$0 review${kat_filter:+ $kat_filter}${aus}"
  else
    info "\nDurchsicht fertig."
  fi
  info "Zum Verschieben markiert: ${fett}$n_go ($(mb "$kb_go"))${aus}"
  [ "$R_ABBRUCH" -eq 1 ] || info "Weiter: ${fett}$0 apply${aus}"
}

# ---------- apply ----------
befehl_apply() {
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  local anzahl; anzahl="$(awk -F'\t' '$1=="go"' "$KANDIDATEN" | wc -l | tr -d ' ')"
  [ "$anzahl" -eq 0 ] && { warn "Nichts markiert. Erst '$0 review'."; return 0; }

  # Waehrend eines Laufs liegen Original und neue Fassung gleichzeitig da.
  # Als Puffer die groesste ausgewaehlte Datei plus etwas Luft.
  local groesste frei
  groesste="$(awk -F'\t' '$1=="go" && $9+0 > m { m=$9 } END{ print m+0 }' "$VIDEOLISTE")"
  frei="$(freier_platz_kb "$HOME")"
  if [ "${frei:-0}" -lt $(( groesste + 1048576 )) ]; then
    fehler "Zu wenig Platz: $(mb "$frei") frei, mindestens $(mb $((groesste + 1048576))) nötig."
    info "${grau}Während des Kodierens liegen Original und neue Fassung gleichzeitig auf der Platte.${aus}"
    return 1
  fi

  local stapel; stapel="$(date '+%Y-%m-%d_%H%M%S')"
  local ziel="$QUARANTAENE/$stapel"
  local manifest="$ziel/_manifest.tsv"
  mkdir -p "$ziel"
  : > "$manifest"

  local platz; platz="$(awk -F'\t' '$1=="go"{s+=$3} END{print s}' "$KANDIDATEN")"
  info "\n${fett}$anzahl Einträge${aus} ($(mb "$platz")) → Quarantäne"
  info "${grau}$ziel${aus}\n"
  printf 'Fortfahren? [j/N] '
  local ok; read -r ok || ok=n
  case "$ok" in j|J) ;; *) info "Abgebrochen."; return 0;; esac

  # Ein 'go'-Ordner darf nichts mitnehmen, was ausdruecklich behalten werden
  # soll -- mv wuerde den Unterordner sonst kommentarlos mitverschieben.
  local keepliste="$ARBEIT/apply_keep.txt"
  awk -F'\t' '$1=="keep"{print $5}' "$KANDIDATEN" > "$keepliste"

  local verschoben=0 fehlgeschlagen=0 blockiert=0
  local -a neu=()
  while IFS= read -r zeile <&3; do
    local st kt kb mt pfad grund grp etikett
    IFS=$'\t' read -r st kt kb mt pfad grund grp etikett <<< "$zeile"
    if [ "$st" != "go" ]; then neu+=("$zeile"); continue; fi
    if ist_geschuetzt "$pfad"; then
      warn "geschützt, übersprungen: $pfad"; neu+=("$(status_setzen "$zeile" keep)"); continue
    fi
    if [ ! -e "$pfad" ]; then continue; fi
    if [ -d "$pfad" ] && awk -v praefix="$pfad/" 'index($0, praefix)==1 { gefunden=1; exit } END { exit !gefunden }' "$keepliste"; then
      local drin
      drin="$(awk -v praefix="$pfad/" 'index($0, praefix)==1 { print; exit }' "$keepliste")"
      warn "übersprungen: ${pfad/#$HOME/$TILDE}"
      info "  ${grau}enthält ${drin/#$HOME/$TILDE}, das du behalten wolltest.${aus}"
      info "  ${grau}Entweder den Unterordner auch freigeben oder den Elternordner behalten.${aus}"
      blockiert=$((blockiert + 1))
      neu+=("$zeile")
      continue
    fi
    local rel="${pfad#$HOME/}"
    local zielpfad="$ziel/$rel"
    mkdir -p "$(dirname "$zielpfad")"
    if mv "$pfad" "$zielpfad" 2>/dev/null; then
    # Vierte Spalte haelt fest, wie der Eintrag hierher kam.
    # "verschoben": beiseitegelegt, der Originalort ist frei.
    printf '%s\t%s\t%s\t%s\n' "$rel" "$pfad" "$kb" "verschoben" >> "$manifest"
      verschoben=$((verschoben+1))
      printf '  %s✓%s %s\n' "$gruen" "$aus" "${pfad/#$HOME/$TILDE}"
    else
      fehlgeschlagen=$((fehlgeschlagen+1))
      printf '  %s✗%s %s %s(keine Berechtigung?)%s\n' "$rot" "$aus" "${pfad/#$HOME/$TILDE}" "$grau" "$aus"
      neu+=("$zeile")
    fi
  done 3< "$KANDIDATEN"

  schreibe_kandidaten "${neu[@]+"${neu[@]}"}"
  [ "$blockiert" -gt 0 ] && warn "$blockiert übersprungen, weil sie behaltene Unterordner enthalten"
  if [ "$fehlgeschlagen" -gt 0 ]; then
    info "\n${gruen}$verschoben verschoben${aus}, ${rot}$fehlgeschlagen fehlgeschlagen${aus}"
  else
    info "\n${gruen}$verschoben verschoben${aus}"
  fi
  if [ "$verschoben" -eq 0 ]; then
    rm -f "$manifest"
    rmdir "$ziel" 2>/dev/null
    info "\nNichts verschoben, kein Stapel angelegt."
    return 0
  fi

  info "\nJetzt bitte den Mac normal weiterbenutzen. Wenn nach ein paar Tagen"
  info "nichts fehlt:  ${fett}$0 purge${aus}"
  info "Etwas vermisst? ${fett}$0 restore $stapel${aus}"
}

# ---------- list / restore / purge ----------
befehl_list() {
  [ -d "$QUARANTAENE" ] || { info "Quarantäne ist leer."; return 0; }
  titel "Quarantäne"
  local gesamt=0
  for s in "$QUARANTAENE"/*/; do
    [ -d "$s" ] || continue
    local name; name="$(basename "$s")"
    local kb; kb="$(du -sk "$s" 2>/dev/null | cut -f1)"
    local n; n="$(wc -l < "$s/_manifest.tsv" 2>/dev/null | tr -d ' ')"
    local tage; tage=$(( ( $(date +%s) - $(stat -f %m "$s") ) / 86400 ))
    printf '  %-22s %8s  %3s Einträge  %s(vor %d Tagen)%s\n' "$name" "$(mb "$kb")" "${n:-0}" "$grau" "$tage" "$aus"
    gesamt=$((gesamt+kb))
  done
  info "\n  Gesamt: $(mb "$gesamt")"
}

befehl_restore() {
  local stapel="" modus="ueberspringen"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ersetzen)        modus="ersetzen";;
      --zusammenfuehren) modus="zusammenfuehren";;
      --ueberspringen)   modus="ueberspringen";;
      --*) fehler "Unbekannte Option: $1"; return 1;;
      *) stapel="$1";;
    esac
    shift
  done
  [ -n "$stapel" ] || { fehler "Welcher Stapel? Siehe '$0 list'"; return 1; }
  local ziel="$QUARANTAENE/$stapel"
  [ -d "$ziel" ] || { fehler "Stapel '$stapel' nicht gefunden."; return 1; }
  local manifest="$ziel/_manifest.tsv"
  [ -f "$manifest" ] || { fehler "Manifest fehlt -- Stapel unvollständig."; return 1; }

  # Verdraengte Fassungen kommen hierhin, geloescht wird beim Zurueckholen nie
  local beiseite="$QUARANTAENE/_verdraengt-$(date '+%Y-%m-%d_%H%M%S')"

  local n=0 uebersprungen=0 uebersprungen_ersetzt=0 ersetzt=0 vereint=0 misslungen=0
  local -a bleibt=()
  local rel original kb art quelle

  while IFS=$'\t' read -r rel original kb art <&3; do
    [ -n "$rel" ] || continue
    quelle="$ziel/$rel"
    if [ ! -e "$quelle" ]; then continue; fi

    # --- Der Kern: niemals auf einen belegten Pfad verschieben ---
    if [ -e "$original" ]; then
      case "$modus" in
        ueberspringen)
          if [ "$art" = "ersetzt" ]; then
            uebersprungen_ersetzt=$((uebersprungen_ersetzt + 1))
            printf '  %s•%s %s %s(dort liegt die neu kodierte Fassung)%s\n' \
              "$gelb" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
          else
            printf '  %s•%s %s %s(ist wieder da — unangetastet)%s\n' \
              "$gelb" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
          fi
          uebersprungen=$((uebersprungen + 1))
          bleibt+=("$(printf '%s\t%s\t%s\t%s' "$rel" "$original" "$kb" "$art")")
          continue;;
        zusammenfuehren)
          if [ -d "$original" ] && [ -d "$quelle" ]; then
            if ! command -v rsync >/dev/null 2>&1; then
              fehler "--zusammenfuehren braucht rsync, das hier nicht vorhanden ist."
              return 1
            fi
            # Nur ergaenzen: was inzwischen neu entstanden ist, bleibt unberuehrt
            if rsync -a --ignore-existing "$quelle"/ "$original"/ 2>/dev/null; then
              rm -rf "$quelle"
              vereint=$((vereint + 1))
              printf '  %s⊕%s %s %s(ergänzt)%s\n' "$gruen" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
              continue
            fi
          fi
          printf '  %s•%s %s %s(keine zwei Ordner — übersprungen)%s\n' \
            "$gelb" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
          uebersprungen=$((uebersprungen + 1))
          bleibt+=("$(printf '%s\t%s\t%s\t%s' "$rel" "$original" "$kb" "$art")")
          continue;;
        ersetzen)
          mkdir -p "$beiseite/$(dirname "$rel")"
          if mv "$original" "$beiseite/$rel" 2>/dev/null; then
            ersetzt=$((ersetzt + 1))
          else
            printf '  %s✗%s %s %s(aktuelle Fassung ließ sich nicht sichern)%s\n' \
              "$rot" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
            misslungen=$((misslungen + 1))
            bleibt+=("$(printf '%s\t%s\t%s\t%s' "$rel" "$original" "$kb" "$art")")
            continue
          fi;;
      esac
    fi

    mkdir -p "$(dirname "$original")"
    if mv "$quelle" "$original" 2>/dev/null; then
      n=$((n + 1))
      printf '  %s✓%s %s\n' "$gruen" "$aus" "${original/#$HOME/$TILDE}"
    else
      printf '  %s✗%s %s\n' "$rot" "$aus" "${original/#$HOME/$TILDE}"
      misslungen=$((misslungen + 1))
      bleibt+=("$(printf '%s\t%s\t%s\t%s' "$rel" "$original" "$kb" "$art")")
    fi
  done 3< "$manifest"

  # Manifest auf das reduzieren, was noch in Quarantäne liegt
  if [ ${#bleibt[@]} -eq 0 ]; then : > "$manifest"; else printf '%s\n' "${bleibt[@]}" > "$manifest"; fi

  while find "$ziel" -mindepth 1 -type d -empty -delete 2>/dev/null | grep -q .; do :; done
  find "$ziel" -mindepth 1 -type d -empty -delete 2>/dev/null

  info ""
  [ "$n" -gt 0 ]            && info "${gruen}$n zurückgeholt${aus}"
  [ "$vereint" -gt 0 ]      && info "${gruen}$vereint Ordner ergänzt${aus}"
  [ "$ersetzt" -gt 0 ]      && info "${gruen}$ersetzt ersetzt${aus} ${grau}— verdrängte Fassungen: $beiseite${aus}"
  [ "$misslungen" -gt 0 ]   && warn "$misslungen fehlgeschlagen"
  if [ "$uebersprungen" -gt 0 ]; then
    warn "$uebersprungen übersprungen, weil der Pfad wieder belegt ist"
    if [ "$uebersprungen_ersetzt" -gt 0 ]; then
      info "${grau}Davon $uebersprungen_ersetzt Videos, an deren Stelle die neu kodierte Fassung liegt."
      info "Sieh sie dir an. Willst du das Original zurück:${aus} ${fett}$0 restore $stapel --ersetzen${aus}"
      info "${grau}Die neue Fassung wird dabei nicht gelöscht, sondern beiseitegelegt.${aus}"
    fi
    if [ "$uebersprungen" -gt "$uebersprungen_ersetzt" ]; then
      info "${grau}Der Rest sind meist Caches, die sich selbst neu aufgebaut haben — dann brauchst"
      info "du die alte Fassung nicht mehr: ${aus}${fett}$0 purge --wieder-da $stapel${aus}"
      info "${grau}Ordner nur ergänzen: ${aus}${fett}$0 restore $stapel --zusammenfuehren${aus}"
    fi
  fi

  if [ ! -s "$manifest" ]; then
    rm -f "$manifest"
    rmdir "$ziel" 2>/dev/null
    info "\nStapel $stapel ist leer und wurde entfernt."
  fi
}

# ---------- pruefen ----------
# Beantwortet die eigentliche Frage: was davon ist von selbst zurückgekommen?
# Was wieder da ist, hat sich als entbehrlich erwiesen.
befehl_pruefen() {
  [ -d "$QUARANTAENE" ] || { info "Quarantäne ist leer."; return 0; }
  local gesamt_wieder=0 gesamt_fehlt=0 kb_wieder=0 kb_fehlt=0 gesamt_ersetzt=0 kb_ersetzt=0
  local stapelordner rel original kb name tage

  for stapelordner in "$QUARANTAENE"/*/; do
    [ -d "$stapelordner" ] || continue
    name="$(basename "$stapelordner")"
    case "$name" in _verdraengt-*) continue;; esac
    [ -f "$stapelordner/_manifest.tsv" ] || continue
    tage=$(( ( $(date +%s) - $(stat -f %m "$stapelordner") ) / 86400 ))

    titel "$name  (vor $tage Tagen)"
    local w=0 f=0 e=0 wkb=0 fkb=0 ekb=0 art
    local -a wieder=()
    while IFS=$'\t' read -r rel original kb art; do
      [ -n "$rel" ] || continue
      if [ "$art" = "ersetzt" ]; then
        e=$((e + 1)); ekb=$((ekb + kb))
      elif [ -e "$original" ]; then
        w=$((w + 1)); wkb=$((wkb + kb))
        wieder+=("$(printf '%s\t%s' "$kb" "$original")")
      else
        f=$((f + 1)); fkb=$((fkb + kb))
      fi
    done < "$stapelordner/_manifest.tsv"

    [ "$w" -gt 0 ] && info "  ${gruen}$w wieder aufgebaut${aus} ($(mb "$wkb"))   ${grau}—  von selbst zurückgekehrt, die Quarantänekopie ist überflüssig${aus}"
    [ "$f" -gt 0 ] && info "  $f noch verschwunden ($(mb "$fkb"))   ${grau}—  hat dir bisher nichts gefehlt${aus}"
    if [ "$e" -gt 0 ]; then
      info "  ${gelb}$e ersetzt${aus} ($(mb "$ekb"))   ${grau}—  Originale neu kodierter Videos${aus}"
      info "    ${grau}Am Originalort liegt die neue Fassung, nicht etwas Nachgewachsenes."
      info "    Sieh sie dir an, bevor du das Original endgültig löschst.${aus}"
    fi

    if [ "$w" -gt 0 ]; then
      info "\n  ${grau}Wieder aufgebaut, größte zuerst:${aus}"
      printf '%s\n' "${wieder[@]}" | sort -t$'\t' -k1,1nr | head -8 \
        | while IFS=$'\t' read -r kb original; do
            local jetzt; jetzt="$(du -sk "$original" 2>/dev/null | cut -f1)"
            printf '    vorher %8s → jetzt %8s   %s\n' \
              "$(mb "$kb")" "$(mb "${jetzt:-0}")" "${original/#$HOME/$TILDE}"
          done
      info "\n  Platz sofort freigeben: ${fett}$0 purge --wieder-da $name${aus}"
    fi
    gesamt_wieder=$((gesamt_wieder + w)); gesamt_fehlt=$((gesamt_fehlt + f))
    kb_wieder=$((kb_wieder + wkb)); kb_fehlt=$((kb_fehlt + fkb))
    gesamt_ersetzt=$((gesamt_ersetzt + e)); kb_ersetzt=$((kb_ersetzt + ekb))
  done

  local zusatz=""
  [ "$gesamt_ersetzt" -gt 0 ] && zusatz=", $gesamt_ersetzt ersetzt ($(mb "$kb_ersetzt"))"
  info "\n${fett}Zusammen:${aus} $gesamt_wieder wieder da ($(mb "$kb_wieder")), $gesamt_fehlt verschwunden ($(mb "$kb_fehlt"))$zusatz"
}

befehl_purge() {
  # Sonderfall: nur das loeschen, was sich nachweislich neu aufgebaut hat
  if [ "${1:-}" = "--wieder-da" ]; then
    purge_wieder_da "${2:-}"
    return $?
  fi

  local tage="${1:-7}"
  [ -d "$QUARANTAENE" ] || { info "Quarantäne ist leer."; return 0; }
  local -a faellig=()
  local s name
  for s in "$QUARANTAENE"/*/; do
    [ -d "$s" ] || continue
    name="$(basename "$s")"
    local alter=$(( ( $(date +%s) - $(stat -f %m "$s") ) / 86400 ))
    [ "$alter" -ge "$tage" ] && faellig+=("$s")
  done
  [ ${#faellig[@]} -eq 0 ] && { info "Nichts älter als $tage Tage."; return 0; }

  local kb=0
  for s in "${faellig[@]}"; do kb=$(( kb + $(du -sk "$s" 2>/dev/null | cut -f1) )); done
  warn "Endgültiges Löschen von ${#faellig[@]} Stapel(n), $(mb "$kb"). Das lässt sich NICHT rückgängig machen."
  printf 'Wirklich löschen? Tippe %sLOESCHEN%s: ' "$fett" "$aus"
  local ok; read -r ok || ok=n
  [ "$ok" = "LOESCHEN" ] || { info "Abgebrochen."; return 0; }
  for s in "${faellig[@]}"; do rm -rf "$s" && info "  gelöscht: $(basename "$s")"; done
  info "\n$(mb "$kb") freigegeben."
}

# Eintraege loeschen, deren Originalpfad wieder existiert. Diese Kopien haben
# sich als entbehrlich erwiesen -- das System hat sie selbst ersetzt.
purge_wieder_da() {
  local stapel="${1:-}"
  local -a stapelliste=()
  if [ -n "$stapel" ]; then
    [ -d "$QUARANTAENE/$stapel" ] || { fehler "Stapel '$stapel' nicht gefunden."; return 1; }
    stapelliste=("$QUARANTAENE/$stapel/")
  else
    local s name
    for s in "$QUARANTAENE"/*/; do
      [ -d "$s" ] || continue
      name="$(basename "$s")"
      case "$name" in _verdraengt-*) continue;; esac
      stapelliste+=("$s")
    done
  fi
  [ ${#stapelliste[@]} -eq 0 ] && { info "Quarantäne ist leer."; return 0; }

  # Erst zaehlen, dann fragen
  local gesamt=0 kb=0 uebergangen=0 sordner rel original ekb art
  for sordner in "${stapelliste[@]}"; do
    [ -f "$sordner/_manifest.tsv" ] || continue
    while IFS=$'\t' read -r rel original ekb art; do
      [ -n "$rel" ] || continue
      # Ersetzte Videooriginale sind nicht "nachgewachsen" -- am Originalort
      # liegt die neu kodierte Fassung. Die gehoeren nicht in diesen Rundumschlag.
      [ "$art" = "ersetzt" ] && { uebergangen=$((uebergangen+1)); continue; }
      [ -e "$original" ] && [ -e "$sordner/$rel" ] && { gesamt=$((gesamt+1)); kb=$((kb+ekb)); }
    done < "$sordner/_manifest.tsv"
  done
  if [ "$uebergangen" -gt 0 ]; then
    info "${grau}$uebergangen Originale neu kodierter Videos bleiben aussen vor —"
    info "dort liegt die neue Fassung, nicht etwas Nachgewachsenes.${aus}"
  fi
  [ "$gesamt" -eq 0 ] && { info "Nichts davon ist bisher zurückgekehrt."; return 0; }

  info "${fett}$gesamt Einträge${aus} ($(mb "$kb")) sind am Originalort wieder vorhanden."
  info "${grau}Das System hat sie neu angelegt — die Quarantänekopien werden nicht mehr gebraucht.${aus}"
  warn "Endgültiges Löschen. Das lässt sich NICHT rückgängig machen."
  printf 'Wirklich löschen? Tippe %sLOESCHEN%s: ' "$fett" "$aus"
  local ok; read -r ok || ok=n
  [ "$ok" = "LOESCHEN" ] || { info "Abgebrochen."; return 0; }

  local geloescht=0
  for sordner in "${stapelliste[@]}"; do
    [ -f "$sordner/_manifest.tsv" ] || continue
    local -a bleibt=()
    while IFS=$'\t' read -r rel original ekb art; do
      [ -n "$rel" ] || continue
      if [ "$art" != "ersetzt" ] && [ -e "$original" ] && [ -e "$sordner/$rel" ]; then
        rm -rf "$sordner/$rel" && geloescht=$((geloescht+1))
      else
        bleibt+=("$(printf '%s\t%s\t%s\t%s' "$rel" "$original" "$ekb" "$art")")
      fi
    done < "$sordner/_manifest.tsv"
    if [ ${#bleibt[@]} -eq 0 ]; then : > "$sordner/_manifest.tsv"; else printf '%s\n' "${bleibt[@]}" > "$sordner/_manifest.tsv"; fi
    while find "$sordner" -mindepth 1 -type d -empty -delete 2>/dev/null | grep -q .; do :; done
    find "$sordner" -mindepth 1 -type d -empty -delete 2>/dev/null
    if [ ! -s "$sordner/_manifest.tsv" ]; then
      rm -f "$sordner/_manifest.tsv"; rmdir "$sordner" 2>/dev/null
      info "  Stapel $(basename "$sordner") ist jetzt leer und wurde entfernt."
    fi
  done
  info "\n${gruen}$geloescht Einträge gelöscht${aus}, $(mb "$kb") freigegeben."
}

# ---------- mark ----------
# Sammelentscheidung fuer eine ganze Kategorie, spart Einzelklicks im review.
befehl_mark() {
  local kat="${1:-}" status="${2:-}"
  case "$status" in go|keep|neu) ;; *) fehler "Status muss go, keep oder neu sein."; return 1;; esac
  [ -n "$kat" ] || { fehler "Welche Kategorie? (app-rest, cache, toolchain, gross, dublette)"; return 1; }
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  local n
  n="$(awk -F'\t' -v k="$kat" '$2==k' "$KANDIDATEN" | wc -l | tr -d ' ')"
  [ "$n" -eq 0 ] && { warn "Kategorie '$kat' enthaelt nichts."; return 0; }
  local platz
  platz="$(awk -F'\t' -v k="$kat" '$2==k {s+=$3} END{print s+0}' "$KANDIDATEN")"
  info "Kategorie ${fett}$kat${aus}: $n Eintraege, $(mb "$platz") -> ${fett}$status${aus}"
  awk -F'\t' -v OFS='\t' -v k="$kat" -v st="$status" '$2==k { $1=st } { print }' \
    "$KANDIDATEN" > "$KANDIDATEN.tmp" && mv "$KANDIDATEN.tmp" "$KANDIDATEN"
  info "Gesetzt. Pruefen mit: $0 zeigen $kat"
}

# ---------- zeigen ----------
befehl_zeigen() {
  local kat="${1:-}"
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  awk -F'\t' -v k="$kat" 'k=="" || $2==k' "$KANDIDATEN" \
    | sort -t$'\t' -k3,3nr \
    | while IFS=$'\t' read -r st kt kb mt pfad grund grp etikett; do
        local farbe="$grau"
        [ "$st" = "go" ] && farbe="$rot"
        [ "$st" = "keep" ] && farbe="$gruen"
        printf '%s%-5s%s %9s  %-10s %s\n' "$farbe" "$st" "$aus" "$(mb "$kb")" "$kt" "${pfad/#$HOME/$TILDE}"
      done
}

# ---------- gruppen ----------
# Ueberblick, was im review noch ansteht -- groesste Gruppen zuerst.
befehl_gruppen() {
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  if [ "$(head -1 "$KANDIDATEN" | awk -F'\t' '{print NF}')" -lt 8 ]; then gruppen_zuordnen; fi
  local kat="${1:-}"
  titel "Offene Gruppen${kat:+ in $kat}"
  awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k) {
        n[$8]++; s[$8]+=$3; kat[$8]=$2
      } END { for (g in n) printf "%d\t%d\t%s\t%s\n", s[g], n[g], kat[g], g }' "$KANDIDATEN" \
    | sort -t$'\t' -k1,1nr \
    | while IFS=$'\t' read -r kb n kt g; do
        printf '  %9s  %3d  %-10s %s\n' "$(mb "$kb")" "$n" "$kt" "$g"
      done
  local gz ez
  gz="$(awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k){print $8}' "$KANDIDATEN" | sort -u | wc -l | tr -d ' ')"
  ez="$(awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k)' "$KANDIDATEN" | wc -l | tr -d ' ')"
  info "\n  ${fett}$gz Gruppen${aus} aus $ez Einträgen"
}

# ---------- video ----------
# Neukodieren ist etwas anderes als Verschieben: es erzeugt eine neue,
# verlustbehaftete Datei. Darum ein eigener Unterbefehl mit eigener Liste
# und eigener Pruefung -- und nicht als weitere Kategorie in kandidaten.tsv,
# wo "go" bisher immer nur "verschieben" bedeutet hat.

VIDEOLISTE="$BASIS/video-kandidaten.tsv"

# Messwerte von einem Apple M2, Quelle 4K60 H.264 mit 0,168 bpp:
#   schnell  VideoToolbox q60    -> 0,055 bpp Ausgabe, rund 413 Mpx/s
#   sparsam  x265 veryfast crf24 -> 0,040 bpp Ausgabe, rund  90 Mpx/s
VIDEO_BPP_SCHNELL="0.055"
VIDEO_BPP_SPARSAM="0.040"
VIDEO_TEMPO_SCHNELL="413000000"
VIDEO_TEMPO_SPARSAM="90000000"
# Ab so viel Datenmenge je Bildpunkt lohnt das Neukodieren.
VIDEO_SCHWELLE="0.10"
# Bereits sparsame Codecs brauchen mehr, bevor sich ein Eingriff lohnt.
VIDEO_SCHWELLE_MODERN="0.15"
# Unter diesem Gewinn lohnt der Aufwand nicht, egal wie ueppig kodiert.
VIDEO_MINDESTGEWINN_KB="51200"

# Alle Profile an genau einer Stelle. Die Zahlen stammen aus Messungen an
# einer 4K60-Datei auf einem Apple M2:
#   Feld 1  Encoder, wie er in der Auswahl erscheint
#   Feld 2  Merksatz
#   Feld 3  erwartete Ausgabe-bpp (Datenmenge je Bildpunkt und Bild)
#   Feld 4  Tempo in Millionen Bildpunkten je Sekunde
#   Feld 5  Warnhinweis, leer wenn keiner noetig
video_profil_namen() { printf '%s\n' "schnell" "av1" "sparsam" "klein"; }

video_profil_daten() {
  case "$1" in
    schnell) echo "VideoToolbox q60|Hardware-Chip des Macs, mit Abstand am schnellsten|0.0548|413|";;
    av1)     echo "SVT-AV1 crf32|beste Bildqualität im Test, dabei schneller als x265|0.0505|87|Der M2 dekodiert AV1 nicht in Hardware: Abspielen kostet mehr Akku, und ältere Geräte oder Handys spielen es womöglich gar nicht ab.";;
    sparsam) echo "x265 veryfast crf24|guter Mittelweg, überall abspielbar|0.0378|72|";;
    klein)   echo "x265 veryfast crf28|kleinste Dateien, merklich weniger Reserve|0.0247|89|";;
    *) return 1;;
  esac
}

video_profil_encoder() {
  case "$1" in
    schnell) printf '%s\n' "-c:v" "hevc_videotoolbox" "-q:v" "60" "-tag:v" "hvc1";;
    av1)     printf '%s\n' "-c:v" "libsvtav1" "-crf" "32" "-preset" "8";;
    sparsam) printf '%s\n' "-c:v" "libx265" "-crf" "24" "-preset" "veryfast" "-tag:v" "hvc1";;
    klein)   printf '%s\n' "-c:v" "libx265" "-crf" "28" "-preset" "veryfast" "-tag:v" "hvc1";;
    *) return 1;;
  esac
}

video_profil_feld() { video_profil_daten "$1" | cut -d'|' -f"$2"; }

# Fuehrt ffmpeg aus und zeigt dabei, wie weit es ist. ffmpeg meldet ueber
# -progress fortlaufend out_time_us (Mikrosekunden des fertigen Materials).
video_ffmpeg() {   # video_ffmpeg <dauer_s> <text> <ffmpeg-argumente...>
  local dauer="$1" text="$2"; shift 2
  local meldedatei="$ARBEIT/ff_fortschritt.txt"
  : > "$meldedatei"
  ffmpeg -hide_banner -nostats -loglevel error -progress "$meldedatei" "$@" -y 2>/dev/null &
  local ff=$!
  local gesamt_ms
  gesamt_ms="$(LC_ALL=C awk -v d="$dauer" 'BEGIN{ printf "%d", d * 1000 }')"
  fortschritt_start
  local us
  while kill -0 "$ff" 2>/dev/null; do
    us="$(grep '^out_time_us=' "$meldedatei" 2>/dev/null | tail -1 | cut -d= -f2)"
    case "$us" in
      ''|*[!0-9]*) ;;
      *) fortschritt "$((us / 1000))" "$gesamt_ms" "$text";;
    esac
    sleep 1
  done
  wait "$ff"
  local rc=$?
  fortschritt_ende
  rm -f "$meldedatei"
  return "$rc"
}

# Schaetzt fuer alle 'go'-Eintraege der Liste: belegt, danach, Minuten.
# ziel_h = 0 heisst Auflösung beibehalten, sonst auf diese Höhe verkleinern.
video_schaetzen() {   # video_schaetzen <profil> <ziel_hoehe> -> "belegt danach minuten"
  local bpp mpxs
  bpp="$(video_profil_feld "$1" 3)"
  mpxs="$(video_profil_feld "$1" 4)"
  LC_ALL=C awk -F'\t' -v bpp="$bpp" -v mpxs="$mpxs" -v zh="${2:-0}" '
    $1=="go" {
      w=$5; h=$6; fps=$7; dauer=$8; kb=$9
      aw=w; ah=h
      if (zh > 0 && h > zh) { ah = zh; aw = int(w * zh / h / 2) * 2 }
      verhaeltnis = (w*h > 0) ? (aw*ah)/(w*h) : 1
      aus_kb = bpp * aw * ah * fps * dauer / 8 / 1024
      if (aus_kb > kb) aus_kb = kb
      # Zeit: gemessen bei voller Auflösung; Verkleinern spart weniger als
      # das Pixelverhältnis vermuten lässt, weil das Dekodieren gleich bleibt.
      voll = w * h * fps * dauer / (mpxs * 1000000)
      sek = voll * (0.45 + 0.55 * verhaeltnis)
      belegt += kb; danach += aus_kb; zeit += sek
    }
    END { printf "%d\t%d\t%.1f", belegt, danach, zeit/60 }' "$VIDEOLISTE"
}

video_werkzeuge_pruefen() {
  local fehlt=""
  command -v ffmpeg  >/dev/null 2>&1 || fehlt="$fehlt ffmpeg"
  command -v ffprobe >/dev/null 2>&1 || fehlt="$fehlt ffprobe"
  if [ -n "$fehlt" ]; then
    fehler "Für Videos fehlt:$fehlt"
    info "${grau}Der übrige Teil von fegefeuer kommt ohne Zusatzsoftware aus,"
    info "das Neukodieren nicht. Zu installieren mit:${aus}"
    info "  ${fett}brew install ffmpeg${aus}"
    return 1
  fi
  return 0
}

# Zahlen mit deutschem Komma ausgeben, gerechnet wird mit Punkt
zahl() { LC_ALL=C awk -v w="$1" -v n="${2:-1}" 'BEGIN{s=sprintf("%.*f", n, w); sub(/\./, ",", s); print s}'; }

# "codec breite hoehe fps dauer" oder nichts
video_vermessen() {
  LC_ALL=C ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate \
    -show_entries format=duration -of default=nw=1 "$1" 2>/dev/null \
  | LC_ALL=C awk -F= '
      /^codec_name/ { c=$2 }
      /^width/      { w=$2 }
      /^height/     { h=$2 }
      /^r_frame_rate/ { split($2,a,"/"); f=(a[2]>0)? a[1]/a[2] : 0 }
      /^duration/   { d=$2 }
      END { if (c!="" && w>0 && h>0 && f>0 && d>0) printf "%s %d %d %.4f %.3f\n", c, w, h, f, d }'
}

freier_platz_kb() { df -k "${1:-$HOME}" 2>/dev/null | tail -1 | awk '{print $4}'; }

befehl_video_scan() {
  video_werkzeuge_pruefen || return 1
  local wurzel="${1:-$HOME}"
  [ -d "$wurzel" ] || { fehler "Kein Verzeichnis: $wurzel"; return 1; }

  titel "Videos suchen unter ${wurzel/#$HOME/$TILDE}"
  local tmp="$ARBEIT/video_fund.txt"
  find "$wurzel" -type f \( \
       -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.avi" \
    -o -iname "*.mkv" -o -iname "*.wmv" -o -iname "*.mpg" -o -iname "*.mpeg" \
    -o -iname "*.mp4.zip" -o -iname "*.mov.zip" -o -iname "*.m4v.zip" \) \
    -size +20M \
    ! -path "*/Library/*" ! -path "*/.fegefeuer/*" ! -path "*/node_modules/*" \
    ! -path "*/.Trash/*" ! -path "*.photoslibrary/*" ! -path "*OneDrive*" \
    -print 2>/dev/null | sort > "$tmp"
  local gefunden; gefunden="$(wc -l < "$tmp" | tr -d ' ')"
  [ "$gefunden" -eq 0 ] && { info "  Keine Videos über 20 MB gefunden."; return 0; }
  info "  $gefunden Dateien über 20 MB"

  local entpackbedarf=0 zips=0 pfad
  while IFS= read -r pfad; do
    case "$pfad" in
      *.zip) zips=$((zips+1))
             local roh; roh="$(LC_ALL=C unzip -l "$pfad" 2>/dev/null | tail -1 | awk '{print $1}')"
             [ -n "$roh" ] && [ "$roh" -gt "$entpackbedarf" ] 2>/dev/null && entpackbedarf="$roh";;
    esac
  done < "$tmp"
  if [ "$zips" -gt 0 ]; then
    info "  davon $zips in einem ZIP — die müssen zum Messen kurz entpackt werden"
    local frei; frei="$(freier_platz_kb "$ARBEIT")"
    local noetig=$(( entpackbedarf / 1024 + 500000 ))
    if [ "$frei" -lt "$noetig" ]; then
      fehler "Zu wenig Platz zum Entpacken: $(mb "$frei") frei, $(mb "$noetig") nötig."
      return 1
    fi
  fi

  : > "$VIDEOLISTE.tmp"
  fortschritt_start
  local entpackordner="$ARBEIT/video_tmp"
  rm -rf "$entpackordner"; mkdir -p "$entpackordner"
  local i=0 messfehler=0
  while IFS= read -r pfad; do
    i=$((i+1))
    fortschritt "$i" "$gefunden" "Videos vermessen"
    local messpfad="$pfad" verpackt="nein" temp=""
    case "$pfad" in
      *.zip)
        verpackt="ja"
        rm -rf "$entpackordner"; mkdir -p "$entpackordner"
        unzip -o -q "$pfad" -d "$entpackordner" 2>/dev/null
        temp="$(find "$entpackordner" -type f -size +1M 2>/dev/null | head -1)"
        [ -n "$temp" ] || { messfehler=$((messfehler+1)); continue; }
        messpfad="$temp";;
    esac
    local daten; daten="$(video_vermessen "$messpfad")"
    if [ -z "$daten" ]; then
      messfehler=$((messfehler+1))
      [ "$verpackt" = "ja" ] && rm -rf "$entpackordner"
      continue
    fi
    local kb; kb="$(du -sk "$pfad" 2>/dev/null | cut -f1)"
    local rohkb; rohkb="$(du -sk "$messpfad" 2>/dev/null | cut -f1)"
    # Felder einzeln setzen -- ein tr ueber die ganze Zeile wuerde Dateinamen
    # mit Leerzeichen in lauter Spalten zerlegen.
    local codec breite hoehe fps dauer
    # IFS ausdruecklich setzen: das IFS= der aeusseren Schleife wirkt hier
    # sonst weiter, und read stopft alles in die erste Variable.
    IFS=' ' read -r codec breite hoehe fps dauer <<< "$daten"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "neu" "$pfad" "$verpackt" "$codec" "$breite" "$hoehe" "$fps" "$dauer" "$kb" "$rohkb" \
      >> "$VIDEOLISTE.tmp"
    [ "$verpackt" = "ja" ] && rm -rf "$entpackordner"
  done < "$tmp"
  rm -rf "$entpackordner"
  fortschritt_ende
  [ "$messfehler" -gt 0 ] && warn "$messfehler Dateien liessen sich nicht vermessen"

  # bpp und Urteil ergaenzen
  LC_ALL=C awk -F'\t' -v OFS='\t' \
      -v s="$VIDEO_SCHWELLE" -v sm="$VIDEO_SCHWELLE_MODERN" \
      -v bs="$VIDEO_BPP_SCHNELL" -v bp="$VIDEO_BPP_SPARSAM" \
      -v mg="$VIDEO_MINDESTGEWINN_KB" '
    {
      status=$1; pfad=$2; verpackt=$3; codec=$4; w=$5; h=$6; fps=$7; dauer=$8; kb=$9; rohkb=$10
      pxs = w * h * fps
      if (pxs <= 0 || dauer <= 0) next
      bitrate = rohkb * 1024 * 8 / dauer
      bpp = (pxs>0) ? bitrate / pxs : 0
      modern = (codec=="hevc" || codec=="av1" || codec=="vp9")
      schwelle = modern ? sm : s
      neu_schnell = pxs * bs * dauer / 8 / 1024
      neu_sparsam = pxs * bp * dauer / 8 / 1024
      if (neu_schnell > rohkb) neu_schnell = rohkb
      if (neu_sparsam > rohkb) neu_sparsam = rohkb
      # Gewinn gegen den tatsaechlichen Platzbedarf rechnen: bei einem ZIP
      # belegt die Platte die gepackte Groesse, nicht die entpackte.
      gewinn = kb - neu_sparsam
      if (fps < 5)              urteil = "zeitraffer"
      else if (bpp <= schwelle) urteil = "sparsam"
      else if (gewinn < mg)     urteil = "geringfuegig"
      else                      urteil = "lohnt"
      print status, pfad, verpackt, codec, w, h, fps, dauer, kb, rohkb, bpp, urteil, int(neu_schnell), int(neu_sparsam)
    }' "$VIDEOLISTE.tmp" > "$VIDEOLISTE"
  rm -f "$VIDEOLISTE.tmp"

  video_bericht
}

video_bericht() {
  [ -s "$VIDEOLISTE" ] || { info "Keine vermessenen Videos."; return 0; }

  titel "Was sich lohnt"
  LC_ALL=C awk -F'\t' -v h="$HOME" '
    function komma(w, n,   t) { t = sprintf("%.*f", n, w); sub(/\./, ",", t); return t }
    $12=="lohnt" {
      p=$2; sub(h, "~", p)
      n=split(p, teile, "/"); kurz=teile[n]
      if (length(kurz)>36) kurz=substr(kurz,1,35) "…"
      gewinn = ($9 - $14) / 1048576
      printf "%.6f\t  %-36s %5dx%-4d %3.0f fps %7s min %7s bpp %7s GB → %7s GB\n", \
             gewinn, kurz, $5, $6, $7, komma($8/60,1), komma($11,3), \
             komma($9/1048576,2), komma($14/1048576,2)
    }' "$VIDEOLISTE" \
  | sort -t$'\t' -k1,1nr | cut -f2- > "$ARBEIT/video_liste.txt"

  local zeilen; zeilen="$(wc -l < "$ARBEIT/video_liste.txt" | tr -d ' ')"
  head -15 "$ARBEIT/video_liste.txt"
  if [ "$zeilen" -gt 15 ]; then
    local rest_gb
    rest_gb="$(LC_ALL=C awk -F'\t' '$12=="lohnt"{g[++n]=($9-$14)/1048576}
      END{ m=n; for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(g[j]>g[i]){t=g[i];g[i]=g[j];g[j]=t}
           for(i=16;i<=n;i++) s+=g[i]; t=sprintf("%.2f", s); sub(/\./,",",t); print t }' "$VIDEOLISTE")"
    info "  ${grau}… und $((zeilen - 15)) weitere, zusammen $rest_gb GB Ersparnis${aus}"
  fi

  # Randfaelle sichtbar machen, statt sie stillschweigend zu schlucken
  local n_ger n_zeit n_spar
  n_ger="$(awk -F'\t' '$12=="geringfuegig"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  n_zeit="$(awk -F'\t' '$12=="zeitraffer"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  n_spar="$(awk -F'\t' '$12=="sparsam"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  echo
  [ "$n_spar" -gt 0 ] && info "  ${grau}$n_spar Dateien sind bereits sparsam kodiert — unangetastet.${aus}"
  [ "$n_ger" -gt 0 ]  && info "  ${grau}$n_ger Dateien wären zwar üppig kodiert, brächten aber je unter $(mb "$VIDEO_MINDESTGEWINN_KB") — nicht vorgeschlagen.${aus}"
  [ "$n_zeit" -gt 0 ] && info "  ${grau}$n_zeit Zeitraffer (unter 5 fps) — dort ist die Kennzahl nicht aussagekräftig, bitte selbst ansehen.${aus}"

  LC_ALL=C awk -F'\t' -v ts="$VIDEO_TEMPO_SCHNELL" -v tp="$VIDEO_TEMPO_SPARSAM" '
    { gesamt_kb += $9
      if ($12=="lohnt") {
        n++; belegt += $9; schnell += $13; sparsam += $14
        pxs = $5*$6*$7; zeit_s += pxs*$8/ts; zeit_p += pxs*$8/tp
      } }
    END { printf "%d\t%.2f\t%.2f\t%.2f\t%.1f\t%.1f\t%.2f\n", \
            n, belegt/1048576, schnell/1048576, sparsam/1048576, zeit_s/60, zeit_p/60, gesamt_kb/1048576 }' \
    "$VIDEOLISTE" | while IFS=$'\t' read -r n belegt sch spa zs zp ges; do
      echo
      info "  ${fett}$n Dateien vorgeschlagen${aus} — $(zahl "$belegt" 2) GB von $(zahl "$ges" 2) GB Videomaterial"
      echo
      printf "  %-10s %-22s %11s %11s %12s\n" "Profil" "Encoder" "danach" "gespart" "Rechenzeit"
      printf "  %-10s %-22s %8s GB %8s GB %9s min\n" "schnell" "VideoToolbox q60" \
        "$(zahl "$sch" 2)" "$(LC_ALL=C awk -v a="$belegt" -v b="$sch" 'BEGIN{t=sprintf("%.2f",a-b); sub(/\./,",",t); print t}')" "$(zahl "$zs" 1)"
      printf "  %-10s %-22s %8s GB %8s GB %9s min\n" "sparsam" "x265 veryfast crf24" \
        "$(zahl "$spa" 2)" "$(LC_ALL=C awk -v a="$belegt" -v b="$spa" 'BEGIN{t=sprintf("%.2f",a-b); sub(/\./,",",t); print t}')" "$(zahl "$zp" 1)"
    done
  echo
  info "  ${grau}Geschätzt aus Messungen an einer 4K60-Datei; ruhige Aufnahmen werden kleiner,"
  info "  bewegte grösser. Es wurde noch nichts angefasst.${aus}"
  info "\n  Liste: ${VIDEOLISTE/#$HOME/$TILDE}"
}

# --- Pruefung nach dem Kodieren ---------------------------------------------
# Reihenfolge nach Kosten: erst das Billige, das die groben Fehler faengt.
# Gemessen an 4K60: Dekodieren laeuft mit 4,5x Echtzeit, Kodieren mit 0,9x --
# die Pruefung kostet also rund ein Fuenftel der Kodierzeit.
# Untergrenze fuer die Bildaehnlichkeit. Gemessene Werte echter Kodierungen
# lagen zwischen 0,93 (viel Bewegung) und 0,99 (ruhige Aufnahmen); eine
# absichtlich zerstoerte Fassung kam auf 0,87. Der Abstand ist also knapp.
# Lieber einmal zu viel ablehnen -- das Original bleibt dabei unangetastet.
# Ueber die Umgebungsvariable FEGEFEUER_SSIM_MIN anpassbar.
VIDEO_SSIM_MIN="${FEGEFEUER_SSIM_MIN:-0.90}"

video_pruefen() {   # video_pruefen <neu> <original> -> SSIM oder Grund, 0 = gut
  local neu="$1" alt="$2"
  [ -s "$neu" ] || { echo "Datei ist leer"; return 1; }

  local d_neu d_alt
  d_neu="$(LC_ALL=C ffprobe -v error -show_entries format=duration -of csv=p=0 "$neu" 2>/dev/null)"
  d_alt="$(LC_ALL=C ffprobe -v error -show_entries format=duration -of csv=p=0 "$alt" 2>/dev/null)"
  if [ -z "$d_neu" ] || [ -z "$d_alt" ]; then echo "Laufzeit nicht lesbar"; return 1; fi
  if ! LC_ALL=C awk -v a="$d_neu" -v b="$d_alt" 'BEGIN{ exit !((a-b < 0.5) && (b-a < 0.5)) }'; then
    echo "Laufzeit weicht ab: $(zahl "$d_neu" 1) s statt $(zahl "$d_alt" 1) s"; return 1
  fi

  # Tonspur: ein stiller Film faellt sonst erst Monate spaeter auf
  local ton_neu ton_alt
  ton_neu="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$neu" 2>/dev/null | wc -l | tr -d ' ')"
  ton_alt="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$alt" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$ton_neu" -lt "$ton_alt" ]; then echo "Tonspur fehlt ($ton_neu statt $ton_alt)"; return 1; fi

  # Eine vollstaendige SSIM-Messung statt Stichproben. Stichproben mit
  # -ss vor -i landen bei unterschiedlichen Keyframe-Rastern nicht immer auf
  # demselben Bild -- gemessen: 0,838 statt 0,948 an derselben Stelle.
  # Der Durchlauf dekodiert beide Dateien komplett und ersetzt damit zugleich
  # die Prueflesung: bricht eine Datei ab, schlaegt er fehl.
  # Bei verkleinerter Ausgabe muss fuer den Vergleich wieder hochskaliert
  # werden, sonst kann der ssim-Filter die Bilder nicht uebereinanderlegen.
  local masse_neu masse_alt lavfi="[0:v][1:v]ssim"
  masse_neu="$(LC_ALL=C ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$neu" 2>/dev/null)"
  masse_alt="$(LC_ALL=C ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$alt" 2>/dev/null)"
  if [ -n "$masse_alt" ] && [ "$masse_neu" != "$masse_alt" ]; then
    local aw="${masse_alt%%,*}" ah="${masse_alt##*,}"
    lavfi="[0:v]scale=${aw}:${ah}:flags=bicubic[hoch];[hoch][1:v]ssim"
  fi
  local ausgabe wert meldedatei="$ARBEIT/ssim_fortschritt.txt"
  : > "$meldedatei"
  ffmpeg -hide_banner -nostats -xerror -progress "$meldedatei" -i "$neu" -i "$alt" \
    -lavfi "$lavfi" -f null - > "$ARBEIT/ssim_ausgabe.txt" 2>&1 &
  local ff=$!
  local gesamt_ms us
  gesamt_ms="$(LC_ALL=C awk -v d="$d_alt" 'BEGIN{ printf "%d", d * 1000 }')"
  fortschritt_start
  while kill -0 "$ff" 2>/dev/null; do
    us="$(grep '^out_time_us=' "$meldedatei" 2>/dev/null | tail -1 | cut -d= -f2)"
    case "$us" in
      ''|*[!0-9]*) ;;
      *) fortschritt "$((us / 1000))" "$gesamt_ms" "prüfe Bild und Ton";;
    esac
    sleep 1
  done
  wait "$ff"
  local rc=$?
  fortschritt_ende
  ausgabe="$(cat "$ARBEIT/ssim_ausgabe.txt" 2>/dev/null)"
  rm -f "$meldedatei" "$ARBEIT/ssim_ausgabe.txt"
  if [ "$rc" -ne 0 ]; then echo "Datei laesst sich nicht fehlerfrei durchspielen"; return 1; fi
  wert="$(printf '%s' "$ausgabe" | grep -oE "All:[0-9.]+" | tail -1 | cut -d: -f2)"
  [ -n "$wert" ] || { echo "SSIM liess sich nicht messen"; return 1; }
  if LC_ALL=C awk -v w="$wert" -v m="$VIDEO_SSIM_MIN" 'BEGIN{ exit !(w < m) }'; then
    echo "Bildqualität zu weit weg (SSIM $(zahl "$wert" 3), verlangt $(zahl "$VIDEO_SSIM_MIN" 2)) — mit FEGEFEUER_SSIM_MIN anpassbar"; return 1
  fi

  # Groesser als vorher waere sinnlos. Hier zaehlt die logische Groesse:
  # du meldet belegte Bloecke und liefert fuer zwei byte-gleiche Dateien
  # unterschiedliche Werte (gemessen: 114692 gegen 98460 KB).
  local b_neu b_alt
  b_neu="$(stat -f %z "$neu" 2>/dev/null)"
  b_alt="$(stat -f %z "$alt" 2>/dev/null)"
  if [ -n "$b_neu" ] && [ -n "$b_alt" ] && [ "$b_neu" -ge "$b_alt" ]; then
    echo "wäre nicht kleiner ($(mb $((b_neu/1024))) statt $(mb $((b_alt/1024))))"; return 1
  fi

  echo "$wert"
  return 0
}

befehl_video_review() {
  [ -s "$VIDEOLISTE" ] || { fehler "Keine Videoliste. Erst '$0 video scan'."; return 1; }
  local offen
  offen="$(awk -F'\t' '$1=="neu" && $12=="lohnt"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  [ "$offen" -eq 0 ] && { info "Nichts offen. Weiter mit: ${fett}$0 video run${aus}"; return 0; }

  info "\n${fett}Videos durchgehen${aus} — $offen offen"
  info "${grau}j=neu kodieren  n=so lassen  a=alle übrigen freigeben  o=Finder  s=später  q=Ende${aus}"

  local -a ausgabe=()
  local zeile nr=0 abbruch=0 alle=0
  while IFS= read -r zeile <&3; do
    local st pfad w h fps dauer kb neu_kb
    st="$(printf '%s' "$zeile" | cut -f1)"
    if [ "$st" != "neu" ] || [ "$(printf '%s' "$zeile" | cut -f12)" != "lohnt" ] || [ "$abbruch" -eq 1 ]; then
      ausgabe+=("$zeile"); continue
    fi
    if [ "$alle" -eq 1 ]; then ausgabe+=("$(status_setzen "$zeile" go)"); continue; fi
    nr=$((nr+1))
    pfad="$(printf '%s' "$zeile" | cut -f2)"
    w="$(printf '%s' "$zeile" | cut -f5)"; h="$(printf '%s' "$zeile" | cut -f6)"
    fps="$(printf '%s' "$zeile" | cut -f7)"; dauer="$(printf '%s' "$zeile" | cut -f8)"
    kb="$(printf '%s' "$zeile" | cut -f9)"; neu_kb="$(printf '%s' "$zeile" | cut -f14)"
    printf '\n%s[%d/%d]%s %s\n' "$grau" "$nr" "$offen" "$aus" "${pfad/#$HOME/$TILDE}"
    printf '  %s%sx%s · %s fps · %s min · %s bpp%s\n' "$grau" "$w" "$h" \
      "$(zahl "$fps" 0)" "$(zahl "$(LC_ALL=C awk -v d="$dauer" 'BEGIN{print d/60}')" 1)" \
      "$(printf '%s' "$zeile" | cut -f11 | { read -r b; zahl "$b" 3; })" "$aus"
    printf '  %s%s%s  →  etwa %s%s%s\n' "$fett" "$(mb "$kb")" "$aus" "$fett" "$(mb "$neu_kb")" "$aus"
    local antwort
    while true; do
      printf '  → '
      read -r antwort || antwort=q
      case "$antwort" in
        j|J) ausgabe+=("$(status_setzen "$zeile" go)"); break;;
        n|N) ausgabe+=("$(status_setzen "$zeile" keep)"); break;;
        a|A) alle=1; ausgabe+=("$(status_setzen "$zeile" go)"); break;;
        o|O) open -R "$pfad" 2>/dev/null;;
        s|S|"") ausgabe+=("$zeile"); break;;
        q|Q) abbruch=1; ausgabe+=("$zeile"); break;;
        *) printf '  %sBitte j / n / a / o / s / q%s\n' "$gelb" "$aus";;
      esac
    done
  done 3< "$VIDEOLISTE"

  if [ ${#ausgabe[@]} -eq 0 ]; then : > "$VIDEOLISTE"; else printf '%s\n' "${ausgabe[@]}" > "$VIDEOLISTE"; fi
  local n_go
  n_go="$(awk -F'\t' '$1=="go"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  info "\nFreigegeben: ${fett}$n_go${aus}"
  [ "$n_go" -gt 0 ] && info "Weiter: ${fett}$0 video run --profil sparsam${aus}"
}

# Zeigt beide Profile mit den Zahlen der tatsaechlich ausgewaehlten Dateien
# und fragt. Ergebnis in VIDEO_PROFIL.
video_profil_waehlen() {   # <anzahl> <ziel_hoehe>
  local anzahl="$1" zielhoehe="${2:-0}"
  info "\n${fett}Womit kodieren?${aus}  ${grau}Zahlen für deine $anzahl ausgewählten Dateien"
  [ "$zielhoehe" -gt 0 ] && info "  einschliesslich Verkleinerung auf ${zielhoehe}p"
  printf '%s' "$aus"
  echo

  local i=0 name rumpf belegt danach minuten hinweis
  for name in $(video_profil_namen); do
    i=$((i+1))
    read -r belegt danach minuten <<< "$(video_schaetzen "$name" "$zielhoehe")"
    rumpf="$(printf '%-9s %-22s %9s → %-9s  %8s gespart   ~%s min' \
      "$name" "$(video_profil_feld "$name" 1)" "$(mb "$belegt")" "$(mb "$danach")" \
      "$(mb $((belegt - danach)))" "$(zahl "$minuten" 0)")"
    printf '  %s%d)%s %s\n' "$fett" "$i" "$aus" "$rumpf"
    printf '     %s%s%s\n' "$grau" "$(video_profil_feld "$name" 2)" "$aus"
    hinweis="$(video_profil_feld "$name" 5)"
    [ -n "$hinweis" ] && printf '     %s⚠ %s%s\n' "$gelb" "$hinweis" "$aus"
  done

  info "\n  ${grau}Die Bildqualität liegt bei allen vier dicht beieinander — gemessen SSIM"
  info "  0,989 (av1) bis 0,979 (klein). Es geht vor allem um Zeit gegen Platz.${aus}"

  local antwort gewaehlt
  while true; do
    printf '\n  Profil [Ziffer oder Name, q=Abbruch] → '
    if ! read -r antwort; then
      printf '\n'; fehler "Keine Eingabe. Bitte --profil <name> angeben."; return 1
    fi
    case "$antwort" in
      q|Q) return 1;;
      [0-9]*)
        gewaehlt="$(video_profil_namen | sed -n "${antwort}p")"
        if [ -n "$gewaehlt" ]; then VIDEO_PROFIL="$gewaehlt"; return 0; fi;;
      *)
        if video_profil_daten "$antwort" >/dev/null 2>&1; then VIDEO_PROFIL="$antwort"; return 0; fi;;
    esac
    printf '  %sBitte 1–%d, einen Profilnamen oder q%s\n' "$gelb" "$i" "$aus"
  done
}

befehl_video_run() {
  video_werkzeuge_pruefen || return 1
  [ -s "$VIDEOLISTE" ] || { fehler "Keine Videoliste. Erst '$0 video scan'."; return 1; }
  local profil="" zielhoehe=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profil) shift; profil="${1:-}";;
      --profil=*) profil="${1#*=}";;
      --auf) shift; zielhoehe="${1:-}";;
      --auf=*) zielhoehe="${1#*=}";;
      *) fehler "Unbekannte Option: $1"; return 1;;
    esac
    shift
  done
  case "$zielhoehe" in
    0) ;;
    1080p|1080) zielhoehe=1080;;
    720p|720)   zielhoehe=720;;
    *) fehler "--auf versteht 1080p oder 720p."; return 1;;
  esac

  local anzahl
  anzahl="$(awk -F'\t' '$1=="go"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  [ "$anzahl" -eq 0 ] && { warn "Nichts freigegeben. Erst '$0 video review'."; return 0; }

  # Kein stiller Standardwert: entweder ausdruecklich angegeben oder gefragt.
  if [ -z "$profil" ]; then
    VIDEO_PROFIL=""
    video_profil_waehlen "$anzahl" "$zielhoehe" || { info "Abgebrochen."; return 0; }
    profil="$VIDEO_PROFIL"
  fi
  local -a enc=()
  local zeile_enc
  while IFS= read -r zeile_enc; do enc+=("$zeile_enc"); done < <(video_profil_encoder "$profil")
  if [ ${#enc[@]} -eq 0 ]; then
    fehler "Unbekanntes Profil '$profil'. Möglich sind: $(video_profil_namen | tr '\n' ' ')"
    return 1
  fi

  local vorher nachher minuten
  read -r vorher nachher minuten <<< "$(video_schaetzen "$profil" "$zielhoehe")"

  info "\n${fett}$anzahl Videos${aus} neu kodieren, Profil ${fett}$profil${aus}"
  [ "$zielhoehe" -gt 0 ] && info "  ${gelb}verkleinert auf ${zielhoehe}p — verlorene Bildpunkte kommen nicht zurück${aus}"
  info "  $(mb "$vorher") → etwa $(mb "$nachher")   ${grau}(~$(zahl "$minuten" 0) min)${aus}"
  info "  ${grau}Jedes Ergebnis wird geprüft, bevor das Original ins Fegefeuer wandert."
  info "  Schlägt eine Prüfung fehl, bleibt das Original unangetastet.${aus}"
  printf 'Fortfahren? [j/N] '
  local ok; read -r ok || ok=n
  case "$ok" in j|J) ;; *) info "Abgebrochen."; return 0;; esac

  # Waehrend eines Laufs liegen Original und neue Fassung gleichzeitig da.
  # Als Puffer die groesste ausgewaehlte Datei plus etwas Luft.
  local groesste frei
  groesste="$(awk -F'\t' '$1=="go" && $9+0 > m { m=$9 } END{ print m+0 }' "$VIDEOLISTE")"
  frei="$(freier_platz_kb "$HOME")"
  if [ "${frei:-0}" -lt $(( groesste + 1048576 )) ]; then
    fehler "Zu wenig Platz: $(mb "$frei") frei, mindestens $(mb $((groesste + 1048576))) nötig."
    info "${grau}Während des Kodierens liegen Original und neue Fassung gleichzeitig auf der Platte.${aus}"
    return 1
  fi

  local stapel; stapel="$(date '+%Y-%m-%d_%H%M%S')"
  local ziel="$QUARANTAENE/$stapel"
  local manifest="$ziel/_manifest.tsv"
  mkdir -p "$ziel"; touch "$manifest"
  local tmpdir="$ARBEIT/video_arbeit"
  rm -rf "$tmpdir"; mkdir -p "$tmpdir"

  local fertig=0 misslungen=0 gespart=0 i=0
  local zeile
  while IFS= read -r zeile <&3; do
    local st; st="$(printf '%s' "$zeile" | cut -f1)"
    [ "$st" = "go" ] || continue
    i=$((i+1))
    local pfad verpackt kb
    pfad="$(printf '%s' "$zeile" | cut -f2)"
    verpackt="$(printf '%s' "$zeile" | cut -f3)"
    kb="$(printf '%s' "$zeile" | cut -f9)"
    [ -e "$pfad" ] || { warn "verschwunden: ${pfad/#$HOME/$TILDE}"; continue; }
    ist_geschuetzt "$pfad" && { warn "geschützt, übersprungen: ${pfad/#$HOME/$TILDE}"; continue; }

    printf '\n%s[%d/%d]%s %s\n' "$grau" "$i" "$anzahl" "$aus" "${pfad/#$HOME/$TILDE}"

    # Quelle bereitstellen (ZIP wird zum Kodieren ausgepackt)
    local quelle="$pfad" ausgepackt=""
    if [ "$verpackt" = "ja" ]; then
      rm -rf "$tmpdir/aus"; mkdir -p "$tmpdir/aus"
      unzip -o -q "$pfad" -d "$tmpdir/aus" 2>/dev/null
      ausgepackt="$(find "$tmpdir/aus" -type f -size +1M 2>/dev/null | head -1)"
      [ -n "$ausgepackt" ] || { warn "  ZIP liess sich nicht öffnen"; misslungen=$((misslungen+1)); continue; }
      quelle="$ausgepackt"
    fi

    local neu="$tmpdir/neu.mp4"
    rm -f "$neu"
    local start; start="$(date +%s)"
    local -a skalierung=()
    if [ "$zielhoehe" -gt 0 ]; then
      # min() verhindert, dass kleinere Videos hochskaliert werden
      skalierung=(-vf "scale=-2:'min($zielhoehe,ih)'")
    fi
    # -map 0:v:0 -map 0:a? nimmt alle Tonspuren mit. Ohne -map waehlt ffmpeg
    # nur eine aus, und 16 der Testdateien hatten zwei.
    local dauer_s; dauer_s="$(printf '%s' "$zeile" | cut -f8)"
    if ! video_ffmpeg "$dauer_s" "kodiere" -i "$quelle" \
         -map 0:v:0 -map "0:a?" \
         "${skalierung[@]+"${skalierung[@]}"}" "${enc[@]}" -c:a copy -movflags +faststart "$neu"; then
      # Manche Kameras legen Ton ab, den ein MP4 nicht aufnimmt (etwa PCM).
      # Dann neu kodieren statt aufzugeben.
      printf '  %sTon lässt sich nicht übernehmen, kodiere ihn neu …%s\n' "$grau" "$aus"
      if ! video_ffmpeg "$dauer_s" "kodiere (Ton neu)" -i "$quelle" \
           -map 0:v:0 -map "0:a?" \
           "${skalierung[@]+"${skalierung[@]}"}" "${enc[@]}" -c:a aac -b:a 192k -movflags +faststart "$neu"; then
        printf '  %s✗%s Kodieren fehlgeschlagen\n' "$rot" "$aus"
        misslungen=$((misslungen+1)); rm -f "$neu"; rm -rf "$tmpdir/aus"; continue
      fi
    fi
    local dauer_s=$(( $(date +%s) - start ))

    local grund
    if ! grund="$(video_pruefen "$neu" "$quelle")"; then
      printf '  %s✗%s %s — Original bleibt unangetastet\n' "$rot" "$aus" "$grund"
      misslungen=$((misslungen+1)); rm -f "$neu"; rm -rf "$tmpdir/aus"; continue
    fi

    # Original ins Fegefeuer, neue Datei an seinen Platz
    local rel="${pfad#$HOME/}"
    mkdir -p "$(dirname "$ziel/$rel")"
    if ! mv "$pfad" "$ziel/$rel" 2>/dev/null; then
      printf '  %s✗%s Original liess sich nicht sichern\n' "$rot" "$aus"
      misslungen=$((misslungen+1)); rm -f "$neu"; rm -rf "$tmpdir/aus"; continue
    fi
    # Vierte Spalte: nicht bloss beiseitegelegt, sondern durch eine neu
    # kodierte Fassung ersetzt. pruefen und purge muessen das auseinanderhalten.
    printf '%s\t%s\t%s\t%s\n' "$rel" "$pfad" "$kb" "ersetzt" >> "$manifest"

    local zielname="${pfad%.zip}"
    zielname="${zielname%.*}.mp4"
    # Aus film.mov wird film.mp4 -- das darf keine fremde Datei ueberschreiben.
    if [ -e "$zielname" ] && [ "$zielname" != "$pfad" ]; then
      local i=2
      while [ -e "${zielname%.mp4} ($i).mp4" ]; do i=$((i+1)); done
      zielname="${zielname%.mp4} ($i).mp4"
      warn "  Zielname war belegt, lege ab als $(basename "$zielname")"
    fi
    mv "$neu" "$zielname"
    rm -rf "$tmpdir/aus"

    local neu_kb; neu_kb="$(du -sk "$zielname" 2>/dev/null | cut -f1)"
    gespart=$(( gespart + kb - neu_kb ))
    fertig=$((fertig+1))
    printf '  %s✓%s %s → %s   %s(SSIM %s, %d min)%s\n' "$gruen" "$aus" \
      "$(mb "$kb")" "$(mb "$neu_kb")" "$grau" "$(zahl "$grund" 3)" "$((dauer_s/60))" "$aus"

    # Zustand sofort festhalten: ein Abbruch kostet hoechstens die laufende Datei
    awk -F'\t' -v OFS='\t' -v p="$pfad" '$2==p{$1="fertig"} {print}' "$VIDEOLISTE" > "$VIDEOLISTE.tmp" \
      && mv "$VIDEOLISTE.tmp" "$VIDEOLISTE"
  done 3< "$VIDEOLISTE"

  rm -rf "$tmpdir"
  [ -s "$manifest" ] || { rm -f "$manifest"; rmdir "$ziel" 2>/dev/null; }

  info "\n${gruen}$fertig neu kodiert${aus}, $(mb "$gespart") gespart"
  [ "$misslungen" -gt 0 ] && warn "$misslungen fehlgeschlagen — die Originale liegen unverändert an ihrem Platz"
  if [ "$fertig" -gt 0 ]; then
    info "\nDie Originale liegen im Fegefeuer: ${fett}$stapel${aus}"
    info "Erst ansehen, dann: ${fett}$0 purge${aus}   ·   zurück mit: ${fett}$0 restore $stapel${aus}"
  fi
}

befehl_video() {
  case "${1:-hilfe}" in
    scan)   shift; befehl_video_scan "${1:-$HOME}";;
    review) shift; befehl_video_review;;
    run)    shift; befehl_video_run "$@";;
    *) info "${fett}$0 video${aus} <scan|review|run>"
       info "  ${fett}scan${aus} [pfad]              vermessen, nichts anfassen"
       info "  ${fett}review${aus}                   auswählen, was neu kodiert wird"
       info "  ${fett}run${aus} [--profil <name>] [--auf 1080p]"
       info "                             ${grau}kodieren, prüfen, Original ins Fegefeuer"
       info "                             ohne --profil wird gefragt"
       info "                             --auf verkleinert zusätzlich — das ist endgültig${aus}"
       echo
       info "  ${fett}Profile${aus}"
       local pn pb
       for pn in $(video_profil_namen); do
         printf '    %s%-9s%s %-22s %s%s%s\n' "$fett" "$pn" "$aus" \
           "$(video_profil_feld "$pn" 1)" "$grau" "$(video_profil_feld "$pn" 2)" "$aus"
       done;;
  esac
}

# ---------- Hilfe ----------
befehl_hilfe() {
  cat <<HILFE
${fett}fegefeuer.sh${aus} — Festplatte aufräumen ohne Reue

  ${fett}scan${aus}              Festplatte analysieren, Kandidaten sammeln
  ${fett}review${aus} [kategorie] Kandidaten durchgehen; Einträge desselben Programms
                    werden zu einer Entscheidung zusammengefasst
  ${fett}mark${aus} <kat> <status> Ganze Kategorie auf go/keep setzen (Sammelentscheidung)
  ${fett}zeigen${aus} [kategorie]  Aktuelle Entscheidungen auflisten
  ${fett}gruppen${aus} [kategorie] Offene Gruppen anzeigen, größte zuerst
  ${fett}apply${aus}             Entschiedenes in die Quarantäne verschieben
  ${fett}brew${aus}              Homebrew durchleuchten, Deinstallations-Vorschlag erzeugen
  ${fett}video${aus} <scan|review|run>
                    Videos vermessen, auswählen und neu kodieren
                    ${grau}(braucht ffmpeg; Original wandert erst nach bestandener Prüfung
                     ins Fegefeuer)${aus}
  ${fett}list${aus}              Quarantäne anzeigen
  ${fett}pruefen${aus}           Zeigen, was sich von selbst wieder aufgebaut hat
  ${fett}restore${aus} <stapel>  Einen Stapel zurückholen
                    ${grau}--ueberspringen${aus}   belegte Pfade nicht anfassen (Standard)
                    ${grau}--ersetzen${aus}        aktuelle Fassung beiseitelegen, alte zurück
                    ${grau}--zusammenfuehren${aus} Ordner nur um fehlende Dateien ergänzen
  ${fett}purge${aus} [tage]      Quarantäne endgültig löschen (Standard: älter als 7 Tage)
  ${fett}purge --wieder-da${aus} [stapel]
                    Nur löschen, was am Originalort wieder existiert

Kategorien: app-rest, cache, toolchain, gross, dublette

${grau}Ablauf:  scan → review → apply → (ein paar Tage warten) → purge${aus}
HILFE
}

case "${1:-hilfe}" in
  hilfe|-h|--help|"") befehl_hilfe; exit 0;;
esac

pruefe_umgebung || exit 1

if [ ! -d "$QUARANTAENE" ] && [ -d "$QUARANTAENE_ALT" ]; then
  warn "Gefunden: die ältere Quarantäne $QUARANTAENE_ALT"
  info "${grau}Sie wird weiter verwendet. Zum Umstellen:${aus}"
  info "  mv \"$QUARANTAENE_ALT\" \"$QUARANTAENE\""
  QUARANTAENE="$QUARANTAENE_ALT"
fi

case "${1:-hilfe}" in
  scan) befehl_scan;;
  review) befehl_review "${2:-}";;
  apply) befehl_apply;;
  list) befehl_list;;
  restore) shift; befehl_restore "$@";;
  mark) befehl_mark "${2:-}" "${3:-}";;
  zeigen) befehl_zeigen "${2:-}";;
  gruppen) befehl_gruppen "${2:-}";;
  brew) befehl_brew;;
  video) shift; befehl_video "$@";;
  purge) shift; befehl_purge "$@";;
  pruefen) befehl_pruefen;;
  *) befehl_hilfe;;
esac
