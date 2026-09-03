<#
.SYNOPSIS
    Local, read-only readiness and health check for the Microsoft Defender for
    Endpoint plug-in for Windows Subsystem for Linux (WSL) 2 on a single host.

.DESCRIPTION
    This is a host-local diagnostic script, not a tenant-wide Graph audit — the
    WSL plug-in has no Graph/Intune-readable configuration or health surface as of
    this writing, so per-machine visibility depends entirely on running this (or the
    plug-in's own healthcheck.exe) directly on each Windows host.

    The script checks, in dependency order:
      1. Host OS build/architecture eligibility (non-ARM64, non-multi-session,
         Windows 10 2004+/19044+ or Windows 11)
      2. Host Defender for Endpoint onboarding status (Sense service)
      3. WSL version and per-distro WSL1-vs-WSL2 state
      4. Plug-in installation footprint (DLL + healthcheck.exe present)
      5. Plug-in self-reported health, by invoking healthcheck.exe if present
      6. .wslconfig custom-kernel usage (a documented visibility-limiting
         configuration the plug-in doesn't block but doesn't guarantee coverage for)
      7. Custom device-tagging registry configuration, if present

    It does NOT and cannot: confirm the WSL2 instance has actually registered as a
    device object in the Microsoft Defender portal (no local API for that — verify
    in the portal, filtered on tag WSL2, or via Advanced Hunting's DeviceInfo table
    using the HostDeviceId join), or remotely audit a fleet of machines in one pass
    (run it via Intune remediation script / proactive remediation for fleet-wide
    coverage instead).

.PARAMETER ExportPath
    Full path for a CSV summary of this run's findings. Defaults to a timestamped
    file in the current user's Documents folder.

.EXAMPLE
    .\Get-MDEWSLPluginHealth.ps1

    Runs all checks against the local host and writes a CSV summary.

.EXAMPLE
    .\Get-MDEWSLPluginHealth.ps1 -ExportPath C:\Temp\wsl-plugin-health.csv

.NOTES
    Run locally on the Windows host in question (not remotely) — WSL and the
    plug-in's healthcheck.exe are only meaningfully queryable from an interactive
    or remote-PowerShell session on that exact machine.
    Read-only. Does not install, repair, or configure anything.
    Requires: Windows PowerShell 5.1+ or PowerShell 7+. No elevation required for
    the checks themselves, though some source commands (Get-Service) may return
    partial data for non-admin callers on hardened systems.
#>
[CmdletBinding()]
param(
    [string]$ExportPath = (Join-Path $env:USERPROFILE "Documents\MDE-WSL-PluginHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [ordered]@{
    ComputerName              = $env:COMPUTERNAME
    Timestamp                 = (Get-Date).ToString("s")
    OSBuild                   = $null
    Architecture               = $null
    IsMultiSession             = $null
    EligibleHostPlatform       = $null
    SenseServiceStatus         = $null
    HostOnboarded               = $null
    WslVersionRaw               = $null
    WslVersionMeetsFloor        = $null
    DistrosSummary               = $null
    AnyDistroOnWsl1              = $null
    PluginDllPresent             = $null
    HealthcheckExePresent        = $null
    HealthcheckOutput            = $null
    DefenderHealthStatus         = $null
    CustomKernelConfigured       = $null
    CustomDeviceTag              = $null
    OverrideReleaseRing          = $null
}

Write-Status "Checking host OS eligibility..." 
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $results.OSBuild = $os.BuildNumber
    $results.Architecture = $os.OSArchitecture
    $results.IsMultiSession = ($os.Caption -match "Multi-Session|Session Host")
    $meetsBuildFloor = [int]$os.BuildNumber -ge 19044
    $isArm64 = $os.OSArchitecture -match "ARM"
    $results.EligibleHostPlatform = ($meetsBuildFloor -and (-not $isArm64) -and (-not $results.IsMultiSession))
    if ($results.EligibleHostPlatform) {
        Write-Status "Host platform eligible (build $($os.BuildNumber), $($os.OSArchitecture))" "OK"
    } else {
        Write-Status "Host platform NOT eligible for the WSL plug-in (build floor 19044, non-ARM64, non-multi-session required)" "WARN"
    }
} catch {
    Write-Status "Could not determine host OS eligibility: $_" "ERROR"
}

Write-Status "Checking Defender for Endpoint host onboarding (Sense service)..."
try {
    $sense = Get-Service -Name Sense -ErrorAction Stop
    $results.SenseServiceStatus = $sense.Status
    $results.HostOnboarded = ($sense.Status -eq "Running")
    if ($results.HostOnboarded) {
        Write-Status "Host is onboarded and Sense is running" "OK"
    } else {
        Write-Status "Sense service present but not running (Status: $($sense.Status)) — plug-in cannot function without host onboarding" "WARN"
    }
} catch {
    $results.SenseServiceStatus = "NotFound"
    $results.HostOnboarded = $false
    Write-Status "Sense service not found — host is not onboarded to Defender for Endpoint. Resolve host onboarding before troubleshooting the WSL plug-in." "ERROR"
}

Write-Status "Checking WSL version and distro state..."
try {
    $wslVersionRaw = (wsl --version 2>&1 | Out-String).Trim()
    $results.WslVersionRaw = ($wslVersionRaw -split "`n" | Select-Object -First 1)
    if ($wslVersionRaw -match "(\d+\.\d+\.\d+\.\d+)") {
        $ver = [version]($Matches[1])
        $floor = [version]"2.0.7.0"
        $results.WslVersionMeetsFloor = ($ver -ge $floor)
    } else {
        $results.WslVersionMeetsFloor = $null
    }

    $distroListRaw = (wsl -l -v 2>&1 | Out-String)
    $results.DistrosSummary = ($distroListRaw -replace "`0", "").Trim()
    $results.AnyDistroOnWsl1 = ($distroListRaw -match "\s1\s*$" -or $distroListRaw -match "\s1\r?\n")

    if ($results.WslVersionMeetsFloor -eq $true) {
        Write-Status "WSL version meets the 2.0.7.0 floor" "OK"
    } elseif ($results.WslVersionMeetsFloor -eq $false) {
        Write-Status "WSL version is below the 2.0.7.0 floor required by the plug-in — run 'wsl --update'" "WARN"
    } else {
        Write-Status "Could not parse WSL version output" "WARN"
    }

    if ($results.AnyDistroOnWsl1) {
        Write-Status "At least one distro appears to be running under WSL1 — it will not report to the plug-in. Run 'wsl -l -v' to confirm and 'wsl --set-version <name> 2' to upgrade." "WARN"
    }
} catch {
    Write-Status "WSL command not available on this host — WSL may not be installed. ($_)" "ERROR"
}

Write-Status "Checking plug-in installation footprint..."
$dllPath = Join-Path $env:ProgramFiles "Microsoft Defender for Endpoint plug-in for WSL\plug-in\DefenderforEndpointPlug-in.dll"
$toolsDir = Join-Path $env:ProgramFiles "Microsoft Defender for Endpoint plug-in for WSL\tools"
$healthcheckPath = Join-Path $toolsDir "healthcheck.exe"

$results.PluginDllPresent = Test-Path $dllPath
$results.HealthcheckExePresent = Test-Path $healthcheckPath

if ($results.PluginDllPresent) {
    Write-Status "Plug-in DLL found at $dllPath" "OK"
} else {
    Write-Status "Plug-in DLL NOT found — plug-in is not installed on this host. Download from the Defender portal (Settings > Endpoints > Onboarding > 'Windows Subsystem for Linux 2 (plug-in)')." "WARN"
}

if ($results.HealthcheckExePresent) {
    Write-Status "Running plug-in healthcheck.exe..."
    try {
        Push-Location $toolsDir
        $hcOutput = (& .\healthcheck.exe 2>&1 | Out-String).Trim()
        Pop-Location
        $results.HealthcheckOutput = $hcOutput -replace "`r?`n", " | "
        if ($hcOutput -match "Healthy") {
            $results.DefenderHealthStatus = "Healthy"
            Write-Status "healthcheck.exe reports Healthy" "OK"
        } elseif ($hcOutput -match "retry in five minutes") {
            $results.DefenderHealthStatus = "PendingStartup"
            Write-Status "healthcheck.exe reports a startup-timing message (not an error) — re-run after 5+ minutes with a distro running" "WARN"
        } else {
            $results.DefenderHealthStatus = "Unknown/Unhealthy"
            Write-Status "healthcheck.exe did not report Healthy — review full output" "WARN"
        }
    } catch {
        $results.DefenderHealthStatus = "ErrorRunning"
        Write-Status "Error running healthcheck.exe: $_" "ERROR"
    }
} else {
    Write-Status "healthcheck.exe not found — cannot verify plug-in self-reported health" "WARN"
}

Write-Status "Checking .wslconfig for custom kernel configuration..."
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
if (Test-Path $wslConfigPath) {
    $wslConfigContent = Get-Content $wslConfigPath -Raw
    $results.CustomKernelConfigured = ($wslConfigContent -match "(?im)^\s*kernel\s*=" -or $wslConfigContent -match "(?im)^\s*kernelCommandLine\s*=")
    if ($results.CustomKernelConfigured) {
        Write-Status "Custom kernel or kernelCommandLine found in .wslconfig — plug-in visibility is not guaranteed for this configuration" "WARN"
    } else {
        Write-Status "No custom kernel configuration found in .wslconfig" "OK"
    }
} else {
    $results.CustomKernelConfigured = $false
    Write-Status ".wslconfig not present — no custom kernel configuration (default kernel in use)" "OK"
}

Write-Status "Checking custom device-tag and release-ring registry overrides..."
try {
    $tagKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging"
    $results.CustomDeviceTag = (Get-ItemProperty -Path $tagKey -Name "GROUP" -ErrorAction SilentlyContinue).GROUP
} catch { $results.CustomDeviceTag = $null }
try {
    $ringKey = "HKLM:\SOFTWARE\Microsoft\Microsoft Defender for Endpoint plug-in for WSL"
    $results.OverrideReleaseRing = (Get-ItemProperty -Path $ringKey -Name "OverrideReleaseRing" -ErrorAction SilentlyContinue).OverrideReleaseRing
} catch { $results.OverrideReleaseRing = $null }

$row = [pscustomobject]$results
$row | Format-List
$row | Export-Csv -Path $ExportPath -NoTypeInformation -Force
Write-Status "Summary exported to $ExportPath" "OK"
