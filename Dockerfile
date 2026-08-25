# SongFormer als RunPod-Serverless-Endpunkt.
#
# Grundsatz: Alles Schwere steckt im Abbild, damit ein Kaltstart nur noch das
# Modell in den GPU-Speicher legen muss. Nichts wird zur Laufzeit
# nachgeladen -- kein pip, kein Modell-Download, keine Ablage.
#
# Die Versionsfestlegungen sind nicht willkuerlich, sondern am 18.08.2026 auf
# dem StudioPC erarbeitet:
#   transformers==4.51.1  Ab 5.x werden Modelle auf dem Platzhalter-Geraet
#                         "meta" angelegt; SongFormers Code erzeugt Tensoren
#                         direkt -> "Tensor on device cpu is not on the
#                         expected device meta".
#   torchvision           Muss aus demselben Index wie torch kommen, sonst
#                         "operator torchvision::nms does not exist".
#   msaf                  Wird nur fuer eine Auswertungsfunktion importiert,
#                         die bei Inferenz nie laeuft -- der Import steht aber
#                         am Dateianfang. Siehe scipy-Bruecke im handler.

# RUNTIME, NICHT DEVEL -- gemessen am 18.08.2026.
#
# Das Abbild war 17,8 GB, davon rund neun allein die Basis: ein
# devel-Abbild mit CUDA-Compiler, Header-Dateien und Werkzeugketten, die
# zur Laufzeit kein einziges Mal angefasst werden. Wir bauen hier nichts
# aus Quelltext; alles kommt als fertiges Rad von pip.
#
# Das kostet nicht nur Platz. Jede Aenderung an der Endpunkt-Umgebung
# erzeugt bei RunPod eine neue Version, und die zwingt einen frischen
# Worker, das Abbild ERNEUT zu ziehen. Am 18.08. war der Endpunkt nach
# einem Nachmittag bei Version 10 -- zehn Downloads, und jeder von ihnen
# stand als "warum dauert das so lange" im Weg.
#
# Die offizielle Runtime-Variante wiegt 3,2 statt 9 GB. RunPods eigene
# Abbilder liegen samt und sonders zwischen 11 und 17 GB; dort war nichts
# zu holen.

# TORCH 2.8 / CUDA 12.8 -- WEIL DIE FLOTTE BLACKWELL KENNT UND 2.4 NICHT.
#
# Hier stand 2.4.1+cu124. Gemessen am 19.08.2026: der Worker starb
# reihenweise in RunPods Tauglichkeitspruefung, und PyTorch selbst hat
# im Protokoll buchstabiert, warum --
#
#   NVIDIA RTX PRO 6000 Blackwell Server Edition MIG 1g.24gb with CUDA
#   capability sm_120 is not compatible with the current PyTorch
#   installation. The current PyTorch install supports CUDA capabilities
#   sm_50 sm_60 sm_70 sm_75 sm_80 sm_86 sm_90.
#
# Blackwell ist sm_120; 2.4 hoert bei sm_90 auf. Es traf nicht immer:
# derselbe Endpunkt lieferte einmal sauber ab und danach stundenlang
# nichts -- je nachdem, welche Karte der Worker bekam. Genau diese Form
# von Zufall ist das Teuerste, was ein System haben kann.
#
# Die Klasse "16 GB" schuetzt davor NICHT: was dort als 24-GB-Karte
# erscheint, kann eine MIG-Scheibe einer grossen Blackwell sein.
#
# Es waere moeglich gewesen, die Kartenliste am Endpunkt auf Ampere zu
# verengen. Das ist aber ein Rueckzug auf schrumpfende Hardware -- die
# Flotte wird jeden Monat neuer, nicht aelter. Ein Abbild, das die
# aktuellen Karten kennt, ist die Loesung; eine Kartenliste ist eine
# Vertagung.
#
# sm_120 gibt es ab torch 2.7 mit CUDA 12.8. Genommen wird 2.8.0: eine
# Fassung weiter als das Minimum, damit nicht die allererste
# Blackwell-Unterstuetzung getragen wird.
#
# ACHTUNG BEIM ENDPUNKT: cu128 verlangt einen Treiber >= 12.8. Die
# erlaubten CUDA-Fassungen dort muessen entsprechend auf 12.8 und
# neuer stehen -- sonst landet der Worker auf einem zu alten Rechner und
# der Fehler kehrt seitenverkehrt zurueck.
FROM pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    # HF-Cache an einen Ort, den auch der non-root-USER (s. unten) lesen
    # und schreiben darf. Vorgabe waere /root/.cache -- fuer appuser
    # unerreichbar, und der gebackene Modell-Cache laege dort.
    HF_HOME=/opt/hf \
    # MODELL-REVISION FESTNAGELN. Ohne feste Revision zieht
    # snapshot_download den jeweils neuesten Stand -- zusammen mit
    # trust_remote_code beim Laden fuehrt das fremden Code aus, wenn das
    # Repo uebernommen oder eine neue Revision eingestellt wird. Dies ist
    # der gepruefte main-Commit von ASLP-lab/SongFormer (Stand 2026-05-14);
    # der Build backt genau ihn, der Handler liest dieselbe ENV -- Abbild
    # und Laufzeit ziehen denselben unveraenderlichen Stand. Ein eigenes
    # MODELL_REPO braucht ein eigenes MODELL_REVISION (der SongFormer-Commit
    # existiert dort nicht, der Start bricht dann sichtbar ab).
    MODELL_REVISION=a75880ed1b7375ac71860ec6c4fc9c899cf99515 \
    # Der ungekuerzte HarmonixSet-Satz. Am 18.08.2026 an zwei EDM-Tracks
    # gemessen: gliedert sauberer als die 8-Klassen-Vorgabe (fasst das Intro
    # zusammen statt es zu zerhacken). EDM-Begriffe liefert er trotzdem nicht --
    # die Benennung passiert auf dem Lichtrechner.
    TAXONOMIE=SongForm-HX-Widen \
    # Leer = offizielles Modell. Fuer ein spaeter nachtrainiertes Modell hier
    # das eigene HuggingFace-Repo eintragen (dann auch MODELL_REVISION setzen).
    MODELL_REPO="" \
    # KEIN Vorgabewert fuer ORT_NAME, mit Absicht. Er muss die KENNUNG des
    # Rechenorts aus config/rechenorte.json tragen. Steht dort etwas
    # anderes, liefert `kann(ort, aufgabe)` einfach False und
    # /api/analyse/holen antwortet {"auftrag": null} -- ununterscheidbar
    # von "gerade nichts zu tun". Der Auftrag bliebe liegen, der Endpunkt
    # meldete Erfolg. start.sh bricht deshalb ab, wenn er leer ist.
    AUFGABE=songform

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libsndfile1 git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# NON-ROOT. Das Abbild lief als root; zusammen mit trust_remote_code beim
# Modell-Laden ist das mehr Recht als noetig -- ein uebernommenes Modell-Repo
# haette root im Container. Ein eigener Nutzer, dem der HF-Cache (/opt/hf,
# s. HF_HOME) und /app gehoeren. Angelegt VOR dem Backen der Gewichte, damit
# der Cache gleich richtig gehoert.
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /opt/hf \
    && chown -R appuser:appuser /opt/hf /app

