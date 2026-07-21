<#
.SYNOPSIS
    Audits the prerequisites for Kerberos Armoring (FAST) — domain functional
    level, domain controller OS-version homogeneity, and (optionally) the
    KDC-side/client-side Group Policy state — to identify the most common
    root causes of "configured but not working" armoring issues.

.DESCRIPTION
    Kerberos Armoring's stricter enforcement options ("Always provide claims",
    "Fail unarmored authentication requests") silently do nothing below domain
    functional level Windows Server 2012, and a single down-level domain
    controller can cause purely intermittent, DC-dependent failures even above
    that level. This script checks both conditions first, since they explain
    the large majority of real-world tickets in this topic, then optionally
    runs a local gpresult scan (via -IncludeLocalPolicy) to surface the
    client-side policy state on the machine the script is run from.

    This script does NOT change any AD setting, GPO, or domain functional
    level. Read-only / reporting only. Exports a consolidated CSV.

.PARAMETER IncludeLocalPolicy
    If specified, additionally runs 'gpresult /r /scope:computer' on the local
    machine and searches the output for Kerberos/KDC-related policy lines.
    Useful when run directly on an affected client or DC.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\KerberosArmoringAudit_<timestamp>.csv

.EXAMPLE
    .\Get-KerberosArmoringAudit.ps1
    # Checks domain functional level and DC OS-version homogeneity only

.EXAMPLE
    .\Get-KerberosArmoringAudit.ps1 -IncludeLocalPolicy
    # Also scans this machine's local gpresult output for Kerberos/KDC policy state

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT)
    Run as: Any account with read access to AD domain/DC objects; local admin
            recommended for the -IncludeLocalPolicy gpresult scan
    Safe/Unsafe: READ-ONLY — does not modify domain functional level, GPOs,
                 or any registry value on any machine
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
    Limitation: This script cannot directly read the KDC-side or client-side
                GPO's configured VALUE remotely with full reliability, since
                the exact registry value names for the two client-side
                policies are not consistently documented across sources.
                Use -IncludeLocalPolicy (gpresult) on the specific machine in
                question for an authoritative policy-state read, or open the
                GPO itself in Group Policy Management Console.
#>

