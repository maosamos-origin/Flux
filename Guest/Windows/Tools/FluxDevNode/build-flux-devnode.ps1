param(
    [string]$Configuration = 'Release',
    [string]$Platform = 'ARM64',
    [string]$OutputDir = "$PSScriptRoot\ARM64\Release"
)

$ErrorActionPreference = 'Stop'
if ($Configuration -ne 'Release' -or $Platform -ne 'ARM64') {
    throw 'FluxDevNode supports only Release|ARM64.'
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe was not found: $vswhere" }
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild -or -not (Test-Path $msbuild)) { throw 'Visual Studio x64 MSBuild was not found.' }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$target = Join-Path $OutputDir 'FluxDevNode.exe'
if (Test-Path $target) { Remove-Item -Force $target }

& $msbuild "$PSScriptRoot\FluxDevNode.vcxproj" /m /p:Configuration=$Configuration /p:Platform=$Platform /p:OutDir="$OutputDir\"
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE." }
if (-not (Test-Path $target)) { throw "FluxDevNode.exe was not produced: $target" }

$vsInstall = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
$dumpbin = Get-ChildItem "$vsInstall\VC\Tools\MSVC" -Recurse -Filter dumpbin.exe |
    Where-Object { $_.FullName -match '\\Hostx64\\x64\\dumpbin\.exe$' } | Select-Object -First 1
if (-not $dumpbin) { throw 'x64 dumpbin.exe was not found.' }
$headers = & $dumpbin.FullName /headers $target
if (-not ($headers -match 'AA64 machine \(ARM64\)')) { throw 'FluxDevNode.exe is not ARM64.' }

$file = Get-Item $target
Write-Host "OUTPUT=$target"
Write-Host "SIZE=$($file.Length)"
Write-Host "SHA256=$((Get-FileHash -Path $target -Algorithm SHA256).Hash)"
Write-Host 'PE_MACHINE=0xAA64 ARM64'