# TORCH BLEIBT, WAS DAS BASIS-ABBILD MITBRINGT.
#
# Am 18.08.2026 im fertigen Abbild gemessen: torch 2.13.0+cu130, obwohl das
# Basis-Abbild "pytorch:2.4.0" heisst. Eines der Zusatzpakete zieht torch
# als Abhaengigkeit hoch, und pip nimmt dann die neueste Fassung. Damit
# steckte im Abbild NICHT die Kombination, die auf dem StudioPC erarbeitet
# wurde -- und genau daneben steht der Hinweis, dass torchvision aus
# demselben Index kommen muss wie torch.
#
# Die Sperrliste entsteht aus dem, was schon da ist. So steht die Nummer an
# keiner zweiten Stelle: wer das Basis-Abbild wechselt, wechselt sie mit.
RUN pip freeze | grep -E "^(torch|torchvision|torchaudio)==" > /tmp/sperrliste.txt \
    && cat /tmp/sperrliste.txt \
    && pip install --no-cache-dir -c /tmp/sperrliste.txt \
        "transformers==4.51.1" \
        huggingface_hub \
        librosa soundfile \
        omegaconf einops \
        ema_pytorch loguru \
        muq x_transformers \
        msaf \
        runpod

# Gewichte fest ins Abbild backen: SongFormer plus die Grundmodelle MuQ und
# MusicFM. Das sind die 30 Dateien, deren Download auf dem StudioPC vier
# Minuten gedauert hat -- die will niemand bei jedem Kaltstart erneut holen.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('ASLP-lab/SongFormer', repo_type='model', revision='${MODELL_REVISION}')" \
    && chown -R appuser:appuser /opt/hf

# KEIN TAILSCALE MEHR (25.08.2026). Der Tunnel war eine Konstruktion
# der RunPod-Nacht vom 18.08., damit der Abhol-Worker den Lichtrechner
# erreichen konnte. Seit dem Direkt-Transport traegt der Auftrag sein
# Audio selbst, und LAN-Worker (Betriebsart schleife) sprechen ohnehin
# direkt -- ein VPN-Client im Abbild war nur noch Gewicht und
# Angriffsflaeche.

COPY handler.py /app/handler.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Ab hier laeuft alles als non-root. handler.py und start.sh sind
# weltlesbar (COPY -> 644, chmod +x -> 755); geschrieben wird nur in
# /tmp (tempfile) und /opt/hf (dem Cache gehoert appuser).
USER appuser

# start.sh prueft im Abhol-Betrieb (serverless wie schleife) die
# Erreichbarkeit des Lichtrechners; nur "direkt" springt vorher heraus.
# Danach uebergibt es per exec an den Handler.
CMD ["/app/start.sh"]
