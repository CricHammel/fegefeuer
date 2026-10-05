# lib/schutz.sh -- Die Schutzliste: Pfade, die fegefeuer nie anfasst, und was die Scans
# gar nicht erst durchsuchen. Hier anpassen, wenn dein Rechner andere
# heikle Orte hat.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- Schutzliste ----------
# Diese Pfade werden NIE angefasst, egal was in der Kandidatenliste steht.
ist_geschuetzt() {
  local p="$1"
  case "$p" in
    "$HOME"/Library/Keychains*|\
    "$HOME"/Library/Mail*|\
    "$HOME"/Library/Messages*|\
    "$HOME"/Library/Mobile\ Documents*|\
    *.photoslibrary|*.photoslibrary/*|\
    "$HOME"/Library/Application\ Support/AddressBook*|\
    "$HOME"/Library/Group\ Containers/group.com.apple.notes*|\
    "$HOME"/Library/Containers/com.apple.mail*|\
    "$HOME"/.ssh*|\
    "$HOME"/.gnupg*|\
    "$HOME"/Library/Preferences/ByHost*|\
    "$HOME"/Library/Metadata*|\
    "$HOME"/Library/Group\ Containers/UBF8T346G9.*|\
    *OneDrive*|\
    "$HOME"/Library/CloudStorage|"$HOME"/Library/CloudStorage/*|\
    "$HOME"/Dropbox|"$HOME"/Dropbox/*|"$HOME"/Dropbox\ \(*|\
    "$HOME"/Google\ Drive|"$HOME"/Google\ Drive/*|\
    "$HOME"/Box|"$HOME"/Box/*|"$HOME"/pCloud\ Drive|"$HOME"/pCloud\ Drive/*|\
    "$HOME"/.fegefeuer|"$HOME"/.fegefeuer/*|\
    "$HOME"/.aufraeumen-quarantaene|"$HOME"/.aufraeumen-quarantaene/*|\
    "$ARBEIT"|"$ARBEIT"/*|\
    *.noindex/*|\
    "$HOME"/*.7z|\
    "$HOME") return 0;;
  esac
  # Nie etwas aus einem Paket heraus -- das Paket selbst darf wandern
  liegt_in_paket "$p" && return 0
  # Nie außerhalb des Home löschen
  case "$p" in
    "$HOME"/*) ;;
    *) return 0;;
  esac
  return 1
}

# Was fegefeuer selbst ablegt, darf kein Scan finden. Sonst erscheint eine
# Datei im Fegefeuer als Dublette ihrer letzten echten Kopie -- behaelt man
# die aus dem Fegefeuer, wandert auch die echte hinein, und purge loescht
# nach sieben Tagen beide.
INTERN_AUSSCHLUSS=(! -path "$HOME/.fegefeuer/*" ! -path "$HOME/.aufraeumen-quarantaene/*"
                   ! -path "$ARBEIT/*")

# Foto-Mediatheken sind Pakete: Eine einzelne Datei daraus zu verschieben
# beschaedigt die ganze Mediathek. Sie heissen "Name.photoslibrary" -- das
# fruehere Muster */.photoslibrary/* traf deshalb nie. Und sie liegen nicht
# nur in ~/Pictures.
# Gegenstueck zum photoslibrary-Eintrag in ist_geschuetzt.
MEDIATHEK_AUSSCHLUSS=(! -path "*.photoslibrary/*")

# ---------- Pakete ----------
# Apps, virtuelle Maschinen und Projekte sind Ordner, die der Finder als eine
# Datei zeigt. Eine einzelne Datei daraus zu verschieben beschaedigt das
# Paket: die Festplatte einer VM als "gross", eine Bibliothek, die zwei Apps
# gleich mitbringen, als "Dublette". Die Scans gehen nicht hinein; grosse
# Pakete zeigt scan als Ganzes. Foto-Mediatheken sind auch Pakete, aber
# ganz geschuetzt (siehe oben).
PAKET_ENDUNGEN=(app pvm utm vmwarevm fcpbundle logicx band imovielibrary musiclibrary
                sparsebundle xcarchive)

# Daraus gebildet, damit die Liste nur an einer Stelle steht:
#   PAKET_AUSSCHLUSS  find-Tests, die nichts innerhalb eines Pakets durchlassen
#   PAKET_NAMEN       find-Ausdruck, der die Pakete selbst trifft (in \( \))
PAKET_AUSSCHLUSS=()
PAKET_NAMEN=()
for _endung in "${PAKET_ENDUNGEN[@]}"; do
  PAKET_AUSSCHLUSS+=(! -path "*.$_endung/*")
  [ ${#PAKET_NAMEN[@]} -gt 0 ] && PAKET_NAMEN+=(-o)
  PAKET_NAMEN+=(-name "*.$_endung")
done
unset _endung

liegt_in_paket() {   # liegt_in_paket <pfad>
  local e
  for e in "${PAKET_ENDUNGEN[@]}"; do
    case "$1" in *."$e"/*) return 0;; esac
  done
  return 1
}

# Python-Umgebungen: oft dieselben Bibliotheken in jedem Projekt. Eine davon
# zu verschieben macht die Umgebung kaputt. Nur fuer die Dublettensuche --
# grosse Dateien darin (Modelle etwa) bleiben sichtbar.
UMGEBUNG_AUSSCHLUSS=(! -path "*/venv/*" ! -path "*/.venv/*" ! -path "*/site-packages/*")

# Cloud-Ordner gehoeren nicht nur diesem Rechner: Was hier verschwindet,
# verschwindet auf dem Server, bei geteilten Ordnern fuer alle. Die Scans
# gehen gar nicht erst hinein -- schon das Lesen einer nur online liegenden
# Datei, etwa zum Hashen, laedt sie herunter.
# Gegenstueck zu den Cloud-Eintraegen in ist_geschuetzt.
WOLKEN_AUSSCHLUSS=(! -path "$HOME/Library/CloudStorage/*" ! -path "*/Library/Mobile Documents/*"
                   ! -path "*OneDrive*" ! -path "$HOME/Dropbox/*" ! -path "$HOME/Dropbox (*"
                   ! -path "$HOME/Google Drive/*" ! -path "$HOME/Box/*" ! -path "$HOME/pCloud Drive/*")
