# lib/brew.sh -- brew: Homebrew durchleuchten und eine Vorschlagsliste schreiben.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- brew ----------
# Homebrew-Pakete lassen sich nicht sinnvoll in Quarantaene schieben.
# Stattdessen: Vorschlagsliste erzeugen, die du selbst durchgehst.
#
# Jede Zeile der Liste steht auskommentiert da: Entfernt wird nur, was du
# freischaltest. Wer die Datei unveraendert ausfuehrt, aendert nichts.

# Liest die JSON-Ausgabe von "brew info --cask --json=v2" und gibt je Cask
# "token<TAB>version<TAB>App1;App2" aus. JavaScript ueber osascript, weil es
# auf jedem Mac vorhanden ist -- jq oder Python sind es nicht.
# Fehlt die Version, steht "-" da: read mit IFS=Tab fasst aufeinanderfolgende
# Tabs zusammen, ein leeres Feld in der Mitte wuerde die Spalten dahinter
# verschieben.
brew_casks_lesen() {   # brew_casks_lesen <json-datei>
  osascript -l JavaScript - "$1" <<'JXA' 2>/dev/null
function run(argv) {
  var roh = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  var zeilen = [];
  JSON.parse(roh).casks.forEach(function (c) {
    var apps = [];
    (c.artifacts || []).forEach(function (a) {
      if (!a || !a.app) return;
      a.app.forEach(function (x) {
        // {"target": "..."} benennt die App davor beim Installieren um
        if (typeof x === "string") apps.push(x);
        else if (x && x.target && apps.length) apps[apps.length - 1] = x.target;
      });
    });
    zeilen.push([c.token, c.installed || "-", apps.join(";")].join("\t"));
  });
  return zeilen.join("\n");
}
JXA
}

