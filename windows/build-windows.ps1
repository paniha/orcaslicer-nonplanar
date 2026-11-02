<#
.SYNOPSIS
    Builds OrcaSlicer Nonplanar for Windows x64 with Visual Studio.

.DESCRIPTION
    Fetches OrcaSlicer at the commit the patch is based on, applies
    orca-nonplanar.patch and windows\orca-nonplanar-windows.patch, builds the
    dependencies and the slicer, and packs a portable ZIP.

    Plan on several hours for the first run: the dependencies take most of
    the time and are reused by later runs (-Stage slicer).

.EXAMPLE
    .\windows\build-windows.ps1
    Full build. The result is written to the dist folder of this repository.

.EXAMPLE
    .\windows\build-windows.ps1 -Stage slicer -Tests -Installer
    Rebuilds only the slicer, runs the nonplanar tests and makes an installer.
#>
[CmdletBinding()]
param(
    # Keep this short and without spaces: the dependency build is sensitive
    # to long paths.
    [string]$SourceDir = 'C:\onp\orca',

    # all    = source + deps + slicer + package
    # deps   = source + deps
    # slicer = source + slicer + package (deps must exist)
    # tests  = build and run the tests only (slicer must have been built)
    [ValidateSet('all', 'deps', 'slicer', 'tests')]
    [string]$Stage = 'all',

    # Also builds and runs the [Nonplanar] unit tests after the slicer.
    [switch]$Tests,

    # Also builds an NSIS installer (needs NSIS on PATH or in its default folder).
    [switch]$Installer
)

$ErrorActionPreference = 'Stop'

# Strawberry Perl brings a complete MinGW toolchain in C:\Strawberry\c. With its
# bin folder on PATH, CMake treats C:\Strawberry\c as a system prefix and uses its
# headers and MinGW libraries (expat, gmp, mpfr, lzma, iconv and an incompatible
# jpeglib.h), which breaks the MSVC build. Only Perl itself is needed.
$env:Path = ($env:Path -split ';' | Where-Object { $_ -notmatch '\\Strawberry\\c\\' }) -join ';'

$UpstreamUrl    = 'https://github.com/OrcaSlicer/OrcaSlicer.git'
$UpstreamCommit = '8500fcdccaa10b5099ac20d252af3a7c560046f1'  # OrcaSlicer v2.4.2
$RepoRoot       = Split-Path -Parent $PSScriptRoot
$DistDir        = Join-Path $RepoRoot 'dist'
$LogFile        = Join-Path $DistDir 'build.log'
$Patches        = @(
    (Join-Path $RepoRoot 'orca-nonplanar.patch'),
    (Join-Path $PSScriptRoot 'orca-nonplanar-windows.patch')
)

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Invoke-Git {
    # Windows batch files must keep CRLF line endings: labels in LF .bat files
    # are not found reliably, which breaks build_release_vs.bat.
    & git -c core.autocrlf=true -c core.longpaths=true @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Show-BuildErrors {
    if (-not (Test-Path $LogFile)) { return }
    $found = @(Select-String -Path $LogFile -Pattern ': (fatal )?error [A-Z]*[0-9]+|CMake Error' |
        ForEach-Object { $_.Line } | Select-Object -Unique -First 20)
    if ($found.Count -gt 0) {
        Write-Host ''
        Write-Host 'First errors:' -ForegroundColor Red
        $found | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    Write-Host "Full log: $LogFile" -ForegroundColor Yellow
}

function Find-VsDevCmd {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw 'Visual Studio was not found. Install Visual Studio 2022 with the "Desktop development with C++" workload.'
    }
    $path = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'Common7\Tools\VsDevCmd.bat' | Select-Object -First 1
    if (-not $path) {
        throw 'Visual Studio has no C++ compiler. Add the "Desktop development with C++" workload in the Visual Studio Installer.'
    }
    return $path
}

function Invoke-InVsShell([string]$Commands) {
    # Runs commands in a Visual Studio developer shell. msbuild and cmake are
    # only on PATH there. A temporary .cmd avoids PowerShell/cmd quoting issues.
    $cmdFile = Join-Path $env:TEMP "onp-$([guid]::NewGuid().ToString('N')).cmd"
    # The :main wrapper merges stderr inside cmd. PowerShell would turn native
    # stderr lines into terminating errors under ErrorActionPreference Stop.
    $lines = @(
        '@echo off',
        'call :main 2>&1',
        'exit /b %errorlevel%',
        ':main',
        "call `"$script:VsDevCmd`" -arch=x64 -host_arch=x64 -no_logo",
        'if errorlevel 1 exit /b 1',
        "cd /d `"$SourceDir`"",
        'if errorlevel 1 exit /b 1',
        $Commands
    )
    $text = (($lines -join "`n") -replace "`r`n", "`n") -replace "`n", "`r`n"
    Set-Content -Path $cmdFile -Value $text -Encoding Ascii
    try {
        # Out-Host: without it the build output would become the return value.
        & cmd.exe /d /c $cmdFile | Tee-Object -FilePath $LogFile -Append | Out-Host
        return $LASTEXITCODE
    } finally {
        Remove-Item $cmdFile -ErrorAction SilentlyContinue
    }
}

function Assert-Prerequisites {
    Write-Step 'Checking prerequisites'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git was not found. Install Git for Windows.'
    }
    foreach ($patch in $Patches) {
        if (-not (Test-Path $patch)) { throw "Patch not found: $patch" }
    }
    if ($SourceDir -match '\s') { throw "SourceDir must not contain spaces: $SourceDir" }

    $script:VsDevCmd = Find-VsDevCmd
    Write-Host "Visual Studio: $script:VsDevCmd"

    if ($Stage -in 'all', 'deps') {
        # OpenSSL's Configure needs a native Windows Perl. The MSYS perl that
        # comes with Git does not work, so look at it explicitly.
        $perl = Get-Command perl -ErrorAction SilentlyContinue
        if (-not $perl -and (Test-Path 'C:\Strawberry\perl\bin\perl.exe')) {
            $env:Path = "C:\Strawberry\perl\bin;$env:Path"
            $perl = Get-Command perl -ErrorAction SilentlyContinue
        }
        if (-not $perl -or $perl.Source -match '\\Git\\') {
            throw 'Strawberry Perl is required. Run: winget install StrawberryPerl.StrawberryPerl   Then open a new terminal.'
        }
        Write-Host "Perl: $($perl.Source)"
    }

    $drive = (Split-Path -Qualifier $SourceDir).TrimEnd(':')
    $freeGb = [math]::Floor((Get-PSDrive $drive).Free / 1GB)
    if ($freeGb -lt 40) { throw "Need at least 40 GB free on ${drive}:, found $freeGb GB." }
    Write-Host "Free space on ${drive}: $freeGb GB"
}

