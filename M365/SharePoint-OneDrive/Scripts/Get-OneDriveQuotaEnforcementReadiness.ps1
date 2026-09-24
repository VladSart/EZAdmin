<#
.SYNOPSIS
    Read-only readiness audit for OneDrive storage quota enforcement (MC1310684 / MC1465765 / PAYG MC1477185).

.DESCRIPTION
    Enumerates every OneDrive (personal site) in the tenant via the SharePoint Online Management Shell
    and flags accounts at risk of being clamped or set read-only by Microsoft's 2026 quota enforcement:

      - Level2Risk             : usage above 5 TB (Level 2 expansion removal, Nov 2026 - Feb 2027)
      - QuotaAbove5TB          : configured quota above 5 TB (legacy increase that will be removed)
      - QuotaAboveEntitlement  : configured quota above the licence entitlement (clamped at refresh)
      - UsageAboveEntitlement  : usage above the licence entitlement (read-only after clamp, or
                                 billable overage once a OneDrive PAYG billing policy is attached)
      - NearQuota              : usage >= 90% of the current configured quota
      - Locked                 : LockState is not 'Unlock'

    Licence entitlement is only calculated with -ResolveLicenses (Microsoft Graph, User.Read.All +
    Organization.Read.All). The SKU -> entitlement map covers common commercial SKUs; unknown SKUs are
    reported as 'Unknown' and are NOT flagged. Extend $EntitlementMap for your tenant.
    The entitlement used is the MAXIMUM an admin may set without paid storage (e.g. 5 TB for E3/E5),
    not the 1 TB default.

    Does NOT change any quota, lock or billing setting. Does NOT read paid add-on or PAYG state (no
    public cmdlet) - check the admin center and treat EntitlementMB as "before paid storage".

.PARAMETER AdminUrl
    SharePoint admin center URL, e.g. https://contoso-admin.sharepoint.com

.PARAMETER ResolveLicenses
    Look up each owner's assigned SKUs via Microsoft Graph and compute EntitlementMB.

.PARAMETER SkipConnect
    Assume Connect-SPOService (and Connect-MgGraph if -ResolveLicenses) have already been run.

.PARAMETER OutputPath
    CSV output path. Default: .\OneDriveQuotaReadiness_<timestamp>.csv

.EXAMPLE
    .\Get-OneDriveQuotaEnforcementReadiness.ps1 -AdminUrl https://contoso-admin.sharepoint.com -ResolveLicenses

.EXAMPLE
    Connect-SPOService -Url https://contoso-admin.sharepoint.com
    .\Get-OneDriveQuotaEnforcementReadiness.ps1 -AdminUrl https://contoso-admin.sharepoint.com -SkipConnect

