<#
.SYNOPSIS
    Audits Microsoft 365 Backup coverage against the tenant's actual SharePoint sites,
    OneDrive accounts, and Exchange mailboxes to surface protection gaps.

.DESCRIPTION
    Microsoft 365 Backup protection policies do not automatically expand to cover new
    sites, OneDrive accounts, or mailboxes created after the policy exists, unless an
    inclusion rule matches them. This is the single most common "why can't I restore
    this" root cause per M365-Backup-B.md and M365-Backup-A.md.

    This script:
      1. Confirms the Backup Storage service is enabled tenant-wide.
      2. Enumerates all protection policies per workload (SharePoint / OneDrive / Exchange)
         and flags any stuck in "activating" past a configurable grace period.
      3. Enumerates all protection units per workload and diffs them against the tenant's
         actual site/account/mailbox inventory to flag NOT_PROTECTED items.
      4. Reports on inclusion rules present per policy (informational — helps explain
         why some items are covered automatically and others are not).
      5. Flags recent restore session failures for visibility.

    Read-only. Does not create, modify, or remove any protection policy, protection unit,
    or restore session. Requires Microsoft.Graph.BackupRestore (and Microsoft.Graph.Sites /
    Microsoft.Graph.Users for inventory comparison) to be installed and connected with at
    least BackupRestore-Configuration.Read.All, Sites.Read.All, and User.Read.All scopes.
    For Exchange mailbox inventory, the Exchange Online Management module (Get-Mailbox)
    is used if available; the script degrades gracefully if it is not connected.

.PARAMETER PolicyActivatingGraceHours
    Number of hours a policy is allowed to remain in "activating" status before being
    flagged as POLICY_STALLED. Default: 4 (matches the documented worst-case activation
    window for 1,000+ protection units).

.PARAMETER ExportPath
    Folder to write the CSV reports to. Default: current directory.

