<#
.SYNOPSIS
    Fleet-level Windows Autopatch readiness and ring-assignment audit via Graph —
    surfaces devices with stale sync, static/dynamic ring membership conflicts, and
    devices duplicated across multiple ring groups.

.DESCRIPTION
    Autopatch-A.md's Validation Steps and Symptom → Cause Map identify two of the most
    common "silent" Autopatch problems as manual/repetitive portal work:
    - "Device duplicated across two rings" (Symptom → Cause Map) — caused by a manual
      ring override (Playbook 2) that was never cleaned up, conflicting with dynamic
      group recalculation
    - Stale readiness/registration state that only becomes visible one device at a time
      in the portal's Devices list

    This script uses Microsoft Graph to:
    - Enumerate the specified ring groups (Test/First/Fast/Broad — pass group IDs,
      since Autopatch doesn't expose a single "get all ring groups" Graph endpoint)
    - Cross-reference membership to flag any device present in more than one ring
      group simultaneously (the exact failure mode in Playbook 2's rollback note:
      "remember to remove it later, or it will never rejoin the dynamic rotation")
    - Pull registration group membership and flag devices whose Entra device object
      has a stale `approximateLastSignInDateTime` (a proxy for "device hasn't
      checked in — readiness evaluation may be running against stale state", per
      Autopatch-A.md Phase 2 guidance to not chase readiness failures without first
      confirming the device is actually online and syncing)
    - Summarise ring size balance, since Autopatch-A.md's Phase 3 guidance calls out
      "extremely small Test/First rings reduce the statistical value of the canary
      approach" as a design smell worth flagging proactively

    Exports full results to CSV and prints a colour-coded console summary.

    Does NOT cover (portal-only or beta-endpoint-limited — see Autopatch-A.md):
    - Readiness *reason* detail (license/join/management/OS build/conflicting policy)
      — the readiness reason string is portal-only as of writing
    - Release health / active safeguard holds
    - Feature update safeguard hold reasons for a specific device

.PARAMETER RegistrationGroupId
    Entra object ID of the Autopatch device registration group.

.PARAMETER RingGroupIds
    Hashtable mapping ring name to Entra group object ID, e.g.:
    @{ Test = "<guid>"; First = "<guid>"; Fast = "<guid>"; Broad = "<guid>" }
    Find these under Windows Autopatch > Devices in the Intune admin center, or via
    Get-MgGroup -Filter "displayName eq '<RingGroupName>'".

.PARAMETER StaleSignInDays
    Number of days since last Entra sign-in beyond which a device is flagged as
    possibly offline/not syncing. Default: 14.

.PARAMETER MinRingSize
    Ring size below which a WARN is raised for statistical-significance concerns per
    Autopatch-A.md Phase 3. Default: 5. Set to 0 to disable this check (e.g. for
    small pilot tenants where this is expected).

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\AutopatchReadiness-<timestamp>.csv

.EXAMPLE
    .\Get-AutopatchReadiness.ps1 -RegistrationGroupId "<guid>" -RingGroupIds @{ Test="<guid>"; First="<guid>"; Fast="<guid>"; Broad="<guid>" }

.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.DirectoryObjects modules
    Permissions: Group.Read.All, Device.Read.All
    Safe: Read-only — no group membership changes made
    Cross-references: Intune/Troubleshooting/Autopatch-B.md and Autopatch-A.md
                       (Playbook 2, Phase 2, Phase 3)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RegistrationGroupId,

    [Parameter(Mandatory)]
    [hashtable]$RingGroupIds,

    [int]$StaleSignInDays = 14,

    [int]$MinRingSize = 5,

    [string]$OutputPath = "C:\Temp\AutopatchReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
    Write-Status "Microsoft.Graph.Groups module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Groups -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (Group.Read.All, Device.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "Group.Read.All","Device.Read.All" -NoWelcome
}

# ── Step 1: Pull registration group membership ─────────────────────────────
Write-Status "Pulling registration group membership..." "INFO"
$registeredDevices = [System.Collections.Generic.Dictionary[string,object]]::new()

