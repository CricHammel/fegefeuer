# lib/review.sh -- review, mark, zeigen, gruppen: Kandidaten durchgehen und entscheiden.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- review ----------
# Reihenfolge der Durchsicht. Gruppen aus demselben Ordner kommen
# hintereinander -- verstreut musste man bei jeder Frage neu umdenken, etwa
# zwischen "Kopie weg" in einem Ordnerpaar und "beide behalten" im naechsten.
# Ein Block ist der Ordner eines Eintrags, bei Dubletten das Ordnerpaar
# "A ⇄ B", bei App-Resten die Gruppe des Herstellers. Die Bloecke kommen nach
# ihrer Groesse, darin die Gruppen nach ihrer -- das Lohnende zuerst. Es
# zaehlen nur offene Eintraege.
# Ausgabe je Zeile: Block, Zahl seiner offenen Gruppen, Kandidatenzeile.
review_sortieren() {   # review_sortieren <kandidatendatei>
  LC_ALL=C awk -F'\t' -v OFS='\t' -v h="$HOME" '
    function ordner(p) {
      sub(/\/[^\/]*$/, "", p)
      if (index(p, h "/") == 1) p = "~" substr(p, length(h) + 1)
      return p
    }
    function block_von(g,   n, t, a, c, x, b) {
      if (kat[g] == "app-rest") return "app-rest " g
      if (kat[g] != "dublette") return ordner(erster[g])
      n = split(orte[g], t, "\n")
      for (a = 1; a <= n; a++) for (c = a + 1; c <= n; c++) if (t[c] < t[a]) { x = t[a]; t[a] = t[c]; t[c] = x }
      b = t[1]
      for (a = 2; a <= n; a++) b = b " ⇄ " t[a]
      return b
    }
    NR == FNR {
      if (!($7 in kat)) { kat[$7] = $2; erster[$7] = $5 }
      if ($1 == "neu") { summe[$7] += $3; offen[$7] = 1 }
      if ($2 == "dublette") {
        o = ordner($5)
        if (index("\n" orte[$7] "\n", "\n" o "\n") == 0) orte[$7] = (orte[$7] == "" ? o : orte[$7] "\n" o)
      }
      next
    }
    FNR == 1 {
      for (g in kat) {
        block[g] = block_von(g)
        bsumme[block[g]] += summe[g]
        if (g in offen) banzahl[block[g]]++
      }
    }
    { b = block[$7]; print bsumme[b] + 0, b, summe[$7] + 0, banzahl[b] + 0, $0 }' "$1" "$1" \
  | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 -k3,3nr -k11,11 -k7,7nr \
  | cut -f2,4-
}

# Eintraege desselben Programms liegen ueber viele Library-Ordner verstreut.
# Sie werden zu einer Gruppe zusammengefasst und gemeinsam entschieden.
R_PUFFER=()
R_AUSGABE=()
R_BLOCK=""            # Block der Gruppe in R_PUFFER (siehe review_sortieren)
R_BLOCK_N=0           # wie viele offene Gruppen dieser Block hat
R_BLOCK_GEZEIGT=""    # zuletzt angekuendigter Block
R_GO_PFADE=""
R_UEBERDECKT=0
R_ABBRUCH=0
R_NR=0
R_GESAMT=0

# Gibt einen Eintrag frei und merkt sich seinen Pfad: Was darin liegt, wandert
# mit und wird danach nicht mehr gefragt. Alle Freigaben laufen hierueber --
# frueher stand das Merken an jeder Stelle einzeln und fehlte beim einzelnen
# Durchgehen einer Gruppe.
r_freigeben() {   # r_freigeben <zeile>
  local st kt kb mt pfad
  felder_lesen "$1" st kt kb mt pfad
  R_AUSGABE+=("$(status_setzen "$1" go)")
  R_GO_PFADE="$R_GO_PFADE
$pfad"
}

r_einzeln_fragen() {   # r_einzeln_fragen <zeile>  -> Antwort in R_ANTWORT
  local zeile="$1"
  local st kt kb mt pfad grund
  felder_lesen "$zeile" st kt kb mt pfad grund
  printf '    %s%9s%s  %s\n' "$fett" "$(mb "$kb")" "$aus" "${pfad/#$HOME/$TILDE}"
  printf '    %s%s · %s%s\n' "$grau" "$grund" "$mt" "$aus"
  local antwort
  while true; do
    tasten "    " "j:weg" "n:behalten" "o:Finder" "s:später" "q:Ende"
    printf '    → '
    read -r antwort || antwort=q
    case "$antwort" in
      j|J|n|N|s|S|q|Q) R_ANTWORT="$antwort"; return 0;;
      "") R_ANTWORT=s; return 0;;
      o|O) open -R "$pfad" 2>/dev/null;;
      *) tasten_bitte '    ';;
    esac
  done
}

