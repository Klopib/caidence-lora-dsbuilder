<#
.SYNOPSIS
    Caption providers and caption post-processing for LoRA dataset building.

.DESCRIPTION
    Exposes a single entry point, Get-ImageCaption, which dispatches to a
    captioning backend:

      ollama    An instruction-following vision model served by Ollama.
                The prompt carries the captioning rules, so no post-processing
                is needed beyond trimming model chatter.

      florence  A Florence-2 captioning API. Florence cannot take instructions,
                so its prose output is normalised here instead.

    Keeping both behind one interface means the pipeline is not coupled to a
    single model, and Florence stays available as an offline fallback.
#>

Set-StrictMode -Version Latest

# Phrases models habitually open a caption with. Useless in a training caption:
# every image is "an image", so the words carry no signal and only dilute the
# tokens that matter.
# Applied repeatedly, so a nested opener like "The image is a photo of ..."
# peels off one layer per pass rather than needing a single pattern for every
# combination. Each alternative deliberately stops before the following article.
$script:PreamblePattern =
    '^\s*(?:' +
    '(?:this|that|the)\s+(?:image|photo|picture|photograph)\s+(?:is|shows|depicts|features|captures)\s+' +
    '|(?:a|an)\s+(?:close-?up\s+|wide\s+|medium\s+)?(?:photo|image|picture|portrait|selfie|photograph|shot|view)\s+of\s+' +
    '|here\s+is\s+(?:a|an|the)\s+caption\s*:?\s*' +
    '|caption\s*:\s*' +
    ')'


function Remove-CaptionPreamble {
    <#
    .SYNOPSIS
        Strips "The image is a photo of ..." style openers and stray quoting.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Caption)

    if ([string]::IsNullOrWhiteSpace($Caption)) { return '' }

    $text = $Caption.Trim()

    # Reasoning-model leakage: drop a <think>...</think> block if one survives.
    $text = $text -replace '(?is)<think>.*?</think>', ''

    # Models sometimes wrap the whole caption in quotes. The curly quote pair is
    # the curly quote pair, written as escapes so this file stays pure ASCII:
    # PowerShell passes a single-quoted string through verbatim and .NET's
    # regex engine resolves the escapes itself.
    $text = $text -replace '^[\s"“”''`]+', ''
    $text = $text -replace '[\s"“”''`]+$', ''

    # Strip the opener repeatedly: "This image shows a photo of ..." nests.
    for ($i = 0; $i -lt 3; $i++) {
        $stripped = $text -replace "(?i)$script:PreamblePattern", ''
        if ($stripped -eq $text) { break }
        $text = $stripped
    }

    return ($text -replace '\s+', ' ').Trim()
}


function Convert-ToTags {
    <#
    .SYNOPSIS
        Flattens a prose caption into de-duplicated comma-separated tags.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Caption)

    if ([string]::IsNullOrWhiteSpace($Caption)) { return '' }

    $clean = ($Caption -replace '[\r\n]', ' ') -replace '[\.;]', ',' -replace '\s+', ' '
    $tags = foreach ($part in ($clean -split ',| and ')) {
        $tag = $part.Trim().ToLowerInvariant() -replace '^(a|an|the)\s+', ''
        if ($tag) { $tag }
    }

    return (($tags | Select-Object -Unique) -join ', ')
}


function Get-CaptionJaccard {
    <#
    .SYNOPSIS
        Jaccard similarity between two captions, compared as sets of clauses.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$A,
        [AllowEmptyString()][string]$B
    )

    # Built by Add rather than the collection constructor: passing an empty
    # array makes the HashSet overload ambiguous (IEnumerable vs IComparer).
    $toSet = {
        param([string]$Text)
        $set = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($part in ($Text -split '[,;\.]+')) {
            $clause = $part.Trim().ToLowerInvariant()
            if ($clause) { [void]$set.Add($clause) }
        }
        return , $set
    }

    $setA = & $toSet $A
    $setB = & $toSet $B

    $union = [System.Collections.Generic.HashSet[string]]::new($setA)
    $union.UnionWith($setB)
    if ($union.Count -eq 0) { return 0.0 }

    $intersection = [System.Collections.Generic.HashSet[string]]::new($setA)
    $intersection.IntersectWith($setB)

    return [double]$intersection.Count / $union.Count
}


