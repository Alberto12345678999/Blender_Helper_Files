<#![CDATA[
.SYNOPSIS
  One-command, headache-free Blender build on Windows with MSVC x64.

.DESCRIPTION
  - Auto-detects the latest Visual Studio with C++ tools (via vswhere)
  - Picks the latest MSVC toolset and Windows 10 SDK installed
  - Sets PATH/LIB/LIBPATH to x64-only so link never grabs x86 libs
  - Runs CMake configure using your existing presets (x64-debug/x64-release)
  - Optionally builds afterward

.PARAMETER Preset
  CMake configure preset to use. Defaults to x64-debug. Accepts x64-release as well.

.PARAMETER Clean
  If set, removes the preset's build directory before configuring.

.PARAMETER Build
  If set, runs `cmake --build` after configuring.

.PARAMETER UseSccache
  If set, enables sccache as the compiler launcher to speed up compilations.

.PARAMETER SccachePath
  Optional path to sccache.exe if it's not already on PATH.

.PARAMETER SccacheDir
  Optional directory for sccache cache (defaults to ./out/sccache).

.PARAMETER SccacheCacheSize
  Optional sccache cache size limit (e.g. 20G). Default: 20G.

.PARAMETER BuildRoot
  Optional alternate root directory for build outputs. If provided, the script
  will create a directory junction from ./out/build/<Preset> to <BuildRoot>/<Preset>
  so large artifacts are stored on a drive with more space.

.EXAMPLE
  # Configure debug and build
  .\tools\windows\build-blender.ps1 -Preset x64-debug -Clean -Build -Jobs 20

  # Configure release
  .\tools\windows\build-blender.ps1 -Preset x64-release -Clean -Build -Jobs 20

  # build-blender.ps1 -Preset x64-debug -Build
  # You can pass -Jobs N to control parallelism.

  # Enable sccache for faster rebuilds (uses PATH or provided path)
  .\tools\windows\build-blender.ps1 -Preset x64-debug -Clean -Build -UseSccache -Jobs 20
  # With explicit cache dir and size
  .\tools\windows\build-blender.ps1 -Preset x64-release -Clean -Build -UseSccache -SccacheDir .\out\sccache -SccacheCacheSize 30G
  # with clangd preset
  .\tools\windows\build-blender.ps1 -Preset x64-release-clangd -Clean -Build -UseSccache -SccacheDir .\out\sccache -SccachePath "C:\Program Files\sccache-v0.14.0-x86_64-pc-windows-msvc\sccache.exe" -SccacheCacheSize 30G

.NOTES
  Requires PowerShell 5.1+ and vswhere (installed with Visual Studio Installer).
#>

param(
  [ValidateSet('x64-debug','x64-release','x64-release-clangd')]
  [string]$Preset = 'x64-debug',
  [switch]$Clean,
  [switch]$Build,
  [string]$Target,
  [int]$Jobs,
  [switch]$UseSccache,
  [string]$SccachePath,
  [string]$SccacheDir,
  [string]$SccacheCacheSize = '20G',
  [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'

# Ensure we always run from the Blender repo root (important when invoked via VS Code tasks).
$RepoRoot = $null
try {
  if ($PSScriptRoot) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..') -ErrorAction Stop).Path
    Set-Location -LiteralPath $RepoRoot
  }
} catch {
  # Non-fatal; fall back to current working directory.
  $RepoRoot = $null
}

function Write-Info($msg) { Write-Host "[build-blender] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[build-blender] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[build-blender] $msg" -ForegroundColor Red }

function Write-ToolLocation([string]$label, [string]$path) {
  if ($path -and (Test-Path -LiteralPath $path)) {
    Write-Info "$label => $path"
  } else {
    Write-Warn "$label => (not found) ${path}"
  }
}

function Get-VSWherePath {
  $vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vsw)) {
    throw "vswhere not found at '$vsw'. Please install Visual Studio Installer or add vswhere to PATH."
  }
  return $vsw
}

