#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for lib/Captioners.psm1.

    Several cases are marked REGRESSION. Those encode bugs that were shipping
    and silently corrupting training data; they use the real Florence-2 output
    recorded from the sample dataset, not invented strings.
#>

BeforeAll {
    $ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/Captioners.psm1'
    Import-Module $ModulePath -Force

    # Verbatim Florence-2 <MORE_DETAILED_CAPTION> output for sample image 2.jpg.
    $script:FlorenceSample = "The image is a close-up selfie of a man's face. " +
    "He is looking directly at the camera with a slight smile on his lips. " +
    "He has short, dark hair and a beard. " +
    "He appears to be in his late 30s or early 40s. " +
    "The background is a plain white wall with a door visible on the left side. " +
    "The man is wearing a light blue t-shirt."

    $script:SubjectFocus = 'focus on the subject; ignore background objects'
}

Describe 'Remove-CaptionPreamble' {

    It 'strips "The image is a close-up selfie of"' {
        $result = Remove-CaptionPreamble -Caption $script:FlorenceSample
        $result | Should -Not -Match '(?i)^the image is'
        $result | Should -Match "(?i)^a man's face"
    }

    It 'strips "A photo of" openers' {
        Remove-CaptionPreamble -Caption 'A photo of a red car' | Should -Be 'a red car'
    }

    It 'strips a wrapping pair of quotes' {
        Remove-CaptionPreamble -Caption '"mikey in a blue shirt"' | Should -Be 'mikey in a blue shirt'
    }

    It 'removes reasoning-model <think> leakage' {
        $withThinking = '<think>The user wants a concise caption.</think>mikey seated by a window'
        Remove-CaptionPreamble -Caption $withThinking | Should -Be 'mikey seated by a window'
    }

    It 'collapses runs of whitespace' {
        Remove-CaptionPreamble -Caption "mikey    standing`n`nindoors" | Should -Be 'mikey standing indoors'
    }

    It 'returns empty string for null or whitespace input' {
        Remove-CaptionPreamble -Caption '' | Should -Be ''
        Remove-CaptionPreamble -Caption '   ' | Should -Be ''
    }
}

Describe 'Set-CaptionSubject' {

    It 'names the subject on its first mention' {
        $result = Set-CaptionSubject -Caption "a man's face, smiling" -Trigger 'mikey'
        $result | Should -Match "^mikey's face"
    }

    It 'REGRESSION: does not rewrite possessive pronouns into the trigger' {
        # Old behaviour produced "mikey appears to be in mikey's late 30s".
        $result = Set-CaptionSubject -Caption $script:FlorenceSample -Trigger 'mikey'
        $result | Should -Not -Match "mikey's late 30s"
        $result | Should -Not -Match "on mikey's lips"
    }

    It 'REGRESSION: does not leave a dangling article ("The mikey")' {
        $result = Set-CaptionSubject -Caption 'The man is wearing a blue shirt' -Trigger 'mikey'
        $result | Should -Not -Match '(?i)the mikey'
        $result | Should -Match '^mikey is wearing'
    }

    It 'mentions the trigger exactly once for a multi-sentence caption' {
        $result = Set-CaptionSubject -Caption $script:FlorenceSample -Trigger 'mikey'
        ([regex]::Matches($result, '(?i)\bmikey\b')).Count | Should -Be 1
    }

    It 'handles a bare subject noun with no article' {
        Set-CaptionSubject -Caption 'man riding a bike' -Trigger 'mikey' |
            Should -Match '^mikey riding'
    }

    It 'capitalises a sentence that substitution left starting lower-case' {
        # "... t-shirt. The man is wearing ..." becomes "... t-shirt. He is wearing ..."
        $result = Set-CaptionSubject -Caption 'A man smiles. The man is wearing a blue t-shirt.' -Trigger 'mikey'
        $result | Should -Match 'smiles\. He is wearing'
    }

    It 'keeps the trigger spelling even when it opens a sentence' {
        $result = Set-CaptionSubject -Caption 'a man smiles.' -Trigger 'mikey'
        ($result -cmatch 'Mikey') | Should -BeFalse
        $result | Should -Match '^mikey'
    }

    It 'leaves a caption with no subject noun untouched' {
        Set-CaptionSubject -Caption 'a red sports car on a track' -Trigger 'mikey' |
            Should -Be 'a red sports car on a track'
    }

    It 'returns empty string for empty input' {
        Set-CaptionSubject -Caption '' -Trigger 'mikey' | Should -Be ''
    }
}

