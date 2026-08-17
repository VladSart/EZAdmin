<#
.SYNOPSIS
    Audits a device's readiness for Windows Autopilot pre-provisioning (White Glove) and,
    if run post-provisioning, flags common failure signatures from local logs/registry state.

.DESCRIPTION
    Read-only diagnostic script for Windows Autopilot for pre-provisioned deployment (White Glove).
    Run locally on the device in question — either pre-flight (before attempting the Technician
    flow) or post-failure (from a Shift+F10 command prompt during a stuck OOBE/ESP screen, or from
    a live desktop after the User flow completed with problems).

    Covers:
      - TPM 2.0 presence/readiness (hard requirement — VMs and non-TPM-2.0 hardware cannot use
        this scenario at all)
      - Reachability of documented Autopilot/enrollment/TPM-attestation network endpoints
      - Device identity state via dsregcmd (Entra join / hybrid join / PRT)
      - ESP tracking registry state — what, if anything, is still being waited on
      - Recent Autopilot and MDM enrollment event log entries
      - Intune Management Extension log tail, filtered to failure/detection-related lines
      - A best-effort elapsed-time check against the Technician-flow completion timestamp found
        in the event log, flagged against the documented 90-minute minimum / 6-month maximum
        windows before the User flow should run

    Does NOT cover:
      - Modifying any Autopilot profile, ESP configuration, or app assignment in Intune (that is
        a portal/Graph write operation, out of scope for a local read-only script)
      - Deleting or re-enrolling the Intune device record (the documented recovery path after a
        completed/failed pre-provisioning attempt) — this script only flags when that's likely needed
      - TPM firmware updates or TPM clearing (BIOS/UEFI or manufacturer-tool operations, not scriptable
        generically across OEMs)
      - Hybrid-join-specific server-side checks (Intune Connector service health, Entra Connect sync
        state) — those live on the connector/sync server, not this device; see
        `EntraID/Scripts/Get-HybridJoinDiagnostics.ps1` for that side of the chain

.PARAMETER OutputPath
    Directory to write the CSV summary and copied log excerpts to. Defaults to
    C:\WhiteGloveReadiness_<timestamp>.

.PARAMETER SkipEndpointCheck
    Skip the network endpoint reachability tests (useful if running from a locked-down jump box
    where those endpoints are expected to be unreachable for unrelated reasons).

.EXAMPLE
    .\Get-WhiteGloveReadiness.ps1
    Runs a full pre-flight/post-failure readiness check and writes results to
    C:\WhiteGloveReadiness_<timestamp>\.

.EXAMPLE
    .\Get-WhiteGloveReadiness.ps1 -SkipEndpointCheck -OutputPath D:\Diag
    Runs the check without network tests, writing results to D:\Diag.

.NOTES
    Requires: Local admin rights recommended (TPM cmdlets and some event log channels need it).
    Run-as: Local device — either at OOBE (Shift+F10) or a live Windows session.
    Safe/unsafe: Fully read-only. No configuration, registry, or Intune state is modified.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\WhiteGloveReadiness_$(Get-Date -Format 'yyyyMMdd_HHmm')",
    [switch]$SkipEndpointCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Status "Could not create output directory '$OutputPath': $($_.Exception.Message)" "ERROR"
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running elevated — TPM and some event log checks may return incomplete data." "WARN"
}

$findings = New-Object System.Collections.Generic.List[Object]
function Add-Finding {
    param([string]$Area, [string]$Status, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Area = $Area; Status = $Status; Detail = $Detail })
}

Write-Status "Windows Autopilot Pre-Provisioning (White Glove) readiness check starting..." "INFO"

# ---------------------------------------------------------------------------
# 1. TPM readiness — hard requirement, no bypass exists
# ---------------------------------------------------------------------------
Write-Status "Checking TPM 2.0 readiness..." "INFO"
try {
    $tpm = Get-Tpm
    if ($tpm.TpmPresent -and $tpm.TpmReady -and $tpm.TpmEnabled) {
        Add-Finding "TPM" "OK" "TPM present, ready, and enabled."
        Write-Status "TPM: present / ready / enabled." "OK"
    } else {
        Add-Finding "TPM" "ERROR" "TpmPresent=$($tpm.TpmPresent) TpmReady=$($tpm.TpmReady) TpmEnabled=$($tpm.TpmEnabled). Pre-provisioning cannot proceed at all without a ready TPM 2.0 — this is a hard, non-negotiable requirement (self-deploying-mode mechanics)."
        Write-Status "TPM is not fully ready. Pre-provisioning will fail at the very start of Technician flow." "ERROR"
    }
} catch {
    Add-Finding "TPM" "ERROR" "Get-Tpm failed: $($_.Exception.Message). If this is a virtual machine, note VMs are explicitly unsupported for this scenario."
    Write-Status "Could not query TPM state — is this a VM? VMs are unsupported for pre-provisioning." "ERROR"
}

