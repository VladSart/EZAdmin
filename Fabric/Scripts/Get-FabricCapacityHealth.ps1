<#
.SYNOPSIS
    Audits Microsoft Fabric capacity state and workspace-to-capacity assignment
    across a tenant, flagging paused capacities, unassigned workspaces, and
    capacities nearing/over their region's soft-delete or state-change risk.

.DESCRIPTION
    Connects via the official MicrosoftPowerBIMgmt module (Fabric capacities are
    administered through the same Power BI admin cmdlets) and reports:
      - Every capacity visible to the admin, its SKU, region, and State
      - Any capacity NOT in an Active state (Paused, Suspended, or otherwise)
      - Every workspace with no CapacityId assigned (falls back to Pro-only
        shared-capacity behavior; non-Power BI Fabric items won't function)
      - A summary count of workspaces per capacity, useful for spotting an
        overloaded capacity before a throttling ticket comes in

    This script does NOT call the Fabric Capacity Metrics app's CU-second data
    (no stable unauthenticated cmdlet surface for that yet) — for throttling
    diagnosis, pair this script's output with the Capacity Metrics app in the
    Fabric portal, as documented in FabricAdmin-B.md Fix 2.

.PARAMETER ExportPath
    Full path for CSV export of the workspace-assignment report. Defaults to
    $env:TEMP\Fabric-CapacityHealth-<date>.csv.

.PARAMETER FlagUnassignedOnly
    If set, only reports workspaces with no capacity assigned (skips the full
    capacity list) — useful for a quick "what's not on Fabric capacity yet" sweep.

.EXAMPLE
    # Full capacity + workspace assignment audit
    .\Get-FabricCapacityHealth.ps1

.EXAMPLE
    # Just find workspaces with no capacity assigned
    .\Get-FabricCapacityHealth.ps1 -FlagUnassignedOnly

.NOTES
    Requires: MicrosoftPowerBIMgmt module (Install-Module MicrosoftPowerBIMgmt)
    Permissions needed: Fabric Administrator, Power BI Administrator, or
        Power Platform Administrator role (Connect-PowerBIServiceAccount will
        prompt for interactive sign-in unless a service principal is configured)
    Safe to run in production — read-only operations only.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExportPath = "$env:TEMP\Fabric-CapacityHealth-$(Get-Date -Format yyyyMMdd-HHmmss).csv",

    [Parameter()]
    [switch]$FlagUnassignedOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
    Write-Status "MicrosoftPowerBIMgmt module not found. Installing..." -Status WARN
    Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force -AllowClobber
}
Import-Module MicrosoftPowerBIMgmt.Profile -ErrorAction Stop
Import-Module MicrosoftPowerBIMgmt.Admin -ErrorAction Stop
Write-Status "MicrosoftPowerBIMgmt module loaded." -Status OK
#endregion

#region Authentication
Write-Status "Connecting to Power BI / Fabric service..." -Status SECTION
try {
    Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
    Write-Status "Connected." -Status OK
}
catch {
    Write-Status "Connection failed: $($_.Exception.Message)" -Status ERROR
    Write-Status "Ensure the signed-in account has Fabric Administrator, Power BI Administrator, or Power Platform Administrator role." -Status INFO
    exit 1
}
#endregion

#region Capacity Audit
if (-not $FlagUnassignedOnly) {
    Write-Status "Auditing capacities..." -Status SECTION

    try {
        $capacities = Get-PowerBICapacity -Scope Organization -ErrorAction Stop
    }
    catch {
        Write-Status "Failed to retrieve capacities: $($_.Exception.Message)" -Status ERROR
        Disconnect-PowerBIServiceAccount | Out-Null
        exit 1
    }

    if (-not $capacities) {
        Write-Status "No capacities found or visible to this account." -Status WARN
    }
    else {
        foreach ($cap in $capacities) {
            $stateColour = if ($cap.State -eq "Active") { "OK" } else { "ERROR" }
            Write-Status "$($cap.DisplayName) [$($cap.Sku)] — State: $($cap.State)" -Status $stateColour
        }

        $nonActive = $capacities | Where-Object State -ne "Active"
        if ($nonActive) {
            Write-Status "$($nonActive.Count) capacity(ies) NOT in Active state — investigate before assuming a workspace-level fault." -Status WARN
            $nonActive | Select-Object DisplayName, Id, Sku, State | Format-Table -AutoSize
        }
    }
}
#endregion

#region Workspace-to-Capacity Assignment Audit
Write-Status "Auditing workspace capacity assignment..." -Status SECTION

try {
    $workspaces = Get-PowerBIWorkspace -Scope Organization -Include All -ErrorAction Stop
}
catch {
    Write-Status "Failed to retrieve workspaces: $($_.Exception.Message)" -Status ERROR
    Disconnect-PowerBIServiceAccount | Out-Null
    exit 1
}

$results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($ws in $workspaces) {
    $hasCapacity = -not [string]::IsNullOrEmpty($ws.CapacityId)
    $results.Add([PSCustomObject]@{
        WorkspaceName = $ws.Name
        WorkspaceId   = $ws.Id
        CapacityId    = $ws.CapacityId
        HasCapacity   = $hasCapacity
        WorkspaceType = $ws.Type
        State         = $ws.State
    })
}

$unassigned = $results | Where-Object { -not $_.HasCapacity -and $_.State -eq "Active" }

Write-Status "Total workspaces: $($results.Count) | Unassigned (no capacity, Active state): $($unassigned.Count)" -Status SECTION

if ($unassigned.Count -gt 0) {
    Write-Status "Workspaces with NO capacity assigned — Fabric items (non-Power BI) will not function here:" -Status WARN
    $unassigned | Select-Object WorkspaceName, WorkspaceId | Format-Table -AutoSize
}
else {
    Write-Status "No unassigned active workspaces found." -Status OK
}

# Workspace count per capacity — surfaces potential overload candidates before a throttling ticket lands
if (-not $FlagUnassignedOnly) {
    $perCapacity = $results | Where-Object HasCapacity | Group-Object CapacityId | Sort-Object Count -Descending
    if ($perCapacity) {
        Write-Status "Workspace count per capacity (top 10):" -Status SECTION
        $perCapacity | Select-Object -First 10 | ForEach-Object {
            Write-Host ("  {0,-40} {1,4} workspace(s)" -f $_.Name, $_.Count) -ForegroundColor Cyan
        }
        Write-Status "High workspace counts on a single capacity are a lead for CU-throttling investigation — pair with the Fabric Capacity Metrics app." -Status INFO
    }
}
#endregion

#region Export
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Workspace assignment report exported to: $ExportPath" -Status OK
#endregion

#region Disconnect
Disconnect-PowerBIServiceAccount | Out-Null
Write-Status "Disconnected." -Status OK
Write-Status "Run complete." -Status OK
#endregion
