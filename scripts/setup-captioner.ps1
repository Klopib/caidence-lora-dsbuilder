<#
.SYNOPSIS
    Sets up a local captioning model, with no Ollama install required.

.DESCRIPTION
    Brings up a captioning backend on this machine and downloads a vision
    model into it. Docker is the only prerequisite, and this project already
    requires Docker for the review UI.

    The script is deliberately conservative about an Ollama you already run:

      1. If something is already serving Ollama on the port and it has a
         vision-capable model, nothing is installed and that is used.
      2. If the port is free, a container owned by this project is started
         ('lora-captioner', on its own volume) and the model pulled into it.
      3. If the port is taken by something that is not Ollama, a different
         port is used and reported, rather than fighting for it.

    Your own Ollama install, its container and its models are never modified.

.PARAMETER Model
    Model to pull. Omit to choose from a list with download sizes.

.PARAMETER Port
    Host port for the managed captioner. Default 11434, Ollama's usual port.

.PARAMETER Force
    Pull the model even when a vision-capable model is already available.

.EXAMPLE
    ./scripts/setup-captioner.ps1

.EXAMPLE
    ./scripts/setup-captioner.ps1 -Model qwen3.5:4b
#>

[CmdletBinding()]
param(
    [string]$Model = '',
    [int]$Port = 11434,
    [switch]$Force,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $RepoRoot 'lib/Captioners.psm1') -Force

$ComposeFile = Join-Path $RepoRoot 'docker/docker-compose.yml'
$ContainerName = 'lora-captioner'

# Sizes are approximate download sizes, to set expectations before a pull.
$ModelChoices = @(
    [pscustomobject]@{ Name = 'qwen3.5:4b'; Size = '~3.5 GB'; Note = 'Good balance of quality and size (recommended)' }
    [pscustomobject]@{ Name = 'qwen3.5:2b'; Size = '~2.9 GB'; Note = 'Smaller and faster, still instruction-following' }
    [pscustomobject]@{ Name = 'qwen3.5:9b'; Size = '~7.0 GB'; Note = 'Best quality, needs more VRAM' }
    [pscustomobject]@{ Name = 'qwen2.5vl:3b'; Size = '~3.2 GB'; Note = 'Alternative family, shorter context' }
    [pscustomobject]@{ Name = 'moondream'; Size = '~1.7 GB'; Note = 'Smallest option, basic captions' }
)


function Test-OllamaAt {
    param([string]$Url)
    try {
        Invoke-RestMethod -Method Get -Uri "$Url/api/tags" -TimeoutSec 5 | Out-Null
        return $true
    }
    catch { return $false }
}


function Test-PortFree {
    param([int]$Number)
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Number)
        $listener.Start()
        $listener.Stop()
        return $true
    }
    catch { return $false }
}


function Read-Choice {
    param([string]$Message, [int]$Min, [int]$Max, [int]$Default)
    if ($Yes) { return $Default }
    while ($true) {
        $raw = Read-Host "$Message [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "  Enter a number between $Min and $Max." -ForegroundColor Yellow
    }
}


# --- Docker must be available ----------------------------------------------

Write-Host ''
Write-Host 'Setting up a local captioner' -ForegroundColor Cyan
Write-Host ''

try {
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'docker info failed' }
}
catch {
    throw ("Docker is not available. Install Docker Desktop and make sure it is running, " +
        "then run this script again.")
}

# --- Decide which endpoint to use ------------------------------------------

$endpoint = "http://localhost:$Port"
$startContainer = $false

if (Test-OllamaAt -Url $endpoint) {
    Write-Host "  Found an Ollama already serving $endpoint." -ForegroundColor Green
    Write-Host '  It will be used as-is; nothing of yours is modified.' -ForegroundColor DarkGray
}
elseif (Test-PortFree -Number $Port) {
    Write-Host "  Port $Port is free; starting this project's captioner there." -ForegroundColor DarkGray
    $startContainer = $true
}
else {
    # Something holds the port but does not answer as Ollama. Stepping aside is
    # safer than competing with whatever that is.
    $alt = $Port + 1
    while (-not (Test-PortFree -Number $alt) -and $alt -lt ($Port + 20)) { $alt++ }

    Write-Host "  Port $Port is in use by something that is not Ollama." -ForegroundColor Yellow
    Write-Host "  Using port $alt instead." -ForegroundColor Yellow
    $Port = $alt
    $endpoint = "http://localhost:$Port"
    $startContainer = $true
}