r_gruppe_abschliessen() {
  local anzahl=${#R_PUFFER[@]}
  [ "$anzahl" -eq 0 ] && return 0
  local zeile st kt mt pfad

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
    felder_lesen "$zeile" st kt kb
    if [ "$st" = "neu" ]; then
      offen+=("$zeile")
      offen_kb=$((offen_kb + kb))
    else
      entschieden=$((entschieden + 1))
      R_AUSGABE+=("$zeile")
    fi
  done
  local n_offen=${#offen[@]}
  [ "$n_offen" -eq 0 ] && return 0

  # Liegt alles davon in einem bereits freigegebenen Ordner? Dann eruebrigt
  # sich die Frage -- es wandert ohnehin mit.
  local alle_drin=1 pruef
  for zeile in "${offen[@]}"; do
    felder_lesen "$zeile" st kt kb mt pruef
    liegt_innerhalb "$pruef" "$R_GO_PFADE" || { alle_drin=0; break; }
  done
  if [ "$alle_drin" -eq 1 ]; then
    for zeile in "${offen[@]}"; do
      r_freigeben "$zeile"
      R_UEBERDECKT=$((R_UEBERDECKT + 1))
    done
    return 0
  fi

  # Neuer Block mit mehreren Gruppen: ankuendigen, dass jetzt Aehnliches kommt
  if [ "$R_BLOCK" != "$R_BLOCK_GEZEIGT" ]; then
    R_BLOCK_GEZEIGT="$R_BLOCK"
    [ "$R_BLOCK_N" -ge 2 ] && printf '\n%s── %s · %d Gruppen%s\n' "$fett" "$R_BLOCK" "$R_BLOCK_N" "$aus"
  fi

  R_NR=$((R_NR + 1))
  local etikett grund1 pfad1 mt1 kategorie grp1
  felder_lesen "${offen[0]}" st kategorie kb mt1 pfad1 grund1 grp1 etikett
  [ -n "$etikett" ] || etikett="$(basename "$pfad1")"

  # --- Dubletten: die Frage lautet nicht "weg oder nicht", sondern
  # "welche von diesen gleichen Dateien soll bleiben". Es muss immer eine
  # uebrig bleiben -- ein Griff, der alle loescht, gibt es hier nicht.
  if [ "$kategorie" = "dublette" ] && [ "$n_offen" -ge 2 ]; then
    local -a nach_alter=()
    while IFS= read -r zeile; do nach_alter+=("$zeile"); done < <(printf '%s\n' "${offen[@]}" | sort -t$'\t' -k4,4)
    local erstes_kb pfad_aelteste
    felder_lesen "${nach_alter[0]}" st kt erstes_kb mt pfad_aelteste
    printf '\n%s[%d/%d]%s %s%d gleiche Dateien%s %s· je %s%s\n' \
      "$grau" "$R_NR" "$R_GESAMT" "$aus" "$fett" "$n_offen" "$aus" "$grau" "$(mb "$erstes_kb")" "$aus"
    local i=0 pfad mtime zusatz
    for zeile in "${nach_alter[@]}"; do
      i=$((i + 1))
      felder_lesen "$zeile" st kt kb mtime pfad
      zusatz=""
      [ "$i" -eq 1 ] && zusatz="  ${gruen}← älteste, Vorschlag${aus}"
      printf '  %s%d%s  %-52s %s%s%s%s\n' "$fett" "$i" "$aus" \
        "${pfad/#$HOME/$TILDE}" "$grau" "$mtime" "$aus" "$zusatz"
    done
    [ "$entschieden" -gt 0 ] && printf '  %s(%d weitere dieser Gruppe hast du schon entschieden)%s\n' "$grau" "$entschieden" "$aus"
    printf '  %sWelche soll bleiben? Die anderen wandern ins Fegefeuer.%s\n' "$grau" "$aus"
    local antwort k
    while true; do
      tasten "  " "1-$n_offen:diese behalten" "n:alle behalten" "o:Finder" "s:später" "q:Ende"
      printf '  → '
      read -r antwort || antwort=q
      case "$antwort" in
        n|N) for zeile in "${nach_alter[@]}"; do R_AUSGABE+=("$(status_setzen "$zeile" keep)"); done; return 0;;
        o|O) open -R "$pfad_aelteste" 2>/dev/null;;
        s|S|"") for zeile in "${nach_alter[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
        q|Q) R_ABBRUCH=1; for zeile in "${nach_alter[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
        *[!0-9]*|'') tasten_bitte '  ';;
        *)
          k="$antwort"
          if [ "$k" -ge 1 ] && [ "$k" -le "$n_offen" ]; then
            i=0
            for zeile in "${nach_alter[@]}"; do
              i=$((i + 1))
              if [ "$i" -eq "$k" ]; then
                R_AUSGABE+=("$(status_setzen "$zeile" keep)")
              else
                r_freigeben "$zeile"
              fi
            done
            return 0
          fi
          tasten_bitte '  ';;
      esac
    done
  fi

  # --- nur ein offener Eintrag: schlichte Ansicht ---
  if [ "$n_offen" -eq 1 ]; then
    printf '\n%s[%d/%d]%s %s%s%s\n' "$grau" "$R_NR" "$R_GESAMT" "$aus" "$fett" "$(mb "$offen_kb")" "$aus"
    printf '  %s\n' "${pfad1/#$HOME/$TILDE}"
    printf '  %s%s · geändert %s%s\n' "$grau" "$grund1" "$mt1" "$aus"
    if [ -d "$pfad1" ]; then
      printf '  %sInhalt: %s%s\n' "$grau" "$(ls -1 "$pfad1" 2>/dev/null | head -4 | tr '\n' ' ')" "$aus"
      local enthaltene
      enthaltene="$(awk -F'\t' -v p="$pfad1/" 'index($5,p)==1 {n++; s+=$3} END{printf "%d %d", n+0, s+0}' "$KANDIDATEN")"
      if [ "${enthaltene%% *}" -gt 0 ]; then
        printf '  %senthält %s weitere Kandidaten (%s) — die wandern mit%s\n' \
          "$grau" "${enthaltene%% *}" "$(mb "${enthaltene##* }")" "$aus"
      fi
    fi
    [ "$entschieden" -gt 0 ] && printf '  %s(%d weitere Einträge dieser Gruppe hast du schon entschieden)%s\n' "$grau" "$entschieden" "$aus"
    local antwort
    while true; do
      tasten "  " "j:weg" "n:behalten" "o:im Finder zeigen" "s:später" "q:Ende"
      printf '  → '
      read -r antwort || antwort=q
      case "$antwort" in
        j|J) r_freigeben "${offen[0]}"; return 0;;
        n|N) R_AUSGABE+=("$(status_setzen "${offen[0]}" keep)"); return 0;;
        o|O) open -R "$pfad1" 2>/dev/null;;
        s|S|"") R_AUSGABE+=("${offen[0]}"); return 0;;
        q|Q) R_ABBRUCH=1; R_AUSGABE+=("${offen[0]}"); return 0;;
        *) tasten_bitte '  ';;
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
    felder_lesen "$zeile" st kt kb mtime pfad
    kurz="${pfad#$HOME/Library/}"
    printf '  %9s  %-56s %s%s%s\n' "$(mb "$kb")" "$kurz" "$grau" "$mtime" "$aus"
  done
  printf '  %s%s%s\n' "$grau" "$grund1" "$aus"
  [ "$entschieden" -gt 0 ] && printf '  %s(%d weitere Einträge dieser Gruppe hast du schon entschieden — die bleiben, wie sie sind)%s\n' "$grau" "$entschieden" "$aus"

  local antwort
  while true; do
    tasten "  " "j:alle weg" "n:alle behalten" "e:einzeln durchgehen" "o:Finder" "s:später" "q:Ende"
    printf '  → '
    read -r antwort || antwort=q
    case "$antwort" in
      j|J) for zeile in "${offen[@]}"; do r_freigeben "$zeile"; done; return 0;;
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
            j|J) r_freigeben "$zeile";;
            n|N) R_AUSGABE+=("$(status_setzen "$zeile" keep)");;
            q|Q) R_ABBRUCH=1; R_AUSGABE+=("$zeile");;
            *)   R_AUSGABE+=("$zeile");;
          esac
        done
        return 0;;
      *) tasten_bitte '  ';;
    esac
  done
}

