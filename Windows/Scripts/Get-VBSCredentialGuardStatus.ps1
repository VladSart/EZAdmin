<#
.SYNOPSIS
    Reports Virtualization-Based Security (VBS) and Credential Guard status on a Windows endpoint.

.DESCRIPTION
    Local diagnostic companion to Windows/Troubleshooting/VBS-CredentialGuard-A.md and -B.md.
    Walks the full dependency chain those runbooks document — hardware prerequisites (SLAT, Secure
    Boot, TPM), the Win32_DeviceGuard WMI status (the "gold standard" per VBS-CredentialGuard-A.md
    Validation Step 2), the lsaiso.exe process check (the fastest signal that Credential Guard is
    actually running, not just configured), the MDM/Intune policy channel under PolicyManager, the
    legacy registry-based DeviceGuard scenario key, and a scan of the CodeIntegrity/Operational event
    log for HVCI driver-block events (3001/3002/3003/3010/3023) — the #1 real-world pain point the
    runbook's Learning Pointers call out.

    This script is read-only / reporting only. It does NOT enable or disable VBS, Credential Guard,
    or HVCI. Use the runbook's Remediation Playbooks (registry-based enable, Intune Endpoint Security
    profile, or the Safe Mode HVCI-only disable) for actual remediation.

.PARAMETER EventLogHours
    How many hours back to scan the CodeIntegrity/Operational event log for HVCI block events.
    Default: 72.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-VBSCredentialGuardStatus.ps1
    Runs a full local VBS/Credential Guard status check with default settings.

.EXAMPLE
    .\Get-VBSCredentialGuardStatus.ps1 -EventLogHours 168 -OutputPath C:\Temp\Evidence
    Scans the last 7 days of CodeIntegrity events and writes the CSV to a custom folder.

.NOTES
    Requires: Run as Administrator (WMI DeviceGuard namespace and some registry keys require elevation).
    Safe: Read-only. No configuration changes are made.
    Companion runbooks: Windows/Troubleshooting/VBS-CredentialGuard-A.md (deep dive),
                         Windows/Troubleshooting/VBS-CredentialGuard-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [int]$EventLogHours = 72,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Status "Not running as Administrator — some checks (WMI DeviceGuard namespace, HKLM registry, event log) may fail or return incomplete data." "WARN"
}

$results = [ordered]@{}
$findings = New-Object System.Collections.Generic.List[string]

Write-Status "Starting VBS / Credential Guard diagnostic..." "INFO"

# ---- Preflight / Detect: Hardware prerequisites ----
Write-Status "Checking hardware prerequisites (SLAT, Secure Boot, TPM)..." "INFO"

try {
    $slat = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop).SecondLevelAddressTranslationExtensions
    $results["SLAT_Supported"] = $slat
    if ($slat -eq $true) {
        Write-Status "SLAT (hardware virtualization) supported." "OK"
    } else {
        Write-Status "SLAT not reported as supported. VBS requires SLAT — check BIOS/UEFI virtualization settings (VT-x/AMD-V)." "WARN"
        $findings.Add("SLAT_NOT_SUPPORTED")
    }
} catch {
    $results["SLAT_Supported"] = "ERROR: $($_.Exception.Message)"
    Write-Status "Could not query SLAT support: $($_.Exception.Message)" "ERROR"
}

try {
    $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
    $results["SecureBoot_Enabled"] = $secureBoot
    if ($secureBoot) {
        Write-Status "Secure Boot is enabled." "OK"
    } else {
        Write-Status "Secure Boot is NOT enabled. VBS strongly prefers Secure Boot for full protection." "WARN"
        $findings.Add("SECUREBOOT_DISABLED")
    }
} catch {
    $results["SecureBoot_Enabled"] = "ERROR (likely non-UEFI or access denied): $($_.Exception.Message)"
    Write-Status "Could not confirm Secure Boot state — device may be legacy BIOS or this check needs elevation." "WARN"
    $findings.Add("SECUREBOOT_CHECK_FAILED")
}

