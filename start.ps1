<#
.SYNOPSIS
    Starts the Florence-2 caption API.

.DESCRIPTION
    Only needed for the 'florence' captioning provider. The default 'ollama'
    provider does not use this container.
#>
[CmdletBinding()]
param([switch]$Wait)

$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot 'docker')
try {
    docker compose up -d
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

if ($Wait) {
    Write-Host 'Waiting for the model to load ...' -ForegroundColor Cyan
    for ($i = 1; $i -le 60; $i++) {
        try {
            $health = Invoke-RestMethod -Uri 'http://localhost:8080/health' -TimeoutSec 5
            Write-Host "Ready: model=$($health.model_id) device=$($health.device)" -ForegroundColor Green
            exit 0
        }
        catch { Start-Sleep -Seconds 2 }
    }
    throw 'Florence-2 did not report healthy within 120s. Check ./logs.ps1'
}

Write-Host 'florence-2 starting at http://localhost:8080 (docs at /docs).' -ForegroundColor Green
Write-Host 'Pass -Wait to block until the model has finished loading.' -ForegroundColor DarkGray
