# FluxMilestone3.ps1
# Controlled Driver Update & Multi-Mode Resolution Testing with Multi-Monitor Discovery
$ErrorActionPreference = 'Continue'

function Log($line) {
    Write-Output $line
}

Log "========================================================"
Log "FLUX MILESTONE 3: CONTROLLED DRIVER UPDATE & RESOLUTION TEST"
Log "========================================================"
Log ("TIMESTAMP=" + (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"))
Log ("RUNNING_AS=" + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("IS_ADMIN=" + $(if ($isAdmin) { "YES" } else { "NO" }))

# Find media drive containing FluxIdd and FluxTools
$mediaDrive = $null
foreach ($d in @('D', 'E', 'F', 'C')) {
    if (Test-Path "$($d):\FluxIdd\FluxIdd.inf") {
        $mediaDrive = "$($d):"
        break
    }
}
Log ("MEDIA_DRIVE=" + $(if ($mediaDrive) { $mediaDrive } else { "NONE" }))

# Compile DisplayHelper with full multi-monitor discovery and ChangeDisplaySettingsExW
try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;

    public class DisplayHelper {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
            public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation;
            public int dmDisplayFixedOutput; public short dmColor; public short dmDuplex; public short dmYResolution;
            public short dmTTOption; public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
            public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
            public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
            public int dmPanningWidth; public int dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevicesW(string lpDevice, int iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, int dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsExW(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsW(ref DEVMODE lpDevMode, int dwflags);

        public static string GetFluxDeviceName() {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(dd);
            for (int i = 0; EnumDisplayDevicesW(null, i, ref dd, 0); i++) {
                if ((dd.DeviceString != null && dd.DeviceString.IndexOf("Flux", StringComparison.OrdinalIgnoreCase) >= 0) ||
                    (dd.DeviceID != null && dd.DeviceID.IndexOf("FLUX", StringComparison.OrdinalIgnoreCase) >= 0) ||
                    (dd.DeviceID != null && dd.DeviceID.IndexOf("SWD\\", StringComparison.OrdinalIgnoreCase) >= 0)) {
                    return dd.DeviceName;
                }
            }
            // If not found by string, return secondary display if available
            for (int i = 0; EnumDisplayDevicesW(null, i, ref dd, 0); i++) {
                if (dd.DeviceName != @"\\.\DISPLAY1") {
                    return dd.DeviceName;
                }
            }
            return @"\\.\DISPLAY1";
        }

        public static string GetCurrentMode(string deviceName) {
            if (string.IsNullOrEmpty(deviceName)) deviceName = GetFluxDeviceName();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            if (EnumDisplaySettingsW(deviceName, -1, ref dm)) {
                return dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency + "Hz";
            }
            if (EnumDisplaySettingsW(null, -1, ref dm)) {
                return dm.dmPelsWidth + "x" + dm.dmPelsHeight + "@" + dm.dmDisplayFrequency + "Hz";
            }
            return "UNKNOWN";
        }

        public static int GetCurrentWidth(string deviceName) {
            if (string.IsNullOrEmpty(deviceName)) deviceName = GetFluxDeviceName();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            if (EnumDisplaySettingsW(deviceName, -1, ref dm)) { return dm.dmPelsWidth; }
            if (EnumDisplaySettingsW(null, -1, ref dm)) { return dm.dmPelsWidth; }
            return 0;
        }

        public static int GetCurrentHeight(string deviceName) {
            if (string.IsNullOrEmpty(deviceName)) deviceName = GetFluxDeviceName();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            if (EnumDisplaySettingsW(deviceName, -1, ref dm)) { return dm.dmPelsHeight; }
            if (EnumDisplaySettingsW(null, -1, ref dm)) { return dm.dmPelsHeight; }
            return 0;
        }

        public static int SetResolution(string deviceName, int width, int height) {
            if (string.IsNullOrEmpty(deviceName)) deviceName = GetFluxDeviceName();
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(dm);
            dm.dmPelsWidth = width;
            dm.dmPelsHeight = height;
            dm.dmFields = 0x00080000 | 0x00100000; // DM_PELSWIDTH | DM_PELSHEIGHT

            int res = ChangeDisplaySettingsExW(deviceName, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
            if (res == 0) {
                // Persist in registry
                ChangeDisplaySettingsExW(deviceName, ref dm, IntPtr.Zero, 0x00000001 | 0x00000008, IntPtr.Zero);
            }
            return res;
        }
    }
"@
    Log "DISPLAY_HELPER_LOADED=YES"
} catch {
    Log ("DISPLAY_HELPER_ERR=" + $_.Exception.Message)
}

# ----------------------------------------------------
# STEP 1: PRE-UPDATE BASELINE EVIDENCE & DISPLAY ENUM
# ----------------------------------------------------
Log ""
Log "--- BEGIN STEP 1: PRE-UPDATE BASELINE EVIDENCE ---"

$preSwd = @(Get-CimInstance Win32_PnPEntity | Where-Object { 
    $_.DeviceID -eq 'SWD\FluxIdd\0' -or ($_.HardwareID -and ($_.HardwareID -contains 'ROOT\FLUX_IDD' -or $_.HardwareID -contains 'FluxIdd'))
})
Log ("PRE_SWD_COUNT=" + $preSwd.Count)
if ($preSwd.Count -ge 1) {
    Log ("PRE_DEVICE_ID=" + $preSwd[0].DeviceID)
    Log ("PRE_DEVICE_STATUS=" + $preSwd[0].Status)
    Log ("PRE_PROBLEM_CODE=" + $preSwd[0].ConfigManagerErrorCode)
    Log ("PRE_SERVICE=" + $preSwd[0].Service)
}

$preDaemon = @(Get-Process -Name FluxDevNode -ErrorAction SilentlyContinue)
Log ("PRE_FLUXDEVNODE_PROCESS_COUNT=" + $preDaemon.Count)

$preWudf = @(Get-Process -Name WUDFHost -ErrorAction SilentlyContinue)
Log ("PRE_WUDFHOST_PROCESS_COUNT=" + $preWudf.Count)

$preModules = @(Get-Process | ForEach-Object { try { $_.Modules } catch {} } | Where-Object { $_.ModuleName -like '*FluxIdd*' })
Log ("PRE_FLUXIDD_DLL_LOADED=" + $(if ($preModules.Count -gt 0) { "YES" } else { "NO" }))

$preDrv = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq 'SWD\FluxIdd\0' })
if ($preDrv.Count -ge 1) {
    Log ("PRE_DRIVER_VERSION=" + $preDrv[0].DriverVersion)
    Log ("PRE_DRIVER_INF=" + $preDrv[0].InfName)
}

# Enumerate all display devices in system
try {
    Log "--- ENUMERATING ALL DISPLAY DEVICES ---"
    $dd = New-Object DisplayHelper+DISPLAY_DEVICE
    $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
    for ($i = 0; [DisplayHelper]::EnumDisplayDevicesW($null, $i, [ref]$dd, 0); $i++) {
        Log ("DISP_DEV[$i]: Name=" + $dd.DeviceName + " String=" + $dd.DeviceString + " Flags=0x" + $dd.StateFlags.ToString("X") + " ID=" + $dd.DeviceID)
        $dmCur = New-Object DisplayHelper+DEVMODE
        $dmCur.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dmCur)
        if ([DisplayHelper]::EnumDisplaySettingsW($dd.DeviceName, -1, [ref]$dmCur)) {
            Log ("  Mode: " + $dmCur.dmPelsWidth + "x" + $dmCur.dmPelsHeight + "@" + $dmCur.dmDisplayFrequency + "Hz")
        }
    }
} catch {
    Log ("DISP_ENUM_ERR=" + $_.Exception.Message)
}

$fluxTargetDevice = [DisplayHelper]::GetFluxDeviceName()
Log ("FLUX_TARGET_DEVICE=" + $fluxTargetDevice)
Log ("PRE_FLUX_DISPLAY_MODE=" + [DisplayHelper]::GetCurrentMode($fluxTargetDevice))
Log ("PRE_DEFAULT_DISPLAY_MODE=" + [DisplayHelper]::GetCurrentMode($null))

if (Test-Path "C:\Users\Public\flux_swapchain_status.txt") {
    Log "--- PRE_SWAPCHAIN_STATUS ---"
    Get-Content "C:\Users\Public\flux_swapchain_status.txt" | ForEach-Object { Log ("PRE_" + $_) }
}
Log "--- END STEP 1: PRE-UPDATE BASELINE EVIDENCE ---"

# ----------------------------------------------------
# STEP 2: DRIVER PACKAGE & HELPER VERIFICATION
# ----------------------------------------------------
Log ""
Log "--- BEGIN STEP 2: DRIVER PACKAGE VERIFICATION ---"

if ($mediaDrive) {
    $pkgCer = Join-Path $mediaDrive "FluxIdd\FluxIddTestCert.cer"
    $pkgInf = Join-Path $mediaDrive "FluxIdd\FluxIdd.inf"
    $newHelper = Join-Path $mediaDrive "FluxTools\FluxDevNode.exe"
    $destHelper = "C:\FluxTools\FluxDevNode.exe"

    if (Test-Path $pkgCer) {
        try {
            & certutil.exe -addstore -f Root $pkgCer | Out-Null
            & certutil.exe -addstore -f TrustedPublisher $pkgCer | Out-Null
            Log "CERT_IMPORT=SUCCESS"
        } catch {
            Log ("CERT_IMPORT_ERR=" + $_.Exception.Message)
        }
    }

    # Update helper binary if media has a copy
    if (Test-Path $newHelper) {
        try {
            Stop-ScheduledTask -TaskName "FluxDevNode" -ErrorAction SilentlyContinue
            & $destHelper stop | Out-Null
            Start-Sleep -Seconds 2
            Copy-Item -LiteralPath $newHelper -Destination $destHelper -Force
            Start-ScheduledTask -TaskName "FluxDevNode"
            Start-Sleep -Seconds 3
            Log "UPDATED_C_FLUXTOOLS_HELPER=YES"
            Log ("NEW_HELPER_SHA256=" + (Get-FileHash -LiteralPath $destHelper -Algorithm SHA256).Hash)
        } catch {
            Log ("UPDATE_HELPER_ERR=" + $_.Exception.Message)
        }
    }

    # Install/update driver package from media
    if (Test-Path $pkgInf) {
        Log ("UPDATING_DRIVER_PACKAGE=" + $pkgInf)
        try {
            $pnpAdd = & pnputil.exe /add-driver $pkgInf /install 2>&1
            foreach ($l in $pnpAdd) { Log ("PNPUTIL_ADD: " + $l) }

            # Restart SWD\FluxIdd\0 so WUDFHost reloads the newly installed driver DLL
            Log "RESTARTING_DEVICE_PNPUTIL: SWD\FluxIdd\0"
            $pnpRestart = & pnputil.exe /restart-device "SWD\FluxIdd\0" 2>&1
            foreach ($r in $pnpRestart) { Log ("PNPUTIL_RESTART: " + $r) }
            Log "SETTLE_AFTER_RESTART=10s"
            Start-Sleep -Seconds 10
        } catch {
            Log ("DRIVER_UPDATE_ERR=" + $_.Exception.Message)
        }
    }
}
Log "--- END STEP 2: DRIVER PACKAGE VERIFICATION ---"

# ----------------------------------------------------
# STEP 3: POST-UPDATE VERIFICATION
# ----------------------------------------------------
Log ""
Log "--- BEGIN STEP 3: POST-UPDATE VERIFICATION ---"

$postSwd = @(Get-CimInstance Win32_PnPEntity | Where-Object { 
    $_.DeviceID -eq 'SWD\FluxIdd\0' -or ($_.HardwareID -and ($_.HardwareID -contains 'ROOT\FLUX_IDD' -or $_.HardwareID -contains 'FluxIdd'))
})
Log ("POST_SWD_COUNT=" + $postSwd.Count)
if ($postSwd.Count -ge 1) {
    Log ("POST_DEVICE_ID=" + $postSwd[0].DeviceID)
    Log ("POST_DEVICE_STATUS=" + $postSwd[0].Status)
    Log ("POST_PROBLEM_CODE=" + $postSwd[0].ConfigManagerErrorCode)
    Log ("POST_SERVICE=" + $postSwd[0].Service)
}

$drv = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq 'SWD\FluxIdd\0' })
if ($drv.Count -ge 1) {
    Log ("POST_DRIVER_PROVIDER=" + $drv[0].DriverProviderName)
    Log ("POST_DRIVER_VERSION=" + $drv[0].DriverVersion)
    Log ("POST_DRIVER_INF=" + $drv[0].InfName)
}

