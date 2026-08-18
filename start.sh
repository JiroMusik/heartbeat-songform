#!/bin/sh
# Erst in das Tailnet, dann rechnen.
#
# WARUM DAS HIER STEHT UND NICHT IM HANDLER.
#
# Der Lichtrechner ist aus dem Netz nicht erreichbar, und das soll er auch
# nicht sein. Er liegt in einem Tailnet, und nur wer darin ist, kommt an die
# vier Protokoll-Routen. Der Container muss also beitreten, BEVOR die erste
# Zeile Python eine Adresse aufloest -- ein Handler, der schon laeuft und
# dann feststellt, dass es kein Netz gibt, hat den Auftrag bereits
# beansprucht.
#
# USERSPACE-NETZ, kein TUN. Ein RunPod-Worker bekommt kein /dev/net/tun
# zugesichert, und ein Abbild, das davon abhaengt, laeuft irgendwann auf
# einer Maschine nicht mehr. `--tun=userspace-networking` braucht weder das
# Geraet noch NET_ADMIN. Dass die Verbindung dabei ueber einen lokalen
# Vermittler laeuft, aendert an der Absenderadresse NICHTS: der Lichtrechner
# sieht die Tailnet-Adresse dieses Containers, und genau darauf beruht seine
# Schranke (src/zutritt.py).
#
# Fuer den Lichtrechner selbst waere dieselbe Bauform falsch -- dort kaeme
# eingehender Verkehr als 127.0.0.1 an und wuerde als "Studio-Netz"
# durchgelassen. Er laeuft deshalb mit echtem TUN.
set -e

echo "[start] Rechenort '${ORT_NAME}' fuer Aufgabe '${AUFGABE}'"

# EIN NAME, in dieser Datei und im Handler derselbe. Zwei aehnliche
# Regeln an zwei Stellen sind schlimmer als eine strenge: dann entscheidet
# die Datei, und nicht der Vertrag.
if [ -z "$BASIS_URL" ]; then
    echo "[start] ABBRUCH: BASIS_URL ist nicht gesetzt." >&2
    echo "[start] Sie muss auf den Lichtrechner zeigen, z. B." >&2
    echo "[start]   BASIS_URL=http://100.73.50.47:5555" >&2
    exit 1
fi

# ORT_NAME IST PFLICHT, und zwar weil sein Fehlen sonst NICHT auffiele.
#
# Der Lichtrechner prueft mit `kann(ort, aufgabe)`, ob dieser Ort die
# Aufgabe traegt. Passt der Name nicht, ist die Antwort auf
# /api/analyse/holen schlicht {"auftrag": null} -- dasselbe, was ein
# Endpunkt bekommt, fuer den gerade nichts anliegt. Der Worker meldete
# also Erfolg, der Auftrag bliebe liegen, und niemand saehe einen Fehler.
#
# Am 18.08.2026 hiess der Ort intern `runpod` und wurde als "cloud"
# angezeigt; ein geratener Vorgabewert haette genau hier zugeschlagen.
if [ -z "$ORT_NAME" ]; then
    echo "[start] ABBRUCH: ORT_NAME ist nicht gesetzt." >&2
    echo "[start] Er muss die KENNUNG aus config/rechenorte.json tragen" >&2
    echo "[start] (die linke Spalte), nicht den Anzeigenamen." >&2
    exit 1
fi

if [ -n "$TS_AUTHKEY" ]; then
    echo "[tailnet] trete bei ..."
    tailscaled \
        --tun=userspace-networking \
        --socks5-server=127.0.0.1:1055 \
        --outbound-http-proxy-listen=127.0.0.1:1055 \
        --state=/tmp/tailscaled.state \
        --socket=/tmp/tailscaled.sock \
        > /tmp/tailscaled.log 2>&1 &

    # Auf den Dienst warten, statt blind weiterzulaufen. Ohne diese Schleife
    # trifft `tailscale up` gelegentlich einen Socket, den es noch nicht gibt.
    i=0
    while [ $i -lt 30 ]; do
        tailscale --socket=/tmp/tailscaled.sock status >/dev/null 2>&1 && break
        i=$((i + 1))
        sleep 1
    done

    # Der Name traegt die Worker-Kennung: mehrere Worker gleichzeitig sollen
    # sich in der Tailscale-Konsole unterscheiden lassen, statt sich
    # gegenseitig zu verdraengen.
    NAME="rechenort-${ORT_NAME:-cloud}-${RUNPOD_POD_ID:-$(hostname)}"

    # TAGS, und warum sie hier keine Kuer sind.
    #
    # Ein Auth-Key laeuft nach spaetestens 90 Tagen ab -- dann meldet sich
    # kein Worker mehr an, und niemand merkt es, bis ein Auftrag liegen
    # bleibt. Ein OAuth-Client (`tskey-client-...`) laeuft NICHT ab und
    # loest sich seinen Ephemeral-Key bei jedem Start selbst. Tailscale
    # verlangt dafuer aber einen Tag: ein OAuth-Client ohne
    # --advertise-tags wird abgewiesen.
    #
    # Der Tag ist ausserdem der Griff, an dem die ACL haengt: "wer
    # tag:rechenort traegt, darf dmx-control:5555 und sonst nichts".
    # Und er schaltet den Node-Key-Ablauf fuer das Geraet ab.
    #
    # Leer lassen ist erlaubt -- dann gilt der klassische Auth-Key-Weg.
    TAGS=""
    if [ -n "$TS_TAGS" ]; then
        TAGS="--advertise-tags=$TS_TAGS"
        echo "[tailnet] Tags: $TS_TAGS"
    fi

    tailscale --socket=/tmp/tailscaled.sock up \
        --authkey="$TS_AUTHKEY" \
        --hostname="$NAME" \
        --accept-dns=false \
        --accept-routes=false \
        $TAGS

    # GENAU DIE DREI VARIABLEN AUS DER DOKU
    # (tailscale.com/docs/concepts/userspace-networking):
    #   ALL_PROXY=socks5://localhost:1055/
    #   HTTP_PROXY=http://localhost:1055/
    #   http_proxy=http://localhost:1055/
    #
    # Der HTTP-Vermittler allein reichte NICHT. Am 18.08.2026 gemessen:
    # die Startprobe (GET) kam beim Lichtrechner an, der erste POST
    # scheiterte viermal mit "502 Bad Gateway", und im Protokoll des
    # Lichtrechners stand kein einziger POST. Die Doku nennt den Grund,
    # ohne den Fall zu beschreiben: "The HTTP proxy is only for that
    # protocol" -- SOCKS5 dagegen ist "a more general and flexible proxy
    # that can work with any traffic".
    export ALL_PROXY="socks5://127.0.0.1:1055/"
    export HTTP_PROXY="http://127.0.0.1:1055/"
    export http_proxy="http://127.0.0.1:1055/"
    export NO_PROXY="127.0.0.1,localhost"
    export no_proxy="127.0.0.1,localhost"

    echo "[tailnet] beigetreten als $NAME, Adresse $(tailscale --socket=/tmp/tailscaled.sock ip -4 2>/dev/null || echo unbekannt)"
