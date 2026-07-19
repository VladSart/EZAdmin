<#
.SYNOPSIS
    Read-only health check for Microsoft Entra Cloud Sync — local agent state plus optional cloud-side job/agent status.

.DESCRIPTION
    Run on a Microsoft Entra provisioning agent server to assess Cloud Sync health end to end:
      - Local agent services (Microsoft Entra Provisioning Agent + Agent Updater) running state
      - Host OS support check, including the documented Windows Server 2025 KB5070773 requirement
      - Prerequisite checks: .NET Framework 4.7.1+, TLS 1.2 registry state, PowerShell execution policy,
        Windows Credential Manager (VaultSvc) service state
      - gMSA presence and which servers are authorized to retrieve its password
      - Outbound network reachability to the core Cloud Sync / Service Bus / registration endpoints
      - Recent agent trace log presence (staleness check)
      - Optional cloud-side check via the AADCloudSyncTools module: agent health and job/quarantine
        status, surfaced with the same friendly flags used elsewhere in this repo's Entra scripts

    Does NOT make any changes, clear quarantine, repair accounts, or alter scoping. Read-only.

.PARAMETER SkipCloudCheck
    Skip the AADCloudSyncTools-based cloud agent/job status check (useful if you only want the local
    host health check, or if interactive sign-in isn't available in this session). Default: $false.

.PARAMETER CheckGpad
    Also test LDAP (389) and Global Catalog (3268) reachability to the nearest domain controller —
    only relevant if Group Provisioning to Active Directory (the reverse Entra-to-AD flow) is in use.
    Default: $false.

.PARAMETER ExportPath
    Path for the CSV export of flagged findings. Default: $env:TEMP\CloudSyncHealth_<timestamp>.csv

.EXAMPLE
    .\Get-CloudSyncHealth.ps1
    # Local host health check + cloud agent/job status, console summary + CSV export

.EXAMPLE
    .\Get-CloudSyncHealth.ps1 -SkipCloudCheck
    # Local-only check — no sign-in prompt, useful for a fast triage pass

.EXAMPLE
    .\Get-CloudSyncHealth.ps1 -CheckGpad -ExportPath "C:\Reports\CloudSync.csv"
    # Full check including reverse Group-Provisioning-to-AD-DS network prerequisites

.NOTES
    Requires: run on a server with the Microsoft Entra provisioning agent installed for the local checks.
              AADCloudSyncTools module (auto-installed if missing) for the cloud-side check.
    Run as:   Local admin on the agent server. Cloud check requires a Hybrid Identity Administrator sign-in.
    Safe/Unsafe: READ-ONLY — makes no changes, clears no quarantine, repairs nothing.
    Tested against: Microsoft Entra Cloud Sync provisioning agent, current as of mid-2026.
#>

[CmdletBinding()]
param(
    [switch] $SkipCloudCheck,
    [switch] $CheckGpad,
    [string] $ExportPath = "$env:TEMP\CloudSyncHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region --- Helpers ---

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

$findings = @()
function Add-Finding {
    param([string]$Area, [string]$Flag, [string]$Detail, [string]$Severity = "WARN")
    $script:findings += [PSCustomObject]@{
        Area     = $Area
        Flag     = $Flag
        Detail   = $Detail
        Severity = $Severity
        Time     = Get-Date
    }
    Write-Status "$Area — $Flag`: $Detail" -Status $Severity
}

#endregion

Write-Status "Microsoft Entra Cloud Sync Health Check" -Status "HEADER"
Write-Status "Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

#region --- Local Agent Service State ---

Write-Status "`n=== Agent Services ===" -Status "HEADER"
$serviceNames = @("AADConnectProvisioningAgent", "AADConnectProvisioningAgentUpdater")
$servicesFound = @()

foreach ($svcName in $serviceNames) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Finding "AgentService" "SERVICE_NOT_FOUND" "$svcName is not installed on this host — this may not be a provisioning agent server." "ERROR"
        continue
    }
    $servicesFound += $svc
    Write-Host "  $($svc.DisplayName): $($svc.Status) / $($svc.StartType)"
    if ($svc.Status -ne "Running") {
        Add-Finding "AgentService" "SERVICE_STOPPED" "$svcName is $($svc.Status) — Cloud Sync will not function until it's running." "ERROR"
    }
}

#endregion

#region --- Host OS Support Check ---

