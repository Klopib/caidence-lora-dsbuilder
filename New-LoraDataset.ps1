<#
.SYNOPSIS
    Prepares a dataset for LoRA training.

.DESCRIPTION
    Creates a standardized folder structure and prepares images for LoRA training
    using kohya_ss or similar training frameworks.
    
    Runs the full flow: folder structure, image copy and optional resize,
    autocaptioning, the review UI, and export to kohya_ss .txt files.

.PARAMETER ConceptName
    Name of the concept you're training (e.g., "moroccan_caftan", "cyberpunk_edg").

.PARAMETER SourceImagesPath
    Path to folder containing source images.

.PARAMETER ConceptType
    Type: "character", "clothing", "style", "object".

.PARAMETER TrainingRate
    Number of times each image is repeated during training.

.EXAMPLE
    .\New-LoraDataset.ps1
.EXAMPLE
    .\New-LoraDataset.ps1 -ConceptName "my_character" -ConceptType character -SourceImagesPath .\photos\my_character
#>

param(
    [string]$ConceptName,
    [string]$SourceImagesPath,
    [ValidateSet("character", "clothing", "style", "object", "")]
    [string]$ConceptType,
    [int]$TrainingRate,
    [string]$Instruction = "",

    # Captioning backend. 'ollama' follows instructions, so it needs no
    # 'local' captions here and needs nothing installed; 'ollama' reuses one
    # you already run.
    [ValidateSet("local", "ollama")]
    [string]$Provider = "local",

    # Model for -Provider local. See lib/local_captioner.py for the list.
    [string]$LocalModel = "qwen2.5-vl-3b",

    # For -Provider ollama. Blank means auto-select a vision-capable model.
    [string]$Model = "",

    [string]$OllamaEndpoint = "http://localhost:11434",

    # Port for the caption review UI.
    [int]$ReviewPort = 7861,

    # Comma-separated tags instead of prose. Tag captions suit booru-style base
    # models (Pony, Illustrious); prose suits newer ones (Flux, SDXL).
    [switch]$Tagify,

    # Set when the subject's hair or facial hair changes across the photos.
    [switch]$VariableAppearance,

    # Accept the default answer to every confirmation prompt and run unattended.
    # Requires the values that have no default to be passed as parameters:
    # -ConceptName, -SourceImagesPath, -ConceptType and -TrainingRate.
    [switch]$Yes,

    # Where prepared datasets are written. Resolution order:
    #   1. -BaseDir
    #   2. $env:LORA_DATASET_ROOT
    #   3. a 'datasets' folder beside this script
    # Point it at your trainer's data directory to write straight there.
    [string]$BaseDir = $(
        if ($env:LORA_DATASET_ROOT) { $env:LORA_DATASET_ROOT }
        else { Join-Path $PSScriptRoot 'datasets' }
    )
)

# --- Config -----------------------------------------------------------------

# Helper scripts live in scripts/; the wizard stays at the repo root.
$ScriptsDir = Join-Path $PSScriptRoot 'scripts'
$CaptionScript = Join-Path $ScriptsDir "caption.ps1"
$ReviewScript  = Join-Path $ScriptsDir "run-review-ui.ps1"
$ExportScript  = Join-Path $ScriptsDir "export-captions.ps1"
$ErrorActionPreference = "Stop"
$script:AcceptDefaults = [bool]$Yes

Import-Module (Join-Path $PSScriptRoot 'lib/Captioners.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/PythonEnv.psm1') -Force

# Pillow prepares the images and Gradio runs the review UI. Both live in one
# environment under the repo, created on first run; the system Python is never
# touched. Done here so a missing Python is reported before anything else.
$script:PythonExe = Initialize-PythonEnv `
    -VenvPath (Join-Path $PSScriptRoot '.venv') `
    -Packages @('pillow', 'gradio') `
    -ImportNames @('PIL', 'gradio')

# Any terminating error used to end the script instantly. Launched from an
# icon or a transient terminal, that closed the window before the reason could
# be read. Hold the window open unless running unattended.
trap {
    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor Red
    Write-Host " Dataset preparation stopped" -ForegroundColor Red
    Write-Host "----------------------------------------------------------------" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Any output above this line explains what went wrong." -ForegroundColor DarkGray
    Write-Host ""
    if (-not $script:AcceptDefaults) { pause }
    exit 1
}

# --- Helpers ----------------------------------------------------------------

function Read-StringValue {
    param([string]$Message, [string]$Default)
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $val = Read-Host "$Message$suffix"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}

function Get-LocalModelChoice {
    <#
    .SYNOPSIS
        Lists the vision models the local captioner can download.
    .DESCRIPTION
        The list lives in lib/local_captioner.py beside the download logic, so
        there is one place to add a model rather than two that can disagree.
    .OUTPUTS
        Objects with key, label, size_gb and note. Empty if the list cannot be read.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $script = Join-Path $RepoRoot 'lib/local_captioner.py'
    if (-not (Test-Path -LiteralPath $script)) { return @() }

    try {
        $response = (@{ action = 'models' } | ConvertTo-Json -Compress) | & $PythonExe $script
        if ($LASTEXITCODE -ne 0) { return @() }
        $parsed = $response | ConvertFrom-Json
        if (-not $parsed.ok) { return @() }
        return @($parsed.models)
    }
    catch {
        # A missing list is not fatal: the default model still downloads.
        return @()
    }
}


function Test-OllamaBackend {
    <#
    .SYNOPSIS
        Checks that Ollama is reachable and has a model that can caption images.
    .OUTPUTS
        Hashtable with Ok, Reason and Models.
    #>
    param([string]$Endpoint)

    try {
        Invoke-RestMethod -Method Get -Uri "$Endpoint/api/tags" -TimeoutSec 10 | Out-Null
    }
    catch {
        return @{
            Ok     = $false
            Models = @()
            Reason = "Cannot reach Ollama at $Endpoint.`n" +
            "    Install it from https://ollama.com and make sure it is running.`n" +
            "    Then try again."
        }
    }

    $models = @(Get-OllamaVisionModelList -Endpoint $Endpoint)
    if ($models.Count -eq 0) {
        return @{
            Ok     = $false
            Models = @()
            Reason = "Ollama is running but has no model that can accept images.`n" +
            "    Pull one, for example: ollama pull qwen3.5`n" +
            "    Install it from https://ollama.com, then try again."
        }
    }

    return @{ Ok = $true; Models = $models; Reason = '' }
}


