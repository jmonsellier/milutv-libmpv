# Archives the complete corresponding source of a release, as the LGPL asks of whoever distributes
# the DLLs: mpv at its pinned commit, every meson subproject exactly as it was built (git checkouts
# and wrapdb tarballs with their patches), the ANGLE sources vcpkg downloaded with the overlay port
# that built them, and this recipe. Run after build-angle.ps1 and build-mpv.ps1.
param(
  [string]$WorkDir = (Join-Path $PSScriptRoot '..\work'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\dist')
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$versions = Get-Content (Join-Path $repoRoot 'versions.json') -Raw | ConvertFrom-Json
$WorkDir = Resolve-Path $WorkDir
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = Resolve-Path $OutDir

$name = "milutv-libmpv-$($versions.release)-sources"
$stage = Join-Path $WorkDir "stage\$name"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage, (Join-Path $stage 'angle') | Out-Null

# The recipe (this repository, without build outputs nor a vcpkg binary cache left at its root,
# which would put a prebuilt ANGLE in the sources).
$recipe = Join-Path $stage 'recipe'
New-Item -ItemType Directory -Force $recipe | Out-Null
Get-ChildItem $repoRoot -Force | Where-Object { $_.Name -notin 'work', 'dist', '.git', 'vcpkg-binary-cache' } |
  ForEach-Object { Copy-Item -Recurse $_.FullName $recipe }

# mpv and its subprojects, without VCS metadata or build directory.
$tarMpv = Join-Path $stage 'mpv-and-subprojects.tar'
tar -cf $tarMpv --exclude=mpv/build --exclude=.git -C $WorkDir mpv

# ANGLE: the port that built it, and the two sources it fetches (ANGLE itself and chromium's
# third_party/zlib), downloaded here by commit rather than taken from vcpkg's download cache, which
# stays empty when the binary cache already holds the build.
$port = Join-Path $WorkDir 'overlay-ports\angle'
Copy-Item -Recurse $port (Join-Path $stage 'angle\vcpkg-port')
$portfile = Get-Content (Join-Path $port 'portfile.cmake') -Raw
$angleCommit = [regex]::Match($portfile, 'set\(ANGLE_COMMIT ([0-9a-f]{40})\)').Groups[1].Value
$angleSha512 = [regex]::Match($portfile, 'set\(ANGLE_SHA512 ([0-9a-f]{128})\)').Groups[1].Value
$zlibCommit = [regex]::Match($portfile, 'set\(ANGLE_THIRDPARTY_ZLIB_COMMIT ([0-9a-f]{40})\)').Groups[1].Value
if (-not $angleCommit -or -not $angleSha512 -or -not $zlibCommit) { throw 'Cannot read the ANGLE and zlib commits from the port.' }
$angleTar = Join-Path $stage "angle\angle-$angleCommit.tar.gz"
Invoke-WebRequest "https://github.com/google/angle/archive/$angleCommit.tar.gz" -OutFile $angleTar
$actual = (Get-FileHash $angleTar -Algorithm SHA512).Hash.ToLowerInvariant()
if ($actual -ne $angleSha512) { throw "ANGLE source SHA-512 is $actual, the port expects $angleSha512." }
Invoke-WebRequest "https://chromium.googlesource.com/chromium/src/third_party/zlib/+archive/$zlibCommit.tar.gz" `
  -OutFile (Join-Path $stage "angle\chromium-third_party-zlib-$zlibCommit.tar.gz")
@(
  "vcpkg $($versions.vcpkg.repository) @ $($versions.vcpkg.commit), port files in vcpkg-port/"
  "ANGLE https://github.com/google/angle @ $angleCommit (SHA-512 checked against the port)"
  "third_party/zlib https://chromium.googlesource.com/chromium/src/third_party/zlib @ $zlibCommit"
  'The port also downloads WebKit''s gni-to-cmake.py and include/CMakeLists.txt at the WebKit'
  'commit and SHA-512 written in vcpkg-port/portfile.cmake.'
) | Set-Content (Join-Path $stage 'angle\README.txt')

$archive = Join-Path $OutDir "$name.tar.gz"
Remove-Item $archive -ErrorAction SilentlyContinue
tar -czf $archive -C (Join-Path $WorkDir 'stage') $name
Write-Output "Sources: $archive ($([math]::Round((Get-Item $archive).Length / 1MB, 1)) MB)"
