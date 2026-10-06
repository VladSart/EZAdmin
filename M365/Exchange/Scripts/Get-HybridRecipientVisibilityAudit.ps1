<#
.SYNOPSIS
    Audits Exchange hybrid recipient representation on both sides (on-prem AD vs Exchange Online) to find GAL-split defects.

.DESCRIPTION
    Read-only. Compares on-premises RemoteMailbox objects with Exchange Online mailboxes and flags:
      - CLOUD_MBX_NO_ONPREM_RECIPIENT : synced EXO mailbox whose on-prem user has no Exchange attributes
                                        (licensed before Enable-RemoteMailbox) -> invisible in on-prem GAL
      - CLOUD_ONLY_MBX                : EXO mailbox with IsDirSynced = False in a hybrid org
      - GUID_ZERO                     : on-prem RemoteMailbox ExchangeGuid is all zeros
      - GUID_MISMATCH                 : on-prem RemoteMailbox ExchangeGuid differs from EXO
      - ROUTING_NOT_MOERA             : RemoteRoutingAddress not *.mail.onmicrosoft.com
      - REMOTE_NO_CLOUD_MBX           : on-prem RemoteMailbox with no matching EXO mailbox
      - HIDDEN_MISMATCH               : HiddenFromAddressListsEnabled differs on-prem vs cloud
      - TYPE_MISMATCH                 : e.g. SharedMailbox in EXO but RemoteUserMailbox on-prem
      - ONPREM_MBX_NOT_IN_CLOUD       : on-prem mailbox with no EXO recipient (sync scope/error)

    Does NOT change anything, does not check OAB generation, connectors, OAuth or sync-engine internals.

    Session requirements (same PowerShell session):
      1. On-prem Exchange cmdlets: Exchange Management Shell, an on-prem remote session, or the
         Exchange Management Tools snap-in:
           Add-PSSnapin Microsoft.Exchange.Management.PowerShell.RecipientManagement
      2. Exchange Online connected WITH A PREFIX so on-prem Get-Mailbox/Get-User are not shadowed:
           Connect-ExchangeOnline -Prefix Cloud
         (Get-EXOMailbox / Get-EXORecipient are REST cmdlets and are not prefixed.)

.PARAMETER TenantMoeraDomain
    Optional. The tenant routing domain, e.g. contoso.mail.onmicrosoft.com. If omitted the script
    only checks that RemoteRoutingAddress ends in .mail.onmicrosoft.com.

.PARAMETER SkipOnPremMailboxCheck
    Skip the on-prem mailbox -> cloud MailUser check (useful in tools-only orgs or very large orgs).

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP

.EXAMPLE
    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.RecipientManagement
    Connect-ExchangeOnline -Prefix Cloud
    .\Get-HybridRecipientVisibilityAudit.ps1 -TenantMoeraDomain contoso.mail.onmicrosoft.com

.NOTES
    Requires: ExchangeOnlineManagement v3+, on-prem Exchange cmdlets (2016/2019/SE or Management Tools).
    Run as: an account with Recipient Management (on-prem) and View-Only Recipients (EXO) at minimum.
    Safe: read-only. Large orgs: Get-User is called only for EXO mailboxes with no on-prem RemoteMailbox.
#>
[CmdletBinding()]
param(
    [string]$TenantMoeraDomain,
    [switch]$SkipOnPremMailboxCheck,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Upn, [string]$Code, [string]$Severity, [string]$Detail, [string]$Fix)
    $findings.Add([pscustomobject]@{
        UserPrincipalName = $Upn; Code = $Code; Severity = $Severity; Detail = $Detail; SuggestedFix = $Fix
    })
}

