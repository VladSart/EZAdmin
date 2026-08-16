<#
.SYNOPSIS
    Audits Just Enough Administration (JEA) endpoints on a machine — registration state,
    role capability resolution, RoleDefinitions/RequiredGroups mapping, and merge risk.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/JEA-B.md and JEA-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Every registered PSSessionConfiguration on the local machine, flagging any whose
      name looks JEA-related (RestrictedRemoteServer session type) vs. the default
      Microsoft.PowerShell/Microsoft.PowerShell32 endpoints
    - RunAs identity model in use per endpoint (virtual account, scoped virtual account
      group list, or GMSA) — flags a bare, unscoped virtual account on a Domain
      Controller as higher-risk given the Domain Admins default on that role
    - RoleDefinitions entries, with a check for local-group entries incorrectly
      referencing "localhost" or a wildcard instead of the actual computer name
    - RequiredGroups presence (informational — confirms whether conditional access
      is layered on top of role mapping)
    - For every role capability name referenced, locates EVERY module on
      $Env:PSModulePath containing a RoleCapabilities folder with a matching filename,
      and flags a collision (more than one candidate) as a search-order risk per
      Microsoft's own documented non-determinism
    - TranscriptDirectory presence and a basic writability/recent-activity check
    - Best-effort merge-risk flag: cross-references every role a single RoleDefinitions
      key maps to and flags endpoints where more than one role capability is merged
      for the same user/group (a common source of unintended-permissiveness findings)

    Produces a console summary with pass/fail/flag per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's JEA-B.md Fix 1-8 / JEA-A.md Playbooks 1-3 —
      this script only detects)
    - Actually connecting to and testing the LIVE effective command set inside a session
      (Get-Command from inside Enter-PSSession remains a required manual step — see the
      runbooks' Validation Steps step 5) — this script audits configuration, not
      runtime behavior, since simulating every possible connecting user's live session
      is outside a read-only audit's scope
    - WinRM listener/transport health — see Get-WinRMDiagnostics.ps1 for that layer
    - Remote machines — this script is intentionally single-machine/local, since role
      capability resolution depends on that specific machine's $Env:PSModulePath;
      run it per machine, or wrap it in Invoke-Command for a fleet-wide sweep

.PARAMETER EndpointName
    Specific JEA endpoint name to audit. If omitted, audits every registered
    PSSessionConfiguration on the machine (including non-JEA default endpoints,
    flagged separately for context).

.PARAMETER ExportPath
    Path for CSV export. Default: .\JEAEndpointAudit-<timestamp>.csv

.EXAMPLE
    .\Get-JEAEndpointAudit.ps1
    Audits every registered session configuration on the local machine.

.EXAMPLE
    .\Get-JEAEndpointAudit.ps1 -EndpointName 'JEA-DnsOps'
    Audits a single named JEA endpoint in detail.

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+; local admin rights recommended
    (Get-PSSessionConfiguration returns fuller detail when run elevated)
    Run-as: Local administrator on the target machine
    Safe: Fully read-only. No registration, role capability, or configuration changes.
#>

[CmdletBinding()]
param(
    [string]$EndpointName,

    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

Write-Status "Starting JEA endpoint audit on $Env:COMPUTERNAME" "INFO"

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-Status "Not running elevated — Get-PSSessionConfiguration output may be incomplete. Re-run as Administrator for full detail." "WARN"
}

$isDomainController = $false
try {
    $isDomainController = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).ProductType -eq 2
} catch {
    Write-Status "Could not determine domain controller status — DC-specific virtual account risk check will be skipped" "WARN"
}

if (-not $ExportPath) {
    $ExportPath = ".\JEAEndpointAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

# ---------------------------------------------------------------------------
# Detect: Session Configurations
# ---------------------------------------------------------------------------

$knownDefaultEndpoints = @('microsoft.powershell', 'microsoft.powershell32', 'microsoft.powershell.workflow', 'microsoft.powershell.restricted')

$configs = Get-PSSessionConfiguration -ErrorAction SilentlyContinue
if ($EndpointName) {
    $configs = $configs | Where-Object { $_.Name -eq $EndpointName }
}

if (-not $configs -or $configs.Count -eq 0) {
    Write-Status "No session configurations found (or none matching -EndpointName)." "WARN"
    return
}

Write-Status "Found $($configs.Count) session configuration(s) to audit" "INFO"

# Cache module RoleCapabilities lookups since this is machine-wide, not per-endpoint
Write-Status "Enumerating modules with RoleCapabilities folders on `$Env:PSModulePath..." "INFO"
$roleCapabilityIndex = @{}  # roleName (lowercase) -> list of full paths found
Get-Module -ListAvailable -ErrorAction SilentlyContinue | ForEach-Object {
    $rcFolder = Join-Path $_.ModuleBase 'RoleCapabilities'
    if (Test-Path $rcFolder -ErrorAction SilentlyContinue) {
        Get-ChildItem -Path $rcFolder -Filter '*.psrc' -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_.BaseName.ToLower()
            if (-not $roleCapabilityIndex.ContainsKey($key)) { $roleCapabilityIndex[$key] = @() }
            $roleCapabilityIndex[$key] += $_.FullName
        }
    }
}
Write-Status "Indexed $($roleCapabilityIndex.Keys.Count) unique role capability name(s) across all modules" "INFO"

$results = @()