function Test-CaptionSet {
    <#
    .SYNOPSIS
        Flags captions that are empty, too short, too long, or near-duplicates.

    .DESCRIPTION
        Length is judged by the measure that suits the caption style. Tag-style
        captions are counted in clauses; prose captions are counted in words.

        Counting clauses in prose produced a flag on most of a healthy dataset:
        a 30-word caption with two commas looks like a "2 clause" caption, which
        says nothing about whether it is too short.

    .OUTPUTS
        Zero or more objects with 'image' and 'issue' properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Captions,
        [ValidateSet('prose', 'tags')][string]$Style = 'prose',
        [string]$ConceptType = 'character',
        [switch]$VariableAppearance,
        [int]$MinClauses = 4,
        [int]$MaxClauses = 40,
        [int]$MinWords = 8,
        [int]$MaxWords = 80,
        [double]$DuplicateThreshold = 0.85
    )

    $issues = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Captions.Count; $i++) {
        $caption = [string]$Captions[$i].final_caption

        if ([string]::IsNullOrWhiteSpace($caption)) {
            $issues.Add([pscustomobject]@{ image = $Captions[$i].image; issue = 'Empty caption' })
            continue
        }

        if ($Style -eq 'tags') {
            $clauses = @($caption -split '[,;\.]+' | Where-Object { $_.Trim() })
            if ($clauses.Count -lt $MinClauses -or $clauses.Count -gt $MaxClauses) {
                $issues.Add([pscustomobject]@{
                        image = $Captions[$i].image
                        issue = "Tag count=$($clauses.Count) (expected $MinClauses-$MaxClauses)"
                    })
            }
        }
        else {
            $words = @($caption -split '\s+' | Where-Object { $_ })
            if ($words.Count -lt $MinWords -or $words.Count -gt $MaxWords) {
                $issues.Add([pscustomobject]@{
                        image = $Captions[$i].image
                        issue = "Word count=$($words.Count) (expected $MinWords-$MaxWords)"
                    })
            }
        }

        # Instruction-following is not guaranteed: a model occasionally describes
        # a fixed identity trait despite being told not to. Flag it rather than
        # editing the caption - cutting clauses out of generated prose is what
        # produced the truncation bug this validator exists to catch.
        # Grooming only hurts when it is constant across the set. When it
        # varies, captioning it is the whole point, so flagging it would tell
        # the user to delete exactly what they asked for.
        $traitPattern = if ($VariableAppearance) {
            '(?i)\b(eye colour|eye color|skin tone|complexion)\b'
        }
        else {
            '(?i)\b(hair|hairstyle|beard|stubble|moustache|mustache|goatee|eye colour|eye color)\b'
        }

        if ($ConceptType -eq 'character') {
            $trait = [regex]::Match($caption, $traitPattern)
            if ($trait.Success) {
                $issues.Add([pscustomobject]@{
                        image = $Captions[$i].image
                        issue = "Mentions fixed identity trait '$($trait.Value)' - consider removing"
                    })
            }
        }

        for ($j = $i + 1; $j -lt $Captions.Count; $j++) {
            $similarity = Get-CaptionJaccard -A $caption -B ([string]$Captions[$j].final_caption)
            if ($similarity -gt $DuplicateThreshold) {
                $issues.Add([pscustomobject]@{
                        image = $Captions[$i].image
                        issue = "Too similar to $($Captions[$j].image) (Jaccard=$('{0:N2}' -f $similarity))"
                    })
            }
        }
    }

    return $issues.ToArray()
}


