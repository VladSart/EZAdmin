<#
.SYNOPSIS
    Audits Cloud-Managed Remote Mailbox (Exchange-attribute SOA transfer) readiness and current state.

.DESCRIPTION
    Read-only audit of the Cloud-Managed Remote Mailboxes feature (IsExchangeCloudManaged):
    - Tenant-wide SOA default state (BlockExchangeProvisioningFromOnPremEnabled)
    - Fleet inventory of directory-synced mailboxes and their per-mailbox SOA state
    - Flags mailboxes that were changed on-premises very recently but are already cloud-managed
      (the race condition covered in CloudManagedMailboxes-B.md Fix 2)
    - Optionally checks the on-premises Microsoft Entra Connect Sync build against the
      2.5.190.0 minimum required once any mailbox is cloud-managed
    - Exports findings to CSV for escalation or pre-rollout review

    Does NOT cover:
    - Microsoft Entra Cloud Sync writeback configuration status or attribute mappings —
      not exposed via Exchange Online or on-premises PowerShell. Check the Entra admin center
      (Identity > Hybrid management > Microsoft Entra Connect > Cloud Sync > Configurations)
      manually and record findings alongside this script's CSV output.
    - Object-level Source of Authority (identity attributes) — see the -A.md Scope note;
      this script covers Exchange-attribute SOA only.
    - Making any changes. This script never calls Set-Mailbox, Set-RemoteMailbox, or
      Set-OrganizationConfig — read-only throughout.

.PARAMETER OnPremExchangeServer
    FQDN of an on-premises Exchange server (CAS/Mailbox). Optional — if omitted, on-premises
    checks (Connect Sync build, on-prem WhenChanged comparison) are skipped.

.PARAMETER OnPremCredential
    PSCredential for the on-premises Exchange remote PowerShell session. Required if
    -OnPremExchangeServer is supplied.

.PARAMETER RecentChangeWindowHours
    How recently an on-prem RemoteMailbox change is considered "risky" if the mailbox is
    already cloud-managed (race-condition flag). Default: 24 (matches the documented
    minimum wait period in CloudManagedMailboxes-B.md).

.PARAMETER ExportPath
    Path for the CSV export. Default: .\CloudManagedMailboxAudit-<timestamp>.csv

.EXAMPLE
    .\Get-CloudManagedMailboxAudit.ps1

    Runs the EXO-only checks: tenant-wide SOA state and fleet inventory.

.EXAMPLE
    .\Get-CloudManagedMailboxAudit.ps1 -OnPremExchangeServer mail.contoso.local -OnPremCredential (Get-Credential)

    Runs the full audit including on-premises Connect Sync build check and recent-change race detection.

.NOTES
    Requires: ExchangeOnlineManagement module (and Exchange Management Shell access if using -OnPremExchangeServer)
    Run-as: Exchange Administrator, Hybrid Identity Administrator, or Global Administrator (EXO);
            an account with on-prem Exchange view permissions if using -OnPremExchangeServer
    Safe: Read-only throughout — no Set-* cmdlets are called anywhere in this script
    Tested on: Exchange Online with directory-synced mailboxes, hybrid with Exchange 2016/2019/SE
#>

