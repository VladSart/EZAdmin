<#
.SYNOPSIS
    Tenant-wide health check of Active Directory domain and forest trusts.

.DESCRIPTION
    Collects and reports on, for every trust the current domain has:
      - Trust type, direction, forest-transitivity, SID filtering (quarantine), and
        selective authentication configuration
      - Secure channel verification via netdom trust /verify
      - DNS SRV resolution to the trusted domain's DCs
      - Basic network reachability (Kerberos/LDAP/SMB ports) to a discovered DC
        in the trusted domain

    This script does NOT reset trust passwords, change SID filtering, modify
    selective authentication, or alter any trust in any way. Read-only.
    Exports a consolidated CSV for escalation/reporting.

.PARAMETER TrustName
    Optional. Limit the check to a single named trust instead of every trust
    returned by Get-ADTrust.

.PARAMETER SkipPortCheck
    Skip the Kerberos/LDAP/SMB port reachability test (faster, but loses
    network-path validation). Default: $false.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\ADTrustHealth_<timestamp>.csv

.EXAMPLE
    .\Get-ADTrustHealth.ps1
    # Checks every trust on the current domain, full checks, CSV export

.EXAMPLE
    .\Get-ADTrustHealth.ps1 -TrustName "contoso.com" -SkipPortCheck
    # Faster, single-trust check without the network port test

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), netdom.exe
    Run as: Domain Admin or delegated AD read + trust-verification rights
    Safe/Unsafe: READ-ONLY — does not reset trust passwords or change any
                 trust attribute (SID filtering, selective auth, direction)
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
    Limitation: netdom trust /verify only checks the secure channel from THIS
                domain's perspective. A one-sided desync (healthy here, broken
                on the partner side) requires running this script from a DC
                in the partner domain as well — this is documented behavior,
                not a bug in this script.
#>

[CmdletBinding()]
param(
    [string] $TrustName,
    [switch] $SkipPortCheck,
    [string] $ExportPath = "$env:TEMP\ADTrustHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

Write-Status "AD Trust Health Check" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Get-Command netdom.exe -ErrorAction SilentlyContinue)) {
    Write-Status "netdom.exe not found on PATH. Run from a DC or install RSAT." -Status "ERROR"
    exit 1
}

$thisDomain = (Get-ADDomain).DNSRoot
Write-Status "Local domain: $thisDomain" -Status "INFO"
Write-Status "Prerequisites OK." -Status "OK"

#endregion

$results = @()

#region --- Enumerate Trusts ---

Write-Status "`n=== Enumerating Trusts ===" -Status "HEADER"

$trustFilter = if ($TrustName) { "Name -eq '$TrustName'" } else { "*" }
$trusts = @()
try {
    $trusts = if ($TrustName) {
        Get-ADTrust -Filter { Name -eq $TrustName }
    } else {
        Get-ADTrust -Filter *
    }
} catch {
    Write-Status "Could not enumerate trusts: $_" -Status "ERROR"
    exit 1
}

if (-not $trusts -or $trusts.Count -eq 0) {
    Write-Status "No trusts found $(if ($TrustName) { "matching '$TrustName'" } else { "on this domain" })." -Status "WARN"
    Write-Status "Nothing further to check. Exiting." -Status "INFO"
    exit 0
}

Write-Status "Found $($trusts.Count) trust(s)." -Status "OK"

#endregion

