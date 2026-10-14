<#
.SYNOPSIS
    Rebuilds the Florence-2 API image from scratch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# Repo root, one level up now that scripts live in scripts/.
$RepoRoot = Split-Path $PSScriptRoot -Parent

Push-Location (Join-Path $RepoRoot 'docker')
try {
    docker compose build --no-cache
    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

Write-Host 'florence-2 image rebuilt.' -ForegroundColor Green