Describe 'Limit-CaptionContent' {

    It 'REGRESSION: does not truncate a prose caption at the first comma' {
        # The shipped version returned "... mikey has short", deleting clothing,
        # pose and everything else after the first background-bearing chunk.
        $named = Set-CaptionSubject -Caption $script:FlorenceSample -Trigger 'mikey'
        $result = Limit-CaptionContent -Caption $named -Instruction $script:SubjectFocus

        $result | Should -Match '(?i)light blue t-shirt'
        $result | Should -Not -Match '(?i)has short$'
    }

    It 'drops the sentence describing the background' {
        $named = Set-CaptionSubject -Caption $script:FlorenceSample -Trigger 'mikey'
        $result = Limit-CaptionContent -Caption $named -Instruction $script:SubjectFocus

        $result | Should -Not -Match '(?i)plain white wall'
    }

    It 'drops only background clauses from tag-style input' {
        $tags = 'mikey, blue t-shirt, smiling, plain white wall, soft lighting'
        $result = Limit-CaptionContent -Caption $tags -Instruction $script:SubjectFocus

        $result | Should -Be 'mikey, blue t-shirt, smiling, soft lighting'
    }

    It 'leaves the caption alone when no instruction is given' {
        Limit-CaptionContent -Caption $script:FlorenceSample -Instruction '' |
            Should -Be $script:FlorenceSample
    }

    It 'leaves the caption alone for an unrelated instruction' {
        Limit-CaptionContent -Caption $script:FlorenceSample -Instruction 'use british spelling' |
            Should -Be $script:FlorenceSample
    }

    It 'never returns empty, even when every clause mentions the background' {
        $allBackground = 'a plain white wall, a wooden door, a bright window'
        $result = Limit-CaptionContent -Caption $allBackground -Instruction $script:SubjectFocus

        $result | Should -Not -BeNullOrEmpty
        $result | Should -Be $allBackground
    }
}

Describe 'Convert-ToTags' {

    It 'splits prose into lowercase comma-separated tags' {
        Convert-ToTags -Caption 'A man and a dog.' | Should -Be 'man, dog'
    }

    It 'de-duplicates repeated tags' {
        Convert-ToTags -Caption 'blue shirt, blue shirt, smiling' | Should -Be 'blue shirt, smiling'
    }

    It 'returns empty string for empty input' {
        Convert-ToTags -Caption '' | Should -Be ''
    }
}

Describe 'Get-CaptionJaccard' {

    It 'returns 1 for identical captions' {
        Get-CaptionJaccard -A 'mikey, blue shirt' -B 'mikey, blue shirt' | Should -Be 1
    }

    It 'returns 0 for captions with nothing in common' {
        Get-CaptionJaccard -A 'mikey, blue shirt' -B 'a dog, a park' | Should -Be 0
    }

    It 'returns a fraction for partial overlap' {
        $score = Get-CaptionJaccard -A 'mikey, smiling, beard' -B 'mikey, smiling, hat'
        $score | Should -BeGreaterThan 0
        $score | Should -BeLessThan 1
    }

    It 'returns 0 when both captions are empty' {
        Get-CaptionJaccard -A '' -B '' | Should -Be 0
    }

    It 'is order independent' {
        $forward = Get-CaptionJaccard -A 'mikey, smiling' -B 'smiling, mikey'
        $forward | Should -Be 1
    }
}