else
    echo "[tailnet] kein TS_AUTHKEY -- es wird direkt verbunden."
    echo "[tailnet] Das ist nur richtig, wenn diese Maschine schon im Tailnet ist."
fi

# ERREICHBARKEIT BELEGEN, BEVOR EIN AUFTRAG ANGEFASST WIRD.
#
# `/api/analyse/wav` ohne gueltige id antwortet mit 404 "unbekannte id" und
# beansprucht nichts. Das unterscheidet die drei Fehlerarten, die man sonst
# alle als "geht nicht" erlebt:
#   Verbindungsfehler -> Tunnel steht nicht
#   403               -> Schluessel falsch, oder Route nicht freigegeben
#   404               -> alles in Ordnung
python - <<'PY'
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, "/app")
import netz                                              # noqa: E402
print("[netz] Weg ins Tailnet: %s" % netz.einrichten(), flush=True)

url = os.environ["BASIS_URL"].rstrip("/") + "/api/analyse/wav"
kopf = {}
if os.environ.get("ZUTRITT_SCHLUESSEL", "").strip():
    kopf["X-Rechenort-Schluessel"] = os.environ["ZUTRITT_SCHLUESSEL"].strip()

# MEHRERE VERSUCHE, und zwar aus Erfahrung. Am 18.08.2026 kam diese
# Probe durch und der erste POST zwoelf Sekunden spaeter bekam vom
# Tailscale-Vermittler ein "502 Bad Gateway": frisch beigetreten heisst
# noch nicht belastbar. Ein Container, der deshalb sofort aufgibt,
# kostet einen ganzen Kaltstart.
letzter = None
for versuch in range(5):
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers=kopf), timeout=20)
        print("[probe] unerwartet: 200 auf eine Anfrage ohne id -- aber erreichbar")
        letzter = None
        break
    except urllib.error.HTTPError as e:
        if e.code == 403:
            # AENDERT SICH BEIM ZWEITEN MAL NICHT. Sofort abbrechen,
            # statt den Fehler viermal zu wiederholen.
            print("[probe] ABBRUCH: 403 vom Lichtrechner -- %s"
                  % e.read().decode("utf-8", "replace")[:200], file=sys.stderr)
            print("[probe] Entweder stimmt ZUTRITT_SCHLUESSEL nicht, oder die "
                  "Route ist nicht freigegeben (src/zutritt.py).", file=sys.stderr)
            sys.exit(1)
        if e.code in (502, 503, 504):
            letzter = e
        else:
            print("[probe] Lichtrechner erreichbar (HTTP %d)" % e.code)
            letzter = None
            break
    except Exception as e:
        letzter = e
    if letzter is not None and versuch < 4:
        pause = (2, 4, 8, 15)[versuch]
        print("[probe] noch nicht erreichbar (%s) -- neuer Versuch in %ds"
              % (type(letzter).__name__, pause), flush=True)
        time.sleep(pause)

if letzter is not None:
    print("[probe] ABBRUCH: %s nach 5 Versuchen nicht erreichbar -- %s: %s"
          % (url, type(letzter).__name__, letzter), file=sys.stderr)
    print("[probe] Steht das Tailnet? Ist TS_AUTHKEY gueltig, und ist er "
          "als REUSABLE angelegt? Ein einmaliger Schluessel laesst genau "
          "einen Worker herein, jeder weitere bekommt 'invalid key'.",
          file=sys.stderr)
    sys.exit(1)
PY

echo "[start] uebergebe an den Handler"
exec python -u /app/handler.py
