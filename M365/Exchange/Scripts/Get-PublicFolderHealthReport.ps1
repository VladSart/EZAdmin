<#
.SYNOPSIS
    Audits Exchange Online Public Folder health — org enablement, root mailbox presence, hierarchy
    sync freshness, and (optionally) folder-level permissions in one pass.

.DESCRIPTION
    Companion script for PublicFolders-B.md / PublicFolders-A.md. Automates the Triage and
    Diagnosis & Validation Flow steps from both runbooks across every Public Folder mailbox instead
    of the runbooks' one-mailbox-at-a-time walkthrough.

    Checks and flags:
    - PF_DISABLED_ORG_WIDE: Get-OrganizationConfig shows PublicFoldersEnabled is not Local/Remote —
      Public Folders are off at the tenant level, the first thing to rule out per Fix 1
    - NO_ROOT_MAILBOX: no PF mailbox has IsRootPublicFolderMailbox = $true — nobody can browse the
      folder hierarchy even if content mailboxes are healthy (Dependency Cascade's top layer)
    - STALE_HIERARCHY_SYNC: HierarchyLastSyncTime is older than -SyncStalenessHours (default 24,
      matching the runbook's documented sync interval) — flags the "folders visible but stale/missing
      recently created ones" symptom before anyone starts poking at permissions
    - SYNC_DIAGNOSTIC_ERROR: Get-PublicFolderMailboxDiagnostics reports an aggregate error/failure for
      a mailbox — surfaced verbatim so it can be pasted into the escalation pack

    Optional -FolderPath check (Diagnosis Step 4):
    - NO_DEFAULT_PERMISSION: the folder has no "Default" permission entry, meaning authenticated users
      with no explicit grant get denied access — a common cause of "some people can see it, most can't"

    Does NOT cover:
    - Forcing a hierarchy sync (this script is read-only; run
      Update-PublicFolderMailbox -Identity <PFMailboxName> -InvokeSynchronizer manually per Fix 3
      after reviewing which mailboxes are stale)
    - Hybrid on-prem Public Folder health (Test-OAuthConnectivity / on-prem Exchange cmdlets are out
      of scope for an Exchange Online-connected session)

.PARAMETER FolderPath
    Optional. A specific Public Folder path (e.g. "\Company Announcements") to also check client
    permissions on, per Diagnosis Step 4.

.PARAMETER SyncStalenessHours
    Hours since HierarchyLastSyncTime before a PF mailbox is flagged STALE_HIERARCHY_SYNC.
    Default: 24 (matches the documented default sync interval).

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\PublicFolderHealth-<timestamp>.csv

.EXAMPLE
    .\Get-PublicFolderHealthReport.ps1

.EXAMPLE
    .\Get-PublicFolderHealthReport.ps1 -FolderPath "\Company Announcements" -SyncStalenessHours 12

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+
    Permissions: Exchange Administrator or View-Only Recipients / View-Only Organization Management
    Run-as: Connect-ExchangeOnline before running this script
    Safe: Read-only. Makes no changes to org config, hierarchy, or permissions.
#>

[CmdletBinding()]
param(
    [string]$FolderPath,

    [ValidateRange(1, 168)]
    [int]$SyncStalenessHours = 24,

    [string]$OutputPath = "C:\Temp\PublicFolderHealth-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

# Preflight
Write-Status "Checking Exchange Online connection..."
Try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "Exchange Online connected" -Status "OK"
} Catch {
    Write-Status "Not connected to Exchange Online. Run: Connect-ExchangeOnline" -Status "ERROR"
    Exit 1
}

New-Item -Path (Split-Path $OutputPath) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

$findings = [System.Collections.Generic.List[string]]::new()

# 1. Org-level enablement
Write-Status "Checking org-level Public Folder configuration..."
$orgConfig = Get-OrganizationConfig | Select-Object PublicFoldersEnabled, PublicFolderMailboxesLockedForNewConnections
Write-Host ""
Write-Host "--- Org Configuration ---"
$orgConfig | Format-List

If ($orgConfig.PublicFoldersEnabled -notin @("Local", "Remote")) {
    $findings.Add("PF_DISABLED_ORG_WIDE: PublicFoldersEnabled='$($orgConfig.PublicFoldersEnabled)'")
    Write-Status "Public Folders are not enabled at the org level" -Status "ERROR"
} Else {
    Write-Status "Public Folders enabled org-wide: $($orgConfig.PublicFoldersEnabled)" -Status "OK"
}

If ($orgConfig.PublicFolderMailboxesLockedForNewConnections) {
    $findings.Add("PF_MAILBOXES_LOCKED: PublicFolderMailboxesLockedForNewConnections=`$true — likely mid-migration")
    Write-Status "PF mailboxes are locked for new connections — a migration may be in progress" -Status "WARN"
}

# 2. Enumerate PF mailboxes and root
Write-Status "Enumerating Public Folder mailboxes..."
$pfMailboxes = Get-Mailbox -PublicFolder -ErrorAction SilentlyContinue

If (-not $pfMailboxes) {
    $findings.Add("NO_PF_MAILBOXES: Get-Mailbox -PublicFolder returned nothing")
    Write-Status "No Public Folder mailboxes found" -Status "ERROR"
} Else {
    $rootMailbox = $pfMailboxes | Where-Object { $_.IsRootPublicFolderMailbox }
    Write-Status "Found $($pfMailboxes.Count) PF mailbox(es)" -Status "OK"

    If (-not $rootMailbox) {
        $findings.Add("NO_ROOT_MAILBOX: no PF mailbox has IsRootPublicFolderMailbox=`$true")
        Write-Status "No root Public Folder mailbox found — hierarchy browsing will fail tenant-wide" -Status "ERROR"
    } Else {
        Write-Status "Root mailbox: $($rootMailbox.Name)" -Status "OK"
    }
}

# 3. Hierarchy sync freshness per mailbox
$results = [System.Collections.Generic.List[PSObject]]::new()

ForEach ($pfMbx in $pfMailboxes) {
    $record = [ordered]@{
        Name                  = $pfMbx.Name
        IsRoot                = $pfMbx.IsRootPublicFolderMailbox
        HierarchyLastSyncTime = $null
        HoursSinceSync        = $null
        SyncError             = $null
        Flags                 = ""
    }

    $flags = @()

    Try {
        $diag = Get-PublicFolderMailboxDiagnostics -Identity $pfMbx.Identity -ErrorAction Stop
        $lastSync = $diag | Select-Object -ExpandProperty HierarchyLastSyncTime -ErrorAction SilentlyContinue
        $record.HierarchyLastSyncTime = $lastSync

        If ($lastSync) {
            $hoursSince = [math]::Round(((Get-Date) - [datetime]$lastSync).TotalHours, 1)
            $record.HoursSinceSync = $hoursSince
            If ($hoursSince -gt $SyncStalenessHours) {
                $flags += "STALE_HIERARCHY_SYNC"
            }
        }

        $errorText = ($diag | Select-Object -ExpandProperty *Error* -ErrorAction SilentlyContinue |
            Where-Object { $_ }) -join '; '
        If ($errorText) {
            $record.SyncError = $errorText
            $flags += "SYNC_DIAGNOSTIC_ERROR"
            $findings.Add("SYNC_DIAGNOSTIC_ERROR: $($pfMbx.Name) — $errorText")
        }
    } Catch {
        $record.SyncError = $_.Exception.Message
        $flags += "DIAGNOSTIC_QUERY_FAILED"
    }

    If ($flags -contains "STALE_HIERARCHY_SYNC") {
        $findings.Add("STALE_HIERARCHY_SYNC: $($pfMbx.Name) last synced $($record.HoursSinceSync)h ago (threshold: ${SyncStalenessHours}h)")
        Write-Status "$($pfMbx.Name) hierarchy sync is stale ($($record.HoursSinceSync)h)" -Status "WARN"
    }

    $record.Flags = ($flags -join ', ')
    $results.Add([PSCustomObject]$record)
}

Write-Host ""
Write-Host "--- PF Mailbox Hierarchy Sync Status ---"
$results | Format-Table -AutoSize

# 4. Optional folder permission check
If ($FolderPath) {
    Write-Status "Checking client permissions on '$FolderPath'..."
    Try {
        $perms = Get-PublicFolderClientPermission -Identity $FolderPath -ErrorAction Stop
        $perms | Format-Table User, AccessRights -AutoSize

        $hasDefault = $perms | Where-Object { $_.User -eq "Default" }
        If (-not $hasDefault) {
            $findings.Add("NO_DEFAULT_PERMISSION: '$FolderPath' has no Default permission entry")
            Write-Status "'$FolderPath' has no Default permission — users without an explicit grant will be denied" -Status "WARN"
        }
    } Catch {
        Write-Status "Could not read permissions for '$FolderPath' — $($_.Exception.Message)" -Status "ERROR"
    }
}

# Summary
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"
If ($findings.Count -eq 0) {
    Write-Status "No issues found. Public Folder infrastructure appears healthy." -Status "OK"
} Else {
    Write-Status "$($findings.Count) issue(s) found:" -Status "WARN"
    $findings | ForEach-Object { Write-Host "  - $_" }
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" -Status "OK"