# ---------------------------------------------------------------------------
# 2. Device identity state
# ---------------------------------------------------------------------------
Write-Status "Checking device identity / join state (dsregcmd)..." "INFO"
try {
    $dsreg = dsregcmd /status 2>$null
    $joined = ($dsreg | Select-String "AzureAdJoined\s*:\s*YES")
    $hybridJoined = ($dsreg | Select-String "DomainJoined\s*:\s*YES")
    $prt = ($dsreg | Select-String "AzureAdPrt\s*:\s*YES")

    if ($joined -and -not $hybridJoined) {
        Add-Finding "Identity" "OK" "Entra join detected (AzureAdJoined=YES, DomainJoined=NO)."
    } elseif ($joined -and $hybridJoined) {
        Add-Finding "Identity" "OK" "Entra hybrid join detected (AzureAdJoined=YES, DomainJoined=YES). Verify server-side Intune Connector + Entra Connect sync separately."
    } elseif ($hybridJoined -and -not $joined) {
        Add-Finding "Identity" "WARN" "DomainJoined=YES but AzureAdJoined not yet YES — hybrid join registration may still be in progress (Entra Connect sync lag is a common cause)."
    } else {
        Add-Finding "Identity" "INFO" "Neither AzureAdJoined nor DomainJoined shows YES yet — expected if run before/during the Technician flow's join step."
    }

    if ($prt) {
        Add-Finding "PRT" "OK" "Primary Refresh Token present."
    } else {
        Add-Finding "PRT" "INFO" "No PRT yet — expected before user sign-in completes (User flow)."
    }
    Write-Status "Identity state captured." "OK"
} catch {
    Add-Finding "Identity" "WARN" "dsregcmd /status failed or unavailable: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 3. Network endpoint reachability
# ---------------------------------------------------------------------------
if (-not $SkipEndpointCheck) {
    Write-Status "Testing required Autopilot/enrollment/TPM-attestation endpoints..." "INFO"
    $endpoints = @(
        @{ Name = "ztd.dds.microsoft.com"; Purpose = "Autopilot deployment service" },
        @{ Name = "cs.dds.microsoft.com"; Purpose = "Autopilot deployment service" },
        @{ Name = "login.microsoftonline.com"; Purpose = "Entra ID authentication" },
        @{ Name = "enterpriseregistration.windows.net"; Purpose = "Entra ID device registration" },
        @{ Name = "enrollment.manage.microsoft.com"; Purpose = "Intune MDM enrollment" },
        @{ Name = "ekcert.spserv.microsoft.com"; Purpose = "TPM attestation (Microsoft-hosted EK cert)" }
    )
    $endpointResults = foreach ($ep in $endpoints) {
        try {
            $test = Test-NetConnection -ComputerName $ep.Name -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
            $reachable = $test.TcpTestSucceeded
        } catch {
            $reachable = $false
        }
        if (-not $reachable) {
            Add-Finding "Network" "ERROR" "$($ep.Name) ($($ep.Purpose)) is NOT reachable on 443. If behind a proxy, check for TLS/SSL inspection breaking certificate pinning."
        }
        [PSCustomObject]@{ Endpoint = $ep.Name; Purpose = $ep.Purpose; Reachable = $reachable }
    }
    $endpointResults | Export-Csv (Join-Path $OutputPath "endpoint-reachability.csv") -NoTypeInformation
    $failCount = ($endpointResults | Where-Object { -not $_.Reachable }).Count
    if ($failCount -eq 0) {
        Write-Status "All required endpoints reachable." "OK"
    } else {
        Write-Status "$failCount endpoint(s) unreachable — see endpoint-reachability.csv." "ERROR"
    }
} else {
    Write-Status "Skipping network endpoint check (-SkipEndpointCheck)." "WARN"
}

# ---------------------------------------------------------------------------
# 4. ESP tracking registry state
# ---------------------------------------------------------------------------
Write-Status "Checking ESP tracking registry state..." "INFO"
$espTrackingPath = "HKLM:\SOFTWARE\Microsoft\Windows\Autopilot\EnrollmentStatusTracking"
$enrollmentsPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"

if (Test-Path $espTrackingPath) {
    Add-Finding "ESP" "OK" "ESP tracking registry key present — an ESP profile is actively tracking this device."
} else {
    Add-Finding "ESP" "WARN" "ESP tracking registry key not found. If pre-provisioning is expected to be running, confirm an ESP profile is actually targeted to this device — without one, the Technician flow has nothing holding provisioning state open, and Reseal can appear before content finishes applying."
}

if (Test-Path $enrollmentsPath) {
    Add-Finding "Enrollment" "OK" "MDM enrollment registry hive present."
} else {
    Add-Finding "Enrollment" "INFO" "No MDM enrollment registry hive found yet — expected if run before enrollment completes."
}

# ---------------------------------------------------------------------------
# 5. Recent Autopilot / MDM event log entries
# ---------------------------------------------------------------------------
Write-Status "Collecting recent Autopilot and MDM enrollment event log entries..." "INFO"
$logChannels = @(
    "Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot",
    "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"
)
$allEvents = @()
foreach ($channel in $logChannels) {
    try {
        $events = Get-WinEvent -LogName $channel -MaxEvents 100 -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, @{N='Channel';E={$channel}}, Message
        $allEvents += $events
    } catch {
        Add-Finding "EventLog" "WARN" "Could not read channel '$channel': $($_.Exception.Message)"
    }
}
if ($allEvents.Count -gt 0) {
    $allEvents | Sort-Object TimeCreated -Descending | Export-Csv (Join-Path $OutputPath "autopilot-mdm-events.csv") -NoTypeInformation
    $errorEvents = $allEvents | Where-Object { $_.LevelDisplayName -in @("Error","Warning") }
    if ($errorEvents.Count -gt 0) {
        Add-Finding "EventLog" "WARN" "$($errorEvents.Count) Error/Warning-level Autopilot/MDM event(s) found in the last 100 entries per channel — see autopilot-mdm-events.csv."
    } else {
        Add-Finding "EventLog" "OK" "No Error/Warning-level Autopilot/MDM events in recent history."
    }

    # Best-effort: look for a Technician-flow "provisioning complete" style timestamp to sanity-check
    # the 90-minute / 6-month User-flow timing windows. This is heuristic — event text/IDs for this
    # aren't a stable, documented public contract, so treat it as a hint, not authoritative.
    $successLike = $allEvents | Where-Object { $_.Message -match "(?i)provisioning\s+(complete|succeeded)|reseal" } | Sort-Object TimeCreated -Descending | Select-Object -First 1
    if ($successLike) {
        $elapsed = (Get-Date) - $successLike.TimeCreated
        if ($elapsed.TotalMinutes -lt 90) {
            Add-Finding "Timing" "WARN" "Apparent Technician-flow completion found at $($successLike.TimeCreated) — only $([math]::Round($elapsed.TotalMinutes,1)) minutes ago. Microsoft's documented guidance is to wait at least 90 minutes before running the User flow (token refresh timing)."
        } elseif ($elapsed.TotalDays -gt 180) {
            Add-Finding "Timing" "WARN" "Apparent Technician-flow completion found at $($successLike.TimeCreated) — $([math]::Round($elapsed.TotalDays,0)) days ago (over the ~6-month/180-day window). The Intune Management Extension certificate used during Technician flow may have expired; a fresh re-provision (delete + re-enroll the Intune device record) may be required instead of an in-place repair."
        } else {
            Add-Finding "Timing" "OK" "Apparent Technician-flow completion at $($successLike.TimeCreated) — within the documented 90-minute-to-6-month window for running the User flow."
        }
    } else {
        Add-Finding "Timing" "INFO" "Could not heuristically identify a Technician-flow completion timestamp from recent event log text — this is a best-effort check only, not a failure signal on its own."
    }
} else {
    Add-Finding "EventLog" "INFO" "No Autopilot/MDM event log entries found in the queried channels."
}

# ---------------------------------------------------------------------------
# 6. Intune Management Extension log — Win32 app install/detection failures
# ---------------------------------------------------------------------------
Write-Status "Checking Intune Management Extension log for app install/detection issues..." "INFO"
$imeLogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLogPath) {
    try {
        $imeTail = Get-Content $imeLogPath -Tail 500 -ErrorAction Stop
        $failLines = $imeTail | Select-String -Pattern "Failed|Error|NotComputed" -SimpleMatch:$false
        if ($failLines) {
            $failLines | Out-File (Join-Path $OutputPath "ime-log-failures.txt")
            Add-Finding "IME" "WARN" "$($failLines.Count) failure/error-related line(s) found in the last 500 lines of IntuneManagementExtension.log — see ime-log-failures.txt. Check for detection-rule mismatches or the >6-month IME-certificate-expiry signature (NotComputed detection state)."
        } else {
            Add-Finding "IME" "OK" "No failure/error patterns found in the recent IME log tail."
        }
        Copy-Item $imeLogPath (Join-Path $OutputPath "IntuneManagementExtension.log") -ErrorAction SilentlyContinue
    } catch {
        Add-Finding "IME" "WARN" "Could not read IME log: $($_.Exception.Message)"
    }
} else {
    Add-Finding "IME" "INFO" "IntuneManagementExtension.log not found — no Win32/LOB app activity has occurred on this device yet, or the IME hasn't installed."
}

# ---------------------------------------------------------------------------
# Summary + export
# ---------------------------------------------------------------------------
$findings | Export-Csv (Join-Path $OutputPath "whiteglove-readiness-summary.csv") -NoTypeInformation

Write-Host ""
Write-Status "=== Summary ===" "INFO"
$findings | ForEach-Object {
    Write-Status "$($_.Area): $($_.Detail)" $_.Status
}

$errorCount = ($findings | Where-Object Status -eq "ERROR").Count
$warnCount  = ($findings | Where-Object Status -eq "WARN").Count

Write-Host ""
if ($errorCount -gt 0) {
    Write-Status "$errorCount blocking issue(s) found. This device is NOT ready for / did NOT cleanly complete pre-provisioning." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "$warnCount warning(s) found. Review before proceeding or escalating." "WARN"
} else {
    Write-Status "No blocking issues found." "OK"
}

Write-Status "Full results written to: $OutputPath" "INFO"
