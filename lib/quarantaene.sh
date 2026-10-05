# lib/quarantaene.sh -- Alles, was das Fegefeuer selbst betrifft: Manifest, apply, list,
# restore, pruefen, purge.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- apply ----------
befehl_apply() {
  [ -f "$KANDIDATEN" ] || { fehler "Keine Kandidaten."; return 1; }
  local anzahl; anzahl="$(awk -F'\t' '$1=="go"' "$KANDIDATEN" | wc -l | tr -d ' ')"
  [ "$anzahl" -eq 0 ] && { warn "Nichts markiert. Erst '$0 review'."; return 0; }

  local stapel; stapel="$(date '+%Y-%m-%d_%H%M%S')"
  local ziel="$QUARANTAENE/$stapel"
  local manifest="$ziel/_manifest.tsv"

  local platz; platz="$(summe_echt go)"
  info "\n${fett}$anzahl Einträge${aus} ($(mb "$platz")) → Quarantäne"
  info "${grau}$ziel${aus}\n"
  printf 'Fortfahren? [j/N] '
  local ok; read -r ok || ok=n
  case "$ok" in j|J) ;; *) info "Abgebrochen."; return 0;; esac
  # Erst nach dem Ja anlegen -- sonst bliebe nach einem Nein ein leerer
  # Stapel liegen.
  mkdir -p "$ziel"
  : > "$manifest"

  # Ein 'go'-Ordner darf nichts mitnehmen, was ausdruecklich behalten werden
  # soll -- mv wuerde den Unterordner sonst kommentarlos mitverschieben.
  local keepliste="$ARBEIT/apply_keep.txt"
  awk -F'\t' '$1=="keep"{print $5}' "$KANDIDATEN" > "$keepliste"

  # Von jeder Dubletten-Gruppe muss eine Kopie bleiben. Das review stellt das
  # sicher, aber nicht allein: Eine grosse Datei steht zugleich als "gross" in
  # der Liste, und "mark gross go" schickt dann auch die behaltene Kopie los.
  # Darum hier noch einmal fuer alle Zeilen zusammen. Eine Kopie bleibt, wenn
  # sie existiert und behalten wird -- oder weder selbst freigegeben ist noch
  # in einem freigegebenen Ordner liegt. Bleibt keine, wird die ganze Gruppe
  # nicht angefasst: Ihre Pfade landen in dub_schutz.
  local dub_schutz="$ARBEIT/apply_dub_schutz.tsv"
  local vorhanden="$ARBEIT/apply_dub_vorhanden.txt"
  local p
  awk -F'\t' '$2=="dublette"{print $5}' "$KANDIDATEN" | while IFS= read -r p; do
    [ -e "$p" ] && printf '%s\n' "$p"
  done > "$vorhanden"
  LC_ALL=C awk -F'\t' '
    NR==FNR {
      if ($1=="go")   { gehen[$5]=1; go[++n]=$5 }
      if ($1=="keep") bleib[$5]=1
      if ($2=="dublette" && $7!="") { pfad[++m]=$5; gruppe[m]=$7 }
      next
    }
    { da[$0]=1 }
    END {
      for (j=1; j<=m; j++) {
        g=gruppe[j]; q=pfad[j]
        mitglieder[g] = mitglieder[g] "\n" q
        if (!(q in da)) continue
        vorh[g]++
        if (q in bleib) { rest[g]++; continue }
        if (q in gehen) continue
        drin=0
        for (i=1; i<=n; i++) if (index(q, go[i] "/")==1) { drin=1; break }
        if (!drin) rest[g]++
      }
      for (g in mitglieder) if (vorh[g]>0 && rest[g]+0==0) {
        k=split(mitglieder[g], t, "\n")
        for (i=2; i<=k; i++) print g "\t" t[i]
      }
    }' "$KANDIDATEN" "$vorhanden" > "$dub_schutz"
  # Was nicht mitwandern darf: Behaltenes und die Kopien geschuetzter Gruppen
  local bleibliste="$ARBEIT/apply_bleibt.txt"
  { cat "$keepliste"; cut -f2 "$dub_schutz"; } > "$bleibliste"

  # Nach Pfad sortiert abarbeiten: Ein Ordner kommt so vor allem, was in ihm
  # liegt, und nimmt es mit. In der Reihenfolge der Liste (nach Kategorie)
  # wanderte eine "gross"-Datei vor ihrem "toolchain"-Ordner, und der Ordner
  # landete danach in der Huelle, die sie angelegt hatte.
  local reihenfolge="$ARBEIT/apply_reihenfolge.tsv"
  LC_ALL=C sort -t$'\t' -k5,5 "$KANDIDATEN" > "$reihenfolge"

  local verschoben=0 fehlgeschlagen=0 blockiert=0 mitgewandert=0 widerspruch=0 dub_gehalten=0
  local dub_gemeldet=""
  local -a neu=()
  while IFS= read -r zeile <&3; do
    local st kt kb mt pfad grund grp etikett
    felder_lesen "$zeile" st kt kb mt pfad grund grp etikett
    if [ "$st" != "go" ]; then neu+=("$zeile"); continue; fi
    if ist_geschuetzt "$pfad"; then
      warn "geschützt, übersprungen: $pfad"; neu+=("$(status_setzen "$zeile" keep)"); continue
    fi
    # Derselbe Pfad steht anderswo auf keep: behalten gewinnt
    if grep -Fxq -- "$pfad" "$keepliste"; then
      warn "bleibt: ${pfad/#$HOME/$TILDE}"
      info "  ${grau}hier als $kt freigegeben, an anderer Stelle der Liste aber behalten.${aus}"
      widerspruch=$((widerspruch + 1))
      neu+=("$(status_setzen "$zeile" keep)")
      continue
    fi
    local schutzgruppe
    schutzgruppe="$(awk -F'\t' -v p="$pfad" '$2==p { print $1; exit }' "$dub_schutz")"
    if [ -n "$schutzgruppe" ]; then
      case "$dub_gemeldet" in
        *"|$schutzgruppe|"*) ;;
        *)
          dub_gemeldet="$dub_gemeldet|$schutzgruppe|"
          warn "Dubletten-Gruppe nicht angefasst — sonst bliebe keine Kopie übrig:"
          awk -F'\t' -v g="$schutzgruppe" '$1==g { print $2 }' "$dub_schutz" \
            | while IFS= read -r p; do info "  ${grau}${p/#$HOME/$TILDE}${aus}"; done
          info "  ${grau}Neu entscheiden mit:${aus} ${fett}$0 review dublette${aus}";;
      esac
      dub_gehalten=$((dub_gehalten + 1))
      # Die Dubletten-Zeile wird wieder offen, damit das review neu fragt
      if [ "$kt" = "dublette" ]; then neu+=("$(status_setzen "$zeile" neu)"); else neu+=("$zeile"); fi
      continue
    fi
    if [ ! -e "$pfad" ]; then
      # Meist schon mit einem uebergeordneten Ordner mitgewandert
      mitgewandert=$((mitgewandert + 1))
      continue
    fi
    local drin=""
    [ -d "$pfad" ] && drin="$(awk -v praefix="$pfad/" 'index($0, praefix)==1 { print; exit }' "$bleibliste")"
    if [ -n "$drin" ]; then
      warn "übersprungen: ${pfad/#$HOME/$TILDE}"
      if grep -Fxq -- "$drin" "$keepliste"; then
        info "  ${grau}enthält ${drin/#$HOME/$TILDE}, das du behalten wolltest.${aus}"
        info "  ${grau}Entweder den Unterordner auch freigeben oder den Elternordner behalten.${aus}"
      else
        info "  ${grau}enthält ${drin/#$HOME/$TILDE}, die letzte verbliebene Kopie einer Dublette.${aus}"
      fi
      blockiert=$((blockiert + 1))
      neu+=("$zeile")
      continue
    fi
    local rel="${pfad#$HOME/}"
    local zielpfad="$ziel/$rel"
    # Nie auf einen belegten Pfad verschieben: mv legte einen Ordner sonst
    # in den vorhandenen hinein, und restore holte ihn nur halb zurueck.
    if [ -e "$zielpfad" ] || [ -L "$zielpfad" ]; then
      fehlgeschlagen=$((fehlgeschlagen+1))
      printf '  %s✗%s %s %s(in der Quarantäne schon belegt)%s\n' "$rot" "$aus" "${pfad/#$HOME/$TILDE}" "$grau" "$aus"
      neu+=("$zeile")
      continue
    fi
    mkdir -p "$(dirname "$zielpfad")"
    if mv "$pfad" "$zielpfad" 2>/dev/null; then
      manifest_zeile "$rel" "$pfad" "$kb" "verschoben" "$kt" >> "$manifest"
      verschoben=$((verschoben+1))
      printf '  %s✓%s %s\n' "$gruen" "$aus" "${pfad/#$HOME/$TILDE}"
    else
      fehlgeschlagen=$((fehlgeschlagen+1))
      printf '  %s✗%s %s %s(keine Berechtigung?)%s\n' "$rot" "$aus" "${pfad/#$HOME/$TILDE}" "$grau" "$aus"
      neu+=("$zeile")
    fi
  done 3< "$reihenfolge"
  rm -f "$reihenfolge"

  # Zurueck in die gewohnte Ordnung: Kategorie, dann Groesse
  schreibe_kandidaten "${neu[@]+"${neu[@]}"}"
  sort -t$'\t' -k2,2 -k3,3nr "$KANDIDATEN" -o "$KANDIDATEN"
  [ "$blockiert" -gt 0 ] && warn "$blockiert übersprungen, weil sie Behaltenes enthalten"
  [ "$widerspruch" -gt 0 ] && warn "$widerspruch Einträge waren zugleich freigegeben und behalten — sie bleiben"
  [ "$dub_gehalten" -gt 0 ] && warn "$dub_gehalten Dubletten-Einträge nicht angefasst, damit von jeder Gruppe eine Kopie bleibt"
  [ "$mitgewandert" -gt 0 ] && info "${grau}$mitgewandert Einträge lagen in einem anderen und sind mitgewandert.${aus}"
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
# Eine Zeile im Manifest eines Stapels:
#   rel  original  kb  art  kategorie
# art haelt fest, wie der Eintrag hierher kam: "verschoben" heisst
# beiseitegelegt, der Originalort ist frei; "ersetzt" heisst, am Originalort
# liegt jetzt eine neu kodierte Fassung.
# kategorie ist die aus kandidaten.tsv (cache, app-rest, ...) oder "video".
# Aeltere Stapel haben die Spalte nicht; dort ist sie leer und gilt als
# unbekannt.
# kb nie leer schreiben: Die Leser zerlegen mit IFS=Tab, und ein leeres Feld
# in der Mitte schoebe art und kategorie um eine Spalte nach vorn.
manifest_zeile() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-0}" "$4" "${5:-}"; }

