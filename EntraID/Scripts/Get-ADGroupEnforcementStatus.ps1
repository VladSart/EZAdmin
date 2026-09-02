<#
.SYNOPSIS
    Reports Microsoft Entra Cloud Sync AD group enforcement (preview) status for the local domain controller.

.DESCRIPTION
    Read-only diagnostic for the AD group enforcement preview feature (SOA-Policies / msDS-ObjectSoa).
    Checks, on the local domain controller:
      - whether the enforcement code is present and at/above the documented minimum ntdsai.dll version
      - whether the CN=SOA-Policies / CN=CloudSyncSOAPolicy container and policy object exist
      - the number of authorized break-glass SIDs configured in msDS-Settings (and resolves them to names
        where possible)
      - every AD group currently marked for enforcement (msDS-ObjectSoa = "Cloud"), with basic membership
        counts
      - recent Directory Service event log entries that reference SOA/enforcement (Audit-mode telemetry)

    This script does NOT change policy mode, does NOT mark or unmark any group, and does NOT modify
    msDS-Settings. Use Set-CloudSyncSOAPolicy.ps1 (AzureAD/EntraIDGovernance GitHub repo) for write
    operations. This script also cannot determine policy MODE (Enforced vs. Audit) with full confidence
    from directory reads alone in this preview -- that is intentionally left to the official
    Check-CloudSyncSOAPolicy.ps1 script, and this script says so explicitly in its output rather than
    guessing.

    Must be run directly on a domain controller (or a management host with the ActiveDirectory module
    and connectivity to one), since the objects being read live in the System container of AD, not in
    Entra ID / Microsoft Graph.

.PARAMETER OutputPath
    Folder to write the CSV export of marked groups to. Defaults to the current directory.

.PARAMETER EventLogHours
    How many hours back to search the Directory Service event log for SOA/enforcement-related entries.
    Defaults to 24.

.EXAMPLE
    .\Get-ADGroupEnforcementStatus.ps1

    Runs a full status check against the local DC using default settings.

.EXAMPLE
    .\Get-ADGroupEnforcementStatus.ps1 -EventLogHours 168 -OutputPath C:\Evidence

    Runs the check looking back 7 days in the event log and writes the CSV export to C:\Evidence.

.NOTES
    Requires: ActiveDirectory PowerShell module, run on or against a domain controller.
    Run-as: Any account with read access to AD and the local Directory Service event log is sufficient;
            no elevated or Domain Admin rights are required for this read-only script.
    Safe/unsafe: Fully read-only. Safe to run in production at any time.
    Preview caveat: this feature (and therefore this script's assumptions about object paths and
            attribute names) is documented by Microsoft as PREVIEW and may change without notice.
            Re-validate against current Microsoft Learn documentation periodically.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ".",
    [int]$EventLogHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "AD Group Enforcement (Cloud Sync preview) status check starting..."

try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory PowerShell module not available. Run this on a domain controller or a host with RSAT-AD-PowerShell installed." -Status "ERROR"
    throw
}

try {
    $domain = Get-ADDomain
    $domainDN = $domain.DistinguishedName
} catch {
    Write-Status "Could not query AD domain. Confirm connectivity to a domain controller and that you're running in a domain-joined context." -Status "ERROR"
    throw
}

Write-Status "Domain: $($domain.DNSRoot)  |  Local host: $env:COMPUTERNAME"

$results = [ordered]@{
    Timestamp                = (Get-Date -Format o)
    ComputerName              = $env:COMPUTERNAME
    Domain                    = $domain.DNSRoot
    NtdsaiVersion             = $null
    NtdsaiVersionMeetsMinimum = $null
    OSCaption                 = $null
    SOAPoliciesContainerExists = $false
    CloudSyncSOAPolicyExists   = $false
    AuthorizedBypassSIDCount   = 0
    MarkedGroupCount           = 0
    ModeCanBeConfirmedHere     = $false
}

