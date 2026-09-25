<#
.SYNOPSIS
    Diagnoses "user missing from / wrongly visible in the address book" issues across Exchange Online and the local classic Outlook OAB cache.

.DESCRIPTION
    Two independent check sets, each can be skipped:

    Tenant checks (requires an existing Connect-ExchangeOnline session):
      - Per recipient: exists, RecipientTypeDetails, hidden flag, dir-sync / cloud-managed state,
        AddressListMembership (is it in the Default GAL?), LegacyExchangeDN, X500 proxy count.
      - Per viewer (optional): AddressBookPolicy / OfflineAddressBook assignment and whether the
        recipient appears to be in that ABP's GAL (membership path match).
      - Tenant: OAB list with IsDefault, AddressLists and LastTouchedTime.

    Client checks (run on the viewer's PC as the viewer - no admin needed):
      - Local OAB folder presence, newest file time, total size, age in hours.
      - Outlook Cached Mode policy value DownloadOAB (0 = download disabled by policy).

    Read-only. Makes no changes to the tenant or the client.
    Does NOT: force OAB generation (not possible in EXO), inspect autocomplete streams, or evaluate
    Information Barriers segments.

.PARAMETER Recipient
    One or more recipient identities (SMTP preferred) to check in the tenant.

.PARAMETER Viewer
    Optional SMTP of the user who cannot see the recipient. Used for ABP scoping checks.

.PARAMETER ClientOnly
    Skip tenant checks; only inspect the local Outlook OAB cache.

.PARAMETER SkipClient
    Skip local client checks (e.g. when running from an admin workstation).

.PARAMETER OutputPath
    Folder for the CSV report. Defaults to $env:TEMP.

.EXAMPLE
    Connect-ExchangeOnline
    .\Get-AddressBookDiagnostics.ps1 -Recipient newstarter@contoso.com -Viewer jane@contoso.com -SkipClient

.EXAMPLE
    # On the affected user's PC, as that user
    .\Get-AddressBookDiagnostics.ps1 -ClientOnly

.NOTES
    Requires ExchangeOnlineManagement v3+ for tenant checks (Get-EXOMailbox).
    Run-as: tenant checks - Exchange Administrator or View-Only Recipients; client checks - the Outlook user.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [string[]]$Recipient = @(),
    [string]$Viewer,
    [switch]$ClientOnly,
    [switch]$SkipClient,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Scope, [string]$Target, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Scope=$Scope; Target=$Target; Check=$Check; Status=$Status; Detail=$Detail })
    Write-Status "$Scope | $Target | $Check : $Detail" $Status
}

# ---------------- Preflight ----------------
$doTenant = -not $ClientOnly
$doClient = -not $SkipClient
if ($doTenant) {
    if (-not (Get-Command Get-Recipient -ErrorAction SilentlyContinue)) {
        Write-Status "Get-Recipient not found - no Exchange Online session. Run Connect-ExchangeOnline or use -ClientOnly." "ERROR"
        $doTenant = $false
    } elseif ($Recipient.Count -eq 0) {
        Write-Status "No -Recipient supplied; tenant OAB summary only." "WARN"
    }
}