function Read-IntValue {
    param(
        [string]$Message,
        [int]$Default = 0,
        [int]$Min = 1,
        # 0 means no upper bound.
        [int]$Max = 0
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { "" }
        $val = Read-Host "$Message$suffix"
        if ([string]::IsNullOrWhiteSpace($val) -and $Default) { return $Default }

        $parsed = 0
        if ([int]::TryParse($val, [ref]$parsed) -and $parsed -ge $Min -and ($Max -le 0 -or $parsed -le $Max)) {
            return $parsed
        }

        $range = if ($Max -gt 0) { "between $Min and $Max" } else { "$Min or greater" }
        Write-Host "  Please enter a number $range." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Message, [bool]$Default = $true)
    $hint = if ($Default) { "[Y]/n" } else { "y/[N]" }

    # -Yes accepts every default so the wizard can run unattended. Read-Host
    # reads the console rather than stdin, so answers cannot simply be piped in.
    if ($script:AcceptDefaults) {
        Write-Host "$Message ($hint) -> $(if ($Default) { 'y' } else { 'n' })" -ForegroundColor DarkGray
        return $Default
    }

    $val = Read-Host "$Message ($hint)"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return ($val.Trim().ToLower() -in @("y", "yes"))
}

function Read-ResizeLongEdge {
    Write-Host ""
    Write-Host "Choose target size for the longest edge:" -ForegroundColor White
    Write-Host "  1. 512px" -ForegroundColor White
    Write-Host "  2. 1024px" -ForegroundColor White
    Write-Host "  3. Custom value" -ForegroundColor White
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Choice (1-3)"
        if ($choice -eq "1") { return 512 }
        if ($choice -eq "2") { return 1024 }
        if ($choice -eq "3") {
            while ($true) {
                $custom = Read-IntValue "Custom long-edge size (pixels)" -Default 768
                if ($custom -ge 64) { return $custom }
                Write-Host "  Please enter at least 64 pixels." -ForegroundColor Yellow
            }
        }
        Write-Host "  Please enter 1, 2, or 3." -ForegroundColor Yellow
    }
}

function Invoke-ImagePreparation {
    <#
    .SYNOPSIS
        Copies, orients and resizes a batch of images.

    .DESCRIPTION
        Hands the work to lib/prepare_images.py, which uses Pillow. That library
        applies EXIF orientation and is available on every platform, unlike
        System.Drawing, which is Windows-only in .NET 6+ and silently wrote
        rotated photos out sideways.

        The whole batch goes in one call, so Python starts once per run rather
        than once per image.

    .OUTPUTS
        One object per image with Source, Status, Width, Height and Error.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][string]$PythonExe,
        [int]$JpegQuality = 95
    )

    $script = Join-Path $PSScriptRoot 'lib/prepare_images.py'
    if (-not (Test-Path -LiteralPath $script)) { throw "prepare_images.py not found at $script" }

    $request = @{ jobs = $Jobs; jpeg_quality = $JpegQuality } | ConvertTo-Json -Depth 5 -Compress
    $response = $request | & $PythonExe $script
    if ($LASTEXITCODE -ne 0) { throw "Image preparation failed (exit $LASTEXITCODE)." }

    return (($response | ConvertFrom-Json).results)
}


function Get-ImageDimension {
    <#
    .SYNOPSIS
        Reports image sizes as a viewer would show them, EXIF rotation applied.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$PythonExe
    )

    $script = Join-Path $PSScriptRoot 'lib/prepare_images.py'
    $request = @{ probe = $Paths } | ConvertTo-Json -Depth 3 -Compress
    $response = $request | & $PythonExe $script
    if ($LASTEXITCODE -ne 0) { return @() }

    return (($response | ConvertFrom-Json).results)
}


