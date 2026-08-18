#!/usr/bin/env python3
"""Songform-Rechenort als RunPod-Serverless-Endpunkt.

Dieser Container ist ein Rechenort im Sinne der Anleitung: Er holt sich seinen
Auftrag selbst beim LXC, laedt das WAV, rechnet und liefert das Ergebnis
zurueck -- ueber dieselben Endpunkte wie jeder andere Rechenort. Der einzige
Unterschied: Er pollt nicht, sondern wird geweckt. Serverless skaliert auf
null; zwischen zwei Aufrufen existiert er nicht und koennte gar nicht fragen.

Erreichbar ist der LXC ueber den Tunnel (Tailscale). Es wird kein eingehender
Port am LXC geoeffnet -- der Container baut die Verbindung auf.

Eingabe:
    {"input": {}}                      -> holt den naechsten songform-Auftrag
    {"input": {"taxonomie": "..."}}    -> Etikettensatz ueberschreiben

Rueckgabe:
    {"auftrag": "<id>", "abschnitte": <n>, "sekunden": <rechenzeit>}
    {"auftrag": null}                  -> es lag nichts an; das ist der
                                          Normalfall und kein Fehler.
"""

import os
import sys
import tempfile
import time
import json
import urllib.error
import urllib.request

import runpod

BASIS_URL = os.environ.get("LXC_BASIS_URL", "http://lxc:5555")
ORT = os.environ.get("ORT_NAME", "cloud")
AUFGABE = os.environ.get("AUFGABE", "songform")
# Vorgabe des Modells ist SongForm-HX-8Class (8 Klassen). SongForm-HX-Widen
# oeffnet den ungekuerzten HarmonixSet-Satz mit build, breakdown, transition --
# fuer EDM aussagekraeftiger. Als Umgebungsvariable, damit die Entscheidung
# ohne neues Abbild revidierbar bleibt.
TAXONOMIE = os.environ.get("TAXONOMIE", "SongForm-HX-Widen")

# --- Eigenes Modell (deaktiviert) -------------------------------------------
# Vorbereitung fuer ein spaeter auf EDM nachtrainiertes Modell. Solange leer,
# laeuft das offizielle ASLP-lab/SongFormer. Ist die Variable gesetzt, wird
# stattdessen dieses HuggingFace-Repo geladen -- eine Konfigurationsaenderung
# am Endpunkt, kein neues Abbild und keine Codeaenderung.
# Siehe training/README.md: der teure Teil ist das Annotieren, nicht die
# Rechenzeit.
MODELL_REPO = os.environ.get("MODELL_REPO", "").strip() or "ASLP-lab/SongFormer"
TAXONOMIE_IDS = {
    "SongForm-HX-7Class": 0,
    "SongForm-HX-Widen": 1,   # ungekuerzter HarmonixSet-Satz, Vorgabe
    "SongForm-HX-8Class": 5,
    # "EDMFormer": 9,         # erst mit eigenem, nachtrainiertem Modell
}

# ZUTRITT. Der LXC prueft jede Anfrage aus dem Tailnet (100.64.0.0/10,
# fd7a:115c:a1e0::/48) auf diese Kopfzeile -- ohne sie antwortet er mit 403,
# und zwar auf ALLE vier Routen einschliesslich des WAV-Downloads. Der
# Studio-PC im Studio-Netz braucht sie nicht; dieser Container schon.
# Der Wert gehoert in die Geheimnisverwaltung des Endpunkts, nie ins Abbild.
ZUTRITT = os.environ.get("ZUTRITT_SCHLUESSEL", "").strip()

HTTP_TIMEOUT = 30
WAV_TIMEOUT = 300


def _kopfzeilen(extra=None):
    kopf = dict(extra or {})
    if ZUTRITT:
        kopf["X-Rechenort-Schluessel"] = ZUTRITT
    return kopf


# ---------------------------------------------------------------------------
# Modell einmalig laden -- bleibt zwischen Aufrufen warm, solange der Worker
# lebt. Das ist der Unterschied zwischen 3 und 30 Sekunden pro Titel.
# ---------------------------------------------------------------------------
def _vertraeglichkeit():
    """msaf (2019) erwartet scipy.inf; der Alias wurde in SciPy 1.12 entfernt.

    SongFormer importiert msaf nur fuer eine Auswertungsfunktion, die bei
    Inferenz nie laeuft -- der Import steht aber am Dateianfang und wuerde das
    Laden sonst verhindern. Wiederhergestellt wird nur der Name, nicht mehr.
    """
    import numpy as np
    import scipy
    for name in ("inf", "nan", "pi", "e"):
        if not hasattr(scipy, name):
            setattr(scipy, name, getattr(np, name))


