<#
.SYNOPSIS
    Stops the Florence-2 caption API.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# Repo root, one level up now that scripts live in scripts/.
$RepoRoot = Split-Path $PSScriptRoot -Parent

Push-Location (Join-Path $RepoRoot 'docker')
try {
    docker compose down
    if ($LASTEXITCODE -ne 0) { throw "docker compose down failed (exit $LASTEXITCODE)." }
}
finally {
    Pop-Location
}

Write-Host 'florence-2 stopped.' -ForegroundColor Yellow