function Show-TrainingRateInfo {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          Understanding Training Rate Per Image            ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The training rate controls how many times each image is seen" -ForegroundColor White
    Write-Host "during training. Think of it as 'repeats per image per epoch'." -ForegroundColor White
    Write-Host ""
    Write-Host "Effects of training rate:" -ForegroundColor Yellow
    Write-Host "  • Too LOW  → Model won't learn the concept properly" -ForegroundColor DarkGray
    Write-Host "               Result: Weak LoRA, inconsistent outputs" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  • Too HIGH → Model becomes inflexible and overfitted" -ForegroundColor DarkGray
    Write-Host "               Result: Won't mix well with other models" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Recommended rates (from EDG's tutorial):" -ForegroundColor Yellow
    Write-Host "  • Simple concepts (clothing, objects)    → 5-8" -ForegroundColor White
    Write-Host "  • Complex concepts (characters, people)  → 10-15" -ForegroundColor White
    Write-Host "  • Art styles                             → 8-12" -ForegroundColor White
    Write-Host ""
    Write-Host "Example: 31 images at rate 5 = 155 training steps per epoch" -ForegroundColor DarkGray
    Write-Host ""
    pause
}

function Show-ImageSelectionGuide {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║            How to Select Good Training Images             ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Key principle: DIVERSE yet HOMOGENEOUS" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "[ok] DO include variety in:" -ForegroundColor Green
    Write-Host "  • Poses and angles" -ForegroundColor White
    Write-Host "  • Lighting conditions (bright, dim, natural, artificial)" -ForegroundColor White
    Write-Host "  • Backgrounds (indoor, outdoor, plain, detailed)" -ForegroundColor White
    Write-Host "  • Colors and styles (if applicable to concept)" -ForegroundColor White
    Write-Host "  • Distances (close-up, full body, medium shots)" -ForegroundColor White
    Write-Host ""
    Write-Host "[!!] DON'T include:" -ForegroundColor Red
    Write-Host "  • Blurry or low-quality images" -ForegroundColor White
    Write-Host "  • Watermarked images (distracting)" -ForegroundColor White
    Write-Host "  • Images where concept is barely visible" -ForegroundColor White
    Write-Host "  • Completely inconsistent content" -ForegroundColor White
    Write-Host ""
    Write-Host "Recommended image count: 20-40 images" -ForegroundColor Yellow
    Write-Host "  • Minimum: 15 images (limited quality)" -ForegroundColor DarkGray
    Write-Host "  • Sweet spot: 25-35 images" -ForegroundColor DarkGray
    Write-Host "  • More isn't always better!" -ForegroundColor DarkGray
    Write-Host ""
    pause
}

function Get-ImageAnalysis {
    param([string]$Path)
    
    $imageFiles = Get-ChildItem -Path $Path -Include *.png,*.jpg,*.jpeg,*.webp,*.bmp -File -Recurse
    $count = $imageFiles.Count
    
    if ($count -eq 0) {
        Write-Host "  No images found in the specified path." -ForegroundColor Red
        return $null
    }
    
    # Sample resolution, as a viewer would show it: EXIF-rotated photos report
    # their stored size otherwise, which reads as landscape for a portrait shot.
    $avgWidth = "Unknown"
    $avgHeight = "Unknown"
    $probe = Get-ImageDimension -Paths @($imageFiles[0].FullName) -PythonExe $script:PythonExe
    if ($probe -and $probe[0].width -gt 0) {
        $avgWidth = $probe[0].width
        $avgHeight = $probe[0].height
    }
    
    return [PSCustomObject]@{
        Count = $count
        Files = $imageFiles
        AvgWidth = $avgWidth
        AvgHeight = $avgHeight
    }
}

# --- Main Flow --------------------------------------------------------------

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                   LoRA Dataset Builder                    ║" -ForegroundColor Cyan
Write-Host "║      (Structure, Copy, Autocaption, Review, Export)       ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will prepare your images for LoRA training." -ForegroundColor White
Write-Host "Includes: folder setup, image copy/resizing, autocaptioning, review UI, export." -ForegroundColor DarkGray
Write-Host ""

# --- Step 1: Concept Name ---------------------------------------------------

if (-not $ConceptName) {
    Write-Host "What concept are you training?" -ForegroundColor White
    Write-Host "  Examples: 'moroccan_caftan', 'edg_character', 'cyberpunk_style'" -ForegroundColor DarkGray
    Write-Host "  Use underscores instead of spaces" -ForegroundColor DarkGray
    Write-Host ""
    $ConceptName = Read-StringValue "Concept name"
    if (-not $ConceptName) {
        Write-Host "Concept name is required." -ForegroundColor Red
        pause
        return
    }
}

$ConceptName = $ConceptName.ToLower() -replace '\s+', '_' -replace '[^a-z0-9_-]', ''
Write-Host "  Using concept name: $ConceptName" -ForegroundColor DarkGray

# --- Step 2: Concept Type ---------------------------------------------------

if (-not $ConceptType) {
    Write-Host ""
    Write-Host "What type of concept are you training?" -ForegroundColor White
    Write-Host "  1. Character/Person    (Recommended rate: 12)" -ForegroundColor White
    Write-Host "  2. Clothing/Fashion    (Recommended rate: 6)" -ForegroundColor White
    Write-Host "  3. Art Style           (Recommended rate: 10)" -ForegroundColor White
    Write-Host "  4. Object/Item         (Recommended rate: 7)" -ForegroundColor White
    Write-Host ""
    Write-Host "  5. More information about training rates" -ForegroundColor Cyan
    Write-Host ""
    
    while ($true) {
        $choice = Read-Host "Choice (1-5)"
        if ($choice -eq "1") { $ConceptType = "character"; $suggestedRate = 12; break }
        if ($choice -eq "2") { $ConceptType = "clothing"; $suggestedRate = 6; break }
        if ($choice -eq "3") { $ConceptType = "style"; $suggestedRate = 10; break }
        if ($choice -eq "4") { $ConceptType = "object"; $suggestedRate = 7; break }
        if ($choice -eq "5") {
            Show-TrainingRateInfo
            Write-Host "What type of concept are you training?" -ForegroundColor White
            Write-Host "  1. Character/Person  2. Clothing/Fashion" -ForegroundColor White
            Write-Host "  3. Art Style         4. Object/Item" -ForegroundColor White
            Write-Host ""
            continue
        }
        Write-Host "  Please enter 1, 2, 3, 4, or 5." -ForegroundColor Yellow
    }
}
else {
    # Set suggested rate based on type if not interactive
    $suggestedRate = switch ($ConceptType) {
        "character" { 12 }
        "clothing"  { 6 }
        "style"     { 10 }
        "object"    { 7 }
        default     { 8 }
    }
}

Write-Host "  Selected: $ConceptType (suggested training rate: $suggestedRate)" -ForegroundColor DarkGray

# --- Step 3: Source Images --------------------------------------------------

if (-not $SourceImagesPath) {
    Write-Host ""
    Write-Host "Where are your source images?" -ForegroundColor White
    Write-Host "  You can drag and drop the folder here, or paste the path" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Need help selecting good images? Type 'H' for guidance" -ForegroundColor Cyan
    Write-Host ""
    
    while ($true) {
        $answer = Read-Host "Image folder path (or H for help)"
        if ($answer -eq "H" -or $answer -eq "h") {
            Show-ImageSelectionGuide
            Write-Host "Where are your source images?" -ForegroundColor White
            continue
        }
        $SourceImagesPath = $answer.Trim('"').Trim("'")
        if (Test-Path $SourceImagesPath) { break }
        Write-Host "  Path not found. Please try again." -ForegroundColor Yellow
    }
}

# --- Step 4: Analyze Images -------------------------------------------------

Write-Host ""
Write-Host "Analyzing images..." -ForegroundColor Cyan

$imageAnalysis = Get-ImageAnalysis -Path $SourceImagesPath

if (-not $imageAnalysis) {
    Write-Host "No valid images found. Exiting." -ForegroundColor Red
    pause
    return
}

$imageCount = $imageAnalysis.Count
Write-Host "  [ok] Found $imageCount images" -ForegroundColor Green

if ($imageAnalysis.AvgWidth -ne "Unknown") {
    Write-Host "  [ok] Sample resolution: $($imageAnalysis.AvgWidth)x$($imageAnalysis.AvgHeight)" -ForegroundColor Green
}

# Quality check
if ($imageCount -lt 15) {
    Write-Host ""
    Write-Host "  ⚠ WARNING: Fewer than 15 images detected" -ForegroundColor Yellow
    Write-Host "  Your LoRA quality will be significantly limited." -ForegroundColor Yellow
    Write-Host "  Recommended minimum: 20 images" -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-YesNo "Continue anyway?" -Default $false
    if (-not $continue) {
        Write-Host "Cancelled. Please gather more images." -ForegroundColor Yellow
        pause
        return
    }
}
elseif ($imageCount -gt 100) {
    Write-Host ""
    Write-Host "  ⚠ NOTE: You have $imageCount images" -ForegroundColor Yellow
    Write-Host "  More isn't always better! 25-40 diverse images often work best." -ForegroundColor Yellow
    Write-Host "  Consider curating down to your best, most diverse shots." -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-YesNo "Continue with all $imageCount images?" -Default $true
    if (-not $continue) {
        Write-Host "Cancelled. Please curate your image set." -ForegroundColor Yellow
        pause
        return
    }
}

# --- Step 5: Optional Resize -------------------------------------------------

$resizeImages = $false
$resizeLongEdge = 0

Write-Host ""
Write-Host "Would you like to downsize images before training?" -ForegroundColor White
Write-Host "  Only images larger than the selected size will be resized." -ForegroundColor DarkGray
Write-Host "  The longest edge will be set to the target value." -ForegroundColor DarkGray

$resizeImages = Read-YesNo "Resize images?" -Default $false

if ($resizeImages) {
    $resizeLongEdge = Read-ResizeLongEdge
    Write-Host "  [ok] Resize enabled: longest edge = $resizeLongEdge px" -ForegroundColor Green
}
else {
    Write-Host "  [ok] Resize disabled (images kept at original size)" -ForegroundColor Green
}

# --- Step 6: Training Rate --------------------------------------------------

if (-not $TrainingRate -or $TrainingRate -le 0) {
    Write-Host ""
    Write-Host "How many times should each image be repeated during training?" -ForegroundColor White
    Write-Host "  Based on '$ConceptType', the recommended rate is: $suggestedRate" -ForegroundColor Cyan
    Write-Host "  This means each image will be seen $suggestedRate times per epoch." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Need more info? Type 'I' for training rate explanation" -ForegroundColor Cyan
    Write-Host ""
    
    while ($true) {
        $answer = Read-Host "Training rate per image [$suggestedRate] (or I for info)"
        if ($answer -eq "I" -or $answer -eq "i") {
            Show-TrainingRateInfo
            Write-Host "Training rate per image [$suggestedRate]:" -ForegroundColor White
            continue
        }
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $TrainingRate = $suggestedRate
            break
        }
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -gt 0) {
            $TrainingRate = $parsed
            break
        }
        Write-Host "  Please enter a valid number." -ForegroundColor Yellow
    }
}

