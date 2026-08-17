<#
.SYNOPSIS
    Read-only audit of AD LDS (Active Directory Lightweight Directory Services) instances
    on the local server: service health, ports, partitions, replication status (if part of
    a configuration set), and bind-redirection (userProxy) object health.

.DESCRIPTION
    Discovers every ADAM_<instanceName> service on the local machine, then for each running
    instance:
      - Reports service status/start type
      - Binds via -Server "localhost:<port>" and reads RootDSE for naming contexts
      - Runs repadmin /showrepl against the instance to surface replication errors, if the
        instance is part of a configuration set (harmless no-op output if it isn't)
      - Optionally enumerates userProxy bind-redirection objects and, where possible,
        resolves and reports the referenced AD DS account's Enabled/LockedOut/PasswordExpired
        state (requires network reachability + read access to the referenced domain; failures
        to resolve are reported as findings, not treated as script errors)
    This script makes NO changes to any AD LDS instance, AD DS object, or service state.
    It only starts a stopped service if -IncludeStoppedInstances is NOT used to skip it
    (default: stopped instances are reported, not started).

.PARAMETER InstanceName
    Optional. Limit the audit to one instance (matches the service's ADAM_<name> suffix).
    If omitted, every ADAM_* service on the local machine is audited.

.PARAMETER IncludeProxyCheck
    Switch. If set, enumerates userProxy objects in each instance's application partitions
    and attempts to resolve/report the referenced AD DS account's status. Requires the
    ActiveDirectory module to have connectivity to the referenced domain(s); a proxy object
    whose SID cannot be resolved is reported as a finding (STALE_PROXY_SID), not a script error.

.PARAMETER OutputCsv
    Optional path to export a flat CSV of findings. If omitted, results are only written to
    the host and returned as objects on the pipeline.

.EXAMPLE
    .\Get-ADLDSInstanceAudit.ps1

    Audits every AD LDS instance on the local machine, reports service/port/replication
    health to the host.

.EXAMPLE
    .\Get-ADLDSInstanceAudit.ps1 -InstanceName "Portal" -IncludeProxyCheck -OutputCsv .\adlds-audit.csv

    Audits only the "Portal" instance, including bind-redirection proxy object health,
    exporting findings to CSV.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT: AD DS and AD LDS Tools), dsdbutil.exe
    and repadmin.exe available on PATH (both ship with the AD LDS role/RSAT tools).
    Run-as: local administrator on the box hosting the instance(s); domain read rights on
    any domain referenced by -IncludeProxyCheck.
    Safe/unsafe: fully read-only. Does not start/stop services, does not modify AD LDS or
    AD DS objects, does not change any service account or port configuration.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InstanceName,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeProxyCheck,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv
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
    Write-Status "ActiveDirectory module not available. Install RSAT: AD DS and AD LDS Tools, or run from a server with the AD LDS role." "ERROR"
    throw
}

$dsdbutilAvailable = [bool](Get-Command dsdbutil.exe -ErrorAction SilentlyContinue)
$repadminAvailable = [bool](Get-Command repadmin.exe -ErrorAction SilentlyContinue)

if (-not $dsdbutilAvailable) {
    Write-Status "dsdbutil.exe not found on PATH — instance port/partition listing will rely on Get-Service + RootDSE binds only." "WARN"
}
if (-not $repadminAvailable) {
    Write-Status "repadmin.exe not found on PATH — replication health checks will be skipped." "WARN"
}

# ---------------------------------------------------------------------------
# Detect
# ---------------------------------------------------------------------------
$serviceFilter = if ($InstanceName) { "ADAM_$InstanceName" } else { "ADAM_*" }
$instanceServices = Get-Service -Name $serviceFilter -ErrorAction SilentlyContinue

if (-not $instanceServices) {
    Write-Status "No AD LDS instance services found matching '$serviceFilter' on this server." "WARN"
    return
}

$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [string]$InstanceNameLocal,
        [string]$Category,
        [string]$Status,
        [string]$Detail
    )
    $findings.Add([pscustomobject]@{
        Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Instance     = $InstanceNameLocal
        Category     = $Category
        Status       = $Status
        Detail       = $Detail
    })
}

