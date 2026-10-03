param(
    [string]$Configuration = "Release",
    [string]$Platform = "ARM64",
    [string]$OutputDir = "$PSScriptRoot\ARM64\Release"
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================"
Write-Host "=== Starting ARM64 devcon.exe build ==="
Write-Host "========================================"
Write-Host "Script Root: $PSScriptRoot"
Write-Host "Configuration: $Configuration"
Write-Host "Platform: $Platform"
Write-Host "Output Directory: $OutputDir"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe was not found: $vswhere" }
$vsInstallPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (-not $vsInstallPath -or -not (Test-Path $vsInstallPath)) { throw 'Visual Studio installation with MSBuild was not found.' }
Write-Host "Visual Studio installation: $vsInstallPath"

$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild -or -not (Test-Path $msbuild)) { throw 'x64 MSBuild was not found.' }
Write-Host "MSBuild: $msbuild"

# Find Windows Kits 10 SDK & WDK
$sdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
if (-not (Test-Path $sdkRoot)) { throw "Windows Kits directory not found: $sdkRoot" }

# Locate latest SDK include & lib
$sdkVersionDir = Get-ChildItem "$sdkRoot\Include" -Directory | Where-Object { $_.Name -match '^10\.0\.' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVersionDir) { throw "No Windows 10/11 SDK include directory found in $sdkRoot\Include" }
$sdkVersion = $sdkVersionDir.Name
Write-Host "Detected SDK Version: $sdkVersion"

$sdkInclude = "$sdkRoot\Include\$sdkVersion"
$sdkLib = "$sdkRoot\Lib\$sdkVersion"
$sdkBin = "$sdkRoot\bin\$sdkVersion\x64"
if (-not (Test-Path $sdkBin)) {
    $sdkBin = "$sdkRoot\bin\$sdkVersion\x86"
}

# Locate MSVC tools
$vcToolsDir = Get-ChildItem "$vsInstallPath\VC\Tools\MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $vcToolsDir) { throw "MSVC tools directory not found in $vsInstallPath\VC\Tools\MSVC" }
$vcVersion = $vcToolsDir.Name
Write-Host "Detected MSVC Version: $vcVersion"

$clArm64 = "$($vcToolsDir.FullName)\bin\Hostx64\arm64\cl.exe"
$linkArm64 = "$($vcToolsDir.FullName)\bin\Hostx64\arm64\link.exe"
$vcInclude = "$($vcToolsDir.FullName)\include"
$vcLib = "$($vcToolsDir.FullName)\lib"

$mcExe = "$sdkBin\mc.exe"
$rcExe = "$sdkBin\rc.exe"

$dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) {
    $dumpbin = Get-ChildItem "$vsInstallPath\VC\Tools\MSVC" -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\Hostx64\\x64\\dumpbin\.exe$' } | Select-Object -First 1
}

Write-Host "cl.exe (ARM64): $clArm64 (Exists: $(Test-Path $clArm64))"
Write-Host "link.exe (ARM64): $linkArm64 (Exists: $(Test-Path $linkArm64))"
Write-Host "mc.exe: $mcExe (Exists: $(Test-Path $mcExe))"
Write-Host "rc.exe: $rcExe (Exists: $(Test-Path $rcExe))"
Write-Host "dumpbin.exe: $dumpbin (Exists: $([bool]$dumpbin))"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$targetExe = Join-Path $OutputDir "devcon.exe"
if (Test-Path $targetExe) { Remove-Item -Force $targetExe }

# Method 1: Try MSBuild with devcon.vcxproj
$builtViaMSBuild = $false
Write-Host "--- Attempting build via MSBuild ($Platform|$Configuration) ---"
$msbuildLog = Join-Path $OutputDir "msbuild-devcon.log"
& $msbuild "$PSScriptRoot\devcon.vcxproj" /m /p:Configuration=$Configuration /p:Platform=$Platform /p:OutDir="$OutputDir\" 2>&1 | Tee-Object -FilePath $msbuildLog

if (Test-Path $targetExe) {
    Write-Host "MSBuild succeeded in producing: $targetExe"
    $builtViaMSBuild = $true
} else {
    Write-Warning "MSBuild did not produce $targetExe. Falling back to direct WDK/SDK compilation..."
}