.NOTES
    Requires : Microsoft.Online.SharePoint.PowerShell (SharePoint Administrator)
               Microsoft.Graph.Users + Microsoft.Graph.Identity.DirectoryManagement (only with -ResolveLicenses)
    Run as   : any user with the above roles; no local admin needed
    Safety   : read-only. Values from Get-SPOSite are MB (binary): 1 TB = 1,048,576 MB.
    Windows PowerShell 5.1 compatible. The SPO module is Windows PowerShell-native; under PowerShell 7
    import it with -UseWindowsPowerShell.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[a-zA-Z0-9-]+-admin\.sharepoint\.(com|us|de|cn)/?$')]
    [string]$AdminUrl,

    [switch]$ResolveLicenses,

    [switch]$SkipConnect,

    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath ("OneDriveQuotaReadiness_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$MB_1TB  = [int64]1048576
$MB_5TB  = [int64]5242880

# Maximum OneDrive quota (MB) an admin may set per SKU WITHOUT paid storage.
# Source: OneDrive service description (Sept 2026). Extend as needed.
$EntitlementMap = @{
    'SPE_E3'                   = $MB_5TB   # Microsoft 365 E3
    'SPE_E5'                   = $MB_5TB   # Microsoft 365 E5
    'ENTERPRISEPACK'           = $MB_5TB   # Office 365 E3
    'ENTERPRISEPREMIUM'        = $MB_5TB   # Office 365 E5
    'SPB'                      = $MB_1TB   # Microsoft 365 Business Premium
    'O365_BUSINESS_PREMIUM'    = $MB_1TB   # Microsoft 365 Business Standard
    'O365_BUSINESS_ESSENTIALS' = $MB_1TB   # Microsoft 365 Business Basic
    'STANDARDPACK'             = $MB_1TB   # Office 365 E1
    'SPE_F1'                   = [int64]2048   # Microsoft 365 F3 (2 GB)
    'DESKLESSPACK'             = [int64]2048   # Office 365 F3 (2 GB)
}

# ---------------- Preflight ----------------
Write-Status "Preflight"
if (-not (Get-Command -Name Get-SPOSite -ErrorAction SilentlyContinue)) {
    try { Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking }
    catch {
        Write-Status "SharePoint Online Management Shell not found. Install-Module Microsoft.Online.SharePoint.PowerShell" "ERROR"
        throw
    }
}
if (-not $SkipConnect) {
    Write-Status "Connecting to $AdminUrl"
    Connect-SPOService -Url $AdminUrl
}

$skuIdToPart = @{}
if ($ResolveLicenses) {
    foreach ($m in 'Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement') {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Status "Module $m missing - Install-Module Microsoft.Graph" "ERROR"
            throw "Missing module $m"
        }
    }
    if (-not $SkipConnect) {
        Connect-MgGraph -Scopes 'User.Read.All', 'Organization.Read.All' -NoWelcome
    }
    foreach ($sku in @(Get-MgSubscribedSku -All)) {
        $skuIdToPart[[string]$sku.SkuId] = [string]$sku.SkuPartNumber
    }
    Write-Status ("Loaded {0} subscribed SKUs" -f $skuIdToPart.Count) "OK"
}

# ---------------- Detect ----------------
Write-Status "Enumerating OneDrive sites (can take several minutes in large tenants)"
$sites = @(Get-SPOSite -IncludePersonalSite $true -Limit All -Filter "Url -like '-my.sharepoint.com/personal/'")
Write-Status ("Found {0} OneDrive sites" -f $sites.Count) "OK"

$licenceCache = @{}
function Get-OwnerEntitlement {
    param([string]$Owner)
    if ([string]::IsNullOrWhiteSpace($Owner)) { return [pscustomobject]@{ Skus = ''; EntitlementMB = $null; Note = 'NoOwner' } }
    if ($licenceCache.ContainsKey($Owner)) { return $licenceCache[$Owner] }
    $result = $null
    try {
        $u = Get-MgUser -UserId $Owner -Property 'id,userPrincipalName,assignedLicenses,accountEnabled'
        $parts = @()
        foreach ($al in @($u.AssignedLicenses)) {
            $id = [string]$al.SkuId
            if ($skuIdToPart.ContainsKey($id)) { $parts += $skuIdToPart[$id] } else { $parts += $id }
        }
        $known = @($parts | Where-Object { $EntitlementMap.ContainsKey($_) })
        $ent = $null
        $note = ''
        if ($known.Count -gt 0) {
            $ent = ($known | ForEach-Object { $EntitlementMap[$_] } | Measure-Object -Maximum).Maximum
        } elseif ($parts.Count -eq 0) {
            $note = 'Unlicensed'
        } else {
            $note = 'UnknownSku'
        }
        if (-not $u.AccountEnabled) { $note = ($note + ' Disabled').Trim() }
        $result = [pscustomobject]@{ Skus = ($parts -join ';'); EntitlementMB = $ent; Note = $note }
    } catch {
        $result = [pscustomobject]@{ Skus = ''; EntitlementMB = $null; Note = 'OwnerNotFound' }
    }
    $licenceCache[$Owner] = $result
    return $result
}

