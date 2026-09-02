<#
.SYNOPSIS
    Audits one or more Windows devices for Windows Update Maintenance Window (Preview)
    eligibility, policy delivery, and runtime evidence of activation.

.DESCRIPTION
    The Maintenance Window Update Policy CSP family is currently Windows Insider
    Preview-flagged with no native Intune Settings Catalog UI (as of this writing),
    and its effective behavior depends on a server-side feature-flighting gate
    (Feature_Containment_UUS_Feature_MaintenanceWindow_*) entirely outside admin
    control. This script cannot confirm that gate's state directly — no supported
    local diagnostic exists for it — so it is scoped honestly around what IS
    reliably readable on a device:

    - OS build/UBR, compared against the current confirmed-functionally-working
      floor (informational heuristic, not a hard pass/fail, since this is a moving
      target for an actively-shipping Preview feature)
    - Raw MDM-delivered policy values (PolicyManager providers path)
    - Effective/current policy values (PolicyManager current path)
    - Windows Update Client Operational log entries referencing "Maintenance Window",
      as indirect runtime evidence that the feature-flighting gate is active and the
      policy is actually being evaluated by MoUsoCoreWorker.exe

    It does NOT and cannot: enable/configure the Maintenance Window policy itself (no
    write actions — this is read-only), confirm the server-side feature-flighting gate
    state directly, or determine precedence between Maintenance Window and Update ring
    deadlines (an open, under-documented interaction as of this writing — see
    MaintenanceWindow-A.md Troubleshooting Phase 3).

    Designed to run locally or via remote invocation (Invoke-Command) against a fleet
    for pilot-cohort evidence gathering.

.PARAMETER ComputerName
    One or more computer names to audit remotely via Invoke-Command. If omitted, runs
    against the local computer only.

.PARAMETER BuildFloor
    The OS build number considered the current confirmed-working floor, as an
    informational (not authoritative) comparison point. Defaults to 26200 (Windows 11
    25H2 + February 2026 CU, per independent lab testing as of this writing) — override
    if more current information is available, since this floor moves as the feature ships.

.PARAMETER EventLookbackDays
    How many days back to scan the Windows Update Client Operational log for
    Maintenance Window runtime evidence. Default: 14 (long enough to catch at least
    two cycles of a weekly recurrence).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\MaintenanceWindow-ReadinessAudit-<date>.csv.

.EXAMPLE
    .\Get-MaintenanceWindowReadinessAudit.ps1
    Audits the local computer only.

.EXAMPLE
    .\Get-MaintenanceWindowReadinessAudit.ps1 -ComputerName "KIOSK01","KIOSK02" -EventLookbackDays 30

