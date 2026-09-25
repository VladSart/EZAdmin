<#
.SYNOPSIS
    Read-only health check of file-server aliases (DNS CNAME / netdom alternate names): DNS, SPN ownership, AD alt-name attributes, Kerberos ticket and server-side SMB name settings.

.DESCRIPTION
    For one file server and one or more alias names, reports every layer that has to line up for
    \\alias\share to work with Kerberos:

      - DNS: record type (A vs CNAME), CNAME target, resolved IPs, and whether the IPs match the real server.
      - SPN ownership: which AD objects own HOST/<alias-fqdn>, HOST/<alias-short>, cifs/<alias-fqdn>
        (none / correct server / wrong object / duplicate). Uses ADSI - no RSAT module required.
      - AD alternate-name attributes: msDS-AdditionalDnsHostName on the real server's computer object,
        plus any OTHER computer object still holding the alias (stale, post-migration).
      - Kerberos: optional 'klist get cifs/<alias-fqdn>' from the machine running the script.
      - Server settings (optional, via WinRM): DisableStrictNameChecking, OptionalNames,
        SmbServerNameHardeningLevel, SrvAllowedServerNames, BackConnectionHostNames, DisableLoopbackCheck.

    Each alias gets a Verdict and a list of Findings pointing at the matching fix in FileServerAlias-B.md.
    Makes NO changes (klist get only requests a service ticket; -TestKerberos also runs 'klist purge_bind'
    which only clears the KDC binding cache, not tickets).

    Does not cover: failover-cluster network names / SOFS, share or NTFS permissions, SMB signing/NTLM
    blocking posture (use Get-SmbHardeningPosture.ps1), non-Windows NAS.

.PARAMETER Server
    FQDN (preferred) or short name of the real file server.

.PARAMETER Alias
    One or more alias names. FQDN preferred; short names are qualified with the current AD domain.

.PARAMETER IncludeServerRegistry
    Read LanmanServer / MSV1_0 settings from the server via Invoke-Command (WinRM, admin on server).

.PARAMETER TestKerberos
    Request a cifs/<alias-fqdn> service ticket from this machine with klist.

.PARAMETER OutputPath
    Folder for the CSV report. Default: $env:TEMP.

.EXAMPLE
    .\Get-FileServerAliasHealth.ps1 -Server newfs.contoso.com -Alias oldfs.contoso.com,files.contoso.com -IncludeServerRegistry -TestKerberos

.EXAMPLE
    .\Get-FileServerAliasHealth.ps1 -Server newfs -Alias oldfs
    DNS + SPN + AD checks only (no remoting, no ticket request).

.NOTES
    Requires: Windows PowerShell 5.1+, domain-joined machine, domain user (read access to AD).
    -IncludeServerRegistry needs WinRM + local admin on the server. Does not require elevation locally.
    Safe: read-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string[]]$Alias,
    [switch]$IncludeServerRegistry,
    [switch]$TestKerberos,
    [string]$OutputPath = $env:TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-SpnOwners {
    param([string]$Spn)
    # Global Catalog search so owners in any domain of the forest are found
    try {
        $root = [ADSI]"GC://$($script:ForestName)"
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.Filter = "(servicePrincipalName=$Spn)"
        [void]$ds.PropertiesToLoad.Add('distinguishedName')
        [void]$ds.PropertiesToLoad.Add('sAMAccountName')
        $ds.PageSize = 500
        $res = $ds.FindAll()
        $owners = @()
        foreach ($r in $res) { $owners += [string]$r.Properties['samaccountname'][0] }
        $res.Dispose()
        return ,$owners
    } catch {
        Write-Status "SPN search failed for $Spn : $($_.Exception.Message)" "WARN"
        return ,@('<search-error>')
    }
}

function Get-AltNameHolders {
    param([string]$AliasFqdn)
    try {
        $root = [ADSI]"GC://$($script:ForestName)"
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.Filter = "(&(objectCategory=computer)(msDS-AdditionalDnsHostName=$AliasFqdn))"
        [void]$ds.PropertiesToLoad.Add('sAMAccountName')
        $res = $ds.FindAll()
        $holders = @()
        foreach ($r in $res) { $holders += [string]$r.Properties['samaccountname'][0] }
        $res.Dispose()
        return ,$holders
    } catch {
        return ,@('<search-error>')
    }
}

# ---------------- Preflight ----------------
try {
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
    $script:ForestName = $domain.Forest.Name
    $domainFqdn = $domain.Name
    Write-Status "Domain: $domainFqdn  Forest: $($script:ForestName)"
} catch {
    Write-Status "This machine is not domain-joined or no DC is reachable: $($_.Exception.Message)" "ERROR"
    throw
}
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$serverFqdn  = if ($Server -like '*.*') { $Server } else { "$Server.$domainFqdn" }
$serverShort = $serverFqdn.Split('.')[0]
$serverSam   = ($serverShort + '$').ToUpper()

