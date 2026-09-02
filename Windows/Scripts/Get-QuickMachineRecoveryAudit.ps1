<#
.SYNOPSIS
    Audits Quick Machine Recovery (QMR) eligibility, effective configuration, management-state
    default expectations, and WinRE network readiness on the local machine.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/QuickMachineRecovery-B.md and -A.md.
    Runs in one pass everything the runbooks' triage and diagnosis steps ask for:
    - WinRE enablement state (hard prerequisite for QMR and Startup Repair alike)
    - OS edition/build eligibility (flags the documented discrepancy between Microsoft's
      Support-article minimum build and the higher Recovery CSP reference minimum)
    - Effective recovery settings via reagentc.exe /getrecoverysettings (CloudRemediation,
      AutoRemediation + timers, and any configured WinRE Wi-Fi fallback profile)
    - Whether the observed CloudRemediation state matches the EXPECTED default for this
      device's management state (unmanaged vs. domain/MDM-managed), flagging a mismatch
      as "likely an explicit legacy/sticky setting" rather than a fault
    - Auto-remediation timer relationship validation (retry interval must be <= time to reboot)
    - Network adapter inventory as a WinRE-connectivity readiness signal (wired presence is
      the strongest positive signal; Wi-Fi-only devices need their SSID's security type
      confirmed manually, since this script cannot determine 802.1X vs. WPA2-PSK from here)
    - Recent MDM/CSP policy delivery activity (sync health signal only)

    Produces a console summary with pass/fail/info per check and exports full detail to CSV.
    Any WinRE Wi-Fi password found in /getrecoverysettings output is REDACTED before both
    console display and CSV export.

    Does NOT cover:
    - Fixing any detected issue (that's QuickMachineRecovery-B.md Fix 1-6 / -A.md Playbooks 1-3)
    - Enabling/disabling QMR itself (a policy change, not a diagnostic action)
    - Determining whether a specific Wi-Fi SSID uses 802.1X vs. WPA2-PSK (no local API exposes
      this reliably for the currently-connected profile in all cases — verify with network team)
    - Fleet-wide auditing — this is a single-machine diagnostic; there is no documented Graph/
      Intune reporting surface for QMR remediation history across a tenant

.PARAMETER ExportPath
    Path for CSV export. Default: .\QuickMachineRecoveryAudit-<timestamp>.csv

.EXAMPLE
    .\Get-QuickMachineRecoveryAudit.ps1
    Audits local QMR eligibility, effective configuration, and WinRE network readiness.

.EXAMPLE
    .\Get-QuickMachineRecoveryAudit.ps1 -ExportPath C:\Temp\qmr-audit.csv
    Audits and exports results to a specific CSV path.

.NOTES
    Requires: Windows PowerShell 5.1+, Windows 11 24H2/25H2 (script is safe to run on older
              builds/editions too — it will simply report ineligibility)
    Run-as: Administrator required (reagentc.exe and WinRE state queries need elevation)
    Safe: Fully read-only. No configuration changes, no WinRE enable/disable, no policy writes.
          Redacts any WinRE Wi-Fi password before it is displayed or exported.
#>

[CmdletBinding()]
param(
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Status "This script should be run elevated — reagentc.exe queries will likely fail without it." "WARN"
}

if (-not $ExportPath) {
    $ExportPath = ".\QuickMachineRecoveryAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

Write-Status "Starting Quick Machine Recovery audit..." "INFO"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. WinRE status (hard prerequisite)
# ---------------------------------------------------------------------------
Write-Status "Checking Windows Recovery Environment (WinRE) status..." "INFO"
$winREEnabled = $false
try {
    $reagentInfo = & reagentc.exe /info 2>&1 | Out-String
    if ($reagentInfo -match "Enabled") {
        $winREEnabled = $true
        Add-Result -Check "WinRE Status" -Status "OK" -Detail "Enabled"
        Write-Status "WinRE is Enabled" "OK"
    } elseif ($reagentInfo -match "Disabled") {
        Add-Result -Check "WinRE Status" -Status "ERROR" -Detail "Disabled — QMR cannot function until WinRE is re-enabled (reagentc /enable)"
        Write-Status "WinRE is Disabled — QMR cannot function. Nothing further in this audit matters until this is fixed." "ERROR"
    } else {
        Add-Result -Check "WinRE Status" -Status "WARN" -Detail "Could not parse reagentc /info output: $reagentInfo"
        Write-Status "Could not determine WinRE status from reagentc /info output" "WARN"
    }
} catch {
    Add-Result -Check "WinRE Status" -Status "ERROR" -Detail "Failed to run reagentc.exe /info: $($_.Exception.Message)"
    Write-Status "Failed to run reagentc.exe /info — is this script running elevated?" "ERROR"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 2. OS edition/build eligibility
# ---------------------------------------------------------------------------
Write-Status "Checking OS edition and build eligibility..." "INFO"
try {
    $osInfo = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
    $displayVersion = $osInfo.DisplayVersion
    $currentBuild = [int]$osInfo.CurrentBuild
    $ubr = $osInfo.UBR
    $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption

    Add-Result -Check "OS Version" -Status "INFO" -Detail "$edition, $displayVersion, Build $currentBuild.$ubr"
    Write-Status "OS: $edition, $displayVersion, Build $currentBuild.$ubr" "INFO"

    # Support-article minimum: 24H2 build 26100.4700+
    # Recovery CSP reference minimum (higher, more recent): 24H2 26100.8737+ / 25H2 26200.8737+
    $meetsSupportMin = ($currentBuild -ge 26100) -and (($currentBuild -gt 26100) -or ([int]$ubr -ge 4700))
    $meetsCspMin = $false
    if ($currentBuild -eq 26100 -and [int]$ubr -ge 8737) { $meetsCspMin = $true }
    if ($currentBuild -eq 26200 -and [int]$ubr -ge 8737) { $meetsCspMin = $true }
    if ($currentBuild -gt 26200) { $meetsCspMin = $true }

    if ($meetsCspMin) {
        Add-Result -Check "Build Eligibility" -Status "OK" -Detail "Meets the higher Recovery CSP reference minimum (26100.8737+/26200.8737+)"
        Write-Status "Build meets the Recovery CSP reference minimum" "OK"
    } elseif ($meetsSupportMin) {
        Add-Result -Check "Build Eligibility" -Status "WARN" -Detail "Meets the Support-article minimum (26100.4700+) but NOT the higher CSP-reference minimum (26100.8737+/26200.8737+) — Microsoft's two own pages disagree; treat this device as borderline"
        Write-Status "Build meets the LOWER Support-article minimum only — CSP reference wants a higher build. Treat as borderline." "WARN"
    } else {
        Add-Result -Check "Build Eligibility" -Status "ERROR" -Detail "Below both documented minimums — QMR configuration will have no effect"
        Write-Status "Build is below both documented minimums for QMR" "ERROR"
    }
} catch {
    Add-Result -Check "OS Version" -Status "ERROR" -Detail "Failed to read OS version info: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Effective recovery settings (redact any Wi-Fi password)
# ---------------------------------------------------------------------------
Write-Status "Reading effective recovery settings (reagentc /getrecoverysettings)..." "INFO"
try {
    $rawSettings = & reagentc.exe /getrecoverysettings 2>&1 | Out-String
    $redactedSettings = $rawSettings -replace '(password=")[^"]*(")', '$1[REDACTED]$2'

    if ($rawSettings -match 'CloudRemediation state="(\d)"') {
        $cloudState = $matches[1]
        if ($cloudState -eq "1") {
            Add-Result -Check "CloudRemediation" -Status "INFO" -Detail "Enabled (state=1)"
            Write-Status "CloudRemediation: Enabled" "INFO"
        } else {
            Add-Result -Check "CloudRemediation" -Status "INFO" -Detail "Disabled (state=0)"
            Write-Status "CloudRemediation: Disabled" "INFO"
        }
    } else {
        Add-Result -Check "CloudRemediation" -Status "WARN" -Detail "Could not parse CloudRemediation state from output"
    }

    if ($rawSettings -match 'AutoRemediation state="(\d)"(?:\s+totalwaittime="(\d+)")?(?:\s+waitinterval="(\d+)")?') {
        $autoState = $matches[1]
        $totalWait = $matches[2]
        $waitInterval = $matches[3]
        Add-Result -Check "AutoRemediation" -Status "INFO" -Detail "state=$autoState, totalwaittime=$totalWait, waitinterval=$waitInterval"
        Write-Status "AutoRemediation: state=$autoState, totalwaittime=$totalWait min, waitinterval=$waitInterval min" "INFO"

        if ($autoState -eq "1" -and $totalWait -and $waitInterval) {
            if ([int]$waitInterval -gt [int]$totalWait) {
                Add-Result -Check "Timer Relationship" -Status "ERROR" -Detail "waitinterval ($waitInterval) > totalwaittime ($totalWait) — misconfigured, behavior is undocumented/unreliable per Microsoft"
                Write-Status "MISCONFIGURED: retry interval ($waitInterval min) exceeds time-to-reboot ($totalWait min)" "ERROR"
            } else {
                Add-Result -Check "Timer Relationship" -Status "OK" -Detail "waitinterval ($waitInterval) <= totalwaittime ($totalWait)"
                Write-Status "Timer relationship is valid" "OK"
            }
        }
    } else {
        Add-Result -Check "AutoRemediation" -Status "INFO" -Detail "Not configured or not present in output"
    }

    if ($rawSettings -match 'WifiCredential') {
        Add-Result -Check "WinRE Wi-Fi Fallback Profile" -Status "INFO" -Detail "Configured (SSID/password redacted from this export)"
        Write-Status "A WinRE Wi-Fi fallback profile IS configured (password redacted)" "INFO"
    } else {
        Add-Result -Check "WinRE Wi-Fi Fallback Profile" -Status "INFO" -Detail "Not configured — recovery will only work over wired Ethernet unless one is added"
        Write-Status "No WinRE Wi-Fi fallback profile configured — wired-only recovery unless added" "INFO"
    }

    Add-Result -Check "Raw Settings (Redacted)" -Status "INFO" -Detail ($redactedSettings -replace '\s+', ' ').Trim()
} catch {
    Add-Result -Check "Recovery Settings" -Status "ERROR" -Detail "Failed to run reagentc.exe /getrecoverysettings: $($_.Exception.Message)"
    Write-Status "Failed to read recovery settings — is this script running elevated?" "ERROR"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 4. Management state and expected-default cross-check
# ---------------------------------------------------------------------------
Write-Status "Checking management state (for expected-default cross-check)..." "INFO"
try {
    $dsreg = & dsregcmd /status 2>&1 | Out-String
    $azureAdJoined = ($dsreg -match "AzureAdJoined\s*:\s*YES")
    $domainJoined = ($dsreg -match "DomainJoined\s*:\s*YES")
    $isManaged = $azureAdJoined -or $domainJoined
    $edition = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption

    $managedLabel = if ($isManaged) { "Managed (Entra-joined and/or domain-joined)" } else { "Unmanaged (or not Entra/domain-joined)" }
    Add-Result -Check "Management State" -Status "INFO" -Detail $managedLabel
    Write-Status "Management state: $managedLabel" "INFO"

    $isEnterpriseEdition = $edition -match "Enterprise|Education"
    $expectedDefault = if ($isManaged -or $isEnterpriseEdition) { "OFF (managed default)" } else { "ON, one-time scan (unmanaged default)" }
    Add-Result -Check "Expected Default (if never explicitly configured)" -Status "INFO" -Detail $expectedDefault
    Write-Status "Expected default for this device (if never explicitly configured): $expectedDefault" "INFO"
    Write-Status "NOTE: if the observed CloudRemediation state above does not match this expected default," "WARN"
    Write-Status "      it is most likely an explicit legacy/sticky configuration, not a delivery failure." "WARN"
} catch {
    Add-Result -Check "Management State" -Status "WARN" -Detail "Failed to run dsregcmd /status: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 5. Network adapter inventory (WinRE connectivity readiness signal)
# ---------------------------------------------------------------------------
Write-Status "Checking network adapters (WinRE connectivity readiness signal)..." "INFO"
try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq "Up"
    $wiredUp = $adapters | Where-Object { $_.MediaType -eq "802.3" }
    $wirelessUp = $adapters | Where-Object { $_.MediaType -match "Native 802.11|802.11" }

    if ($wiredUp) {
        Add-Result -Check "Wired Connectivity" -Status "OK" -Detail "Wired adapter(s) up: $($wiredUp.Name -join ', ') — strong positive signal for WinRE connectivity"
        Write-Status "Wired adapter(s) up — WinRE should be able to use this automatically" "OK"
    } elseif ($wirelessUp) {
        Add-Result -Check "Wired Connectivity" -Status "WARN" -Detail "No wired adapter up; Wi-Fi-only — confirm production SSID security type (802.1X is NOT supported in WinRE)"
        Write-Status "Wi-Fi-only device — confirm the SSID's security type manually; 802.1X/Enterprise Wi-Fi will NOT work in WinRE" "WARN"
    } else {
        Add-Result -Check "Wired Connectivity" -Status "WARN" -Detail "No active network adapter detected"
    }
} catch {
    Add-Result -Check "Network Adapters" -Status "WARN" -Detail "Failed to query network adapters: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 6. Recent MDM/CSP policy delivery activity (sync health signal only)
# ---------------------------------------------------------------------------
Write-Status "Checking recent MDM/CSP policy delivery activity..." "INFO"
try {
    $mdmEvents = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 20 -ErrorAction Stop
    $recentEvents = $mdmEvents | Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) }
    if ($recentEvents) {
        Add-Result -Check "MDM Policy Activity" -Status "INFO" -Detail "$($recentEvents.Count) event(s) in the last 7 days — sync channel appears active"
        Write-Status "$($recentEvents.Count) MDM policy event(s) in the last 7 days" "INFO"
    } else {
        Add-Result -Check "MDM Policy Activity" -Status "WARN" -Detail "No MDM policy events in the last 7 days — confirm this device is syncing if a fleet QMR policy is expected"
        Write-Status "No recent MDM policy events found — confirm sync health if a fleet policy should be applying" "WARN"
    }
} catch {
    Add-Result -Check "MDM Policy Activity" -Status "INFO" -Detail "Event log not present or not accessible — device may not be MDM-enrolled, or this is expected on an unmanaged device"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Summary and export
# ---------------------------------------------------------------------------
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
$okCount    = ($results | Where-Object Status -eq "OK").Count

Write-Status "Audit complete: $okCount OK, $warnCount WARN, $errorCount ERROR" "INFO"

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Results exported to: $ExportPath (any WinRE Wi-Fi password has been redacted)" "OK"

if ($errorCount -gt 0) {
    Write-Status "One or more checks indicate a blocking condition — see QuickMachineRecovery-B.md Common Fix Paths." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "One or more checks indicate a condition worth reviewing — see QuickMachineRecovery-B.md Triage table." "WARN"
} else {
    Write-Status "No blocking conditions detected." "OK"
}
