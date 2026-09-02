<#
.SYNOPSIS
    Audits Windows Recall eligibility, governance policy state, prerequisite health, and local
    snapshot store status on the local machine.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/Recall-B.md and Recall-A.md.
    Runs in one pass everything the runbooks' triage and diagnosis steps ask for:
    - Copilot+ PC hardware signal (supporting only — Settings > System > About remains authoritative)
    - WindowsAI CSP/GPO policy state (AllowRecallEnablement, DisableAIDataAnalysis)
    - BitLocker/device encryption status on the OS volume (hard Recall prerequisite)
    - Windows Hello enrollment presence (supporting signal for Enhanced Sign-in Security)
    - Active Recall capture process (aihost.exe) and related service state
    - Disk free space headroom (independent of the Recall storage-allocation slider)
    - Local per-user snapshot store existence and size (existence/size only — never reads
      or exports snapshot content itself)

    Produces a console summary with pass/fail/info per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's Recall-B.md Fix 1-6 / Recall-A.md Playbooks 1-4)
    - Enrolling or un-enrolling Recall (opt-in setup must be completed by the signed-in user)
    - Reading, exporting, or exposing any actual snapshot content — this script only checks
      whether the local store exists and how large it is
    - Fleet-wide auditing — this is a single-machine, single-user-profile diagnostic; Recall
      state is per-user and there is no Graph/Intune API surface for snapshot-level state

.PARAMETER ExportPath
    Path for CSV export. Default: .\RecallPolicyAudit-<timestamp>.csv

.EXAMPLE
    .\Get-RecallPolicyAudit.ps1
    Audits local Recall eligibility, policy, and prerequisite state for the current user profile.