[CmdletBinding()]
param(
    [switch] $IncludeLocalPolicy,
    [string] $ExportPath = "$env:TEMP\KerberosArmoringAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

Write-Status "Kerberos Armoring (FAST) Prerequisite Audit" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

$results = @()

#endregion

#region --- Domain Functional Level ---

Write-Status "`n=== Domain Functional Level ===" -Status "HEADER"

try {
    $domain = Get-ADDomain -ErrorAction Stop
    $domainMode = $domain.DomainMode

    # Functional levels are an ordered enum; anything at/above Windows2012Domain qualifies.
    $qualifyingLevels = @(
        "Windows2012Domain", "Windows2012R2Domain", "Windows2016Domain"
    )
    $dflOk = $qualifyingLevels -contains $domainMode.ToString()

    $dflStatus = if ($dflOk) { "OK" } else { "ERROR" }
    Write-Status "  Domain: $($domain.DNSRoot)" -Status "INFO"
    Write-Status "  Domain functional level: $domainMode" -Status $dflStatus

    if (-not $dflOk) {
        Write-Status "  BELOW WINDOWS SERVER 2012 DOMAIN FUNCTIONAL LEVEL." -Status "ERROR"
        Write-Status "  'Always provide claims' and 'Fail unarmored authentication requests' will" -Status "ERROR"
        Write-Status "  have NO EFFECT regardless of GPO configuration until this is raised." -Status "ERROR"
    }

    $results += [PSCustomObject]@{
        Category = "DomainFunctionalLevel"; Item = $domain.DNSRoot
        Value = $domainMode; Status = $dflStatus
        Note = if ($dflOk) { "Qualifies for stricter armoring enforcement options" } else { "BLOCKS stricter enforcement options - raise DFL first (one-way change)" }
    }
} catch {
    Write-Status "  Could not query domain functional level: $_" -Status "ERROR"
    $results += [PSCustomObject]@{
        Category = "DomainFunctionalLevel"; Item = "Query"; Value = "FAILED"; Status = "ERROR"; Note = "$_"
    }
}

#endregion

#region --- Domain Controller OS Homogeneity ---

Write-Status "`n=== Domain Controller OS-Version Homogeneity ===" -Status "HEADER"

try {
    $dcs = Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem, OperatingSystemVersion, Site

    if (-not $dcs) {
        Write-Status "  No domain controllers returned — check connectivity/permissions." -Status "WARN"
    } else {
        $downLevelPattern = '2000|2003|2008(?!\s*R2\+)'
        foreach ($dc in $dcs) {
            $isDownLevel = $dc.OperatingSystem -match '2000|2003' -or
                           ($dc.OperatingSystem -match '2008' -and $dc.OperatingSystem -notmatch '2008\s*R2')
            $dcStatus = if ($isDownLevel) { "ERROR" } else { "OK" }

            Write-Host "  $($dc.Name) [$($dc.Site)] : $($dc.OperatingSystem)" -ForegroundColor $(if ($isDownLevel) { "Red" } else { "Green" })

            $results += [PSCustomObject]@{
                Category = "DomainController"; Item = $dc.Name
                Value = $dc.OperatingSystem; Status = $dcStatus
                Note = if ($isDownLevel) { "Down-level DC cannot participate in armored exchanges - clients landing here will fail/degrade" } else { "Supports Kerberos armoring" }
            }
        }

        $downLevelCount = ($results | Where-Object { $_.Category -eq "DomainController" -and $_.Status -eq "ERROR" }).Count
        if ($downLevelCount -gt 0) {
            Write-Status "  $downLevelCount down-level DC(s) found — this is a common cause of purely" -Status "ERROR"
            Write-Status "  intermittent, DC-dependent armoring failures." -Status "ERROR"
        } else {
            Write-Status "  All $($dcs.Count) domain controller(s) support Kerberos armoring." -Status "OK"
        }
    }
} catch {
    Write-Status "  Could not enumerate domain controllers: $_" -Status "ERROR"
    $results += [PSCustomObject]@{
        Category = "DomainController"; Item = "Enumeration"; Value = "FAILED"; Status = "ERROR"; Note = "$_"
    }
}

#endregion

#region --- Optional Local Policy Scan ---

if ($IncludeLocalPolicy) {
    Write-Status "`n=== Local Machine Policy Scan (gpresult) ===" -Status "HEADER"
    try {
        $gpText = gpresult /r /scope:computer 2>&1 | Out-String
        $relevantLines = $gpText -split "`n" | Where-Object { $_ -match "Kerberos|KDC|armoring|claims" }

        if ($relevantLines) {
            Write-Status "  Found $($relevantLines.Count) potentially relevant policy line(s):" -Status "INFO"
            $relevantLines | ForEach-Object { Write-Host "    $_" }
            $results += [PSCustomObject]@{
                Category = "LocalPolicy"; Item = $env:COMPUTERNAME
                Value = "$($relevantLines.Count) relevant line(s) found"; Status = "INFO"
                Note = "Review full gpresult /h HTML report for exact policy values - registry value names for client-side armoring policies are not consistently documented"
            }
        } else {
            Write-Status "  No Kerberos/KDC/armoring/claims policy lines found in gpresult output." -Status "WARN"
            Write-Status "  This may mean neither client-side armoring policy is configured on this machine." -Status "WARN"
            $results += [PSCustomObject]@{
                Category = "LocalPolicy"; Item = $env:COMPUTERNAME
                Value = "No relevant lines found"; Status = "WARN"
                Note = "Client-side armoring policy may not be configured on this machine"
            }
        }
    } catch {
        Write-Status "  Could not run gpresult: $_" -Status "WARN"
        $results += [PSCustomObject]@{
            Category = "LocalPolicy"; Item = $env:COMPUTERNAME; Value = "FAILED"; Status = "WARN"; Note = "$_"
        }
    }
} else {
    Write-Status "`n(Skipping local policy scan — run with -IncludeLocalPolicy on the affected machine to check client-side Kerberos/KDC policy state.)" -Status "INFO"
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
    Write-Status "One or more prerequisite gaps found (domain functional level and/or down-level DC) - review the CSV before assuming a GPO misconfiguration." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Prerequisites look healthy, but review warnings — run with -IncludeLocalPolicy on the affected machine for a full picture." -Status "WARN"
} else {
    Write-Status "Domain functional level and DC OS-version prerequisites are healthy." -Status "OK"
}

#endregion