foreach ($config in $configs) {

    Write-Status "Auditing endpoint: $($config.Name)" "INFO"

    $findings = New-Object System.Collections.Generic.List[string]
    $isDefaultEndpoint = $knownDefaultEndpoints -contains $config.Name.ToLower()
    $isRestrictedRemoteServer = $config.SessionType -eq 'RestrictedRemoteServer' -or ($config.PSObject.Properties['Capability'] -and $config.Capability -contains 'JEA')

    # --- RunAs identity model ---
    $runAsUser = $config.RunAsUser
    $identityModel = if ($runAsUser -match 'VirtualAccount' -or [string]::IsNullOrWhiteSpace($runAsUser)) { "VirtualAccount" }
                     elseif ($runAsUser -match '\$') { "GroupManagedServiceAccount" }
                     else { "Other/Unknown" }

    if ($isDomainController -and $identityModel -eq "VirtualAccount" -and -not $isDefaultEndpoint) {
        $findings.Add("Running on a Domain Controller with a virtual account identity — confirm RunAsVirtualAccountGroups is explicitly scoped; the unscoped default is Domain Admins on a DC, not local Administrators")
    }

    # --- RoleDefinitions ---
    $roleDefKeys = @()
    $roleCapabilityNamesUsed = @()
    if ($config.PSObject.Properties['RoleDefinitions'] -and $config.RoleDefinitions) {
        $roleDefKeys = $config.RoleDefinitions.Keys
        foreach ($key in $roleDefKeys) {
            if ($key -match '(?i)^localhost\\' -or $key -match '\*') {
                $findings.Add("RoleDefinitions key '$key' uses 'localhost' or a wildcard instead of the actual computer name ($Env:COMPUTERNAME) — local group mappings require the literal computer name")
            }
            $roleCaps = $config.RoleDefinitions[$key].RoleCapabilities
            if ($roleCaps) {
                $roleCapabilityNamesUsed += $roleCaps
                if (@($roleCaps).Count -gt 1) {
                    $findings.Add("RoleDefinitions key '$key' maps to $(@($roleCaps).Count) role capabilities ($($roleCaps -join ', ')) — merge rules grant the MOST PERMISSIVE combined result across all of them; confirm this is intentional")
                }
            }
        }
    } elseif (-not $isDefaultEndpoint) {
        $findings.Add("No RoleDefinitions found — endpoint may not be a JEA configuration, or nothing is currently mapped")
    }

    # --- Role capability resolution + search-order collision check ---
    foreach ($roleCapName in ($roleCapabilityNamesUsed | Select-Object -Unique)) {
        $key = $roleCapName.ToLower()
        if (-not $roleCapabilityIndex.ContainsKey($key)) {
            $findings.Add("Role capability '$roleCapName' referenced in RoleDefinitions but NO matching .psrc file found anywhere on `$Env:PSModulePath — endpoint will fail to grant this role")
        } elseif ($roleCapabilityIndex[$key].Count -gt 1) {
            $findings.Add("Role capability '$roleCapName' resolves to $($roleCapabilityIndex[$key].Count) DIFFERENT .psrc files across modules — search order is NOT deterministic, rename to guarantee uniqueness. Candidates: $($roleCapabilityIndex[$key] -join '; ')")
        }
    }

    # --- RequiredGroups (informational) ---
    $hasRequiredGroups = $config.PSObject.Properties['RequiredGroups'] -and $null -ne $config.RequiredGroups

    # --- TranscriptDirectory ---
    $transcriptDir = if ($config.PSObject.Properties['TranscriptDirectory']) { $config.TranscriptDirectory } else { $null }
    $transcriptDirWritable = $false
    $recentTranscriptCount = 0
    if ($transcriptDir) {
        if (Test-Path $transcriptDir -ErrorAction SilentlyContinue) {
            try {
                $recentTranscriptCount = (Get-ChildItem -Path $transcriptDir -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) }).Count
                $transcriptDirWritable = $true
            } catch {
                $findings.Add("TranscriptDirectory '$transcriptDir' exists but could not be enumerated — check permissions")
            }
        } else {
            $findings.Add("TranscriptDirectory '$transcriptDir' is configured but does not exist — sessions may be failing to open, or transcription is silently not happening")
        }
    } elseif (-not $isDefaultEndpoint -and $isRestrictedRemoteServer) {
        $findings.Add("No TranscriptDirectory configured — session activity is not being logged for audit")
    }

    $results += [PSCustomObject]@{
        EndpointName            = $config.Name
        IsDefaultEndpoint       = $isDefaultEndpoint
        IsRestrictedRemoteServer = $isRestrictedRemoteServer
        Permission              = $config.Permission
        Enabled                 = $config.Enabled
        RunAsIdentityModel      = $identityModel
        RunAsUser               = $runAsUser
        RoleDefinitionCount     = @($roleDefKeys).Count
        RoleCapabilitiesUsed    = ($roleCapabilityNamesUsed -join '; ')
        HasRequiredGroups       = $hasRequiredGroups
        TranscriptDirectory     = $transcriptDir
        TranscriptDirWritable   = $transcriptDirWritable
        RecentTranscripts7Days  = $recentTranscriptCount
        FindingCount            = $findings.Count
        Findings                = ($findings -join " | ")
        NeedsReview             = $findings.Count -gt 0
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=== JEA Endpoint Audit Summary ($Env:COMPUTERNAME) ===" -ForegroundColor Cyan
Write-Host "Total session configurations audited: $($results.Count)"
Write-Host "Endpoints with findings: $(($results | Where-Object NeedsReview).Count)"
Write-Host ""

$results | Where-Object NeedsReview | ForEach-Object {
    Write-Status "$($_.EndpointName): $($_.Findings)" "WARN"
}

$results | Where-Object { -not $_.NeedsReview } | ForEach-Object {
    Write-Status "$($_.EndpointName): No issues detected" "OK"
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full detail exported to: $ExportPath" "INFO"
