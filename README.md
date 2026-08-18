# SongFormer als Rechenort

Struktur-Analyse für Heartbeat DMX. Der Container holt sich Aufträge beim
Lichtrechner ab, lässt SongFormer über die WAV laufen und liefert die
**Gliederung** zurück — Abschnitte mit Etikett, Anfang und Ende.

**Keine Beats.** Die liefert ein Rechenort mit der Aufgabe `raster`.
SongFormers `forward()` gibt eine schlichte Liste `{label, start, end}` zurück
(`modeling_songformer.py`: `return msa_json`); ein Beat-Raster kennt es nicht
und behauptet hier auch keins.

Drei Ebenen, die man auseinanderhalten muss:

| | Beispiele | wo |
|---|---|---|
| **Ort** | Host, StudioPC, Cloud | `config/rechenorte.json` beim Lichtrechner |
| **Aufgabe** | `songform`, `raster` | ebenda, je Ort |
| **Methode** | SongFormer, beat_this, madmom | hier im Worker — nirgends konfiguriert |

Die Methode steht nicht in der Konfiguration: den Lichtrechner interessiert,
**was** zurückkommt, nicht **womit**. Festgehalten wird sie trotzdem — jedes
Ergebnis trägt das Feld `worker`, hier `<ort>:songformer`.

## Zwei Betriebsarten, ein Abbild

| `BETRIEBSART` | Verhalten |
|---|---|
| `serverless` (Vorgabe) | Der Ort wird **geweckt**. Serverless skaliert auf null; zwischen zwei Aufträgen existiert er nicht und könnte gar nicht fragen |
| `schleife` | Der Ort **fragt selbst**, in Ruhe, immer wieder — das Gerüst aus `docs/ANLEITUNG_ANALYSE_WORKER.md` §5. Für Maschinen, die ohnehin laufen |

Beides ist derselbe Weg zum Auftrag (`/api/analyse/holen`); der Unterschied
ist nur, wer den ersten Schritt tut.

## Umgebungsvariablen

Im Abbild steht kein einziger Zugangswert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `BASIS_URL` | ja | Adresse des Lichtrechners, z. B. `http://100.73.50.47:5555`. **Kein Vorgabewert** — fehlt sie, bricht der Start ab |
| `ORT_NAME` | ja | die **Kennung** des Orts aus `rechenorte.json`, nicht sein Anzeigename |
| `ZUTRITT_SCHLUESSEL` | ja¹ | als `X-Rechenort-Schluessel`; ohne ihn antwortet der Lichtrechner aus dem Tunnel auf **alle** Routen mit 403 |
| `TS_AUTHKEY` | ja¹ | Tailscale-Schlüssel, **reusable** und **ephemeral**. Ein einmaliger lässt genau einen Worker herein — jeder weitere bekommt „invalid key" |
| `AUFGABE` | — | `songform` |
| `TAXONOMIE` | — | `SongForm-HX-Widen` |
| `MODELL_REPO` | — | leer = offizielles Modell |
| `BETRIEBSART` | — | `serverless` oder `schleife` |

¹ nur, wenn der Ort über den Tunnel kommt. Eine Maschine im Studio-Netz
braucht beides nicht.

## Start

`start.sh` läuft vor dem Handler und tut drei Dinge in dieser Reihenfolge:

1. **Tailnet beitreten** — im Userspace-Modus, ohne `/dev/net/tun` und ohne
   `NET_ADMIN`. Das ist der von Tailscale für Serverless vorgesehene Modus
   (`TS_USERSPACE` ist dort die Vorgabe); Kernel-Modus verlangt beides.
2. **Erreichbarkeit belegen** — ein Aufruf von `/api/analyse/wav` ohne id.
   Der antwortet `404 unbekannte id` und beansprucht nichts. So sind die drei
   Fehlerarten unterscheidbar: Verbindungsfehler = kein Tunnel, 403 =
   Schlüssel falsch, 404 = alles in Ordnung.
3. **Übergeben** — `exec` auf den Handler.

Bricht Schritt 1 oder 2 ab, startet der Handler gar nicht erst: ein Worker,
der einen Auftrag beansprucht und ihn dann nicht holen kann, blockiert ihn für
die Dauer der Reservierung.

## Gemessen am 18.08.2026

| | |
|---|---|
| Abbildgröße | 17,8 GB |
| torch | 2.4.1+cu124, an das Basis-Abbild gebunden |
| Gewichte beim Start | 30 Dateien, 0,0 s — sie liegen im Abbild |
| Modell laden (CPU) | 37,6 s |
| Analyse (CPU, 304 s Audio) | 316 s = 0,96× Echtzeit |
| Erster vollständiger Durchlauf über RunPod | 20 Rohfenster, vom Lichtrechner zu 11 Abschnitten zusammengefasst |

## Was hier schon schiefging

- **Zwei Namen für die Adresse.** Der Handler las `LXC_BASIS_URL` mit einem
  erfundenen Vorgabewert, `start.sh` prüfte `BASIS_URL`. Der Vermittler konnte
  die erfundene Adresse nicht auflösen und meldete `502 Bad Gateway` —
  woraufhin über eine Stunde der Tunnel verdächtigt wurde, der einwandfrei
  lief. Heute: ein Name, kein Vorgabewert.
- **Ein Rechnername im Code.** Wo der Lichtrechner läuft, ist Konfiguration —
  heute ein Container, morgen ein Barebone. Ein Variablenname, der die heutige
  Hardware trägt, ist beim ersten Umzug eine Lüge.
- **`{"input": {}}` beim Testen.** RunPod verwirft ein leeres `input`, und der
  Worker stirbt an `Job has missing field(s): id or input`
  (`runpod-python/rp_job.py`). Testaufrufe brauchen einen nichtleeren Inhalt —
  die Klingel schickt ohnehin einen.
- **Jeder Build erzeugt eine neue Vorlage mit leerer Umgebung.** Nach einem
  Neubau müssen alle Variablen erneut gesetzt werden; das geht über
  `PATCH /templates/{id}` ohne weiteren Build.
