# lib/kandidaten.sh -- Helfer fuer kandidaten.tsv: Status setzen, Gruppen zuordnen, Summen
# ohne Doppelzaehlung, Zeilen schreiben.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# Der Status ist das erste Feld: neuer Status plus alles ab dem ersten Tab.
# Ohne awk -- das lief bei jeder einzelnen Entscheidung im review.
status_setzen() {   # status_setzen <zeile> <neuer-status>
  printf '%s\t%s\n' "$2" "${1#*$'\t'}"
}

# Gruppenschluessel (Spalte 7) und lesbares Etikett (Spalte 8) vergeben
gruppen_zuordnen() {
  local awkdatei="$BASIS/lib/gruppen.awk"
  [ -f "$awkdatei" ] || { warn "Gruppendefinition fehlt, ueberspringe Gruppierung."; return 0; }
  awk -v home="$HOME" -f "$awkdatei" "$KANDIDATEN" "$KANDIDATEN" > "$KANDIDATEN.grp" \
    && mv "$KANDIDATEN.grp" "$KANDIDATEN"
}

# Summiert Groessen, ohne doppelt zu zaehlen, was innerhalb eines anderen
# Eintrags liegt. Ohne das meldet der Scan den Homebrew-Cache und zugleich
# die grossen Dateien darin -- bei einem Lauf waren das 3,16 GB zu viel.
summe_echt() {   # summe_echt [statusfilter]
  LC_ALL=C awk -F'\t' -v f="${1:-}" '
    NR==FNR { if (f=="" || $1==f) pfad[++n]=$5; next }
    (f=="" || $1==f) {
      for (i=1; i<=n; i++) if (index($5, pfad[i] "/") == 1) next
      summe += $3
    }
    END { print summe+0 }' "$KANDIDATEN" "$KANDIDATEN"
}

# Liegt der Pfad innerhalb eines der uebergebenen Pfade?
liegt_innerhalb() {   # liegt_innerhalb <pfad> <pfadliste>
  local pfad="$1" liste="$2" p
  [ -n "$liste" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$pfad" in "$p"/*) return 0;; esac
  done <<< "$liste"
  return 1
}

schreibe_kandidaten() { zeilen_schreiben "$KANDIDATEN" "$@"; }

# Groesse und Aenderungsdatum ermittelt die Funktion selbst -- frueher stand
# beides an jedem der sechs Aufrufe im scan. -x: nicht in andere Volumes
# hinabsteigen; fuer einzelne Dateien aendert das nichts.
kandidat_schreiben() {   # kandidat_schreiben <kategorie> <pfad> <begruendung> [gruppenschluessel]
  local kb mt
  kb="$(du -sk -x "$2" 2>/dev/null | cut -f1)"
  mt="$(stat -f '%Sm' -t '%Y-%m-%d' "$2" 2>/dev/null)"
  if [ -n "${4:-}" ]; then
    printf 'neu\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$kb" "$mt" "$2" "$3" "$4" >> "$KANDIDATEN.tmp"
  else
    printf 'neu\t%s\t%s\t%s\t%s\t%s\n' "$1" "$kb" "$mt" "$2" "$3" >> "$KANDIDATEN.tmp"
  fi
}

# Aeltere Kandidatenlisten haben die Gruppenspalten 7 und 8 noch nicht
gruppen_sicherstellen() {
  [ "$(head -1 "$KANDIDATEN" | awk -F'\t' '{print NF}')" -lt 8 ] || return 0
  info "${grau}Ergänze Gruppenzuordnung …${aus}"
  gruppen_zuordnen
}