function Initialize-Source {
    Write-Step "Preparing source in $SourceDir"
    $marker = Join-Path $SourceDir '.nonplanar-patched'
    if (Test-Path $marker) {
        Write-Host 'Source is already patched.'
        return
    }
    if (Test-Path (Join-Path $SourceDir '.git')) {
        throw "$SourceDir contains a checkout without the patch marker. Delete it or pick another -SourceDir."
    }
    New-Item -ItemType Directory -Force -Path $SourceDir | Out-Null
    Invoke-Git -C $SourceDir init -q
    Invoke-Git -C $SourceDir remote add origin $UpstreamUrl
    Invoke-Git -C $SourceDir fetch --depth 1 origin $UpstreamCommit
    Invoke-Git -C $SourceDir checkout -q FETCH_HEAD
    foreach ($patch in $Patches) {
        Write-Host "Applying $(Split-Path -Leaf $patch)"
        Invoke-Git -C $SourceDir apply --whitespace=nowarn $patch
    }
    Set-Content -Path $marker -Value $UpstreamCommit -Encoding Ascii
}

function Test-Polluted([string]$CacheFile) {
    return (Test-Path $CacheFile) -and (Select-String -Path $CacheFile -Pattern 'Strawberry/c/' -Quiet)
}

function Remove-Folder([string]$Path) {
    if (Test-Path $Path) {
        & cmd.exe /d /c rmdir /s /q $Path
        if (Test-Path $Path) { throw "Could not delete $Path. Close programs using it and try again." }
    }
}

function Remove-PollutedBuilds {
    # A build configured with Strawberry's C toolchain on PATH stays broken:
    # the wrong paths are in the CMake caches and in the built dependencies.
    $depsBuild = Join-Path $SourceDir 'deps\build'
    $build     = Join-Path $SourceDir 'build'
    if (Test-Polluted (Join-Path $depsBuild 'CMakeCache.txt')) {
        if ($Stage -notin 'all', 'deps') {
            throw 'The dependencies were built against Strawberry Perl''s C libraries. Run the script without -Stage to rebuild them.'
        }
        Write-Warning 'Deleting dependencies built against Strawberry Perl''s C libraries. They will be rebuilt.'
        Remove-Folder $depsBuild
        Remove-Folder $build
    } elseif (Test-Polluted (Join-Path $build 'CMakeCache.txt')) {
        Write-Warning 'Deleting a slicer build configured with Strawberry Perl''s C libraries.'
        Remove-Folder $build
    }
}

function Assert-CMake {
    # Visual Studio's own CMake is used; it comes with the C++ workload unless
    # the "C++ CMake tools for Windows" component was deselected.
    if ((Invoke-InVsShell 'cmake --version') -ne 0) {
        throw 'CMake was not found. Add "C++ CMake tools for Windows" in the Visual Studio Installer.'
    }
}

