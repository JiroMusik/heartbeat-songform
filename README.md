# SongFormer als RunPod-Serverless-Endpunkt

Struktur-Analyse für Heartbeat DMX. Der Container tritt beim Start dem Tailnet
bei, holt sich Aufträge beim Lichtrechner ab, lässt SongFormer über die WAV
laufen und liefert die **Gliederung** zurück — Abschnitte mit Etikett, Anfang
und Ende.

**Keine Beats.** Die liefert der andere Worker (`beat-this`). SongFormers
`forward()` gibt eine schlichte Liste `{label, start, end}` zurück
(`modeling_songformer.py`: `return msa_json`); ein Beat-Raster kennt es nicht
und behauptet hier auch keins. Der Lichtrechner nimmt seit dem 18.08.2026
beide Ergebnisarten getrennt an und unterscheidet sie am Vorhandensein von
`beats` — wer das Feld mitschickt, meint ein Raster und wird auch so geprüft.

## Umgebungsvariablen

Alles, was der Container über seine Umgebung wissen muss, kommt von außen —
im Abbild steht kein einziger Zugangswert.

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `BASIS_URL` | ja | Tailnet-Adresse des Lichtrechners, z. B. `http://100.73.50.47:5555`. Fehlt sie, bricht der Start ab, statt später beim ersten Auftrag zu scheitern |
| `TS_AUTHKEY` | ja | Tailscale-Auth-Key, **ephemeral** und **reusable**. Ephemeral, weil ein Serverless-Worker verschwindet — sonst füllt sich die Tailscale-Konsole mit toten Maschinen |
| `ZUTRITT_SCHLUESSEL` | ja | wird als `X-Rechenort-Schluessel` mitgeschickt; ohne ihn antwortet der Lichtrechner auf **alle** vier Routen mit 403 |
| `ORT_NAME` | ja | die **Kennung** des Rechenorts aus `config/rechenorte.json` — nicht sein Anzeigename |
| `AUFGABE` | — | `songform` (Vorgabe) |
| `TAXONOMIE` | — | `SongForm-HX-Widen` (gliedert an EDM sauberer als die 8-Klassen-Vorgabe) |
| `MODELL_REPO` | — | leer = offizielles Modell |

`TS_AUTHKEY` und `ZUTRITT_SCHLUESSEL` gehören in die Geheimnisverwaltung des
Endpunkts, nie in dieses Repo und nie ins Abbild.

Kennung und Anzeigename auseinanderzuhalten ist kein Detail: am 18.08.2026
hieß der Ort intern `runpod` und wurde als „cloud" angezeigt. Ein Container
mit `ORT_NAME=cloud` hätte unter einem Namen gefragt, den `rechenorte` nicht
kennt — `kann()` liefert dann `False`, ohne Fehlermeldung, und der Endpunkt
bekäme schlicht nie Arbeit.

## Start

`start.sh` läuft vor dem Handler und tut drei Dinge in dieser Reihenfolge:

1. **Tailnet beitreten** — im Userspace-Modus, ohne `/dev/net/tun` und ohne
   `NET_ADMIN`. Ein RunPod-Worker bekommt das Gerät nicht zugesichert.
2. **Erreichbarkeit belegen** — ein Aufruf von `/api/analyse/wav` ohne id.
   Der antwortet mit `404 unbekannte id` und beansprucht nichts. So sind die
   drei Fehlerarten unterscheidbar, die man sonst alle als „geht nicht"
   erlebt: Verbindungsfehler = kein Tunnel, 403 = Schlüssel falsch,
   404 = alles in Ordnung.
3. **Übergeben** — `exec` auf den Handler. Der weiß von Tailscale nichts; er
   spricht HTTP, und die Vermittlung steht in `http_proxy`.

Bricht Schritt 1 oder 2 ab, startet der Handler gar nicht erst — ein Worker,
der einen Auftrag beansprucht und ihn dann nicht holen kann, blockiert ihn
für die Dauer der Reservierung.

## Protokoll

Vier Routen, alle mit der Zutritts-Kopfzeile:
`/api/analyse/holen` · `/api/analyse/wav` · `/api/analyse/ergebnis` ·
`/api/analyse/zurueck`

Der Endpunkt wird **geweckt**, nicht gepollt: entsteht ein Auftrag, klingelt
der Lichtrechner einmal. Fällt die Klingel aus, geht nichts verloren — der
Auftrag bleibt liegen, die Reservierung verfällt, der nächste freie Ort
nimmt ihn.

## Gemessen am 18.08.2026

| | |
|---|---|
| Abbildgröße | 17,8 GB |
| torch | 2.4.1+cu124, an das Basis-Abbild gebunden |
| Gewichte beim Start | 30 Dateien, 0,0 s — sie liegen im Abbild |
| Modell laden (CPU) | 37,6 s |
