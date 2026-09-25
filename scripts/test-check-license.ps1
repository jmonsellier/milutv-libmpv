# Self-test of check-license.ps1 on synthetic builds: an LGPL build passes, and each way of not
# being LGPL v2.1+ (gpl, version3, nonfree, a GPL mpv, a DLL without the ANGLE interop) fails.
# Runs in seconds, before the real build, on any machine with PowerShell 7.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$check = Join-Path $PSScriptRoot 'check-license.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) "check-license-test-$PID"

function New-FakeBuild([hashtable]$Ff = @{}, [string]$MpvGpl = '0', [string]$Features = 'd3d-hwaccel egl-angle gl gl-win32 wasapi',
                       [string]$DllText = 'LGPL version 2.1 or later d3d11-egl d3d11vpp') {
  $dir = Join-Path $root ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force (Join-Path $dir 'build\subprojects\ffmpeg') | Out-Null
  $values = @{ CONFIG_GPL = '0'; CONFIG_VERSION3 = '0'; CONFIG_NONFREE = '0'; FFMPEG_LICENSE = '"LGPL version 2.1 or later"' }
  foreach ($k in $Ff.Keys) { $values[$k] = $Ff[$k] }
  @(
    '#define FFMPEG_CONFIGURATION "-Dffmpeg:gpl=disabled"'
    "#define FFMPEG_LICENSE $($values.FFMPEG_LICENSE)"
    "#define CONFIG_GPL $($values.CONFIG_GPL)"
    "#define CONFIG_VERSION3 $($values.CONFIG_VERSION3)"
    "#define CONFIG_NONFREE $($values.CONFIG_NONFREE)"
  ) | Set-Content (Join-Path $dir 'build\subprojects\ffmpeg\config.h')
  @("#define HAVE_GPL $MpvGpl", "#define FULLCONFIG `"$Features`"") | Set-Content (Join-Path $dir 'build\config.h')
  $dll = Join-Path $dir 'libmpv-2.dll'
  [IO.File]::WriteAllBytes($dll, [Text.Encoding]::ASCII.GetBytes("MZ`0$DllText`0"))
  return $dir
}

function Invoke-Check([string]$Dir) {
  try {
    & $check -BuildDir (Join-Path $Dir 'build') -Dll (Join-Path $Dir 'libmpv-2.dll') -OutFile (Join-Path $Dir 'proof.txt') | Out-Null
    return $true
  } catch {
    # Only the licence verdict counts as a failure; a broken script or bad parameter must not pass
    # for an expected rejection.
    if ($_.Exception.Message -like 'Licence check failed:*') { return $false }
    throw
  }
}

$cases = @(
  @{ Name = 'LGPL v2.1+ build passes'; Expect = $true; Dir = { New-FakeBuild } }
  # mpv never calls avcodec_license(), so the linker drops FFMPEG_LICENSE (as in zhongfly's LGPL DLL).
  @{ Name = 'LGPL v2.1+ DLL without the dead-stripped licence string passes'; Expect = $true; Dir = { New-FakeBuild -DllText 'd3d11-egl d3d11vpp' } }
  @{ Name = 'FFmpeg gpl fails'; Expect = $false; Dir = { New-FakeBuild -Ff @{ CONFIG_GPL = '1'; FFMPEG_LICENSE = '"GPL version 2 or later"' } } }
  @{ Name = 'FFmpeg version3 fails'; Expect = $false; Dir = { New-FakeBuild -Ff @{ CONFIG_VERSION3 = '1'; FFMPEG_LICENSE = '"LGPL version 3 or later"' } } }
  @{ Name = 'FFmpeg nonfree fails'; Expect = $false; Dir = { New-FakeBuild -Ff @{ CONFIG_NONFREE = '1' } } }
  @{ Name = 'mpv gpl fails'; Expect = $false; Dir = { New-FakeBuild -MpvGpl '1' } }
  @{ Name = 'mpv with vulkan fails'; Expect = $false; Dir = { New-FakeBuild -Features 'd3d-hwaccel egl-angle gl gl-win32 vulkan wasapi' } }
  @{ Name = 'mpv without egl-angle fails'; Expect = $false; Dir = { New-FakeBuild -Features 'd3d-hwaccel gl gl-win32 wasapi' } }
  @{ Name = 'DLL with a GPL FFmpeg string fails'; Expect = $false; Dir = { New-FakeBuild -DllText 'LGPL version 2.1 or later GPL version 2 or later d3d11-egl d3d11vpp' } }
  @{ Name = 'DLL without the d3d11-egl interop fails'; Expect = $false; Dir = { New-FakeBuild -DllText 'LGPL version 2.1 or later d3d11vpp' } }
)

$failed = 0
try {
  foreach ($case in $cases) {
    $passed = Invoke-Check (& $case.Dir)
    if ($passed -eq $case.Expect) {
      Write-Output "ok   $($case.Name)"
    } else {
      Write-Output "FAIL $($case.Name) (check returned $passed)"
      $failed++
    }
  }
} finally {
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
if ($failed -gt 0) { throw "$failed check-license case(s) failed." }
