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

FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    # Der ungekuerzte HarmonixSet-Satz. Am 18.08.2026 an zwei EDM-Tracks
    # gemessen: gliedert sauberer als die 8-Klassen-Vorgabe (fasst das Intro
    # zusammen statt es zu zerhacken). EDM-Begriffe liefert er trotzdem nicht --
    # die Benennung passiert auf dem Lichtrechner.
    TAXONOMIE=SongForm-HX-Widen \
    # Leer = offizielles Modell. Fuer ein spaeter nachtrainiertes Modell hier
    # das eigene HuggingFace-Repo eintragen, siehe training/README.md.
    MODELL_REPO="" \
    ORT_NAME=cloud \
    AUFGABE=songform

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg libsndfile1 git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

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
    snapshot_download('ASLP-lab/SongFormer', repo_type='model')"

# TAILSCALE. Der Lichtrechner ist nur im Tailnet erreichbar -- ohne diesen
# Client kaeme der Container gar nicht an die Warteschlange. Das offizielle
# Depot statt eines Installationsskripts aus dem Netz: signierte Pakete,
# nachvollziehbare Fassung.
#
# Am 18.08.2026 fehlte das hier, und der erste RunPod-Build war deshalb
# wertlos -- ein Container, der rechnen kann, aber niemanden erreicht.
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list \
        > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/* \
    && tailscale version

COPY handler.py /app/handler.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# start.sh tritt dem Tailnet bei, belegt die Erreichbarkeit und uebergibt
# dann per exec an den Handler. Der Handler selbst weiss von Tailscale
# nichts -- er spricht HTTP, und die Vermittlung steht in der Umgebung.
CMD ["/app/start.sh"]
