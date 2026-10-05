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

# Cloud-Ordner gehoeren nicht nur diesem Rechner: Was hier verschwindet,
# verschwindet auf dem Server, bei geteilten Ordnern fuer alle. Die Scans
# gehen gar nicht erst hinein -- schon das Lesen einer nur online liegenden
# Datei, etwa zum Hashen, laedt sie herunter.
# Gegenstueck zu den Cloud-Eintraegen in ist_geschuetzt.
WOLKEN_AUSSCHLUSS=(! -path "$HOME/Library/CloudStorage/*" ! -path "*/Library/Mobile Documents/*"
                   ! -path "*OneDrive*" ! -path "$HOME/Dropbox/*" ! -path "$HOME/Dropbox (*"
                   ! -path "$HOME/Google Drive/*" ! -path "$HOME/Box/*" ! -path "$HOME/pCloud Drive/*")
