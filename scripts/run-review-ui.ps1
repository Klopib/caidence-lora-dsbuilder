<#
.SYNOPSIS
    Runs the Gradio caption review UI in Docker.

.DESCRIPTION
    Builds the review image, mounts the dataset at /data and serves the UI.
    Needs no host Python install. On exit, captions are exported to .txt files
    ready for kohya_ss.

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

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ImageDir)) { throw "ImageDir not found: $ImageDir" }

function Stop-ExistingReviewUI {
  param([int]$Port)

  $ids = docker ps --filter "publish=$Port" --format "{{.ID}}"
  $ids = @($ids) | Where-Object { $_ }
  if ($ids.Count -eq 0) { return }

  foreach ($id in $ids) {
    Write-Host "Stopping existing container on port $Port ($id)..." -ForegroundColor Yellow
    docker rm -f $id | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to stop container $id on port $Port"
    }
  }
}

Stop-ExistingReviewUI -Port $Port

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

$imageDirUnix = "/data"
$hostPath = (Resolve-Path $ImageDir).ProviderPath
if ($hostPath -match '^[A-Za-z]:\\') {
  $drive = $hostPath.Substring(0,1).ToLower()
  $rest = $hostPath.Substring(2) -replace '\\','/'
  $dockerHostPath = "/${drive}${rest}"
} else {
  $dockerHostPath = $hostPath -replace '\\','/'
}
$volume = "${dockerHostPath}:${imageDirUnix}"

Write-Host "Building review-ui image (florence-2-review-ui)..." -ForegroundColor Cyan
# Paths are resolved from the repo root rather than the caller's working
# directory, so the script works no matter where it is invoked from.
docker build -f (Join-Path $RepoRoot 'docker/Dockerfile.review') -t florence-2-review-ui $RepoRoot
if ($LASTEXITCODE -ne 0) { throw "docker build failed." }

Write-Host "Starting review UI at http://127.0.0.1:$Port ..." -ForegroundColor Green
Write-Host "docker run --rm -p ${Port}:7861 -v ${volume} florence-2-review-ui ..." -ForegroundColor DarkGray

docker run --rm `
  -p "${Port}:7861" `
  -v "${volume}" `
  florence-2-review-ui `
  python /workspace/review_ui.py `
    --captions "$imageDirUnix/captions.json" `
    --csv "$imageDirUnix/captions.csv" `
    --concept "$Concept" `
    --port 7861

if ($LASTEXITCODE -ne 0) { throw "review UI container exited with code $LASTEXITCODE" }


Write-Host "Exporting captions to .txt files..." -ForegroundColor Cyan
if (-not (Test-Path $ExportScript)) {
  throw "export-captions.ps1 not found at $ExportScript"
}
& pwsh -File $ExportScript `
  -CaptionsJson $capsJson `
  -Overwrite
if ($LASTEXITCODE -ne 0) { throw "Export captions failed (exit code $LASTEXITCODE)" }
Write-Host "  [ok] Captions exported: $ImageDir\*.txt" -ForegroundColor Green
