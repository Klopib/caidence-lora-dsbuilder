<#
.SYNOPSIS
    Tails the Florence-2 API logs.
#>
[CmdletBinding()]
param([int]$Tail = 50)

$ErrorActionPreference = 'Stop'
# Repo root, one level up now that scripts live in scripts/.
$RepoRoot = Split-Path $PSScriptRoot -Parent

Push-Location (Join-Path $RepoRoot 'docker')
try {
    Write-Host 'Streaming logs. Press Ctrl+C to stop.' -ForegroundColor DarkGray
    docker compose logs -f --tail $Tail
}
finally {
    Pop-Location
}
