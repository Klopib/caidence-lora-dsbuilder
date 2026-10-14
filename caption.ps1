<#
.SYNOPSIS
    Batch-captions an image folder for LoRA training.

.DESCRIPTION
    Captions every image in a folder and writes captions.json, captions.csv and,
    when validation flags anything, caption_issues.csv.

    Two providers are supported:

      ollama    (default) An instruction-following vision model served by Ollama.
                The captioning rules travel in the prompt, so captions come back
                already in training form.

      florence  A Florence-2 API in Docker. Florence cannot take instructions, so
                its output is normalised afterwards. Kept as an offline fallback.

.PARAMETER ImageDir
    Folder containing the images to caption.

.PARAMETER Concept
    Trigger word for the concept being trained, e.g. "mikey".

.PARAMETER Provider
    Captioning backend: ollama (default) or florence.

.PARAMETER ConceptType
    character (default), clothing, style or object. Shapes the prompt: for a
    character the model is told to skip fixed identity traits.

.PARAMETER Instruction
    Extra plain-English guidance passed to the model.

.PARAMETER Tagify
    Ask for comma-separated tags instead of prose clauses.

.PARAMETER Overwrite
    Re-caption even when captions.json already exists.

.NOTES
    The source folder is never written to. Images are copied into the output
    dataset folder and captioned there, so a run can always be repeated from
    the same untouched source.

.EXAMPLE
    # Builds ./datasets/mikey from the source images, leaving the source alone.
    ./caption.ps1 -ImageDir .\photos\mikey -Concept mikey

.EXAMPLE
    ./caption.ps1 -ImageDir .\photos\mikey -Concept mikey -OutputDir D:\training\mikey

.EXAMPLE
    # Re-caption an existing dataset folder in place.
    ./caption.ps1 -ImageDir .\datasets\mikey -Concept mikey -InPlace -Overwrite
#>

[CmdletBinding()]
param(
    # Source images. Treated as read-only: nothing is ever written here.
    [Parameter(Mandatory)][string]$ImageDir,

    [Parameter(Mandatory)][string]$Concept,

    # Where the dataset is built. Source images are copied here, and captions
    # are written beside the copies so the folder is a complete training set.
    # Resolution order:
    #   1. -OutputDir
    #   2. $env:LORA_DATASET_ROOT/<Concept>
    #   3. <repo>/datasets/<Concept>
    [string]$OutputDir,

    # Write captions directly into -ImageDir instead of staging a copy. Only
    # for folders that are already a working dataset, never a source folder.
    [switch]$InPlace,

    [ValidateSet('ollama', 'florence')]
    [string]$Provider = 'ollama',

    [ValidateSet('character', 'clothing', 'style', 'object')]
    [string]$ConceptType = 'character',

    [string]$Instruction = '',
    [switch]$Tagify,
    [switch]$Overwrite,

    # Ollama provider
    [string]$Model = 'qwen3.5',
    [string]$OllamaEndpoint = 'http://localhost:11434',

    # Florence provider
    [string]$Task = '<MORE_DETAILED_CAPTION>',
    [string]$FlorenceEndpoint = 'http://localhost:8080',

    [int]$TimeoutSec = 300,
    [switch]$SkipAutoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'lib/Captioners.psm1') -Force

$ImageExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.bmp')


function Wait-ForEndpoint {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Name,
        [int]$Retries = 30,
        [int]$DelaySeconds = 2
    )

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-RestMethod -Method Get -Uri $Url -TimeoutSec 5 | Out-Null
            Write-Host "  $Name ready (attempt $i)." -ForegroundColor Green
            return
        }
        catch {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "$Name did not become ready at $Url after $Retries attempts."
}