function Build-CaptionPrompt {
    <#
    .SYNOPSIS
        Builds the instruction prompt sent to a vision language model.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Trigger,
        [AllowEmptyString()][string]$Instruction,
        [string]$ConceptType = 'character',
        [switch]$Tagify,

        # Set when the subject's grooming or build changes across the dataset,
        # e.g. photos taken over years with different hair or facial hair.
        # See the LEAVE OUT / DESCRIBE wording below for why it matters.
        [switch]$VariableAppearance
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    # The objective is stated before the rules, deliberately. A capable model
    # that understands WHY a detail is excluded can judge the cases this prompt
    # never enumerates; a blacklist of banned words cannot. Earlier versions
    # listed "hair, beard, stubble ..." and the model still volunteered "light
    # five o'clock shadow", which no list would have caught.
    $lines.Add('You are writing one caption for an image in a LoRA fine-tuning dataset.')
    $lines.Add('')
    $lines.Add('How the caption is used, so you can judge what belongs in it:')
    $lines.Add("every image in this set is tagged '$Trigger'. During training the model")
    $lines.Add("binds whatever stays CONSTANT across the set to '$Trigger', and treats")
    $lines.Add('whatever the captions describe as VARIABLE, controllable later by prompt.')
    $lines.Add('')
    $lines.Add('So describe what changes from photo to photo, and leave out what does not.')
    $lines.Add('')

    if ($ConceptType -eq 'character') {
        $lines.Add('DESCRIBE: pose, gaze, expression, clothing and accessories, what the')
        $lines.Add('subject is doing or holding, framing and crop, camera angle, lighting,')
        $lines.Add('setting and background.')
        $lines.Add('')
        if ($VariableAppearance) {
            # Grooming that changes between photos has to be captioned. Left
            # uncaptioned, the same token carries contradictory evidence and
            # the model averages it, producing facial hair you cannot control.
            # Captioned, each state becomes promptable.
            $lines.Add('ALSO DESCRIBE hair length and style, and facial hair, because these')
            $lines.Add('change across this set. Naming them lets each state be requested later')
            $lines.Add("('$Trigger with a full beard', '$Trigger clean-shaven'). Leaving them")
            $lines.Add('out would make the model average the versions together.')
            $lines.Add('')
            $lines.Add('LEAVE OUT what never changes: face shape and features, eye colour and')
            $lines.Add("skin tone. That is the identity '$Trigger' must own.")
        }
        else {
            $lines.Add('LEAVE OUT anything about the person that is the same in every photo:')
            $lines.Add('face shape and features, hair, facial hair, eye colour, skin tone, build,')
            $lines.Add("age. That is the identity '$Trigger' must own. Describing it teaches the")
            $lines.Add('model those traits are optional, which weakens the likeness.')
        }
    }
    else {
        $lines.Add("DESCRIBE the $ConceptType itself in concrete visual detail: shape, colour,")
        $lines.Add('material, construction, condition, plus framing, lighting and setting.')
        $lines.Add('')
        $lines.Add('LEAVE OUT anything incidental to it, such as who is wearing or holding it,')
        $lines.Add('unless that is what varies across the set.')
    }

    $lines.Add('')
    $lines.Add('Accuracy matters more than richness. A confidently wrong detail teaches the')
    $lines.Add('model something false about the concept. Describe only what you can actually')
    $lines.Add('see; never guess at age, mood, names, places, or text and brands you cannot')
    $lines.Add('read clearly. If you are unsure what something is, describe it plainly or')
    $lines.Add('omit it.')
    $lines.Add('')
    $lines.Add('Vary your wording between images. Repeating the same phrasing across the set')
    $lines.Add('teaches the model the phrasing instead of the subject.')
    $lines.Add('')
    $lines.Add('FORMAT:')
    $lines.Add("- Start with '$Trigger', then what the subject is doing or wearing.")

    if ($Tagify) {
        $lines.Add('- Lowercase comma-separated tags on one line. No sentences.')
    }
    else {
        $lines.Add('- One line, 15 to 40 words, clauses separated by commas.')
        $lines.Add('- No full sentences, semicolons, bullet points or quotation marks.')
    }

    $lines.Add("- No preamble: never open with 'The image', 'A photo of', 'This picture',")
    $lines.Add("  '$Trigger is shown' or '$Trigger is captured'.")
    $lines.Add('- Output the caption only, with no explanation or commentary.')

    if (-not [string]::IsNullOrWhiteSpace($Instruction)) {
        $lines.Add('')
        $lines.Add("ALSO: $Instruction")
    }

    return ($lines -join "`n")
}