# ---------------------------------------------------------------------------
# Detect: enforcement code presence and version
# ---------------------------------------------------------------------------
Write-Status "Checking ntdsai.dll version against documented minimums..."

$dllPath = "$env:SystemRoot\System32\ntdsai.dll"
if (Test-Path $dllPath) {
    $ver = (Get-Item $dllPath).VersionInfo.FileVersion
    $results.NtdsaiVersion = $ver

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $results.OSCaption = $os.Caption

        # Minimums per Microsoft Learn (2026-06 doc): 2022 = 10.0.20348.5257 ; 2025 = 10.0.26100.32995
        $parsedVer = [version]($ver -replace '[^\d\.]', '')
        if ($os.Caption -match "2025") {
            $minVer = [version]"10.0.26100.32995"
        } elseif ($os.Caption -match "2022") {
            $minVer = [version]"10.0.20348.5257"
        } else {
            $minVer = $null
        }

        if ($minVer) {
            $meetsMin = $parsedVer -ge $minVer
            $results.NtdsaiVersionMeetsMinimum = $meetsMin
            if ($meetsMin) {
                Write-Status "ntdsai.dll $ver meets documented minimum ($minVer) for $($os.Caption)." -Status "OK"
            } else {
                Write-Status "ntdsai.dll $ver is BELOW documented minimum ($minVer) for $($os.Caption). Install the latest cumulative update." -Status "WARN"
            }
        } else {
            Write-Status "OS is not Windows Server 2022 or 2025 ($($os.Caption)) -- AD group enforcement preview is not documented as supported on this OS." -Status "WARN"
            $results.NtdsaiVersionMeetsMinimum = $false
        }
    } catch {
        Write-Status "Could not determine OS version for minimum-version comparison: $($_.Exception.Message)" -Status "WARN"
    }
} else {
    Write-Status "ntdsai.dll not found at expected path -- unexpected on a domain controller. Confirm this is being run on a DC." -Status "ERROR"
}

# ---------------------------------------------------------------------------
# Detect: SOA-Policies container and CloudSyncSOAPolicy object
# ---------------------------------------------------------------------------
Write-Status "Checking for CN=SOA-Policies container..."

$soaPoliciesDN = "CN=SOA-Policies,CN=System,$domainDN"
$policyDN = "CN=CloudSyncSOAPolicy,$soaPoliciesDN"

$soaContainer = Get-ADObject -Identity $soaPoliciesDN -ErrorAction SilentlyContinue
if ($soaContainer) {
    $results.SOAPoliciesContainerExists = $true
    Write-Status "SOA-Policies container found." -Status "OK"

    $policyObj = Get-ADObject -Identity $policyDN -Properties * -ErrorAction SilentlyContinue
    if ($policyObj) {
        $results.CloudSyncSOAPolicyExists = $true
        Write-Status "CloudSyncSOAPolicy object found." -Status "OK"

        # msDS-Settings holds the authorized bypass SIDs. Attribute name/shape is preview-documented and
        # may shift -- read defensively rather than assuming a fixed property name/type.
        $bypassSids = @()
        if ($policyObj.PSObject.Properties.Name -contains 'msDS-Settings') {
            $bypassSids = @($policyObj.'msDS-Settings')
        }
        $results.AuthorizedBypassSIDCount = $bypassSids.Count

        if ($bypassSids.Count -eq 0) {
            Write-Status "msDS-Settings has ZERO entries. Per Microsoft's documented behavior, this means the policy is EFFECTIVELY OFF -- not maximally locked down. If Enforced mode was intended, add at least one break-glass SID." -Status "WARN"
        } else {
            Write-Status "msDS-Settings has $($bypassSids.Count) authorized bypass SID(s) configured." -Status "OK"
            foreach ($sid in $bypassSids) {
                try {
                    $resolved = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
                    Write-Host "    - $sid  ->  $resolved"
                } catch {
                    Write-Host "    - $sid  ->  (could not resolve to an account name)"
                }
            }
        }

        Write-Status "This script does not attempt to read policy MODE (Enforced/Audit) directly -- attribute storage for mode is not stably documented for this preview. Use the official Check-CloudSyncSOAPolicy.ps1 (AzureAD/EntraIDGovernance GitHub repo) for an authoritative mode read." -Status "WARN"
    } else {
        Write-Status "CN=CloudSyncSOAPolicy object NOT found under SOA-Policies. Enablement may be incomplete, or Set-CloudSyncSOAPolicy.ps1 has never been run." -Status "WARN"
    }
} else {
    Write-Status "SOA-Policies container NOT found on this DC. Either enforcement was never enabled here, or this is not the DC it was enabled on -- check other DCs in the domain, especially the PDCe." -Status "WARN"
}

