<#
.SYNOPSIS
    Tails the Florence-2 API logs.
#>
[CmdletBinding()]
param([int]$Tail = 50)

$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot 'docker')
try {
    Write-Host 'Streaming logs. Press Ctrl+C to stop.' -ForegroundColor DarkGray
    docker compose logs -f --tail $Tail
}
finally {
    Pop-Location
}
