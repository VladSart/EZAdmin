<#
.SYNOPSIS
    Read-only audit of Intune Multi Admin Approval (MAA) access policies, approver
    group health, and pending/expiring approval requests.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/MultiAdminApproval-B.md and
    MultiAdminApproval-A.md.

    Both runbooks describe two silent-failure conditions in the approver-group
    configuration that produce no error anywhere in the UI or API (MultiAdminApproval-A.md
    How It Works): the approver group must be a pure Microsoft Entra security group
    (not a Microsoft 365 group, mail-enabled security group, or distribution list), and
    it must be directly assigned as a member group to an Intune RBAC role assignment.
    This script automates both checks tenant-wide, plus flags approval requests
    approaching their undocumented-in-the-UI 3-day expiry window (MultiAdminApproval-A.md
    Dependency Stack, Layer 6) so a pending request doesn't silently expire before anyone
    notices — Intune sends no notification at creation, approaching-expiry, or approval.

    For each access policy (operationApprovalPolicy), reports:
      - policyType / policyPlatform / lastModifiedDateTime
      - Whether the referenced approver group(s) are pure security groups
      - Whether the referenced approver group(s) are directly assigned to an
        Intune RBAC role assignment (the "member group" requirement)
      - A RiskFlag of "SILENT FAILURE RISK" if either check fails

    Separately, lists all approval requests with age-in-hours and flags any still
    "needsApproval" past 60 hours (2.5 days) as approaching the 3-day expiry.

    Also flags, as a standing risk note rather than a pass/fail check, any access
    policy with policyType "role" — this policy type can deadlock a tenant's own
    RBAC administration if the approver group's role assignment is ever broken while
    it's active (MultiAdminApproval-A.md Remediation Playbook 3).

    This script makes NO changes to access policies, approval requests, RBAC role
    assignments, or group membership — it is read-only audit and diagnostic only.
    See MultiAdminApproval-A.md Remediation Playbooks 1-3 for the actual fixes once
    a gap is confirmed here.

.PARAMETER OutputPath
    Folder to write CSV reports to. Default: current directory.

.PARAMETER ExpiryWarningHours
    Age (in hours) at which a "needsApproval" request is flagged as approaching the
    3-day (72-hour) expiry window. Default: 60 (2.5 days) — deliberately earlier than
    the actual 72-hour cutoff to leave a response window. This is a script-side
    convenience threshold, not a Microsoft-documented value, and should be adjusted
    to fit how quickly your approver pool typically responds.

.EXAMPLE
    .\Get-MAAAccessPolicyAudit.ps1
    Runs the full tenant-wide audit: access policies, approver group health, and
    approval request expiry risk.

.EXAMPLE
    .\Get-MAAAccessPolicyAudit.ps1 -ExpiryWarningHours 48 -OutputPath C:\Reports
    Same audit, but flags pending requests earlier (48h) and writes CSVs to C:\Reports.

.NOTES
    Requires: Microsoft.Graph.Authentication (Invoke-MgGraphRequest), Microsoft.Graph.Groups
    Scopes:   DeviceManagementRBAC.Read.All, DeviceManagementConfiguration.Read.All, Group.Read.All
    Safe/Unsafe: Fully read-only. Zero New-Mg/Set-Mg/Remove-Mg/Update-Mg cmdlets anywhere
                 in this script's executable code — confirmed no write cmdlet touches
                 Entra ID, Intune, or Graph.

    Known Gaps (confirmed against the live operationApprovalPolicy Graph schema and the
    Multi Admin Approval documentation as of this writing — see MultiAdminApproval-A.md
    Learning Pointers):
      - Per-app exclusion lists (Exclusions tab on an access policy) are NOT exposed as
        a property on the operationApprovalPolicy Graph resource. This script cannot
        confirm or list exclusions — verify manually in the Intune admin center under
        the policy's Exclusions tab.
      - The tenant-wide "Allow access to unlicensed admins" setting is not read by this
        script (portal-surfaced only as of this writing). If approver licensing is in
        question, verify manually and cross-reference against each approver's assigned
        Intune license.
      - This script reports role-assignment membership using the roleAssignments
        "members" property returned by the beta endpoint at the time of writing. If a
        future Graph schema revision renames or restructures this property, the RBAC
        check below will silently under- or over-report — re-verify against current
        Microsoft Graph documentation before trusting this check in a schema-changed
        tenant.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [int]$ExpiryWarningHours = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Status "Starting Multi Admin Approval (MAA) access policy audit..." "INFO"

# ---------------------------------------------------------------------------
# Step 1: Pull all access policies
# ---------------------------------------------------------------------------
$policies = @()
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalPolicies"
    $policies = $resp.value
    Write-Status "Found $($policies.Count) MAA access policy object(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve operationApprovalPolicies: $($_.Exception.Message)" "ERROR"
}

if ($policies.Count -eq 0) {
    Write-Status "No MAA access policies found. MAA is not configured for any workload in this tenant — nothing further to audit." "WARN"
}

$policyReport = $policies | Select-Object displayName, policyType, policyPlatform, lastModifiedDateTime,
    @{Name = "ApproverGroupCount"; Expression = { $_.approverGroupIds.Count } }
$policyReport | Format-Table -AutoSize
$policyReport | Export-Csv -Path (Join-Path $OutputPath "MAA-AccessPolicies.csv") -NoTypeInformation

$rolePolicies = $policies | Where-Object { $_.policyType -eq "role" }
if ($rolePolicies.Count -gt 0) {
    Write-Status "$($rolePolicies.Count) 'role'-type access policy found — this policy type can deadlock RBAC administration if its approver group's own role assignment is ever broken. See MultiAdminApproval-A.md Remediation Playbook 3 before touching RBAC in this tenant." "WARN"
}

