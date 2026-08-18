# SongFormer als RunPod-Serverless-Endpunkt

Struktur-Analyse für Heartbeat DMX. Der Container holt sich Aufträge beim
Lichtrechner ab, lässt SongFormer über die WAV laufen und liefert die
**Gliederung** zurück — Abschnitte mit Etikett, Anfang und Ende.

**Keine Beats.** Die liefert der andere Worker (`beat-this`). SongFormers
`forward()` gibt eine schlichte Liste `{label, start, end}` zurück
(`modeling_songformer.py`: `return msa_json`); ein Beat-Raster kennt es nicht
und behauptet hier auch keins. Der Lichtrechner nimmt seit dem 18.08.2026
beide Ergebnisarten getrennt an und unterscheidet sie am Vorhandensein von
`beats` — wer das Feld mitschickt, meint ein Raster und wird auch so geprüft.

## Umgebungsvariablen

Alles, was der Container über seine Umgebung wissen muss, kommt von außen —
im Abbild steht kein einziger Zugangswert.

| Variable | Bedeutung |
|---|---|
| `BASIS_URL` | Adresse des Lichtrechners im Tunnel, z. B. `http://100.x.y.z:5555` |
| `ZUTRITT_SCHLUESSEL` | wird als `X-Rechenort-Schluessel` mitgeschickt; ohne ihn antwortet der Lichtrechner auf **alle** vier Routen mit 403 |
| `ORT_NAME` | die **Kennung** des Rechenorts, wie sie in `config/rechenorte.json` steht — nicht sein Anzeigename |
| `AUFGABE` | `songform` |
| `TAXONOMIE` | `SongForm-HX-Widen` (gliedert an EDM sauberer als die 8-Klassen-Vorgabe) |
| `MODELL_REPO` | leer = offizielles Modell |

`ZUTRITT_SCHLUESSEL` gehört in die Geheimnisverwaltung des Endpunkts, nie in
dieses Repo und nie ins Abbild.

Kennung und Anzeigename auseinanderzuhalten ist kein Detail: am 18.08.2026
hieß der Ort intern `runpod` und wurde als „cloud" angezeigt. Ein Container
mit `ORT_NAME=cloud` hätte unter einem Namen gefragt, den `rechenorte` nicht
kennt — `kann()` liefert dann `False`, ohne Fehlermeldung, und der Endpunkt
bekäme schlicht nie Arbeit.

## Protokoll

Vier Routen, alle mit der Zutritts-Kopfzeile:
`/api/analyse/holen` · `/api/analyse/wav` · `/api/analyse/ergebnis` ·
`/api/analyse/zurueck`

Der Endpunkt wird **geweckt**, nicht gepollt: entsteht ein Auftrag, klingelt
der Lichtrechner einmal. Fällt die Klingel aus, geht nichts verloren — der
Auftrag bleibt liegen, die Reservierung verfällt, der nächste freie Ort
nimmt ihn.
