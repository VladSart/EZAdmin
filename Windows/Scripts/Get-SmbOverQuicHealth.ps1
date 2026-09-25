<#
.SYNOPSIS
    Read-only health check of an SMB over QUIC file server (certificate mappings, listener, firewall, KDC Proxy, client access control).

.DESCRIPTION
    Companion to Windows/Troubleshooting/SMBoverQUIC-A.md / -B.md.
    Run on the SMB over QUIC file server (Windows Server 2025 any edition, or Windows Server 2022
    Datacenter: Azure Edition). Checks, without changing anything:
      - OS build / edition supports SMB over QUIC
      - EnableSMBQUIC and AuditClientCertificateAccess server settings
      - Every SMB server certificate mapping: certificate present in LocalMachine\My, private key,
        Server Authentication EKU, expiry (warns inside -ExpiryWarningDays), mapping Name present in SAN
      - Certificates in LocalMachine\My that look like REPLACEMENTS for a mapped cert (same SAN,
        later expiry, different thumbprint) - the classic "renewed but never remapped" outage
      - UDP listener on 443 (and alternative QUIC ports) and which process owns UDP 443
      - Enabled inbound Windows Firewall rule allowing UDP 443 (or the alternative port)
      - KDC Proxy (kpssvc) state and HTTP.sys urlacl/sslcert presence (Kerberos over HTTPS)
      - Client access control: RequireClientAuthentication / SkipClientCertificateAccessCheck and ACL entry count
    Does NOT: test from an external client (UDP cannot be probed reliably from here - use
    New-SmbMapping -TransportType QUIC off-network), validate edge NAT/public DNS, change any setting.

.PARAMETER ExpiryWarningDays
    Warn when a mapped certificate expires within this many days. Default 30.

.PARAMETER OutputPath
    Folder for the CSV report. Default C:\Temp.

.EXAMPLE
    .\Get-SmbOverQuicHealth.ps1

.EXAMPLE
    .\Get-SmbOverQuicHealth.ps1 -ExpiryWarningDays 45 -OutputPath D:\Reports

.NOTES
    Requires: Windows PowerShell 5.1, SmbShare module, local administrator on the file server.
    Safe: read-only. Suitable for a scheduled task (non-zero exit code when any ERROR is found).
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1,365)][int]$ExpiryWarningDays = 30,
    [string]$OutputPath = 'C:\Temp'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param([string]$Message, [string]$Status = 'INFO')
    $colour = switch ($Status) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Cyan'} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Item, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Detail = $Detail })
    Write-Status -Message "$Area | $Item | $Detail" -Status $Status
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

# ---------------- Preflight ----------------
Write-Status "SMB over QUIC health check on $env:COMPUTERNAME"
if (-not (Get-Command Get-SmbServerCertificateMapping -ErrorAction SilentlyContinue)) {
    Add-Result 'Preflight' 'SmbShare cmdlets' 'ERROR' 'Get-SmbServerCertificateMapping not available - OS does not support SMB over QUIC'
    $results | Format-Table -AutoSize
    exit 2
}
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$caption = $os.Caption
if ($build -ge 26100) {
    Add-Result 'Preflight' 'OS' 'OK' "$caption (build $build) - SMB over QUIC supported on all editions"
} elseif ($build -eq 20348 -and $caption -match 'Azure Edition') {
    Add-Result 'Preflight' 'OS' 'OK' "$caption (build $build)"
} elseif ($os.ProductType -eq 1) {
    Add-Result 'Preflight' 'OS' 'WARN' "$caption is a client OS - this script targets the file server"
} else {
    Add-Result 'Preflight' 'OS' 'ERROR' "$caption (build $build) - server-side SMB over QUIC needs WS2025 or WS2022 Datacenter: Azure Edition"
}

# ---------------- Detect: server configuration ----------------
$srvCfg = Get-SmbServerConfiguration
$quicOn = Get-Prop $srvCfg 'EnableSMBQUIC'
if ($quicOn -eq $true) { Add-Result 'Server' 'EnableSMBQUIC' 'OK' 'True' }
elseif ($null -eq $quicOn) { Add-Result 'Server' 'EnableSMBQUIC' 'WARN' 'Property not exposed on this build' }
else { Add-Result 'Server' 'EnableSMBQUIC' 'ERROR' 'False - Set-SmbServerConfiguration -EnableSMBQUIC $true' }

$audit = Get-Prop $srvCfg 'AuditClientCertificateAccess'
if ($null -ne $audit) {
    Add-Result 'Server' 'AuditClientCertificateAccess' 'INFO' "$audit (SMBServer/Audit 3007-3009 only logged when True)"
}

# ---------------- Detect: certificate mappings ----------------
$mappings = @(Get-SmbServerCertificateMapping -ErrorAction SilentlyContinue)
$myCerts  = @(Get-ChildItem Cert:\LocalMachine\My)
$now = Get-Date
$serverAuthOid = '1.3.6.1.5.5.7.3.1'
$anyRequireClientAuth = $false

