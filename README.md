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

## Drei Betriebsarten, ein Abbild

| `BETRIEBSART` | Verhalten |
|---|---|
| `direkt` | **Der Produkt-Weg für die Cloud (25.08.2026):** das Audio steckt komprimiert in der Anfrage, das Ergebnis geht als Job-Antwort zurück. Der Container ruft niemanden an — keine Adresse, **kein Geheimnis in der Umgebung** |
| `serverless` (Vorgabe) | Abhol-Weg für geweckte Orte — historisch, die Klingel ruft heute keinen Cloud-Ort mehr |
| `schleife` | Der Ort **fragt selbst**, in Ruhe, immer wieder — für Maschinen im eigenen Netz, die ohnehin laufen (`scripts/worker-install.*` richtet genau das ein) |

Der Tailscale-Tunnel der ersten Fassung ist **vollständig entfallen**:
der Direkt-Weg braucht keinen Rückkanal, und LAN-Worker sprechen den
Lichtrechner ohnehin direkt an.

## Was das Haus verlässt (Datenschutz)

Mit einem **aktiven Cloud-Rechenort** (RunPod, Betriebsart `direkt`) schickt
der Lichtrechner das Audio des laufenden Titels — als **Vorbis/Opus mono**,
komprimiert — zusammen mit **Titel und Kennung** an RunPod und bekommt die
**Gliederung** zurück. RunPod hält Ein- und Ausgabe eines Auftrags in seiner
Konsole vor; das ist bei einem Serverless-Anbieter nicht vermeidbar.

**Nicht** übertragen werden: andere Titel, sonstige Studio-Daten, und — in
`direkt` — kein einziger Zugangswert (der Container trägt keinen). Wer das
nicht will, lässt den Cloud-Rechenort inaktiv; die Analyse läuft dann lokal
oder auf dem Studio-PC (Betriebsart `schleife`), und das Audio bleibt im
eigenen Netz.

## Umgebungsvariablen

Im Abbild steht kein einziger Zugangswert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `BASIS_URL` | ja¹ | Adresse des Lichtrechners im eigenen Netz, z. B. `http://192.168.1.50:5555`. **Kein Vorgabewert** — fehlt sie, bricht der Start ab |
| `ORT_NAME` | ja | die **Kennung** des Orts aus den Rechenorten, nicht sein Anzeigename |
| `AUFGABE` | — | `songform` |
| `TAXONOMIE` | — | `SongForm-HX-Widen` |
| `MODELL_REPO` | — | leer = offizielles Modell |
| `MODELL_REVISION` | — | fester Commit des Modell-Repos; Default: der im Abbild gebackene SongFormer-Stand |
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

## Bauen und Ausrollen

**Bauen** übernimmt GitHub Actions: jeder Push nach `master` (außer reinen
Änderungen an `scripts/**` oder `README.md`) und jedes Release baut das
Abbild und schiebt es nach `ghcr.io/jiromusik/heartbeat-songform` — getaggt
mit dem kurzen Commit-Hash (unveränderlich, den zieht der Endpoint), auf
`master` zusätzlich `latest` (`.github/workflows/abbild.yml`). Ein
RunPod-Secret braucht der Bau **nicht**, nur das automatische `GITHUB_TOKEN`.

**Ausrollen** macht der Lichtrechner selbst: er trägt den RunPod-Schlüssel
ohnehin und stößt über den Knopf **„Abbild aktualisieren"** in der
Rechenorte-Karte einen Versions-Bump der Endpoint-Vorlage an
(`cloud_worker.ausrollen`) — der nächste Kaltstart zieht das neue Abbild.
Der Weg von Hand (`PATCH /templates/{id}`) bleibt als Rückfall.

## Gemessen am 18.08.2026

| | |
|---|---|
| Abbildgröße | 17,8 GB |
| torch | 2.8.0+cu128 (Basis-Abbild `pytorch/pytorch:2.8.0-cuda12.8`, seit 19.08. — Blackwell/`sm_120`) |
| Gewichte beim Start | 30 Dateien, 0,0 s — sie liegen im Abbild |
| Modell laden (CPU) | 37,6 s |
| Analyse (CPU, 304 s Audio) | 316 s = 0,96× Echtzeit |
| Erster vollständiger Durchlauf über RunPod | 20 Rohfenster, vom Lichtrechner zu 11 Abschnitten zusammengefasst |

> **Achtung:** Abbildgröße und Zeiten oben stammen vom torch-2.4-Bau
> (18.08.); seit dem Wechsel auf torch 2.8 / CUDA 12.8 (Blackwell,
> `Dockerfile`) sind sie nicht neu gemessen. Nur die torch-Zeile ist der
> aktuelle Stand.

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
  Neubau müssen alle Variablen erneut gesetzt werden; das erledigt der Knopf
  „Abbild aktualisieren" (s. „Bauen und Ausrollen"), notfalls
  `PATCH /templates/{id}` von Hand.
