<#
.SYNOPSIS
    Audits LDAP signing (LDAPServerIntegrity) and LDAP channel binding
    (LdapEnforceChannelBinding) enforcement across every domain controller,
    plus recent unsigned-bind/channel-binding exposure event counts.

.DESCRIPTION
    For every reachable DC in the current domain, collects:
      - LDAPServerIntegrity (0=None, 1=Negotiate, 2=Require)
      - LdapEnforceChannelBinding (0=Never, 1=When supported, 2=Always)
      - Consistency check across all DCs (mixed enforcement is itself a finding)
      - Event 2886/2887 count (signing exposure summary, Directory Service log)
      - Event 3039 count (channel binding exposure summary, Directory Service log)
      - Current "16 LDAP Interface Events" diagnostics logging level

    This script does NOT change any enforcement value or diagnostics logging
    level. Read-only. Exports a consolidated CSV for escalation/reporting.

    Use this BEFORE tightening enforcement, to confirm current posture and
    quantify exposure — and periodically afterward, to confirm enforcement
    stayed consistent across all DCs (e.g., after adding a new DC that may
    not have inherited the same GPO-applied values yet).

.PARAMETER DomainController
    Optional. Limit the audit to one or more specific DC hostnames instead
    of every DC discovered via Get-ADDomainController -Filter *.

.PARAMETER EventLookbackHours
    How far back to search the Directory Service log for Event 2886/2887/3039.
    Default: 72 hours (covers a long weekend without requiring a huge scan).

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\LDAPSigningAudit_<timestamp>.csv

.EXAMPLE
    .\Get-LDAPSigningAudit.ps1
    # Audits every DC in the domain, default 72h event lookback, CSV export

.EXAMPLE
    .\Get-LDAPSigningAudit.ps1 -DomainController "DC01","DC02" -EventLookbackHours 168
    # Audits two named DCs with a full week of event lookback

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), WinRM/PSRemoting
              enabled on target DCs (uses Invoke-Command)
    Run as: Domain Admin, or an account with local admin rights on each DC
            and read access to the Directory Service event log
    Safe/Unsafe: READ-ONLY — does not modify LDAPServerIntegrity,
                 LdapEnforceChannelBinding, or diagnostics logging level
                 on any DC
    Tested against: Windows Server 2016 / 2019 / 2022 domain controllers
    Limitation: Event 2886/2887/3039 are periodic summary events (roughly
                every 24h while the corresponding setting is in its
                permissive/monitoring state) — a short EventLookbackHours
                window can miss the most recent summary if it hasn't fired
                yet. Widen the window if counts show as 0 but you suspect
                real exposure.
#>

[CmdletBinding()]
param(
    [string[]] $DomainController,
    [int] $EventLookbackHours = 72,
    [string] $ExportPath = "$env:TEMP\LDAPSigningAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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

function Get-SigningLabel {
    param([Nullable[int]]$Value)
    switch ($Value) {
        0       { "0 - None (unsigned binds fully accepted, no logging)" }
        1       { "1 - Negotiate (unsigned accepted, Event 2887 counts it)" }
        2       { "2 - Require (unsigned binds REJECTED)" }
        default { "Not set / unreadable (treat as build default, do not assume)" }
    }
}

function Get-ChannelBindingLabel {
    param([Nullable[int]]$Value)
    switch ($Value) {
        0       { "0 - Never (CBT never required)" }
        1       { "1 - When supported (CBT validated if present, not required)" }
        2       { "2 - Always (bind REJECTED without a valid, matching CBT)" }
        default { "Not set / unreadable (treat as build default, do not assume)" }
    }
}

#region --- Preflight ---

Write-Status "LDAP Signing / Channel Binding Audit" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Status "ActiveDirectory module not found. Install RSAT: AD DS Tools." -Status "ERROR"
    exit 1
}
Import-Module ActiveDirectory -ErrorAction Stop

$targets = if ($DomainController) {
    $DomainController
} else {
    try {
        (Get-ADDomainController -Filter *).HostName
    } catch {
        Write-Status "Could not enumerate domain controllers: $_" -Status "ERROR"
        exit 1
    }
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Status "No domain controllers to audit. Exiting." -Status "WARN"
    exit 0
}

