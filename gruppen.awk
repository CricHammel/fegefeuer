BEGIN {
  FS = OFS = "\t"
  split("com org net io de ch dk us co me ai eu uk fr es it se no fi pl cz ru cn jp tv gg is im la to ly", x, " ")
  for (i in x) tld[x[i]] = 1
  split("group shared private family mac macos osx desktop app apps client my " \
        "extension extensions safariextension safariextensionapp webextension " \
        "widget widgetextension shareextension actionextension intents intentsui " \
        "service services serviceextension notificationserviceextension helper " \
        "loginhelper loginitemhelper launchhelper launcher updater autoupdate fba " \
        "sandbox thumbnails thumbnail quicklookpreview quicklookthumbnail preview " \
        "plist savedstate binarycookies store storage data files finder findersync " \
        "networkextension tunnel button social safety privacy custom blocker scripts " \
        "others web bridge agent daemon xpc pro plus lite free beta dev v2 v3 x", y, " ")
  for (i in y) generisch[y[i]] = 1
}

function tokenisieren(name,   roh, teile, n, i, t, ergebnis, gesehen, anzahl) {
  sub(/^[A-Z0-9]{10}\./, "", name)
  sub(/\.(savedState|plist|binarycookies)$/, "", name)
  roh = tolower(name)
  gsub(/[^a-z0-9]+/, " ", roh)
  anzahl = split(roh, teile, " ")
  n = 0
  delete gesehen
  for (i = 1; i <= anzahl; i++) {
    t = teile[i]
    if (t == "" || tld[t] || generisch[t]) continue
    if (t ~ /^[0-9]+$/) continue
    if (length(t) < 2) continue
    if (t in gesehen) continue
    gesehen[t] = 1
    ergebnis[++n] = t
  }
  tok1 = (n >= 1) ? ergebnis[1] : ""
  tok2 = (n >= 2) ? ergebnis[2] : ""
  return n
}

# Zwei Durchgaenge ueber dieselbe Datei: NR == FNR trennt sie korrekt.
# (FILENAME waere hier falsch -- beide Argumente tragen denselben Namen.)
NR == FNR {
  if ($2 == "app-rest") {
    basis = $5; sub(/.*\//, "", basis)
    tokenisieren(basis)
    if (tok1 != "" && tok2 != "" && !((tok1 SUBSEP tok2) in kombi)) {
      kombi[tok1 SUBSEP tok2] = 1
      produkte[tok1]++
    }
  }
  next
}

{
  reihen[FNR] = $0
  if ($2 == "app-rest") {
    basis = $5; sub(/.*\//, "", basis)
    tokenisieren(basis)
    if (tok1 == "") schluessel = tolower(basis)
    else if (produkte[tok1] >= 3 && tok2 != "") schluessel = tok1 "." tok2
    else schluessel = tok1
    # Haeufigsten Produktnamen je Gruppe merken -- der ist wiedererkennbarer
    # als der Herstellername (com.khanov.BlockerX -> "BlockerX", nicht "khanov")
    if (tok2 != "" && tok2 != tok1) {
      mitprodukt[schluessel]++
      zaehler[schluessel SUBSEP tok2]++
      if (zaehler[schluessel SUBSEP tok2] > best[schluessel]) {
        best[schluessel] = zaehler[schluessel SUBSEP tok2]
        produktname[schluessel] = tok2
      }
    }
  } else {
    schluessel = $5
  }
  gruppe[FNR] = schluessel
}

END {
  for (i = 1; i <= FNR; i++) {
    g = gruppe[i]
    if (index(g, ".") > 0) {
      # Schluessel traegt schon Hersteller.Produkt
      hersteller = g; sub(/\..*/, "", hersteller)
      produkt    = g; sub(/.*\./, "", produkt)
      etikett = hersteller " \xc2\xb7 " produkt
    } else if (produktname[g] != "" && best[g] * 2 >= mitprodukt[g]) {
      # Ein Produktname dominiert -- beide zeigen, damit nichts geraten wirkt
      etikett = g " \xc2\xb7 " produktname[g]
    } else {
      etikett = g
    }
    print reihen[i], g, etikett
  }
}
