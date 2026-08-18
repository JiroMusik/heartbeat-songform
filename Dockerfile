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

RUN pip install --no-cache-dir \
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

COPY handler.py /app/handler.py

CMD ["python", "-u", "/app/handler.py"]