foreach ($trust in $trusts) {

    $trustedName = $trust.Name
    Write-Status "`n=== Trust: $trustedName ===" -Status "HEADER"

    #region --- Attribute Summary ---

    Write-Host "  Direction               : $($trust.Direction)"
    Write-Host "  TrustType               : $($trust.TrustType)"
    Write-Host "  ForestTransitive        : $($trust.ForestTransitive)"
    Write-Host "  SIDFilteringQuarantined : $($trust.SIDFilteringQuarantined)"
    Write-Host "  SIDFilteringForestAware : $($trust.SIDFilteringForestAware)"
    Write-Host "  SelectiveAuthentication : $($trust.SelectiveAuthentication)"

    $results += [PSCustomObject]@{
        Trust  = $trustedName; Category = "Attributes"; Metric = "Direction"
        Value  = $trust.Direction; Status = "INFO"
    }
    $results += [PSCustomObject]@{
        Trust  = $trustedName; Category = "Attributes"; Metric = "TrustType"
        Value  = $trust.TrustType; Status = "INFO"
    }

    # External (non-forest-transitive) trusts should be quarantined by default —
    # flag as WARN only if quarantine is explicitly OFF on a non-forest-transitive trust,
    # since that's the security-relevant deviation from the safe default.
    if (-not $trust.ForestTransitive -and -not $trust.SIDFilteringQuarantined) {
        Write-Status "  SID filtering is DISABLED on a non-forest-transitive trust — confirm this is an intentional, time-boxed migration state." -Status "WARN"
        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "Security"; Metric = "SIDFilteringQuarantined"
            Value = "False"; Status = "WARN"
        }
    } else {
        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "Security"; Metric = "SIDFilteringQuarantined"
            Value = $trust.SIDFilteringQuarantined; Status = "OK"
        }
    }

    if ($trust.SelectiveAuthentication) {
        Write-Status "  Selective authentication is ENABLED — access requires explicit 'Allowed to Authenticate' ACEs on target computer objects." -Status "INFO"
    }

    #endregion

    #region --- Secure Channel Verification ---

    Write-Host "`n  --- Secure Channel Verify (netdom trust /verify) ---"
    try {
        $verifyOut = netdom trust $thisDomain /Domain:$trustedName /verify 2>&1
        $verifyText = $verifyOut -join " "
        $verifyOk = $verifyText -match "verified successfully|valid condition|completed successfully"

        if ($verifyOk) {
            Write-Status "  Secure channel verified OK (from $thisDomain's perspective)." -Status "OK"
        } else {
            Write-Status "  Secure channel verification FAILED or returned unexpected output — review raw output below." -Status "ERROR"
            $verifyOut | ForEach-Object { Write-Host "    $_" }
        }

        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "SecureChannel"; Metric = "VerifyFromThisDomain"
            Value = if ($verifyOk) { "OK" } else { "FAILED" }
            Status = if ($verifyOk) { "OK" } else { "ERROR" }
        }
    } catch {
        Write-Status "  Could not run netdom trust /verify: $_" -Status "WARN"
        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "SecureChannel"; Metric = "VerifyFromThisDomain"
            Value = "ERROR"; Status = "WARN"
        }
    }

    Write-Status "  Note: this only verifies from $thisDomain's side. Run this script from a DC in '$trustedName' to catch a one-sided desync." -Status "INFO"

    #endregion

    #region --- DNS Resolution ---

    Write-Host "`n  --- DNS SRV Resolution ---"
    $dcHost = $null
    try {
        $srv = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$trustedName" -Type SRV -ErrorAction Stop
        $dcHost = ($srv | Select-Object -First 1).NameTarget
        Write-Status "  DNS SRV resolution OK — first DC target: $dcHost" -Status "OK"
        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "DNS"; Metric = "SRVResolution"
            Value = $dcHost; Status = "OK"
        }
    } catch {
        Write-Status "  DNS SRV resolution FAILED for _ldap._tcp.dc._msdcs.$trustedName — check conditional forwarder/delegation." -Status "ERROR"
        $results += [PSCustomObject]@{
            Trust = $trustedName; Category = "DNS"; Metric = "SRVResolution"
            Value = "FAILED"; Status = "ERROR"
        }
    }

    #endregion

    #region --- Network Reachability ---

    if (-not $SkipPortCheck -and $dcHost) {
        Write-Host "`n  --- Network Reachability to $dcHost ---"
        $portsToCheck = @{ 88 = "Kerberos"; 389 = "LDAP"; 445 = "SMB" }
        foreach ($port in $portsToCheck.Keys) {
            $label = $portsToCheck[$port]
            try {
                $test = Test-NetConnection -ComputerName $dcHost -Port $port -WarningAction SilentlyContinue -ErrorAction Stop
                $open = $test.TcpTestSucceeded
                if ($open) {
                    Write-Status "    Port $port ($label): reachable" -Status "OK"
                } else {
                    Write-Status "    Port $port ($label): NOT reachable" -Status "ERROR"
                }
                $results += [PSCustomObject]@{
                    Trust = $trustedName; Category = "Network"; Metric = "Port$port-$label"
                    Value = if ($open) { "Open" } else { "Blocked" }
                    Status = if ($open) { "OK" } else { "ERROR" }
                }
            } catch {
                Write-Status "    Port $port ($label): could not test — $_" -Status "WARN"
                $results += [PSCustomObject]@{
                    Trust = $trustedName; Category = "Network"; Metric = "Port$port-$label"
                    Value = "N/A"; Status = "WARN"
                }
            }
        }
    } elseif ($SkipPortCheck) {
        Write-Status "  Skipping port reachability check (per -SkipPortCheck)." -Status "INFO"
    } else {
        Write-Status "  Skipping port reachability check — no DC host resolved from DNS." -Status "WARN"
    }

    #endregion
}

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  Trusts checked   : $($trusts.Count)"
Write-Host "  Total checks run : $($results.Count)"
Write-Host "  Errors           : $errorCount"
Write-Host "  Warnings         : $warnCount"
Write-Host "  Report saved to  : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "One or more trust health issues detected — review the CSV and escalate if needed." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Minor issues or security-relevant deviations detected — review the CSV." -Status "WARN"
} else {
    Write-Status "All checked trusts look healthy." -Status "OK"
}

#endregion