Write-Status "Auditing $($targets.Count) domain controller(s): $($targets -join ', ')" -Status "OK"
Write-Status "Event lookback window: $EventLookbackHours hour(s)" -Status "INFO"

#endregion

$results = @()
$dcSummaries = @()
$startTime = (Get-Date).AddHours(-$EventLookbackHours)

foreach ($dc in $targets) {

    Write-Status "`n=== $dc ===" -Status "HEADER"

    #region --- Enforcement Values ---

    $signingValue = $null
    $cbtValue = $null
    $diagLevel = $null
    $reachable = $true

    try {
        $regData = Invoke-Command -ComputerName $dc -ErrorAction Stop -ScriptBlock {
            $params = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -ErrorAction SilentlyContinue
            $diag   = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "16 LDAP Interface Events" -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                LDAPServerIntegrity       = $params.LDAPServerIntegrity
                LdapEnforceChannelBinding = $params.LdapEnforceChannelBinding
                DiagLevel                 = $diag.'16 LDAP Interface Events'
            }
        }
        $signingValue = $regData.LDAPServerIntegrity
        $cbtValue     = $regData.LdapEnforceChannelBinding
        $diagLevel    = $regData.DiagLevel
    } catch {
        Write-Status "  Could not connect to $dc via WinRM: $_" -Status "ERROR"
        $reachable = $false
        $results += [PSCustomObject]@{
            DC = $dc; Category = "Connectivity"; Metric = "Reachable"
            Value = "FAILED"; Status = "ERROR"
        }
    }

    if ($reachable) {
        $signingLabel = Get-SigningLabel -Value $signingValue
        $cbtLabel     = Get-ChannelBindingLabel -Value $cbtValue

        $signingStatus = if ($signingValue -eq 2) { "OK" } elseif ($null -eq $signingValue -or $signingValue -eq 1) { "WARN" } else { "ERROR" }
        $cbtStatus     = if ($cbtValue -eq 2) { "OK" } elseif ($null -eq $cbtValue -or $cbtValue -eq 1) { "WARN" } else { "ERROR" }

        Write-Host "  LDAPServerIntegrity       : $signingLabel"
        Write-Host "  LdapEnforceChannelBinding : $cbtLabel"
        Write-Host "  Diagnostics (16 LDAP Interface Events): $(if ($null -ne $diagLevel) { $diagLevel } else { '0 (default, not verbose)' })"

        $results += [PSCustomObject]@{
            DC = $dc; Category = "Enforcement"; Metric = "LDAPServerIntegrity"
            Value = $signingValue; Status = $signingStatus
        }
        $results += [PSCustomObject]@{
            DC = $dc; Category = "Enforcement"; Metric = "LdapEnforceChannelBinding"
            Value = $cbtValue; Status = $cbtStatus
        }
        $results += [PSCustomObject]@{
            DC = $dc; Category = "Diagnostics"; Metric = "16 LDAP Interface Events"
            Value = $diagLevel; Status = "INFO"
        }

        $dcSummaries += [PSCustomObject]@{
            DC = $dc; Signing = $signingValue; ChannelBinding = $cbtValue
        }
    }

    #endregion

    #region --- Exposure Events ---

    if ($reachable) {
        Write-Host "`n  --- Exposure Events (last $EventLookbackHours h) ---"
        try {
            $signingEvents = Invoke-Command -ComputerName $dc -ErrorAction Stop -ScriptBlock {
                param($start)
                Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=2886 or EventID=2887) and TimeCreated[@SystemTime>='$($start.ToUniversalTime().ToString('o'))']]]" -ErrorAction SilentlyContinue
            } -ArgumentList $startTime

            $cbtEvents = Invoke-Command -ComputerName $dc -ErrorAction Stop -ScriptBlock {
                param($start)
                Get-WinEvent -LogName "Directory Service" -FilterXPath "*[System[(EventID=3039) and TimeCreated[@SystemTime>='$($start.ToUniversalTime().ToString('o'))']]]" -ErrorAction SilentlyContinue
            } -ArgumentList $startTime

            $signingCount = if ($signingEvents) { $signingEvents.Count } else { 0 }
            $cbtCount     = if ($cbtEvents) { $cbtEvents.Count } else { 0 }

            $signingEventStatus = if ($signingCount -gt 0) { "WARN" } else { "OK" }
            $cbtEventStatus     = if ($cbtCount -gt 0) { "WARN" } else { "OK" }

            Write-Status "  Event 2886/2887 (signing exposure) occurrences: $signingCount" -Status $signingEventStatus
            Write-Status "  Event 3039 (channel binding exposure) occurrences: $cbtCount" -Status $cbtEventStatus

            $results += [PSCustomObject]@{
                DC = $dc; Category = "Exposure"; Metric = "Event2886-2887Count"
                Value = $signingCount; Status = $signingEventStatus
            }
            $results += [PSCustomObject]@{
                DC = $dc; Category = "Exposure"; Metric = "Event3039Count"
                Value = $cbtCount; Status = $cbtEventStatus
            }

            if ($signingCount -gt 0 -or $cbtCount -gt 0) {
                Write-Status "  Exposure confirmed — enable '16 LDAP Interface Events' = 2 to identify the specific client(s) before tightening enforcement." -Status "WARN"
            }
        } catch {
            Write-Status "  Could not query Directory Service event log on $dc : $_" -Status "WARN"
            $results += [PSCustomObject]@{
                DC = $dc; Category = "Exposure"; Metric = "EventQuery"
                Value = "ERROR"; Status = "WARN"
            }
        }
    }

    #endregion
}

