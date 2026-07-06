<#
.SYNOPSIS
    Checks Intune Management Extension (IME) health locally and/or pulls fleet-wide
    Platform Script run status via Graph.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/Platform-Scripts-B.md and -A.md.

    Both runbooks converge on the same root truth: IME (IntuneManagementExtension.exe)
    is the engine behind Platform Scripts, Win32 apps, Remediations, and Custom
    Compliance — if IME is unhealthy, script execution breaks regardless of what the
    script itself contains (Platform-Scripts-A.md Learning Pointers, -B.md Dependency
    Cascade). This script checks both ends of that chain:

    Local mode (run ON the affected Windows device):
      - IME service status (Running/Stopped/Not installed) — -A.md Validation Step 1
      - IME version — cross-reference against known-good installs
      - MDM enrollment type (EnrollmentType=6 required) — -A.md Validation Step 2
      - Tail of IntuneManagementExtension.log filtered for Script/PowerShell/ExitCode
        lines — -A.md Validation Step 3
      - Effective PowerShell execution policy (Machine/User/Process scope) — -A.md
        Validation Step 4
      - Recent WDAC CodeIntegrity block events (3076/3077) — -A.md Phase 4

    Fleet mode (-ScriptId supplied, run from an admin workstation with Graph):
      - Pulls per-device RunState for the named Platform Script
      - Buckets into success / failed / pending / notApplicable / unknown
      - Flags PENDING_STALE: devices stuck in `pending` whose LastSyncDateTime is
        older than -StaleHours — per -B.md's "Script stuck in pending" Fix 2, this
        means the device likely hasn't checked in, not that the script itself failed

    Both modes are independent and can be run together. This script makes no changes —
    it does not clear the IME policy cache or restart services (see Platform-Scripts-B.md
    Fix 2 for that remediation step, applied manually after reviewing this report).

.PARAMETER ScriptId
    The Intune Platform Script (DeviceManagementScript) object ID to pull fleet-wide
    run status for via Graph. Found in the Intune portal URL when viewing the script.

.PARAMETER StaleHours
    Hours since a device's LastSyncDateTime before a `pending` run state is flagged
    PENDING_STALE rather than "still waiting on its normal check-in cycle". Default: 9.

.PARAMETER SkipLocalChecks
    Skip the local IME health checks — useful when running fleet mode only from an
    admin workstation that isn't itself the affected endpoint.

.PARAMETER OutputPath
    Folder to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-PlatformScriptRunStatus.ps1
    Runs local IME health checks only, on the current device.

.EXAMPLE
    .\Get-PlatformScriptRunStatus.ps1 -ScriptId "<script-guid>" -SkipLocalChecks
    Pulls fleet-wide run status for a script from an admin workstation.

.EXAMPLE
    .\Get-PlatformScriptRunStatus.ps1 -ScriptId "<script-guid>"
    Runs both local IME health checks and the fleet-wide report in one pass
    (use when troubleshooting directly on a device that also has Graph access).

.NOTES
    Requires (local):  Windows PowerShell 5.1+, Administrator for full log/registry access
    Requires (fleet):  Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Scopes (fleet):    DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All
    Safe/Unsafe:       Fully read-only in both modes. Makes no service, cache, or policy changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptId,

    [Parameter(Mandatory = $false)]
    [int]$StaleHours = 9,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLocalChecks,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------
# LOCAL MODE — IME health on this device
# ---------------------------------------------------------------------------
if (-not $SkipLocalChecks) {
    Write-Status "=== Local IME Health Check ===" "INFO"

    $svc = Get-Service -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Status "IME service: $($svc.Status) (StartType: $($svc.StartType))" $(if ($svc.Status -eq "Running") { "OK" } else { "ERROR" })
    }
    else {
        Write-Status "IME service NOT FOUND — not installed. It auto-installs when a Win32 app, script, or Remediation targets this device (Platform-Scripts-B.md Fix 1)." "ERROR"
    }

    $imeInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Intune Management Extension*" }
    if ($imeInfo) {
        Write-Status "IME version: $($imeInfo.DisplayVersion) (installed $($imeInfo.InstallDate))" "OK"
    }

    $enrollInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Enrollments\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.EnrollmentType -eq 6 }
    if ($enrollInfo) {
        Write-Status "MDM enrollment confirmed (EnrollmentType=6)." "OK"
    }
    else {
        Write-Status "No EnrollmentType=6 entry found — device may not be MDM-enrolled, only Workplace Joined. Scripts require full MDM enrollment (Platform-Scripts-A.md Validation Step 2)." "ERROR"
    }

    $imeLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    if (Test-Path $imeLog) {
        $lines = Get-Content $imeLog | Select-String -Pattern "Script|PowerShell|ExitCode" | Select-Object -Last 30
        $lines | Out-File (Join-Path $OutputPath "IMELogTail-$timestamp.txt")
        Write-Status "IME log tail (last 30 Script/PowerShell/ExitCode lines) exported. Scan for 'Exit code: 0' (success) vs non-zero (failure)." "INFO"
    }
    else {
        Write-Status "IME log not found at expected path — IME may never have run on this device." "WARN"
    }

    $policy = Get-ExecutionPolicy -List
    $machinePolicy = ($policy | Where-Object Scope -eq "MachinePolicy").ExecutionPolicy
    if ($machinePolicy -eq "Restricted" -or $machinePolicy -eq "AllSigned") {
        Write-Status "MachinePolicy execution policy is '$machinePolicy' — this is NOT bypassed by Intune's -ExecutionPolicy Bypass flag and can block unsigned scripts (Platform-Scripts-A.md Phase 4)." "WARN"
    }
    else {
        Write-Status "MachinePolicy execution policy: '$machinePolicy' (or unset) — should not block Intune scripts." "OK"
    }

    try {
        $wdacBlocks = Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 50 -ErrorAction Stop |
            Where-Object { $_.Id -in @(3076, 3077) }
        if ($wdacBlocks) {
            Write-Status "$($wdacBlocks.Count) recent WDAC block event(s) (3076/3077) found — a WDAC policy may be blocking script/PowerShell execution (Platform-Scripts-A.md Phase 4). See WDAC-A.md." "WARN"
            $wdacBlocks | Select-Object TimeCreated, Id, Message | Export-Csv (Join-Path $OutputPath "WDACBlocks-$timestamp.csv") -NoTypeInformation
        }
        else {
            Write-Status "No recent WDAC block events found." "OK"
        }
    }
    catch {
        Write-Status "Could not query CodeIntegrity event log (may not be enabled on this SKU)." "INFO"
    }

    Write-Host ""
}