$postDaemon = @(Get-Process -Name FluxDevNode -ErrorAction SilentlyContinue)
Log ("POST_FLUXDEVNODE_PROCESS_COUNT=" + $postDaemon.Count)

$postWudf = @(Get-Process -Name WUDFHost -ErrorAction SilentlyContinue)
Log ("POST_WUDFHOST_PROCESS_COUNT=" + $postWudf.Count)

$postModules = @(Get-Process | ForEach-Object { try { $_.Modules } catch {} } | Where-Object { $_.ModuleName -like '*FluxIdd*' })
Log ("POST_FLUXIDD_DLL_LOADED=" + $(if ($postModules.Count -gt 0) { "YES" } else { "NO" }))

$postTargetDevice = [DisplayHelper]::GetFluxDeviceName()
Log ("POST_FLUX_TARGET_DEVICE=" + $postTargetDevice)
Log "--- END STEP 3: POST-UPDATE VERIFICATION ---"

# ----------------------------------------------------
# STEP 4: MULTI-MODE RESOLUTION TESTING (SEQUENTIAL)
# ----------------------------------------------------
Log ""
Log "--- BEGIN STEP 4: MULTI-MODE RESOLUTION TESTING ---"

$modes = @(
    @{ Width = 800;  Height = 600;  Name = "SVGA_800x600" },
    @{ Width = 1280; Height = 720;  Name = "HD_1280x720" },
    @{ Width = 1600; Height = 900;  Name = "HD_PLUS_1600x900" },
    @{ Width = 1920; Height = 1080; Name = "FULL_HD_1920x1080" }
)