$serverIPs = @()
try {
    $serverIPs = @(Resolve-DnsName -Name $serverFqdn -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    Write-Status "Real server $serverFqdn -> $($serverIPs -join ', ')" "OK"
} catch {
    Write-Status "Cannot resolve real server $serverFqdn : $($_.Exception.Message)" "ERROR"
}

# Server computer object alt names
$serverAltNames = @()
try {
    $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"GC://$($script:ForestName)")
    $ds.Filter = "(&(objectCategory=computer)(sAMAccountName=$serverSam))"
    [void]$ds.PropertiesToLoad.Add('msDS-AdditionalDnsHostName')
    $obj = $ds.FindOne()
    if ($null -eq $obj) {
        Write-Status "Computer object $serverSam not found in the Global Catalog" "WARN"
    } elseif ($obj.Properties.Contains('msds-additionaldnshostname')) {
        foreach ($v in $obj.Properties['msds-additionaldnshostname']) { $serverAltNames += [string]$v }
    }
} catch {
    Write-Status "AD lookup of $serverSam failed: $($_.Exception.Message)" "WARN"
}
Write-Status "Alternate names on $serverSam : $(if ($serverAltNames.Count) { $serverAltNames -join ', ' } else { '(none)' })"

# ---------------- Server registry (optional) ----------------
$reg = $null
if ($IncludeServerRegistry) {
    try {
        $reg = Invoke-Command -ComputerName $serverFqdn -ErrorAction Stop -ScriptBlock {
            $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -ErrorAction SilentlyContinue
            $m = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -ErrorAction SilentlyContinue
            $l = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
            function Get-Val($o, $n) { if ($o -and ($o.PSObject.Properties.Name -contains $n)) { $o.$n } else { $null } }
            [pscustomobject]@{
                DisableStrictNameChecking   = Get-Val $p 'DisableStrictNameChecking'
                OptionalNames               = @(Get-Val $p 'OptionalNames') -join ';'
                SmbServerNameHardeningLevel = Get-Val $p 'SmbServerNameHardeningLevel'
                SrvAllowedServerNames       = @(Get-Val $p 'SrvAllowedServerNames') -join ';'
                BackConnectionHostNames     = @(Get-Val $m 'BackConnectionHostNames') -join ';'
                DisableLoopbackCheck        = Get-Val $l 'DisableLoopbackCheck'
            }
        }
        Write-Status "Read server registry from $serverFqdn" "OK"
    } catch {
        Write-Status "Invoke-Command to $serverFqdn failed (WinRM/admin?): $($_.Exception.Message)" "WARN"
    }
}