_vertraeglichkeit()

import torch  # noqa: E402
from huggingface_hub import snapshot_download  # noqa: E402
from transformers import AutoModel  # noqa: E402

print(f"[start] lade Modell {MODELL_REPO}", flush=True)
_t0 = time.monotonic()
_LOKAL = snapshot_download(MODELL_REPO, repo_type="model")
sys.path.insert(0, _LOKAL)
os.environ["SONGFORMER_LOCAL_DIR"] = _LOKAL

MODELL = AutoModel.from_pretrained(_LOKAL, trust_remote_code=True)
GERAET = "cuda" if torch.cuda.is_available() else "cpu"
MODELL.to(GERAET)
MODELL.eval()
MODUL = sys.modules[type(MODELL).__module__]
print(f"[start] Modell auf {GERAET} in {time.monotonic() - _t0:.1f}s", flush=True)


def taxonomie_setzen(name):
    """Etikettensatz waehlen. Das Modell traegt alle Gewichte; die Auswahl
    blendet nur aus, welche Etiketten erlaubt sind."""
    if name not in TAXONOMIE_IDS:
        raise ValueError(f"unbekannte Taxonomie: {name}")
    MODUL.DATASET_LABEL = name
    MODUL.DATASET_IDS = [TAXONOMIE_IDS[name]]


# ---------------------------------------------------------------------------
# Protokoll v1 -- unveraendert, nur Standardbibliothek
# ---------------------------------------------------------------------------
# WIEDERHOLEN, WO ES SICH LOHNT.
#
# Am 18.08.2026 gemessen: der Container trat dem Tailnet bei, die
# Startprobe (GET) kam durch, und zwoelf Sekunden spaeter scheiterte der
# erste POST mit "502 Bad Gateway". Der 502 stammt vom Tailscale-
# Vermittler, nicht vom Lichtrechner -- die Verbindung war noch nicht
# belastbar. Ein einziger Fehlschlag riss damit den ganzen Auftrag ab.
#
# WIEDERHOLT WIRD NUR, WAS SICH WIEDERHOLEN LAESST: Verbindungsfehler und
# die 5xx-Antworten eines Vermittlers. Ein 403 (Schluessel falsch) oder
# ein 400 (Ergebnis abgelehnt) bleibt beim ersten Mal stehen -- die
# aendern sich beim zweiten Versuch nicht, und sie zu wiederholen
# verschleierte nur die Ursache.
_WIEDERHOLBAR = (502, 503, 504)
_VERSUCHE = 4
_PAUSEN_S = (2, 5, 12)


def _mit_wiederholung(was, tun):
    letzter = None
    for versuch in range(_VERSUCHE):
        try:
            return tun()
        except urllib.error.HTTPError as e:
            if e.code not in _WIEDERHOLBAR:
                raise
            letzter = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            letzter = e
        if versuch < len(_PAUSEN_S):
            pause = _PAUSEN_S[versuch]
            print(f"[netz] {was}: {type(letzter).__name__} {letzter} -- "
                  f"neuer Versuch in {pause}s "
                  f"({versuch + 2}/{_VERSUCHE})", flush=True)
            time.sleep(pause)
    raise letzter


def _post(pfad, nutzlast):
    daten = json.dumps(nutzlast).encode("utf-8")
    req = urllib.request.Request(
        f"{BASIS_URL}{pfad}", data=daten, method="POST",
        headers=_kopfzeilen({"Content-Type": "application/json"}))
    def einmal():
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))

    try:
        return _mit_wiederholung(f"POST {pfad}", einmal)
    except urllib.error.HTTPError as e:
        # DEN GRUND MITNEHMEN. Der Server begruendet jede Ablehnung im Rumpf
        # ("beats ist leer", "track passt nicht zur id"). Ohne dieses Lesen
        # stuende im Protokoll nur "HTTP Error 400: Bad Request", und man
        # suchte die Ursache im Falschen.
        rumpf = ""
        try:
            rumpf = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        print(f"[http] {pfad}: {e.code} {e.reason} -- {rumpf}", flush=True)
        raise


def auftrag_holen():
    return _post("/api/analyse/holen", {"ort": ORT, "aufgabe": AUFGABE}).get("auftrag")