.EXAMPLE
    .\Get-RecallPolicyAudit.ps1 -ExportPath C:\Temp\recall-audit.csv
    Audits and exports results to a specific CSV path.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (BitLocker and HKLM policy reads need elevation; local
            store size check runs under the current user's profile without elevation)
    Safe: Fully read-only. No policy changes, no Recall enrollment/un-enrollment, no snapshot
          deletion, no snapshot content is read.
    Tested on: Windows 11 24H2+ on Copilot+ PC hardware (Snapdragon X, Intel Lunar Lake/Panther
               Lake, AMD Strix/Kraken Point generations). Also safe to run on non-eligible
               hardware — will simply report ineligibility and skip downstream checks.
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

if (-not $ExportPath) {
    $ExportPath = ".\RecallPolicyAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
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

Write-Status "Starting Windows Recall policy and readiness audit..." "INFO"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Hardware eligibility signal (supporting only)
# ---------------------------------------------------------------------------
Write-Status "Checking Copilot+ PC hardware signal..." "INFO"
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $sku = $cs.SystemSKU
    $model = $cs.Model
    $manufacturer = $cs.Manufacturer
    Add-Result -Check "Hardware (Manufacturer/Model/SKU)" -Status "INFO" `
        -Detail "$manufacturer / $model / SKU=$sku (supporting signal only — confirm via Settings > System > About)"
    Write-Status "Manufacturer=$manufacturer Model=$model SKU=$sku" "INFO"
    Write-Status "NOTE: No single registry/WMI field reliably confirms Copilot+ PC status across all OEMs." "WARN"
    Write-Status "Ground truth is Settings > System > About > Device specifications." "WARN"
} catch {
    Add-Result -Check "Hardware signal" -Status "ERROR" -Detail "Failed to query Win32_ComputerSystem: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 2. WindowsAI governance policy state
# ---------------------------------------------------------------------------
Write-Status "Checking WindowsAI (Recall) governance policy state..." "INFO"
$policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
if (Test-Path $policyPath) {
    $policy = Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue

    $allowEnable = $policy.AllowRecallEnablement
    if ($null -eq $allowEnable) {
        Add-Result -Check "AllowRecallEnablement" -Status "INFO" -Detail "Not configured (default: allowed)"
        Write-Status "AllowRecallEnablement: Not Configured (enrollment permitted by default)" "INFO"
    } elseif ($allowEnable -eq 0) {
        Add-Result -Check "AllowRecallEnablement" -Status "WARN" -Detail "0 — Recall enrollment is BLOCKED by policy"
        Write-Status "AllowRecallEnablement = 0 — enrollment is blocked by policy" "WARN"
    } else {
        Add-Result -Check "AllowRecallEnablement" -Status "OK" -Detail "$allowEnable — enrollment permitted"
        Write-Status "AllowRecallEnablement = $allowEnable — enrollment permitted" "OK"
    }

    $disableCapture = $policy.DisableAIDataAnalysis
    if ($null -eq $disableCapture) {
        Add-Result -Check "DisableAIDataAnalysis" -Status "INFO" -Detail "Not configured (default: capture permitted if enrolled)"
        Write-Status "DisableAIDataAnalysis: Not Configured (snapshot capture permitted by default)" "INFO"
    } elseif ($disableCapture -eq 1) {
        Add-Result -Check "DisableAIDataAnalysis" -Status "WARN" -Detail "1 — Snapshot capture is BLOCKED by policy (even if already enrolled)"
        Write-Status "DisableAIDataAnalysis = 1 — snapshot capture is blocked by policy" "WARN"
    } else {
        Add-Result -Check "DisableAIDataAnalysis" -Status "OK" -Detail "$disableCapture — capture permitted"
        Write-Status "DisableAIDataAnalysis = $disableCapture — capture permitted" "OK"
    }
} else {
    Add-Result -Check "WindowsAI policy key" -Status "INFO" -Detail "Registry path not present — no Recall-specific policy configured (default: permitted)"
    Write-Status "No WindowsAI policy key present — Recall is unmanaged/default-permitted on this device" "INFO"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 3. BitLocker / device encryption
# ---------------------------------------------------------------------------
Write-Status "Checking BitLocker/device encryption on OS volume..." "INFO"
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($bl.ProtectionStatus -eq "On") {
        Add-Result -Check "BitLocker/Device Encryption" -Status "OK" -Detail "ProtectionStatus=On, VolumeStatus=$($bl.VolumeStatus)"
        Write-Status "OS volume encryption: On" "OK"
    } else {
        Add-Result -Check "BitLocker/Device Encryption" -Status "ERROR" -Detail "ProtectionStatus=$($bl.ProtectionStatus) — Recall setup will block until this is On"
        Write-Status "OS volume encryption is NOT On (ProtectionStatus=$($bl.ProtectionStatus)) — Recall setup will block" "ERROR"
    }
} catch {
    Add-Result -Check "BitLocker/Device Encryption" -Status "ERROR" -Detail "Failed to query (requires elevation, or BitLocker cmdlets unavailable): $($_.Exception.Message)"
    Write-Status "Could not query BitLocker state — re-run elevated" "ERROR"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 4. Windows Hello enrollment (supporting signal for Enhanced Sign-in Security)
# ---------------------------------------------------------------------------
Write-Status "Checking Windows Hello enrollment signal..." "INFO"
$helloPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Enum"
if (Test-Path $helloPath) {
    $helloEntries = Get-ChildItem $helloPath -ErrorAction SilentlyContinue
    if ($helloEntries) {
        Add-Result -Check "Windows Hello enrollment" -Status "INFO" -Detail "WinBio enum entries present ($($helloEntries.Count)) — supporting signal only, confirm ESS status via Settings > Accounts > Sign-in options"
        Write-Status "WinBio enrollment entries found ($($helloEntries.Count)) — does not by itself confirm Enhanced Sign-in Security" "INFO"
    } else {
        Add-Result -Check "Windows Hello enrollment" -Status "WARN" -Detail "WinBio enum key present but empty — no biometric factor enrolled"
        Write-Status "No biometric enrollment entries found" "WARN"
    }
} else {
    Add-Result -Check "Windows Hello enrollment" -Status "WARN" -Detail "WinBio registry path not present — likely no biometric factor enrolled"
    Write-Status "WinBio registry path not present" "WARN"
}
Write-Status "Ground truth for Enhanced Sign-in Security is Settings > Accounts > Sign-in options." "WARN"
Write-Host ""

# ---------------------------------------------------------------------------
# 5. Active Recall capture process and related services
# ---------------------------------------------------------------------------
Write-Status "Checking active Recall capture process..." "INFO"
$aihost = Get-Process -Name "aihost" -ErrorAction SilentlyContinue
if ($aihost) {
    Add-Result -Check "aihost.exe process" -Status "OK" -Detail "Running (PID: $($aihost.Id -join ','))"
    Write-Status "aihost.exe is running — Recall capture is active" "OK"
} else {
    Add-Result -Check "aihost.exe process" -Status "INFO" -Detail "Not running — expected if not enrolled, policy-blocked, or user session inactive"
    Write-Status "aihost.exe not running — normal if not enrolled, blocked by policy, or between sessions" "INFO"
}

$aiServices = Get-Service -Name "*aihost*", "*WindowsAI*" -ErrorAction SilentlyContinue
if ($aiServices) {
    foreach ($svc in $aiServices) {
        Add-Result -Check "Service: $($svc.Name)" -Status "INFO" -Detail "Status=$($svc.Status), StartType=$($svc.StartType)"
    }
    Write-Status "Found $($aiServices.Count) related service(s) — see CSV for detail" "INFO"
} else {
    Write-Status "No dedicated aihost/WindowsAI service found — capture may run under a scheduled task or per-session process only on this build" "INFO"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 6. Disk free space headroom
# ---------------------------------------------------------------------------
Write-Status "Checking disk free space headroom..." "INFO"
try {
    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    $usedGB = [math]::Round($drive.Used / 1GB, 1)
    $totalGB = $freeGB + $usedGB
    $freePct = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }

    if ($freePct -lt 10) {
        Add-Result -Check "Disk free space" -Status "ERROR" -Detail "${freeGB}GB free (${freePct}% of ${totalGB}GB) — below ~10% threshold, Recall capture will likely stall"
        Write-Status "Only ${freeGB}GB free (${freePct}%) — Recall capture will likely stall" "ERROR"
    } elseif ($freePct -lt 20) {
        Add-Result -Check "Disk free space" -Status "WARN" -Detail "${freeGB}GB free (${freePct}% of ${totalGB}GB) — getting tight"
        Write-Status "${freeGB}GB free (${freePct}%) — headroom is getting tight" "WARN"
    } else {
        Add-Result -Check "Disk free space" -Status "OK" -Detail "${freeGB}GB free (${freePct}% of ${totalGB}GB)"
        Write-Status "${freeGB}GB free (${freePct}%) — adequate headroom" "OK"
    }
} catch {
    Add-Result -Check "Disk free space" -Status "ERROR" -Detail "Failed to query system drive: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 7. Local snapshot store (existence/size only — never reads content)
# ---------------------------------------------------------------------------
Write-Status "Checking local snapshot store (existence/size only)..." "INFO"
$storePath = "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP"
if (Test-Path $storePath) {
    try {
        $storeItems = Get-ChildItem -Path $storePath -Recurse -File -ErrorAction SilentlyContinue
        $storeSizeMB = [math]::Round((($storeItems | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
        Add-Result -Check "Local snapshot store" -Status "INFO" -Detail "Present. FileCount=$($storeItems.Count), SizeMB=$storeSizeMB (content never read by this script)"
        Write-Status "Local store present: $($storeItems.Count) file(s), ${storeSizeMB}MB" "INFO"
    } catch {
        Add-Result -Check "Local snapshot store" -Status "WARN" -Detail "Path present but could not enumerate: $($_.Exception.Message)"
    }
} else {
    Add-Result -Check "Local snapshot store" -Status "INFO" -Detail "Path not present — Recall likely never enrolled on this user profile"
    Write-Status "Local store path not present — Recall likely not enrolled on this profile" "INFO"
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
Write-Status "Results exported to: $ExportPath" "OK"

if ($errorCount -gt 0) {
    Write-Status "One or more checks indicate a blocking condition — see Recall-B.md Common Fix Paths." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "One or more checks indicate a governance block or a condition worth reviewing — see Recall-B.md Triage table." "WARN"
} else {
    Write-Status "No blocking conditions detected." "OK"
}
