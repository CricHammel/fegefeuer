# lib/scan.sh -- scan: Kandidaten sammeln und den Bericht schreiben.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- App installiert? ----------
app_existiert() {
  mdfind "kMDItemCFBundleIdentifier == '$1'c" 2>/dev/null | grep -qiE '\.(app|appex)$'
}

# Findet Spotlight die Apps, die jedes macOS mitbringt? Sonst ist der Index
# aus oder kaputt, app_existiert verneint alles -- und jeder Library-Ordner
# gaelte als Rest einer deinstallierten App.
spotlight_tauglich() {
  local id
  for id in com.apple.finder com.apple.Safari com.apple.TextEdit; do
    app_existiert "$id" && return 0
  done
  return 1
}

# Loest einen nvm-Alias zu einer installierten Version auf, so wie nvm es
# taete: "20" ist die neueste installierte 20.x, "node" die neueste
# ueberhaupt, "lts/*" und andere Namen stehen als Datei unter alias/ und
# zeigen weiter. Rueckgabe 1, wenn nichts Installiertes passt; "system"
# heisst: keine nvm-Version, Ausgabe leer.
nvm_aufloesen() {   # nvm_aufloesen <alias> [tiefe]
  local a="$1" tiefe="${2:-0}" nvm="$HOME/.nvm" treffer
  [ "$tiefe" -lt 5 ] || return 1   # gegen Kreise in den Aliasen
  case "$a" in
    system) return 0;;
    node|stable) treffer="$(ls -1 "$nvm/versions/node" 2>/dev/null | sort -V | tail -1)";;
    v[0-9]*|[0-9]*)
      local v="${a#v}"
      treffer="$(ls -1 "$nvm/versions/node" 2>/dev/null | grep -E "^v${v//./\\.}(\\.|$)" | sort -V | tail -1)";;
    *)
      [ -f "$nvm/alias/$a" ] || return 1
      nvm_aufloesen "$(head -1 "$nvm/alias/$a")" $((tiefe + 1))
      return $?;;
  esac
  [ -n "$treffer" ] || return 1
  printf '%s\n' "$treffer"
}

# Die Orte, die scan einzeln durchsucht: was direkt im Home liegt und, wo
# gefragt, die Unterordner von ~/Library -- dort liegt das meiste. Ein
# einziges find ueber alles sagt nicht, wie weit es ist; Ort fuer Ort laesst
# sich ein Balken zeigen. NUL-getrennt.
such_orte() {   # such_orte [ohne-library]
  find "$HOME" -mindepth 1 -maxdepth 1 ! -path "$HOME/Library" -print0 2>/dev/null
  [ "${1:-}" = "ohne-library" ] && return 0
  find "$HOME/Library" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
}

# Ort fuer die Fortschrittszeile: mit ~ und hoechstens 40 Zeichen, damit die
# Zeile nicht umbricht und sich nicht mehr selbst ueberschreibt.
ort_kurz() {   # ort_kurz <pfad>
  local k="${1/#$HOME/$TILDE}"
  [ ${#k} -gt 40 ] && k="${k:0:39}…"
  printf '%s' "$k"
}

# ---------- Schritt 1: App-Reste ----------
scan_app_reste() {
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
      # App-Daten liegen in Ordnern. Eine Datei mit Punkt im Namen ist fast
      # immer ein Dateiname, keine Bundle-ID -- fsck_hfs.log oder
      # default.store sind keine Programmreste. Ausgenommen sind die zwei
      # Formen, die als Datei auftreten und sehr wohl eine Bundle-ID tragen.
      if [ ! -d "$e" ]; then
        case "$b" in
          *.savedState|*.binarycookies) ;;
          *) continue;;
        esac
      fi
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
        kandidat_schreiben "app-rest" "$e" "keine App mit Bundle-ID '$id' installiert"
      fi
    done
  done
  fortschritt_ende
  info "  $geprueft geprüft, ${fett}$gefunden${aus} ohne zugehörige App"
}

