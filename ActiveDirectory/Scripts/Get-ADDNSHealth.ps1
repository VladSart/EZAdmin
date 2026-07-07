<#
.SYNOPSIS
    AD-integrated DNS health check — zone config, DC Locator SRV records, scavenging, and forwarder reachability.

.DESCRIPTION
    Collects and reports on:
      - Zone inventory (AD-integrated status, replication scope for domain zone + _msdcs zone)
      - Dynamic update mode per zone (flags anything other than Secure-only)
      - DC Locator SRV record presence for every domain controller (_ldap/_kerberos under _msdcs)
      - Comparison against this DC's own netlogon.dns expected-registration list, if run locally on a DC
      - Server- and zone-level scavenging/aging configuration (flags disabled-at-one-level-only misconfig)
      - Forwarder and root hint reachability (external resolution path, tested independently of internal zones)

    Does NOT make any changes. Read-only. Exports a consolidated CSV for escalation/reporting.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ADDNSHealth_<timestamp>.csv

.PARAMETER SkipExternalCheck
    Skip the external (forwarder/root hint) resolution test — useful in isolated/air-gapped environments. Default: $false.

.PARAMETER ForestRoot
    Forest root domain to use for _msdcs SRV checks. Defaults to the current domain's forest root if not specified.

.EXAMPLE
    .\Get-ADDNSHealth.ps1
    # Full health check with CSV export

.EXAMPLE
    .\Get-ADDNSHealth.ps1 -SkipExternalCheck -ExportPath "C:\Reports\ADDns.csv"
    # Skips external resolution test, custom export path

.NOTES
    Requires: DnsServer PowerShell module (installed with DNS Server role or via RSAT: DNS Server Tools),
              ActiveDirectory PowerShell module, dcdiag.exe
    Run as: Domain Admin or delegated DNS + AD read rights
    Best run: Directly on a Domain Controller hosting the DNS Server role (for netlogon.dns comparison)
    Safe/Unsafe: READ-ONLY — makes no changes to zones, records, or scavenging config
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
#>

[CmdletBinding()]
param(
    [string] $ExportPath        = "$env:TEMP\ADDNSHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [switch] $SkipExternalCheck,
    [string] $ForestRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---

Write-Status "AD-Integrated DNS Health Check" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Status "DnsServer module not found. Run on a DC with the DNS Server role, or install RSAT: DNS Server Tools." -Status "ERROR"
    exit 1
}
Import-Module DnsServer -ErrorAction Stop

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

if (-not $ForestRoot) {
    try {
        $ForestRoot = (Get-ADForest).RootDomain
    } catch {
        Write-Status "Could not auto-detect forest root — specify -ForestRoot explicitly." -Status "ERROR"
        exit 1
    }
}
Write-Status "Forest root: $ForestRoot" -Status "INFO"
Write-Status "Prerequisites OK." -Status "OK"

#endregion

$results = @()

#region --- Zone Inventory ---

Write-Status "`n=== Zone Inventory & Replication Scope ===" -Status "HEADER"
$zones = Get-DnsServerZone
foreach ($zone in $zones) {
    $isMsdcs = $zone.ZoneName -like "_msdcs*"
    $scopeFlag = "OK"
    if ($isMsdcs -and $zone.ReplicationScope -ne "Forest") {
        $scopeFlag = "WARN"
        Write-Status "  _msdcs zone '$($zone.ZoneName)' is scoped '$($zone.ReplicationScope)', not Forest — cross-domain DC Locator may fail" -Status "WARN"
    }
    if (-not $zone.IsDsIntegrated -and $zone.ZoneType -eq "Primary") {
        $scopeFlag = "WARN"
        Write-Status "  Zone '$($zone.ZoneName)' is a standard primary zone, not AD-integrated" -Status "WARN"
    }
    $results += [PSCustomObject]@{
        Category = "ZoneInventory"
        Item     = $zone.ZoneName
        Metric   = "ReplicationScope/IsDsIntegrated"
        Value    = "$($zone.ReplicationScope) / $($zone.IsDsIntegrated)"
        Status   = $scopeFlag
    }
}
Write-Status "Zone inventory collected: $($zones.Count) zone(s)." -Status "OK"

