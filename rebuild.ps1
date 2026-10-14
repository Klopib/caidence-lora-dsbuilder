<#
.SYNOPSIS
    Rebuilds the Florence-2 API image from scratch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot 'docker')
try {
    docker compose build --no-cache
    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

Write-Host 'florence-2 image rebuilt.' -ForegroundColor Green