# Strg-C im review: sichern, was bis dahin entschieden ist, dann beenden.
# Ohne das ging die ganze Sitzung verloren, weil erst am Ende geschrieben
# wird. Bash 3.2 bricht ein wartendes read bei einer Falle nicht ab -- die
# Falle muss deshalb selbst sichern und das Skript beenden.
# Die Entscheidungen werden ueber Kategorie und Pfad in die unveraenderte
# Kandidatenliste eingetragen. Alles andere bleibt, wie es war, ganz gleich,
# an welcher Stelle der Durchsicht der Abbruch kam.
r_unterbrochen() {
  trap - INT
  local entscheidungen="$ARBEIT/review_entscheidungen.tsv"
  zeilen_schreiben "$entscheidungen" "${R_AUSGABE[@]+"${R_AUSGABE[@]}"}"
  awk -F'\t' -v OFS='\t' '
      FILENAME==ARGV[1] { if ($1 != "") status[$2 SUBSEP $5] = $1; next }
      (($2 SUBSEP $5) in status) { $1 = status[$2 SUBSEP $5] }
      { print }' "$entscheidungen" "$KANDIDATEN" > "$KANDIDATEN.tmp" \
    && mv "$KANDIDATEN.tmp" "$KANDIDATEN"
  rm -f "$entscheidungen"
  printf '\n'
  info "Unterbrochen. Was du bis hierher entschieden hast, ist gespeichert."
  info "Weiter mit: ${fett}$0 review${kat_filter:+ $kat_filter}${aus}"
  exit 130
}

