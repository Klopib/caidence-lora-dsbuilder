#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Guards on docker/docker-compose.yml.

    These are cheap text assertions rather than a docker run: they catch the
    edits that would quietly break isolation guarantees the README makes, and
    they run on a CI box with no GPU.
#>

BeforeAll {
    $script:ComposePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'docker/docker-compose.yml'
    $script:Compose = Get-Content -LiteralPath $script:ComposePath -Raw
}

Describe 'docker-compose.yml' {

    It 'exists' {
        Test-Path -LiteralPath $script:ComposePath | Should -BeTrue
    }

    It 'sets an explicit project name' {
        # Without this the project name defaults to the directory name,
        # "docker", and unrelated containers are reported as orphans.
        $script:Compose | Should -Match '(?m)^name:\s*lora-dataset-builder'
    }

    It 'keeps the managed captioner behind a profile' {
        # It must never start as a side effect of bringing up Florence-2.
        $script:Compose | Should -Match 'profiles:\s*\[\s*"captioner"\s*\]'
    }

    It 'does not name the managed captioner "ollama"' {
        # Reusing that name would collide with a container the user owns.
        $script:Compose | Should -Match 'container_name:\s*lora-captioner'
        $script:Compose | Should -Not -Match '(?m)^\s*container_name:\s*ollama\s*$'
    }

    It 'gives the captioner its own named volume' {
        # Sharing the user's Ollama volume would write into models we did not
        # download, which the README promises never happens.
        $script:Compose | Should -Match 'lora-ollama-models:/root/\.ollama'
        $script:Compose | Should -Not -Match '(?m)^\s*-\s*ollama:/root/\.ollama'
    }

    It 'makes the captioner port overridable' {
        $script:Compose | Should -Match '\$\{CAPTIONER_PORT:-11434\}:11434'
    }

    It 'keeps Florence-2 model caches outside the repo by default' {
        $script:Compose | Should -Match '\$\{HF_CACHE_DIR:-'
    }
}
