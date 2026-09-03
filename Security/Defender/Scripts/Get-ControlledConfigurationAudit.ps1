<#
.SYNOPSIS
    Audits Windows devices for Microsoft Defender for Endpoint Controlled Configuration
    readiness and current enforcement state (local, remote, or Graph-assisted).

.DESCRIPTION
    Controlled Configuration has no dedicated Graph read/write surface as of this writing
    — it is a Windows Security Experience policy setting (shared with Tamper Protection)
    whose effective, on-device state is only observable via Get-MpComputerStatus. This
    script is scoped honestly around that constraint:

    - Locally (or against -ComputerName targets, via Invoke-Command/CIM if reachable):
      reads ControlledConfigurationState, IsTamperProtected, TamperProtectionSource,
      AMProductVersion, and the Sense sensor build (SenseVersion) to flag devices below
      the documented version floor (AV platform 4.18.26060.3004+, Sense build > 10.8804).
    - Flags devices with a live ConfigMgr client present (co-management indicator) since
      Controlled Configuration does not currently support co-managed environments.
    - Optionally cross-references Intune-managed device inventory via Microsoft Graph
      (beta managedDevices) for a tenant-wide readiness view, since Graph does not expose
      the ControlledConfigurationState property itself.

    It does NOT and cannot: enable, disable, or change Controlled Configuration policy
    (portal/Intune-only — Endpoint security > Antivirus > Windows Security Experience
    profile), read the Microsoft Defender portal's effective-configuration view for
    devices managed only via Defender for Endpoint security settings management (no
    Intune enrollment), or reset a device's Controlled Configuration state (requires
    local troubleshooting mode and MpCmdRun.exe -Config -ResetControlledConfiguration,
    run manually per device).

    Requires local admin (or equivalent remote access) on target devices for the
    Get-MpComputerStatus read. Graph cross-reference requires the
    Microsoft.Graph.Authentication module and DeviceManagementManagedDevices.Read.All.

.PARAMETER ComputerName
    One or more remote computer names to audit via Invoke-Command. Defaults to the local
    computer only.

.PARAMETER IncludeGraphInventory
    If set, also pulls Intune-managed Windows device inventory via Microsoft Graph to
    report a tenant-wide device count for cross-referencing against local audit results
    (Graph itself cannot report ControlledConfigurationState).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\ControlledConfiguration-Audit-<date>.csv.

.EXAMPLE
    .\Get-ControlledConfigurationAudit.ps1
    Audits the local computer only.

.EXAMPLE
    .\Get-ControlledConfigurationAudit.ps1 -ComputerName PC01,PC02,PC03 -IncludeGraphInventory

.NOTES
    Read-only. Does not modify Controlled Configuration, Tamper Protection, or any policy.
    Preview feature — behavior and the underlying Get-MpComputerStatus property names are
    subject to change; re-verify against the live Microsoft Learn page before relying on
    this script's floor-version constants in a future run.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [switch]$IncludeGraphInventory,
    [string]$ExportPath = "$env:TEMP\ControlledConfiguration-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Version floor constants (per Microsoft Learn, current as of 2026-07-30 —
# re-verify before relying on this in a future run; Preview feature)
# ---------------------------------------------------------------------------
$MinAMProductVersion = [version]"4.18.26060.3004"
$MinSenseBuild        = 10.8804

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Controlled Configuration audit starting for $($ComputerName.Count) device(s)" "INFO"

$scriptBlock = {
    $result = [ordered]@{
        ComputerName                 = $env:COMPUTERNAME
        Reachable                    = $true
        Error                        = $null
        ControlledConfigurationState = $null
        IsTamperProtected            = $null
        TamperProtectionSource       = $null
        AMProductVersion             = $null
        AMProductVersionMeetsFloor   = $null
        SenseVersion                 = $null
        SenseVersionMeetsFloor       = $null
        MDEOnboarded                 = $null
        ConfigMgrClientPresent       = $null
    }

    try {
        $mp = Get-MpComputerStatus -EA Stop
        $result.ControlledConfigurationState = if ($mp.PSObject.Properties.Name -contains "ControlledConfigurationState") { $mp.ControlledConfigurationState } else { "PropertyNotPresent (older AV platform build)" }
        $result.IsTamperProtected      = $mp.IsTamperProtected
        $result.TamperProtectionSource = $mp.TamperProtectionSource
        $result.AMProductVersion       = $mp.AMProductVersion
    }
    catch {
        $result.Reachable = $false
        $result.Error = "Get-MpComputerStatus failed: $($_.Exception.Message)"
        return [PSCustomObject]$result
    }

    try {
        $sense = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name SenseVersion -EA SilentlyContinue
        $result.SenseVersion = if ($sense) { $sense.SenseVersion } else { "Not found" }
    } catch { $result.SenseVersion = "Read failed" }

    try {
        $onboard = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue
        $result.MDEOnboarded = if ($onboard) { $onboard.OnboardingState -eq 1 } else { $false }
    } catch { $result.MDEOnboarded = "Unknown" }

    try {
        $ccm = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\CCM" -EA SilentlyContinue
        $result.ConfigMgrClientPresent = [bool]$ccm
    } catch { $result.ConfigMgrClientPresent = "Unknown" }

    [PSCustomObject]$result
}

