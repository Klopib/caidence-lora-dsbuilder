#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Tests for caption.ps1's handling of the source folder.

    The contract these lock in: a folder passed as -ImageDir is read-only. The
    tool stages a copy and writes captions beside the copy, so a user's source
    photos are never modified and a run can always be repeated from them.

    The captioning provider is never reached: every case fails or returns
    before a model call, or is driven through -WhatIf style argument checking.
#>

BeforeAll {
    $script:CaptionScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/caption.ps1'

    function New-SourceFolder {
        param([int]$Count = 3)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($i in 1..$Count) {
            # Content is irrelevant; only the extension is inspected before
            # a provider call is attempted.
            Set-Content -LiteralPath (Join-Path $dir "$i.jpg") -Value "fake-image-$i"
        }
        return $dir
    }

    function Get-FolderSnapshot {
        param([string]$Path)
        Get-ChildItem -LiteralPath $Path -Recurse -File |
            Sort-Object Name |
            ForEach-Object { '{0}:{1}' -f $_.Name, $_.Length }
    }
}

Describe 'caption.ps1 source folder safety' {

    It 'refuses to write into the source folder when output resolves to it' {
        $source = New-SourceFolder

        { & $script:CaptionScript -ImageDir $source -Concept 'test' -OutputDir $source -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*treated as read-only*'
    }

    It 'rejects -OutputDir and -InPlace together' {
        $source = New-SourceFolder
        $out = Join-Path $TestDrive 'out1'

        { & $script:CaptionScript -ImageDir $source -Concept 'test' -OutputDir $out -InPlace -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not both*'
    }

    It 'leaves the source folder byte-for-byte unchanged on a failed run' {
        $source = New-SourceFolder
        $before = Get-FolderSnapshot -Path $source

        # No provider is reachable on this port, so the run fails after staging.
        $out = Join-Path $TestDrive 'out2'
        try {
            & $script:CaptionScript -ImageDir $source -Concept 'test' `
                -OutputDir $out -OllamaEndpoint 'http://127.0.0.1:9' -ErrorAction Stop
        }
        catch {
            # Expected: no provider is listening. Only the filesystem side
            # effects matter here, so the failure is recorded and ignored.
            $script:expectedFailure = $_
        }

        Get-FolderSnapshot -Path $source | Should -Be $before
    }

    It 'never creates caption artefacts in the source folder' {
        $source = New-SourceFolder
        $out = Join-Path $TestDrive 'out3'

        try {
            & $script:CaptionScript -ImageDir $source -Concept 'test' `
                -OutputDir $out -OllamaEndpoint 'http://127.0.0.1:9' -ErrorAction Stop
        }
        catch {
            # Expected: no provider is listening. Only the filesystem side
            # effects matter here, so the failure is recorded and ignored.
            $script:expectedFailure = $_
        }

        foreach ($artefact in 'captions.json', 'captions.csv', 'caption_issues.csv') {
            Test-Path -LiteralPath (Join-Path $source $artefact) | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath $source -Filter *.txt).Count | Should -Be 0
    }

    It 'stages a copy of every source image into the output folder' {
        $source = New-SourceFolder -Count 4
        $out = Join-Path $TestDrive 'out4'

        try {
            & $script:CaptionScript -ImageDir $source -Concept 'test' `
                -OutputDir $out -OllamaEndpoint 'http://127.0.0.1:9' -ErrorAction Stop
        }
        catch {
            # Expected: no provider is listening. Only the filesystem side
            # effects matter here, so the failure is recorded and ignored.
            $script:expectedFailure = $_
        }

        @(Get-ChildItem -LiteralPath $out -Filter *.jpg).Count | Should -Be 4
    }

    It 'disambiguates images that share a name across subfolders' {
        $source = New-SourceFolder -Count 1
        $sub = Join-Path $source 'nested'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub '1.jpg') -Value 'different-content'

        $out = Join-Path $TestDrive 'out5'
        try {
            & $script:CaptionScript -ImageDir $source -Concept 'test' `
                -OutputDir $out -OllamaEndpoint 'http://127.0.0.1:9' -ErrorAction Stop
        }
        catch {
            # Expected: no provider is listening. Only the filesystem side
            # effects matter here, so the failure is recorded and ignored.
            $script:expectedFailure = $_
        }

        # Both files must survive staging rather than one overwriting the other.
        @(Get-ChildItem -LiteralPath $out -Filter *.jpg).Count | Should -Be 2
    }

    It 'fails clearly when the source folder has no images' {
        $empty = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        { & $script:CaptionScript -ImageDir $empty -Concept 'test' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*No images found*'
    }

    It 'fails clearly when the source folder does not exist' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        { & $script:CaptionScript -ImageDir $missing -Concept 'test' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}