# ---------------------------------------------------------------------------
# Execute — per instance
# ---------------------------------------------------------------------------
foreach ($svc in $instanceServices) {
    $name = $svc.Name -replace '^ADAM_', ''
    Write-Status "=== Instance: $name ===" "INFO"

    Add-Finding -InstanceNameLocal $name -Category "Service" -Status $svc.Status -Detail "StartType: $($svc.StartType)"

    if ($svc.Status -ne 'Running') {
        Write-Status "  Service is not running (Status: $($svc.Status)) — skipping live checks for this instance." "WARN"
        continue
    }

    # Determine port via dsdbutil if available, else prompt the operator to supply it
    $ldapPort = $null
    if ($dsdbutilAvailable) {
        try {
            $listOutput = & dsdbutil.exe "list instances" q q 2>&1 | Out-String
            $match = [regex]::Match($listOutput, "(?i)$name.*?Port\s*:\s*(\d+)")
            if ($match.Success) {
                $ldapPort = $match.Groups[1].Value
            }
        } catch {
            Write-Status "  dsdbutil list instances failed: $($_.Exception.Message)" "WARN"
        }
    }

    if (-not $ldapPort) {
        Write-Status "  Could not auto-determine LDAP port for instance '$name' from dsdbutil output. Skipping bind-based checks for this instance — re-run with the port confirmed manually if needed." "WARN"
        Add-Finding -InstanceNameLocal $name -Category "Port" -Status "UNKNOWN" -Detail "Auto-detection failed; bind-based checks skipped"
        continue
    }

    Add-Finding -InstanceNameLocal $name -Category "Port" -Status "OK" -Detail "LDAP port: $ldapPort"

    # RootDSE bind
    try {
        $rootDse = Get-ADRootDSE -Server "localhost:$ldapPort" -ErrorAction Stop
        $partitions = $rootDse.namingContexts -join "; "
        Write-Status "  RootDSE bind OK. Partitions: $partitions" "OK"
        Add-Finding -InstanceNameLocal $name -Category "RootDSE Bind" -Status "OK" -Detail $partitions
    } catch {
        Write-Status "  RootDSE bind FAILED: $($_.Exception.Message)" "ERROR"
        Add-Finding -InstanceNameLocal $name -Category "RootDSE Bind" -Status "FAILED" -Detail $_.Exception.Message
        continue
    }

    # Replication health (no-op / harmless if not part of a configuration set)
    if ($repadminAvailable) {
        try {
            $replOutput = & repadmin.exe /showrepl "localhost:$ldapPort" 2>&1 | Out-String
            if ($replOutput -match "(?i)fail|error") {
                Write-Status "  repadmin /showrepl reported possible errors — review detail." "WARN"
                Add-Finding -InstanceNameLocal $name -Category "Replication" -Status "WARN" -Detail ($replOutput.Trim() -replace '\s+', ' ')
            } else {
                Write-Status "  repadmin /showrepl: no errors detected." "OK"
                Add-Finding -InstanceNameLocal $name -Category "Replication" -Status "OK" -Detail "No errors detected (or not part of a configuration set)"
            }
        } catch {
            Write-Status "  repadmin /showrepl failed to run: $($_.Exception.Message)" "WARN"
            Add-Finding -InstanceNameLocal $name -Category "Replication" -Status "SKIPPED" -Detail $_.Exception.Message
        }
    }

    # Bind-redirection (userProxy) object health
    if ($IncludeProxyCheck) {
        try {
            $proxyObjects = Get-ADObject -Server "localhost:$ldapPort" -Filter "objectClass -eq 'userProxy'" -Properties objectSid -ErrorAction Stop
            if (-not $proxyObjects) {
                Write-Status "  No userProxy objects found in this instance." "INFO"
                Add-Finding -InstanceNameLocal $name -Category "Proxy Objects" -Status "OK" -Detail "None found"
            } else {
                foreach ($proxy in $proxyObjects) {
                    if (-not $proxy.objectSid) {
                        Add-Finding -InstanceNameLocal $name -Category "Proxy Object" -Status "WARN" -Detail "$($proxy.DistinguishedName) has no objectSid set"
                        continue
                    }
                    try {
                        $sidObj = New-Object System.Security.Principal.SecurityIdentifier($proxy.objectSid, 0)
                        $adAccount = Get-ADObject -Filter "objectSid -eq '$sidObj'" -Properties Enabled, LockedOut, PasswordExpired -ErrorAction Stop
                        if (-not $adAccount) {
                            Write-Status "  STALE PROXY: $($proxy.DistinguishedName) -> SID $sidObj does not resolve to any AD DS account." "WARN"
                            Add-Finding -InstanceNameLocal $name -Category "Proxy Object" -Status "STALE_PROXY_SID" -Detail "$($proxy.DistinguishedName) -> $sidObj (unresolvable)"
                        } else {
                            $detail = "$($proxy.DistinguishedName) -> $($adAccount.DistinguishedName); Enabled=$($adAccount.Enabled) LockedOut=$($adAccount.LockedOut) PasswordExpired=$($adAccount.PasswordExpired)"
                            $status = if ($adAccount.Enabled -eq $false -or $adAccount.LockedOut -eq $true) { "WARN" } else { "OK" }
                            Add-Finding -InstanceNameLocal $name -Category "Proxy Object" -Status $status -Detail $detail
                        }
                    } catch {
                        Add-Finding -InstanceNameLocal $name -Category "Proxy Object" -Status "UNRESOLVABLE" -Detail "$($proxy.DistinguishedName) -> SID resolution/lookup failed: $($_.Exception.Message)"
                    }
                }
            }
        } catch {
            Write-Status "  Could not enumerate userProxy objects: $($_.Exception.Message)" "WARN"
            Add-Finding -InstanceNameLocal $name -Category "Proxy Objects" -Status "SKIPPED" -Detail $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "=== Summary ===" "INFO"
$findings | Format-Table -AutoSize -Wrap

$warnCount  = ($findings | Where-Object { $_.Status -in @("WARN","FAILED","STALE_PROXY_SID") }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) need review." "WARN"
} else {
    Write-Status "No warnings or failures detected across audited instances." "OK"
}

if ($OutputCsv) {
    $findings | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Status "Findings exported to $OutputCsv" "OK"
}

return $findings