# Bei welchen Kategorien macht ein Nachwachsen am Originalort die alte Fassung
# entbehrlich? Nur bei Caches und Toolchains -- die baut das System selbst
# neu auf. Legt dagegen eine App ihren Ordner neu an, wird sie offenbar doch
# benutzt, und die alten Daten sind genau das, was ihr jetzt fehlt.
nachwachsend() { case "${1:-}" in cache|toolchain) return 0;; esac; return 1; }

# Alle Stapel der Quarantaene, einer je Zeile, mit Schraegstrich am Ende.
# "ohne-verdraengt" laesst die _verdraengt-Ordner aus, die restore --ersetzen
# anlegt: Sie haben kein Manifest und gehoeren nicht zu pruefen und
# purge --wieder-da. list und purge zeigen bzw. loeschen sie mit.
stapel_auflisten() {   # stapel_auflisten [ohne-verdraengt]
  local s
  for s in "$QUARANTAENE"/*/; do
    [ -d "$s" ] || continue
    if [ "${1:-}" = "ohne-verdraengt" ]; then
      case "$(basename "$s")" in _verdraengt-*) continue;; esac
    fi
    printf '%s\n' "$s"
  done
}

# Alter eines Stapels in Tagen, gemessen an der Aenderungszeit des Ordners
stapel_alter_tage() { echo $(( ( $(date +%s) - $(stat -f %m "$1") ) / 86400 )); }

# Statt "vor 0 Tagen" und "vor 1 Tagen". Gezaehlt wird in vollen 24 Stunden,
# nicht nach Kalendertagen -- "heute" oder "gestern" waeren deshalb falsch.
vor_tagen() {   # vor_tagen <tage>
  case "$1" in
    0) echo "vor weniger als einem Tag";;
    1) echo "vor 1 Tag";;
    *) echo "vor $1 Tagen";;
  esac
}

# Leere Unterordner entfernen. Ein Durchgang genuegt: -delete arbeitet von
# innen nach aussen, ein Ordner, der dabei leer wird, faellt gleich mit.
leere_ordner_entfernen() { find "$1" -mindepth 1 -type d -empty -delete 2>/dev/null; }

# Fragt nach, bevor endgueltig geloescht wird. 0 nur bei getipptem LOESCHEN.
loeschen_bestaetigen() {
  printf 'Wirklich löschen? Tippe %sLOESCHEN%s: ' "$fett" "$aus"
  local ok; read -r ok || ok=n
  [ "$ok" = "LOESCHEN" ] && return 0
  info "Abgebrochen."
  return 1
}

befehl_list() {
  [ -d "$QUARANTAENE" ] || { info "Quarantäne ist leer."; return 0; }
  titel "Quarantäne"
  local gesamt=0
  while IFS= read -r s; do
    local name; name="$(basename "$s")"
    local kb; kb="$(du -sk "$s" 2>/dev/null | cut -f1)"
    local n=0
    [ -f "$s/_manifest.tsv" ] && n="$(wc -l < "$s/_manifest.tsv" 2>/dev/null | tr -d ' ')"
    local tage; tage="$(stapel_alter_tage "$s")"
    printf '  %-22s %8s  %3s Einträge  %s(%s)%s\n' "$name" "$(mb "$kb")" "${n:-0}" "$grau" "$(vor_tagen "$tage")" "$aus"
    gesamt=$((gesamt+kb))
  done < <(stapel_auflisten)
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

  local n=0 uebersprungen=0 uebersprungen_ersetzt=0 ersetzt=0 vereint=0 teils_vereint=0 misslungen=0
  local -a bleibt=()
  local rel original kb art kat quelle

  while IFS=$'\t' read -r rel original kb art kat <&3; do
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
          bleibt+=("$(manifest_zeile "$rel" "$original" "$kb" "$art" "$kat")")
          continue;;
        zusammenfuehren)
          if [ -d "$original" ] && [ -d "$quelle" ]; then
            if ! command -v rsync >/dev/null 2>&1; then
              fehler "--zusammenfuehren braucht rsync, das hier nicht vorhanden ist."
              return 1
            fi
            # Nur ergaenzen: was inzwischen neu entstanden ist, bleibt unberuehrt.
            # --remove-source-files nimmt nur, was tatsaechlich hinueberging.
            # Wo am Ziel schon eine Fassung liegt, bleibt die alte im Fegefeuer --
            # ein rm -rf hinterher haette genau diese stillschweigend geloescht.
            if rsync -a --ignore-existing --remove-source-files "$quelle"/ "$original"/ 2>/dev/null; then
              find "$quelle" -type d -empty -delete 2>/dev/null
              vereint=$((vereint + 1))
              if [ -e "$quelle" ]; then
                local nicht_ergaenzt
                nicht_ergaenzt="$(find "$quelle" ! -type d 2>/dev/null | wc -l | tr -d ' ')"
                teils_vereint=$((teils_vereint + 1))
                printf '  %s⊕%s %s %s(ergänzt · %s schon vorhanden, deren alte Fassung bleibt im Fegefeuer)%s\n' \
                  "$gruen" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$nicht_ergaenzt" "$aus"
                bleibt+=("$(manifest_zeile "$rel" "$original" "$kb" "$art" "$kat")")
              else
                printf '  %s⊕%s %s %s(ergänzt)%s\n' "$gruen" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
              fi
              continue
            fi
          fi
          printf '  %s•%s %s %s(keine zwei Ordner — übersprungen)%s\n' \
            "$gelb" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
          uebersprungen=$((uebersprungen + 1))
          bleibt+=("$(manifest_zeile "$rel" "$original" "$kb" "$art" "$kat")")
          continue;;
        ersetzen)
          mkdir -p "$beiseite/$(dirname "$rel")"
          if mv "$original" "$beiseite/$rel" 2>/dev/null; then
            ersetzt=$((ersetzt + 1))
          else
            printf '  %s✗%s %s %s(aktuelle Fassung ließ sich nicht sichern)%s\n' \
              "$rot" "$aus" "${original/#$HOME/$TILDE}" "$grau" "$aus"
            misslungen=$((misslungen + 1))
            bleibt+=("$(manifest_zeile "$rel" "$original" "$kb" "$art" "$kat")")
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
      bleibt+=("$(manifest_zeile "$rel" "$original" "$kb" "$art" "$kat")")
    fi
  done 3< "$manifest"

  # Manifest auf das reduzieren, was noch in Quarantäne liegt
  zeilen_schreiben "$manifest" "${bleibt[@]+"${bleibt[@]}"}"

  leere_ordner_entfernen "$ziel"

  info ""
  [ "$n" -gt 0 ]            && info "${gruen}$n zurückgeholt${aus}"
  [ "$vereint" -gt 0 ]      && info "${gruen}$vereint Ordner ergänzt${aus}"
  if [ "$teils_vereint" -gt 0 ]; then
    info "${grau}Bei $teils_vereint davon lag am Ziel schon eine eigene Fassung einzelner Dateien."
    info "Die alten Fassungen bleiben im Stapel — ansehen mit: ${aus}${fett}open \"$ziel\"${aus}"
  fi
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
      info "${grau}Bei Caches, die sich selbst neu aufgebaut haben, brauchst du die alte Fassung"
      info "nicht mehr: ${aus}${fett}$0 purge --wieder-da $stapel${aus}"
      info "${grau}Bei App-Resten heisst es eher: die App wird benutzt. Alte Daten zurück,"
      info "die neue Fassung wird beiseitegelegt: ${aus}${fett}$0 restore $stapel --ersetzen${aus}"
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
  local gesamt_angelegt=0 kb_angelegt=0
  local stapelordner rel original kb kat name tage

  while IFS= read -r stapelordner; do
    name="$(basename "$stapelordner")"
    [ -f "$stapelordner/_manifest.tsv" ] || continue
    tage="$(stapel_alter_tage "$stapelordner")"

    titel "$name  ($(vor_tagen "$tage"))"
    local w=0 f=0 e=0 a=0 wkb=0 fkb=0 ekb=0 akb=0 unbekannt=0 art
    local -a wieder=() angelegt=()
    while IFS=$'\t' read -r rel original kb art kat; do
      [ -n "$rel" ] || continue
      if [ "$art" = "ersetzt" ]; then
        e=$((e + 1)); ekb=$((ekb + kb))
      elif [ -e "$original" ] && nachwachsend "$kat"; then
        w=$((w + 1)); wkb=$((wkb + kb))
        wieder+=("$(printf '%s\t%s' "$kb" "$original")")
      elif [ -e "$original" ]; then
        # Wieder da, aber kein Cache: eher ein Warnsignal als eine Entwarnung
        a=$((a + 1)); akb=$((akb + kb))
        [ -n "$kat" ] || unbekannt=$((unbekannt + 1))
        angelegt+=("$(printf '%s\t%s\t%s' "$kb" "$original" "${kat:-?}")")
      else
        f=$((f + 1)); fkb=$((fkb + kb))
      fi
    done < "$stapelordner/_manifest.tsv"

    [ "$w" -gt 0 ] && info "  ${gruen}$w wieder aufgebaut${aus} ($(mb "$wkb"))   ${grau}—  von selbst zurückgekehrt, die Quarantänekopie ist überflüssig${aus}"
    [ "$f" -gt 0 ] && info "  $f noch verschwunden ($(mb "$fkb"))   ${grau}—  hat dir bisher nichts gefehlt${aus}"
    [ "$a" -gt 0 ] && info "  ${gelb}$a wieder angelegt${aus} ($(mb "$akb"))   ${grau}—  keine Caches: wird das doch benutzt?${aus}"
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
    if [ "$a" -gt 0 ]; then
      info "\n  ${grau}Wieder angelegt, aber kein Cache:${aus}"
      printf '%s\n' "${angelegt[@]}" | sort -t$'\t' -k1,1nr | head -8 \
        | while IFS=$'\t' read -r kb original kat; do
            printf '    %8s  %-9s %s\n' "$(mb "$kb")" "$kat" "${original/#$HOME/$TILDE}"
          done
      info "  ${grau}Legt eine App ihren Ordner neu an, wird sie offenbar benutzt — und ihr"
      info "  fehlen die alten Daten, die hier liegen. Zurückholen, die neue Fassung"
      info "  wird dabei nur beiseitegelegt (gilt für den ganzen Stapel):${aus}"
      info "    ${fett}$0 restore $name --ersetzen${aus}"
      [ "$unbekannt" -gt 0 ] && info "  ${grau}$unbekannt davon stammen aus einem Stapel ohne Kategorie (älter als diese Version)"
      [ "$unbekannt" -gt 0 ] && info "  und werden deshalb vorsichtshalber genauso behandelt.${aus}"
      info "  ${grau}purge --wieder-da lässt diese Einträge aus.${aus}"
    fi
    gesamt_wieder=$((gesamt_wieder + w)); gesamt_fehlt=$((gesamt_fehlt + f))
    kb_wieder=$((kb_wieder + wkb)); kb_fehlt=$((kb_fehlt + fkb))
    gesamt_ersetzt=$((gesamt_ersetzt + e)); kb_ersetzt=$((kb_ersetzt + ekb))
    gesamt_angelegt=$((gesamt_angelegt + a)); kb_angelegt=$((kb_angelegt + akb))
  done < <(stapel_auflisten ohne-verdraengt)

  local zusatz=""
  [ "$gesamt_angelegt" -gt 0 ] && zusatz=", $gesamt_angelegt wieder angelegt ($(mb "$kb_angelegt"))"
  [ "$gesamt_ersetzt" -gt 0 ] && zusatz="$zusatz, $gesamt_ersetzt ersetzt ($(mb "$kb_ersetzt"))"
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
  local s
  while IFS= read -r s; do
    [ "$(stapel_alter_tage "$s")" -ge "$tage" ] && faellig+=("$s")
  done < <(stapel_auflisten)
  [ ${#faellig[@]} -eq 0 ] && { info "Nichts älter als $tage Tage."; return 0; }

  local kb=0
  for s in "${faellig[@]}"; do kb=$(( kb + $(du -sk "$s" 2>/dev/null | cut -f1) )); done
  warn "Endgültiges Löschen von ${#faellig[@]} Stapel(n), $(mb "$kb"). Das lässt sich NICHT rückgängig machen."
  # Originale neu kodierter Videos eigens nennen: An ihrem Platz liegt nur
  # noch die verlustbehaftete neue Fassung. pruefen und purge --wieder-da
  # halten sie auseinander, hier gingen sie sonst stillschweigend mit.
  local n_videos v_kb
  read -r n_videos v_kb <<< "$(for s in "${faellig[@]}"; do
      [ -f "$s/_manifest.tsv" ] && cat "$s/_manifest.tsv"; done \
    | awk -F'\t' '$4=="ersetzt" { n++; k+=$3 } END { printf "%d\t%d", n, k }')"
  if [ "$n_videos" -gt 0 ]; then
    if [ "$n_videos" -eq 1 ]; then info "  Darunter ${fett}das Original eines neu kodierten Videos${aus} ($(mb "$v_kb"))."
    else info "  Darunter ${fett}$n_videos Originale neu kodierter Videos${aus} ($(mb "$v_kb"))."; fi
    info "  ${grau}Danach gibt es von ihnen nur noch die neu kodierte Fassung. Sieh sie dir vorher an.${aus}"
  fi
  loeschen_bestaetigen || return 0
  local befreit=0 reste=0
  for s in "${faellig[@]}"; do
    local vorher; vorher="$(du -sk "$s" 2>/dev/null | cut -f1)"
    stapel_loeschen "$s"
    local uebrig=0
    [ -d "$s" ] && uebrig="$(du -sk "$s" 2>/dev/null | cut -f1)"
    befreit=$(( befreit + vorher - uebrig ))
    if [ ! -d "$s" ]; then
      info "  ${gruen}gelöscht:${aus} $(basename "$s")"
    else
      reste=$(( reste + 1 ))
      warn "unvollständig gelöscht: $(basename "$s") — $(mb "$uebrig") blieben liegen"
      stapel_reste_erklaeren "$s"
    fi
  done
  info "\n${gruen}$(mb "$befreit") freigegeben.${aus}"
  [ "$reste" -gt 0 ] && warn "Nicht alles liess sich entfernen — siehe oben."
  return 0
}

# Loescht einen Stapel und faengt dabei den haeufigsten Stolperstein ab:
# Ist der Ordner im Finder geoeffnet, legt dieser waehrend des Loeschens
# neue .DS_Store-Dateien an, und rmdir scheitert an "Directory not empty".
stapel_loeschen() {
  local ziel="$1"
  rm -rf "$ziel" 2>/dev/null
  [ -d "$ziel" ] || return 0
  find "$ziel" -name ".DS_Store" -delete 2>/dev/null
  rm -rf "$ziel" 2>/dev/null
  [ -d "$ziel" ] || return 0
  return 1
}

# Sagt, was uebrig blieb und warum -- statt den Benutzer mit rm-Meldungen
# allein zu lassen.
stapel_reste_erklaeren() {
  local ziel="$1" fremde
  fremde="$(find "$ziel" ! -user "$(id -un)" 2>/dev/null | head -1)"
  if [ -n "$fremde" ]; then
    local besitzer
    besitzer="$(ls -ld "$fremde" 2>/dev/null | awk '{print $3}')"
    info "  ${grau}Diese Dateien gehören ${besitzer:-einem anderen Benutzer}, nicht dir."
    info "  Ein Programm hat sie mit erhöhten Rechten angelegt. Zum Entfernen:${aus}"
    info "    ${fett}sudo rm -rf \"$ziel\"${aus}"
    info "  ${grau}Prüfe den Pfad, bevor du das ausführst.${aus}"
  else
    info "  ${grau}Grund unklar. Liegt der Ordner im Finder offen? Dann schliessen"
    info "  und erneut versuchen:${aus} ${fett}$0 purge 0${aus}"
  fi
}

# Eintraege loeschen, deren Originalpfad wieder existiert. Diese Kopien haben
# sich als entbehrlich erwiesen -- das System hat sie selbst ersetzt.
# Das gilt nur fuer Caches und Toolchains (siehe nachwachsend).
purge_wieder_da() {
  local stapel="${1:-}"
  local -a stapelliste=()
  if [ -n "$stapel" ]; then
    [ -d "$QUARANTAENE/$stapel" ] || { fehler "Stapel '$stapel' nicht gefunden."; return 1; }
    stapelliste=("$QUARANTAENE/$stapel/")
  else
    local s
    while IFS= read -r s; do stapelliste+=("$s"); done < <(stapel_auflisten ohne-verdraengt)
  fi
  [ ${#stapelliste[@]} -eq 0 ] && { info "Quarantäne ist leer."; return 0; }

  # Erst zaehlen, dann fragen
  local gesamt=0 kb=0 uebergangen=0 kein_cache=0 sordner rel original ekb art kat
  for sordner in "${stapelliste[@]}"; do
    [ -f "$sordner/_manifest.tsv" ] || continue
    while IFS=$'\t' read -r rel original ekb art kat; do
      [ -n "$rel" ] || continue
      # Ersetzte Videooriginale sind nicht "nachgewachsen" -- am Originalort
      # liegt die neu kodierte Fassung. Die gehoeren nicht in diesen Rundumschlag.
      [ "$art" = "ersetzt" ] && { uebergangen=$((uebergangen+1)); continue; }
      [ -e "$original" ] && [ -e "$sordner/$rel" ] || continue
      # Wieder angelegt, aber kein Cache: das ist kein Beleg fuer Entbehrlichkeit
      nachwachsend "$kat" || { kein_cache=$((kein_cache+1)); continue; }
      gesamt=$((gesamt+1)); kb=$((kb+ekb))
    done < "$sordner/_manifest.tsv"
  done
  if [ "$uebergangen" -gt 0 ]; then
    info "${grau}$uebergangen Originale neu kodierter Videos bleiben aussen vor —"
    info "dort liegt die neue Fassung, nicht etwas Nachgewachsenes.${aus}"
  fi
  if [ "$kein_cache" -gt 0 ]; then
    info "${grau}$kein_cache wieder angelegte Einträge sind keine Caches und bleiben aussen vor —"
    info "was das bedeutet, zeigt ${aus}${fett}$0 pruefen${aus}"
  fi
  [ "$gesamt" -eq 0 ] && { info "Kein Cache ist bisher zurückgekehrt."; return 0; }

  info "${fett}$gesamt Einträge${aus} ($(mb "$kb")) sind am Originalort wieder vorhanden."
  info "${grau}Das System hat sie neu angelegt — die Quarantänekopien werden nicht mehr gebraucht.${aus}"
  warn "Endgültiges Löschen. Das lässt sich NICHT rückgängig machen."
  loeschen_bestaetigen || return 0

  local geloescht=0 wirklich_frei=0
  for sordner in "${stapelliste[@]}"; do
    [ -f "$sordner/_manifest.tsv" ] || continue
    local -a bleibt=()
    while IFS=$'\t' read -r rel original ekb art kat; do
      [ -n "$rel" ] || continue
      if [ "$art" != "ersetzt" ] && nachwachsend "$kat" && [ -e "$original" ] && [ -e "$sordner/$rel" ]; then
        local vorher_kb; vorher_kb="$(du -sk "$sordner/$rel" 2>/dev/null | cut -f1)"
        rm -rf "$sordner/$rel" 2>/dev/null
        if [ -e "$sordner/$rel" ]; then
          warn "liess sich nicht löschen: ${original/#$HOME/$TILDE}"
          bleibt+=("$(manifest_zeile "$rel" "$original" "$ekb" "$art" "$kat")")
          continue
        fi
        geloescht=$((geloescht+1)); wirklich_frei=$((wirklich_frei + vorher_kb))
      else
        bleibt+=("$(manifest_zeile "$rel" "$original" "$ekb" "$art" "$kat")")
      fi
    done < "$sordner/_manifest.tsv"
    zeilen_schreiben "$sordner/_manifest.tsv" "${bleibt[@]+"${bleibt[@]}"}"
    leere_ordner_entfernen "$sordner"
    if [ ! -s "$sordner/_manifest.tsv" ]; then
      rm -f "$sordner/_manifest.tsv"; rmdir "$sordner" 2>/dev/null
      info "  Stapel $(basename "$sordner") ist jetzt leer und wurde entfernt."
    fi
  done
  info "\n${gruen}$geloescht Einträge gelöscht${aus}, $(mb "$wirklich_frei") freigegeben."
}