function Build-Deps {
    Write-Step 'Building dependencies (this takes a while)'
    # build_release_vs.bat does not return an error code. The second build is a
    # no-op after a complete build and reports the error of an incomplete one.
    $commands = @'
call build_release_vs.bat deps
cd /d deps\build
if errorlevel 1 exit /b 1
cmake --build . --config Release --target deps -- -m
'@
    $exit = Invoke-InVsShell $commands
    if ($exit -ne 0) {
        Show-BuildErrors
        throw "The dependency build failed (exit code $exit)."
    }
}

function Build-Slicer {
    Write-Step 'Building OrcaSlicer Nonplanar'
    if (-not (Test-Path (Join-Path $SourceDir 'deps\build\OrcaSlicer_dep'))) {
        throw 'The dependencies are missing. Run with -Stage all or -Stage deps first.'
    }
    $exe = Join-Path $SourceDir 'build\OrcaSlicer\orca-slicer.exe'
    Remove-Item $exe -ErrorAction SilentlyContinue
    $exit = Invoke-InVsShell 'call build_release_vs.bat slicer'
    # build_release_vs.bat does not return an error code, so check the output.
    if (-not (Test-Path $exe)) {
        Show-BuildErrors
        throw "The slicer build failed: $exe was not created."
    }
}

function Build-Package {
    Write-Step 'Packing the portable ZIP'
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    $version = (Select-String -Path (Join-Path $SourceDir 'version.inc') `
        -Pattern 'set\(ORCA_NONPLANAR_VERSION "(.+)"\)').Matches[0].Groups[1].Value
    $name = "OrcaSlicer-Nonplanar-$version-Windows-x64-portable"
    $stage = Join-Path $SourceDir "build\$name"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Copy-Item (Join-Path $SourceDir 'build\OrcaSlicer') $stage -Recurse
    $zip = Join-Path $DistDir "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (Test-Path $sevenZip) {
        & $sevenZip a -tzip -bso0 -bsp0 $zip $stage
        if ($LASTEXITCODE -ne 0) { throw '7-Zip failed.' }
    } else {
        Compress-Archive -Path $stage -DestinationPath $zip
    }
    Remove-Item $stage -Recurse -Force
    Write-Host "Portable ZIP: $zip" -ForegroundColor Green

    if ($Installer) {
        Write-Step 'Building the installer'
        $nsis = Join-Path ${env:ProgramFiles(x86)} 'NSIS'
        if (Test-Path $nsis) { $env:Path = "$nsis;$env:Path" }
        $exit = Invoke-InVsShell "cd build`r`ncpack -G NSIS"
        if ($exit -ne 0) { throw "cpack failed with exit code $exit. Is NSIS installed?" }
        Get-ChildItem (Join-Path $SourceDir 'build') -Filter 'OrcaSlicer_Nonplanar_*.exe' |
            Copy-Item -Destination $DistDir -PassThru |
            ForEach-Object { Write-Host "Installer: $($_.FullName)" -ForegroundColor Green }
    }
}

function Invoke-Tests {
    Write-Step 'Building and running the [Nonplanar] tests'
    $env:NONPLANAR_FIXTURES_DIR     = Join-Path $RepoRoot 'tests\prusaslicer-nonplanar'
    $env:NONPLANAR_ORCA_PROFILES_DIR = Join-Path $RepoRoot 'tests\orcaslicer-nonplanar\profiles'
    $commands = @'
cd /d build
if errorlevel 1 exit /b 1
cmake .. -DBUILD_TESTS=ON
if errorlevel 1 exit /b 1
cmake --build . --config Release --target fff_print_tests -- -m
if errorlevel 1 exit /b 1
tests\fff_print\Release\fff_print_tests.exe "[Nonplanar]~[missing-fixture]" --reporter compact
'@
    $exit = Invoke-InVsShell $commands
    if ($exit -ne 0) {
        Show-BuildErrors
        throw "The nonplanar tests failed (exit code $exit)."
    }
    Write-Host 'All nonplanar tests passed.' -ForegroundColor Green
}

Assert-Prerequisites
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Set-Content -Path $LogFile -Value "OrcaSlicer Nonplanar build, stage $Stage" -Encoding Ascii
Initialize-Source
Remove-PollutedBuilds
Assert-CMake
if ($Stage -in 'all', 'deps') { Build-Deps }
if ($Stage -in 'all', 'slicer') {
    Build-Slicer
    Build-Package
}
if ($Stage -eq 'tests' -or ($Tests -and $Stage -in 'all', 'slicer')) { Invoke-Tests }
Write-Step 'Done'