try {
    $tpm = Get-Tpm -ErrorAction Stop
    $results["TPM_Present"]  = $tpm.TpmPresent
    $results["TPM_Ready"]    = $tpm.TpmReady
    $results["TPM_Enabled"]  = $tpm.TpmEnabled
    if ($tpm.TpmPresent -and $tpm.TpmReady -and $tpm.TpmEnabled) {
        Write-Status "TPM present, ready, and enabled." "OK"
    } else {
        Write-Status "TPM is missing, not ready, or not enabled (Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady) Enabled=$($tpm.TpmEnabled))." "WARN"
        $findings.Add("TPM_NOT_READY")
    }
} catch {
    $results["TPM_Present"] = "ERROR: $($_.Exception.Message)"
    Write-Status "Could not query TPM state: $($_.Exception.Message)" "ERROR"
}

# ---- Execute: Win32_DeviceGuard WMI status (the "gold standard" check) ----
Write-Status "Checking Win32_DeviceGuard WMI status (VBS-CredentialGuard-A.md Validation Step 2)..." "INFO"

try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop

    $vbsStatusMap = @{ 0 = "Off"; 1 = "Configured (not running)"; 2 = "Running" }
    $vbsStatus = $vbsStatusMap[[int]$dg.VirtualizationBasedSecurityStatus]
    $results["VBS_Status"] = $vbsStatus
    $results["SecurityServicesConfigured"] = ($dg.SecurityServicesConfigured -join ",")
    $results["SecurityServicesRunning"]    = ($dg.SecurityServicesRunning -join ",")

    switch ([int]$dg.VirtualizationBasedSecurityStatus) {
        2 { Write-Status "VBS Status: Running." "OK" }
        1 { Write-Status "VBS Status: Configured but NOT running. Check hardware prerequisites above and confirm policy actually applied (MDM/registry checks below)." "WARN"; $findings.Add("VBS_CONFIGURED_NOT_RUNNING") }
        0 { Write-Status "VBS Status: Off." "WARN"; $findings.Add("VBS_OFF") }
        default { Write-Status "VBS Status: Unknown ($($dg.VirtualizationBasedSecurityStatus))" "WARN" }
    }

    # SecurityServicesConfigured/Running: 1 = Credential Guard, 2 = HVCI
    $cgConfigured = $dg.SecurityServicesConfigured -contains 1
    $cgRunning    = $dg.SecurityServicesRunning -contains 1
    $hvciConfigured = $dg.SecurityServicesConfigured -contains 2
    $hvciRunning    = $dg.SecurityServicesRunning -contains 2

    $results["CredentialGuard_Configured"] = $cgConfigured
    $results["CredentialGuard_Running"]    = $cgRunning
    $results["HVCI_Configured"] = $hvciConfigured
    $results["HVCI_Running"]    = $hvciRunning

    if ($cgConfigured -and -not $cgRunning) {
        Write-Status "Credential Guard is configured but not running — check lsaiso.exe below and hardware prerequisites." "WARN"
        $findings.Add("CG_CONFIGURED_NOT_RUNNING")
    }
} catch {
    $results["VBS_Status"] = "ERROR: $($_.Exception.Message)"
    Write-Status "Could not query Win32_DeviceGuard (requires elevation, and only present on Win10 1607+/Server 2016+): $($_.Exception.Message)" "ERROR"
    $findings.Add("DEVICEGUARD_WMI_QUERY_FAILED")
}

# ---- Execute: lsaiso.exe process check (fastest real-world signal) ----
Write-Status "Checking for lsaiso.exe (Credential Guard isolated LSA process)..." "INFO"

$lsaiso = Get-Process -Name lsaiso -ErrorAction SilentlyContinue
$results["lsaiso_Running"] = [bool]$lsaiso
if ($lsaiso) {
    Write-Status "lsaiso.exe is running — Credential Guard is active." "OK"
} else {
    Write-Status "lsaiso.exe is NOT running — Credential Guard is not active on this device." "WARN"
    $findings.Add("LSAISO_NOT_RUNNING")
}

# ---- Execute: Registry-based DeviceGuard scenario key (legacy / non-Intune deployments) ----
Write-Status "Checking legacy DeviceGuard registry scenario key..." "INFO"