# ---------------- Preflight ----------------
Write-Status "Preflight: checking cmdlet availability"
foreach ($c in 'Get-RemoteMailbox','Get-User','Get-EXOMailbox','Get-EXORecipient') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
        Write-Status "Missing cmdlet '$c'. See .DESCRIPTION for session requirements." "ERROR"
        throw "Preflight failed: $c not available"
    }
}
$gu = Get-Command Get-User
if ($gu.Source -like 'tmpEXO*' -or $gu.ModuleName -like 'tmpEXO*') {
    Write-Status "Get-User resolves to Exchange Online - reconnect EXO with -Prefix Cloud." "ERROR"
    throw "Preflight failed: cmdlet collision"
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
Write-Status "Preflight OK" "OK"

# ---------------- Detect: collect ----------------
Write-Status "Collecting on-prem RemoteMailbox objects"
$onPremRemote = @(Get-RemoteMailbox -ResultSize Unlimited -ErrorAction Stop |
    Select-Object UserPrincipalName,RecipientTypeDetails,ExchangeGuid,RemoteRoutingAddress,HiddenFromAddressListsEnabled)
Write-Status ("On-prem RemoteMailbox objects: {0}" -f $onPremRemote.Count)

Write-Status "Collecting Exchange Online mailboxes"
$cloudMbx = @(Get-EXOMailbox -ResultSize Unlimited -Properties ExchangeGuid,IsDirSynced,HiddenFromAddressListsEnabled,UserPrincipalName,RecipientTypeDetails,PrimarySmtpAddress |
    Select-Object UserPrincipalName,RecipientTypeDetails,ExchangeGuid,IsDirSynced,HiddenFromAddressListsEnabled,PrimarySmtpAddress)
Write-Status ("EXO mailboxes: {0}" -f $cloudMbx.Count)

$remoteByUpn = @{}
foreach ($r in $onPremRemote) { if ($r.UserPrincipalName) { $remoteByUpn[$r.UserPrincipalName.ToLower()] = $r } }
$cloudByUpn = @{}
foreach ($m in $cloudMbx) { if ($m.UserPrincipalName) { $cloudByUpn[$m.UserPrincipalName.ToLower()] = $m } }

$typeMap = @{
    'UserMailbox'      = 'RemoteUserMailbox'
    'SharedMailbox'    = 'RemoteSharedMailbox'
    'RoomMailbox'      = 'RemoteRoomMailbox'
    'EquipmentMailbox' = 'RemoteEquipmentMailbox'
}

# ---------------- Execute: compare cloud -> on-prem ----------------
Write-Status "Comparing EXO mailboxes against on-prem"
foreach ($m in $cloudMbx) {
    $upn = [string]$m.UserPrincipalName
    if (-not $upn) { continue }
    if (-not $m.IsDirSynced) {
        Add-Finding $upn 'CLOUD_ONLY_MBX' 'WARN' "$($m.RecipientTypeDetails) created cloud-only; no on-prem object" 'HybridGALSplit-B Fix 3 (mail contact in non-synced OU, or soft-match conversion)'
        continue
    }
    $r = $remoteByUpn[$upn.ToLower()]
    if (-not $r) {
        $u = $null
        try { $u = Get-User -Identity $upn -ErrorAction Stop } catch { $u = $null }
        if ($u -and [string]$u.RecipientType -eq 'User') {
            Add-Finding $upn 'CLOUD_MBX_NO_ONPREM_RECIPIENT' 'ERROR' 'Synced user has EXO mailbox but no Exchange attributes on-prem' 'HybridGALSplit-B Fix 1 (Enable-RemoteMailbox + Set-RemoteMailbox -ExchangeGuid)'
        } elseif ($u) {
            Add-Finding $upn 'CLOUD_MBX_ONPREM_TYPE_UNEXPECTED' 'WARN' ("On-prem RecipientType is {0}, not RemoteMailbox" -f $u.RecipientType) 'Investigate - possible dual mailbox (on-prem + cloud)'
        } else {
            Add-Finding $upn 'CLOUD_MBX_ONPREM_NOT_FOUND' 'WARN' 'Synced EXO mailbox but UPN not found on-prem (UPN changed?)' 'Match by ImmutableId/mS-DS-ConsistencyGuid and check UPN'
        }
        continue
    }
    $cg = [string]$m.ExchangeGuid
    $og = [string]$r.ExchangeGuid
    if ($og -eq [guid]::Empty.ToString()) {
        Add-Finding $upn 'GUID_ZERO' 'WARN' "On-prem ExchangeGuid zero; cloud $cg" 'Set-RemoteMailbox -ExchangeGuid (Fix 2)'
    } elseif ($og -ne $cg) {
        Add-Finding $upn 'GUID_MISMATCH' 'ERROR' "On-prem $og vs cloud $cg" 'Set-RemoteMailbox -ExchangeGuid (Fix 2) after confirming the cloud mailbox is the live one'
    }
    if ([bool]$r.HiddenFromAddressListsEnabled -ne [bool]$m.HiddenFromAddressListsEnabled) {
        Add-Finding $upn 'HIDDEN_MISMATCH' 'WARN' ("Hidden on-prem={0} cloud={1}" -f $r.HiddenFromAddressListsEnabled,$m.HiddenFromAddressListsEnabled) 'Set on-prem (SOA), delta sync (Fix 4)'
    }
    $expected = $typeMap[[string]$m.RecipientTypeDetails]
    if ($expected -and [string]$r.RecipientTypeDetails -ne $expected) {
        Add-Finding $upn 'TYPE_MISMATCH' 'WARN' ("EXO {0} vs on-prem {1}" -f $m.RecipientTypeDetails,$r.RecipientTypeDetails) "Set-RemoteMailbox -Type (expect $expected)"
    }
}

# ---------------- Execute: on-prem RemoteMailbox checks ----------------
Write-Status "Checking on-prem RemoteMailbox routing and orphans"
foreach ($r in $onPremRemote) {
    $upn = [string]$r.UserPrincipalName
    $rra = [string]$r.RemoteRoutingAddress
    $rraAddr = ($rra -replace '^(?i)smtp:','')
    $badRouting = $false
    if ($TenantMoeraDomain) { if ($rraAddr -notlike "*@$TenantMoeraDomain") { $badRouting = $true } }
    elseif ($rraAddr -notlike '*.mail.onmicrosoft.com') { $badRouting = $true }
    if ($badRouting) {
        Add-Finding $upn 'ROUTING_NOT_MOERA' 'ERROR' "RemoteRoutingAddress = $rra" 'Set-RemoteMailbox -RemoteRoutingAddress <alias>@<tenant>.mail.onmicrosoft.com'
    }
    if ($upn -and -not $cloudByUpn.ContainsKey($upn.ToLower())) {
        Add-Finding $upn 'REMOTE_NO_CLOUD_MBX' 'WARN' 'On-prem RemoteMailbox but no EXO mailbox (unlicensed / deleted / not synced / UPN differs)' 'Check licence, sync scope, soft-deleted mailboxes (Get-EXOMailbox -SoftDeletedMailbox)'
    }
}

# ---------------- Execute: on-prem mailboxes -> cloud ----------------
if (-not $SkipOnPremMailboxCheck) {
    if (Get-Command Get-Mailbox -ErrorAction SilentlyContinue) {
        Write-Status "Checking on-prem mailboxes are represented in EXO"
        $onPremMbx = @()
        try { $onPremMbx = @(Get-Mailbox -ResultSize Unlimited -ErrorAction Stop | Select-Object UserPrincipalName,PrimarySmtpAddress) }
        catch { Write-Status "On-prem Get-Mailbox failed (tools-only org?): $($_.Exception.Message)" "WARN" }
        if ($onPremMbx.Count -gt 0) {
            $cloudRecipSmtp = @{}
            Get-EXORecipient -ResultSize Unlimited -Properties PrimarySmtpAddress | ForEach-Object {
                $cloudRecipSmtp[([string]$_.PrimarySmtpAddress).ToLower()] = $true
            }
            foreach ($o in $onPremMbx) {
                $smtp = ([string]$o.PrimarySmtpAddress).ToLower()
                if ($smtp -and -not $cloudRecipSmtp.ContainsKey($smtp)) {
                    Add-Finding ([string]$o.UserPrincipalName) 'ONPREM_MBX_NOT_IN_CLOUD' 'ERROR' "No EXO recipient with $smtp" 'HybridGALSplit-B Fix 5 (sync scope / export error)'
                }
            }
        }
    } else {
        Write-Status "On-prem Get-Mailbox not available - skipping on-prem -> cloud check" "WARN"
    }
}

# ---------------- Validate / Report ----------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv = Join-Path $OutputPath "HybridRecipientVisibility_$stamp.csv"
$findings | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Status "Summary"
if ($findings.Count -eq 0) {
    Write-Status "No hybrid recipient visibility defects found" "OK"
} else {
    $findings | Group-Object Code | Sort-Object Count -Descending | ForEach-Object {
        $sev = ($_.Group | Select-Object -First 1).Severity
        Write-Status ("{0,-34} {1}" -f $_.Name, $_.Count) $sev
    }
}
Write-Status "Report: $csv" "OK"
