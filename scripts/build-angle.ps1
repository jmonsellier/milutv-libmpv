# Builds ANGLE (libEGL.dll, libGLESv2.dll and their PDBs) with vcpkg, at the versions of versions.json.
#
# versions.json "angle.mode":
#   pinned : the vcpkg port, re-pointed at angle.commit (the ANGLE the player prototype validated
#            zero-copy decoding with). The port files (build system, patches) stay those of the
#            pinned vcpkg commit.
#   port   : the vcpkg port as it is at the pinned vcpkg commit, if the pinned ANGLE does not build.
#
# Output: <OutDir>\bin (DLLs, PDBs), <OutDir>\include (EGL and KHR headers only, so that mpv never
# picks up vcpkg's zlib.h), <OutDir>\LICENSE.ANGLE, <OutDir>\angle.json (what was built).
param(
  [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Arch,
  [string]$WorkDir = (Join-Path $PSScriptRoot '..\work'),
  [string]$OutDir = (Join-Path $PSScriptRoot "..\work\angle-$Arch")
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$versions = Get-Content (Join-Path $repoRoot 'versions.json') -Raw | ConvertFrom-Json
$triplet = "$Arch-windows-milutv"
New-Item -ItemType Directory -Force $WorkDir, $OutDir | Out-Null
$WorkDir = Resolve-Path $WorkDir
$OutDir = Resolve-Path $OutDir

# 1. vcpkg at the pinned commit (never the runner's preinstalled one, which moves).
$vcpkgRoot = Join-Path $WorkDir 'vcpkg'
if (-not (Test-Path (Join-Path $vcpkgRoot '.git'))) {
  git init --quiet $vcpkgRoot
  git -C $vcpkgRoot remote add origin $versions.vcpkg.repository
}
git -C $vcpkgRoot fetch --quiet --depth 1 origin $versions.vcpkg.commit
git -C $vcpkgRoot checkout --quiet --force FETCH_HEAD
if (-not (Test-Path (Join-Path $vcpkgRoot 'vcpkg.exe'))) {
  & (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
}

# 2. Overlay port.
$overlay = Join-Path $WorkDir 'overlay-ports'
Remove-Item -Recurse -Force $overlay -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $overlay | Out-Null
Copy-Item -Recurse (Join-Path $vcpkgRoot 'ports\angle') (Join-Path $overlay 'angle')
$portfile = Join-Path $overlay 'angle\portfile.cmake'

function Edit-PortFile([string]$Path, [System.Collections.IDictionary]$Replacements) {
  $text = Get-Content $Path -Raw
  foreach ($pattern in $Replacements.Keys) {
    if ($text -notmatch $pattern) {
      throw "The vcpkg angle port no longer has '$pattern' in $(Split-Path -Leaf $Path): update scripts/build-angle.ps1 for vcpkg $($versions.vcpkg.commit)."
    }
    $text = $text -replace $pattern, $Replacements[$pattern]
  }
  Set-Content -Path $Path -Value $text -NoNewline
}

if ($versions.angle.mode -eq 'pinned') {
  Edit-PortFile $portfile ([ordered]@{
    'set\(ANGLE_COMMIT [0-9a-f]{40}\)'                  = "set(ANGLE_COMMIT $($versions.angle.commit))"
    'set\(ANGLE_VERSION [0-9]+\)'                       = "set(ANGLE_VERSION $($versions.angle.revision))"
    'set\(ANGLE_SHA512 [0-9a-f]{128}\)'                 = "set(ANGLE_SHA512 $($versions.angle.sha512))"
    'set\(ANGLE_THIRDPARTY_ZLIB_COMMIT [0-9a-f]{40}\)'  = "set(ANGLE_THIRDPARTY_ZLIB_COMMIT $($versions.angle.zlibCommit))"
  })
  # The pinned ANGLE needs C++20 (std::same_as in src/common/span.h); the port's build system says 17.
  Edit-PortFile (Join-Path $overlay 'angle\cmake-buildsystem\CMakeLists.txt') ([ordered]@{
    'set\(CMAKE_CXX_STANDARD 17\)' = 'set(CMAKE_CXX_STANDARD 20)'
  })
  $manifestPath = Join-Path $overlay 'angle\vcpkg.json'
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $manifest.'version-string' = "milutv-$($versions.angle.revision)"
  $manifest.PSObject.Properties.Remove('port-version')
  $manifest | ConvertTo-Json -Depth 20 | Set-Content $manifestPath
} elseif ($versions.angle.mode -ne 'port') {
  throw "versions.json angle.mode must be 'pinned' or 'port', not '$($versions.angle.mode)'."
}

# 3. Build. The binary cache (VCPKG_DEFAULT_BINARY_CACHE, restored by the workflow) makes a rebuild
#    with unchanged versions take seconds.
$vcpkg = Join-Path $vcpkgRoot 'vcpkg.exe'
# A variable, not (Join-Path ...): PowerShell splits "--opt=(expr)" into two arguments.
$triplets = Join-Path $repoRoot 'triplets'
# The port's gni-to-cmake.py reads BUILD.gn files with the locale encoding (cp1252 on the runners),
# and ANGLE's BUILD.gn files are UTF-8. vcpkg clears the environment of port builds, hence the keep.
$env:PYTHONUTF8 = '1'
$env:VCPKG_KEEP_ENV_VARS = (@($env:VCPKG_KEEP_ENV_VARS, 'PYTHONUTF8') | Where-Object { $_ }) -join ';'
& $vcpkg install "angle:$triplet" `
  --overlay-ports=$overlay `
  --overlay-triplets=$triplets `
  --clean-after-build `
  --disable-metrics

# 4. Collect.
$installed = Join-Path $vcpkgRoot "installed\$triplet"
$bin = Join-Path $OutDir 'bin'
$include = Join-Path $OutDir 'include'
Remove-Item -Recurse -Force $bin, $include -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $bin, $include | Out-Null
foreach ($name in 'libEGL', 'libGLESv2') {
  $dll = Join-Path $installed "bin\$name.dll"
  if (-not (Test-Path $dll)) { throw "vcpkg did not produce $name.dll in $installed\bin." }
  Copy-Item $dll $bin
  $pdb = Join-Path $installed "bin\$name.pdb"
  if (Test-Path $pdb) { Copy-Item $pdb $bin } else { Write-Warning "No $name.pdb from vcpkg." }
}
Copy-Item -Recurse (Join-Path $installed 'include\EGL') (Join-Path $include 'EGL')
Copy-Item -Recurse (Join-Path $installed 'include\KHR') (Join-Path $include 'KHR')
if (-not (Test-Path (Join-Path $include 'EGL\eglext_angle.h'))) {
  throw 'EGL/eglext_angle.h is missing: mpv would build without the d3d11-egl interop (no zero-copy decoding).'
}
Copy-Item (Join-Path $installed 'share\angle\copyright') (Join-Path $OutDir 'LICENSE.ANGLE')

# The version string ANGLE reports ("2.1.<revision> git hash: <commit>"), read back from the DLL.
$bytes = [IO.File]::ReadAllBytes((Join-Path $bin 'libGLESv2.dll'))
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$match = [regex]::Match($ascii, '2\.1\.[0-9]+ git hash: [0-9a-f]+')
$portVersion = (Get-Content (Join-Path $overlay 'angle\vcpkg.json') -Raw | ConvertFrom-Json).'version-string'
[ordered]@{
  mode          = $versions.angle.mode
  commit        = if ($versions.angle.mode -eq 'pinned') { $versions.angle.commit } else { $null }
  portVersion   = $portVersion
  versionString = if ($match.Success) { $match.Value } else { $null }
  vcpkgCommit   = $versions.vcpkg.commit
  triplet       = $triplet
} | ConvertTo-Json | Set-Content (Join-Path $OutDir 'angle.json')
Get-Content (Join-Path $OutDir 'angle.json')