function Get-OllamaModelCapability {
    <#
    .SYNOPSIS
        Returns the capability list Ollama reports for a model.

    .DESCRIPTION
        Ollama's /api/show returns a 'capabilities' array such as
        @('completion', 'vision', 'tools', 'thinking'). This is the
        authoritative way to tell whether a model can accept images; guessing
        from the model name is unreliable because vision and text variants are
        often named alike.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Model,
        [string]$Endpoint = 'http://localhost:11434',
        [int]$TimeoutSec = 30
    )

    try {
        $body = @{ model = $Model } | ConvertTo-Json -Compress
        $info = Invoke-RestMethod -Method Post -Uri "$Endpoint/api/show" `
            -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    }
    catch {
        return @()
    }

    $prop = $info.PSObject.Properties['capabilities']
    if (-not $prop -or -not $prop.Value) { return @() }
    return @($prop.Value)
}


function Get-OllamaVisionModelList {
    <#
    .SYNOPSIS
        Lists every installed Ollama model that can accept images.

    .DESCRIPTION
        Probes each installed model's capabilities. Used to offer a pick-list
        rather than asking someone to type a model name: a name typed by hand
        is easy to get wrong, and a text-only model typed correctly still
        fails later.

    .OUTPUTS
        Array of model names, possibly empty.
    #>
    [CmdletBinding()]
    param(
        [string]$Endpoint = 'http://localhost:11434',
        [int]$TimeoutSec = 30
    )

    $tags = Invoke-RestMethod -Method Get -Uri "$Endpoint/api/tags" -TimeoutSec $TimeoutSec
    $installed = @($tags.models | ForEach-Object { $_.name })

    return @(
        $installed | Where-Object {
            (Get-OllamaModelCapability -Model $_ -Endpoint $Endpoint -TimeoutSec $TimeoutSec) -contains 'vision'
        }
    )
}


function Get-OllamaVisionModel {
    <#
    .SYNOPSIS
        Finds an installed Ollama model that can accept images.

    .DESCRIPTION
        Returns the preferred model when it is installed and vision-capable,
        otherwise the first installed model that reports the 'vision'
        capability. Returns $null when the host has no vision model.

        This exists so the tool works with whatever vision model a user already
        has, instead of insisting on one specific name.

    .OUTPUTS
        The model name, or $null.
    #>
    [CmdletBinding()]
    param(
        [string]$Endpoint = 'http://localhost:11434',
        [string[]]$Preferred = @(),
        [int]$TimeoutSec = 30
    )

    $tags = Invoke-RestMethod -Method Get -Uri "$Endpoint/api/tags" -TimeoutSec $TimeoutSec
    $installed = @($tags.models | ForEach-Object { $_.name })
    if ($installed.Count -eq 0) { return $null }

    # Try the preferred names first so a known-good default wins, and so the
    # common case costs one /api/show call rather than one per installed model.
    foreach ($want in $Preferred) {
        if (-not $want) { continue }
        $match = $installed | Where-Object { $_ -eq $want -or $_ -like "$want`:*" } | Select-Object -First 1
        if ($match) {
            $caps = Get-OllamaModelCapability -Model $match -Endpoint $Endpoint -TimeoutSec $TimeoutSec
            if ($caps -contains 'vision') { return $match }
        }
    }

    foreach ($candidate in $installed) {
        $caps = Get-OllamaModelCapability -Model $candidate -Endpoint $Endpoint -TimeoutSec $TimeoutSec
        if ($caps -contains 'vision') { return $candidate }
    }

    return $null
}


function Invoke-LocalCaption {
    <#
    .SYNOPSIS
        Captions a batch of images in a local Python process, with no service.

    .DESCRIPTION
        Runs lib/local_captioner.py, which loads a quantised vision model
        through llama-cpp-python. The whole batch goes in one call so the model
        is loaded once rather than per image.

        This is the default provider: it needs no Ollama, no container and no
        separately installed service, only a one-time model download.

    .OUTPUTS
        One object per image with image, caption and error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$Model = 'qwen2.5-vl-3b',
        [int]$MaxTokens = 160,
        [double]$Temperature = 0.2
    )

    $request = @{
        action      = 'caption'
        model       = $Model
        prompt      = $Prompt
        images      = $Paths
        max_tokens  = $MaxTokens
        temperature = $Temperature
    } | ConvertTo-Json -Depth 5 -Compress

    # Progress is written to stderr by the script, so it shows as it goes while
    # stdout stays a single JSON document.
    $response = $request | & $PythonExe $ScriptPath
    if ($LASTEXITCODE -ne 0) { throw "Local captioner failed (exit $LASTEXITCODE)." }

    $parsed = $response | ConvertFrom-Json
    if (-not $parsed.ok) { throw "Local captioner error: $($parsed.error)" }

    return $parsed.results
}