$helperExe = if ($mediaDrive -and (Test-Path (Join-Path $mediaDrive "FluxTools\FluxDevNode.exe"))) {
    Join-Path $mediaDrive "FluxTools\FluxDevNode.exe"
} else {
    "C:\FluxTools\FluxDevNode.exe"
}
Log ("USING_HELPER_EXE=" + $helperExe)

foreach ($m in $modes) {
    Log ""
    Log ("=== TESTING MODE: " + $m.Name + " (" + $m.Width + "x" + $m.Height + ") ===")
    
    # 1. Request resolution change via helper specifying target device
    Log ("INVOKING: " + $helperExe + " setres " + $m.Width + " " + $m.Height + " " + $postTargetDevice)
    $setResOut = & $helperExe setres $m.Width $m.Height $postTargetDevice 2>&1
    foreach ($line in $setResOut) {
        Log ("SETRES_OUT: " + $line)
    }

    # 2. If helper returned error (or didn't succeed), invoke SetResolution directly via DisplayHelper
    $helperSuccess = ($setResOut | Where-Object { $_ -like '*DISP_CHANGE_SUCCESSFUL*' })
    if (-not $helperSuccess) {
        Log "INVOKING_DISPLAYHELPER_DIRECT: SetResolution(" + $postTargetDevice + ", " + $m.Width + ", " + $m.Height + ")"
        $dhRes = [DisplayHelper]::SetResolution($postTargetDevice, $m.Width, $m.Height)
        Log ("DISPLAYHELPER_DIRECT_RESULT=" + $dhRes)
    }

    # 3. Settle 4 seconds for display reconfiguration & swapchain re-creation
    Start-Sleep -Seconds 4

    # 4. Query actual active resolution via EnumDisplaySettings for both target device and default
    $actW = 0
    $actH = 0
    $actMode = "UNKNOWN"
    try {
        $actMode = [DisplayHelper]::GetCurrentMode($postTargetDevice)
        $actW = [DisplayHelper]::GetCurrentWidth($postTargetDevice)
        $actH = [DisplayHelper]::GetCurrentHeight($postTargetDevice)
    } catch {}

    Log ("ACTIVE_DISPLAY_MODE=" + $actMode)
    Log ("ACTIVE_WIDTH=" + $actW)
    Log ("ACTIVE_HEIGHT=" + $actH)

    $modeMatch = ($actW -eq $m.Width -and $actH -eq $m.Height)
    Log ("MODE_SWITCH_CONFIRMED=" + $(if ($modeMatch) { "YES" } else { "NO" }))

    # 5. Check swapchain status file
    if (Test-Path "C:\Users\Public\flux_swapchain_status.txt") {
        $sc = Get-Content "C:\Users\Public\flux_swapchain_status.txt"
        $wLine = $sc | Where-Object { $_ -like 'FRAME_WIDTH=*' }
        $hLine = $sc | Where-Object { $_ -like 'FRAME_HEIGHT=*' }
        $seqLine = $sc | Where-Object { $_ -like 'FRAME_TRANSPORT_SEQUENCE=*' }
        $cntLine = $sc | Where-Object { $_ -like 'FRAME_ACQUIRE_COUNT=*' }
        Log ("SWAPCHAIN_" + $wLine)
        Log ("SWAPCHAIN_" + $hLine)
        Log ("SWAPCHAIN_" + $seqLine)
        Log ("SWAPCHAIN_" + $cntLine)
    }
}
Log "--- END STEP 4: MULTI-MODE RESOLUTION TESTING ---"