# ---------------------------------------------------------------------------
# Enumerate marked groups
# ---------------------------------------------------------------------------
Write-Status "Enumerating groups marked for enforcement (msDS-ObjectSoa = 'Cloud')..."

$markedGroups = @()
try {
    $markedGroups = Get-ADGroup -Filter { 'msDS-ObjectSoa' -eq "Cloud" } -Properties msDS-ObjectSoa, Members -ErrorAction Stop |
        ForEach-Object {
            [pscustomobject]@{
                Name              = $_.Name
                DistinguishedName = $_.DistinguishedName
                msDSObjectSoa     = $_.'msDS-ObjectSoa'
                MemberCount       = @($_.Members).Count
            }
        }
} catch {
    Write-Status "Could not query msDS-ObjectSoa attribute -- this attribute may not exist in this AD schema version if the enforcement feature/schema extension has never been used in this forest. $($_.Exception.Message)" -Status "WARN"
}

$results.MarkedGroupCount = $markedGroups.Count
Write-Status "$($markedGroups.Count) group(s) currently marked for enforcement." -Status $(if ($markedGroups.Count -gt 0) {"OK"} else {"WARN"})

if ($markedGroups.Count -gt 0) {
    $markedGroups | Format-Table -AutoSize
}

# ---------------------------------------------------------------------------
# Recent Audit-mode event log entries
# ---------------------------------------------------------------------------
Write-Status "Checking Directory Service event log for SOA/enforcement entries in the last $EventLogHours hour(s)..."

$since = (Get-Date).AddHours(-$EventLogHours)
$events = @()
try {
    $events = Get-WinEvent -LogName "Directory Service" -ErrorAction Stop |
        Where-Object { $_.TimeCreated -ge $since -and ($_.Message -match "SOA|msDS-ObjectSoa|enforcement") } |
        Select-Object TimeCreated, Id, LevelDisplayName, Message
} catch {
    Write-Status "Could not read Directory Service event log: $($_.Exception.Message)" -Status "WARN"
}

if ($events.Count -gt 0) {
    Write-Status "$($events.Count) matching event(s) found. If policy mode is Audit, these represent unauthorized-but-allowed changes -- review each one." -Status "WARN"
    $events | Format-Table -AutoSize
} else {
    Write-Status "No matching events found in the lookback window. (Expected if mode is Enforced with no violation attempts, if Security Diagnostics logging isn't enabled, or if no unauthorized changes were attempted.)" -Status "INFO"
}

# ---------------------------------------------------------------------------
# Report + export
# ---------------------------------------------------------------------------
Write-Status "Summary:"
$results | Format-List

if ($markedGroups.Count -gt 0) {
    $csvPath = Join-Path $OutputPath "ADGroupEnforcement-MarkedGroups-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
    $markedGroups | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Status "Marked-group inventory exported to: $csvPath" -Status "OK"
}

Write-Status "Done. Remember: this script is read-only and does not confirm policy MODE with authority -- pair with Check-CloudSyncSOAPolicy.ps1 for a complete picture." -Status "INFO"