#region --- Cross-DC Consistency Check ---

Write-Status "`n=== Cross-DC Consistency ===" -Status "HEADER"

if ($dcSummaries.Count -gt 1) {
    $distinctSigning = $dcSummaries.Signing | Select-Object -Unique
    $distinctCbt     = $dcSummaries.ChannelBinding | Select-Object -Unique

    if ($distinctSigning.Count -gt 1) {
        Write-Status "  LDAPServerIntegrity is INCONSISTENT across DCs: $($distinctSigning -join ', ') — this produces the 'works against one DC, fails against another' symptom." -Status "ERROR"
        $results += [PSCustomObject]@{
            DC = "ALL"; Category = "Consistency"; Metric = "LDAPServerIntegrity"
            Value = "Inconsistent: $($distinctSigning -join ', ')"; Status = "ERROR"
        }
    } else {
        Write-Status "  LDAPServerIntegrity is consistent across all audited DCs." -Status "OK"
    }

    if ($distinctCbt.Count -gt 1) {
        Write-Status "  LdapEnforceChannelBinding is INCONSISTENT across DCs: $($distinctCbt -join ', ')" -Status "ERROR"
        $results += [PSCustomObject]@{
            DC = "ALL"; Category = "Consistency"; Metric = "LdapEnforceChannelBinding"
            Value = "Inconsistent: $($distinctCbt -join ', ')"; Status = "ERROR"
        }
    } else {
        Write-Status "  LdapEnforceChannelBinding is consistent across all audited DCs." -Status "OK"
    }
} else {
    Write-Status "  Only one DC audited — consistency check skipped." -Status "INFO"
}

#endregion

#region --- Export & Summary ---

$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
Write-Host "  DCs audited      : $($targets.Count)"
Write-Host "  Total checks run : $($results.Count)"
Write-Host "  Errors           : $errorCount"
Write-Host "  Warnings         : $warnCount"
Write-Host "  Report saved to  : $ExportPath"

if ($errorCount -gt 0) {
    Write-Status "Enforcement is either weak or inconsistent across DCs — review the CSV before making changes." -Status "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "Enforcement is in a permissive/monitoring state and/or exposure events were found — review the CSV and plan a remediation window before tightening." -Status "WARN"
} else {
    Write-Status "All audited DCs are consistently at full enforcement (Require/Always) with no recent exposure events." -Status "OK"
}

#endregion