function Initialize-OllamaProvider {
    Write-Host "Checking Ollama at $OllamaEndpoint ..." -ForegroundColor Cyan

    try {
        $tags = Invoke-RestMethod -Method Get -Uri "$OllamaEndpoint/api/tags" -TimeoutSec 10
    }
    catch {
        throw "Cannot reach Ollama at $OllamaEndpoint. Start it with: docker start ollama"
    }

    $available = @($tags.models | ForEach-Object { $_.name })
    if ($available.Count -eq 0) {
        throw "Ollama is running but has no models. Pull one with: ollama pull $Model"
    }

    # Ollama tags are "name:tag"; accept a bare name as matching its default tag.
    $matched = $available | Where-Object { $_ -eq $Model -or $_ -like "$Model`:*" } | Select-Object -First 1
    if (-not $matched) {
        throw ("Model '$Model' not found in Ollama. Available: {0}" -f ($available -join ', '))
    }

    Write-Host "  Using model $matched." -ForegroundColor Green
    return @{
        Model      = $Model
        Endpoint   = $OllamaEndpoint
        TimeoutSec = $TimeoutSec
    }
}


function Initialize-FlorenceProvider {
    $composeDir = Join-Path $PSScriptRoot 'docker'

    if (-not $SkipAutoStart) {
        $running = docker ps --filter 'name=florence-2' --format '{{.Names}}' 2>$null
        if (-not $running) {
            if (-not (Test-Path (Join-Path $composeDir 'docker-compose.yml'))) {
                throw "docker-compose.yml not found under $composeDir."
            }

            Write-Host 'Starting florence-2 container ...' -ForegroundColor Cyan
            Push-Location $composeDir
            try {
                docker compose up -d
                if ($LASTEXITCODE -ne 0) { throw "docker compose up failed (exit $LASTEXITCODE)." }
            }
            finally {
                Pop-Location
            }
        }
        else {
            Write-Host 'florence-2 container already running.' -ForegroundColor DarkGray
        }
    }

    Wait-ForEndpoint -Url "$FlorenceEndpoint/health" -Name 'Florence-2 API'

    return @{
        Task       = $Task
        Endpoint   = "$FlorenceEndpoint/caption"
        TimeoutSec = $TimeoutSec
    }
}


# --- Validate inputs --------------------------------------------------------

if (-not (Test-Path -LiteralPath $ImageDir)) {
    throw "ImageDir not found: $ImageDir"
}

$sourceDir = (Resolve-Path -LiteralPath $ImageDir).ProviderPath