befehl_review() {
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten. Erst '$0 scan' laufen lassen."; return 1; }
  gruppen_sicherstellen

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
  review_sortieren "$gefiltert" > "$sortiert"
  R_GESAMT="$(awk -F'\t' '$3=="neu"{print $9}' "$sortiert" | sort -u | wc -l | tr -d ' ')"
  [ "$R_GESAMT" -eq 0 ] && { info "Alles in dieser Auswahl ist bereits entschieden."; return 0; }

  info "\n${fett}Durchsicht${aus}  —  ${R_GESAMT} offene $([ "$R_GESAMT" -eq 1 ] && echo Gruppe || echo Gruppen)"
  if [ "$kat_filter" = "dublette" ]; then
    info "${grau}Inhaltsgleiche Dateien stehen zusammen — du wählst, welche bleibt.${aus}"
  else
    info "${grau}Einträge desselben Programms sind zusammengefasst.${aus}"
  fi

  R_PUFFER=(); R_AUSGABE=(); R_ABBRUCH=0; R_NR=0; R_UEBERDECKT=0; R_BLOCK_GEZEIGT=""
  # Schon freigegebene Ordner merken: Was darin liegt, wird mitverschoben
  # und muss nicht noch einmal gefragt werden.
  R_GO_PFADE="$(awk -F'\t' '$1=="go"{print $5}' "$KANDIDATEN")"
  local letzte="" roh block block_n zeile g st kt kb mt pfad grund
  trap r_unterbrochen INT
  while IFS= read -r roh <&3; do
    felder_lesen "$roh" block block_n
    zeile="${roh#*$'\t'}"; zeile="${zeile#*$'\t'}"
    felder_lesen "$zeile" st kt kb mt pfad grund g
    if [ -n "$letzte" ] && [ "$g" != "$letzte" ]; then
      r_gruppe_abschliessen
      R_PUFFER=()
    fi
    letzte="$g"; R_BLOCK="$block"; R_BLOCK_N="$block_n"
    R_PUFFER+=("$zeile")
  done 3< "$sortiert"
  r_gruppe_abschliessen
  trap - INT

  { printf '%s\n' "${R_AUSGABE[@]+"${R_AUSGABE[@]}"}" | grep -v '^$'; cat "$rest"; } \
    | sort -t$'\t' -k2,2 -k3,3nr > "$KANDIDATEN.tmp" && mv "$KANDIDATEN.tmp" "$KANDIDATEN"

  local n_go kb_go
  n_go="$(awk -F'\t' '$1=="go"' "$KANDIDATEN" | wc -l | tr -d ' ') Einträge"
  kb_go="$(summe_echt go)"
  [ "$R_UEBERDECKT" -gt 0 ] && info "\n${grau}$R_UEBERDECKT Einträge lagen in bereits freigegebenen Ordnern — nicht erneut gefragt.${aus}"
  if [ "$R_ABBRUCH" -eq 1 ]; then
    info "\nGespeichert. Weiter mit: ${fett}$0 review${kat_filter:+ $kat_filter}${aus}"
  else
    info "\nDurchsicht fertig."
  fi
  info "Zum Verschieben markiert: ${fett}$n_go ($(mb "$kb_go"))${aus}"
  [ "$R_ABBRUCH" -eq 1 ] || info "Weiter: ${fett}$0 apply${aus}"
}