$totalSteps = $imageCount * $TrainingRate
Write-Host "  [ok] Training rate set to: $TrainingRate" -ForegroundColor Green
Write-Host "  [ok] Total training steps per epoch: $totalSteps" -ForegroundColor Green

# --- Step 6b: Captioning backend --------------------------------------------

# Captioning here is the default, because it works for someone who has
# installed nothing beyond this tool. An Ollama is only offered when one is
# actually running, so the common path is a single confirmation.
Write-Host ""
Write-Host "Captioning" -ForegroundColor White
Write-Host ""
Write-Host "  This tool can caption on its own. It downloads a vision model once" -ForegroundColor DarkGray
Write-Host "  and runs it here: no other software, no account, nothing to configure." -ForegroundColor DarkGray

if (-not $script:PythonExe) {
    $script:PythonExe = Initialize-PythonEnv `
        -VenvPath (Join-Path $PSScriptRoot '.venv') `
        -Packages @('pillow', 'huggingface_hub') `
        -ImportNames @('PIL', 'huggingface_hub')
}

$ollama = Test-OllamaBackend -Endpoint $OllamaEndpoint
if ($ollama.Ok) {
    Write-Host ""
    Write-Host "  You also have Ollama running at $OllamaEndpoint" -ForegroundColor DarkGray
    Write-Host "    with: $($ollama.Models -join ', ')" -ForegroundColor DarkGray
}

$backendReady = $false

while (-not $backendReady) {

    Write-Host ""
    Write-Host "How should captions be generated?" -ForegroundColor White
    Write-Host "  1. Here, in this tool  (recommended) downloads a model the first time" -ForegroundColor DarkGray

    $maxChoice = 1
    if ($ollama.Ok) {
        $maxChoice = 2
        Write-Host "  2. Use your Ollama     reuses a model you already have" -ForegroundColor DarkGray
    }

    $cancelChoice = $maxChoice + 1
    Write-Host "  $cancelChoice. Cancel" -ForegroundColor DarkGray
    Write-Host ""

    switch (Read-IntValue "Choice (1-$cancelChoice)" -Min 1 -Max $cancelChoice -Default 1) {

        1 {
            $Provider = 'local'

            if (-not $script:AcceptDefaults) {
                $choices = Get-LocalModelChoice -PythonExe $script:PythonExe -RepoRoot $PSScriptRoot
                if ($choices.Count -gt 1) {
                    Write-Host ""
                    Write-Host "Which model?" -ForegroundColor White
                    for ($i = 0; $i -lt $choices.Count; $i++) {
                        $c = $choices[$i]
                        $mark = if ($c.key -eq $LocalModel) { ' (default)' } else { '' }
                        Write-Host ("  {0}. {1,-16} {2,5:N1} GB  {3}{4}" -f ($i + 1), $c.label, $c.size_gb, $c.note, $mark) -ForegroundColor DarkGray
                    }
                    Write-Host ""
                    Write-Host "  Downloaded once and reused. Larger models caption better but run slower." -ForegroundColor DarkGray
                    Write-Host ""

                    $default = 1
                    for ($i = 0; $i -lt $choices.Count; $i++) {
                        if ($choices[$i].key -eq $LocalModel) { $default = $i + 1 }
                    }
                    $pick = Read-IntValue "Choice (1-$($choices.Count))" -Min 1 -Max $choices.Count -Default $default
                    $LocalModel = $choices[$pick - 1].key
                }
            }

            $backendReady = $true
        }

        2 {
            $Provider = 'ollama'

            if ($Model -and ($ollama.Models -notcontains $Model)) {
                Write-Host "  '$Model' cannot accept images; choosing automatically." -ForegroundColor Yellow
                $Model = ''
            }

            if (-not $Model -and -not $script:AcceptDefaults -and $ollama.Models.Count -gt 1) {
                Write-Host ""
                Write-Host "Which Ollama model?" -ForegroundColor White
                Write-Host "  1. Auto-select (recommended)" -ForegroundColor DarkGray
                for ($i = 0; $i -lt $ollama.Models.Count; $i++) {
                    Write-Host "  $($i + 2). $($ollama.Models[$i])" -ForegroundColor DarkGray
                }
                Write-Host ""
                $pick = Read-IntValue "Choice (1-$($ollama.Models.Count + 1))" -Min 1 -Max ($ollama.Models.Count + 1) -Default 1
                $Model = if ($pick -eq 1) { '' } else { $ollama.Models[$pick - 2] }
            }

            $backendReady = $true
        }

        default {
            Write-Host ""
            Write-Host "Cancelled. No files were created." -ForegroundColor Yellow
            Write-Host ""
            pause
            exit 1
        }
    }
}

# --- Step 6c: Caption style and guidance ------------------------------------

Write-Host ""
Write-Host "Caption settings" -ForegroundColor White
Write-Host "  Backend:   Ollama ($OllamaEndpoint)" -ForegroundColor DarkGray
Write-Host "  Model:     $(if ($Model) { $Model } else { 'auto-select' })" -ForegroundColor DarkGray
Write-Host "  Style:     $(if ($Tagify) { 'comma-separated tags' } else { 'prose clauses' })" -ForegroundColor DarkGray
Write-Host "  Guidance:  $(if ($Instruction) { $Instruction } else { 'none' })" -ForegroundColor DarkGray
Write-Host ""

if (-not $script:AcceptDefaults -and (Read-YesNo "Change caption style or guidance?" -Default $false)) {

    Write-Host ""
    Write-Host "Caption style:" -ForegroundColor White
    Write-Host "  1. Prose clauses  (default) for Flux, SDXL and similar" -ForegroundColor DarkGray
    Write-Host "  2. Comma tags     for booru-trained models such as Pony or Illustrious" -ForegroundColor DarkGray
    Write-Host ""
    $Tagify = ((Read-IntValue "Choice (1-2)" -Min 1 -Max 2 -Default 1) -eq 2)

    if ($ConceptType -eq 'character') {
        Write-Host ""
        Write-Host "Does the subject's hair or facial hair change across these photos?" -ForegroundColor White
        Write-Host "  Photos taken over months or years often vary: beard grown out, hair cut." -ForegroundColor DarkGray
        Write-Host "  Yes -> those get described, so you can prompt for each look later." -ForegroundColor DarkGray
        Write-Host "  No  -> they are left out and become part of the trigger word itself." -ForegroundColor DarkGray
        Write-Host ""
        $VariableAppearance = Read-YesNo "Hair or facial hair varies?" -Default $false
    }

    Write-Host ""
    Write-Host "  Optional extra guidance passed to the captioner." -ForegroundColor DarkGray
    Write-Host "  Example: note the lighting direction" -ForegroundColor DarkGray
    $instructionAnswer = (Read-Host "Extra guidance [none]").Trim()
    if ($instructionAnswer) { $Instruction = $instructionAnswer }

    Write-Host ""
    Write-Host "  [ok] $(if ($Tagify) { 'tags' } else { 'prose' })" -ForegroundColor Green
}

# --- Step 7: Summary --------------------------------------------------------

$projectDir = Join-Path $BaseDir $ConceptName
# 'img' rather than 'datasets': kohya_ss projects are laid out as
# <project>/img, <project>/log, <project>/model, and the old name produced
# paths like datasets\mikey\datasets\set_r5 once the default root became
# ./datasets.
$datasetsRootDir = Join-Path $projectDir "img"
$datasetSetName = "set_r$TrainingRate"
$datasetSetDir = Join-Path $datasetsRootDir $datasetSetName
$trainDir = Join-Path $datasetSetDir "${TrainingRate}_${ConceptName}"
$logDir = Join-Path $projectDir "log"
$modelDir = Join-Path $projectDir "model"

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║                       SUMMARY                             ║" -ForegroundColor White
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor White
Write-Host ""
Write-Host "  Concept Name:         $ConceptName" -ForegroundColor White
Write-Host "  Concept Type:         $ConceptType" -ForegroundColor White
Write-Host "  Source Images:        $imageCount images" -ForegroundColor White
Write-Host "  Resize:               $(if ($resizeImages) { "Long edge = ${resizeLongEdge}px" } else { "No resizing" })" -ForegroundColor White
Write-Host "  Training Rate:        $TrainingRate repeats/image" -ForegroundColor White
Write-Host "  Steps Per Epoch:      $totalSteps" -ForegroundColor White
Write-Host ""
Write-Host "  Captioning:           Ollama$(if ($Model) { " / $Model" } else { ' / auto-selected model' })" -ForegroundColor White
Write-Host "  Caption style:        $(if ($Tagify) { 'comma-separated tags' } else { 'prose clauses' })" -ForegroundColor White
if ($ConceptType -eq 'character') {
    Write-Host "  Hair/facial hair:     $(if ($VariableAppearance) { 'varies - will be described' } else { 'constant - absorbed by the trigger' })" -ForegroundColor White
}
if ($Instruction) {
    Write-Host "  Extra guidance:       $Instruction" -ForegroundColor White
}
Write-Host ""
Write-Host "  Output Structure:" -ForegroundColor White
Write-Host "    $projectDir\" -ForegroundColor DarkGray
Write-Host "    -- img\" -ForegroundColor DarkGray
Write-Host "    -  -- $datasetSetName\" -ForegroundColor DarkGray
Write-Host "    -     -- ${TrainingRate}_${ConceptName}\" -ForegroundColor DarkGray
Write-Host "    -        -- 1.jpg + 1.txt" -ForegroundColor DarkGray
Write-Host "    -        -- 2.jpg + 2.txt" -ForegroundColor DarkGray
Write-Host "    -        -- ... ($imageCount total)" -ForegroundColor DarkGray
Write-Host "    -- log\" -ForegroundColor DarkGray
Write-Host "    -- model\" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Trainer path to use:" -ForegroundColor White
Write-Host "    Training images folder = $datasetSetDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Source images are copied, never modified: $SourceImagesPath" -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-YesNo "Proceed with dataset preparation?" -Default $true
if (-not $confirm) {
    Write-Host ""
    Write-Host "Cancelled." -ForegroundColor Yellow
    pause
    return
}

# --- Step 8: Create Folder Structure ----------------------------------------

Write-Host ""
Write-Host "Creating folder structure..." -ForegroundColor Cyan

if (Test-Path $trainDir) {
    Write-Host ""
    Write-Host "  ⚠ Training directory already exists: $trainDir" -ForegroundColor Yellow
    $keepOld = Read-YesNo "Keep the existing dataset (rename it with a timestamp)?" -Default $true
    if ($keepOld) {
        $createdTime = (Get-Item $trainDir).CreationTime.ToString("yyyy-MM-dd_HH-mm-ss")
        $archivedName = "${TrainingRate}_${ConceptName}_$createdTime"
        Rename-Item -Path $trainDir -NewName $archivedName
        Write-Host "  [ok] Renamed existing dataset to: $archivedName" -ForegroundColor Green
    } else {
        Remove-Item -Path $trainDir -Recurse -Force
        Write-Host "  [ok] Removed existing training directory" -ForegroundColor Green
    }
}

New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
New-Item -ItemType Directory -Path $datasetsRootDir -Force | Out-Null
New-Item -ItemType Directory -Path $datasetSetDir -Force | Out-Null
New-Item -ItemType Directory -Path $trainDir -Force | Out-Null
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $modelDir -Force | Out-Null

Write-Host "  [ok] Created $projectDir" -ForegroundColor Green
Write-Host "  [ok] Created $datasetsRootDir" -ForegroundColor Green
Write-Host "  [ok] Created $datasetSetDir" -ForegroundColor Green
Write-Host "  [ok] Created $trainDir" -ForegroundColor Green
Write-Host "  [ok] Created $logDir" -ForegroundColor Green
Write-Host "  [ok] Created $modelDir" -ForegroundColor Green

# --- Step 9: Copy/Rename (and Optional Resize) ------------------------------

Write-Host ""
if ($resizeImages) {
    Write-Host "Copying, resizing, and renaming images..." -ForegroundColor Cyan
}
else {
    Write-Host "Copying and renaming images..." -ForegroundColor Cyan
}

$jobs = @()
$counter = 1
foreach ($imgFile in $imageAnalysis.Files) {
    $sourceExt = $imgFile.Extension.ToLower()
    # Convert PNG/BMP/WebP to JPEG to avoid lossless bloat after resize.
    $destExt = if ($sourceExt -in @('.png', '.bmp', '.webp')) { '.jpg' } else { $sourceExt }
    $jobs += @{
        source      = $imgFile.FullName
        destination = (Join-Path $trainDir "$counter$destExt")
        long_edge   = $resizeLongEdge
    }
    $counter++
}

# One call for the whole batch; Python starts once rather than per image.
$prepared = @(Invoke-ImagePreparation -Jobs $jobs -PythonExe $script:PythonExe)

$resizedCount = @($prepared | Where-Object { $_.status -eq 'resized' }).Count
$rotatedCount = @($prepared | Where-Object { $_.status -eq 'rotated' }).Count
$noResizeNeededCount = @($prepared | Where-Object { $_.status -eq 'copied' }).Count
$resizeFailedCount = @($prepared | Where-Object { $_.status -eq 'failed' }).Count

Write-Host "  [ok] All $imageCount images copied and renamed" -ForegroundColor Green
if ($resizeImages) {
    Write-Host "  [ok] Resized images: $resizedCount" -ForegroundColor Green
    Write-Host "  [ok] Already <= ${resizeLongEdge}px (copied as-is): $noResizeNeededCount" -ForegroundColor Green
}
if ($rotatedCount -gt 0) {
    Write-Host "  [ok] Rotated to match EXIF orientation: $rotatedCount" -ForegroundColor Green
}
if ($resizeImages) {
    if ($resizeFailedCount -gt 0) {
        Write-Host "  ⚠ Resize unsupported/failed for $resizeFailedCount images; copied original files." -ForegroundColor Yellow
    }
}

# --- Step 10: Autocaption ---------------------------------------------------

Write-Host ""
Write-Host "Running autocaptioning..." -ForegroundColor Cyan

if (-not (Test-Path $CaptionScript)) {
    throw "caption.ps1 not found at $CaptionScript"
}

# $trainDir already holds copies this script made from the source folder, so
# captioning writes there directly. The source images are never touched.
$captionArgs = @(
    '-ImageDir', $trainDir
    '-Concept', $ConceptName
    '-Model', $Model
    '-InPlace'
    '-Overwrite'
)
if ($OllamaEndpoint) { $captionArgs += @('-OllamaEndpoint', $OllamaEndpoint) }
if ($ConceptType) { $captionArgs += @('-ConceptType', $ConceptType) }
if ($Instruction) { $captionArgs += @('-Instruction', $Instruction) }
if ($Tagify) { $captionArgs += '-Tagify' }
if ($VariableAppearance) { $captionArgs += '-VariableAppearance' }
if ($Provider -eq 'local') { $captionArgs += @('-LocalModel', $LocalModel) }

& pwsh -NoProfile -File $CaptionScript @captionArgs

if ($LASTEXITCODE -ne 0) {
    throw ("Captioning failed (exit code $LASTEXITCODE). The images were copied " +
        "to $trainDir, so you can re-run captioning there without redoing this setup.")
}

Write-Host "  [ok] Captions generated: captions.json / captions.csv" -ForegroundColor Green

# --- Step 11: Launch Review UI ----------------------------------------------

Write-Host ""
Write-Host "Launching caption review UI..." -ForegroundColor Cyan

if (-not (Test-Path $ReviewScript)) {
    throw "run-review-ui.ps1 not found at $ReviewScript"
}

Write-Host ""
Write-Host "  The review UI will open at http://127.0.0.1:$ReviewPort" -ForegroundColor Green
Write-Host "  Step through the images, correct any captions, then click End Task." -ForegroundColor DarkGray
Write-Host "  This window waits here until you do, then exports the .txt files." -ForegroundColor DarkGray
Write-Host ""

& pwsh -NoProfile -File $ReviewScript `
    -ImageDir $trainDir `
    -Concept $ConceptName `
    -Port $ReviewPort

if ($LASTEXITCODE -ne 0) {
    throw ("Review UI exited with code $LASTEXITCODE. Captions are already saved in " +
        "$trainDir; you can review them later with scripts/run-review-ui.ps1.")
}

# --- Step 12: Ensure captions are exported to .txt --------------------------

Write-Host ""
$existingTxtCount = (Get-ChildItem -Path $trainDir -Filter "*.txt" -File -ErrorAction SilentlyContinue | Measure-Object).Count

if ($existingTxtCount -gt 0) {
    Write-Host "Captions already exported by review UI: $existingTxtCount .txt files found." -ForegroundColor Green
} else {
    Write-Host "No .txt captions found after review UI; running fallback export..." -ForegroundColor Yellow
    if (-not (Test-Path $ExportScript)) {
        throw "export-captions.ps1 not found at $ExportScript"
    }

    $captionsJsonPath = Join-Path $trainDir "captions.json"
    if (-not (Test-Path $captionsJsonPath)) {
        throw "captions.json not found at $captionsJsonPath"
    }

    & pwsh -NoProfile -File $ExportScript `
        -CaptionsJson $captionsJsonPath `
        -Overwrite

    if ($LASTEXITCODE -ne 0) {
        throw "Export captions failed (exit code $LASTEXITCODE)"
    }
    Write-Host "  [ok] Captions exported: $trainDir\*.txt" -ForegroundColor Green
}

# --- Step 13: Create Info File -----------------------------------------------

$infoContent = @"
LoRA Dataset: $ConceptName
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Configuration:
- Concept Type: $ConceptType
- Image Count: $imageCount
- Resize: $(if ($resizeImages) { "Long edge = ${resizeLongEdge}px" } else { "No resizing" })
- Training Rate: $TrainingRate
- Steps Per Epoch: $totalSteps

Source Images: $SourceImagesPath

Next Steps:
1. Captions generated automatically (captions.json/captions.csv) in $trainDir
2. Review/edit captions in the browser UI (launched automatically)
3. Captions exported to per-image .txt files in $trainDir
4. In trainer UI, set "Training images folder" to: $datasetSetDir
5. Close the UI when finished; proceed to training (kohya_ss config step)
6. Use $modelDir as the default output folder for configs and trained .safetensors

Notes:
- Captions are tag-based and begin with concept name: $ConceptName
- Validation flags (if any) are recorded in caption_issues.csv
"@

$infoPath = Join-Path $projectDir "dataset_info.txt"
$infoContent | Set-Content -Path $infoPath -Encoding UTF8

Write-Host "  [ok] Created dataset info file" -ForegroundColor Green

# --- Final Output -----------------------------------------------------------

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Dataset Preparation Complete!                ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Your dataset is ready at:" -ForegroundColor White
Write-Host "  $projectDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "What's been set up:" -ForegroundColor White
Write-Host "  [ok] Folder structure created" -ForegroundColor Green
Write-Host "  [ok] $imageCount images copied and renamed (1, 2, 3, ...)" -ForegroundColor Green
if ($resizeImages) {
    Write-Host "  [ok] Resize applied to $resizedCount images (long edge = ${resizeLongEdge}px)" -ForegroundColor Green
}
Write-Host "  [ok] Training rate: $TrainingRate ($totalSteps steps/epoch)" -ForegroundColor Green
Write-Host "  [ok] Captions generated: $trainDir\\captions.json / captions.csv" -ForegroundColor Green
Write-Host "  [ok] Training images folder for trainer: $datasetSetDir" -ForegroundColor Green
Write-Host "  [ok] Log folder ready: $logDir" -ForegroundColor Green
Write-Host "  [ok] Model output folder ready: $modelDir" -ForegroundColor Green
Write-Host "  [ok] Review UI launched at the chosen port (ctrl+c to stop when done)" -ForegroundColor Green
Write-Host ""

$openExplorer = Read-YesNo "Open dataset folder in Explorer?" -Default $true
if ($openExplorer) {
    Open-InFileManager -Path $trainDir
}

Write-Host ""
Write-Host "Dataset preparation complete! 🎉" -ForegroundColor Green
Write-Host ""
pause