$sourceImages = @(
    Get-ChildItem -LiteralPath $sourceDir -File -Recurse |
        Where-Object { $ImageExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object @{ Expression = {
                # Natural sort: 2.jpg before 10.jpg.
                $m = [regex]::Match($_.BaseName, '\d+')
                if ($m.Success) { [int]$m.Value } else { [int]::MaxValue }
            }
        }, FullName
)

if ($sourceImages.Count -eq 0) {
    throw "No images found under $sourceDir (looked for $($ImageExtensions -join ', '))."
}

# --- Decide where the dataset is built --------------------------------------

if ($InPlace) {
    if ($OutputDir) {
        throw 'Pass either -OutputDir or -InPlace, not both.'
    }
    $datasetDir = $sourceDir
}
else {
    if (-not $OutputDir) {
        $root = if ($env:LORA_DATASET_ROOT) { $env:LORA_DATASET_ROOT }
        else { Join-Path $PSScriptRoot 'datasets' }
        $OutputDir = Join-Path $root $Concept
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $datasetDir = (Resolve-Path -LiteralPath $OutputDir).ProviderPath

    # Writing captions into the folder the user pointed at as input would
    # modify their source data. Require -InPlace to say so explicitly.
    if ($datasetDir -eq $sourceDir) {
        throw ("-OutputDir is the same folder as -ImageDir. Source images are " +
            "treated as read-only; pass -InPlace if you really mean to write there.")
    }
}

$outJson = Join-Path $datasetDir 'captions.json'
$outCsv = Join-Path $datasetDir 'captions.csv'
$outIssues = Join-Path $datasetDir 'caption_issues.csv'

if ((Test-Path -LiteralPath $outJson) -and -not $Overwrite) {
    Write-Host "captions.json already exists in $datasetDir; pass -Overwrite to regenerate." -ForegroundColor Yellow
    exit 0
}

# --- Stage the images -------------------------------------------------------

if ($InPlace) {
    $images = $sourceImages
}
else {
    Write-Host "Staging $($sourceImages.Count) image(s) into $datasetDir ..." -ForegroundColor Cyan

    $images = [System.Collections.Generic.List[object]]::new()
    $usedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($source in $sourceImages) {
        # -Recurse flattens subfolders, so two files can share a name.
        $name = $source.Name
        if (-not $usedNames.Add($name)) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($source.Name)
            $ext = $source.Extension
            $n = 2
            do { $name = "${stem}_$n$ext"; $n++ } while (-not $usedNames.Add($name))
            Write-Host "  name collision: $($source.Name) staged as $name" -ForegroundColor Yellow
        }

        $destination = Join-Path $datasetDir $name
        Copy-Item -LiteralPath $source.FullName -Destination $destination -Force
        $images.Add((Get-Item -LiteralPath $destination))
    }

    Write-Host "  Source folder left unmodified: $sourceDir" -ForegroundColor DarkGray
}

# --- Prepare the provider ---------------------------------------------------

$providerOptions = switch ($Provider) {
    'ollama' { Initialize-OllamaProvider }
    'florence' { Initialize-FlorenceProvider }
}

Write-Host ''
Write-Host "Captioning $($images.Count) image(s) with provider '$Provider'." -ForegroundColor Cyan
Write-Host "  Concept: $Concept ($ConceptType)" -ForegroundColor DarkGray
Write-Host ''

# --- Caption ----------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($image in $images) {
    $index++
    $label = '[{0}/{1}] {2}' -f $index, $images.Count, $image.Name
    Write-Host $label -ForegroundColor DarkGray

    try {
        $caption = Get-ImageCaption -Path $image.FullName -Trigger $Concept `
            -Provider $Provider -Instruction $Instruction -ConceptType $ConceptType `
            -Tagify:$Tagify -ProviderOptions $providerOptions

        $results.Add($caption)
        Write-Host "    $($caption.final_caption)" -ForegroundColor Gray
    }
    catch {
        # One bad image should not discard the captions already earned.
        Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add([pscustomobject]@{ image = $image.FullName; issue = "Caption failed: $($_.Exception.Message)" })
    }
}

if ($results.Count -eq 0) {
    throw 'Every image failed to caption. Nothing written.'
}

# --- Write outputs ----------------------------------------------------------

# -AsArray keeps a single-image run a JSON array, which review_ui.py requires.
$results | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $outJson -Encoding utf8
$results | Export-Csv -LiteralPath $outCsv -Encoding utf8 -NoTypeInformation

$captionStyle = if ($Tagify) { 'tags' } else { 'prose' }
$issues = @(Test-CaptionSet -Captions $results.ToArray() -Style $captionStyle -ConceptType $ConceptType) +
@($failures.ToArray())

if ($issues.Count -gt 0) {
    $issues | Export-Csv -LiteralPath $outIssues -Encoding utf8 -NoTypeInformation
    Write-Host ''
    Write-Host "$($issues.Count) validation flag(s) written to $outIssues" -ForegroundColor Yellow
}
else {
    if (Test-Path -LiteralPath $outIssues) { Remove-Item -LiteralPath $outIssues -Force }
    Write-Host ''
    Write-Host 'No validation flags.' -ForegroundColor Green
}

Write-Host "Captioned $($results.Count)/$($images.Count) image(s)." -ForegroundColor Green
Write-Host "Dataset: $datasetDir" -ForegroundColor Green
Write-Host "  $outJson" -ForegroundColor DarkGray
Write-Host "  $outCsv" -ForegroundColor DarkGray
if (-not $InPlace) {
    Write-Host "Source images untouched: $sourceDir" -ForegroundColor DarkGray
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) image(s) failed. See $outIssues" -ForegroundColor Red
    exit 1
}