# ---------- mark ----------
# Sammelentscheidung fuer eine ganze Kategorie, spart Einzelklicks im review.
befehl_mark() {   # befehl_mark <kategorie> <go|keep|neu> [--alle]
  local kat="" status="" alle=0 arg
  for arg in "$@"; do
    case "$arg" in
      --alle) alle=1;;
      -*) fehler "Unbekannte Option: $arg"; return 1;;
      *) if [ -z "$kat" ]; then kat="$arg"; else status="$arg"; fi;;
    esac
  done
  case "$status" in go|keep|neu) ;; *) fehler "Status muss go, keep oder neu sein."; return 1;; esac
  [ -n "$kat" ] || { fehler "Welche Kategorie? (app-rest, cache, toolchain, gross, dublette)"; return 1; }
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  if [ "$kat" = "dublette" ] && [ "$status" = "go" ]; then
    fehler "Bei Dubletten würde das jede Kopie löschen, auch die letzte."
    info "${grau}Dort muss je Gruppe eine Datei bleiben — das entscheidest du im review:${aus}"
    info "  ${fett}$0 review dublette${aus}"
    return 1
  fi
  # Einzeln getroffene Entscheidungen bleiben, wie im review: Eine
  # Sammelantwort wirkt nur auf das, was noch offen ist. "neu" setzt dagegen
  # alles zurueck -- dafuer ist es da. --alle ueberschreibt auch Entschiedenes.
  [ "$status" = "neu" ] && alle=1
  local n n_offen platz
  read -r n n_offen platz <<< "$(awk -F'\t' -v k="$kat" -v alle="$alle" '
      $2==k { n++; if (alle || $1=="neu") { m++; s+=$3 } }
      END { printf "%d\t%d\t%d", n, m, s }' "$KANDIDATEN")"
  [ "$n" -eq 0 ] && { warn "Kategorie '$kat' enthält nichts."; return 0; }
  awk -F'\t' -v OFS='\t' -v k="$kat" -v st="$status" -v alle="$alle" \
    '$2==k && (alle || $1=="neu") { $1=st } { print }' \
    "$KANDIDATEN" > "$KANDIDATEN.tmp" && mv "$KANDIDATEN.tmp" "$KANDIDATEN"
  info "Kategorie ${fett}$kat${aus}: $n_offen Einträge, $(mb "$platz") → ${fett}$status${aus}"
  if [ "$n_offen" -lt "$n" ]; then
    info "${grau}$((n - n_offen)) schon entschiedene Einträge bleiben, wie sie sind."
    info "Auch die überschreiben:${aus} ${fett}$0 mark $kat $status --alle${aus}"
  fi
  info "Prüfen mit: ${fett}$0 zeigen $kat${aus}"
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
  gruppen_sicherstellen
  local kat="${1:-}"
  titel "Offene Gruppen${kat:+ in $kat}"
  awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k) {
        # Zusammengefasst wird nach dem Schluessel, angezeigt das Etikett.
        # Nach dem Etikett zu gruppieren hiesse, zwei Gruppen zu verschmelzen,
        # nur weil ihre Namen zufaellig gleich lauten.
        n[$7]++; s[$7]+=$3; kat[$7]=$2
        if (!($7 in et)) et[$7] = ($8 != "" ? $8 : $5)
      } END { for (g in n) printf "%d\t%d\t%s\t%s\n", s[g], n[g], kat[g], et[g] }' "$KANDIDATEN" \
    | sort -t$'\t' -k1,1nr \
    | while IFS=$'\t' read -r kb n kt g; do
        printf '  %9s  %3d  %-10s %s\n' "$(mb "$kb")" "$n" "$kt" "$g"
      done
  local gz ez
  gz="$(awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k){print $7}' "$KANDIDATEN" | sort -u | wc -l | tr -d ' ')"
  ez="$(awk -F'\t' -v k="$kat" '$1=="neu" && (k=="" || $2==k)' "$KANDIDATEN" | wc -l | tr -d ' ')"
  info "\n  ${fett}$gz Gruppen${aus} aus $ez Einträgen"
}