# ---------------------------------------------------------------------------
# Step 2: Pull RBAC role assignments once, for the approver-group cross-check
# ---------------------------------------------------------------------------
$roleAssignments = @()
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments"
    $roleAssignments = $resp.value
    Write-Status "Retrieved $($roleAssignments.Count) Intune RBAC role assignment(s) for cross-check." "OK"
}
catch {
    Write-Status "Failed to retrieve roleAssignments — approver RBAC-assignment check will be skipped: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# Step 3: Validate each approver group referenced by any policy
# ---------------------------------------------------------------------------
$approverHealth = @()
$checkedGroupIds = @{}

foreach ($policy in $policies) {
    foreach ($gid in $policy.approverGroupIds) {
        if (-not $checkedGroupIds.ContainsKey($gid)) {
            $group = $null
            try {
                $group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=id,displayName,securityEnabled,mailEnabled,groupTypes"
            }
            catch {
                Write-Status "Could not resolve approver group $gid : $($_.Exception.Message)" "WARN"
            }
            $checkedGroupIds[$gid] = $group
        }
        $g = $checkedGroupIds[$gid]

        if ($null -eq $g) {
            $approverHealth += [pscustomobject]@{
                Policy               = $policy.displayName
                PolicyType           = $policy.policyType
                ApproverGroupId      = $gid
                ApproverGroupName    = "<unresolved>"
                IsPureSecurityGroup  = "UNKNOWN"
                DirectRBACAssignment = "UNKNOWN"
                RiskFlag             = "COULD NOT VALIDATE"
            }
            continue
        }

        $isPureSecurity = ($g.securityEnabled -eq $true -and $g.mailEnabled -eq $false -and ($g.groupTypes -notcontains "Unified"))
        $hasRoleAssignment = $false
        if ($roleAssignments.Count -gt 0) {
            $hasRoleAssignment = [bool]($roleAssignments | Where-Object { $_.members -contains $gid })
        }

        $risk = "OK"
        if (-not $isPureSecurity -and -not $hasRoleAssignment) { $risk = "SILENT FAILURE RISK (wrong group type AND no RBAC assignment)" }
        elseif (-not $isPureSecurity) { $risk = "SILENT FAILURE RISK (not a pure security group)" }
        elseif (-not $hasRoleAssignment) { $risk = "SILENT FAILURE RISK (not directly assigned to an RBAC role)" }

        $approverHealth += [pscustomobject]@{
            Policy               = $policy.displayName
            PolicyType           = $policy.policyType
            ApproverGroupId      = $gid
            ApproverGroupName    = $g.displayName
            IsPureSecurityGroup  = $isPureSecurity
            DirectRBACAssignment = $hasRoleAssignment
            RiskFlag             = $risk
        }
    }
}

Write-Host ""
Write-Status "Approver group health:" "INFO"
$approverHealth | Format-Table -AutoSize
$approverHealth | Export-Csv -Path (Join-Path $OutputPath "MAA-ApproverGroupHealth.csv") -NoTypeInformation

$atRiskGroups = $approverHealth | Where-Object { $_.RiskFlag -like "SILENT FAILURE RISK*" }
if ($atRiskGroups.Count -gt 0) {
    Write-Status "$($atRiskGroups.Count) approver group configuration(s) flagged as silent-failure risk. See MultiAdminApproval-B.md Fix 7 / MultiAdminApproval-A.md Playbook 2 to correct." "WARN"
}
else {
    Write-Status "All resolved approver groups pass the security-group-type and RBAC-assignment checks." "OK"
}

# ---------------------------------------------------------------------------
# Step 4: Pull approval requests and flag expiry risk
# ---------------------------------------------------------------------------
$requests = @()
try {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/operationApprovalRequests"
    $requests = $resp.value
    Write-Status "Retrieved $($requests.Count) approval request(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve operationApprovalRequests: $($_.Exception.Message)" "ERROR"
}

$requestReport = $requests | ForEach-Object {
    $ageHours = "n/a"
    $expiryRisk = "n/a"
    if ($_.createdDateTime) {
        $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($_.createdDateTime).ToUniversalTime()
        $ageHours = [math]::Round($age.TotalHours, 1)
        if ($_.status -eq "needsApproval" -and $age.TotalHours -ge $ExpiryWarningHours) {
            $expiryRisk = "APPROACHING 3-DAY (72h) EXPIRY"
        }
    }
    [pscustomobject]@{
        RequestId  = $_.requestId
        Status     = $_.status
        CreatedUTC = $_.createdDateTime
        AgeHours   = $ageHours
        ExpiryRisk = $expiryRisk
    }
}
$requestReport = $requestReport | Sort-Object AgeHours -Descending
$requestReport | Format-Table -AutoSize
$requestReport | Export-Csv -Path (Join-Path $OutputPath "MAA-ApprovalRequests.csv") -NoTypeInformation

$atRiskRequests = $requestReport | Where-Object { $_.ExpiryRisk -eq "APPROACHING 3-DAY (72h) EXPIRY" }
if ($atRiskRequests.Count -gt 0) {
    Write-Status "$($atRiskRequests.Count) pending request(s) approaching the 3-day expiry window with no Intune notification pending. Contact an approver directly." "WARN"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "Audit complete. Reports written to: $OutputPath" "OK"
Write-Status "Known Gaps: per-app exclusion lists and the 'Allow access to unlicensed admins' tenant setting are portal-only and NOT covered by this script (see .NOTES). Verify both manually if either is in question." "WARN"
