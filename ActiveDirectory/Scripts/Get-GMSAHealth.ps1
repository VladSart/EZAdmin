<#
.SYNOPSIS
    Audits Group Managed Service Account (gMSA) health across the KDS root key, AD delegation,
    and (optionally) local host installation/retrieval layers.

.DESCRIPTION
    Read-only diagnostic script matching the dependency stack documented in
    ActiveDirectory/Troubleshooting/gMSA/gMSA-A.md and gMSA-B.md. Checks, in order:
      1. Forest KDS root key existence and EffectiveTime convergence (Get-KdsRootKey)
      2. One or more gMSA objects: Enabled state, PrincipalsAllowedToRetrieveManagedPassword
         delegation (direct + resolved group membership), and msDS-ManagedPasswordInterval
      3. Optionally, when run FROM a target host with -TestLocal, the actual end-to-end
         Test-ADServiceAccount retrieval result and a scan of the GMSA Operational event log

    This script does NOT create, modify, or remove any AD object or local installation state.
    It requires the ActiveDirectory PowerShell module (RSAT) for Parts 1-2, run from a DC or a
    management host. Part 3 (-TestLocal) must be run interactively on the specific host being
    diagnosed, since gMSA retrieval success is host-specific by design.

.PARAMETER Identity
    One or more gMSA names (sAMAccountName, without the trailing $) to audit.
    If omitted, audits every gMSA in the domain.

.PARAMETER TestLocal
    Switch. When present, also runs Test-ADServiceAccount locally for each -Identity gMSA
    and scans the Microsoft-Windows-GroupManagedServiceAccounts/Operational event log on
    THIS host. Only meaningful when run directly on a host that consumes the gMSA(s).

.PARAMETER EventLogLookbackHours
    How far back to scan the GMSA Operational event log when -TestLocal is used. Default: 24.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.EXAMPLE
    .\Get-GMSAHealth.ps1
    Audits every gMSA in the domain from the KDS root key and AD delegation perspective.

.EXAMPLE
    .\Get-GMSAHealth.ps1 -Identity "svc-webapp01" -TestLocal
    Audits a single gMSA and, since run with -TestLocal, also tests actual retrieval on
    this host and checks its GMSA Operational event log for the last 24 hours.

.EXAMPLE
    .\Get-GMSAHealth.ps1 -Identity "svc-webapp01","svc-sqlagent" -OutputPath "C:\Temp"
    Audits two named gMSAs and writes GMSAHealth_<timestamp>.csv to C:\Temp.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT) for Parts 1-2.
    Run-as: Any account with read access to gMSA objects and the KDS root key container
            is sufficient for Parts 1-2 (no elevated rights required for read-only audit).
            -TestLocal should be run as (or Invoke-Command'd against) the host/service
            context that actually consumes the gMSA, since retrieval success depends on
            local installation state (Install-ADServiceAccount) that is per-host.
    Safe/Unsafe: 100% read-only. No AD objects are created, modified, or removed; no
                 Install-ADServiceAccount / Uninstall-ADServiceAccount calls are made.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Identity,

    [Parameter(Mandatory = $false)]
    [switch]$TestLocal,

    [Parameter(Mandatory = $false)]
    [int]$EventLogLookbackHours = 24,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory module not available. Install RSAT: AD DS and AD LDS Tools, or run from a DC." "ERROR"
    throw
}

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Part 1 — KDS Root Key state (forest-wide, checked once)
# ---------------------------------------------------------------------------
Write-Status "Checking KDS root key state..."

$kdsKeys = @(Get-KdsRootKey -ErrorAction SilentlyContinue)

if ($kdsKeys.Count -eq 0) {
    Write-Status "No KDS root key found in this forest. No gMSA can retrieve a password until one is created (Add-KdsRootKey)." "ERROR"
    $kdsFlag = "NO_KDS_ROOT_KEY"
    $kdsConverged = $false
} else {
    $convergedKeys = @($kdsKeys | Where-Object { $_.EffectiveTime -le (Get-Date) })
    if ($convergedKeys.Count -eq 0) {
        $earliest = ($kdsKeys | Sort-Object EffectiveTime | Select-Object -First 1).EffectiveTime
        Write-Status "KDS root key(s) exist but none have converged yet. Earliest EffectiveTime: $earliest (default 10-hour post-creation delay)." "WARN"
        $kdsFlag = "KDS_NOT_CONVERGED"
        $kdsConverged = $false
    } else {
        Write-Status "KDS root key converged. $($convergedKeys.Count) usable key(s) found." "OK"
        $kdsFlag = "OK"
        $kdsConverged = $true
    }
}

# ---------------------------------------------------------------------------
# Part 2 — gMSA object inventory, delegation, and interval
# ---------------------------------------------------------------------------
Write-Status "Enumerating gMSA object(s)..."

if ($Identity) {
    $gmsaAccounts = foreach ($id in $Identity) {
        try {
            Get-ADServiceAccount -Identity $id -Properties Enabled, DNSHostName, `
                PrincipalsAllowedToRetrieveManagedPassword, "msDS-ManagedPasswordInterval", `
                whenCreated -ErrorAction Stop
        } catch {
            Write-Status "gMSA '$id' not found: $($_.Exception.Message)" "ERROR"
        }
    }
} else {
    $gmsaAccounts = Get-ADServiceAccount -Filter { ObjectClass -eq "msDS-GroupManagedServiceAccount" } `
        -Properties Enabled, DNSHostName, PrincipalsAllowedToRetrieveManagedPassword, `
        "msDS-ManagedPasswordInterval", whenCreated
}

if (-not $gmsaAccounts -or @($gmsaAccounts).Count -eq 0) {
    Write-Status "No gMSA objects found (or none matched -Identity)." "WARN"
}