# Method 2: Direct compilation via SDK/WDK tools
if (-not $builtViaMSBuild) {
    Write-Host "--- Compiling devcon.exe directly using MSVC ARM64 toolchain ---"
    
    if (-not (Test-Path $clArm64)) { throw "MSVC ARM64 cl.exe not found: $clArm64" }
    if (-not (Test-Path $linkArm64)) { throw "MSVC ARM64 link.exe not found: $linkArm64" }
    if (-not (Test-Path $mcExe)) { throw "SDK mc.exe not found: $mcExe" }
    if (-not (Test-Path $rcExe)) { throw "SDK rc.exe not found: $rcExe" }

    # Step 1: Run mc.exe on msg.mc
    Write-Host "[1/4] Compiling message compiler file msg.mc..."
    & $mcExe -U -r "$PSScriptRoot" -h "$PSScriptRoot" "$PSScriptRoot\msg.mc"
    if ($LASTEXITCODE -ne 0) { throw "mc.exe failed with exit code $LASTEXITCODE" }

    # Step 2: Run rc.exe on devcon.rc
    Write-Host "[2/4] Compiling resource script devcon.rc..."
    $resFile = Join-Path $OutputDir "devcon.res"
    & $rcExe /r /fo "$resFile" /i "$sdkInclude\um" /i "$sdkInclude\shared" /i "$sdkInclude\ucrt" /i "$PSScriptRoot" "$PSScriptRoot\devcon.rc"
    if ($LASTEXITCODE -ne 0) { throw "rc.exe failed with exit code $LASTEXITCODE" }

    # Step 3: Run cl.exe to compile source files to object files
    Write-Host "[3/4] Compiling C++ source files for ARM64..."
    $sources = @("$PSScriptRoot\devcon.cpp", "$PSScriptRoot\cmds.cpp", "$PSScriptRoot\dump.cpp")
    $cflags = @(
        "/c",
        "/O2",
        "/W3",
        "/DUNICODE",
        "/D_UNICODE",
        "/DNDEBUG",
        "/DWIN32_LEAN_AND_MEAN",
        "/I", "$sdkInclude\um",
        "/I", "$sdkInclude\shared",
        "/I", "$sdkInclude\ucrt",
        "/I", "$vcInclude",
        "/I", "$PSScriptRoot",
        "/Fo$OutputDir\"
    )
    & $clArm64 @cflags @sources
    if ($LASTEXITCODE -ne 0) { throw "cl.exe failed with exit code $LASTEXITCODE" }

    # Step 4: Run link.exe to produce ARM64 devcon.exe
    Write-Host "[4/4] Linking ARM64 devcon.exe..."
    $objFiles = @(
        Join-Path $OutputDir "devcon.obj",
        Join-Path $OutputDir "cmds.obj",
        Join-Path $OutputDir "dump.obj"
    )
    $linkFlags = @(
        "/MACHINE:ARM64",
        "/SUBSYSTEM:CONSOLE",
        "/OPT:REF",
        "/OPT:ICF",
        "/LIBPATH:$sdkLib\um\arm64",
        "/LIBPATH:$sdkLib\ucrt\arm64",
        "/LIBPATH:$vcLib\arm64",
        "/OUT:$targetExe"
    )
    $libs = @("setupapi.lib", "cfgmgr32.lib", "advapi32.lib", "kernel32.lib", "user32.lib", "ole32.lib", "shell32.lib")
    & $linkArm64 @linkFlags @objFiles $resFile @libs
    if ($LASTEXITCODE -ne 0) { throw "link.exe failed with exit code $LASTEXITCODE" }
}

# Validation
if (-not (Test-Path $targetExe)) {
    throw "Target executable was not produced: $targetExe"
}

$fileItem = Get-Item $targetExe
$fileSize = $fileItem.Length
$fileHash = (Get-FileHash -Path $targetExe -Algorithm SHA256).Hash

Write-Host "=== devcon.exe Built Successfully ==="
Write-Host "Target Path: $targetExe"
Write-Host "File Size: $fileSize bytes"
Write-Host "SHA-256: $fileHash"

if ($dumpbin) {
    Write-Host "=== Validating Architecture with dumpbin.exe ==="
    $dumpbinOut = & $dumpbin /headers $targetExe
    $isArm64 = $dumpbinOut | Where-Object { $_ -match 'machine \(ARM64\)' -or $_ -match 'AA64 machine \(ARM64\)' }
    if (-not $isArm64) {
        throw "Binary is NOT ARM64! dumpbin output:`n$($dumpbinOut -join "`n")"
    }
    Write-Host "Verified PE Machine Type: ARM64 (0xAA64)"
}

Write-Host "ALL CHECKS PASSED FOR DEVCON ARM64"