Write-Status "`n=== Host OS Support ===" -Status "HEADER"
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "  Caption : $($os.Caption)"
    Write-Host "  Build   : $($os.BuildNumber)"

    $buildNum = [int]$os.BuildNumber
    if ($buildNum -ge 26100) {
        # Windows Server 2025 family
        $kb = Get-HotFix -Id "KB5070773" -ErrorAction SilentlyContinue
        if (-not $kb) {
            Add-Finding "HostOS" "SERVER2025_MISSING_KB" "Host appears to be Windows Server 2025 without KB5070773 (Oct 20, 2025) or later — Cloud Sync is documented as unsupported/problematic on this build until that update is applied and the server rebooted." "ERROR"
        } else {
            Write-Status "  Windows Server 2025 with required KB5070773+ confirmed." -Status "OK"
        }
    } elseif ($buildNum -lt 14393) {
        Add-Finding "HostOS" "UNSUPPORTED_OS" "OS build $buildNum is older than Windows Server 2016 — not a supported Cloud Sync agent host." "ERROR"
    } else {
        Write-Status "  OS build within the supported Server 2016/2019/2022 range." -Status "OK"
    }
} catch {
    Add-Finding "HostOS" "OS_CHECK_FAILED" "Could not query OS info: $_" "WARN"
}

#endregion

#region --- Prerequisite Checks ---

Write-Status "`n=== Prerequisites ===" -Status "HEADER"

# .NET Framework 4.7.1+ (release 461308+)
try {
    $netRelease = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
    if ($null -eq $netRelease) {
        Add-Finding "Prereq" "NET_VERSION_UNKNOWN" ".NET Framework 4.x release key not found — cannot confirm 4.7.1+ requirement." "WARN"
    } elseif ($netRelease -lt 461308) {
        Add-Finding "Prereq" "NET_TOO_OLD" ".NET Framework release $netRelease is below 461308 (4.7.1) — minimum required version." "ERROR"
    } else {
        Write-Status "  .NET Framework release $netRelease meets the 4.7.1+ requirement." -Status "OK"
    }
} catch {
    Add-Finding "Prereq" "NET_CHECK_FAILED" "Could not check .NET Framework version: $_" "WARN"
}

# TLS 1.2
$tlsClientPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"
$tlsServerPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
$tlsOk = $true
foreach ($p in @($tlsClientPath, $tlsServerPath)) {
    if (Test-Path $p) {
        $enabled = (Get-ItemProperty $p -ErrorAction SilentlyContinue).Enabled
        if ($enabled -ne 1) { $tlsOk = $false }
    } else {
        $tlsOk = $false
    }
}
if (-not $tlsOk) {
    Add-Finding "Prereq" "TLS12_NOT_CONFIRMED" "TLS 1.2 is not explicitly enabled via registry on this host — required for agent registration and Service Bus connectivity." "WARN"
} else {
    Write-Status "  TLS 1.2 explicitly enabled (Client + Server)." -Status "OK"
}

# PowerShell execution policy
$policies = Get-ExecutionPolicy -List
$machinePolicy = ($policies | Where-Object { $_.Scope -eq "LocalMachine" }).ExecutionPolicy
$userPolicy    = ($policies | Where-Object { $_.Scope -eq "CurrentUser" }).ExecutionPolicy
foreach ($pair in @(@{Scope="LocalMachine";Val=$machinePolicy}, @{Scope="CurrentUser";Val=$userPolicy})) {
    if ($pair.Val -eq "Unrestricted") {
        Add-Finding "Prereq" "EXECPOLICY_UNRESTRICTED" "$($pair.Scope) execution policy is Unrestricted — Cloud Sync requires Undefined or RemoteSigned; Unrestricted is documented to break agent registration scripts." "WARN"
    }
}
Write-Host "  Execution policy — LocalMachine: $machinePolicy, CurrentUser: $userPolicy"

# Credential Manager (VaultSvc) must not be disabled
$vaultSvc = Get-Service -Name "VaultSvc" -ErrorAction SilentlyContinue
if ($vaultSvc) {
    Write-Host "  VaultSvc (Credential Manager): $($vaultSvc.Status) / $($vaultSvc.StartType)"
    if ($vaultSvc.StartType -eq "Disabled") {
        Add-Finding "Prereq" "VAULTSVC_DISABLED" "Windows Credential Manager service (VaultSvc) is disabled — this prevents the provisioning agent from installing/functioning correctly." "ERROR"
    }
} else {
    Add-Finding "Prereq" "VAULTSVC_NOT_FOUND" "VaultSvc service not found on this host." "WARN"
}