foreach ($gmsa in @($gmsaAccounts)) {

    if (-not $gmsa) { continue }

    $name = $gmsa.Name
    Write-Status "Auditing gMSA: $name" "INFO"

    $findings = [System.Collections.Generic.List[string]]::new()

    if (-not $gmsa.Enabled) {
        $findings.Add("ACCOUNT_DISABLED")
    }

    # Resolve delegation — direct entries and group-based entries
    $delegatedPrincipals = @($gmsa.PrincipalsAllowedToRetrieveManagedPassword)
    $resolvedHostCount = 0
    $delegationDetail = [System.Collections.Generic.List[string]]::new()

    if ($delegatedPrincipals.Count -eq 0) {
        $findings.Add("NO_DELEGATION_CONFIGURED")
    } else {
        foreach ($principalDN in $delegatedPrincipals) {
            try {
                $obj = Get-ADObject -Identity $principalDN -Properties ObjectClass -ErrorAction Stop
                if ($obj.ObjectClass -eq "group") {
                    $memberCount = @(Get-ADGroupMember -Identity $principalDN -ErrorAction SilentlyContinue |
                        Where-Object { $_.objectClass -eq "computer" }).Count
                    $delegationDetail.Add("Group '$($obj.Name)' ($memberCount computer member(s))")
                    $resolvedHostCount += $memberCount
                } elseif ($obj.ObjectClass -eq "computer") {
                    $delegationDetail.Add("Direct host: $($obj.Name)")
                    $resolvedHostCount += 1
                } else {
                    $delegationDetail.Add("Other principal: $($obj.Name) ($($obj.ObjectClass))")
                }
            } catch {
                $delegationDetail.Add("UNRESOLVABLE_PRINCIPAL: $principalDN")
                $findings.Add("DELEGATION_PRINCIPAL_UNRESOLVABLE")
            }
        }

        # Flag direct-host delegation as a scalability warning, not an error
        $directHostEntries = $delegationDetail | Where-Object { $_ -like "Direct host:*" }
        if ($directHostEntries.Count -gt 0) {
            $findings.Add("DIRECT_HOST_DELEGATION_USED")
        }

        if ($resolvedHostCount -eq 0) {
            $findings.Add("DELEGATION_RESOLVES_TO_ZERO_HOSTS")
        }
    }

    # Password rotation interval — flag if using the domain default implicitly vs explicitly set
    $interval = $gmsa."msDS-ManagedPasswordInterval"
    if (-not $interval) {
        $intervalDisplay = "30 (domain default, not explicitly set)"
    } else {
        $intervalDisplay = "$interval"
    }

    if ($kdsFlag -ne "OK") {
        $findings.Add("BLOCKED_BY_KDS_STATE:$kdsFlag")
    }

    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $localTestResult = "NOT_TESTED (use -TestLocal on the consuming host)"
    $eventLogSummary = "N/A"

    if ($TestLocal) {
        Write-Status "  Running local Test-ADServiceAccount for '$name' on $($env:COMPUTERNAME)..." "INFO"
        try {
            $testResult = Test-ADServiceAccount -Identity $name -ErrorAction Stop
            $localTestResult = if ($testResult) { "TRUE (retrieval succeeded on this host)" } else { "FALSE (retrieval failed — check delegation, KDS convergence, or Install-ADServiceAccount state)" }
            if (-not $testResult) { $findings.Add("LOCAL_RETRIEVAL_FAILED") }
        } catch {
            $localTestResult = "ERROR: $($_.Exception.Message) (gMSA likely never installed locally — run Install-ADServiceAccount)"
            $findings.Add("LOCAL_TEST_ERRORED")
        }

        try {
            $since = (Get-Date).AddHours(-$EventLogLookbackHours)
            $events = Get-WinEvent -LogName "Microsoft-Windows-GroupManagedServiceAccounts/Operational" `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.TimeCreated -ge $since }
            $errorEvents = @($events | Where-Object { $_.LevelDisplayName -eq "Error" })
            if ($errorEvents.Count -gt 0) {
                $eventLogSummary = "$($errorEvents.Count) ERROR event(s) in last $EventLogLookbackHours h (most recent: $($errorEvents[0].TimeCreated))"
                $findings.Add("GMSA_EVENTLOG_ERRORS_FOUND")
            } else {
                $eventLogSummary = "No error events in last $EventLogLookbackHours h ($($events.Count) total events)"
            }
        } catch {
            $eventLogSummary = "Could not read GMSA Operational log: $($_.Exception.Message)"
        }
    }

    $results.Add([PSCustomObject]@{
        gMSAName             = $name
        Enabled              = $gmsa.Enabled
        DNSHostName          = $gmsa.DNSHostName
        WhenCreated          = $gmsa.whenCreated
        KdsRootKeyState      = $kdsFlag
        DelegationSummary    = ($delegationDetail -join "; ")
        ResolvedHostCount    = $resolvedHostCount
        PasswordIntervalDays = $intervalDisplay
        LocalTestResult      = $localTestResult
        EventLogSummary      = $eventLogSummary
        Findings             = ($findings -join ", ")
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table gMSAName, Enabled, ResolvedHostCount, KdsRootKeyState, Findings -AutoSize

$flaggedCount = @($results | Where-Object { $_.Findings -ne "OK" }).Count
if ($flaggedCount -gt 0) {
    Write-Status "$flaggedCount of $($results.Count) gMSA(s) have one or more findings. Review the Findings column." "WARN"
} else {
    Write-Status "All $($results.Count) gMSA(s) audited cleanly." "OK"
}

$csvPath = Join-Path -Path $OutputPath -ChildPath "GMSAHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