try {
    $members = Get-MgGroupMember -GroupId $RegistrationGroupId -All
    foreach ($m in $members) {
        $name = $m.AdditionalProperties["displayName"]
        $lastSignIn = $m.AdditionalProperties["approximateLastSignInDateTime"]
        $registeredDevices[$m.Id] = [PSCustomObject]@{
            DeviceId    = $m.Id
            DeviceName  = $name
            LastSignIn  = $lastSignIn
        }
    }
    Write-Status "Registration group contains $($registeredDevices.Count) device(s)." "OK"
} catch {
    Write-Status "Failed to read registration group: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ── Step 2: Pull each ring group's membership, track duplicates ────────────
Write-Status "Pulling ring group membership..." "INFO"
$deviceRingMap = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]::new()
$ringSizes     = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($ringName in $RingGroupIds.Keys) {
    $groupId = $RingGroupIds[$ringName]
    try {
        $ringMembers = Get-MgGroupMember -GroupId $groupId -All
        $ringSizes.Add([PSCustomObject]@{ Ring = $ringName; DeviceCount = $ringMembers.Count })

        foreach ($rm in $ringMembers) {
            if (-not $deviceRingMap.ContainsKey($rm.Id)) {
                $deviceRingMap[$rm.Id] = [System.Collections.Generic.List[string]]::new()
            }
            $deviceRingMap[$rm.Id].Add($ringName)
        }
        Write-Status "  $ringName ring: $($ringMembers.Count) device(s)" "INFO"
    } catch {
        Write-Status "  Failed to read $ringName ring group ($groupId): $($_.Exception.Message)" "WARN"
    }
}

# ── Step 3: Build per-device report ─────────────────────────────────────────
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($deviceId in $registeredDevices.Keys) {
    $dev = $registeredDevices[$deviceId]
    $rings = if ($deviceRingMap.ContainsKey($deviceId)) { $deviceRingMap[$deviceId] } else { @() }

    $staleFlag = "No"
    if ($dev.LastSignIn) {
        try {
            $age = (Get-Date) - [datetime]$dev.LastSignIn
            if ($age.TotalDays -gt $StaleSignInDays) { $staleFlag = "Yes ($([int]$age.TotalDays)d)" }
        } catch { }
    } else {
        $staleFlag = "Unknown (no sign-in data)"
    }

    $report.Add([PSCustomObject]@{
        DeviceName        = $dev.DeviceName
        DeviceId          = $deviceId
        RingMembership    = if ($rings.Count -eq 0) { "NOT IN ANY RING" } else { $rings -join ", " }
        RingCount         = $rings.Count
        DuplicatedAcrossRings = $rings.Count -gt 1
        LastSignIn        = $dev.LastSignIn
        StalePossiblyOffline = $staleFlag
    })
}

# ── Export ────────────────────────────────────────────────────────────────
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" "OK"

# ── Console summary ─────────────────────────────────────────────────────────
Write-Host "`n=== Ring Size Summary ===" -ForegroundColor Cyan
$ringSizes | Format-Table -AutoSize
foreach ($r in $ringSizes) {
    if ($MinRingSize -gt 0 -and $r.DeviceCount -lt $MinRingSize) {
        Write-Status "$($r.Ring) ring has only $($r.DeviceCount) device(s) — below MinRingSize ($MinRingSize), canary signal may not be statistically meaningful (Autopatch-A.md Phase 3)" "WARN"
    }
}

$duplicates = $report | Where-Object { $_.DuplicatedAcrossRings }
if ($duplicates.Count -gt 0) {
    Write-Host "`n=== Devices Duplicated Across Rings (fix per Autopatch-A.md Playbook 2 rollback) ===" -ForegroundColor Red
    $duplicates | Format-Table DeviceName, RingMembership -AutoSize
    Write-Status "$($duplicates.Count) device(s) found in more than one ring group simultaneously" "ERROR"
} else {
    Write-Status "No devices duplicated across ring groups." "OK"
}

$notInRing = $report | Where-Object { $_.RingCount -eq 0 }
if ($notInRing.Count -gt 0) {
    Write-Status "$($notInRing.Count) registered device(s) not in any ring group — check readiness state in the portal (Autopatch-A.md Validation Step 3)" "WARN"
}

$stale = $report | Where-Object { $_.StalePossiblyOffline -like "Yes*" }
if ($stale.Count -gt 0) {
    Write-Status "$($stale.Count) device(s) have not signed in within $StaleSignInDays days — confirm online before troubleshooting readiness (Autopatch-A.md Phase 2)" "WARN"
}

Write-Host "`nNote: readiness *reason* (license/join/management/OS build) and safeguard holds" -ForegroundColor DarkGray
Write-Host "are portal-only — see Autopatch-A.md Validation Step 3 and Phase 4." -ForegroundColor DarkGray
