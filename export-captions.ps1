<#
.SYNOPSIS
    Converts captions.json to individual .txt files for kohya_ss training.

.PARAMETER CaptionsJson
    Path to the captions.json file.

.PARAMETER Overwrite
    Overwrite existing .txt files. Default: $false.

.EXAMPLE
    .\export-captions.ps1 -CaptionsJson .\datasets\mikey\captions.json
#>

param(
    [Parameter(Mandatory)]
    [string]$CaptionsJson,
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $CaptionsJson)) {
    Write-Host "captions.json not found: $CaptionsJson" -ForegroundColor Red
    exit 1
}

$entries = Get-Content $CaptionsJson -Raw | ConvertFrom-Json
$outDir  = Split-Path $CaptionsJson -Parent
$written = 0
$skipped = 0
$errors  = 0

Write-Host ""
Write-Host "Exporting captions to .txt files..." -ForegroundColor Cyan
Write-Host "  Source: $CaptionsJson" -ForegroundColor DarkGray
Write-Host "  Output: $outDir" -ForegroundColor DarkGray
Write-Host ""

foreach ($entry in $entries) {
    try {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($entry.image)
        $txtPath  = Join-Path $outDir "$baseName.txt"

        if ((Test-Path $txtPath) -and -not $Overwrite) {
            $skipped++
            continue
        }

        $entry.final_caption | Set-Content -Path $txtPath -Encoding UTF8 -NoNewline
        $written++
    }
    catch {
        Write-Host "  [!!] Error on $($entry.image): $_" -ForegroundColor Red
        $errors++
    }
}

Write-Host "  [ok] Written: $written" -ForegroundColor Green
if ($skipped -gt 0) { Write-Host "  - Skipped: $skipped (use -Overwrite to replace)" -ForegroundColor Yellow }
if ($errors  -gt 0) { Write-Host "  [!!] Errors:  $errors" -ForegroundColor Red }
Write-Host ""