def auftrag_zurueck(auftrag_id):
    try:
        _post("/api/analyse/zurueck", {"id": auftrag_id, "ort": ORT})
    except Exception as e:                                  # noqa: BLE001
        print(f"[warn] Rueckgabe fehlgeschlagen: {e}", flush=True)


def wav_laden(wav_pfad, ziel):
    return _mit_wiederholung(f"GET {wav_pfad}", lambda: _wav_einmal(wav_pfad, ziel))


def _wav_einmal(wav_pfad, ziel):
    with urllib.request.urlopen(
            urllib.request.Request(f"{BASIS_URL}{wav_pfad}", headers=_kopfzeilen()),
            timeout=WAV_TIMEOUT) as resp, \
            open(ziel, "wb") as fh:
        gesamt = 0
        while True:
            block = resp.read(1024 * 1024)
            if not block:
                break
            fh.write(block)
            gesamt += len(block)
    return gesamt


def handler(job):
    eingabe = job.get("input") or {}
    taxonomie_setzen(eingabe.get("taxonomie", TAXONOMIE))

    auftrag = auftrag_holen()
    if not auftrag:
        # Normalfall, kein Fehler: der Wecker kam, aber ein anderer Rechenort
        # war schneller oder der Auftrag ist zurueckgezogen worden.
        return {"auftrag": None}

    auftrag_id = auftrag["id"]
    fd, tmp = tempfile.mkstemp(prefix="songform_", suffix=".wav")
    os.close(fd)
    try:
        t0 = time.monotonic()
        groesse = wav_laden(auftrag["wav"], tmp)
        t_laden = time.monotonic() - t0

        t0 = time.monotonic()
        with torch.no_grad():
            roh = MODELL(tmp)
        t_rechnen = time.monotonic() - t0

        # Rohetiketten unveraendert weitergeben; auch das Verschmelzen
        # benachbarter gleicher Abschnitte passiert bewusst auf dem
        # Lichtrechner -- an einer Stelle statt an jedem Rechenort.
        sections = [{"start": round(float(s["start"]), 3),
                     "end": round(float(s["end"]), 3),
                     "label": s["label"]} for s in roh]

        # KEINE BEATS, UND DAS WIRD AUCH NICHT BEHAUPTET. SongFormers
        # forward() gibt eine schlichte Liste von {label, start, end}
        # zurueck (modeling_songformer.py: `return msa_json`) -- kein
        # Beat-Raster, kein Tempo. Hier stand `getattr(roh, "beats", None)`
        # auf genau dieser Liste: immer None, also beats=[] und ein
        # gemeldetes bpm von 0.0, als waere es gemessen worden.
        #
        # Die Arbeitsteilung ist ausdruecklich so gewollt (Niklas
        # 18.08.2026): "the on-the-beat gives beats, das neue system soll
        # die STRUKTUR zurueck geben". Deshalb traegt die Nutzlast die
        # Aufgabenart und laesst die Grid-Felder weg, statt sie zu fuellen.
        nutzlast = {
            "id": auftrag_id,
            "track": auftrag.get("track"),
            "dauer_s": auftrag.get("dauer_s"),
            "aufgabe": AUFGABE,
            "worker": f"{ORT}:songformer",
            "konfidenz": 0.7,   # SongFormer gibt kein eigenes Mass heraus
            "sections": sections,
        }
        antwort = _post("/api/analyse/ergebnis", nutzlast)
        if not antwort.get("ok"):
            print(f"[warn] Ergebnis abgelehnt: {antwort}", flush=True)

        print(f"[ok] {auftrag_id}: {groesse/1e6:.1f} MB in {t_laden:.1f}s, "
              f"Analyse {t_rechnen:.1f}s, {len(sections)} Abschnitte", flush=True)
        return {"auftrag": auftrag_id, "abschnitte": len(sections),
                "sekunden": round(t_rechnen, 1),
                "taxonomie": MODUL.DATASET_LABEL}
    except Exception as e:                                  # noqa: BLE001
        # Auftrag freigeben, damit ein anderer Rechenort ihn bekommt -- sonst
        # bliebe er bis zum Ablauf der Reservierung liegen.
        auftrag_zurueck(auftrag_id)
        print(f"[fehler] {auftrag_id}: {type(e).__name__}: {e}", flush=True)
        raise
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


runpod.serverless.start({"handler": handler})