if ($mappings.Count -eq 0) {
    Add-Result 'CertMapping' '(none)' 'ERROR' 'No SMB server certificate mappings - QUIC has no certificate to present'
}
foreach ($m in $mappings) {
    $name  = [string](Get-Prop $m 'Name')
    $thumb = [string](Get-Prop $m 'Thumbprint')
    $store = [string](Get-Prop $m 'StoreName')
    $req   = Get-Prop $m 'RequireClientAuthentication'
    $skip  = Get-Prop $m 'SkipClientCertificateAccessCheck'
    if ($req -eq $true) { $anyRequireClientAuth = $true }

    if ($name -match '^\d{1,3}(\.\d{1,3}){3}$' -or $name -match ':') {
        Add-Result 'CertMapping' $name 'WARN' 'Mapping name is an IP address - forces NTLM, unsupported through NAT; use an FQDN'
    }
    if ($store -and $store -ne 'My') {
        Add-Result 'CertMapping' $name 'WARN' "StoreName is '$store' - this script only inspects LocalMachine\My"
    }

    $cert = $myCerts | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
    if (-not $cert) {
        Add-Result 'CertMapping' $name 'ERROR' "Mapped thumbprint $thumb NOT FOUND in LocalMachine\My (cert removed/renewed?)"
    } else {
        $sans = @()
        if ($cert.DnsNameList) { $sans = @($cert.DnsNameList | ForEach-Object { $_.Unicode }) }
        $daysLeft = [int][math]::Floor(($cert.NotAfter - $now).TotalDays)
        if ($cert.NotAfter -lt $now) {
            Add-Result 'CertMapping' $name 'ERROR' "Certificate $thumb EXPIRED $($cert.NotAfter.ToString('yyyy-MM-dd'))"
        } elseif ($daysLeft -le $ExpiryWarningDays) {
            Add-Result 'CertMapping' $name 'WARN' "Certificate $thumb expires in $daysLeft days ($($cert.NotAfter.ToString('yyyy-MM-dd'))) - renewal needs a REMAP"
        } else {
            Add-Result 'CertMapping' $name 'OK' "Certificate $thumb valid until $($cert.NotAfter.ToString('yyyy-MM-dd')) ($daysLeft days)"
        }
        if (-not $cert.HasPrivateKey) { Add-Result 'CertMapping' $name 'ERROR' 'Certificate has no private key' }
        $ekuOids = @()
        if ($cert.EnhancedKeyUsageList) { $ekuOids = @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) }
        if ($ekuOids.Count -gt 0 -and ($ekuOids -notcontains $serverAuthOid)) {
            Add-Result 'CertMapping' $name 'ERROR' 'Certificate lacks Server Authentication EKU (1.3.6.1.5.5.7.3.1)'
        }
        $sanMatch = $false
        foreach ($san in $sans) {
            if ($san -ieq $name) { $sanMatch = $true; break }
            if ($san.StartsWith('*.') -and $name -ilike $san) { $sanMatch = $true; break }
        }
        if ($sanMatch) { Add-Result 'CertMapping' $name 'OK' "Name present in SAN ($($sans -join ', '))" }
        else { Add-Result 'CertMapping' $name 'ERROR' "Name NOT in certificate SAN ($($sans -join ', ')) - TLS will fail for clients using '$name'" }

        # Look for a newer replacement certificate that is not mapped
        $replacement = $myCerts | Where-Object {
            $_.Thumbprint -ne $thumb -and $_.HasPrivateKey -and $_.NotAfter -gt $cert.NotAfter -and $_.NotAfter -gt $now -and
            $_.DnsNameList -and (@($_.DnsNameList | ForEach-Object { $_.Unicode }) -icontains $name)
        } | Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($replacement) {
            Add-Result 'CertMapping' $name 'WARN' "Newer cert $($replacement.Thumbprint) (exp $($replacement.NotAfter.ToString('yyyy-MM-dd'))) has this SAN but is NOT mapped - likely renewal; Set-SmbServerCertificateMapping -Name $name -Thumbprint $($replacement.Thumbprint) -StoreName My"
        }
    }

    $caDetail = "RequireClientAuthentication=$req; SkipClientCertificateAccessCheck=$skip"
    if ($req -eq $true -and $skip -eq $true) { $caDetail += ' (chain validated, ACL NOT enforced)' }
    Add-Result 'ClientAccess' $name 'INFO' $caDetail
}