#endregion

#region --- gMSA Check ---

Write-Status "`n=== Group Managed Service Account ===" -Status "HEADER"
try {
    if (Get-Command Get-ADServiceAccount -ErrorAction SilentlyContinue) {
        $gmsa = Get-ADServiceAccount -Filter "Name -like 'provAgentgMSA*'" -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction SilentlyContinue
        if ($gmsa) {
            foreach ($g in $gmsa) {
                Write-Host "  gMSA: $($g.Name)"
                $allowed = $g.PrincipalsAllowedToRetrieveManagedPassword
                if (-not $allowed -or $allowed.Count -eq 0) {
                    Add-Finding "gMSA" "GMSA_NO_ALLOWED_HOSTS" "$($g.Name) has no hosts listed in PrincipalsAllowedToRetrieveManagedPassword — no server can retrieve its password." "ERROR"
                } else {
                    Write-Host "    Allowed hosts: $($allowed -join ', ')"
                    if ($allowed.Count -lt 2) {
                        Add-Finding "gMSA" "GMSA_SINGLE_HOST" "$($g.Name) is only retrievable by 1 host — Microsoft recommends 3 active agents for HA; this gMSA can't support multi-agent failover as configured." "WARN"
                    }
                }
            }
        } else {
            Add-Finding "gMSA" "GMSA_NOT_FOUND" "No gMSA matching 'provAgentgMSA*' found — either a custom gMSA name is in use, or the agent hasn't completed gMSA-based setup." "WARN"
        }
    } else {
        Write-Status "  ActiveDirectory PowerShell module not available on this host — skipping gMSA check (run from a DC or a host with RSAT-AD-PowerShell)." -Status "WARN"
    }
} catch {
    Add-Finding "gMSA" "GMSA_CHECK_FAILED" "Could not query gMSA: $_" "WARN"
}

#endregion

#region --- Network Reachability ---

Write-Status "`n=== Network Reachability ===" -Status "HEADER"
$endpoints = @(
    @{ Name = "login.windows.net"; Port = 443 },
    @{ Name = "management.azure.com"; Port = 443 },
    @{ Name = "enterpriseregistration.windows.net"; Port = 443 },
    @{ Name = "ctldl.windowsupdate.com"; Port = 80 }
)
foreach ($ep in $endpoints) {
    try {
        $result = Test-NetConnection -ComputerName $ep.Name -Port $ep.Port -WarningAction SilentlyContinue
        Write-Host "  $($ep.Name):$($ep.Port) — $($result.TcpTestSucceeded)"
        if (-not $result.TcpTestSucceeded) {
            Add-Finding "Network" "ENDPOINT_UNREACHABLE" "$($ep.Name):$($ep.Port) is not reachable — check firewall/proxy rules for this required endpoint." "ERROR"
        }
    } catch {
        Add-Finding "Network" "ENDPOINT_TEST_FAILED" "Could not test $($ep.Name):$($ep.Port): $_" "WARN"
    }
}

if ($CheckGpad) {
    Write-Status "`n=== GPAD (Group Provisioning to AD DS) Network Check ===" -Status "HEADER"
    try {
        $dc = (Get-ADDomainController -Discover -ErrorAction Stop).HostName[0]
        foreach ($gpadPort in @(389, 3268)) {
            $r = Test-NetConnection -ComputerName $dc -Port $gpadPort -WarningAction SilentlyContinue
            Write-Host "  $dc`:$gpadPort — $($r.TcpTestSucceeded)"
            if (-not $r.TcpTestSucceeded) {
                Add-Finding "GPAD" "DC_PORT_UNREACHABLE" "$dc`:$gpadPort unreachable — required for Group Provisioning to AD DS (LDAP=389, Global Catalog=3268)." "ERROR"
            }
        }
    } catch {
        Add-Finding "GPAD" "DC_DISCOVERY_FAILED" "Could not discover a domain controller to test against: $_" "WARN"
    }
}

#endregion

#region --- Trace Log Staleness ---