function Invoke-OllamaCaption {
    <#
    .SYNOPSIS
        Captions one image with an instruction-following vision model via Ollama.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model = 'qwen3.5',
        [string]$Endpoint = 'http://localhost:11434',
        [int]$TimeoutSec = 300,
        [double]$Temperature = 0.2
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    $payload = @{
        model   = $Model
        prompt  = $Prompt
        images  = @([Convert]::ToBase64String($bytes))
        stream  = $false
        # Vision models in this family are reasoning models. Left on, the chain
        # of thought leaks into the caption ("The user wants a concise ...").
        think   = $false
        options = @{ temperature = $Temperature }
    } | ConvertTo-Json -Depth 4 -Compress

    $response = Invoke-RestMethod -Method Post -Uri "$Endpoint/api/generate" `
        -ContentType 'application/json' -Body $payload -TimeoutSec $TimeoutSec

    if ($response.PSObject.Properties['error'] -and $response.error) {
        throw "Ollama error: $($response.error)"
    }

    return [string]$response.response
}


function ConvertTo-FinalCaption {
    <#
    .SYNOPSIS
        Turns one raw model response into a finished caption record.

    .DESCRIPTION
        Shared by every provider, so a caption gets the same treatment whether
        it came back one at a time or as part of a batch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Image,
        [AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory)][string]$Trigger,
        [switch]$Tagify
    )

    $final = Remove-CaptionPreamble -Caption $Raw
    if ($Tagify) { $final = Convert-ToTags -Caption $final }

    # Normalise the trigger's spelling. Models capitalise it at the start of a
    # caption and lower-case it elsewhere; "Mikey" and "mikey" are two
    # different tokens, so an inconsistent trigger trains the concept onto both.
    if ($final) {
        $final = [regex]::Replace($final, "(?i)\b$([regex]::Escape($Trigger))\b", $Trigger)
    }

    # Guarantee the trigger is present so the token actually trains.
    if ($final -and $final -notmatch "\b$([regex]::Escape($Trigger))\b") {
        $final = "$Trigger, $final"
    }

    return [pscustomobject]@{
        image         = $Image
        raw_caption   = ([string]$Raw).Trim()
        final_caption = ([string]$final).Trim()
    }
}


function Get-ImageCaption {
    <#
    .SYNOPSIS
        Captions one image with the selected provider and returns raw + final text.

    .OUTPUTS
        PSCustomObject with image, raw_caption and final_caption.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Trigger,
        [AllowEmptyString()][string]$Instruction,
        [string]$ConceptType = 'character',
        [switch]$Tagify,
        [switch]$VariableAppearance,
        [hashtable]$ProviderOptions = @{}
    )

    $raw = ''
    $final = ''

    $prompt = Build-CaptionPrompt -Trigger $Trigger -Instruction $Instruction `
        -ConceptType $ConceptType -Tagify:$Tagify -VariableAppearance:$VariableAppearance
    $raw = Invoke-OllamaCaption -Path $Path -Prompt $prompt @ProviderOptions

    # The prompt already enforced the rules; only tidy model chatter.
    $final = Remove-CaptionPreamble -Caption $raw
    if ($Tagify) { $final = Convert-ToTags -Caption $final }

    # Normalise the trigger's spelling. Models capitalise it at the start of a
    # caption and lower-case it elsewhere; "Mikey" and "mikey" are two different
    # tokens, so an inconsistent trigger trains the concept onto both.
    if ($final) {
        $final = [regex]::Replace($final, "(?i)\b$([regex]::Escape($Trigger))\b", $Trigger)
    }

    # Guarantee the trigger is present so the token actually trains.
    if ($final -and $final -notmatch "\b$([regex]::Escape($Trigger))\b") {
        $final = "$Trigger, $final"
    }

    return [pscustomobject]@{
        image         = $Path
        raw_caption   = ([string]$raw).Trim()
        final_caption = ([string]$final).Trim()
    }
}


Export-ModuleMember -Function @(
    'Get-OllamaModelCapability'
    'Get-OllamaVisionModel'
    'Get-OllamaVisionModelList'
    'Remove-CaptionPreamble'
    'Convert-ToTags'
    'Get-CaptionJaccard'
    'Test-CaptionSet'
    'Build-CaptionPrompt'
    'Invoke-LocalCaption'
    'Invoke-OllamaCaption'
    'ConvertTo-FinalCaption'
    'Get-ImageCaption'
)