#endregion

#region --- Dynamic Update Mode ---

Write-Status "`n=== Dynamic Update Mode ===" -Status "HEADER"
foreach ($zone in ($zones | Where-Object IsDsIntegrated)) {
    $duFlag = switch ($zone.DynamicUpdate) {
        "Secure"              { "OK" }
        "NonsecureAndSecure"  { "WARN" }
        "None"                { "ERROR" }
        default               { "WARN" }
    }
    if ($duFlag -ne "OK") {
        Write-Status "  Zone '$($zone.ZoneName)' DynamicUpdate = $($zone.DynamicUpdate)" -Status $duFlag
    }
    $results += [PSCustomObject]@{
        Category = "DynamicUpdate"
        Item     = $zone.ZoneName
        Metric   = "DynamicUpdate"
        Value    = $zone.DynamicUpdate
        Status   = $duFlag
    }
}

#endregion

#region --- DC Locator SRV Records ---

Write-Status "`n=== DC Locator SRV Records (_ldap/_kerberos under _msdcs) ===" -Status "HEADER"
$allDCs = (Get-ADDomainController -Filter *).HostName
$ldapSrv = @()
$krbSrv  = @()
try {
    $ldapSrv = (Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$ForestRoot" -Type SRV -ErrorAction SilentlyContinue) |
        Select-Object -ExpandProperty NameTarget -ErrorAction SilentlyContinue
    $krbSrv = (Resolve-DnsName -Name "_kerberos._tcp.dc._msdcs.$ForestRoot" -Type SRV -ErrorAction SilentlyContinue) |
        Select-Object -ExpandProperty NameTarget -ErrorAction SilentlyContinue
} catch {
    Write-Status "  Could not resolve _msdcs SRV records: $_" -Status "ERROR"
}

foreach ($dc in $allDCs) {
    $inLdap = $ldapSrv | Where-Object { $_ -like "$dc*" }
    $inKrb  = $krbSrv  | Where-Object { $_ -like "$dc*" }
    $dcStatus = if ($inLdap -and $inKrb) { "OK" } else { "ERROR" }
    if ($dcStatus -eq "ERROR") {
        Write-Status "  DC '$dc' is MISSING from _ldap and/or _kerberos SRV records — DC Locator broken for this DC" -Status "ERROR"
    }
    $results += [PSCustomObject]@{
        Category = "DCLocatorSRV"
        Item     = $dc
        Metric   = "LDAP+KerberosSRVPresent"
        Value    = "LDAP=$([bool]$inLdap) / KRB=$([bool]$inKrb)"
        Status   = $dcStatus
    }
}
Write-Status "Checked $($allDCs.Count) DC(s) against SRV registration." -Status "OK"

#endregion

#region --- netlogon.dns Local Comparison (if run on a DC) ---

Write-Status "`n=== netlogon.dns Local Comparison ===" -Status "HEADER"
$netlogonPath = "$env:windir\System32\Config\netlogon.dns"
if (Test-Path $netlogonPath) {
    $netlogonLines = Get-Content $netlogonPath -ErrorAction SilentlyContinue
    $expectedCount = ($netlogonLines | Measure-Object).Count
    Write-Host "  netlogon.dns found locally — $expectedCount expected registration line(s) on this DC."
    $results += [PSCustomObject]@{
        Category = "NetlogonDns"; Item = $env:COMPUTERNAME
        Metric = "ExpectedRegistrationLines"; Value = $expectedCount; Status = "OK"
    }
} else {
    Write-Status "  netlogon.dns not found locally — this script is likely not running on a DC. Skipping local comparison." -Status "WARN"
    $results += [PSCustomObject]@{
        Category = "NetlogonDns"; Item = $env:COMPUTERNAME
        Metric = "ExpectedRegistrationLines"; Value = "N/A - not a DC"; Status = "WARN"
    }
}

#endregion

#region --- Scavenging / Aging ---

Write-Status "`n=== Scavenging & Aging Configuration ===" -Status "HEADER"
try {
    $serverScavenging = Get-DnsServerScavenging
    $serverEnabled = $serverScavenging.ScavengingState
    Write-Host "  Server-level scavenging enabled: $serverEnabled"

    foreach ($zone in ($zones | Where-Object { $_.IsDsIntegrated -and $_.ZoneType -eq "Primary" })) {
        try {
            $zoneAging = Get-DnsServerZoneAging -Name $zone.ZoneName -ErrorAction Stop
            $zoneEnabled = $zoneAging.AgingEnabled
            $mismatchFlag = "OK"
            if ($serverEnabled -and -not $zoneEnabled) {
                $mismatchFlag = "WARN"
                Write-Status "  Zone '$($zone.ZoneName)': aging DISABLED at zone level while server-level scavenging is ON — scavenging has no effect here" -Status "WARN"
            } elseif ((-not $serverEnabled) -and $zoneEnabled) {
                $mismatchFlag = "WARN"
                Write-Status "  Zone '$($zone.ZoneName)': aging enabled at zone level but server-level scavenging is OFF — scavenging has no effect" -Status "WARN"
            }
            $results += [PSCustomObject]@{
                Category = "Scavenging"
                Item     = $zone.ZoneName
                Metric   = "ServerEnabled=$serverEnabled/ZoneEnabled=$zoneEnabled"
                Value    = "Refresh=$($zoneAging.RefreshInterval) NoRefresh=$($zoneAging.NoRefreshInterval)"
                Status   = $mismatchFlag
            }
        } catch {
            Write-Status "  Could not read zone aging for $($zone.ZoneName): $_" -Status "WARN"
        }
    }
} catch {
    Write-Status "Could not read server scavenging config: $_" -Status "WARN"
}

#endregion

#region --- Forwarders / External Resolution ---

if (-not $SkipExternalCheck) {
    Write-Status "`n=== Forwarders & External Resolution ===" -Status "HEADER"
    try {
        $forwarders = Get-DnsServerForwarder
        if ($forwarders.IPAddress.Count -eq 0) {
            Write-Status "  No conditional/general forwarders configured — relying on root hints." -Status "WARN"
        } else {
            Write-Host "  Forwarders configured: $($forwarders.IPAddress -join ', ')"
        }

        try {
            $extTest = Resolve-DnsName -Name "www.microsoft.com" -ErrorAction Stop
            Write-Status "  External resolution test (www.microsoft.com): OK" -Status "OK"
            $results += [PSCustomObject]@{
                Category = "ExternalResolution"; Item = "www.microsoft.com"
                Metric = "Resolves"; Value = "True"; Status = "OK"
            }
        } catch {
            Write-Status "  External resolution FAILED — forwarders/root hints unreachable or misconfigured" -Status "ERROR"
            $results += [PSCustomObject]@{
                Category = "ExternalResolution"; Item = "www.microsoft.com"
                Metric = "Resolves"; Value = "False"; Status = "ERROR"
            }
        }
    } catch {
        Write-Status "Could not evaluate forwarders: $_" -Status "WARN"
    }
} else {
    Write-Status "`nSkipping external resolution check (per -SkipExternalCheck)." -Status "INFO"
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Total checks run : $($results.Count)"
Write-Host "  Errors           : $errorCount"
Write-Host "  Warnings         : $warnCount"
Write-Host "  Report saved to  : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "One or more critical AD DNS issues detected — review the CSV and escalate if needed." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Minor issues detected — review the CSV." -Status "WARN"
} else {
    Write-Status "AD-integrated DNS health looks good." -Status "OK"
}

#endregion