# ---------------- Tenant: OABs ----------------
if ($doTenant) {
    try {
        foreach ($o in @(Get-OfflineAddressBook)) {
            $lists = (@(Get-Prop $o 'AddressLists') | ForEach-Object { "$_" }) -join '; '
            $touched = Get-Prop $o 'LastTouchedTime'
            $st = "OK"; $age = ""
            if ($touched) {
                $hrs = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$touched).ToUniversalTime()).TotalHours,1)
                $age = " ageHours=$hrs"
                if ($hrs -gt 48) { $st = "WARN" }
            }
            Add-Result "Tenant" "$($o.Name)" "OAB" $st "IsDefault=$(Get-Prop $o 'IsDefault') Lists=[$lists] LastTouched=$touched$age"
        }
    } catch { Add-Result "Tenant" "OAB" "Get-OfflineAddressBook" "ERROR" $_.Exception.Message }

    # ---------------- Viewer scoping ----------------
    $viewerGalPath = $null
    if ($Viewer) {
        try {
            $vm = Get-EXOMailbox -Identity $Viewer -Properties AddressBookPolicy,OfflineAddressBook
            $abp = Get-Prop $vm 'AddressBookPolicy'
            if ($abp) {
                $p = Get-AddressBookPolicy -Identity "$abp"
                $viewerGalPath = "$(Get-Prop $p 'GlobalAddressList')"
                Add-Result "Viewer" $Viewer "AddressBookPolicy" "WARN" "Scoped by ABP '$abp' GAL=$viewerGalPath OAB=$(Get-Prop $p 'OfflineAddressBook')"
            } else {
                Add-Result "Viewer" $Viewer "AddressBookPolicy" "OK" "No ABP (sees tenant Default GAL)"
            }
            $voab = Get-Prop $vm 'OfflineAddressBook'
            if ($voab) { Add-Result "Viewer" $Viewer "OfflineAddressBook" "INFO" "Explicit OAB assignment: $voab" }
        } catch { Add-Result "Viewer" $Viewer "Lookup" "ERROR" $_.Exception.Message }
    }

    # ---------------- Recipients ----------------
    foreach ($r in $Recipient) {
        try {
            $rec = Get-Recipient -Identity $r -ErrorAction Stop
        } catch {
            Add-Result "Recipient" $r "Exists" "ERROR" "Not found in EXO - provisioning/sync issue, not an address book issue"
            continue
        }
        Add-Result "Recipient" $r "Type" "INFO" "$(Get-Prop $rec 'RecipientTypeDetails') DisplayName='$(Get-Prop $rec 'DisplayName')' WhenChangedUTC=$(Get-Prop $rec 'WhenChangedUTC')"

        $hidden = [bool](Get-Prop $rec 'HiddenFromAddressListsEnabled')
        $synced = [bool](Get-Prop $rec 'IsDirSynced')
        $cloudManaged = $null
        if ($synced -and "$(Get-Prop $rec 'RecipientTypeDetails')" -like "*Mailbox") {
            try { $cloudManaged = Get-Prop (Get-EXOMailbox -Identity $r -Properties IsExchangeCloudManaged) 'IsExchangeCloudManaged' } catch { $cloudManaged = $null }
        }
        $soa = if (-not $synced) { "EXO (cloud-only)" } elseif ($cloudManaged -eq $true) { "EXO (cloud-managed)" } else { "On-prem AD (msExchHideFromAddressLists)" }
        Add-Result "Recipient" $r "HiddenFromAddressLists" ($(if ($hidden) {"WARN"} else {"OK"})) "Hidden=$hidden; set it in: $soa"

        $membership = @(Get-Prop $rec 'AddressListMembership') | ForEach-Object { "$_" }
        $inGal = @($membership | Where-Object { $_ -match 'Default Global Address List' }).Count -gt 0
        if ($hidden) {
            Add-Result "Recipient" $r "AddressListMembership" "INFO" "Hidden - membership irrelevant ($($membership.Count) lists)"
        } elseif ($membership.Count -eq 0) {
            Add-Result "Recipient" $r "AddressListMembership" "ERROR" "Empty - object needs a touch to recalculate (B runbook Fix 3)"
        } else {
            Add-Result "Recipient" $r "AddressListMembership" ($(if ($inGal) {"OK"} else {"WARN"})) "InDefaultGAL=$inGal Lists=[$($membership -join '; ')]"
        }

        if ($viewerGalPath) {
            $galName = ($viewerGalPath -split '\\')[-1]
            $inViewerGal = @($membership | Where-Object { $_ -like "*$galName" }).Count -gt 0
            Add-Result "Recipient" $r "InViewerABPGal" ($(if ($inViewerGal) {"OK"} else {"WARN"})) "Viewer GAL '$galName' contains recipient: $inViewerGal"
        }

        $x500 = @(@(Get-Prop $rec 'EmailAddresses') | ForEach-Object { "$_" } | Where-Object { $_ -like 'X500:*' })
        Add-Result "Recipient" $r "LegacyExchangeDN/X500" "INFO" "LegacyExchangeDN=$(Get-Prop $rec 'LegacyExchangeDN') X500Count=$($x500.Count)"
    }
}

# ---------------- Client ----------------
if ($doClient) {
    $oabRoot = Join-Path $env:LOCALAPPDATA "Microsoft\Outlook\Offline Address Books"
    if (-not (Test-Path $oabRoot)) {
        Add-Result "Client" $env:COMPUTERNAME "OABFolder" "WARN" "No OAB folder - Outlook in Online Mode, never downloaded, or new Outlook/OWA in use (uses live GAL)"
    } else {
        $files = @(Get-ChildItem $oabRoot -Recurse -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            Add-Result "Client" $env:COMPUTERNAME "OABFolder" "WARN" "Folder exists but empty - download never completed"
        } else {
            $newest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            $ageH = [math]::Round(((Get-Date) - $newest).TotalHours, 1)
            $sizeMB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
            $st = if ($ageH -gt 48) { "WARN" } else { "OK" }
            Add-Result "Client" $env:COMPUTERNAME "OABFreshness" $st "Newest=$newest AgeHours=$ageH Files=$($files.Count) SizeMB=$sizeMB Subfolders=$(@(Get-ChildItem $oabRoot -Directory).Count)"
        }
    }
    $polKey = "HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode"
    $dl = $null
    if (Test-Path $polKey) { $dl = Get-Prop (Get-ItemProperty $polKey) 'DownloadOAB' }
    if ($null -ne $dl -and [int]$dl -eq 0) {
        Add-Result "Client" $env:COMPUTERNAME "DownloadOABPolicy" "WARN" "DownloadOAB=0 - OAB download disabled by policy"
    } else {
        Add-Result "Client" $env:COMPUTERNAME "DownloadOABPolicy" "OK" "Not disabled by policy (value: $(if ($null -eq $dl) {'not set'} else {$dl}))"
    }
    $outlook = @(Get-Process -Name OUTLOOK, olk -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    Add-Result "Client" $env:COMPUTERNAME "RunningClient" "INFO" "Running: $(if ($outlook.Count) {$outlook -join ','} else {'none'}) (olk = new Outlook - uses live GAL, no OAB)"
}

# ---------------- Report ----------------
if (-not (Test-Path $OutputPath)) { New-Item $OutputPath -ItemType Directory -Force | Out-Null }
$csv = Join-Path $OutputPath ("AddressBookDiagnostics_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format yyyyMMdd_HHmmss))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$warn = @($results | Where-Object { $_.Status -in 'WARN','ERROR' }).Count
Write-Status "Done. $($results.Count) checks, $warn warnings/errors. Report: $csv" ($(if ($warn) {"WARN"} else {"OK"}))