[CmdletBinding()]
param(
    [string]$OnPremExchangeServer,
    [System.Management.Automation.PSCredential]$OnPremCredential,
    [int]$RecentChangeWindowHours = 24,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

function Add-Finding {
    param(
        [string]$Area,
        [string]$Check,
        [string]$Result,
        [string]$Status,
        [string]$Detail = ""
    )
    $script:findings.Add([PSCustomObject]@{
        Area      = $Area
        Check     = $Check
        Result    = $Result
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "  [$Status] $Check : $Result" -ForegroundColor $colour
    if ($Detail) { Write-Host "           $Detail" -ForegroundColor DarkGray }
}

$script:findings = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\CloudManagedMailboxAudit-$timestamp.csv"
}

$useOnPrem = $false
if ($OnPremExchangeServer) {
    if (-not $OnPremCredential) {
        Write-Status "-OnPremExchangeServer supplied without -OnPremCredential. Skipping on-premises checks." "WARN"
    } else {
        $useOnPrem = $true
    }
}

#region ─── Connect to Exchange Online ───────────────────────────────────────
Write-Status "Connecting to Exchange Online..."
try {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Status "ExchangeOnlineManagement module not found. Install: Install-Module ExchangeOnlineManagement" "ERROR"
        exit 1
    }
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Status "Connected to Exchange Online" "OK"
} catch {
    Write-Status "Failed to connect to Exchange Online: $_" "ERROR"
    exit 1
}
#endregion

#region ─── Optional: Connect to on-premises Exchange ────────────────────────
$onPremSession = $null
if ($useOnPrem) {
    Write-Status "Connecting to on-premises Exchange: $OnPremExchangeServer"
    try {
        $onPremSession = New-PSSession `
            -ConfigurationName Microsoft.Exchange `
            -ConnectionUri "http://$OnPremExchangeServer/PowerShell/" `
            -Authentication Kerberos `
            -Credential $OnPremCredential `
            -ErrorAction Stop
        Import-PSSession $onPremSession -DisableNameChecking -AllowClobber -Prefix OnPrem | Out-Null
        Write-Status "Connected to on-premises Exchange" "OK"
    } catch {
        Write-Status "Failed to connect to on-premises Exchange: $_ — continuing with EXO-only checks" "WARN"
        $useOnPrem = $false
    }
}
#endregion

#region ─── 1. Tenant-wide SOA default state ──────────────────────────────────
Write-Status "Checking tenant-wide Exchange-attribute SOA default..."

try {
    $orgConfig = Get-OrganizationConfig | Select-Object BlockExchangeProvisioningFromOnPremEnabled
    if ($orgConfig.BlockExchangeProvisioningFromOnPremEnabled) {
        Add-Finding -Area "Tenant SOA" -Check "Tenant-wide SOA default" `
            -Result "ENABLED — new mailboxes default to IsExchangeCloudManaged=True" -Status "WARN" `
            -Detail "Confirm ALL on-prem mailboxes have finished migrating before this was enabled. If not, disable immediately: Set-OrganizationConfig -ExchangeAttributesServerManagedByDefault, then escalate affected users to Microsoft Support."
    } else {
        Add-Finding -Area "Tenant SOA" -Check "Tenant-wide SOA default" `
            -Result "Disabled (per-mailbox model in use)" -Status "OK"
    }
} catch {
    Add-Finding -Area "Tenant SOA" -Check "Tenant-wide SOA default" -Result "Query failed: $_" -Status "ERROR"
}
#endregion

#region ─── 2. Fleet inventory — cloud-managed mailboxes ──────────────────────
Write-Status "Building fleet inventory of directory-synced mailboxes..."

$allSyncedMailboxes = @()
try {
    $allSyncedMailboxes = Get-Mailbox -ResultSize Unlimited |
        Where-Object { $_.IsDirSynced -eq $true } |
        Select-Object DisplayName, PrimarySmtpAddress, IsExchangeCloudManaged, RecipientTypeDetails

    $cloudManagedCount = ($allSyncedMailboxes | Where-Object { $_.IsExchangeCloudManaged }).Count
    $totalSyncedCount  = $allSyncedMailboxes.Count

    Add-Finding -Area "Fleet Inventory" -Check "Directory-synced mailboxes" `
        -Result "$totalSyncedCount total, $cloudManagedCount cloud-managed" -Status "INFO"

    if ($cloudManagedCount -eq 0 -and $orgConfig.BlockExchangeProvisioningFromOnPremEnabled) {
        Add-Finding -Area "Fleet Inventory" -Check "Cloud-managed count vs. tenant default" `
            -Result "Tenant-wide SOA is enabled but 0 mailboxes show cloud-managed" -Status "WARN" `
            -Detail "Expected if no new mailboxes have been provisioned since enabling; otherwise investigate."
    }
} catch {
    Add-Finding -Area "Fleet Inventory" -Check "Directory-synced mailboxes" -Result "Query failed: $_" -Status "ERROR"
}
#endregion

#region ─── 3. On-premises Connect Sync build check ───────────────────────────
if ($useOnPrem) {
    Write-Status "Checking on-premises Microsoft Entra Connect Sync build..."
    try {
        $syncVersion = Invoke-Command -Session $onPremSession -ScriptBlock {
            (Get-ADSyncGlobalSettings -ErrorAction SilentlyContinue).Parameters['Microsoft.Synchronize.ServerConfigurationVersion']
        } -ErrorAction Stop

        $minVersion = [version]"2.5.190.0"
        $currentVersion = $null
        if ($syncVersion -and [version]::TryParse($syncVersion, [ref]$currentVersion)) {
            if ($currentVersion -ge $minVersion) {
                Add-Finding -Area "On-Prem Sync" -Check "Entra Connect Sync build" `
                    -Result "$currentVersion (meets 2.5.190.0 minimum)" -Status "OK"
            } else {
                Add-Finding -Area "On-Prem Sync" -Check "Entra Connect Sync build" `
                    -Result "$currentVersion — BELOW 2.5.190.0 minimum" -Status "ERROR" `
                    -Detail "Any cloud-managed mailbox will have push failures until this is upgraded. See CloudManagedMailboxes-B.md Fix 4."
            }
        } else {
            Add-Finding -Area "On-Prem Sync" -Check "Entra Connect Sync build" `
                -Result "Could not determine build (Connect Sync may not be installed on this server, or Cloud Sync is the primary sync engine)" -Status "WARN"
        }
    } catch {
        Add-Finding -Area "On-Prem Sync" -Check "Entra Connect Sync build" -Result "Query failed: $_" -Status "WARN"
    }
}
#endregion

#region ─── 4. Race-condition flag — recent on-prem changes on cloud-managed mailboxes ─
if ($useOnPrem) {
    Write-Status "Cross-checking recent on-premises changes against cloud-managed mailboxes..."

    $cloudManagedMailboxes = $allSyncedMailboxes | Where-Object { $_.IsExchangeCloudManaged }
    $riskWindow = (Get-Date).AddHours(-$RecentChangeWindowHours)
    $flaggedCount = 0

    foreach ($mbx in $cloudManagedMailboxes) {
        try {
            $remoteMbx = Invoke-Command -Session $onPremSession -ScriptBlock {
                param($identity)
                Get-RemoteMailbox -Identity $identity -ErrorAction SilentlyContinue | Select-Object WhenChanged
            } -ArgumentList $mbx.PrimarySmtpAddress.ToString() -ErrorAction Stop

            if ($remoteMbx -and $remoteMbx.WhenChanged -gt $riskWindow) {
                $flaggedCount++
                Add-Finding -Area "Race Condition" -Check "$($mbx.DisplayName)" `
                    -Result "On-prem RemoteMailbox changed $($remoteMbx.WhenChanged) — inside the $RecentChangeWindowHours-hour risk window" `
                    -Status "WARN" `
                    -Detail "If this mailbox is already cloud-managed and the on-prem change was made AFTER the SOA flip, it's likely stale automation still touching AD. Investigate before trusting cloud-side edits on this mailbox."
            }
        } catch {
            # Non-fatal — some cloud-managed mailboxes may no longer have a resolvable on-prem RemoteMailbox object
            continue
        }
    }

    if ($flaggedCount -eq 0 -and $cloudManagedMailboxes.Count -gt 0) {
        Add-Finding -Area "Race Condition" -Check "Recent on-prem change sweep" `
            -Result "No cloud-managed mailboxes had on-prem changes inside the $RecentChangeWindowHours-hour window" -Status "OK"
    }
} else {
    Add-Finding -Area "Race Condition" -Check "Recent on-prem change sweep" `
        -Result "Skipped — no on-premises session (-OnPremExchangeServer not supplied or connection failed)" -Status "INFO"
}
#endregion

