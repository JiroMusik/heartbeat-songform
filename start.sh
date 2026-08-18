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

if [ -z "$BASIS_URL" ]; then
    echo "[start] ABBRUCH: BASIS_URL ist nicht gesetzt." >&2
    echo "[start] Ohne Adresse des Lichtrechners gibt es nichts zu holen." >&2
    exit 1
fi

if [ -n "$TS_AUTHKEY" ]; then
    echo "[tailnet] trete bei ..."
    tailscaled \
        --tun=userspace-networking \
        --outbound-http-proxy-listen=127.0.0.1:1055 \
        --socks5-server=127.0.0.1:1056 \
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
    tailscale --socket=/tmp/tailscaled.sock up \
        --authkey="$TS_AUTHKEY" \
        --hostname="$NAME" \
        --accept-dns=false \
        --accept-routes=false

    # urllib im Handler liest diese Variablen von selbst (getproxies()).
    # Deshalb steht im Handler keine Zeile ueber Tailscale -- er spricht
    # weiterhin einfach HTTP.
    export http_proxy="http://127.0.0.1:1055"
    export https_proxy="http://127.0.0.1:1055"
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
import urllib.error
import urllib.request

url = os.environ["BASIS_URL"].rstrip("/") + "/api/analyse/wav"
kopf = {}
if os.environ.get("ZUTRITT_SCHLUESSEL", "").strip():
    kopf["X-Rechenort-Schluessel"] = os.environ["ZUTRITT_SCHLUESSEL"].strip()

try:
    urllib.request.urlopen(urllib.request.Request(url, headers=kopf), timeout=20)
    print("[probe] unerwartet: 200 auf eine Anfrage ohne id -- aber erreichbar")
except urllib.error.HTTPError as e:
    if e.code == 403:
        print("[probe] ABBRUCH: 403 vom Lichtrechner -- %s"
              % e.read().decode("utf-8", "replace")[:200], file=sys.stderr)
        print("[probe] Entweder stimmt ZUTRITT_SCHLUESSEL nicht, oder die "
              "Route ist nicht freigegeben (src/zutritt.py).", file=sys.stderr)
        sys.exit(1)
    print("[probe] Lichtrechner erreichbar (HTTP %d)" % e.code)
except Exception as e:
    print("[probe] ABBRUCH: %s nicht erreichbar -- %s: %s"
          % (url, type(e).__name__, e), file=sys.stderr)
    print("[probe] Steht das Tailnet? Ist TS_AUTHKEY gueltig und nicht "
          "abgelaufen?", file=sys.stderr)
    sys.exit(1)
PY

echo "[start] uebergebe an den Handler"
exec python -u /app/handler.py