# ---------- scan ----------
befehl_scan() {
  local dubletten_ab="1M"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dubletten-ab) shift; dubletten_ab="${1:-1M}";;
      --dubletten-ab=*) dubletten_ab="${1#*=}";;
      *) fehler "Unbekannte Option: $1"; return 1;;
    esac
    shift
  done
  # Einheit abtrennen und den Rest auf Ziffern pruefen. Nur das letzte
  # Zeichen anzusehen reicht nicht -- "riesig" endet auch auf g.
  local zahl="${dubletten_ab%[kKmMgGcC]}"
  case "$zahl" in
    ''|*[!0-9]*) fehler "--dubletten-ab versteht z.B. 500k, 1M, 10M, 2G."; return 1;;
  esac
  # find unter macOS kennt nur k, M und G (und c fuer Bytes). "10m" oder "2g"
  # liess es mit einem Fehler scheitern, der in 2>/dev/null verschwand -- der
  # Scan meldete dann einfach keine Dubletten. Darum die Schreibweise angleichen.
  local find_groesse="$zahl"
  case "$dubletten_ab" in
    *[kK]) find_groesse="${zahl}k";;
    *[mM]) find_groesse="${zahl}M";;
    *[gG]) find_groesse="${zahl}G";;
    *)     find_groesse="${zahl}c";;   # c/C oder nackte Zahl = Bytes
  esac
  # Und vorab an einem einzelnen Ordner pruefen, ob find die Angabe versteht.
  # Am grossen Lauf laesst sich das nicht ablesen: der scheitert ohnehin
  # regelmaessig an geschuetzten Ordnern und endet mit Fehlercode.
  if ! find "$ARBEIT" -maxdepth 0 -size +"$find_groesse" >/dev/null 2>&1; then
    fehler "find versteht die Größenangabe '$find_groesse' nicht."
    return 1
  fi
  : > "$KANDIDATEN.tmp"
  titel "1/5  Verwaiste App-Reste in ~/Library"
  if spotlight_tauglich; then
    scan_app_reste
  else
    warn "Spotlight findet nicht einmal den Finder — übersprungen."
    info "  ${grau}Ob eine App installiert ist, fragt fegefeuer Spotlight. Ist der Index aus"
    info "  oder kaputt, sähe jeder Ordner in ~/Library verwaist aus. Prüfen mit:${aus}"
    info "    ${fett}mdutil -s /${aus}"
    info "  ${grau}Die übrigen Schritte brauchen Spotlight nicht.${aus}"
  fi

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
    kandidat_schreiben "cache" "$p" "$grund"
  done
  info "  ${fett}$(( ${#caches[@]} ))${aus} Cache-Orte geprüft"

  titel "3/5  Alte Toolchain-Versionen"
  # node: alle ausser der neuesten und der Standardversion. Die Standard-
  # version benutzt jede neue Shell, auch wenn sie nicht die neueste ist.
  # Laesst sie sich nicht bestimmen, wird nichts vorgeschlagen -- lieber
  # kein Vorschlag als die Version, mit der alles laeuft.
  if [ -d "$HOME/.nvm/versions/node" ]; then
    local neueste standard="" standard_ok=1
    neueste="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    if [ -f "$HOME/.nvm/alias/default" ]; then
      local standard_alias; standard_alias="$(head -1 "$HOME/.nvm/alias/default")"
      standard="$(nvm_aufloesen "$standard_alias")" || standard_ok=0
    fi
    if [ "$standard_ok" -eq 0 ]; then
      warn "Node-Standardversion '$standard_alias' passt zu keiner installierten — keine Node-Version vorgeschlagen."
    else
      local behalten="neueste: $neueste"
      [ -n "$standard" ] && [ "$standard" != "$neueste" ] && behalten="$behalten, Standard: $standard"
      for v in "$HOME/.nvm/versions/node"/*; do
        [ -d "$v" ] || continue
        case "$(basename "$v")" in "$neueste"|"$standard") continue;; esac
        kandidat_schreiben "toolchain" "$v" "alte Node-Version ($behalten)"
      done
    fi
  fi
  # playwright: alte Browser-Builds
  if [ -d "$HOME/Library/Caches/ms-playwright" ]; then
    for familie in chromium chromium_headless_shell firefox webkit; do
      local neueste
      neueste="$(ls -1d "$HOME/Library/Caches/ms-playwright/$familie"-* 2>/dev/null | sort -V | tail -1)"
      for b in "$HOME/Library/Caches/ms-playwright/$familie"-*; do
        [ -d "$b" ] || continue
        [ "$b" = "$neueste" ] && continue
        kandidat_schreiben "toolchain" "$b" "alter Playwright-Build (neuester: $(basename "$neueste"))"
      done
    done
  fi
  info "  fertig"

  titel "4/5  Große Dateien und Pakete (>200 MB)"
  local n=0 paket_kb ort i
  local -a orte=()
  while IFS= read -r -d '' ort; do orte+=("$ort"); done < <(such_orte)
  # Ein Durchlauf fuer beides: Ein Paket (App, VM, Projekt) wird als Ganzes
  # gemeldet, und -prune verhindert, dass find hineinsteigt -- seine
  # Einzeldateien zu verschieben beschaedigte es.
  local -a ausschluss=(! -path "*/.Trash/*" "${MEDIATHEK_AUSSCHLUSS[@]}" "${INTERN_AUSSCHLUSS[@]}"
                       "${WOLKEN_AUSSCHLUSS[@]}")
  fortschritt_start
  i=0
  for ort in "${orte[@]+"${orte[@]}"}"; do
    fortschritt "$i" "${#orte[@]}" "durchsuche $(ort_kurz "$ort")"
    i=$((i + 1))
    while IFS= read -r -d '' f; do
      ist_geschuetzt "$f" && continue
      if [ -d "$f" ]; then
        paket_kb="$(du -sk -x "$f" 2>/dev/null | cut -f1)"
        [ "${paket_kb:-0}" -gt 204800 ] || continue
        kandidat_schreiben "gross" "$f" "$(paket_art "$f") — nur als Ganzes verschiebbar"
      else
        kandidat_schreiben "gross" "$f" "große Einzeldatei — bitte einzeln prüfen"
      fi
      n=$((n+1))
    done < <(find "$ort" "${ausschluss[@]}" \
               \( -type d \( "${PAKET_NAMEN[@]}" \) -print0 -prune \
                  -o -type f -size +200M -print0 \) 2>/dev/null)
  done
  fortschritt "${#orte[@]}" "${#orte[@]}" "durchsucht"
  fortschritt_ende
  info "  ${fett}$n${aus} gefunden"

  titel "5/5  Doppelte Dateien (ab $dubletten_ab, gleicher Inhalt)"
  local hashdatei="$ARBEIT/hashes.tsv"
  local dateiliste="$ARBEIT/hash_liste.txt"
  local rohhashes="$ARBEIT/hash_roh.txt"
  local groessen="$ARBEIT/hash_groessen.txt"
  # ~/Library bleibt komplett aussen vor: dort liegen Systemindex und
  # OneDrive-Sync -- gleiche Inhalte sind da gewollt bzw. serverseitig.
  # Darum such_orte ohne ~/Library: find steigt gar nicht erst hinein.
  orte=()
  while IFS= read -r -d '' ort; do orte+=("$ort"); done < <(such_orte ohne-library)
  : > "$dateiliste"
  fortschritt_start
  i=0
  for ort in "${orte[@]+"${orte[@]}"}"; do
    fortschritt "$i" "${#orte[@]}" "sammle $(ort_kurz "$ort")"
    i=$((i + 1))
    find "$ort" -type f -size +"$find_groesse" \
      ! -path "*/.Trash/*" ! -path "*/node_modules/*" \
      ! -path "*/.git/*" ! -path "*/.nvm/*" ! -path "*/.pyenv/*" ! -path "*/.m2/*" \
      ! -path "*/.cargo/*" "${MEDIATHEK_AUSSCHLUSS[@]}" "${INTERN_AUSSCHLUSS[@]}" "${WOLKEN_AUSSCHLUSS[@]}" \
      "${PAKET_AUSSCHLUSS[@]}" "${UMGEBUNG_AUSSCHLUSS[@]}" \
      -print0 2>/dev/null >> "$dateiliste"
  done
  fortschritt "${#orte[@]}" "${#orte[@]}" "gesammelt"
  fortschritt_ende

  # Gehasht wird nur, was eine gleich grosse Partnerdatei hat -- Dubletten
  # sind gleich gross. Auf einem echten Mac blieben so von 41 GB nur 1,1 GB,
  # und eine einzelne Datei von 15,8 GB fiel weg, die allein die Haelfte der
  # Zeit kostete.
  local zu_hashen zu_hashen_kb gesammelt
  gesammelt="$(tr -dc '\0' < "$dateiliste" | wc -c | tr -d ' ')"
  xargs -0 stat -f '%z %N' < "$dateiliste" 2>/dev/null \
    | LC_ALL=C awk '{ g = $1; p = substr($0, length(g) + 2); groesse[NR] = g; pfad[NR] = p; anzahl[g]++ }
        END { for (i = 1; i <= NR; i++) if (anzahl[groesse[i]] >= 2) print groesse[i] "\t" pfad[i] }' \
    > "$groessen"
  zu_hashen="$(wc -l < "$groessen" | tr -d ' ')"
  zu_hashen_kb="$(awk -F'\t' '{ s += $1 } END { printf "%d", s / 1024 }' "$groessen")"
  LC_ALL=C awk -F'\t' '{ printf "%s%c", $2, 0 }' "$groessen" > "$dateiliste"
  info "  ${grau}$gesammelt Dateien, $zu_hashen davon mit gleich großer Partnerdatei ($(mb "$zu_hashen_kb")) werden geprüft${aus}"

  # Der Balken zaehlt Bytes, nicht Dateien: Eine einzige grosse Datei kostet
  # mehr Zeit als Tausende kleine, und ein Balken nach Dateien stand dann
  # lange kurz vor dem Ende.
  : > "$rohhashes"
  fortschritt_start
  xargs -0 -P 8 -n 200 shasum -a 1 < "$dateiliste" > "$rohhashes" 2>/dev/null &
  local hash_pid=$!
  while kill -0 "$hash_pid" 2>/dev/null; do
    fortschritt "$(LC_ALL=C awk -F'\t' 'NR == FNR { g[$2] = $1; next }
        { s += g[substr($0, 43)] } END { printf "%d", s / 1024 }' "$groessen" "$rohhashes")" \
      "$zu_hashen_kb" "Prüfsummen berechnen"
    sleep 1
  done
  wait "$hash_pid" 2>/dev/null
  fortschritt "$zu_hashen_kb" "$zu_hashen_kb" "Prüfsummen berechnen"
  fortschritt_ende

  awk '{ print substr($0,1,40) "\t" substr($0,43) }' "$rohhashes" | sort > "$hashdatei"
  rm -f "$dateiliste" "$rohhashes" "$groessen"

  # Alle Mitglieder einer Gruppe werden Kandidaten und bekommen denselben
  # Gruppenschluessel. Erst im review wird entschieden, welche Kopie bleibt --
  # vorher legte die Sortierung das fest, was bei "Kopie von X" neben "X"
  # genau die falsche Datei behalten haette.
  # Erst aussieben, dann gruppieren. Andersherum bliebe von einer Gruppe, deren
  # andere Mitglieder geschuetzt oder verschwunden sind, eine einzelne Datei
  # als "Dublette" stehen -- und im review haette j die letzte Kopie verschoben.
  local gesiebt="$ARBEIT/hash_gesiebt.tsv"
  : > "$gesiebt"
  local dubletten=0 gruppen=0 h p
  while IFS=$'\t' read -r h p; do
    ist_geschuetzt "$p" && continue
    [ -e "$p" ] || continue
    printf '%s\t%s\n' "$h" "$p" >> "$gesiebt"
  done < <(LC_ALL=C awk -F'\t' 'NR==FNR { anzahl[$1]++; next } anzahl[$1] >= 2' "$hashdatei" "$hashdatei")
  while IFS=$'\t' read -r h p; do
    kandidat_schreiben "dublette" "$p" "eine von mehreren inhaltsgleichen Dateien" "dub-${h:0:12}"
    dubletten=$((dubletten + 1))
  done < <(LC_ALL=C awk -F'\t' 'NR==FNR { anzahl[$1]++; next } anzahl[$1] >= 2' "$gesiebt" "$gesiebt")
  rm -f "$gesiebt"
  gruppen="$(awk -F'\t' '$2=="dublette"{print $7}' "$KANDIDATEN.tmp" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  info "  ${fett}$dubletten${aus} Dateien in ${fett}$gruppen${aus} Gruppen"

  # Bestehende keep/go-Entscheidungen übernehmen
  if [ -s "$KANDIDATEN" ]; then
    # FILENAME statt NR==FNR: bei leerer erster Datei wuerde NR==FNR auf jede
    # Zeile der zweiten zutreffen und den gesamten neuen Scan verschlucken.
    # Schluessel ist Kategorie und Pfad: Eine grosse Datei steht oft zugleich
    # als Dublette in der Liste, und die Entscheidung der einen Zeile darf
    # nicht auf die andere ueberspringen.
    awk -F'\t' -v OFS='\t' '
        FILENAME==ARGV[1] { if ($1!="neu") status[$2 SUBSEP $5]=$1; next }
        { if (($2 SUBSEP $5) in status) $1=status[$2 SUBSEP $5]; print }' \
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
  local roh echt
  roh="$(awk -F'\t' '{s+=$3} END{print s+0}' "$KANDIDATEN")"
  echt="$(summe_echt)"
  info "  Gesamt:     $(mb "$echt")"
  if [ "$roh" -gt "$echt" ]; then
    info "  ${grau}($(mb $((roh - echt))) davon liegen innerhalb anderer Kandidaten und zählen nur einmal)${aus}"
  fi
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