function Get-VSInstallPath {
  $vsw = Get-VSWherePath
  $path = (& $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
  if (-not $path) { throw 'No Visual Studio installation with C++ tools found.' }
  if (-not (Test-Path $path)) { throw "VS installation path not found: $path" }
  return $path
}

function Get-LatestMSVCToolsetDir([string]$vsInstall) {
  $msvcRoot = Join-Path $vsInstall 'VC\Tools\MSVC'
  if (-not (Test-Path $msvcRoot)) { throw "MSVC tools directory not found: $msvcRoot" }
  $dirs = Get-ChildItem -Path $msvcRoot -Directory | Sort-Object Name -Descending
  $dir = $dirs | Select-Object -First 1
  if (-not $dir) { throw "No MSVC toolsets found under $msvcRoot" }
  return $dir.FullName
}

function Get-LatestWindowsSdkVersion([string]$sdkRoot) {
  # Prefer library versions as authoritative
  $libRoot = Join-Path $sdkRoot 'Lib'
  if (-not (Test-Path $libRoot)) { throw "Windows SDK Lib folder not found at $libRoot" }
  $versions = Get-ChildItem -Path $libRoot -Directory | Where-Object { $_.Name -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' } | Sort-Object Name -Descending
  $v = $versions | Select-Object -First 1
  if (-not $v) { throw "No Windows SDK versions found under $libRoot" }
  return $v.Name
}

function Find-NinjaExe([string]$vsInstall) {
  # Try PATH first.
  try {
    $cmd = Get-Command -Name 'ninja.exe' -ErrorAction Stop | Select-Object -First 1
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
      return $cmd.Source
    }
  } catch {
    # ignore
  }

  # Fallback: Visual Studio bundled Ninja (used by CMake integration).
  if ($vsInstall) {
    $vsNinja = Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
    if (Test-Path -LiteralPath $vsNinja) {
      return $vsNinja
    }
  }
  return $null
}

function Initialize-X64Environment {
  $vsInstall = Get-VSInstallPath
  Write-Info "Using VS at: $vsInstall"

  $msvcToolsetDir = Get-LatestMSVCToolsetDir -vsInstall $vsInstall
  $msvcBinX64 = Join-Path $msvcToolsetDir 'bin\Hostx64\x64'
  $msvcLibX64 = Join-Path $msvcToolsetDir 'lib\x64'
  if (-not (Test-Path (Join-Path $msvcBinX64 'cl.exe'))) { throw "cl.exe not found in $msvcBinX64" }

  $sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
  if (-not (Test-Path $sdkRoot)) { throw "Windows 10 SDK root not found: $sdkRoot" }
  $sdkVer = Get-LatestWindowsSdkVersion -sdkRoot $sdkRoot
  Write-Info "Using Windows SDK: $sdkVer"

  $sdkBinX64  = Join-Path $sdkRoot "bin\$sdkVer\x64"
  $sdkUcrtX64 = Join-Path $sdkRoot "Lib\$sdkVer\ucrt\x64"
  $sdkUmX64   = Join-Path $sdkRoot "Lib\$sdkVer\um\x64"
  foreach ($p in @($sdkBinX64,$sdkUcrtX64,$sdkUmX64)) { if (-not (Test-Path $p)) { throw "Missing SDK path: $p" } }

  # Prepend x64 tools; keep parent PATH via $env:PATH
  $env:PATH    = "$msvcBinX64;$sdkBinX64;" + $env:PATH
  $env:LIB     = "$msvcLibX64;$sdkUcrtX64;$sdkUmX64"
  $env:LIBPATH = $msvcLibX64

  # Optional: expose CC/CXX for CMake if presets don't pin
  $env:CC  = Join-Path $msvcBinX64 'cl.exe'
  $env:CXX = $env:CC

  $ninjaExe = Find-NinjaExe -vsInstall $vsInstall
  if ($ninjaExe) {
    # Prepend Ninja's folder so fresh CMake configs can discover it.
    $env:PATH = (Split-Path -Parent $ninjaExe) + ';' + $env:PATH
    Write-Info "ninja.exe => $ninjaExe"
  } else {
    Write-Warn "ninja.exe not found on PATH and not found in VS install. CMake presets use the Ninja generator; install Ninja or ensure it's available." 
  }

  # Avoid `where.exe` here: it scans the entire PATH and can emit "Access is denied" for protected folders.
  Write-ToolLocation 'cl.exe' $env:CC
  Write-ToolLocation 'link.exe' (Join-Path $msvcBinX64 'link.exe')
  Write-ToolLocation 'rc.exe' (Join-Path $sdkBinX64 'rc.exe')
  Write-ToolLocation 'mt.exe' (Join-Path $sdkBinX64 'mt.exe')
}
function Invoke-CMake {
  param([string]$Preset,[switch]$Clean,[switch]$Build,[string]$Target,[int]$Jobs)
  $root = Resolve-Path '.' | Select-Object -ExpandProperty Path
  $buildDir = Join-Path $root "out\build\$Preset"

  # If the build directory already exists, it may have a cached CMAKE_MAKE_PROGRAM
  # pointing to a Ninja that has since moved/been uninstalled.
  $cacheFile = Join-Path $buildDir 'CMakeCache.txt'
  $cachedMake = $null
  if (Test-Path -LiteralPath $cacheFile) {
    $line = Select-String -LiteralPath $cacheFile -Pattern '^CMAKE_MAKE_PROGRAM:FILEPATH=' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($line) {
      $cachedMake = ($line.Line -replace '^CMAKE_MAKE_PROGRAM:FILEPATH=', '').Trim()
    }
  }
  if ($BuildRoot) {
    $physical = Join-Path (Resolve-Path -LiteralPath $BuildRoot -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Select-Object -First 1) $Preset
    if (-not $physical) { $physical = Join-Path $BuildRoot $Preset }
    if (-not (Test-Path $physical)) { New-Item -ItemType Directory -Force -Path $physical | Out-Null }
    $logicalBase = Join-Path $root 'out\build'
    if (-not (Test-Path $logicalBase)) { New-Item -ItemType Directory -Force -Path $logicalBase | Out-Null }
    if (-not (Test-Path $buildDir)) {
      Write-Info "Creating junction: $buildDir -> $physical"
      & cmd /c "mklink /J \"$buildDir\" \"$physical\"" | Out-Null
    }
  }
  if ($Clean) {
    Write-Info "Cleaning build dir: $buildDir"
    # Stop any running sccache server — it may be holding a lock on sccache.exe
    # inside the build directory, preventing deletion.
    try { & sccache --stop-server 2>$null } catch { }
    if (Test-Path $buildDir) {
      try {
        Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction Stop
      } catch {
        Write-Warn "PowerShell Remove-Item failed, retrying with rmdir..."
        & cmd /c "rmdir /s /q \"$buildDir\""
      }
      if (Test-Path $buildDir) { throw "Failed to clean build dir: $buildDir" }
    }
  }
  # Optional sccache wiring
  $use_sccache = $false
  $sccacheExeForCMake = $null
  if ($UseSccache) {
    $sccacheExe = $null
    if ($SccachePath) {
      if (Test-Path $SccachePath) {
        $sccacheExe = (Resolve-Path $SccachePath).Path
        # Prepend provided location to PATH for child processes (cmake/ninja)
        $env:PATH = (Split-Path $sccacheExe) + ";" + $env:PATH
      } else {
        throw "SccachePath provided but file not found: $SccachePath"
      }
    } else {
      $where = & where.exe sccache 2>$null | Select-Object -First 1
      if ($where) { $sccacheExe = $where }
    }
    if (-not $sccacheExe) {
      Write-Err "sccache.exe not found. Install it (e.g. 'choco install sccache' or 'scoop install sccache') or pass -SccachePath."
      throw "sccache not available"
    }
    # Prefer an absolute path in the CMake cache so later `ninja` invocations
    # don't depend on the current shell's PATH.
    try {
      $sccacheExeForCMake = (Resolve-Path -LiteralPath $sccacheExe -ErrorAction Stop).Path
    } catch {
      $sccacheExeForCMake = $sccacheExe
    }
    $cacheDir = $null
    if ($SccacheDir) {
      try {
        $resolved = Resolve-Path -LiteralPath $SccacheDir -ErrorAction Stop
        $cacheDir = $resolved.Path
      } catch {
        # Use as provided if it doesn't exist yet
        $cacheDir = $SccacheDir
      }
    } else {
      $cacheDir = Join-Path $root 'out\sccache'
    }
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
    $env:SCCACHE_DIR = $cacheDir
    $env:SCCACHE_CACHE_SIZE = $SccacheCacheSize
    Write-Info "Using sccache: $sccacheExe"
    Write-Info "sccache dir: $cacheDir (size: $SccacheCacheSize)"
    $use_sccache = $true
  }

  # Ninja generator on Windows may end up invoking just `sccache` (by name) in
  # build.ninja. Make that reliable by placing a copy in the build directory
  # so `ninja install` works even in shells that don't have sccache on PATH.
  if ($use_sccache -and $sccacheExeForCMake -and (Test-Path -LiteralPath $sccacheExeForCMake)) {
    if (-not (Test-Path -LiteralPath $buildDir)) {
      New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    }
    $localSccache = Join-Path $buildDir 'sccache.exe'
    try {
      Copy-Item -LiteralPath $sccacheExeForCMake -Destination $localSccache -Force -ErrorAction Stop
      Write-Info "sccache.exe copied to build dir: $localSccache"
    } catch {
      Write-Warn "Failed to copy sccache.exe to build dir ($localSccache): $($_.Exception.Message)"
    }
  }

  Write-Info "Configuring with preset: $Preset"
  $extraCMakeArgs = @()
  if ($cachedMake -and -not (Test-Path -LiteralPath $cachedMake)) {
    $vsInstall = $null
    try { $vsInstall = Get-VSInstallPath } catch { $vsInstall = $null }
    $ninjaExe = Find-NinjaExe -vsInstall $vsInstall
    if ($ninjaExe) {
      Write-Warn "Cached Ninja is missing: $cachedMake"
      Write-Info "Overriding CMAKE_MAKE_PROGRAM to: $ninjaExe"
      $extraCMakeArgs += "-DCMAKE_MAKE_PROGRAM:FILEPATH=$ninjaExe"
    } else {
      Write-Warn "Cached Ninja is missing: $cachedMake. Re-run with -Clean after installing Ninja." 
    }
  }

  # Keep sccache state consistent across re-configures.
  if ($use_sccache) {
    $extraCMakeArgs += '-DWITH_WINDOWS_SCCACHE=ON'
    if ($sccacheExeForCMake) {
      $extraCMakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$sccacheExeForCMake"
      $extraCMakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$sccacheExeForCMake"
    }
  } else {
    $extraCMakeArgs += '-DWITH_WINDOWS_SCCACHE=OFF'
    $extraCMakeArgs += '-DCMAKE_C_COMPILER_LAUNCHER='  # clear cached launcher (e.g. sccache)
    $extraCMakeArgs += '-DCMAKE_CXX_COMPILER_LAUNCHER='
  }

  & cmake --preset $Preset @extraCMakeArgs
  if ($LASTEXITCODE -ne 0) { throw "CMake configure failed ($LASTEXITCODE)" }
  if ($Build) {
    $jobsToUse = if ($Jobs -gt 0) { $Jobs } else { [Environment]::ProcessorCount }
    if ($Target) {
      Write-Info "Building preset: $Preset, target: $Target (-j $jobsToUse)"
      & cmake --build $buildDir --target $Target -j $jobsToUse
    } else {
      Write-Info "Building preset: $Preset (-j $jobsToUse)"
      & cmake --build $buildDir -j $jobsToUse
    }
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed ($LASTEXITCODE)" }
    if ($UseSccache) {
      Write-Info "sccache stats:"
      & sccache --show-stats 2>$null | ForEach-Object { Write-Host "  $_" }
    }
  }
}

try {
  Initialize-X64Environment
  Invoke-CMake -Preset $Preset -Clean:$Clean -Build:$Build -Target:$Target -Jobs:$Jobs
  Write-Host "[build-blender] Done." -ForegroundColor Green
}
catch {
  Write-Err $_.Exception.Message
  exit 1
}
