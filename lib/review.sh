# lib/review.sh -- review, mark, zeigen, gruppen: Kandidaten durchgehen und entscheiden.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- review ----------
# Eintraege desselben Programms liegen ueber viele Library-Ordner verstreut.
# Sie werden zu einer Gruppe zusammengefasst und gemeinsam entschieden.
R_PUFFER=()
R_AUSGABE=()
R_GO_PFADE=""
R_UEBERDECKT=0
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
    tasten "    " "j:weg" "n:behalten" "o:Finder" "s:später" "q:Ende"
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

  # Liegt alles davon in einem bereits freigegebenen Ordner? Dann eruebrigt
  # sich die Frage -- es wandert ohnehin mit.
  local alle_drin=1 pruef
  for zeile in "${offen[@]}"; do
    pruef="$(printf '%s' "$zeile" | cut -f5)"
    liegt_innerhalb "$pruef" "$R_GO_PFADE" || { alle_drin=0; break; }
  done
  if [ "$alle_drin" -eq 1 ]; then
    for zeile in "${offen[@]}"; do
      R_AUSGABE+=("$(status_setzen "$zeile" go)")
      R_UEBERDECKT=$((R_UEBERDECKT + 1))
    done
    return 0
  fi

  R_NR=$((R_NR + 1))
  local etikett grund1 pfad1 mt1
  etikett="$(printf '%s' "${offen[0]}" | cut -f8)"
  grund1="$(printf '%s' "${offen[0]}" | cut -f6)"
  pfad1="$(printf '%s' "${offen[0]}" | cut -f5)"
  mt1="$(printf '%s' "${offen[0]}" | cut -f4)"
  [ -n "$etikett" ] || etikett="$(basename "$pfad1")"

  # --- Dubletten: die Frage lautet nicht "weg oder nicht", sondern
  # "welche von diesen gleichen Dateien soll bleiben". Es muss immer eine
  # uebrig bleiben -- ein Griff, der alle loescht, gibt es hier nicht.
  local kategorie
  kategorie="$(printf '%s' "${offen[0]}" | cut -f2)"
  if [ "$kategorie" = "dublette" ] && [ "$n_offen" -ge 2 ]; then
    local -a nach_alter=()
    while IFS= read -r zeile; do nach_alter+=("$zeile"); done < <(printf '%s\n' "${offen[@]}" | sort -t$'\t' -k4,4)
    local erstes_kb
    erstes_kb="$(printf '%s' "${nach_alter[0]}" | cut -f3)"
    printf '\n%s[%d/%d]%s %s%d gleiche Dateien%s %s· je %s%s\n' \
      "$grau" "$R_NR" "$R_GESAMT" "$aus" "$fett" "$n_offen" "$aus" "$grau" "$(mb "$erstes_kb")" "$aus"
    local i=0 pfad mtime zusatz
    for zeile in "${nach_alter[@]}"; do
      i=$((i + 1))
      pfad="$(printf '%s' "$zeile" | cut -f5)"
      mtime="$(printf '%s' "$zeile" | cut -f4)"
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
        o|O) open -R "$(printf '%s' "${nach_alter[0]}" | cut -f5)" 2>/dev/null;;
        s|S|"") for zeile in "${nach_alter[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
        q|Q) R_ABBRUCH=1; for zeile in "${nach_alter[@]}"; do R_AUSGABE+=("$zeile"); done; return 0;;
        *[!0-9]*|'') printf '  %sBitte eine Zahl von 1 bis %d, oder n / o / s / q%s\n' "$gelb" "$n_offen" "$aus";;
        *)
          k="$antwort"
          if [ "$k" -ge 1 ] && [ "$k" -le "$n_offen" ]; then
            i=0
            for zeile in "${nach_alter[@]}"; do
              i=$((i + 1))
              if [ "$i" -eq "$k" ]; then
                R_AUSGABE+=("$(status_setzen "$zeile" keep)")
              else
                R_AUSGABE+=("$(status_setzen "$zeile" go)")
                R_GO_PFADE="$R_GO_PFADE
$(printf '%s' "$zeile" | cut -f5)"
              fi
            done
            return 0
          fi
          printf '  %sBitte eine Zahl von 1 bis %d, oder n / o / s / q%s\n' "$gelb" "$n_offen" "$aus";;
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
        j|J) R_AUSGABE+=("$(status_setzen "${offen[0]}" go)")
             R_GO_PFADE="$R_GO_PFADE
$pfad1"; return 0;;
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
    tasten "  " "j:alle weg" "n:alle behalten" "e:einzeln durchgehen" "o:Finder" "s:später" "q:Ende"
    printf '  → '
    read -r antwort || antwort=q
    case "$antwort" in
      j|J) for zeile in "${offen[@]}"; do
             R_AUSGABE+=("$(status_setzen "$zeile" go)")
             R_GO_PFADE="$R_GO_PFADE
$(printf '%s' "$zeile" | cut -f5)"
           done; return 0;;
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
  if [ "$kat_filter" = "dublette" ]; then
    info "${grau}Inhaltsgleiche Dateien stehen zusammen — du wählst, welche bleibt.${aus}"
  else
    info "${grau}Einträge desselben Programms sind zusammengefasst.${aus}"
  fi

  R_PUFFER=(); R_AUSGABE=(); R_ABBRUCH=0; R_NR=0; R_UEBERDECKT=0
  # Schon freigegebene Ordner merken: Was darin liegt, wird mitverschoben
  # und muss nicht noch einmal gefragt werden.
  R_GO_PFADE="$(awk -F'\t' '$1=="go"{print $5}' "$KANDIDATEN")"
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
befehl_mark() {
  local kat="${1:-}" status="${2:-}"
  case "$status" in go|keep|neu) ;; *) fehler "Status muss go, keep oder neu sein."; return 1;; esac
  [ -n "$kat" ] || { fehler "Welche Kategorie? (app-rest, cache, toolchain, gross, dublette)"; return 1; }
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  if [ "$kat" = "dublette" ] && [ "$status" = "go" ]; then
    fehler "Bei Dubletten würde das jede Kopie löschen, auch die letzte."
    info "${grau}Dort muss je Gruppe eine Datei bleiben — das entscheidest du im review:${aus}"
    info "  ${fett}$0 review dublette${aus}"
    return 1
  fi
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
