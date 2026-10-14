<#
.SYNOPSIS
    Locates a Python and prepares the virtual environment the tool runs in.

.DESCRIPTION
    Two things need Python: image preparation (Pillow) and the review UI
    (Gradio). Both share one environment, created on first use and reused
    afterwards, so nothing on the system Python is altered.

    Everything here is written for Windows, macOS and Linux. The differences
    between them are small and confined to this file: where a virtual
    environment puts its interpreter, and what the interpreter is called.
#>

Set-StrictMode -Version Latest

$script:MinPython = [version]'3.10'


function Get-VenvPython {
    <#
    .SYNOPSIS
        Path to the interpreter inside a virtual environment, per platform.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VenvPath)

    if ($IsWindows) { return Join-Path $VenvPath 'Scripts/python.exe' }
    return Join-Path $VenvPath 'bin/python'
}


function Find-HostPython {
    <#
    .SYNOPSIS
        Finds a Python 3.10+ interpreter, preferring whatever the machine
        already uses.

    .DESCRIPTION
        The default interpreter is tried first so the tool uses the Python a
        user already has, rather than insisting on a version. Named versions
        are a fallback for machines with no default on PATH.

        'py' is the Windows launcher; 'python3' is the usual Unix name.

    .OUTPUTS
        Full path to a suitable interpreter, or $null.
    #>
    [CmdletBinding()]
    param()

    $candidates = if ($IsWindows) {
        @(@{ Exe = 'py'; Args = @('-3') }, @{ Exe = 'python'; Args = @() })
    }
    else {
        @(@{ Exe = 'python3'; Args = @() }, @{ Exe = 'python'; Args = @() })
    }

    foreach ($v in '3.15', '3.14', '3.13', '3.12', '3.11', '3.10') {
        if ($IsWindows) { $candidates += @{ Exe = 'py'; Args = @("-$v") } }
        else { $candidates += @{ Exe = "python$v"; Args = @() } }
    }

    $probe = 'import sys; print(sys.executable); print("%d.%d" % sys.version_info[:2])'

    foreach ($c in $candidates) {
        if (-not (Get-Command $c.Exe -ErrorAction SilentlyContinue)) { continue }

        try { $out = & $c.Exe @($c.Args + @('-c', $probe)) 2>$null }
        catch { continue }

        if ($LASTEXITCODE -ne 0 -or -not $out) { continue }

        $lines = @($out) | Where-Object { $_ }
        if ($lines.Count -lt 2) { continue }

        $exe = $lines[0].Trim()
        try { $ver = [version]$lines[1].Trim() } catch { continue }

        if ($ver -ge $script:MinPython -and (Test-Path -LiteralPath $exe)) {
            return [pscustomobject]@{ Path = $exe; Version = $ver }
        }
    }

    return $null
}


function Initialize-PythonEnv {
    <#
    .SYNOPSIS
        Ensures a virtual environment exists with the given packages installed.

    .OUTPUTS
        Path to the environment's interpreter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [Parameter(Mandatory)][string[]]$Packages,
        # Import names to test, when they differ from the package names.
        [string[]]$ImportNames = @()
    )

    $venvPython = Get-VenvPython -VenvPath $VenvPath

    if (-not (Test-Path -LiteralPath $venvPython)) {
        $host_ = Find-HostPython
        if (-not $host_) {
            throw ("No Python 3.10 or newer was found.`n" +
                "  Install Python from https://python.org and run this again.")
        }

        Write-Host "  Creating a Python environment ($($host_.Version)) ..." -ForegroundColor Cyan
        Write-Host "    $VenvPath" -ForegroundColor DarkGray

        # Output from a called program joins this function's return value unless
        # it is captured. Leaving it loose would return the path *and* whatever
        # pip printed, and callers assigning that to a variable get a blob.
        $log = & $host_.Path -m venv $VenvPath 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
            throw "Could not create a virtual environment with $($host_.Path):`n$($log -join "`n")"
        }
    }

    $imports = if ($ImportNames) { $ImportNames } else { $Packages }
    $check = ($imports | ForEach-Object { "import $_" }) -join '; '

    & $venvPython -c $check 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Installing $($Packages -join ', ') (one time) ..." -ForegroundColor Cyan

        $log = & $venvPython -m pip install --quiet --upgrade pip 2>&1
        $log += & $venvPython -m pip install --quiet @Packages 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $($Packages -join ', '):`n$($log -join "`n")"
        }
    }

    # Single value, nothing else in the output stream.
    return $venvPython
}


function Test-NvidiaGpu {
    <#
    .SYNOPSIS
        True when an NVIDIA GPU looks usable on this machine.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $false }

    # The format argument must stay one token: written as "csv, noheader",
    # PowerShell splits on the space and passes "noheader" as its own argument,
    # which nvidia-smi rejects. That silently reported "no GPU" on machines
    # that have one, and installed the slow CPU engine.
    $names = & nvidia-smi --query-gpu=name --format=csv,noheader 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    return [bool](@($names) | Where-Object { $_ -and $_ -notmatch '^ERROR' })
}


function Install-LlamaCpp {
    <#
    .SYNOPSIS
        Installs llama-cpp-python from the project's prebuilt wheel index.

    .DESCRIPTION
        PyPI has no wheel for this package, so pip would try to compile it and
        fail without CMake and a C++ toolchain. The maintainer publishes
        prebuilt wheels per backend; those are used instead, which keeps the
        install to a download.

        The CUDA build is much larger but far faster, so it is chosen only when
        an NVIDIA GPU is actually present.

    .OUTPUTS
        The backend that was installed: 'cuda' or 'cpu'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [switch]$ForceCpu
    )

    & $PythonExe -c 'import llama_cpp' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'already installed' }

    $useCuda = (-not $ForceCpu) -and (Test-NvidiaGpu)
    $index = if ($useCuda) {
        'https://abetlen.github.io/llama-cpp-python/whl/cu124'
    }
    else {
        'https://abetlen.github.io/llama-cpp-python/whl/cpu'
    }

    $size = if ($useCuda) { 'about 510MB' } else { 'about 8MB' }
    $backend = if ($useCuda) { 'CUDA' } else { 'CPU' }
    Write-Host "  Installing the captioning engine ($backend build, $size) ..." -ForegroundColor Cyan

    $log = & $PythonExe -m pip install --quiet --extra-index-url $index llama-cpp-python 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install llama-cpp-python:`n$($log -join "`n")"
    }

    return $(if ($useCuda) { 'cuda' } else { 'cpu' })
}


function Open-InFileManager {
    <#
    .SYNOPSIS
        Opens a folder in the platform's file manager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        # Output is suppressed so this function never returns anything: a bare
        # external call inside a function contributes to its return value.
        if ($IsWindows) { Start-Process explorer.exe -ArgumentList $Path }
        elseif ($IsMacOS) { & open $Path 2>&1 | Out-Null }
        else { & xdg-open $Path 2>&1 | Out-Null }
    }
    catch {
        Write-Host "  Could not open a file manager. Path: $Path" -ForegroundColor DarkGray
    }
}


Export-ModuleMember -Function @(
    'Get-VenvPython'
    'Find-HostPython'
    'Initialize-PythonEnv'
    'Test-NvidiaGpu'
    'Install-LlamaCpp'
    'Open-InFileManager'
)
