<#
.SYNOPSIS
    Batch-captions an image folder for LoRA training.

.DESCRIPTION
    Captions every image in a folder and writes captions.json, captions.csv and,
    when validation flags anything, caption_issues.csv.

    Two providers are available. Both use an instruction-following vision
    model, so the captioning rules travel in the prompt and the result needs no
    post-processing beyond trimming model chatter.

      local   (default) Runs the model in this tool's own Python process.
              Needs nothing installed beyond Python: the engine ships as a
              prebuilt wheel and the model downloads once.

      ollama  Talks to an Ollama you already run, anywhere reachable over
              HTTP. Useful if you have one and want to reuse its models.

.PARAMETER ImageDir
    Folder containing the images to caption.

.PARAMETER Concept
    Trigger word for the concept being trained, e.g. "mikey".

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
    ./scripts/caption.ps1 -ImageDir .\photos\mikey -Concept mikey


.EXAMPLE
    # Re-caption an existing dataset folder in place.
    ./scripts/caption.ps1 -ImageDir .\datasets\mikey -Concept mikey -InPlace -Overwrite
#>

[CmdletBinding()]
param(
    # Source images. Treated as read-only: nothing is ever written here.
    [Parameter(Mandatory)][string]$ImageDir,

    [Parameter(Mandatory)][string]$Concept,

    # 'local' runs the model here and needs no service; 'ollama' uses one you
    # already run.
    [ValidateSet('local', 'ollama')]
    [string]$Provider = 'local',

    # For -Provider local. See: lib/local_captioner.py
    [string]$LocalModel = 'qwen2.5-vl-3b',

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

    [ValidateSet('character', 'clothing', 'style', 'object')]
    [string]$ConceptType = 'character',

    [string]$Instruction = '',
    [switch]$Tagify,

    # Set when the subject's hair or facial hair changes across the photos, so
    # those become captioned and promptable rather than averaged together.
    [switch]$VariableAppearance,
    [switch]$Overwrite,

    # For -Provider ollama. Leave empty to auto-select whichever installed
    # model reports the 'vision' capability, preferring $PreferredModels.
    [string]$Model = '',
    [string]$OllamaEndpoint = 'http://localhost:11434',

    [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Repo root, one level up now that scripts live in scripts/.
$RepoRoot = Split-Path $PSScriptRoot -Parent


Import-Module (Join-Path $RepoRoot 'lib/Captioners.psm1') -Force
Import-Module (Join-Path $RepoRoot 'lib/PythonEnv.psm1') -Force

$script:PythonExe = $null

$ImageExtensions = @('.png', '.jpg', '.jpeg', '.webp', '.bmp')

# Tried in order when -Model is not given. Any installed model reporting the
# 'vision' capability works; these are just sensible first choices. Override
# the order with $env:LORA_CAPTION_MODELS (comma-separated).
$PreferredModels = if ($env:LORA_CAPTION_MODELS) {
    @($env:LORA_CAPTION_MODELS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
else {
    @('qwen3.5', 'qwen3-vl', 'qwen2.5vl', 'llama3.2-vision', 'minicpm-v', 'moondream', 'llava')
}


function Initialize-LocalProvider {
    <#
    .SYNOPSIS
        Prepares the in-process captioner: engine wheel, then model weights.
    #>
    Write-Host 'Preparing the local captioner ...' -ForegroundColor Cyan

    # Shared with image preparation and the review UI, so a wizard run builds
    # this once.
    if (-not $script:PythonExe) {
        $script:PythonExe = Initialize-PythonEnv `
            -VenvPath (Join-Path $RepoRoot '.venv') `
            -Packages @('pillow', 'huggingface_hub') `
            -ImportNames @('PIL', 'huggingface_hub')
    }

    Install-LlamaCpp -PythonExe $script:PythonExe | Out-Null

    $script = Join-Path $RepoRoot 'lib/local_captioner.py'
    if (-not (Test-Path -LiteralPath $script)) { throw "local_captioner.py not found at $script" }

    # Downloading here rather than mid-run means a slow first download happens
    # before any captioning starts, and is reported as its own step.
    Write-Host "  Checking model '$LocalModel' ..." -ForegroundColor DarkGray
    $request = @{ action = 'ensure'; model = $LocalModel } | ConvertTo-Json -Compress
    $response = $request | & $script:PythonExe $script
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare model '$LocalModel'." }

    $parsed = $response | ConvertFrom-Json
    if (-not $parsed.ok) { throw "Model error: $($parsed.error)" }

    Write-Host "  [ok] Model ready." -ForegroundColor Green

    return @{ Model = $LocalModel; ScriptPath = $script; PythonExe = $script:PythonExe }
}


function Initialize-OllamaProvider {
    Write-Host "Checking Ollama at $OllamaEndpoint ..." -ForegroundColor Cyan

    try {
        $tags = Invoke-RestMethod -Method Get -Uri "$OllamaEndpoint/api/tags" -TimeoutSec 10
    }
    catch {
        throw ("Cannot reach Ollama at $OllamaEndpoint.`n" +
            "  Install it from https://ollama.com and make sure it is running,`n" +
            "  then check: curl $OllamaEndpoint/api/tags")
    }

    $available = @($tags.models | ForEach-Object { $_.name })
    if ($available.Count -eq 0) {
        throw ("Ollama is running but has no models installed.`n" +
            "  Pull a vision model, for example: ollama pull $($PreferredModels[0])")
    }

    if ($Model) {
        # An explicit choice is honoured, but verified: a text-only model fails
        # confusingly later, having ignored the image entirely.
        $resolved = $available | Where-Object { $_ -eq $Model -or $_ -like "$Model`:*" } | Select-Object -First 1
        if (-not $resolved) {
            throw ("Model '$Model' is not installed in Ollama.`n" +
                "  Installed: $($available -join ', ')`n" +
                "  Pull it with: ollama pull $Model")
        }

        $caps = Get-OllamaModelCapability -Model $resolved -Endpoint $OllamaEndpoint -TimeoutSec 30
        if ($caps -and ($caps -notcontains 'vision')) {
            $visionModels = @(
                $available | Where-Object {
                    (Get-OllamaModelCapability -Model $_ -Endpoint $OllamaEndpoint -TimeoutSec 30) -contains 'vision'
                }
            )
            $hint = if ($visionModels) { "  Vision-capable models you have: $($visionModels -join ', ')" }
            else { "  None of your installed models support vision. Try: ollama pull $($PreferredModels[0])" }

            throw ("Model '$resolved' cannot accept images (capabilities: $($caps -join ', ')).`n$hint")
        }
    }
    else {
        Write-Host '  No -Model given; looking for an installed vision model ...' -ForegroundColor DarkGray
        $resolved = Get-OllamaVisionModel -Endpoint $OllamaEndpoint -Preferred $PreferredModels -TimeoutSec 30

        if (-not $resolved) {
            throw ("No vision-capable model is installed in Ollama.`n" +
                "  Installed: $($available -join ', ')`n" +
                "  Pull one, for example: ollama pull $($PreferredModels[0])")
        }
    }

    Write-Host "  Using model $resolved." -ForegroundColor Green
    return @{
        Model      = $resolved
        Endpoint   = $OllamaEndpoint
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
        else { Join-Path $RepoRoot 'datasets' }
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

try {
    $providerOptions = switch ($Provider) {
        'local' { Initialize-LocalProvider }
        'ollama' { Initialize-OllamaProvider }
    }
}
catch {
    # Setup problems are the ones users hit most (wrong model, service down),
    # so they get a readable message instead of a PowerShell stack trace.
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host "Captioning $($images.Count) image(s)." -ForegroundColor Cyan
Write-Host "  Concept: $Concept ($ConceptType)" -ForegroundColor DarkGray
Write-Host ''

# --- Caption ----------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()

if ($Provider -eq 'local') {

    # The whole batch goes in one call: the model is loaded once rather than
    # per image, which dominates the cost for a local model.
    $prompt = Build-CaptionPrompt -Trigger $Concept -Instruction $Instruction `
        -ConceptType $ConceptType -Tagify:$Tagify -VariableAppearance:$VariableAppearance

    $raw = @(Invoke-LocalCaption -Paths @($images.FullName) -Prompt $prompt `
            -PythonExe $providerOptions.PythonExe -ScriptPath $providerOptions.ScriptPath `
            -Model $providerOptions.Model)

    $index = 0
    foreach ($entry in $raw) {
        $index++
        Write-Host ('[{0}/{1}] {2}' -f $index, $images.Count, (Split-Path $entry.image -Leaf)) -ForegroundColor DarkGray

        if ($entry.error) {
            Write-Host "    FAILED: $($entry.error)" -ForegroundColor Red
            $failures.Add([pscustomobject]@{ image = $entry.image; issue = "Caption failed: $($entry.error)" })
            continue
        }

        $caption = ConvertTo-FinalCaption -Image $entry.image -Raw $entry.caption `
            -Trigger $Concept -Tagify:$Tagify
        $results.Add($caption)
        Write-Host "    $($caption.final_caption)" -ForegroundColor Gray
    }
}
else {

    $index = 0
    foreach ($image in $images) {
        $index++
        Write-Host ('[{0}/{1}] {2}' -f $index, $images.Count, $image.Name) -ForegroundColor DarkGray

        try {
            $caption = Get-ImageCaption -Path $image.FullName -Trigger $Concept `
                -Instruction $Instruction -ConceptType $ConceptType `
                -Tagify:$Tagify -VariableAppearance:$VariableAppearance `
                -ProviderOptions $providerOptions

            $results.Add($caption)
            Write-Host "    $($caption.final_caption)" -ForegroundColor Gray
        }
        catch {
            # One bad image should not discard the captions already earned.
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
            $failures.Add([pscustomobject]@{ image = $image.FullName; issue = "Caption failed: $($_.Exception.Message)" })
        }
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
$issues = @(Test-CaptionSet -Captions $results.ToArray() -Style $captionStyle -ConceptType $ConceptType -VariableAppearance:$VariableAppearance) +
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