# --- Start the managed container if needed ---------------------------------

if ($startContainer) {
    Write-Host ''
    Write-Host "  Starting $ContainerName ..." -ForegroundColor Cyan

    $env:CAPTIONER_PORT = "$Port"
    docker compose -f $ComposeFile --profile captioner up -d captioner
    if ($LASTEXITCODE -ne 0) { throw 'Failed to start the captioner container.' }

    Write-Host '  Waiting for it to accept connections ...' -ForegroundColor DarkGray
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-OllamaAt -Url $endpoint) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "The captioner started but is not answering at $endpoint." }
    Write-Host "  [ok] Captioner running at $endpoint" -ForegroundColor Green
}

# --- Is a vision model already available? ----------------------------------

$existing = @(Get-OllamaVisionModelList -Endpoint $endpoint)

if ($existing.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host '  A vision-capable model is already available:' -ForegroundColor Green
    $existing | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  Nothing to download. Caption with:' -ForegroundColor Green
    Write-Host "    ./scripts/caption.ps1 -ImageDir <photos> -Concept <name> -OllamaEndpoint $endpoint" -ForegroundColor DarkGray
    Write-Host ''
    return
}

# --- Choose and pull a model -----------------------------------------------

if (-not $Model) {
    Write-Host ''
    Write-Host 'Choose a captioning model to download:' -ForegroundColor White
    for ($i = 0; $i -lt $ModelChoices.Count; $i++) {
        $c = $ModelChoices[$i]
        Write-Host ("  {0}. {1,-14} {2,-9} {3}" -f ($i + 1), $c.Name, $c.Size, $c.Note) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Downloaded once and reused. Stored in a Docker volume, not the repo.' -ForegroundColor DarkGray
    Write-Host ''
    $pick = Read-Choice -Message "Choice (1-$($ModelChoices.Count))" -Min 1 -Max $ModelChoices.Count -Default 1
    $Model = $ModelChoices[$pick - 1].Name
}

Write-Host ''
Write-Host "  Pulling $Model. This downloads several GB and may take a while." -ForegroundColor Cyan
Write-Host ''

if ($startContainer) {
    docker exec $ContainerName ollama pull $Model
}
else {
    # Pulling into an Ollama this script did not start, over its HTTP API, so
    # it works whether that instance is a container or a host install.
    # stream must be false: the streaming response is a sequence of JSON
    # objects, which Invoke-RestMethod cannot parse as one document.
    Write-Host '  (no progress output over the HTTP API; this can take several minutes)' -ForegroundColor DarkGray
    $body = @{ model = $Model; stream = $false } | ConvertTo-Json -Compress
    $pull = Invoke-RestMethod -Method Post -Uri "$endpoint/api/pull" -ContentType 'application/json' `
        -Body $body -TimeoutSec 7200

    if ($pull.PSObject.Properties['status'] -and $pull.status -ne 'success') {
        throw "Pull of $Model did not succeed: $($pull.status)"
    }
}

if ($LASTEXITCODE -ne 0 -and $startContainer) { throw "Failed to pull $Model." }

# --- Verify it can actually caption ----------------------------------------

Write-Host ''
Write-Host '  Verifying the model can accept images ...' -ForegroundColor Cyan

$caps = Get-OllamaModelCapability -Model $Model -Endpoint $endpoint -TimeoutSec 60
if ($caps -notcontains 'vision') {
    throw ("$Model downloaded but does not report the 'vision' capability " +
        "(got: $($caps -join ', ')). Pick a different model.")
}

Write-Host ''
Write-Host "  [ok] $Model is installed and can caption images." -ForegroundColor Green
Write-Host ''
Write-Host '  Next:' -ForegroundColor White
if ($Port -eq 11434) {
    Write-Host '    ./New-LoraDataset.ps1' -ForegroundColor DarkGray
}
else {
    Write-Host "    ./New-LoraDataset.ps1 -OllamaEndpoint $endpoint" -ForegroundColor DarkGray
}
Write-Host ''