befehl_brew() {
  command -v brew >/dev/null 2>&1 || { fehler "Homebrew nicht gefunden."; return 1; }
  local cellar; cellar="$(brew --cellar 2>/dev/null)"
  titel "Veraltete Versionen (brew cleanup)"
  brew cleanup --dry-run 2>/dev/null | tail -12
  # Abhaengigkeiten, die schon jetzt niemand mehr braucht
  brew autoremove --dry-run 2>/dev/null | tail -12

  local liste="$DATEN/brew-vorschlag.sh"
  {
    echo "#!/usr/bin/env bash"
    echo "# Von fegefeuer.sh erzeugt am $(date '+%d.%m.%Y %H:%M')"
    echo "#"
    echo "# Alle Zeilen stehen auskommentiert. Was weg soll, schaltest du frei,"
    echo "# indem du das # am Zeilenanfang loeschst. Unveraendert ausgefuehrt"
    echo "# aendert die Datei nichts."
    echo "#"
    echo "# Rueckgaengig jederzeit mit: brew install <name>"
    echo "#                        bzw. brew install --cask <name>"
  } > "$liste"

  # --- Formulas ---------------------------------------------------------
  # Gezaehlt wird, was beim Entfernen tatsaechlich frei wird: das Paket selbst
  # und die Abhaengigkeiten, die kein anderes installiertes Paket braucht.
  # Die eigene Groesse allein taeuscht: powershell belegt 74 MB, haelt aber
  # 669 MB dotnet fest.
  # Abhaengigkeiten, die sich zwei Pakete teilen, zaehlen bei keinem von
  # beiden -- sie werden erst frei, wenn beide gehen.
  titel "Direkt installierte Pakete, nach Platzgewinn"
  info "${grau}Nur diese hast du selbst gewollt — alles andere sind Abhängigkeiten.${aus}"
  info "${grau}Größe = was beim Entfernen frei wird, samt Abhängigkeiten, die sonst niemand braucht.${aus}"
  info "${grau}Datum = wann zuletzt installiert oder aktualisiert, nicht wann zuletzt benutzt.${aus}\n"

  local groessen="$ARBEIT/brew_groessen.tsv" abh="$ARBEIT/brew_abh.txt"
  local -a leaves=()
  local f
  while IFS= read -r f; do [ -n "$f" ] && leaves+=("$f"); done < <(brew leaves 2>/dev/null)
  # Ein einziges du ueber den Cellar statt eines Aufrufs je Paket
  du -sk "$cellar"/* 2>/dev/null | awk -F'\t' '{ n=$2; sub(/.*\//, "", n); print n "\t" $1 }' > "$groessen"
  : > "$abh"
  [ ${#leaves[@]} -gt 0 ] && brew deps --installed --for-each "${leaves[@]}" > "$abh" 2>/dev/null

  local n_formula=0
  if [ ${#leaves[@]} -gt 0 ]; then
    echo >> "$liste"
    echo "# --- Formulas ---" >> "$liste"
    local gesamt eigen mit name seit zusatz
    while IFS=$'\t' read -r gesamt eigen mit name; do
      [ -d "$cellar/$name" ] || continue
      seit="$(stat -f '%Sm' -t '%Y-%m-%d' "$cellar/$name" 2>/dev/null)"
      zusatz=""
      [ "$mit" -gt 0 ] && zusatz="  ${grau}davon $(mb "$mit") Abhängigkeiten${aus}"
      printf '  %9s  %s  %s%s\n' "$(mb "$gesamt")" "$seit" "$name" "$zusatz"
      if [ "$mit" -gt 0 ]; then
        printf '# brew uninstall %s   # %s (%s + %s Abhaengigkeiten), installiert %s\n' \
          "$name" "$(mb "$gesamt")" "$(mb "$eigen")" "$(mb "$mit")" "$seit" >> "$liste"
      else
        printf '# brew uninstall %s   # %s, installiert %s\n' "$name" "$(mb "$gesamt")" "$seit" >> "$liste"
      fi
      n_formula=$((n_formula + 1))
    done < <(LC_ALL=C awk -F'\t' '
        NR==FNR { kb[$1]=$2; next }
        {
          # Zeile: "leaf: abh1 abh2 ..." (Tap-Formulas mit vollem Namen)
          i = index($0, ":"); leaf = substr($0, 1, i-1); rest = substr($0, i+1)
          sub(/.*\//, "", leaf)
          leaves[leaf] = 1
          n = split(rest, d, " ")
          for (j=1; j<=n; j++) { a = d[j]; sub(/.*\//, "", a); nutzer[a]++; von[leaf] = von[leaf] " " a }
        }
        END {
          for (l in leaves) {
            mit = 0
            n = split(von[l], d, " ")
            for (j=1; j<=n; j++) if (nutzer[d[j]] == 1) mit += kb[d[j]]
            printf "%d\t%d\t%d\t%s\n", kb[l] + mit, kb[l], mit, l
          }
        }' FS='\t' "$groessen" FS=' ' "$abh" | sort -t$'\t' -k1,1nr)
  fi

  # --- Casks ------------------------------------------------------------
  titel "Programme (Casks), nach Größe"
  info "${grau}Zuletzt geöffnet = laut Spotlight. \"unbekannt\" heißt nicht unbenutzt — Apps,"
  info "die sich selbst aktualisieren, verlieren den Eintrag oft.${aus}\n"

  # Was installiert ist, sagt "brew list". "brew info --installed" taugt dafuer
  # nicht: Es laesst Casks weg, deren Eintrag im Caskroom unvollstaendig ist,
  # obwohl die App laeuft (gesehen bei AlDente, das sich selbst aktualisiert).
  local json="$ARBEIT/brew_casks.json" casks="$ARBEIT/brew_casks.tsv"
  local -a tokens=()
  local t
  while IFS= read -r t; do [ -n "$t" ] && tokens+=("$t"); done < <(brew list --cask -1 2>/dev/null)
  : > "$casks"
  if [ ${#tokens[@]} -gt 0 ]; then
    if brew info --cask --json=v2 "${tokens[@]}" > "$json" 2>/dev/null; then
      brew_casks_lesen "$json" > "$casks"
    else
      # Ein Cask, den Homebrew nicht mehr kennt, laesst die ganze Abfrage
      # scheitern. Dann einzeln fragen; wer keine Antwort bekommt, steht
      # trotzdem in der Liste.
      for t in "${tokens[@]}"; do
        if brew info --cask --json=v2 "$t" > "$json" 2>/dev/null; then
          brew_casks_lesen "$json" >> "$casks"
        else
          printf '%s\t-\t?\n' "$t" >> "$casks"
        fi
      done
    fi
  fi

  local n_cask=0
  if [ -s "$casks" ]; then
    echo >> "$liste"
    echo "# --- Programme (Casks) ---" >> "$liste"
    echo "# Die Daten der App in ~/Library bleiben liegen. Der naechste" >> "$liste"
    echo "# 'fegefeuer.sh scan' findet sie als App-Rest." >> "$liste"
    local heute; heute="$(date +%s)"
    local token version apps kb app pfad lu lu_app sek tage
    local hinweis
    while IFS=$'\t' read -r kb lu token hinweis; do
      [ "$lu" = "-" ] && lu=""
      if [ "$kb" = "-" ] || [ "$kb" = "?" ]; then
        if [ "$kb" = "?" ]; then hinweis="Homebrew kennt diesen Cask nicht mehr"
        else hinweis="ohne App"; fi
        printf '  %9s  %-10s  %s %s(%s — Größe unbekannt)%s\n' "?" "" "$token" "$grau" "$hinweis" "$aus"
        printf '# brew uninstall --cask %s   # Groesse unbekannt (%s)\n' "$token" "$hinweis" >> "$liste"
      else
        zusatz=""
        if [ -n "$lu" ]; then
          sek="$(date -j -f '%Y-%m-%d' "$lu" +%s 2>/dev/null)"
          if [ -n "$sek" ]; then
            tage=$(( (heute - sek) / 86400 ))
            [ "$tage" -ge 90 ] && zusatz="  ${gelb}seit $tage Tagen nicht geöffnet${aus}"
          fi
        fi
        [ -n "$hinweis" ] && zusatz="$zusatz  ${grau}($hinweis)${aus}"
        printf '  %9s  %-10s  %s%s\n' "$(mb "$kb")" "${lu:-unbekannt}" "$token" "$zusatz"
        printf '# brew uninstall --cask %s   # %s, zuletzt geoeffnet: %s%s\n' \
          "$token" "$(mb "$kb")" "${lu:-unbekannt}" "${hinweis:+ -- $hinweis}" >> "$liste"
      fi
      n_cask=$((n_cask + 1))
    done < <(
      while IFS=$'\t' read -r token version apps; do
        [ -n "$token" ] || continue
        [ "$apps" = "?" ] && { printf '%s\t-\t%s\t\n' "?" "$token"; continue; }
        [ -z "$apps" ] && { printf '%s\t-\t%s\t\n' "-" "$token"; continue; }
        # Ohne Versionsangabe ist der Eintrag im Caskroom unvollstaendig; die
        # App kann trotzdem da sein, brew uninstall scheitert dann aber.
        hinweis=""
        [ "$version" != "-" ] || hinweis="Homebrew-Eintrag unvollständig, brew uninstall scheitert womöglich"
        kb=0; lu=""
        while IFS= read -r app; do
          [ -n "$app" ] || continue
          pfad="/Applications/$app"
          [ -e "$pfad" ] || pfad="$HOME/Applications/$app"
          [ -e "$pfad" ] || continue
          kb=$(( kb + $(du -sk "$pfad" 2>/dev/null | cut -f1) ))
          # Bei mehreren Apps zaehlt die zuletzt geoeffnete
          lu_app="$(mdls -raw -name kMDItemLastUsedDate "$pfad" 2>/dev/null | cut -c1-10)"
          case "$lu_app" in ([0-9][0-9][0-9][0-9]-*) [ "$lu_app" \> "$lu" ] && lu="$lu_app";; esac
        done <<< "$(printf '%s' "$apps" | tr ';' '\n')"
        [ "$kb" -gt 0 ] || hinweis="App nicht gefunden"
        printf '%s\t%s\t%s\t%s\n' "$kb" "${lu:--}" "$token" "$hinweis"
      done < "$casks" | sort -t$'\t' -k1,1nr)
  else
    info "  ${grau}keine${aus}"
  fi

  # Erst brew autoremove macht die Abhaengigkeiten frei, die oben mitgezaehlt
  # sind. Es raeumt aber auch auf, was schon vorher verwaist war -- und soll
  # deshalb nur laufen, wenn ueberhaupt etwas freigeschaltet ist. Sonst
  # aenderte die unveraenderte Datei doch etwas.
  {
    echo
    echo "# Zum Schluss Abhaengigkeiten entfernen, die niemand mehr braucht -- erst"
    echo "# damit werden die oben genannten Abhaengigkeiten frei. Laeuft nur, wenn"
    echo "# oben mindestens eine Zeile freigeschaltet ist."
    echo "if grep -q '^brew uninstall' \"\$0\"; then brew autoremove; fi"
  } >> "$liste"
  chmod +x "$liste"
  rm -f "$groessen" "$abh" "$json" "$casks"
  info "\nVorschlagsliste: ${fett}$liste${aus}  ${grau}($n_formula Formulas, $n_cask Programme)${aus}"
  info "${grau}Alles steht auskommentiert. Was weg soll, freischalten (# entfernen), dann ausführen.${aus}"
  info "Platzsparen ohne Risiko: ${fett}brew cleanup${aus}"
}