Describe 'Test-CaptionSet' {

    It 'flags an empty caption' {
        $set = @([pscustomobject]@{ image = 'a.jpg'; final_caption = '' })
        $issues = Test-CaptionSet -Captions $set

        $issues.Count | Should -Be 1
        $issues[0].issue | Should -Match 'Empty'
    }

    It 'flags near-duplicate captions' {
        $set = @(
            [pscustomobject]@{ image = 'a.jpg'; final_caption = 'mikey, blue shirt, smiling, indoors' }
            [pscustomobject]@{ image = 'b.jpg'; final_caption = 'mikey, blue shirt, smiling, indoors' }
        )
        $issues = Test-CaptionSet -Captions $set

        @($issues | Where-Object { $_.issue -match 'Too similar' }).Count | Should -Be 1
    }

    It 'flags a prose caption with too few words' {
        $set = @([pscustomobject]@{ image = 'a.jpg'; final_caption = 'mikey smiling' })
        $issues = Test-CaptionSet -Captions $set -Style 'prose'

        @($issues | Where-Object { $_.issue -match 'Word count' }).Count | Should -Be 1
    }

    It 'flags a tag caption with too few tags' {
        $set = @([pscustomobject]@{ image = 'a.jpg'; final_caption = 'mikey, smiling' })
        $issues = Test-CaptionSet -Captions $set -Style 'tags'

        @($issues | Where-Object { $_.issue -match 'Tag count' }).Count | Should -Be 1
    }

    It 'REGRESSION: does not flag healthy prose for having few commas' {
        # A 28-word caption with two commas was reported as "Clause count=3"
        # and flagged on most of a perfectly good dataset.
        $prose = 'mikey sits in a car wearing a black hoodie and seatbelt, ' +
        'looking at the camera with a neutral expression under natural daylight inside the vehicle'
        $set = @([pscustomobject]@{ image = 'a.jpg'; final_caption = $prose })

        Test-CaptionSet -Captions $set -Style 'prose' | Should -BeNullOrEmpty
    }

    It 'reports nothing for a healthy, varied caption set' {
        $set = @(
            [pscustomobject]@{ image = 'a.jpg'; final_caption = 'mikey, blue t-shirt, standing, soft window light, kitchen' }
            [pscustomobject]@{ image = 'b.jpg'; final_caption = 'mikey, grey hoodie, seated, harsh overhead light, office' }
        )
        Test-CaptionSet -Captions $set -Style 'tags' | Should -BeNullOrEmpty
    }

    It 'accepts an empty caption set without error' {
        Test-CaptionSet -Captions @() | Should -BeNullOrEmpty
    }

    It 'flags a character caption that describes a fixed identity trait' {
        # Models follow the "no identity traits" rule most of the time, not all
        # of the time, so the validator is the backstop.
        $set = @([pscustomobject]@{
                image         = 'a.jpg'
                final_caption = 'mikey in a black shirt smiles at the camera with short hair and stubble'
            })
        $issues = Test-CaptionSet -Captions $set -ConceptType 'character'

        @($issues | Where-Object { $_.issue -match 'identity trait' }).Count | Should -Be 1
    }

    It 'does not flag identity traits for non-character concepts' {
        $set = @([pscustomobject]@{
                image         = 'a.jpg'
                final_caption = 'a caftan with fine embroidery, draped on a stand, lit softly, beside a hair comb'
            })
        $issues = Test-CaptionSet -Captions $set -ConceptType 'clothing'

        @($issues | Where-Object { $_.issue -match 'identity trait' }).Count | Should -Be 0
    }
}