# ---------------------------------------------------------------------------
# FLEET MODE — Graph-side script run status
# ---------------------------------------------------------------------------
if ($ScriptId) {
    Write-Status "=== Fleet Platform Script Run Status (Script: $ScriptId) ===" "INFO"

    try {
        $context = Get-MgContext
        if (-not $context) {
            Write-Status "Not connected. Connecting with required scopes..." "WARN"
            Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
        }
        else {
            Write-Status "Connected as $($context.Account)" "OK"
        }
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        throw
    }

    try {
        $runStates = Get-MgDeviceManagementDeviceManagementScriptDeviceRunState -DeviceManagementScriptId $ScriptId -All
    }
    catch {
        Write-Status "Failed to retrieve run states for script '$ScriptId': $($_.Exception.Message)" "ERROR"
        throw
    }

    # Cross-reference last sync time per device to distinguish "genuinely pending" from "stale/offline"
    $deviceSyncMap = @{}
    try {
        Get-MgDeviceManagementManagedDevice -All -Property "id,deviceName,lastSyncDateTime" | ForEach-Object {
            $deviceSyncMap[$_.Id] = $_
        }
    }
    catch {
        Write-Status "Could not retrieve device sync times for staleness cross-check: $($_.Exception.Message)" "WARN"
    }

    $staleThreshold = (Get-Date).AddHours(-$StaleHours)
    $report = $runStates | ForEach-Object {
        $deviceId = $_.ManagedDevice.Id
        $deviceInfo = $deviceSyncMap[$deviceId]
        $flags = New-Object System.Collections.Generic.List[string]

        if ($_.RunState -eq "fail" -or $_.RunState -eq "failed") { $flags.Add("SCRIPT_FAILED") }
        if ($_.RunState -eq "pending" -and $deviceInfo -and $deviceInfo.LastSyncDateTime -lt $staleThreshold) {
            $flags.Add("PENDING_STALE")
        }
        if ($_.RunState -eq "unknown") { $flags.Add("DEVICE_NOT_CHECKED_IN") }

        [PSCustomObject]@{
            DeviceName       = $_.ManagedDevice.DeviceName
            RunState         = $_.RunState
            ErrorCode        = $_.ErrorCode
            ResultMessage    = ($_.ResultMessage -replace "`n", " ")
            LastSyncDateTime = if ($deviceInfo) { $deviceInfo.LastSyncDateTime } else { $null }
            LastStateUpdate  = $_.LastStateUpdateDateTime
            Flags            = ($flags -join "; ")
        }
    }

    $reportFile = Join-Path $OutputPath "PlatformScriptRunStatus-$timestamp.csv"
    $report | Sort-Object RunState, DeviceName | Export-Csv -Path $reportFile -NoTypeInformation

    Write-Host ""
    Write-Status "Success:                  $(@($report | Where-Object RunState -eq 'success').Count)" "OK"
    Write-Status "Failed:                   $(@($report | Where-Object { $_.Flags -match 'SCRIPT_FAILED' }).Count)" "ERROR"
    Write-Status "Pending (normal):         $(@($report | Where-Object { $_.RunState -eq 'pending' -and $_.Flags -notmatch 'PENDING_STALE' }).Count)" "INFO"
    Write-Status "PENDING_STALE (>${StaleHours}h since sync): $(@($report | Where-Object { $_.Flags -match 'PENDING_STALE' }).Count)" "WARN"
    Write-Status "notApplicable:            $(@($report | Where-Object RunState -eq 'notApplicable').Count)" "INFO"
    Write-Host ""
    Write-Status "Full fleet report exported to: $reportFile" "OK"

    if (@($report | Where-Object { $_.Flags -match 'PENDING_STALE' }).Count -gt 0) {
        Write-Status "PENDING_STALE devices likely have a connectivity or enrollment problem, not a script problem — the script hasn't even been evaluated yet on those devices (Platform-Scripts-B.md Fix 2)." "WARN"
    }
    if (@($report | Where-Object { $_.Flags -match 'SCRIPT_FAILED' }).Count -gt 0) {
        Write-Status "For failed devices, re-run this script with -SkipLocalChecks:`$false directly on a representative failing device to pull IME log/WDAC context." "WARN"
    }
}

if (-not $ScriptId -and $SkipLocalChecks) {
    Write-Status "Nothing to do — provide -ScriptId for fleet mode, or omit -SkipLocalChecks to run local checks." "ERROR"
}
