#!/usr/bin/env python3
"""Songform-Rechenort als RunPod-Serverless-Endpunkt.

Dieser Container ist ein Rechenort im Sinne der Anleitung: Er holt sich seinen
Auftrag selbst beim Lichtrechner, laedt das WAV, rechnet und liefert das Ergebnis
zurueck -- ueber dieselben Endpunkte wie jeder andere Rechenort.

ZWEI BETRIEBSARTEN, dasselbe Abbild (s. BETRIEBSART am Dateiende):

  serverless  Der Ort wird GEWECKT. Serverless skaliert auf null; zwischen
              zwei Aufrufen existiert er nicht und koennte gar nicht fragen.
              Deshalb klingelt der Lichtrechner, sobald ein Auftrag entsteht.
  schleife    Der Ort FRAGT SELBST, in Ruhe, immer wieder -- das Geruest aus
              docs/ANLEITUNG_ANALYSE_WORKER.md Paragraph 5. Fuer jede Maschine,
              die ohnehin laeuft: Studio-PC, Laptop, zweiter Server.

Beides ist derselbe Weg zum Auftrag (/api/analyse/holen); der Unterschied ist
nur, wer den ersten Schritt tut.

Erreichbar ist der Lichtrechner ueber den Tunnel (Tailscale). Es wird kein eingehender
Port am Lichtrechner geoeffnet -- der Container baut die Verbindung auf.

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

import netz
import runpod

# DIE ADRESSE DES LICHTRECHNERS -- ein Name, keine Erfindung, und kein
# Rechnername.
#
# Hier stand einmal ein zweiter Variablenname, der die Maschine benannte,
# auf der der Dienst gerade zufaellig laeuft. Das ist doppelt falsch:
#
#   1. Er stimmte nicht mit dem ueberein, den start.sh prueft. Gesetzt war
#      der eine, gelesen der andere, also griff ein Vorgabewert -- eine
#      erfundene Adresse. Der Vermittler konnte sie nicht aufloesen und
#      antwortete "502 Bad Gateway", woraufhin am 18.08.2026 eine Stunde
#      lang der Tunnel verdaechtigt wurde, der einwandfrei lief.
#   2. Er zementierte eine Kiste. Wo der Lichtrechner laeuft, ist
#      Konfiguration: heute ein Container im Studio, morgen ein Barebone,
#      uebermorgen beim Kunden. Ein Variablenname, der die heutige
#      Hardware traegt, ist beim ersten Umzug eine Luege.
#
# KEIN VORGABEWERT. Eine erfundene Adresse macht aus einer fehlenden
# Einstellung einen Netzwerkfehler, und den sucht man an der falschen
# Stelle. Fehlt sie, bricht der Start ab und sagt das auch.
#
# AUSSER in der Betriebsart "direkt": dort steckt das Audio in der
# Anfrage und das Ergebnis geht als Antwort zurueck -- der Container
# ruft NIEMANDEN an und braucht deshalb weder Adresse noch Tunnel noch
# Zutritt. Das ist die Produkt-Betriebsart (25.08.2026): ein Kunde
# soll einen Cloud-Worker bereitstellen koennen, ohne ein einziges
# Geheimnis in den Container zu legen.
_BETRIEBSART = os.environ.get("BETRIEBSART", "serverless").strip().lower()
BASIS_URL = (os.environ.get("BASIS_URL") or "").strip().rstrip("/")
if not BASIS_URL and _BETRIEBSART != "direkt":
    raise SystemExit(
        "[start] ABBRUCH: BASIS_URL ist nicht gesetzt. Sie muss auf den "
        "Lichtrechner zeigen, z. B. http://dmx-control:5555 -- der "
        "MagicDNS-Name, keine IP: Adressen wechseln, Namen bleiben")
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

# ZUTRITT. Der Lichtrechner prueft jede Anfrage aus dem Tailnet (100.64.0.0/10,
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

# ERST DEN WEG, DANN DAS MODELL. Ohne das laed der Container vierzig
# Sekunden lang Gewichte, um danach festzustellen, dass er niemanden
# erreicht.
print(f"[netz] Weg ins Tailnet: {netz.einrichten()}", flush=True)

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
# Hier stand, der 502 vom 18.08.2026 komme daher, dass eine frisch
# aufgebaute Tunnelverbindung "noch nicht belastbar" sei. Das war falsch,
# und der Irrtum hat Stunden gekostet: der Vermittler bekam eine
# unaufloesbare Adresse (s. BASIS_URL oben) und meldete pflichtgemaess
# 502. Der Tunnel war nie das Problem.
#
# Die Wiederholung bleibt trotzdem -- ein Rechenort haengt an einer
# Leitung, und eine Leitung zuckt. Sie ist nur keine Behandlung fuer
# einen Konfigurationsfehler mehr, sondern das, was sie sein soll.
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


def auftrag_zurueck(auftrag_id, grund=""):
    """Auftrag freigeben und sagen, WARUM.

    Ohne den Grund sieht der Lichtrechner einen Auftrag, der zurueckkam,
    und sonst nichts -- die Ursache stuende nur im Protokoll des
    Anbieters (docs/RECHENORT_BETRIEB.md, Punkt 5).
    """
    try:
        _post("/api/analyse/zurueck",
              {"id": auftrag_id, "ort": ORT, "grund": str(grund)[:200]})
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


# WIE VIELE AUFTRAEGE EIN WECKRUF HOLT.
#
# Der teure Teil ist der Kaltstart, nicht die Analyse: Abbild ziehen,
# Tailnet beitreten, Modell laden. Ein warmer Ort, der nach dem ersten
# Auftrag stehen bleibt, waehrend zwei weitere liegen, verschenkt genau
# das, was gerade bezahlt wurde. Am 18.08.2026 lagen drei Auftraege in
# der Schlange, und es brauchte drei Weckrufe -- zwei davon gingen
# verloren.
#
# Also: holen, bis nichts mehr kommt. Das ist auch die Bauform des
# Protokolls ("holen statt zuteilen", docs/ANLEITUNG_ANALYSE_WORKER.md):
# wer da ist und kann, nimmt.
#
# ZWEI GRENZEN, damit daraus kein Dauerlauf wird:
#   - die Warteschlange gibt nichts mehr her
#   - die Laufzeit naeht sich der Ausfuehrungsgrenze des Endpunkts
# Die zweite kennt der Container nicht von selbst; sie steht in der
# Umgebung, weil sie eine Einstellung des Endpunkts ist und keine
# Eigenschaft dieses Codes.
LAUFZEIT_GRENZE_S = float(os.environ.get("LAUFZEIT_GRENZE_S", "480") or 480)


def _direkt(eingabe):
    """Betriebsart "direkt": das Audio steckt in der Anfrage, das
    Ergebnis geht als Antwort zurueck.

    Kein Tunnel, kein Rueckkanal, kein Geheimnis im Container -- der
    Lichtrechner schickt den Titel komprimiert mit (Vorbis/Opus, mono)
    und nimmt die Gliederung aus dem Job-Ergebnis. Die Nutzlast-Deckel
    des Anbieters (10 MB /run, 20 MB /runsync) prueft der ABSENDER vor
    dem Senden; hier wird nur gerechnet.

    Fehler kommen als {"fehler": "..."} zurueck, nie als Absturz: ein
    geplatzter Job saehe von aussen aus wie eine kaputte Karte, und
    dessen Protokoll ist nur in der Konsole des Anbieters lesbar.
    """
    import base64
    import subprocess

    kennung = eingabe.get("id") or "?"
    form = str(eingabe.get("format") or "ogg").strip().lstrip(".").lower()
    if not eingabe.get("audio_b64"):
        return {"fehler": "audio_b64 fehlt in der Anfrage"}
    try:
        roh = base64.b64decode(eingabe["audio_b64"], validate=True)
    except Exception as e:                                  # noqa: BLE001
        return {"fehler": f"audio_b64 nicht dekodierbar: {e}"}

    fd, quelle = tempfile.mkstemp(prefix="songform_", suffix="." + form)
    os.close(fd)
    fd, wav = tempfile.mkstemp(prefix="songform_", suffix=".wav")
    os.close(fd)
    try:
        with open(quelle, "wb") as fh:
            fh.write(roh)
        # ffmpeg statt eines Python-Dekoders: es liest jedes Format, das
        # ein Absender sinnvoll waehlen kann, und liegt ohnehin im Abbild.
        lauf = subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-i", quelle, "-ac", "1", "-ar", "44100", wav],
            capture_output=True, text=True, timeout=180)
        if lauf.returncode != 0:
            return {"fehler": "ffmpeg: " + (lauf.stderr or "?")[-300:]}

        t0 = time.monotonic()
        with torch.no_grad():
            roh_abschnitte = MODELL(wav)
        sekunden = time.monotonic() - t0
        sections = [{"start": round(float(s["start"]), 3),
                     "end": round(float(s["end"]), 3),
                     "label": s["label"]} for s in roh_abschnitte]
        print(f"[ok] {kennung}: {len(roh)/1e6:.1f} MB Paket, Analyse "
              f"{sekunden:.1f}s, {len(sections)} Abschnitte", flush=True)
        # Die Nutzlast ist bereits das, was /api/analyse/ergebnis auf dem
        # Lichtrechner erwartet -- der Absender reicht sie unveraendert
        # an analyse_queue.ergebnis_annehmen weiter.
        return {
            "id": eingabe.get("id"),
            "track": eingabe.get("track"),
            "dauer_s": eingabe.get("dauer_s"),
            "aufgabe": AUFGABE,
            "worker": f"{ORT}:songformer",
            "konfidenz": 0.7,   # SongFormer gibt kein eigenes Mass heraus
            "sections": sections,
            "sekunden": round(sekunden, 1),
            "taxonomie": MODUL.DATASET_LABEL,
        }
    except Exception as e:                                  # noqa: BLE001
        return {"fehler": f"{type(e).__name__}: {e}"}
    finally:
        for pfad in (quelle, wav):
            try:
                os.unlink(pfad)
            except OSError:
                pass


def handler(job):
    eingabe = job.get("input") or {}
    taxonomie_setzen(eingabe.get("taxonomie", TAXONOMIE))

    # SELBSTBESCHREIBENDE EINGABE: traegt sie Audio, ist sie ein
    # Direkt-Auftrag -- unabhaengig von der Betriebsart. So kann ein
    # Endpoint, der noch als Weck-Ort konfiguriert ist, trotzdem schon
    # Direkt-Auftraege annehmen (und umgekehrt bleibt nichts liegen).
    if eingabe.get("audio_b64"):
        return _direkt(eingabe)
    if not BASIS_URL:
        # Direkt-Container ohne Audio in der Anfrage: hier gibt es
        # nichts zu holen, und niemanden, bei dem man holen koennte.
        return {"fehler": "Anfrage ohne audio_b64, und der Container "
                          "kennt keinen Lichtrechner (BETRIEBSART direkt)"}

    t_start = time.monotonic()
    erledigt, letzte_dauer = [], 0.0
    while True:
        rest = LAUFZEIT_GRENZE_S - (time.monotonic() - t_start)
        # Nicht anfangen, was nicht mehr fertig wird: ein abgeschnittener
        # Auftrag kostet die Reservierungsfrist, in der ihn niemand
        # anfassen kann.
        if erledigt and rest < letzte_dauer * 1.3:
            print(f"[schluss] noch {rest:.0f}s Laufzeit -- das reicht fuer "
                  f"keinen weiteren Auftrag", flush=True)
            break
        ergebnis = _einen_auftrag()
        if not ergebnis:
            break
        erledigt.append(ergebnis)
        letzte_dauer = ergebnis.get("sekunden") or letzte_dauer

    if not erledigt:
        # Normalfall, kein Fehler: der Wecker kam, aber ein anderer
        # Rechenort war schneller oder der Auftrag ist zurueckgezogen.
        return {"auftrag": None}
    return {"auftrag": erledigt[0]["auftrag"], "erledigt": len(erledigt),
            "auftraege": erledigt}


def _einen_auftrag():
    """Einen Auftrag holen und abarbeiten. None, wenn keiner anliegt."""
    auftrag = auftrag_holen()
    if not auftrag:
        return None

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
        auftrag_zurueck(auftrag_id, f"{type(e).__name__}: {e}")
        print(f"[fehler] {auftrag_id}: {type(e).__name__}: {e}", flush=True)
        raise
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ZWEI BETRIEBSARTEN, EIN ABBILD.
#
# Serverless heisst: jemand weckt uns, wir arbeiten einen Auftrag ab und
# verschwinden wieder. Das passt zu RunPod und zu nichts sonst.
#
# Ein Rechenort im eigenen Netz -- der Studio-PC, ein Laptop, irgendeine
# Maschine mit Grafikkarte -- soll dagegen von SICH AUS fragen. Genau das
# ist das Modell des Systems: "der Lichtrechner gibt die Datei an irgendeinen
# Worker, und wer die Rolle kann, nimmt den Auftrag". Ohne diese
# Betriebsart kann das Abbild das nicht, obwohl der ganze Rest
# identisch ist.
#
# Umgeschaltet wird ueber BETRIEBSART, nicht ueber ein zweites Abbild:
# zwei Abbilder waeren zwei Staende, und einer davon waere irgendwann
# der aeltere. (_BETRIEBSART selbst steht oben bei BASIS_URL -- die
# Adress-Pflicht haengt daran.)
_PAUSE_S = float(os.environ.get("SCHLEIFE_PAUSE_S", "20") or 20)


def schleife():
    """Holen, rechnen, abliefern -- bis jemand abbricht.

    Ist nichts zu tun, wird gewartet statt gefragt: die Warteschlange
    laeuft nicht weg, und ein Worker, der im Sekundentakt anklopft,
    kostet nur Strom.
    """
    print(f"[schleife] Rechenort {ORT} fragt alle {_PAUSE_S:.0f}s nach "
          f"Aufgabe '{AUFGABE}'", flush=True)
    leer = 0
    while True:
        try:
            ergebnis = handler({"input": {}})
        except Exception as e:                              # noqa: BLE001
            # NICHT STERBEN. Ein Netzfehler oder ein kaputter Auftrag
            # darf einen Dauerlaeufer nicht beenden -- der Auftrag bleibt
            # ohnehin in der Warteschlange stehen.
            print(f"[schleife] Fehler: {type(e).__name__}: {e}", flush=True)
            time.sleep(_PAUSE_S)
            continue
        if (ergebnis or {}).get("auftrag"):
            leer = 0
            continue          # gleich weiter, es koennte mehr anliegen
        leer += 1
        if leer == 1:
            print("[schleife] nichts zu tun -- warte", flush=True)
        time.sleep(_PAUSE_S)


if _BETRIEBSART == "schleife":
    schleife()
else:
    runpod.serverless.start({"handler": handler})
