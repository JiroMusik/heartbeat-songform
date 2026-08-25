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
| `direkt` | **Der Produkt-Weg für die Cloud (25.08.2026):** das Audio steckt komprimiert in der Anfrage, das Ergebnis geht als Job-Antwort zurück. Der Container ruft niemanden an — keine Adresse, **kein Geheimnis in der Umgebung** |
| `serverless` (Vorgabe) | Abhol-Weg für geweckte Orte — historisch, die Klingel ruft heute keinen Cloud-Ort mehr |
| `schleife` | Der Ort **fragt selbst**, in Ruhe, immer wieder — für Maschinen im eigenen Netz, die ohnehin laufen (`scripts/worker-install.*` richtet genau das ein) |

Der Tailscale-Tunnel der ersten Fassung ist **vollständig entfallen**:
der Direkt-Weg braucht keinen Rückkanal, und LAN-Worker sprechen den
Lichtrechner ohnehin direkt an.

## Umgebungsvariablen

Im Abbild steht kein einziger Zugangswert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `BASIS_URL` | ja¹ | Adresse des Lichtrechners im eigenen Netz, z. B. `http://192.168.1.50:5555`. **Kein Vorgabewert** — fehlt sie, bricht der Start ab |
| `ORT_NAME` | ja | die **Kennung** des Orts aus den Rechenorten, nicht sein Anzeigename |
| `AUFGABE` | — | `songform` |
| `TAXONOMIE` | — | `SongForm-HX-Widen` |
| `MODELL_REPO` | — | leer = offizielles Modell |
| `BETRIEBSART` | — | `direkt`, `serverless` oder `schleife` |

¹ entfällt in der Betriebsart `direkt` — dort ruft der Container niemanden an.

## Start

`start.sh` läuft vor dem Handler: in der Betriebsart `direkt` übergibt es
sofort; im Abhol-Betrieb belegt es erst die **Erreichbarkeit** (ein Aufruf
von `/api/analyse/wav` ohne id antwortet `404 unbekannte id` und beansprucht
nichts — Verbindungsfehler heißt also „Adresse/Netz", 404 heißt „alles in
Ordnung") und meldet dabei die Grafikkarte der Maschine mit. Bricht die
Probe ab, startet der Handler gar nicht erst: ein Worker, der einen Auftrag
beansprucht und ihn dann nicht holen kann, blockiert ihn für die Dauer der
Reservierung.

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
