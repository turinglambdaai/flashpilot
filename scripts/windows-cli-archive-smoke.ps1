param(
    [Parameter(Mandatory = $true)][string]$Archive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$install = Join-Path ([System.IO.Path]::GetTempPath()) ("flashpilot-archive-smoke-" + [guid]::NewGuid().ToString('N'))

try {
    # An unrelated temporary location catches paths that only happen to
    # work because the release runner still has the source tree installed.
    Expand-Archive -LiteralPath $archivePath -DestinationPath $install -Force
    $exe = Join-Path $install 'bin/flashpilot.exe'
    $sample = Join-Path $install 'examples/plan.sim.json'

    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Portable Windows archive must contain bin/flashpilot.exe"
    }
    if (Test-Path -LiteralPath (Join-Path $install 'flashpilot.exe')) {
        throw "Windows archive still contains the old root-level executable"
    }
    if (-not (Test-Path -LiteralPath $sample -PathType Leaf)) {
        throw "Portable archive is missing its simulated-ECU sample"
    }

    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        & $exe --help
        if ($LASTEXITCODE -ne 0) { throw "Extracted --help failed: $LASTEXITCODE" }
        & $exe verify $sample
        if ($LASTEXITCODE -ne 0) { throw "Extracted verify failed: $LASTEXITCODE" }
        & $exe flash $sample
        if ($LASTEXITCODE -ne 0) { throw "Extracted simulated flash failed: $LASTEXITCODE" }
        # PowerShell/GitHub runners may treat a deliberately nonzero native
        # exit as a terminating error before the assertion can inspect it.
        $PSNativeCommandUseErrorActionPreference = $false
        & $exe bogus 2>$null
        if ($LASTEXITCODE -ne 2) {
            throw "Invalid-command exit code must be 2, got $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    # The native negative-case command intentionally returned a nonzero code.
    # Do not allow the GitHub PowerShell wrapper to mistake that verified
    # expected result for the script's own exit status.
    $global:LASTEXITCODE = 0
} finally {
    if (Test-Path -LiteralPath $install) {
        Remove-Item -LiteralPath $install -Recurse -Force
    }
}
