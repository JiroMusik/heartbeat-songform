#!/bin/sh
# Heartbeat-DMX Netzwerk-Worker — Installation (Linux/macOS).
#
# Ein Befehl, ein Worker: zieht das Abbild und startet es in der
# Betriebsart "schleife" — der Worker FRAGT den Lichtrechner selbst
# nach Arbeit (kein Tunnel, kein Schluessel im eigenen Netz) und
# startet nach jedem Boot von allein wieder (--restart unless-stopped).
#
#   ./worker-install.sh http://<lichtrechner>:5555 <ortsname> [aufgabe]
#
# Beispiel:
#   ./worker-install.sh http://192.168.1.50:5555 studio-pc songform
#
# Danach im Admin unter Rechenorte: den Ort <ortsname> anlegen (falls
# noch nicht da) und die Aufgabe ankreuzen — ohne Haekchen bekommt der
# Worker nichts, mit Absicht (ein Tippfehler soll keine Arbeit ziehen).
#
# macOS-Hinweis: ohne NVIDIA-Karte rechnet der Worker auf der CPU —
# das funktioniert, dauert je Titel aber ein Vielfaches.
set -e

BASIS_URL="$1"
ORT_NAME="$2"
AUFGABE="${3:-songform}"
ABBILD="ghcr.io/jiromusik/heartbeat-songform:latest"

if [ -z "$BASIS_URL" ] || [ -z "$ORT_NAME" ]; then
    echo "Aufruf: $0 http://<lichtrechner>:5555 <ortsname> [aufgabe]" >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker fehlt — https://docs.docker.com/get-docker/" >&2
    exit 1
fi

# GPU nur anfordern, wenn das Werkzeug dafuer ueberhaupt da ist:
# ein --gpus all ohne NVIDIA-Laufzeit laesst den Start scheitern,
# und ein CPU-Worker ist besser als gar keiner.
GPU=""
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU="--gpus all"
    echo "NVIDIA-Karte gefunden — Worker rechnet auf der GPU."
else
    echo "Keine NVIDIA-Karte gefunden — Worker rechnet auf der CPU (langsam)."
fi

NAME="heartbeat-worker-$ORT_NAME"
echo "Ziehe $ABBILD ..."
docker pull "$ABBILD"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --restart unless-stopped $GPU \
    -e BETRIEBSART=schleife \
    -e BASIS_URL="$BASIS_URL" \
    -e ORT_NAME="$ORT_NAME" \
    -e AUFGABE="$AUFGABE" \
    "$ABBILD"
echo
echo "Worker '$NAME' laeuft. Protokoll:  docker logs -f $NAME"
echo "Nicht vergessen: im Admin unter Rechenorte den Ort '$ORT_NAME'"
echo "anlegen und die Aufgabe '$AUFGABE' ankreuzen."
