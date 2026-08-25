#!/bin/sh
# Start des Rechenort-Containers.
#
# KEIN TUNNEL MEHR (25.08.2026): Tailscale war eine Konstruktion der
# RunPod-Nacht vom 18.08., damit der Abhol-Worker den Lichtrechner
# erreichte. Der Cloud-Weg faehrt seit dem 25.08. direkt (Audio im
# Auftrag, Ergebnis in der Antwort), und LAN-Worker sprechen ohnehin
# direkt -- uebrig bleibt hier nur: pruefen, ob der Lichtrechner
# antwortet, dann uebergeben.
set -e

echo "[start] Rechenort '${ORT_NAME}' fuer Aufgabe '${AUFGABE}'"

# BETRIEBSART "direkt" (Produkt-Weg): das Audio steckt in der Anfrage,
# das Ergebnis geht als Antwort zurueck. Der Container ruft niemanden
# an -- keine Basis-Adresse, KEIN GEHEIMNIS in der Umgebung. Alles
# unterhalb dieses Blocks dient der Abhol-Betriebsart (schleife).
if [ "$(echo "${BETRIEBSART:-serverless}" | tr 'A-Z' 'a-z')" = "direkt" ]; then
    echo "[start] Betriebsart 'direkt' -- uebergebe an den Handler"
    exec python -u /app/handler.py
fi

# EIN NAME, in dieser Datei und im Handler derselbe. Zwei aehnliche
# Regeln an zwei Stellen sind schlimmer als eine strenge: dann entscheidet
# die Datei, und nicht der Vertrag.
if [ -z "$BASIS_URL" ]; then
    echo "[start] ABBRUCH: BASIS_URL ist nicht gesetzt." >&2
    echo "[start] Sie muss auf den Lichtrechner zeigen, z. B." >&2
    echo "[start]   BASIS_URL=http://192.168.1.50:5555" >&2
    exit 1
fi

# ORT_NAME IST PFLICHT, und zwar weil sein Fehlen sonst NICHT auffiele.
#
# Der Lichtrechner prueft mit `kann(ort, aufgabe)`, ob dieser Ort die
# Aufgabe traegt. Passt der Name nicht, ist die Antwort auf
# /api/analyse/holen schlicht {"auftrag": null} -- dasselbe, was ein
# Worker bekommt, fuer den gerade nichts anliegt. Der Worker meldete
# also Erfolg, der Auftrag bliebe liegen, und niemand saehe einen Fehler.
if [ -z "$ORT_NAME" ]; then
    echo "[start] ABBRUCH: ORT_NAME ist nicht gesetzt." >&2
    echo "[start] Er muss die KENNUNG aus den Rechenorten tragen" >&2
    echo "[start] (die linke Spalte), nicht den Anzeigenamen." >&2
    exit 1
fi

# ERREICHBARKEIT BELEGEN, BEVOR EIN AUFTRAG ANGEFASST WIRD.
#
# `/api/analyse/wav` ohne gueltige id antwortet mit 404 "unbekannte id"
# und beansprucht nichts: Verbindungsfehler heisst also "Adresse/Netz",
# 404 heisst "alles in Ordnung". Die Karte der Maschine faehrt als
# Gruss mit -- sie steht damit im Zugriffsprotokoll des Lichtrechners,
# ohne neue Route (die Antwort auf "WELCHE Karte war schuld?" hat am
# 19.08.2026 einen Abend gekostet).
python - <<'PY'
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def _karte():
    try:
        aus = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=15)
        erste = (aus.stdout or "").strip().splitlines()
        return erste[0].strip() if erste else "nvidia-smi ohne Ausgabe"
    except Exception as e:                              # noqa: BLE001
        return "%s: %s" % (type(e).__name__, e)


KARTE = _karte()
print("[karte] %s" % KARTE, flush=True)

url = (os.environ["BASIS_URL"].rstrip("/") + "/api/analyse/wav?ort="
       + urllib.parse.quote(os.environ.get("ORT_NAME", "?"))
       + "&karte=" + urllib.parse.quote(KARTE))

letzter = None
for versuch in range(5):
    try:
        urllib.request.urlopen(urllib.request.Request(url), timeout=20)
        print("[probe] unerwartet: 200 auf eine Anfrage ohne id -- aber erreichbar")
        letzter = None
        break
    except urllib.error.HTTPError as e:
        print("[probe] Lichtrechner erreichbar (HTTP %d)" % e.code)
        letzter = None
        break
    except Exception as e:                              # noqa: BLE001
        letzter = e
    if letzter is not None and versuch < 4:
        pause = (2, 4, 8, 15)[versuch]
        print("[probe] noch nicht erreichbar (%s) -- neuer Versuch in %ds"
              % (type(letzter).__name__, pause), flush=True)
        time.sleep(pause)

if letzter is not None:
    print("[probe] ABBRUCH: %s nach 5 Versuchen nicht erreichbar -- %s: %s"
          % (url, type(letzter).__name__, letzter), file=sys.stderr)
    print("[probe] Stimmt BASIS_URL, und ist die Maschine im selben Netz "
          "wie der Lichtrechner?", file=sys.stderr)
    sys.exit(1)
PY

echo "[start] uebergebe an den Handler"
exec python -u /app/handler.py
