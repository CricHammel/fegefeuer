# lib/video.sh -- video: Videos vermessen, auswaehlen, neu kodieren und pruefen.
#
# Wird von fegefeuer.sh geladen, nicht direkt aufgerufen.

# ---------- video ----------
# Neukodieren ist etwas anderes als Verschieben: es erzeugt eine neue,
# verlustbehaftete Datei. Darum ein eigener Unterbefehl mit eigener Liste
# und eigener Pruefung -- und nicht als weitere Kategorie in kandidaten.tsv,
# wo "go" bisher immer nur "verschieben" bedeutet hat.

VIDEOLISTE="$DATEN/video-kandidaten.tsv"

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
  ffmpeg_verfolgen $! "$meldedatei" "$dauer" "$text"
  local rc=$?
  rm -f "$meldedatei"
  return "$rc"
}

# Wartet auf einen ffmpeg-Prozess im Hintergrund und zeigt dabei, wie weit er
# ist. Gestartet wird ffmpeg vom Aufrufer, weil die Aufrufe sich darin
# unterscheiden, wohin die Ausgabe geht. Gibt den Rueckgabewert von ffmpeg
# zurueck.
ffmpeg_verfolgen() {   # ffmpeg_verfolgen <pid> <meldedatei> <dauer_s> <text>
  local ff="$1" meldedatei="$2" text="$4" gesamt_ms us rc
  gesamt_ms="$(LC_ALL=C awk -v d="$3" 'BEGIN{ printf "%d", d * 1000 }')"
  fortschritt_start
  while kill -0 "$ff" 2>/dev/null; do
    us="$(grep '^out_time_us=' "$meldedatei" 2>/dev/null | tail -1 | cut -d= -f2)"
    case "$us" in
      ''|*[!0-9]*) ;;
      *) fortschritt "$((us / 1000))" "$gesamt_ms" "$text";;
    esac
    sleep 1
  done
  wait "$ff"
  rc=$?
  fortschritt_ende
  return "$rc"
}

