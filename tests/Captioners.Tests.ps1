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

    It 'does not flag hair when appearance is declared variable' {
        # With -VariableAppearance the trait is wanted, so flagging it would be
        # telling the user to remove exactly what they asked for.
        $set = @([pscustomobject]@{
                image         = 'a.jpg'
                final_caption = 'mikey in a black shirt with a full beard, seated indoors, warm light'
            })
        $issues = Test-CaptionSet -Captions $set -ConceptType 'character' -VariableAppearance

        @($issues | Where-Object { $_.issue -match 'identity trait' }).Count | Should -Be 0
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

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey'

        # -Match is case-insensitive in Pester, so compare case-sensitively here.
        ($result.final_caption -cmatch 'Mikey') | Should -BeFalse
        ([regex]::Matches($result.final_caption, '\bmikey\b')).Count | Should -Be 2
    }

    It 'prepends the trigger when the model omits it entirely' {
        Mock -ModuleName Captioners Invoke-OllamaCaption {
            'a blue t-shirt, standing indoors, soft lighting'
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey'
        $result.final_caption | Should -Match '^mikey, '
    }

    It 'keeps the raw caption alongside the processed one' {
        Mock -ModuleName Captioners Invoke-OllamaCaption {
            'The image shows mikey standing outdoors in a red coat'
        }

        $result = Get-ImageCaption -Path $script:FakeImage -Trigger 'mikey'

        $result.raw_caption | Should -Match '^The image shows'
        $result.final_caption | Should -Not -Match '^The image shows'
        $result.image | Should -Be $script:FakeImage
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

Describe 'Get-OllamaVisionModelList' {

    It 'returns only the models that can accept images' {
        # The wizard offers this list as a pick-list, so a text-only model
        # leaking into it would be selectable and then fail at caption time.
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(
                    @{ name = 'qwen3.5:latest' }
                    @{ name = 'qwen2.5-coder:14b' }
                    @{ name = 'aravhawk/qwen3.6:27b' }
                    @{ name = 'llava:7b' }
                ) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability {
            switch -Wildcard ($Model) {
                'qwen3.5*' { @('completion', 'vision', 'thinking') }
                'llava*' { @('completion', 'vision') }
                default { @('completion', 'tools', 'thinking') }
            }
        }

        $list = Get-OllamaVisionModelList

        $list.Count | Should -Be 2
        $list | Should -Contain 'qwen3.5:latest'
        $list | Should -Contain 'llava:7b'
        $list | Should -Not -Contain 'aravhawk/qwen3.6:27b'
        $list | Should -Not -Contain 'qwen2.5-coder:14b'
    }

    It 'returns an empty list when nothing installed supports vision' {
        Mock -ModuleName Captioners Invoke-RestMethod {
            @{ models = @(@{ name = 'qwen2.5-coder:14b' }) }
        }
        Mock -ModuleName Captioners Get-OllamaModelCapability { @('completion') }

        @(Get-OllamaVisionModelList).Count | Should -Be 0
    }

    It 'returns an empty list when no models are installed' {
        Mock -ModuleName Captioners Invoke-RestMethod { @{ models = @() } }

        @(Get-OllamaVisionModelList).Count | Should -Be 0
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
        # The prompt explains WHY a trait is excluded rather than listing banned
        # words, so the model can judge cases the prompt never enumerates.
        $prompt | Should -Match '(?i)LEAVE OUT'
        $prompt | Should -Match '(?i)identity'
        $prompt | Should -Match '(?i)hair'
    }

    It 'forbids semicolons so clause counting stays accurate' {
        # Semicolon-joined prose made rich captions look like 2-clause captions
        # to the validator, producing false "Clause count" flags.
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' |
            Should -Match '(?i)semicolons'
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

    It 'describes hair and facial hair when they vary across the set' {
        # Captioning a trait that changes is what makes it promptable later;
        # omitting it makes the model average the versions together.
        $prompt = Build-CaptionPrompt -Trigger 'mikey' -Instruction '' -VariableAppearance
        $prompt | Should -Match '(?i)ALSO DESCRIBE'
        $prompt | Should -Match '(?i)facial hair'
        $prompt | Should -Match '(?i)clean-shaven'
    }

    It 'still excludes what never changes, even when appearance varies' {
        $prompt = Build-CaptionPrompt -Trigger 'mikey' -Instruction '' -VariableAppearance
        $prompt | Should -Match '(?i)LEAVE OUT what never changes'
        $prompt | Should -Match '(?i)eye colour'
    }

    It 'always forbids a preamble' {
        Build-CaptionPrompt -Trigger 'mikey' -Instruction '' | Should -Match '(?i)no preamble'
    }
}
