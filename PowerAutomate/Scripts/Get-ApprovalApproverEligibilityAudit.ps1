<#
.SYNOPSIS
    Audits Power Automate approval assignee eligibility and, where ineligible, resolves an
    escalation contact — automates the diagnostic core of Approval-Workflows-A.md / -B.md.

.DESCRIPTION
    "Start and wait for an approval" has no in-flight way to edit who it was sent to, and
    "Everyone must approve" waits indefinitely for a non-responder with no built-in timeout.
    Both runbooks identify a disabled/unlicensed approver account as the single most common
    cause of a "stuck approval" ticket. This script checks a supplied list of approver UPNs
    (typically pulled from the flow's approval action Inputs) and reports:

    - AccountEnabled / license state per approver (INELIGIBLE if either fails)
    - The approver's manager, as a ready-made escalation candidate if -ResolveManager is used —
      operationalizes the reminder/escalation pattern from Approval-Workflows-A.md Playbook 2
    - A tenant-wide summary suitable for pasting straight into the Escalation Evidence template
      in Approval-Workflows-B.md

    This does not query the Approvals service itself — there is no supported API for reading
    a specific approval request's live state. Run History and the approval action's Inputs
    must still be checked manually in the portal; this script covers the approver-eligibility
    half of the diagnosis, which is fully scriptable.

    Read-only. Makes no changes to any user account, flow, or approval.

.PARAMETER ApproverUPNs
    One or more approver UPNs to check, e.g. from the flow's "Assigned to" field.

.PARAMETER ResolveManager
    Also resolve each approver's manager, for use as an escalation contact per
    Approval-Workflows-A.md Playbook 2 (manager-lookup escalation pattern).

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\ApprovalEligibility-<timestamp>

.EXAMPLE
    .\Get-ApprovalApproverEligibilityAudit.ps1 -ApproverUPNs "jane.doe@contoso.com","john.smith@contoso.com"

.EXAMPLE
    # Also pull each approver's manager so a stuck "Everyone must approve" can be escalated immediately
    .\Get-ApprovalApproverEligibilityAudit.ps1 -ApproverUPNs "jane.doe@contoso.com" -ResolveManager

.NOTES
    Requires: Microsoft.Graph.Users module
    Auth:     Connect-MgGraph -Scopes "User.Read.All"
    Permissions: Directory reader (any role that can read user + manager properties)
    Safe to run repeatedly — read-only.
    Companion runbooks: PowerAutomate/Troubleshooting/Approval-Workflows-A.md and -B.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ApproverUPNs,

    [Parameter()]
    [switch]$ResolveManager,

    [Parameter()]
    [string]$OutputPath = "C:\Temp\ApprovalEligibility-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Status "Microsoft.Graph.Users not found. Installing..." "WARN"
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.Graph.Users -ErrorAction Stop

Write-Status "Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome -ErrorAction Stop
} catch {
    Write-Status "Graph auth failed: $_" "ERROR"
    exit 1
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ─── Per-approver eligibility check ────────────────────────────────────────────

$Report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Upn in $ApproverUPNs) {

    $User = $null
    try {
        $User = Get-MgUser -UserId $Upn -Property "displayName,accountEnabled,assignedLicenses,mail" -ErrorAction Stop
    } catch {
        # falls through to null-user handling below
    }

    $Reasons = [System.Collections.Generic.List[string]]::new()
    $Licensed = $false

    if (-not $User) {
        $Reasons.Add("Account not found — deleted, or UPN typo'd/stale")
    } else {
        if (-not $User.AccountEnabled) { $Reasons.Add("Account disabled") }
        $Licensed = ($User.AssignedLicenses.Count -gt 0)
        if (-not $Licensed) { $Reasons.Add("No licenses assigned") }
    }

    $Eligible = ($Reasons.Count -eq 0)

    $ManagerUpn = $null
    if ($ResolveManager -and $User) {
        try {
            $Mgr = Get-MgUserManager -UserId $Upn -ErrorAction Stop
            $ManagerUpn = $Mgr.AdditionalProperties["userPrincipalName"]
        } catch {
            $ManagerUpn = "(no manager set in Entra ID)"
        }
    }

    $Report.Add([PSCustomObject]@{
        ApproverUPN     = $Upn
        DisplayName     = $User.DisplayName
        AccountEnabled  = if ($User) { $User.AccountEnabled } else { $null }
        Licensed        = $Licensed
        Eligible        = $Eligible
        IneligibleReason = ($Reasons -join "; ")
        EscalateToManager = $ManagerUpn
    })
}

# ─── Report ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== APPROVAL APPROVER ELIGIBILITY AUDIT ===" -ForegroundColor Magenta
Write-Status "Approvers checked: $($Report.Count)"

$Ineligible = $Report | Where-Object { -not $_.Eligible }
if ($Ineligible.Count -gt 0) {
    Write-Status "`nINELIGIBLE approvers found: $($Ineligible.Count)" "ERROR"
    $Ineligible | Format-Table ApproverUPN, DisplayName, IneligibleReason, EscalateToManager -AutoSize -Wrap
    Write-Status "If this is 'Everyone must approve' and any of the above are the ONLY assigned approver, the run cannot complete without cancel+resubmit — see Approval-Workflows-B.md Fix 1/2." "WARN"
} else {
    Write-Status "All listed approvers are enabled and licensed." "OK"
}

if ($ResolveManager -and $Ineligible.Count -gt 0) {
    Write-Status "`nSuggested escalation contacts (manager of each ineligible approver) are in EscalateToManager above." "WARN"
}

# ─── Export ────────────────────────────────────────────────────────────────────

$Report | Export-Csv "$OutputPath\approver-eligibility.csv" -NoTypeInformation -Encoding UTF8

Write-Status "`nReport exported to: $OutputPath" "OK"
Write-Status "Remember: this covers approver eligibility only. Run History, approval type" "INFO"
Write-Status "('First to respond' vs 'Everyone must approve'), and elapsed run duration vs. the" "INFO"
Write-Status "30-day platform ceiling must still be checked manually in the portal." "INFO"
Write-Status "Done." "OK"