Write-Status "`n=== Agent Trace Logs ===" -Status "HEADER"
$tracePath = "C:\ProgramData\Microsoft\Azure AD Connect Provisioning Agent\Trace"
if (Test-Path $tracePath) {
    $recentLogs = Get-ChildItem $tracePath -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($recentLogs) {
        $newest = $recentLogs | Select-Object -First 1
        Write-Host "  Newest trace file: $($newest.Name) ($($newest.LastWriteTime))"
        if ($newest.LastWriteTime -lt (Get-Date).AddDays(-2)) {
            Add-Finding "TraceLogs" "TRACE_LOGS_STALE" "Newest trace log is older than 2 days ($($newest.LastWriteTime)) — the agent may not be actively processing cycles." "WARN"
        }
    } else {
        Add-Finding "TraceLogs" "TRACE_LOGS_EMPTY" "Trace log folder exists but is empty." "WARN"
    }
} else {
    Add-Finding "TraceLogs" "TRACE_PATH_NOT_FOUND" "Trace log folder not found at the expected path — confirm this is a provisioning agent host." "WARN"
}

#endregion

#region --- Optional Cloud-Side Agent/Job Check ---

if (-not $SkipCloudCheck) {
    Write-Status "`n=== Cloud-Side Agent and Job Status ===" -Status "HEADER"
    try {
        if (-not (Get-Module -ListAvailable -Name AADCloudSyncTools)) {
            Write-Status "  AADCloudSyncTools module not found — installing (requires internet + admin)..." -Status "INFO"
            Install-Module -Name AADCloudSyncTools -Scope AllUsers -Force -ErrorAction Stop
        }
        Import-Module AADCloudSyncTools -ErrorAction Stop
        Connect-AADCloudSyncTools -ErrorAction Stop

        $agents = Get-AADCloudSyncToolsAgent -ErrorAction SilentlyContinue
        if ($agents) {
            foreach ($a in $agents) {
                Write-Host "  Agent: $($a.MachineName)  Status: $($a.Status)"
                if ($a.Status -notmatch "Active|Healthy") {
                    Add-Finding "CloudAgent" "AGENT_NOT_ACTIVE" "Agent $($a.MachineName) is not reporting Active/Healthy in the cloud — status: $($a.Status)." "ERROR"
                }
            }
            if (@($agents).Count -lt 2) {
                Add-Finding "CloudAgent" "SINGLE_AGENT_NO_HA" "Only $(@($agents).Count) agent registered for this tenant — Microsoft recommends 3 active agents for high availability; a single agent is a single point of failure." "WARN"
            }
        } else {
            Add-Finding "CloudAgent" "NO_AGENTS_RETURNED" "No agents returned by Get-AADCloudSyncToolsAgent — confirm sign-in succeeded and at least one agent is registered." "ERROR"
        }

        $jobs = Get-AADCloudSyncToolsJob -ErrorAction SilentlyContinue
        if ($jobs) {
            foreach ($j in $jobs) {
                Write-Host "  Job: $($j.Id)  Status: $($j.Status)"
                if ($j.Status -match "Quarantine") {
                    Add-Finding "CloudJob" "JOB_QUARANTINED" "Job $($j.Id) is in quarantine — check the specific error code before clearing (see CloudSync-A.md Playbook 2)." "ERROR"
                }
            }
        } else {
            Add-Finding "CloudJob" "NO_JOBS_RETURNED" "No sync jobs returned — confirm at least one Cloud Sync configuration exists for this tenant." "WARN"
        }
    } catch {
        Add-Finding "CloudCheck" "CLOUD_CHECK_FAILED" "Could not complete the cloud-side check (sign-in, module install, or Graph call failed): $_" "WARN"
    }
} else {
    Write-Status "`nSkipping cloud-side agent/job check (-SkipCloudCheck specified)." -Status "INFO"
}

#endregion

#region --- Export and Summary ---

Write-Status "`n=== Summary ===" -Status "HEADER"
$errorCount = ($findings | Where-Object { $_.Severity -eq "ERROR" }).Count
$warnCount  = ($findings | Where-Object { $_.Severity -eq "WARN" }).Count
Write-Host "  Findings: $errorCount error(s), $warnCount warning(s)"

if ($findings.Count -gt 0) {
    $findings | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "Findings exported to: $ExportPath" -Status "OK"
} else {
    [PSCustomObject]@{ Area = "ALL"; Flag = "NO_FINDINGS"; Detail = "No issues detected"; Severity = "OK"; Time = Get-Date } |
        Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "No issues detected. Summary exported to: $ExportPath" -Status "OK"
}

Write-Status "Done." -Status "OK"

#endregion
