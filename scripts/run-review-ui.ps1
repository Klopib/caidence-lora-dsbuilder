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

  # Run the UI in a container instead of on the host. Only needed when there
  # is no Python available; the UI itself has no use for Docker.
  [switch]$Docker,

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

$script:MinPython = [version]'3.10'

function Find-HostPython {
  <#
    .SYNOPSIS
      Finds a Python suitable for running the review UI.

    .DESCRIPTION
      Whatever Python is already on PATH is tried first, so the machine's
      normal interpreter is used rather than a particular version. Specific
      versions are only a fallback for when no default is configured.

      The single requirement is 3.10 or newer; current Gradio installs on
      everything above that, including the newest releases.
  #>

  # 'py -3' is the launcher default; 'python' is the PATH default.
  $candidates = @(
    @{ Exe = 'py'; Args = @('-3') }
    @{ Exe = 'python'; Args = @() }
  )
  foreach ($v in '3.15', '3.14', '3.13', '3.12', '3.11', '3.10') {
    $candidates += @{ Exe = 'py'; Args = @("-$v") }
  }

  foreach ($c in $candidates) {
    try {
      $probe = & $c.Exe @($c.Args + @('-c', 'import sys; print(sys.executable); print("%d.%d" % sys.version_info[:2])')) 2>$null
    }
    catch { continue }

    if ($LASTEXITCODE -ne 0 -or -not $probe) { continue }

    $lines = @($probe) | Where-Object { $_ }
    if ($lines.Count -lt 2) { continue }

    $exe = $lines[0].Trim()
    $ver = [version]$lines[1].Trim()
    if ($ver -ge $script:MinPython -and (Test-Path $exe)) {
      Write-Host "  Using Python $ver" -ForegroundColor DarkGray
      return $exe
    }
  }

  return $null
}

function Initialize-ReviewVenv {
  <#
    .SYNOPSIS
      Creates (once) a virtual environment holding Gradio and returns its python.
    .DESCRIPTION
      Kept out of the system Python so nothing on the machine is altered. Built
      on first use and reused afterwards.
  #>
  param([string]$BasePython, [string]$VenvPath)

  $venvPython = Join-Path $VenvPath 'Scripts/python.exe'

  if (-not (Test-Path $venvPython)) {
    Write-Host "  Creating a Python environment for the review UI ..." -ForegroundColor Cyan
    Write-Host "    $VenvPath" -ForegroundColor DarkGray
    & $BasePython -m venv $VenvPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPython)) {
      throw "Could not create a virtual environment with $BasePython"
    }
  }

  & $venvPython -c "import gradio" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  Installing Gradio (one time, about a minute) ..." -ForegroundColor Cyan
    & $venvPython -m pip install --quiet --upgrade pip
    & $venvPython -m pip install --quiet gradio
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install Gradio.' }
  }

  return $venvPython
}


$capsJson = Join-Path $ImageDir "captions.json"
$capsCsv  = Join-Path $ImageDir "captions.csv"
if (-not (Test-Path $capsJson) -or -not (Test-Path $capsCsv)) {
  throw "captions.json / captions.csv not found in $ImageDir. Run caption.ps1 first."
}

if ($Docker) {

  # Container path: no Python needed on the host.
  $hostPath = (Resolve-Path $ImageDir).ProviderPath
  if ($hostPath -match '^[A-Za-z]:\') {
    $drive = $hostPath.Substring(0,1).ToLower()
    $rest = $hostPath.Substring(2) -replace '\','/'
    $dockerHostPath = "/${drive}${rest}"
  } else {
    $dockerHostPath = $hostPath -replace '\','/'
  }
  $volume = "${dockerHostPath}:/data"

  Write-Host "Building review-ui image ..." -ForegroundColor Cyan
  # Paths resolve from the repo root, not the caller's working directory.
  docker build -f (Join-Path $RepoRoot 'docker/Dockerfile.review') -t lora-review-ui $RepoRoot
  if ($LASTEXITCODE -ne 0) { throw "docker build failed." }

  Write-Host ""
  Write-Host "  Review UI: http://127.0.0.1:$Port" -ForegroundColor Green
  Write-Host ""

  docker run --rm `
    -p "${Port}:7861" `
    -v "${volume}" `
    lora-review-ui `
    python /workspace/review_ui.py `
      --captions "/data/captions.json" `
      --csv "/data/captions.csv" `
      --concept "$Concept" `
      --host "0.0.0.0" `
      --port 7861

  if ($LASTEXITCODE -ne 0) { throw "review UI container exited with code $LASTEXITCODE" }

} else {

  # Default: run on the host. The review UI is a small Gradio app and needs
  # no container, which keeps Docker out of the common path entirely.
  $basePython = Find-HostPython
  if (-not $basePython) {
    throw ("No Python 3.10 or newer found for the review UI.`n" +
      "  Install Python from https://python.org, or`n" +
      "  re-run with -Docker to use the container instead.")
  }

  $venvPython = Initialize-ReviewVenv -BasePython $basePython -VenvPath (Join-Path $RepoRoot '.venv_review')

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
}


Write-Host "Exporting captions to .txt files..." -ForegroundColor Cyan
if (-not (Test-Path $ExportScript)) {
  throw "export-captions.ps1 not found at $ExportScript"
}
& pwsh -File $ExportScript `
  -CaptionsJson $capsJson `
  -Overwrite
if ($LASTEXITCODE -ne 0) { throw "Export captions failed (exit code $LASTEXITCODE)" }
Write-Host "  [ok] Captions exported: $ImageDir\*.txt" -ForegroundColor Green