# ---------------------------------------------------------------------------
# Step 1 — Collect per-device state
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($cn in $ComputerName) {
    Write-Status "Auditing $cn..." "INFO"
    try {
        if ($cn -eq $env:COMPUTERNAME) {
            $r = & $scriptBlock
        }
        else {
            $r = Invoke-Command -ComputerName $cn -ScriptBlock $scriptBlock -EA Stop
        }
        $results.Add($r)
    }
    catch {
        Write-Status "Failed to audit $cn : $($_.Exception.Message)" "ERROR"
        $results.Add([PSCustomObject]@{
            ComputerName = $cn; Reachable = $false; Error = $_.Exception.Message
            ControlledConfigurationState = $null; IsTamperProtected = $null; TamperProtectionSource = $null
            AMProductVersion = $null; AMProductVersionMeetsFloor = $null; SenseVersion = $null
            SenseVersionMeetsFloor = $null; MDEOnboarded = $null; ConfigMgrClientPresent = $null
        })
    }
}

# ---------------------------------------------------------------------------
# Step 2 — Evaluate version floors and build readiness verdict
# ---------------------------------------------------------------------------
foreach ($r in $results) {
    if (-not $r.Reachable) { continue }

    if ($r.AMProductVersion -and $r.AMProductVersion -ne "Read failed") {
        try {
            $r.AMProductVersionMeetsFloor = ([version]$r.AMProductVersion) -ge $MinAMProductVersion
        } catch { $r.AMProductVersionMeetsFloor = "ParseError" }
    }

    if ($r.SenseVersion -and $r.SenseVersion -notin @("Not found", "Read failed")) {
        try {
            $r.SenseVersionMeetsFloor = [double]$r.SenseVersion -gt $MinSenseBuild
        } catch { $r.SenseVersionMeetsFloor = "ParseError" }
    }
}

# ---------------------------------------------------------------------------
# Step 3 — Optional Graph cross-reference (Intune device inventory only —
# Graph cannot read ControlledConfigurationState itself)
# ---------------------------------------------------------------------------
if ($IncludeGraphInventory) {
    Write-Status "Pulling Intune-managed Windows device inventory from Graph for cross-reference..." "INFO"
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" "WARN"
    }
    else {
        try {
            if (-not (Get-MgContext)) {
                Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
            }
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=deviceName,osVersion,managementAgent&`$top=999"
            $deviceCount = 0
            do {
                $resp = Invoke-MgGraphRequest -Method GET -Uri $uri
                $deviceCount += $resp.value.Count
                $uri = $resp.'@odata.nextLink'
            } while ($uri)
            Write-Status "Tenant has $deviceCount Intune-managed Windows device(s) — this script audited $($results.Count) of them directly. Devices managed only via Defender for Endpoint security settings management (no Intune enrollment) are not included in this Graph count and must be checked in the Microsoft Defender portal." "INFO"
        }
        catch {
            Write-Status "Graph inventory pull failed: $($_.Exception.Message)" "WARN"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Report + export
# ---------------------------------------------------------------------------
$notReady = $results | Where-Object { $_.Reachable -and ($_.AMProductVersionMeetsFloor -eq $false -or $_.SenseVersionMeetsFloor -eq $false) }
$coManaged = $results | Where-Object { $_.Reachable -and $_.ConfigMgrClientPresent -eq $true }
$onState = $results | Where-Object { $_.Reachable -and $_.ControlledConfigurationState -match "^(1|On|Enabled)$" }

Write-Status "Summary: $($results.Count) audited, $($notReady.Count) below version floor, $($coManaged.Count) show a ConfigMgr client present, $($onState.Count) report Controlled Configuration On" "INFO"

if ($notReady.Count -gt 0) {
    Write-Status "Devices below the AV platform/Sense build floor will silently apply neither Controlled Configuration nor Tamper Protection if a policy targets them as On — remediate before enabling." "WARN"
}
if ($coManaged.Count -gt 0) {
    Write-Status "Co-managed devices detected — Controlled Configuration does not currently support ConfigMgr+Intune co-management. These devices should stay on classic Tamper Protection for now." "WARN"
}

$results | Sort-Object ComputerName | Format-Table -AutoSize

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Exported full report to $ExportPath" "OK"

Write-Status "Note: this script cannot read the Microsoft Defender portal's effective-configuration view for devices managed only via Defender for Endpoint security settings management (no Intune enrollment) — check that portal directly for those devices." "INFO"
