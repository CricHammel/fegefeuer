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

# ---------- Module ----------
# Immer alle laden: Nur das Noetige je Befehl zu laden spart nichts und
# riskiert, eine Abhaengigkeit zu vergessen -- das fiele erst zur Laufzeit auf.
for modul in gemeinsam schutz kandidaten scan review quarantaene brew video; do
  # shellcheck source=/dev/null
  . "$BASIS/lib/$modul.sh" || { echo "fegefeuer: Modul fehlt: $BASIS/lib/$modul.sh" >&2; exit 1; }
done
unset modul

# ---------- Hilfe ----------
befehl_hilfe() {
  cat <<HILFE
${fett}fegefeuer.sh${aus} — Festplatte aufräumen ohne Reue

  ${fett}scan${aus}              Festplatte analysieren, Kandidaten sammeln
  ${fett}review${aus} [kategorie] Kandidaten durchgehen; Einträge desselben Programms
                    werden zu einer Entscheidung zusammengefasst
  ${fett}mark${aus} <kat> <status> Offene Einträge einer Kategorie auf go/keep setzen
                    ${grau}--alle${aus}  auch schon Entschiedenes überschreiben
                    ${grau}neu${aus}     setzt die ganze Kategorie zurück
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
  scan) shift; befehl_scan "$@";;
  review) befehl_review "${2:-}";;
  apply) befehl_apply;;
  list) befehl_list;;
  restore) shift; befehl_restore "$@";;
  mark) shift; befehl_mark "$@";;
  zeigen) befehl_zeigen "${2:-}";;
  gruppen) befehl_gruppen "${2:-}";;
  brew) befehl_brew;;
  video) shift; befehl_video "$@";;
  purge) shift; befehl_purge "$@";;
  pruefen) befehl_pruefen;;
  *) befehl_hilfe;;
esac
