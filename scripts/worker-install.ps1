# Heartbeat-DMX Netzwerk-Worker — Installation (Windows, Docker Desktop).
#
# Ein Befehl, ein Worker: zieht das Abbild und startet es in der
# Betriebsart "schleife" — der Worker FRAGT den Lichtrechner selbst
# nach Arbeit (kein Tunnel, kein Schluessel im eigenen Netz) und
# startet nach jedem Boot von allein wieder (--restart unless-stopped).
#
#   .\worker-install.ps1 -BasisUrl http://<lichtrechner>:5555 -OrtName studio-pc [-Aufgabe songform]
#
# Danach im Admin unter Rechenorte: den Ort anlegen (falls noch nicht
# da) und die Aufgabe ankreuzen — ohne Haekchen bekommt der Worker
# nichts, mit Absicht (ein Tippfehler soll keine Arbeit ziehen).
#
# GPU: Docker Desktop mit WSL2 reicht NVIDIA-Karten durch; ohne Karte
# rechnet der Worker auf der CPU (funktioniert, dauert ein Vielfaches).
param(
    [Parameter(Mandatory = $true)][string]$BasisUrl,
    [Parameter(Mandatory = $true)][string]$OrtName,
    [string]$Aufgabe = "songform"
)
$ErrorActionPreference = "Stop"
$Abbild = "ghcr.io/jiromusik/heartbeat-songform:latest"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker fehlt - https://docs.docker.com/get-docker/"
}

# GPU nur anfordern, wenn nvidia-smi antwortet: ein --gpus all ohne
# NVIDIA-Laufzeit laesst den Start scheitern, und ein CPU-Worker ist
# besser als gar keiner.
$Gpu = @()
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $Gpu = @("--gpus", "all")
    Write-Host "NVIDIA-Karte gefunden - Worker rechnet auf der GPU."
} else {
    Write-Host "Keine NVIDIA-Karte gefunden - Worker rechnet auf der CPU (langsam)."
}

$Name = "heartbeat-worker-$OrtName"

Write-Host "Ziehe $Abbild ..."
# KEIN "2>$null" an einem nativen Aufruf: unter PowerShell 5.1 macht die
# stderr-Umleitung zusammen mit $ErrorActionPreference="Stop" aus jeder
# Fehlerzeile einen abbrechenden NativeCommandError -- das Skript stuerbe
# genau hier, noch vor "docker run". Umgekehrt loest der Exit-Code eines
# nativen Programms "Stop" NICHT aus; deshalb pruefen wir $LASTEXITCODE
# von Hand, sonst meldet ein fehlgeschlagener Pull faelschlich Erfolg.
docker pull $Abbild
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FEHLER: 'docker pull' ist fehlgeschlagen (Code $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "Kein Netz, GHCR-Paket privat oder Tag entfernt? Der Worker wurde NICHT gestartet."
    exit 1
}

# Alten Container entfernen -- aber nur, wenn es ihn gibt. So schreibt
# "docker rm" bei der Erst-Installation kein "No such container" nach
# stderr (dasselbe, was die sh-Fassung mit "|| true" abfaengt). Exakter
# Namensvergleich in PowerShell statt eines Regex-Filters.
$Vorhanden = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Name }
if ($Vorhanden) {
    docker rm -f $Name | Out-Null
}

# STARTEN -- erst mit GPU (falls erkannt), und wenn GENAU das scheitert,
# ohne. Ein "--gpus all" verlangt das nvidia-container-toolkit, nicht nur
# den Treiber (nvidia-smi); fehlt das Toolkit, scheitert der GPU-Start mit
# "could not select device driver". Dann ist ein CPU-Worker besser als gar
# keiner -- genau das, was der Hinweis oben verspricht.
function StarteWorker($GpuArgs) {
    docker run -d --name $Name --restart unless-stopped @GpuArgs `
        -e BETRIEBSART=schleife `
        -e BASIS_URL=$BasisUrl `
        -e ORT_NAME=$OrtName `
        -e AUFGABE=$Aufgabe `
        $Abbild
}

StarteWorker $Gpu
if ($LASTEXITCODE -ne 0 -and $Gpu.Count -gt 0) {
    Write-Host ""
    Write-Host "GPU-Start fehlgeschlagen -- fehlt das nvidia-container-toolkit?" -ForegroundColor Yellow
    Write-Host "Zweiter Versuch ohne GPU (CPU, langsam)."
    # Ein gescheiterter GPU-Start kann einen Container im Zustand "created"
    # hinterlassen; sonst scheitert der zweite Lauf am belegten Namen.
    if (docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $Name }) {
        docker rm -f $Name | Out-Null
    }
    StarteWorker @()
}
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FEHLER: 'docker run' ist fehlgeschlagen (Code $LASTEXITCODE)." -ForegroundColor Red
    Write-Host "Laeuft Docker Desktop? Der Worker laeuft NICHT."
    exit 1
}

Write-Host ""
Write-Host "Worker '$Name' laeuft. Protokoll:  docker logs -f $Name"
Write-Host "Nicht vergessen: im Admin unter Rechenorte den Ort '$OrtName'"
Write-Host "anlegen und die Aufgabe '$Aufgabe' ankreuzen."