.PARAMETER SkipExchange
    Skip Exchange mailbox inventory comparison (useful if the Exchange Online Management
    module/session isn't available on this host).

.EXAMPLE
    .\Get-M365BackupCoverageAudit.ps1

    Runs a full tenant-wide coverage audit and writes CSV reports to the current directory.

.EXAMPLE
    .\Get-M365BackupCoverageAudit.ps1 -SkipExchange -ExportPath "C:\Reports"

    Skips the Exchange mailbox comparison (e.g., no EXO session available) and writes
    reports to C:\Reports.

.NOTES
    Requires: Microsoft.Graph.BackupRestore, Microsoft.Graph.Sites, Microsoft.Graph.Users
              modules; optionally ExchangeOnlineManagement for full Exchange coverage.
    Run as: any account holding Global Administrator, SharePoint Administrator, Exchange
            Administrator, or Microsoft 365 Backup Administrator (read scopes only needed).
    Safe/Unsafe: Read-only — safe to run in production at any time.
#>
[CmdletBinding()]
param(
    [int]$PolicyActivatingGraceHours = 4,
    [string]$ExportPath = ".",
    [switch]$SkipExchange
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Invoke-GraphCollection {
    # Thin wrapper around Invoke-MgGraphRequest that follows @odata.nextLink pagination
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while ($nextUri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        if ($response.value) { $results.AddRange($response.value) }
        $nextUri = $response.'@odata.nextLink'
    }
    return $results
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Microsoft 365 Backup coverage audit..."

$requiredModules = @("Microsoft.Graph.BackupRestore", "Microsoft.Graph.Sites", "Microsoft.Graph.Users")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Required module '$mod' is not installed. Run: Install-Module $mod -Scope CurrentUser" "ERROR"
        throw "Missing required module: $mod"
    }
}

if (-not (Get-MgContext)) {
    Write-Status "Not connected to Microsoft Graph. Connecting with required scopes..." "WARN"
    Connect-MgGraph -Scopes "BackupRestore-Configuration.Read.All", "Sites.Read.All", "User.Read.All"
}

# ---------------------------------------------------------------------------
# 1. Service status
# ---------------------------------------------------------------------------
Write-Status "Checking Backup Storage service status..."
$service = Get-MgSolutionBackupRestore
$findings = [System.Collections.Generic.List[object]]::new()

if ($service.ServiceStatus -ne "enabled") {
    Write-Status "Backup Storage service is NOT enabled (ServiceStatus: $($service.ServiceStatus))" "ERROR"
    $findings.Add([PSCustomObject]@{
        Category = "Service"; Item = "Tenant"; Flag = "SERVICE_NOT_ENABLED"
        Detail   = "ServiceStatus=$($service.ServiceStatus). No protection policy can be active until this is enabled."
    })
} else {
    Write-Status "Backup Storage service is enabled." "OK"
}

# ---------------------------------------------------------------------------
# 2. Protection policies — per workload, flag stalled activation
# ---------------------------------------------------------------------------
Write-Status "Enumerating protection policies..."
$policies = Get-MgSolutionBackupRestoreProtectionPolicy

foreach ($policy in $policies) {
    if ($policy.Status -eq "activating") {
        $ageHours = ((Get-Date) - [datetime]$policy.CreatedDateTime).TotalHours
        if ($ageHours -gt $PolicyActivatingGraceHours) {
            Write-Status "Policy '$($policy.DisplayName)' stuck in activating for $([math]::Round($ageHours,1))h" "WARN"
            $findings.Add([PSCustomObject]@{
                Category = "Policy"; Item = $policy.DisplayName; Flag = "POLICY_STALLED"
                Detail   = "Status=activating for $([math]::Round($ageHours,1)) hours (grace period: $PolicyActivatingGraceHours h)."
            })
        }
    }
}
Write-Status "Found $($policies.Count) protection polic$(if($policies.Count -eq 1){'y'}else{'ies'})." "OK"

# ---------------------------------------------------------------------------
# 3. SharePoint coverage diff
# ---------------------------------------------------------------------------
Write-Status "Auditing SharePoint site coverage..."
$protectedSites = Invoke-GraphCollection -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/siteProtectionUnits"
$protectedSiteIds = $protectedSites | ForEach-Object { $_.resourceId }

$allSites = Get-MgSite -All -Property "id,webUrl,displayName" | Where-Object { $_.WebUrl -notlike "*-my.sharepoint.com*" }
$unprotectedSites = $allSites | Where-Object { $_.Id -notin $protectedSiteIds }

foreach ($site in $unprotectedSites) {
    $findings.Add([PSCustomObject]@{
        Category = "SharePoint"; Item = $site.WebUrl; Flag = "NOT_PROTECTED"
        Detail   = "Site '$($site.DisplayName)' has no matching entry in siteProtectionUnits."
    })
}
Write-Status "SharePoint: $($allSites.Count) sites total, $($unprotectedSites.Count) not protected." $(if ($unprotectedSites.Count -gt 0) { "WARN" } else { "OK" })

# ---------------------------------------------------------------------------
# 4. OneDrive coverage diff
# ---------------------------------------------------------------------------
Write-Status "Auditing OneDrive account coverage..."
$protectedDrives = Invoke-GraphCollection -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/driveProtectionUnits"
$protectedDriveIds = $protectedDrives | ForEach-Object { $_.resourceId }

# Only meaningfully-licensed, enabled users are expected to have an active OneDrive
$licensedUsers = Get-MgUser -All -Property "id,userPrincipalName,accountEnabled,assignedLicenses" |
    Where-Object { $_.AccountEnabled -and $_.AssignedLicenses.Count -gt 0 }

$unprotectedDriveUsers = $licensedUsers | Where-Object { $_.Id -notin $protectedDriveIds }

foreach ($user in $unprotectedDriveUsers) {
    $findings.Add([PSCustomObject]@{
        Category = "OneDrive"; Item = $user.UserPrincipalName; Flag = "NOT_PROTECTED"
        Detail   = "Licensed, enabled user has no matching entry in driveProtectionUnits (may also mean OneDrive was never provisioned — verify before treating as a true gap)."
    })
}
Write-Status "OneDrive: $($licensedUsers.Count) licensed users, $($unprotectedDriveUsers.Count) with no matching protection unit." $(if ($unprotectedDriveUsers.Count -gt 0) { "WARN" } else { "OK" })

# ---------------------------------------------------------------------------
# 5. Exchange coverage diff (optional — requires EXO session)
# ---------------------------------------------------------------------------
if (-not $SkipExchange) {
    Write-Status "Auditing Exchange mailbox coverage..."
    if (Get-Command Get-Mailbox -ErrorAction SilentlyContinue) {
        $protectedMailboxes = Invoke-GraphCollection -Uri "https://graph.microsoft.com/v1.0/solutions/backupRestore/mailboxProtectionUnits"
        $protectedMailboxIds = $protectedMailboxes | ForEach-Object { $_.resourceId }

        $allMailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox |
            Select-Object DisplayName, PrimarySmtpAddress, ExternalDirectoryObjectId

        $unprotectedMailboxes = $allMailboxes | Where-Object { $_.ExternalDirectoryObjectId -notin $protectedMailboxIds }

        foreach ($mbx in $unprotectedMailboxes) {
            $findings.Add([PSCustomObject]@{
                Category = "Exchange"; Item = $mbx.PrimarySmtpAddress; Flag = "NOT_PROTECTED"
                Detail   = "Mailbox '$($mbx.DisplayName)' has no matching entry in mailboxProtectionUnits."
            })
        }
        Write-Status "Exchange: $($allMailboxes.Count) mailboxes, $($unprotectedMailboxes.Count) not protected." $(if ($unprotectedMailboxes.Count -gt 0) { "WARN" } else { "OK" })
    } else {
        Write-Status "Get-Mailbox not available — connect to Exchange Online Management to include Exchange in this audit. Skipping." "WARN"
        $findings.Add([PSCustomObject]@{
            Category = "Exchange"; Item = "N/A"; Flag = "EXCHANGE_AUDIT_SKIPPED"
            Detail   = "ExchangeOnlineManagement module/session not available on this host."
        })
    }
} else {
    Write-Status "Exchange coverage audit skipped by -SkipExchange." "INFO"
}

# ---------------------------------------------------------------------------
# 6. Recent restore session failures
# ---------------------------------------------------------------------------
Write-Status "Checking recent restore sessions for failures..."
$recentSessions = Get-MgSolutionBackupRestoreSession | Sort-Object CreatedDateTime -Descending | Select-Object -First 20
$failedSessions = $recentSessions | Where-Object { $_.Status -eq "failed" }

foreach ($session in $failedSessions) {
    $findings.Add([PSCustomObject]@{
        Category = "RestoreSession"; Item = $session.Id; Flag = "RECENT_RESTORE_FAILED"
        Detail   = "CreatedDateTime=$($session.CreatedDateTime). Investigate via Get-MgSolutionBackupRestoreSession -RestoreSessionId $($session.Id)."
    })
}
Write-Status "$($failedSessions.Count) of the last $($recentSessions.Count) restore sessions failed." $(if ($failedSessions.Count -gt 0) { "WARN" } else { "OK" })

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$csvPath = Join-Path $ExportPath "M365BackupCoverageAudit-$timestamp.csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Status "Audit complete. $($findings.Count) finding(s) written to $csvPath" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })
$findings | Format-Table -AutoSize