# ---------------- Detect: listener & alternative ports ----------------
$ports = New-Object System.Collections.Generic.List[int]
$ports.Add(443)
if (Get-Command Get-SmbServerAlternativePort -ErrorAction SilentlyContinue) {
    $alts = @(Get-SmbServerAlternativePort -ErrorAction SilentlyContinue)
    foreach ($a in $alts) {
        $t = [string](Get-Prop $a 'TransportType'); $p = Get-Prop $a 'Port'
        if ($null -ne $p) {
            Add-Result 'Listener' "AltPort $p" 'INFO' "Alternative SMB server port configured (Transport=$t)"
            if ($t -match 'QUIC') { $ports.Add([int]$p) }
        }
    }
}
foreach ($port in ($ports | Select-Object -Unique)) {
    $eps = @(Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue)
    if ($eps.Count -eq 0) {
        $sev = 'WARN'; if ($port -eq 443 -and $quicOn -eq $true -and $mappings.Count -gt 0) { $sev = 'ERROR' }
        Add-Result 'Listener' "UDP $port" $sev 'No UDP endpoint bound'
    } else {
        $owners = @($eps | Select-Object -ExpandProperty OwningProcess -Unique)
        $names = foreach ($o in $owners) {
            if ($o -eq 4) { 'System(4)' } else {
                $pr = Get-Process -Id $o -ErrorAction SilentlyContinue
                if ($pr) { "$($pr.ProcessName)($o)" } else { "PID $o" }
            }
        }
        $sev = 'OK'; if (@($owners | Where-Object { $_ -ne 4 }).Count -gt 0) { $sev = 'WARN' }
        $d = "Bound by $($names -join ', ')"; if ($sev -eq 'WARN') { $d += ' - non-System owner may be a port conflict (HTTP/3 app?)' }
        Add-Result 'Listener' "UDP $port" $sev $d
    }

    # Firewall
    $fwHit = $false
    $filters = @(Get-NetFirewallPortFilter -Protocol UDP -ErrorAction SilentlyContinue | Where-Object {
        @($_.LocalPort) -contains [string]$port -or @($_.LocalPort) -contains 'Any' })
    foreach ($f in $filters) {
        $rule = $f | Get-NetFirewallRule -ErrorAction SilentlyContinue
        if ($rule -and $rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and $rule.Action -eq 'Allow') {
            $fwHit = $true
            Add-Result 'Firewall' "UDP $port" 'OK' "Allowed by '$($rule.DisplayName)' (Profile=$($rule.Profile))"
            break
        }
    }
    if (-not $fwHit) { Add-Result 'Firewall' "UDP $port" 'WARN' 'No enabled inbound Allow rule found for this UDP port (check GPO-managed store / edge firewall)' }
}

# ---------------- Detect: KDC Proxy ----------------
$kps = Get-Service -Name kpssvc -ErrorAction SilentlyContinue
if (-not $kps) {
    Add-Result 'KdcProxy' 'kpssvc' 'WARN' 'KDC Proxy service not present - clients off-network will authenticate with NTLM'
} else {
    $sev = 'OK'; if ($kps.Status -ne 'Running') { $sev = 'WARN' }
    Add-Result 'KdcProxy' 'kpssvc' $sev "Status=$($kps.Status) StartType=$($kps.StartType)"
    $urlacl = (& netsh http show urlacl) -join "`n"
    if ($urlacl -match '(?i)/KdcProxy') { Add-Result 'KdcProxy' 'urlacl' 'OK' 'KdcProxy URL reservation present' }
    else { Add-Result 'KdcProxy' 'urlacl' 'WARN' 'No /KdcProxy URL reservation in HTTP.sys' }
    $ssl = (& netsh http show sslcert) -join "`n"
    if ($ssl -match ':443') { Add-Result 'KdcProxy' 'sslcert' 'INFO' 'An HTTP.sys SSL binding exists on port 443 (verify it uses a current cert)' }
    else { Add-Result 'KdcProxy' 'sslcert' 'WARN' 'No HTTP.sys SSL binding on 443 - KDC Proxy cannot serve HTTPS' }
    $kpsReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\KPSSVC\Settings' -ErrorAction SilentlyContinue
    if ($kpsReg) {
        Add-Result 'KdcProxy' 'Settings' 'INFO' ("HttpsClientAuth={0}; DisallowUnprotectedPasswordAuth={1}" -f (Get-Prop $kpsReg 'HttpsClientAuth'), (Get-Prop $kpsReg 'DisallowUnprotectedPasswordAuth'))
    }
}

# ---------------- Detect: client access control ACL ----------------
if (Get-Command Get-SmbClientAccessToServer -ErrorAction SilentlyContinue) {
    $acl = @(Get-SmbClientAccessToServer -ErrorAction SilentlyContinue)
    if ($anyRequireClientAuth -and $acl.Count -eq 0) {
        Add-Result 'ClientAccess' 'ACL' 'ERROR' 'RequireClientAuthentication is on but the access list is EMPTY - every client will be denied'
    } else {
        Add-Result 'ClientAccess' 'ACL' 'INFO' "$($acl.Count) access control entr(y/ies)"
    }
}

# ---------------- Report ----------------
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$csv = Join-Path $OutputPath ("SmbOverQuicHealth_{0}_{1}.csv" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$err  = @($results | Where-Object Status -eq 'ERROR').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ''
Write-Status "Summary: $err error(s), $warn warning(s). Report: $csv" -Status $(if ($err) {'ERROR'} elseif ($warn) {'WARN'} else {'OK'})
Write-Status 'Next: test from an EXTERNAL Windows 11 client with New-SmbMapping -RemotePath \\<fqdn>\<share> -TransportType QUIC'
if ($err -gt 0) { exit 1 } else { exit 0 }
