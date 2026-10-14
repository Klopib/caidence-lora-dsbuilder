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

# Words indicating a clause is about the setting rather than the subject.
$script:BackgroundPattern = 'background|backdrop|wall|door|window|room|house|building|tree|sky|floor|ceiling'


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


function Set-CaptionSubject {
    <#
    .SYNOPSIS
        Names the training subject once, instead of substituting every pronoun.

    .DESCRIPTION
        Replaces the FIRST generic subject noun ("a man", "the woman") with the
        trigger word and leaves later references as ordinary pronouns.

        The previous implementation rewrote every pronoun, producing
        "mikey is looking at the camera with a smile on mikey's lips" and
        "mikey appears to be in mikey's late 30s". Repeating the trigger in
        every clause also teaches the model the phrasing rather than the face.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Caption,
        [Parameter(Mandatory)][string]$Trigger
    )

    if ([string]::IsNullOrWhiteSpace($Caption)) { return '' }

    $subject = '(?:young\s+|old\s+|elderly\s+|middle-aged\s+)?(?:man|woman|boy|girl|person|guy|lady|male|female)'
    $text = $Caption

    # Replaces only the FIRST match. Note [regex]::Replace() has no static
    # overload taking a count - a 4th argument is read as RegexOptions, so
    # passing 1 silently means IgnoreCase and replaces every match instead.
    # $Subject, not $Input: $Input is an automatic variable and binding it
    # as a parameter silently yields an empty result.
    $replaceFirst = {
        param([string]$Subject, [string]$Pattern, [string]$Replacement)
        $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $rx.Replace($Subject, $Replacement, 1)
    }

    # Possessive first: "a man's face" -> "<trigger>'s face".
    $text = & $replaceFirst $text "\b(?:a|an|the)\s+$subject(?='s\b)" $Trigger

    # Then the plain noun, article included so "The man" does not become "The <trigger>".
    if ($text -notmatch [regex]::Escape($Trigger)) {
        $text = & $replaceFirst $text "\b(?:a|an|the)\s+$subject\b" $Trigger
    }

    # Bare noun with no article, still only the first occurrence.
    if ($text -notmatch [regex]::Escape($Trigger)) {
        $text = & $replaceFirst $text "\b$subject\b" $Trigger
    }

    # Any later "the man" is a repeat mention; a pronoun reads better.
    $text = $text -replace "(?i)\bthe\s+$subject\b", 'he'

    $text = ($text -replace '\s+', ' ').Trim()

    # Substituting mid-caption can leave a lower-case word opening a sentence
    # ("... blue t-shirt. he is wearing ..."). Restore sentence capitalisation.
    $text = [regex]::Replace($text, '(^|[.!?]\s+)(\p{Ll})', {
            param($m)
            $m.Groups[1].Value + $m.Groups[2].Value.ToUpperInvariant()
        })

    # The trigger itself keeps its given spelling even at a sentence start.
    return [regex]::Replace($text, "(?i)\b$([regex]::Escape($Trigger))\b", $Trigger)
}


