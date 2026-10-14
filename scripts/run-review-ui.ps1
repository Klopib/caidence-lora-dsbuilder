<#
.SYNOPSIS
    Runs the Gradio caption review UI.

.DESCRIPTION
    Serves the UI from a Python environment under the repo, created on first
    use. On exit, captions are exported to .txt files ready for kohya_ss.

.PARAMETER ImageDir
    Dataset folder containing images plus captions.json / captions.csv.

.PARAMETER Concept
    Trigger word, shown in the UI title.

.PARAMETER RegistryPath
    Optional shared port registry. Skipped when the file does not exist.

.EXAMPLE
    ./scripts/run-review-ui.ps1 -DatasetDir .\datasets\mikey -Concept mikey
#>

param(
  # The dataset folder: staged images plus captions.json / captions.csv.
  [Parameter(Mandatory = $true)]
  [Alias('DatasetDir')]
  [string]$ImageDir,

  [Parameter(Mandatory = $true)][string]$Concept,
  [int]$Port = 7861,

  # Optional shared port registry, for machines that coordinate ports across
  # several local services. Empty means no registry, which is the default;
  # set $env:LORA_PORT_REGISTRY to opt in.
  [string]$RegistryPath = $(
    if ($env:LORA_PORT_REGISTRY) { $env:LORA_PORT_REGISTRY } else { '' }
  )
)

$ExportScript = Join-Path $PSScriptRoot "export-captions.ps1"

# Repo root, one level up now that scripts live in scripts/.
$RepoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $RepoRoot 'lib/PythonEnv.psm1') -Force

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ImageDir)) { throw "ImageDir not found: $ImageDir" }

if ($RegistryPath -and (Test-Path $RegistryPath)) {
  try {
    $reg = Get-Content $RegistryPath | ConvertFrom-Json
    $reserved = $reg | Where-Object { $_.port -eq $Port }
    if ($reserved) {
      $nonReview = $reserved | Where-Object { $_.name -ne "review-ui" }
      if ($nonReview) {
        throw "Port $Port is already reserved for '$($nonReview[0].name)'. Choose another or update the registry."
      }

      $samePath = $reserved | Where-Object { $_.name -eq "review-ui" -and $_.storage_path -eq $ImageDir }
      if ($samePath) {
        Write-Host "Port $Port already reserved for review-ui at $ImageDir; reusing entry." -ForegroundColor DarkGray
      } else {
        foreach ($r in $reserved) {
          if ($r.name -eq "review-ui") {
            $r.storage_path = $ImageDir
            $r.created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
          }
        }
        $reg | ConvertTo-Json -Depth 5 | Set-Content $RegistryPath -Encoding UTF8
        Write-Host "Updated review-ui reservation for port $Port to $ImageDir." -ForegroundColor Green
      }
    } else {
      $entry = [pscustomobject]@{
        name   = "review-ui"
        port   = $Port
        type   = "service"
        image  = "florence-2-review-ui"
        gpu    = $false
        model_cache = $false
        storage_path = $ImageDir
        created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
      }
      $reg = $reg + $entry
      $reg | ConvertTo-Json -Depth 5 | Set-Content $RegistryPath -Encoding UTF8
      Write-Host "Reserved port $Port in $RegistryPath for review-ui." -ForegroundColor Green
    }
  } catch { throw "Port registry error: $_" }
} else {
  if ($RegistryPath) {
    Write-Host "Registry $RegistryPath not found; skipping reservation check." -ForegroundColor Yellow
  }
}

$capsJson = Join-Path $ImageDir "captions.json"
$capsCsv  = Join-Path $ImageDir "captions.csv"
if (-not (Test-Path $capsJson) -or -not (Test-Path $capsCsv)) { throw "captions.json / captions.csv not found in $ImageDir. Run caption.ps1 first." }

$script:MinPython = [version]'3.10'

$capsJson = Join-Path $ImageDir "captions.json"
$capsCsv  = Join-Path $ImageDir "captions.csv"
if (-not (Test-Path $capsJson) -or -not (Test-Path $capsCsv)) {
  throw "captions.json / captions.csv not found in $ImageDir. Run caption.ps1 first."
}

# Shared with image preparation, so a wizard run installs this once.
$venvPython = Initialize-PythonEnv `
  -VenvPath (Join-Path $RepoRoot '.venv') `
  -Packages @('pillow', 'gradio') `
  -ImportNames @('PIL', 'gradio')

Write-Host ""
Write-Host "  Review UI: http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host ""

& $venvPython (Join-Path $RepoRoot 'review_ui.py') `
  --captions $capsJson `
  --csv $capsCsv `
  --concept $Concept `
  --host '127.0.0.1' `
  --port $Port

if ($LASTEXITCODE -ne 0) { throw "review UI exited with code $LASTEXITCODE" }

Write-Host "Exporting captions to .txt files..." -ForegroundColor Cyan
if (-not (Test-Path $ExportScript)) {
  throw "export-captions.ps1 not found at $ExportScript"
}
& pwsh -File $ExportScript `
  -CaptionsJson $capsJson `
  -Overwrite
if ($LASTEXITCODE -ne 0) { throw "Export captions failed (exit code $LASTEXITCODE)" }
Write-Host "  [ok] Captions exported: $ImageDir\*.txt" -ForegroundColor Green