# ---------------- Execute (evaluate) ----------------
$report = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($s in $sites) {
    $i++
    if ($i % 200 -eq 0) { Write-Status ("Processed {0}/{1}" -f $i, $sites.Count) }

    $used  = [int64]$s.StorageUsageCurrent
    $quota = [int64]$s.StorageQuota
    $lock  = [string]$s.LockState

    $skus = ''; $entMB = $null; $note = ''
    if ($ResolveLicenses) {
        $e = Get-OwnerEntitlement -Owner ([string]$s.Owner)
        $skus = $e.Skus; $entMB = $e.EntitlementMB; $note = $e.Note
    }

    $quotaAboveEnt = $false
    $usageAboveEnt = $false
    if ($null -ne $entMB) {
        $quotaAboveEnt = ($quota -gt $entMB)
        $usageAboveEnt = ($used -gt $entMB)
    }
    $pct = 0
    if ($quota -gt 0) { $pct = [math]::Round(($used / $quota) * 100, 1) }

    $report.Add([pscustomobject]@{
        Owner                 = $s.Owner
        Url                   = $s.Url
        UsedMB                = $used
        UsedTB                = [math]::Round($used / $MB_1TB, 3)
        QuotaMB               = $quota
        QuotaTB               = [math]::Round($quota / $MB_1TB, 3)
        PercentUsed           = $pct
        LockState             = $lock
        Skus                  = $skus
        EntitlementMB         = $entMB
        LicenceNote           = $note
        Level2Risk            = ($used -gt $MB_5TB)
        QuotaAbove5TB         = ($quota -gt $MB_5TB)
        QuotaAboveEntitlement = $quotaAboveEnt
        UsageAboveEntitlement = $usageAboveEnt
        NearQuota             = ($pct -ge 90)
        Locked                = ($lock -ne 'Unlock')
    })
}

# ---------------- Validate / Report ----------------
$report | Sort-Object UsedMB -Descending | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$l2     = @($report | Where-Object { $_.Level2Risk })
$q5     = @($report | Where-Object { $_.QuotaAbove5TB })
$qEnt   = @($report | Where-Object { $_.QuotaAboveEntitlement })
$uEnt   = @($report | Where-Object { $_.UsageAboveEntitlement })
$near   = @($report | Where-Object { $_.NearQuota })
$locked = @($report | Where-Object { $_.Locked })

Write-Host ""
Write-Status "===== Summary ====="
Write-Status ("OneDrives scanned              : {0}" -f $report.Count)
if ($l2.Count -gt 0)   { Write-Status ("Usage > 5 TB (Level 2 risk)    : {0}" -f $l2.Count) "ERROR" } else { Write-Status "Usage > 5 TB (Level 2 risk)    : 0" "OK" }
if ($q5.Count -gt 0)   { Write-Status ("Quota > 5 TB (legacy increase) : {0}" -f $q5.Count) "WARN" }  else { Write-Status "Quota > 5 TB (legacy increase) : 0" "OK" }
if ($ResolveLicenses) {
    if ($qEnt.Count -gt 0) { Write-Status ("Quota > entitlement            : {0}" -f $qEnt.Count) "WARN" } else { Write-Status "Quota > entitlement            : 0" "OK" }
    if ($uEnt.Count -gt 0) { Write-Status ("Usage > entitlement            : {0}  (read-only or PAYG-billable)" -f $uEnt.Count) "ERROR" } else { Write-Status "Usage > entitlement            : 0" "OK" }
    $unk = @($report | Where-Object { $_.LicenceNote -match 'UnknownSku|OwnerNotFound' })
    if ($unk.Count -gt 0) { Write-Status ("Entitlement unknown (not flagged): {0} - extend `$EntitlementMap" -f $unk.Count) "WARN" }
} else {
    Write-Status "Entitlement checks skipped (use -ResolveLicenses)" "WARN"
}
if ($near.Count -gt 0)   { Write-Status ("Usage >= 90% of quota          : {0}" -f $near.Count) "WARN" }
if ($locked.Count -gt 0) { Write-Status ("Not 'Unlock' (read-only/noaccess): {0}" -f $locked.Count) "WARN" }
Write-Status ("CSV written: {0}" -f $OutputPath) "OK"
Write-Status "Reminder: paid add-on / PAYG capacity is NOT visible to this script - check the admin center before acting."
