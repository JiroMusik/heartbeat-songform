"""Der Weg ins Tailnet, an einer Stelle.

WARUM ES DIESE DATEI GIBT.

Im Userspace-Modus hat `tailscaled` keinen Netzwerk-Stack im Kernel; aller
Verkehr laeuft ueber einen lokalen Vermittler. Tailscale stellt zwei
bereit, und die Doku (kb/1112, "Userspace networking mode") ist deutlich
darin, welcher der allgemeine ist:

    SOCKS5 ist "a more general and flexible proxy that can work with any
    traffic", der HTTP-Vermittler "only proxies HTTP and HTTPS traffic".

Am 18.08.2026 lief hier nur der HTTP-Vermittler. Ergebnis, gemessen: die
Startprobe (GET) kam beim Lichtrechner an, der erste POST scheiterte
viermal hintereinander mit "502 Bad Gateway" -- im Protokoll des
Lichtrechners stand der GET und kein einziger POST. Die Anfrage starb im
Vermittler, nicht am Ziel.

Die Doku empfiehlt fuer Serverless ausdruecklich, der Anwendung BEIDE
Wege zu geben (`ALL_PROXY` und `HTTP_PROXY`). Python liest `ALL_PROXY`
aber nicht von selbst: `urllib` kennt nur `http_proxy`/`https_proxy` und
spricht kein SOCKS. Deshalb wird hier PySocks als Standard-Socket
eingesetzt -- danach geht JEDE Verbindung durch das Tailnet, ohne dass
eine einzige Zeile im Handler davon wissen muss.
"""
import os


def einrichten():
    """SOCKS5 als Standardweg setzen, wenn ALL_PROXY danach aussieht.

    Rueckgabe: eine kurze Beschreibung des gewaehlten Weges, fuer das
    Protokoll. Ohne ALL_PROXY passiert nichts -- dann laeuft der
    Container entweder mit echtem TUN oder gar nicht im Tailnet, und
    beides ist ohne Zutun richtig.
    """
    ziel = (os.environ.get("ALL_PROXY") or "").strip()
    if not ziel.startswith("socks5"):
        return "direkt" if not ziel else "unbekannter ALL_PROXY: %s" % ziel

    # socks5h:// = Namensaufloesung auf der Gegenseite. Wir sprechen
    # ohnehin IP-Adressen, aber der Unterschied gehoert erkannt.
    ohne = ziel.split("://", 1)[1].rstrip("/")
    wirt, _, port = ohne.partition(":")

    try:
        import socket

        import socks                                    # PySocks
    except ImportError as e:
        raise SystemExit(
            "[netz] ABBRUCH: ALL_PROXY ist gesetzt (%s), aber PySocks fehlt "
            "im Abbild -- ohne das spricht Python kein SOCKS und der "
            "Verkehr ginge am Tailnet vorbei. (%s)" % (ziel, e))

    socks.set_default_proxy(socks.SOCKS5, wirt, int(port or 1080))
    # ALLE Sockets, nicht nur neue Sitzungen: urllib legt sie selbst an.
    socket.socket = socks.socksocket

    # UND DEN HTTP-VERMITTLER AUSDRUECKLICH ABSCHALTEN. Beide gleichzeitig
    # hiesse: urllib schickt die Anfrage an den HTTP-Vermittler, und der
    # Socket dorthin laeuft schon durch SOCKS. Genau ein Weg, nicht
    # anderthalb.
    for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        os.environ.pop(name, None)

    return "SOCKS5 ueber %s:%s" % (wirt, port or 1080)