# Schaetzt fuer alle 'go'-Eintraege der Liste: belegt, danach, Minuten.
# ziel_h = 0 heisst Auflösung beibehalten, sonst die kurze Seite auf diesen
# Wert verkleinern.
# auswahl "go" (Standard) rechnet ueber die freigegebenen Dateien -- das
# braucht video run. "lohnt" rechnet ueber alle vorgeschlagenen -- das
# braucht der Bericht nach video scan. Beide ueber dieselbe Rechnung, damit
# sie fuer dieselben Dateien dieselben Zahlen nennen.
video_schaetzen() {   # video_schaetzen <profil> <ziel_hoehe> [go|lohnt] -> "belegt danach minuten"
  local bpp mpxs
  bpp="$(video_profil_feld "$1" 3)"
  mpxs="$(video_profil_feld "$1" 4)"
  LC_ALL=C awk -F'\t' -v bpp="$bpp" -v mpxs="$mpxs" -v zh="${2:-0}" -v auswahl="${3:-go}" '
    (auswahl == "lohnt" ? $12 == "lohnt" : $1 == "go") {
      w=$5; h=$6; fps=$7; dauer=$8; kb=$9
      # Wie video run: die kurze Seite wird begrenzt. Sie bleibt dieselbe,
      # ob die Liste die Masse gedreht fuehrt oder nicht (ffprobe meldet sie
      # ungedreht, die Kamera vermerkt die Drehung nur).
      kurz = (w < h) ? w : h
      verhaeltnis = (zh > 0 && kurz > zh) ? (zh / kurz) ^ 2 : 1
      aus_kb = bpp * w * h * verhaeltnis * fps * dauer / 8 / 1024
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
  # Die Pruefung skaliert mit Bezugsbild (scale=rw:rh), das gibt es erst ab
  # ffmpeg 7.1. Ein aelteres liesse jede Pruefung scheitern -- mit einer
  # Meldung, die nach kaputter Datei klingt. Darum vorab an zwei Farbflaechen
  # ausprobieren statt die Versionsnummer zu deuten.
  if ! ffmpeg -v error -f lavfi -i color=s=16x16:d=0.1 -f lavfi -i color=s=32x32:d=0.1 \
       -lavfi "[0:v][1:v]scale=rw:rh" -f null - </dev/null >/dev/null 2>&1; then
    fehler "Dieses ffmpeg ist zu alt für die Prüfung (nötig: 7.1 oder neuer)."
    info "  ${fett}brew upgrade ffmpeg${aus}"
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

# Liegt genau eine Datei im ZIP? Nur dann darf die neue Fassung das ZIP
# ersetzen -- sonst laegen die uebrigen Dateien nur noch im Fegefeuer, bis
# purge sie loescht. Ordnereintraege und die Beigaben des Finders
# (__MACOSX, .DS_Store) zaehlen nicht.
zip_einzeldatei() {   # zip_einzeldatei <zip>
  local n
  n="$(LC_ALL=C unzip -Z1 "$1" 2>/dev/null | grep -v '/$' | grep -v '^__MACOSX/' \
       | grep -vE '(^|/)\.DS_Store$' | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ]
}

befehl_video_scan() {
  video_werkzeuge_pruefen || return 1
  local wurzel="${1:-$HOME}"
  [ -d "$wurzel" ] || { fehler "Kein Verzeichnis: $wurzel"; return 1; }
  # Absolut machen: find gaebe zu einem relativen Ordner relative Pfade aus,
  # und die Schutzliste hielte sie fuer ausserhalb des Home -- video run
  # uebersprang dann jede Datei. pwd ohne -P, damit der Pfad mit $HOME
  # beginnt, auch wenn darin ein Symlink steckt.
  wurzel="$(cd "$wurzel" && pwd)"

  titel "Videos suchen unter ${wurzel/#$HOME/$TILDE}"
  local tmp="$ARBEIT/video_fund.txt"
  find "$wurzel" -type f \( \
       -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.avi" \
    -o -iname "*.mkv" -o -iname "*.wmv" -o -iname "*.mpg" -o -iname "*.mpeg" \
    -o -iname "*.mp4.zip" -o -iname "*.mov.zip" -o -iname "*.m4v.zip" \) \
    -size +20M \
    ! -path "*/Library/*" ! -path "*/.fegefeuer/*" ! -path "*/node_modules/*" \
    ! -path "*/.Trash/*" "${MEDIATHEK_AUSSCHLUSS[@]}" "${PAKET_AUSSCHLUSS[@]}" "${WOLKEN_AUSSCHLUSS[@]}" \
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
  local i=0 messfehler=0 mehrteilig=0
  while IFS= read -r pfad; do
    i=$((i+1))
    fortschritt "$i" "$gefunden" "Videos vermessen"
    local messpfad="$pfad" verpackt="nein" temp=""
    case "$pfad" in
      *.zip)
        verpackt="ja"
        zip_einzeldatei "$pfad" || { mehrteilig=$((mehrteilig+1)); continue; }
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
  [ "$mehrteilig" -gt 0 ] && warn "$mehrteilig ZIPs enthalten mehr als eine Datei — nicht vorgeschlagen, sonst ersetzte ein Video das ganze ZIP"

  # bpp und Urteil ergaenzen. Die erwarteten Groessen kommen aus der
  # Profiltabelle -- frueher standen hier eigene Konstanten aus einer
  # aelteren Messreihe, und scan und run nannten verschiedene Zahlen.
  LC_ALL=C awk -F'\t' -v OFS='\t' \
      -v s="$VIDEO_SCHWELLE" -v sm="$VIDEO_SCHWELLE_MODERN" \
      -v bs="$(video_profil_feld schnell 3)" -v bp="$(video_profil_feld sparsam 3)" \
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
    # Gegenstueck zu zahl() fuer Werte, die in awk Zeile fuer Zeile entstehen
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
           for(i=16;i<=n;i++) s+=g[i]; printf "%.2f", s }' "$VIDEOLISTE")"
    rest_gb="$(zahl "$rest_gb" 2)"
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

  # Alle Profile aus der Tabelle, gerechnet wie die Auswahl in video run.
  # Frueher standen hier zwei Profile fest eingetippt; av1 und klein fehlten.
  local n_lohnt belegt_kb gesamt_kb name danach minuten hinweis
  read -r n_lohnt belegt_kb gesamt_kb <<< "$(LC_ALL=C awk -F'\t' '
      { gesamt += $9 } $12=="lohnt" { n++; belegt += $9 }
      END { printf "%d\t%d\t%d", n, belegt, gesamt }' "$VIDEOLISTE")"
  echo
  info "  ${fett}$n_lohnt Dateien vorgeschlagen${aus} — $(mb "$belegt_kb") von $(mb "$gesamt_kb") Videomaterial"
  echo
  printf "  %-10s %-22s %9s %11s %12s\n" "Profil" "Encoder" "danach" "gespart" "Rechenzeit"
  for name in $(video_profil_namen); do
    read -r _ danach minuten <<< "$(video_schaetzen "$name" 0 lohnt)"
    printf "  %-10s %-22s %9s %11s %8s min\n" "$name" "$(video_profil_feld "$name" 1)" \
      "$(mb "$danach")" "$(mb $((belegt_kb - danach)))" "$(zahl "$minuten" 1)"
  done
  for name in $(video_profil_namen); do
    hinweis="$(video_profil_feld "$name" 5)"
    [ -n "$hinweis" ] && info "  ${gelb}⚠ $name:${aus} ${grau}$hinweis${aus}"
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
  # Die neue Fassung wird fuer den Vergleich auf das Bild des Originals
  # gebracht -- bei verkleinerter Ausgabe hochskaliert, sonst kann der
  # ssim-Filter die Bilder nicht uebereinanderlegen. Das Mass nimmt scale
  # direkt vom Original (rw:rh), nicht von ffprobe: ffprobe meldet die
  # ungedrehten Masse, ffmpeg dreht aber beim Dekodieren, was die Kamera als
  # Drehung vermerkt hat. Mit den ffprobe-Massen fiel jedes hochkant gefilmte
  # Handyvideo durch.
  local lavfi="[1:v]split[ref1][ref2];[0:v][ref1]scale=rw:rh:flags=bicubic[neu];[neu][ref2]ssim"
  local ausgabe wert meldedatei="$ARBEIT/ssim_fortschritt.txt"
  : > "$meldedatei"
  ffmpeg -hide_banner -nostats -xerror -progress "$meldedatei" -i "$neu" -i "$alt" \
    -lavfi "$lavfi" -f null - > "$ARBEIT/ssim_ausgabe.txt" 2>&1 &
  ffmpeg_verfolgen $! "$meldedatei" "$d_alt" "prüfe Bild und Ton"
  local rc=$?
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

# Strg-C in video review: sichern, was bis dahin entschieden ist, dann
# beenden -- wie r_unterbrochen im review. Die Entscheidungen stehen in
# ausgabe, der lokalen Liste von befehl_video_review; die Falle laeuft in
# deren Kontext und sieht sie. Schluessel ist der Pfad (Spalte 2).
v_unterbrochen() {
  trap - INT
  local entscheidungen="$ARBEIT/video_entscheidungen.tsv"
  zeilen_schreiben "$entscheidungen" "${ausgabe[@]+"${ausgabe[@]}"}"
  awk -F'\t' -v OFS='\t' '
      FILENAME==ARGV[1] { if ($1 != "") status[$2] = $1; next }
      ($2 in status) { $1 = status[$2] }
      { print }' "$entscheidungen" "$VIDEOLISTE" > "$VIDEOLISTE.tmp" \
    && mv "$VIDEOLISTE.tmp" "$VIDEOLISTE"
  rm -f "$entscheidungen"
  printf '\n'
  info "Unterbrochen. Was du bis hierher entschieden hast, ist gespeichert."
  info "Weiter mit: ${fett}$0 video review${aus}"
  exit 130
}

befehl_video_review() {
  [ -s "$VIDEOLISTE" ] || { fehler "Keine Videoliste. Erst '$0 video scan'."; return 1; }
  local offen
  offen="$(awk -F'\t' '$1=="neu" && $12=="lohnt"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
  [ "$offen" -eq 0 ] && { info "Nichts offen. Weiter mit: ${fett}$0 video run${aus}"; return 0; }

  info "\n${fett}Videos durchgehen${aus} — $offen offen"
  info "${grau}Die Originale wandern nach bestandener Prüfung ins Fegefeuer.${aus}"

  local -a ausgabe=()
  local zeile nr=0 abbruch=0 alle=0
  trap v_unterbrochen INT
  while IFS= read -r zeile <&3; do
    local st pfad verpackt codec w h fps dauer kb rohkb bpp urteil neu_schnell neu_kb
    felder_lesen "$zeile" st pfad verpackt codec w h fps dauer kb rohkb bpp urteil neu_schnell neu_kb
    if [ "$st" != "neu" ] || [ "$urteil" != "lohnt" ] || [ "$abbruch" -eq 1 ]; then
      ausgabe+=("$zeile"); continue
    fi
    if [ "$alle" -eq 1 ]; then ausgabe+=("$(status_setzen "$zeile" go)"); continue; fi
    nr=$((nr+1))
    printf '\n%s[%d/%d]%s %s\n' "$grau" "$nr" "$offen" "$aus" "${pfad/#$HOME/$TILDE}"
    printf '  %s%sx%s · %s fps · %s min · %s bpp%s\n' "$grau" "$w" "$h" \
      "$(zahl "$fps" 0)" "$(zahl "$(LC_ALL=C awk -v d="$dauer" 'BEGIN{print d/60}')" 1)" \
      "$(zahl "$bpp" 3)" "$aus"
    printf '  %s%s%s  →  etwa %s%s%s\n' "$fett" "$(mb "$kb")" "$aus" "$fett" "$(mb "$neu_kb")" "$aus"
    local antwort
    while true; do
      tasten "  " "j:neu kodieren" "n:so lassen" "a:alle übrigen freigeben" "o:Finder" "s:später" "q:Ende"
      printf '  → '
      read -r antwort || antwort=q
      case "$antwort" in
        j|J) ausgabe+=("$(status_setzen "$zeile" go)"); break;;
        n|N) ausgabe+=("$(status_setzen "$zeile" keep)"); break;;
        a|A) alle=1; ausgabe+=("$(status_setzen "$zeile" go)"); break;;
        o|O) open -R "$pfad" 2>/dev/null;;
        s|S|"") ausgabe+=("$zeile"); break;;
        q|Q) abbruch=1; ausgabe+=("$zeile"); break;;
        *) tasten_bitte '  ';;
      esac
    done
  done 3< "$VIDEOLISTE"
  trap - INT

  zeilen_schreiben "$VIDEOLISTE" "${ausgabe[@]+"${ausgabe[@]}"}"
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

  local stapel; stapel="$(date '+%Y-%m-%d_%H%M%S')"
  local ziel="$QUARANTAENE/$stapel"
  local manifest="$ziel/_manifest.tsv"
  mkdir -p "$ziel"; touch "$manifest"
  local tmpdir="$ARBEIT/video_arbeit"
  rm -rf "$tmpdir"; mkdir -p "$tmpdir"

  local fertig=0 misslungen=0 gespart=0 i=0 platz_fehlt=0
  local zeile
  while IFS= read -r zeile <&3; do
    local st pfad verpackt codec w h fps dauer kb
    felder_lesen "$zeile" st pfad verpackt codec w h fps dauer kb rohkb
    [ "$st" = "go" ] || continue
    i=$((i+1))
    [ -e "$pfad" ] || { warn "verschwunden: ${pfad/#$HOME/$TILDE}"; continue; }
    ist_geschuetzt "$pfad" && { warn "geschützt, übersprungen: ${pfad/#$HOME/$TILDE}"; continue; }

    printf '\n%s[%d/%d]%s %s\n' "$grau" "$i" "$anzahl" "$aus" "${pfad/#$HOME/$TILDE}"

    # Platz vor jeder Datei pruefen, nicht einmal vorab: Die Originale
    # bleiben im Fegefeuer auf derselben Platte, jede neue Fassung kommt
    # hinzu. Gebraucht wird hoechstens die Groesse des Originals -- groesser
    # darf die neue Fassung nicht werden --, bei einem ZIP das Ausgepackte
    # zweimal. Dazu 1 GB Luft fuer alles andere auf dem Mac. Reicht es
    # nicht, endet der Lauf; die uebrigen bleiben freigegeben.
    local noetig frei
    noetig=$(( ${kb:-0} + 1048576 ))
    [ "$verpackt" = "ja" ] && noetig=$(( ${rohkb:-0} * 2 + 1048576 ))
    frei="$(freier_platz_kb "$HOME")"
    if [ "${frei:-0}" -lt "$noetig" ]; then
      warn "Zu wenig Platz: $(mb "${frei:-0}") frei, für diese Datei $(mb "$noetig") nötig."
      info "  ${grau}Lauf beendet. Platz schafft ${aus}${fett}$0 purge${aus}${grau}, sobald du die bisherigen"
      info "  neuen Fassungen angesehen hast; danach geht es mit ${aus}${fett}$0 video run${aus}${grau} weiter.${aus}"
      platz_fehlt=1
      break
    fi

    # Quelle bereitstellen (ZIP wird zum Kodieren ausgepackt)
    local quelle="$pfad" ausgepackt=""
    if [ "$verpackt" = "ja" ]; then
      # Auch hier: Die Liste kann aus einem scan stammen, der noch nicht
      # danach fragte, und ein ZIP kann sich seither geaendert haben.
      if ! zip_einzeldatei "$pfad"; then
        warn "  ZIP enthält mehr als eine Datei — nicht angefasst, sonst ersetzte ein Video das ganze ZIP"
        misslungen=$((misslungen+1)); continue
      fi
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
      # Begrenzt wird die kurze Seite: 1080p heisst 1920x1080 quer und
      # 1080x1920 hochkant. ffmpeg hat das Bild hier schon gedreht -- frueher
      # begrenzte min(...,ih) deshalb bei Hochkant-Videos die lange Seite,
      # und aus 1080x1920 wurde mit 720p ein 404x720.
      # min() verhindert, dass kleinere Videos hochskaliert werden.
      skalierung=(-vf "scale=w='if(gte(iw,ih),-2,min($zielhoehe,iw))':h='if(gte(iw,ih),min($zielhoehe,ih),-2)'")
    fi
    # -map 0:v:0 -map 0:a? nimmt alle Tonspuren mit. Ohne -map waehlt ffmpeg
    # nur eine aus, und 16 der Testdateien hatten zwei.
    # -map_metadata 0 mit use_metadata_tags uebernimmt die Angaben der
    # Kamera, auch Apples eigene wie Aufnahmeort und -datum
    # (com.apple.quicktime.*). Ohne fehlten sie der neuen Datei, und nach
    # purge waeren sie endgueltig weg.
    local -a metadaten=(-map_metadata 0 -movflags +faststart+use_metadata_tags)
    if ! video_ffmpeg "$dauer" "kodiere" -i "$quelle" \
         -map 0:v:0 -map "0:a?" \
         "${skalierung[@]+"${skalierung[@]}"}" "${enc[@]}" -c:a copy "${metadaten[@]}" "$neu"; then
      # Manche Kameras legen Ton ab, den ein MP4 nicht aufnimmt (etwa PCM).
      # Dann neu kodieren statt aufzugeben.
      printf '  %sTon lässt sich nicht übernehmen, kodiere ihn neu …%s\n' "$grau" "$aus"
      if ! video_ffmpeg "$dauer" "kodiere (Ton neu)" -i "$quelle" \
           -map 0:v:0 -map "0:a?" \
           "${skalierung[@]+"${skalierung[@]}"}" "${enc[@]}" -c:a aac -b:a 192k "${metadaten[@]}" "$neu"; then
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
    # Das Datum der Datei uebernehmen: Finder und Fotos sortieren danach,
    # und die neue Datei truege sonst das heutige. Ein aelteres
    # Aenderungsdatum zieht unter macOS das Erstellungsdatum mit. Bei einem
    # ZIP ist die Quelle die ausgepackte Datei -- unzip hat ihr Datum erhalten.
    touch -r "$quelle" "$neu"

    # Original ins Fegefeuer, neue Datei an seinen Platz
    local rel="${pfad#$HOME/}"
    mkdir -p "$(dirname "$ziel/$rel")"
    if ! mv "$pfad" "$ziel/$rel" 2>/dev/null; then
      printf '  %s✗%s Original liess sich nicht sichern\n' "$rot" "$aus"
      misslungen=$((misslungen+1)); rm -f "$neu"; rm -rf "$tmpdir/aus"; continue
    fi
    # Sofort ins Manifest, nicht erst, wenn auch die neue Fassung liegt: Endet
    # das Skript dazwischen, laege das Original sonst ohne Eintrag im Stapel --
    # restore faende es nicht, und purge loeschte es. "ersetzt" ist dabei der
    # vorsichtige Vermerk: purge --wieder-da laesst solche Eintraege aus.
    manifest_zeile "$rel" "$pfad" "$kb" "ersetzt" "video" >> "$manifest"
    local zielname="${pfad%.zip}"
    zielname="${zielname%.*}.mp4"
    # Aus film.mov wird film.mp4 -- das darf keine fremde Datei ueberschreiben.
    if [ -e "$zielname" ] && [ "$zielname" != "$pfad" ]; then
      # Eigener Zaehler: i zaehlt die Dateien dieses Laufs fuer die Anzeige [i/n]
      local zaehler=2
      while [ -e "${zielname%.mp4} ($zaehler).mp4" ]; do zaehler=$((zaehler+1)); done
      zielname="${zielname%.mp4} ($zaehler).mp4"
      warn "  Zielname war belegt, lege ab als $(basename "$zielname")"
    fi
    if ! mv "$neu" "$zielname" 2>/dev/null; then
      # Das Original zurueck an seinen Platz. Sonst laege es nur noch im
      # Fegefeuer, waehrend das Arbeitsverzeichnis mit der neuen Fassung
      # am Ende geloescht wird -- und purge loeschte es nach sieben Tagen.
      printf '  %s✗%s neue Fassung liess sich nicht ablegen\n' "$rot" "$aus"
      misslungen=$((misslungen+1)); rm -f "$neu"; rm -rf "$tmpdir/aus"
      # Die Manifestzeile von oben stimmt dann nicht mehr: Ersetzt wurde nichts.
      sed -i '' '$d' "$manifest"
      if ! mv "$ziel/$rel" "$pfad" 2>/dev/null; then
        # Dann wenigstens so vermerkt, dass restore es findet
        manifest_zeile "$rel" "$pfad" "$kb" "verschoben" "video" >> "$manifest"
        warn "  Das Original liess sich nicht zurücklegen. Es liegt im Stapel $stapel."
      fi
      continue
    fi
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
  # Leere Unterordner bleiben, wenn ein Original zurueckgelegt wurde -- ohne
  # sie wegzuraeumen scheiterte rmdir, und ein leerer Stapel blieb liegen.
  [ -s "$manifest" ] || { rm -f "$manifest"; leere_ordner_entfernen "$ziel"; rmdir "$ziel" 2>/dev/null; }

  info "\n${gruen}$fertig neu kodiert${aus}, $(mb "$gespart") gespart"
  [ "$misslungen" -gt 0 ] && warn "$misslungen fehlgeschlagen — die Originale liegen unverändert an ihrem Platz"
  if [ "$platz_fehlt" -eq 1 ]; then
    local offen_go; offen_go="$(awk -F'\t' '$1=="go"' "$VIDEOLISTE" | wc -l | tr -d ' ')"
    warn "Wegen Platzmangels vorzeitig beendet — $offen_go Videos bleiben freigegeben"
  fi
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