.NOTES
    Read-only. Does not modify any policy, registry value, or feature flag.
    Requires appropriate remote-management permissions (WinRM/PSRemoting) if run
    against remote computers via -ComputerName.
    This is a Preview-feature diagnostic tool; re-verify its build-floor default and
    the underlying feature's status against current sources before relying on it for
    a production rollout decision.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [int]$BuildFloor = 26200,
    [int]$EventLookbackDays = 14,
    [string]$ExportPath = "$env:TEMP\MaintenanceWindow-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$AuditScriptBlock = {
    param($BuildFloor, $EventLookbackDays)

    $result = [PSCustomObject]@{
        ComputerName            = $env:COMPUTERNAME
        DisplayVersion          = $null
        CurrentBuildNumber      = $null
        UBR                     = $null
        MeetsBuildFloor         = $false
        MDMPolicyDelivered      = $false
        EffectivePolicyPresent  = $false
        MaintenanceWindowEnabled = "Unknown"
        RecurrenceRaw           = "Unknown"
        RuntimeEventCount       = 0
        LikelyFeatureActive     = "Unknown — no supported diagnostic for the server-side flighting gate"
        Notes                   = ""
    }

    try {
        $ver = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -EA Stop
        $result.DisplayVersion     = $ver.DisplayVersion
        $result.CurrentBuildNumber = $ver.CurrentBuildNumber
        $result.UBR                = $ver.UBR
        $result.MeetsBuildFloor    = ([int]$ver.CurrentBuildNumber -ge $BuildFloor)
    }
    catch {
        $result.Notes += "OS version read failed. "
    }

    # Raw MDM-delivered policy (provider path — GUID varies per enrollment, so search all providers)
    try {
        $providerRoot = "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers"
        if (Test-Path $providerRoot) {
            $providerPaths = Get-ChildItem $providerRoot -EA SilentlyContinue |
                ForEach-Object { Join-Path $_.PSPath "default\Update" }
            foreach ($p in $providerPaths) {
                if (Test-Path $p) {
                    $vals = Get-ItemProperty $p -EA SilentlyContinue
                    if ($vals -and ($vals.PSObject.Properties.Name -match "MaintenanceWindow")) {
                        $result.MDMPolicyDelivered = $true
                        break
                    }
                }
            }
        }
    }
    catch {
        $result.Notes += "Provider policy scan failed. "
    }

    # Effective (current) policy
    try {
        $currentPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
        if (Test-Path $currentPath) {
            $current = Get-ItemProperty $currentPath -EA SilentlyContinue
            $mwProps = $current.PSObject.Properties | Where-Object { $_.Name -match "MaintenanceWindow" }
            if ($mwProps) {
                $result.EffectivePolicyPresent = $true
                $enabledProp = $mwProps | Where-Object { $_.Name -match "Enabled" } | Select-Object -First 1
                if ($enabledProp) { $result.MaintenanceWindowEnabled = [bool]$enabledProp.Value }
                $recurProp = $mwProps | Where-Object { $_.Name -match "Recur|Repeat" } | Select-Object -First 1
                if ($recurProp) { $result.RecurrenceRaw = $recurProp.Value }
            }
        }
    }
    catch {
        $result.Notes += "Effective policy read failed. "
    }

    # Runtime evidence via event log
    try {
        $events = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -EA SilentlyContinue |
            Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-$EventLookbackDays) -and $_.Message -match "[Mm]aintenance [Ww]indow" }
        $result.RuntimeEventCount = ($events | Measure-Object).Count
        if ($result.RuntimeEventCount -gt 0) {
            $result.LikelyFeatureActive = "Likely YES — runtime evidence found in event log"
        }
        elseif ($result.MDMPolicyDelivered -and $result.MeetsBuildFloor) {
            $result.LikelyFeatureActive = "Likely NO — policy delivered, build eligible, but no runtime evidence over lookback window (possible feature-flighting gate not enabled for this device)"
        }
    }
    catch {
        $result.Notes += "Event log read failed (log may not exist on this build). "
    }

    $result
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
Write-Status "Maintenance Window readiness audit starting (build floor: $BuildFloor, event lookback: $EventLookbackDays days)" "INFO"

$results = [System.Collections.Generic.List[object]]::new()

if ($ComputerName -and $ComputerName.Count -gt 0) {
    foreach ($cn in $ComputerName) {
        Write-Status "Auditing $cn..." "INFO"
        try {
            $r = Invoke-Command -ComputerName $cn -ScriptBlock $AuditScriptBlock -ArgumentList $BuildFloor, $EventLookbackDays -EA Stop
            $results.Add($r)
        }
        catch {
            Write-Status "Failed to audit $cn : $($_.Exception.Message)" "ERROR"
        }
    }
}
else {
    Write-Status "No -ComputerName supplied; auditing local computer." "INFO"
    $results.Add((& $AuditScriptBlock $BuildFloor $EventLookbackDays))
}

if ($results.Count -eq 0) {
    Write-Status "No results collected." "ERROR"
    return
}

$results | Format-Table -AutoSize
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Exported $($results.Count) result(s) to $ExportPath" "OK"

$gateFlagged = ($results | Where-Object { $_.LikelyFeatureActive -like "Likely NO*" }).Count
if ($gateFlagged -gt 0) {
    Write-Status "$gateFlagged device(s) show delivered policy + eligible build but no runtime evidence — possible feature-flighting gate not yet enabled. This cannot be confirmed or resolved locally; see MaintenanceWindow-B.md Fix 1." "WARN"
}

Write-Status "Reminder: this is a Preview feature. Re-verify BuildFloor and overall feature status against current sources before treating results as authoritative for a production decision." "INFO"