function Limit-CaptionContent {
    <#
    .SYNOPSIS
        Drops background detail from a caption when asked to focus on the subject.

    .DESCRIPTION
        Splits on sentences for prose and on commas for tag-style input, then
        removes only the clauses that mention the setting.

        The previous implementation always split on commas. A prose caption
        often contains a single comma, so one background word deleted
        everything after it - captions were silently truncated mid-sentence
        ("... <trigger> has short") on every run using the default instruction.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Caption,
        [AllowEmptyString()][string]$Instruction
    )

    if ([string]::IsNullOrWhiteSpace($Caption)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Instruction)) { return $Caption }

    $wantsSubjectFocus = $Instruction -match
        '(?i)ignore background|less background|no background|focus on (?:the )?(?:subject|person|man|woman)'
    if (-not $wantsSubjectFocus) { return $Caption }

    # Tag-style input has many commas and no sentence terminators.
    $isTagStyle = ($Caption -notmatch '[.!?](\s|$)') -and (($Caption -split ',').Count -ge 3)

    if ($isTagStyle) {
        $parts = $Caption -split ',\s*'
        $joiner = ', '
    }
    else {
        # Keep the terminator attached to each sentence.
        $parts = [regex]::Split($Caption, '(?<=[.!?])\s+')
        $joiner = ' '
    }

    $kept = @($parts | Where-Object { $_ -and ($_ -notmatch "(?i)$script:BackgroundPattern") })

    # Never return nothing: a caption about only the background still beats an
    # empty caption, which would silently corrupt the dataset.
    if ($kept.Count -eq 0) { return $Caption }

    return (($kept -join $joiner) -replace '\s+', ' ').Trim()
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
        if ($ConceptType -eq 'character') {
            $trait = [regex]::Match($caption, '(?i)\b(hair|hairstyle|beard|stubble|moustache|mustache|goatee|eye colour|eye color)\b')
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
        [switch]$Tagify
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Write a single training caption for an image in a LoRA dataset.')
    $lines.Add('Rules:')
    $lines.Add("- Refer to the subject as '$Trigger'.")

    if ($ConceptType -eq 'character') {
        # Identity traits belong to the trigger token, not the caption. Captioning
        # them teaches the model they are variable, which dilutes likeness.
        $lines.Add('- NEVER mention hair, hairstyle, beard, stubble, facial hair, chest hair, face shape, eye colour, skin tone or age. Those are fixed identity traits and must be left out.')
        $lines.Add('- DO describe pose, expression, clothing, framing, lighting and background.')
    }
    else {
        $lines.Add("- Describe the $ConceptType itself in concrete visual detail.")
        $lines.Add('- DO describe shape, colour, material, framing, lighting and background.')
    }

    $lines.Add('- Describe only what is visible. Never guess at age, mood, names or location.')
    $lines.Add("- No preamble. Do not begin with 'The image', 'A photo of', 'This picture', '$Trigger is shown' or '$Trigger is captured'. Begin with the subject and what he is doing or wearing.")

    if ($Tagify) {
        $lines.Add('- Output lowercase comma-separated tags on one line, no sentences.')
    }
    else {
        $lines.Add('- Output ONE line of 15 to 40 words. Separate clauses with commas only.')
        $lines.Add('- Do not use semicolons, full sentences, bullet points or quotes.')
    }

    if (-not [string]::IsNullOrWhiteSpace($Instruction)) {
        $lines.Add("- Additional guidance: $Instruction")
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


function Invoke-FlorenceCaption {
    <#
    .SYNOPSIS
        Captions one image with the Florence-2 API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Task = '<MORE_DETAILED_CAPTION>',
        [string]$Endpoint = 'http://localhost:8080/caption',
        [int]$TimeoutSec = 300
    )

    $form = @{ file = Get-Item -LiteralPath $Path; task = $Task }
    $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Form $form -TimeoutSec $TimeoutSec

    $result = $response.result
    if ($null -eq $result) { return '' }
    if ($result -is [string]) { return $result }

    # Florence keys its result by the task token; older builds used 'caption'.
    foreach ($key in @($Task, 'caption', '<MORE_DETAILED_CAPTION>', '<DETAILED_CAPTION>', '<CAPTION>')) {
        $prop = $result.PSObject.Properties[$key]
        if ($prop -and $prop.Value) { return [string]$prop.Value }
    }

    # Unknown shape: fall back to the first non-empty property.
    $first = $result.PSObject.Properties | Where-Object { $_.Value } | Select-Object -First 1
    if ($first) { return [string]$first.Value }

    return ''
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
        [ValidateSet('ollama', 'florence')][string]$Provider = 'ollama',
        [AllowEmptyString()][string]$Instruction,
        [string]$ConceptType = 'character',
        [switch]$Tagify,
        [hashtable]$ProviderOptions = @{}
    )

    $raw = ''
    $final = ''

    switch ($Provider) {
        'ollama' {
            $prompt = Build-CaptionPrompt -Trigger $Trigger -Instruction $Instruction `
                -ConceptType $ConceptType -Tagify:$Tagify
            $raw = Invoke-OllamaCaption -Path $Path -Prompt $prompt @ProviderOptions

            # The prompt already enforced the rules; only tidy model chatter.
            $final = Remove-CaptionPreamble -Caption $raw
            if ($Tagify) { $final = Convert-ToTags -Caption $final }
        }

        'florence' {
            $raw = Invoke-FlorenceCaption -Path $Path @ProviderOptions

            # Florence takes no instructions, so the rules are applied after the fact.
            $final = Remove-CaptionPreamble -Caption $raw
            if ($Tagify) { $final = Convert-ToTags -Caption $final }
            $final = Set-CaptionSubject -Caption $final -Trigger $Trigger
            $final = Limit-CaptionContent -Caption $final -Instruction $Instruction
        }
    }

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
    'Set-CaptionSubject'
    'Limit-CaptionContent'
    'Get-CaptionJaccard'
    'Test-CaptionSet'
    'Build-CaptionPrompt'
    'Invoke-OllamaCaption'
    'Invoke-FlorenceCaption'
    'Get-ImageCaption'
)
