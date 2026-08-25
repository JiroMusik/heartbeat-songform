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
docker pull $Abbild
docker rm -f $Name 2>$null | Out-Null
docker run -d --name $Name --restart unless-stopped @Gpu `
    -e BETRIEBSART=schleife `
    -e BASIS_URL=$BasisUrl `
    -e ORT_NAME=$OrtName `
    -e AUFGABE=$Aufgabe `
    $Abbild
Write-Host ""
Write-Host "Worker '$Name' laeuft. Protokoll:  docker logs -f $Name"
Write-Host "Nicht vergessen: im Admin unter Rechenorte den Ort '$OrtName'"
Write-Host "anlegen und die Aufgabe '$Aufgabe' ankreuzen."