# ----------------------------------------------------
# STEP 5: START RESOLUTION AGENT IN BACKGROUND
# ----------------------------------------------------
Log ""
Log "--- BEGIN STEP 5: START RESOLUTION AGENT ---"

$resAgentProc = @(Get-Process -Name FluxDevNode | Where-Object { 
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
        $cmd -like '*resagent*'
    } catch { $false }
})

if ($resAgentProc.Count -eq 0) {
    Log "STARTING_RESAGENT: C:\FluxTools\FluxDevNode.exe resagent D:\flux_resolution_request.txt 250"
    $reqFile = if ($mediaDrive) { "$($mediaDrive)\flux_resolution_request.txt" } else { "C:\Users\Public\flux_resolution_request.txt" }
    Start-Process -FilePath $helperExe -ArgumentList "resagent $reqFile 250" -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $agentAfter = @(Get-Process -Name FluxDevNode | Where-Object {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
            $cmd -like '*resagent*'
        } catch { $false }
    })
    Log ("RESAGENT_STARTED=" + $(if ($agentAfter.Count -ge 1) { "YES" } else { "NO" }))
} else {
    Log "RESAGENT_ALREADY_RUNNING=YES"
}
Log "--- END STEP 5: START RESOLUTION AGENT ---"

Log ""
Log "========================================================"
Log "MILESTONE 3 AUTOMATION SCRIPT COMPLETE"
Log "========================================================"
Log ("END_TIMESTAMP=" + (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"))