Describe 'Get-ImageCaption' {

    BeforeAll {
        # The sample image is never read: the provider call is mocked out.
        $script:FakeImage = Join-Path $TestDrive 'sample.jpg'
        Set-Content -LiteralPath $script:FakeImage -Value 'not-a-real-jpeg'
    }

    It 'REGRESSION: normalises the trigger to one consistent spelling' {
        # Models capitalise the trigger at the start of a caption and lower-case
        # it mid-caption. "Mikey" and "mikey" are different tokens, so a dataset
        # split between the two trains the concept onto both.
        Mock -ModuleName Captioners Invoke-OllamaCaption {
            'Mikey sits in a car, mikey wears a black hoodie'
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey' -Provider 'ollama'

        # -Match is case-insensitive in Pester, so compare case-sensitively here.
        ($result.final_caption -cmatch 'Mikey') | Should -BeFalse
        ([regex]::Matches($result.final_caption, '\bmikey\b')).Count | Should -Be 2
    }

    It 'prepends the trigger when the model omits it entirely' {
        Mock -ModuleName Captioners Invoke-OllamaCaption {
            'a blue t-shirt, standing indoors, soft lighting'
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey' -Provider 'ollama'
        $result.final_caption | Should -Match '^mikey, '
    }

    It 'keeps the raw caption alongside the processed one' {
        Mock -ModuleName Captioners Invoke-OllamaCaption {
            'The image shows mikey standing outdoors in a red coat'
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey' -Provider 'ollama'

        $result.raw_caption | Should -Match '^The image shows'
        $result.final_caption | Should -Not -Match '^The image shows'
        $result.image | Should -Be $script:FakeImage
    }

    It 'applies Florence post-processing only on the florence provider' {
        Mock -ModuleName Captioners Invoke-FlorenceCaption {
            "The image is a photo of a man's face. The background is a white wall."
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey' `
            -Provider 'florence' -Instruction 'ignore background objects'

        $result.final_caption | Should -Match "^mikey's face"
        $result.final_caption | Should -Not -Match '(?i)white wall'
    }
}

Describe 'Get-OllamaVisionModel' {

    It 'prefers a listed model when it is installed and vision-capable' {
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(@{ name = 'llava:7b' }, @{ name = 'qwen3.5:latest' }) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability {
            if ($Model -like 'qwen3.5*') { @('completion', 'vision') } else { @('completion', 'vision') }
        }

        Get-OllamaVisionModel -Preferred @('qwen3.5') | Should -Be 'qwen3.5:latest'
    }

    It 'falls back to any installed vision model when no preference matches' {
        # A user who already has a vision model should not be forced to pull
        # a second one just because it is not the tool's favourite.
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(@{ name = 'qwen2.5-coder:14b' }, @{ name = 'minicpm-v:latest' }) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability {
            if ($Model -like 'minicpm*') { @('completion', 'vision') } else { @('completion', 'tools') }
        }

        Get-OllamaVisionModel -Preferred @('qwen3.5') | Should -Be 'minicpm-v:latest'
    }

    It 'skips a preferred model that is installed but text-only' {
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(@{ name = 'qwen3.5:latest' }, @{ name = 'llava:7b' }) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability {
            if ($Model -like 'llava*') { @('completion', 'vision') } else { @('completion') }
        }

        Get-OllamaVisionModel -Preferred @('qwen3.5') | Should -Be 'llava:7b'
    }

    It 'returns null when nothing installed supports vision' {
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(@{ name = 'qwen2.5-coder:14b' }) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability { @('completion', 'tools') }

        Get-OllamaVisionModel -Preferred @('qwen3.5') | Should -BeNullOrEmpty
    }

    It 'returns null when no models are installed at all' {
        Mock -ModuleName Captioners Invoke-RestMethod { @{ models = @() } }

        Get-OllamaVisionModel | Should -BeNullOrEmpty
    }
}

Describe 'Get-OllamaModelCapability' {

    It 'returns the capability list Ollama reports' {
        Mock -ModuleName Captioners Invoke-RestMethod {
            [pscustomobject]@{ capabilities = @('completion', 'vision', 'thinking') }
        }

        $caps = Get-OllamaModelCapability -Model 'qwen3.5'
        $caps | Should -Contain 'vision'
    }

    It 'returns an empty list when the model is unknown to Ollama' {
        Mock -ModuleName Captioners Invoke-RestMethod { throw 'model not found' }

        Get-OllamaModelCapability -Model 'nope' | Should -BeNullOrEmpty
    }

    It 'returns an empty list when the response carries no capabilities field' {
        Mock -ModuleName Captioners Invoke-RestMethod { [pscustomobject]@{ details = @{} } }

        Get-OllamaModelCapability -Model 'old-model' | Should -BeNullOrEmpty
    }
}

Describe 'Build-CaptionPrompt' {

    It 'names the trigger word in the prompt' {
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' | Should -Match "'mikey'"
    }

    It 'tells a character model to skip fixed identity traits' {
        $prompt = Build-CaptionPrompt -Trigger 'mikey' -Instruction '' -ConceptType 'character'
        $prompt | Should -Match '(?i)fixed identity traits'
        # Hair and stubble leaked into real captions until the prompt named them.
        $prompt | Should -Match '(?i)hair'
        $prompt | Should -Match '(?i)stubble'
    }

    It 'forbids semicolons so clause counting stays accurate' {
        # Semicolon-joined prose made rich captions look like 2-clause captions
        # to the validator, producing false "Clause count" flags.
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' |
            Should -Match '(?i)do not use semicolons'
    }

    It 'describes the object itself for non-character concepts' {
        $prompt = Build-CaptionPrompt -Trigger 'caftan' -Instruction '' -ConceptType 'clothing'
        $prompt | Should -Match '(?i)describe the clothing itself'
        $prompt | Should -Not -Match '(?i)fixed identity traits'
    }

    It 'asks for tags when -Tagify is set' {
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' -Tagify |
            Should -Match '(?i)comma-separated tags'
    }

    It 'appends caller guidance when an instruction is supplied' {
        Build-CaptionPrompt -Trigger 'mikey' -Instruction 'prefer short captions' |
            Should -Match 'prefer short captions'
    }

    It 'always forbids a preamble' {
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' | Should -Match '(?i)no preamble'
    }
}