try {
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    if (Test-Path $regPath) {
        $hvciReg = (Get-ItemProperty -Path $regPath -ErrorAction Stop).Enabled
        $results["Registry_HVCI_Enabled"] = $hvciReg
        Write-Status "Registry HVCI scenario 'Enabled' value: $hvciReg (1 = enabled)" "INFO"
    } else {
        $results["Registry_HVCI_Enabled"] = "KeyNotPresent"
        Write-Status "HVCI scenario registry key not present — likely managed via MDM/Intune rather than direct registry." "INFO"
    }
} catch {
    $results["Registry_HVCI_Enabled"] = "ERROR: $($_.Exception.Message)"
}

# ---- Execute: MDM/Intune policy channel check ----
Write-Status "Checking MDM (Intune) DeviceGuard policy channel..." "INFO"

try {
    $policyPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceGuard'
    if (Test-Path $policyPath) {
        $mdmPolicy = Get-ChildItem $policyPath -ErrorAction Stop | Get-ItemProperty |
            Select-Object PSChildName, EnableVirtualizationBasedSecurity, RequirePlatformSecurityFeatures,
                          LsaCfgFlags, HypervisorEnforcedCodeIntegrity
        $results["MDM_Policy_Present"] = $true
        Write-Status "MDM DeviceGuard policy channel found — policy is being delivered via Intune/MDM." "OK"
    } else {
        $results["MDM_Policy_Present"] = $false
        Write-Status "No MDM DeviceGuard policy channel found. If this device should be managed via Intune's Endpoint Security > Account Protection profile, confirm policy assignment and sync." "WARN"
        $findings.Add("NO_MDM_POLICY_CHANNEL")
    }
} catch {
    $results["MDM_Policy_Present"] = "ERROR: $($_.Exception.Message)"
}

# ---- Validate: CodeIntegrity/Operational event log scan for HVCI driver blocks ----
Write-Status "Scanning CodeIntegrity/Operational event log for HVCI driver-block events (last $EventLogHours hours)..." "INFO"

$ciEvents = @()
try {
    $startTime = (Get-Date).AddHours(-$EventLogHours)
    $ciEvents = Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -ErrorAction Stop |
        Where-Object { $_.Id -in @(3001, 3002, 3003, 3010, 3023) -and $_.TimeCreated -ge $startTime } |
        Select-Object TimeCreated, Id, LevelDisplayName, Message

    $results["CodeIntegrity_BlockEvents_Count"] = $ciEvents.Count
    if ($ciEvents.Count -gt 0) {
        Write-Status "$($ciEvents.Count) HVCI-relevant CodeIntegrity event(s) found in the last $EventLogHours hours — a driver may be incompatible with HVCI." "WARN"
        $findings.Add("HVCI_DRIVER_BLOCK_EVENTS_FOUND")
    } else {
        Write-Status "No HVCI driver-block events found in the scanned window." "OK"
    }
} catch {
    $results["CodeIntegrity_BlockEvents_Count"] = "ERROR: $($_.Exception.Message)"
    Write-Status "Could not read CodeIntegrity/Operational log: $($_.Exception.Message)" "WARN"
}

# ---- Report ----
Write-Status "Writing report..." "INFO"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryCsvPath = Join-Path $OutputPath "VBS-CredentialGuard-Status-$timestamp.csv"
$eventsCsvPath  = Join-Path $OutputPath "VBS-CredentialGuard-CIEvents-$timestamp.csv"

$summaryObject = [PSCustomObject]$results
$summaryObject | Export-Csv -Path $summaryCsvPath -NoTypeInformation -Force
Write-Status "Summary CSV written: $summaryCsvPath" "OK"

if ($ciEvents.Count -gt 0) {
    $ciEvents | Export-Csv -Path $eventsCsvPath -NoTypeInformation -Force
    Write-Status "CodeIntegrity events CSV written: $eventsCsvPath" "OK"
}

Write-Host ""
Write-Status "=== SUMMARY ===" "INFO"
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged. VBS/Credential Guard appear healthy." "OK"
} else {
    Write-Status "Flags raised: $($findings -join ', ')" "WARN"
}
Write-Host ""

$summaryObject | Format-List