# ---------------- Per-alias checks ----------------
$results = @()
foreach ($a in $Alias) {
    $aFqdn  = if ($a -like '*.*') { $a } else { "$a.$domainFqdn" }
    $aShort = $aFqdn.Split('.')[0]
    Write-Status "---- Alias $aFqdn ----"
    $findings = New-Object System.Collections.Generic.List[string]

    # DNS
    $recType = 'none'; $cnameTarget = ''; $aliasIPs = @()
    try {
        $dns = @(Resolve-DnsName -Name $aFqdn -DnsOnly -ErrorAction Stop)
        $cn = @($dns | Where-Object { $_.Type -eq 'CNAME' })
        if ($cn.Count -gt 0) { $recType = 'CNAME'; $cnameTarget = [string]$cn[0].NameHost } else { $recType = 'A' }
        $aliasIPs = @($dns | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    } catch {
        $findings.Add('DNS: alias does not resolve')
    }
    $ipMatch = $false
    if ($aliasIPs.Count -gt 0 -and $serverIPs.Count -gt 0) {
        $ipMatch = @($aliasIPs | Where-Object { $serverIPs -contains $_ }).Count -gt 0
        if (-not $ipMatch) { $findings.Add("DNS: alias IP(s) $($aliasIPs -join ',') do not match server IP(s) - stale record?") }
    }
    if ($recType -eq 'CNAME') { $findings.Add('DNS: CNAME in use - Microsoft recommends netdom alternate name instead (Fix 1)') }

    # SPNs
    $spnReport = @{}
    foreach ($spn in @("HOST/$aFqdn", "HOST/$aShort", "cifs/$aFqdn")) {
        $owners = Get-SpnOwners -Spn $spn
        $spnReport[$spn] = $owners
        $ownersU = @($owners | ForEach-Object { $_.ToUpper() })
        if ($spn -like 'cifs/*') { continue }   # cifs normally resolves via HOST mapping; informational only
        if ($owners.Count -eq 0) {
            $findings.Add("SPN: $spn has no owner - Kerberos impossible, NTLM fallback (Fix 1/3)")
        } elseif ($owners.Count -gt 1) {
            $findings.Add("SPN: $spn DUPLICATED on $($owners -join ', ') (Fix 2)")
        } elseif ($ownersU[0] -ne $serverSam) {
            $findings.Add("SPN: $spn owned by $($owners[0]), not $serverSam - KRB_AP_ERR_MODIFIED expected (Fix 2)")
        }
    }

    # AD alternate-name holders
    $holders = Get-AltNameHolders -AliasFqdn $aFqdn
    $isAltName = $serverAltNames -contains $aFqdn
    $otherHolders = @($holders | Where-Object { $_.ToUpper() -ne $serverSam })
    if ($otherHolders.Count -gt 0) { $findings.Add("AD: alias still in msDS-AdditionalDnsHostName of $($otherHolders -join ', ') (Fix 2)") }

    # Kerberos
    $krb = 'not tested'
    if ($TestKerberos) {
        try {
            & klist.exe purge_bind 2>&1 | Out-Null
            $k = (& klist.exe get "cifs/$aFqdn" 2>&1 | Out-String)
            if ($k -match 'retrieved successfully') { $krb = 'ticket OK' }
            elseif ($k -match '0x[0-9a-fA-F]+') { $krb = "failed $($Matches[0])"; $findings.Add("Kerberos: klist get cifs/$aFqdn failed $($Matches[0])") }
            else { $krb = 'failed (see klist output)'; $findings.Add('Kerberos: klist get failed') }
        } catch { $krb = "klist error: $($_.Exception.Message)" }
    }

    # Server acceptance
    if ($null -ne $reg) {
        $strict = ($reg.DisableStrictNameChecking -eq 1)
        $optional = @($reg.OptionalNames -split ';' | Where-Object { $_ }) -contains $aShort
        if (-not $isAltName -and -not $strict -and -not $optional) {
            $findings.Add('Server: alias is not an alt name / OptionalNames entry and DisableStrictNameChecking is off (Fix 1/3)')
        }
        if ($reg.SmbServerNameHardeningLevel -ge 1) {
            $allowed = @($reg.SrvAllowedServerNames -split ';' | Where-Object { $_ })
            if (-not (($allowed -contains $aFqdn) -or ($allowed -contains $aShort))) {
                $findings.Add("Server: SmbServerNameHardeningLevel=$($reg.SmbServerNameHardeningLevel) and alias not in SrvAllowedServerNames (Fix 4)")
            }
        }
        if ($reg.DisableLoopbackCheck -eq 1) { $findings.Add('Server: DisableLoopbackCheck=1 (global) - prefer BackConnectionHostNames') }
    }

    $verdict = if ($findings.Count -eq 0) { 'OK' }
               elseif (@($findings | Where-Object { $_ -match 'DUPLICATED|KRB_AP_ERR|no owner|does not resolve|do not match|Fix 4' }).Count -gt 0) { 'BROKEN' }
               else { 'WARN' }
    Write-Status "$aFqdn -> $verdict" $(if ($verdict -eq 'OK') {'OK'} elseif ($verdict -eq 'WARN') {'WARN'} else {'ERROR'})
    foreach ($f in $findings) { Write-Status "  $f" "WARN" }

    $results += [pscustomobject]@{
        Server                      = $serverFqdn
        Alias                       = $aFqdn
        DnsRecordType               = $recType
        CnameTarget                 = $cnameTarget
        AliasIPs                    = $aliasIPs -join ';'
        ServerIPs                   = $serverIPs -join ';'
        IpMatchesServer             = $ipMatch
        IsNetdomAltName             = $isAltName
        SpnHostFqdnOwners           = $spnReport["HOST/$aFqdn"] -join ';'
        SpnHostShortOwners          = $spnReport["HOST/$aShort"] -join ';'
        SpnCifsFqdnOwners           = $spnReport["cifs/$aFqdn"] -join ';'
        AltNameHolders              = $holders -join ';'
        KerberosTest                = $krb
        DisableStrictNameChecking   = if ($reg) { $reg.DisableStrictNameChecking } else { 'n/a' }
        OptionalNames               = if ($reg) { $reg.OptionalNames } else { 'n/a' }
        SmbServerNameHardeningLevel = if ($reg) { $reg.SmbServerNameHardeningLevel } else { 'n/a' }
        SrvAllowedServerNames       = if ($reg) { $reg.SrvAllowedServerNames } else { 'n/a' }
        BackConnectionHostNames     = if ($reg) { $reg.BackConnectionHostNames } else { 'n/a' }
        Verdict                     = $verdict
        Findings                    = $findings -join ' | '
    }
}

# ---------------- Report ----------------
$csv = Join-Path $OutputPath ("FileServerAliasHealth_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $serverShort, (Get-Date))
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
$results | Format-Table Alias, DnsRecordType, IsNetdomAltName, SpnHostFqdnOwners, KerberosTest, Verdict -AutoSize
Write-Status "Report written to $csv" "OK"