#region ─── 5. Known gaps (always reported) ───────────────────────────────────
Add-Finding -Area "Known Gaps" -Check "Cloud Sync writeback configuration status" `
    -Result "NOT CHECKED — not exposed via PowerShell" -Status "INFO" `
    -Detail "Verify manually: Entra admin center > Identity > Hybrid management > Microsoft Entra Connect > Cloud Sync > Configurations. Confirm job status Healthy and the Mail -> mail attribute mapping is present."

Add-Finding -Area "Known Gaps" -Check "Cloud Sync provisioning agent version" `
    -Result "NOT CHECKED — not exposed via Exchange PowerShell" -Status "INFO" `
    -Detail "Verify manually: Entra admin center > Cloud Sync > Agents (status Active, version 1.1.1107.0+), or locally via AADConnectProvisioningAgent.exe file properties."

Add-Finding -Area "Known Gaps" -Check "Mail-enabled groups / mail contacts" `
    -Result "OUT OF SCOPE — this script covers user mailboxes only" -Status "INFO" `
    -Detail "Groups and contacts use separate SOA mechanisms (Group SOA / Contact SOA) not audited here."
#endregion

#region ─── Summary ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Cloud-Managed Mailbox Audit Summary ────────────" -ForegroundColor Cyan

$okCount    = ($script:findings | Where-Object { $_.Status -eq "OK" }).Count
$warnCount  = ($script:findings | Where-Object { $_.Status -eq "WARN" }).Count
$errorCount = ($script:findings | Where-Object { $_.Status -eq "ERROR" }).Count
$infoCount  = ($script:findings | Where-Object { $_.Status -eq "INFO" }).Count

Write-Host "  OK      : $okCount" -ForegroundColor Green
Write-Host "  WARN    : $warnCount" -ForegroundColor Yellow
Write-Host "  ERROR   : $errorCount" -ForegroundColor Red
Write-Host "  INFO    : $infoCount" -ForegroundColor Cyan
Write-Host ""

$problems = $script:findings | Where-Object { $_.Status -in "WARN","ERROR" }
if ($problems) {
    Write-Host "─── Issues Found ──────────────────────────────────" -ForegroundColor Yellow
    $problems | Format-Table Area, Check, Result, Status, Detail -AutoSize -Wrap
}

$script:findings | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported -> $ExportPath" "OK"
#endregion

#region ─── Cleanup ───────────────────────────────────────────────────────────
if ($onPremSession) { Remove-PSSession $onPremSession -ErrorAction SilentlyContinue }
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Status "Cloud-managed mailbox audit complete — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
