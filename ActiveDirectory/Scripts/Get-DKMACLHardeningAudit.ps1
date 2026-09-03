<#
.SYNOPSIS
    Audits an AD FS farm's Distributed Key Manager (DKM) container ACL against the
    CVE-2026-56155 secure baseline, and reports patch level, detection events, and
    remediation opt-in state.

.DESCRIPTION
    Read-only diagnostic for the AD FS DKM container ACL hardening rollout (KB5121391).
    Covers:
      - Windows update level relative to the July 14, 2026 (Audit mode) and
        October 13, 2026 (Enforcement mode) milestones
      - Current live DKM container ACL vs. the documented secure baseline
        (Domain Admins / Enterprise Admins / SYSTEM / AD FS service account only,
        inheritance disabled)
      - Recent AD FS/Admin event log entries for Event IDs 1132-1136
      - Current HKLM:\SOFTWARE\Microsoft\ADFS\RemediateDkmAcl registry state
      - Windows Server platform version, since remediation mechanics differ between
        Windows Server 2012/2012 R2 (manual-only, forever) and 2016+ (opt-in during
        Audit mode, default-on from Enforcement mode)

    This script does NOT modify the DKM container ACL, does NOT set the RemediateDkmAcl
    registry value, and does NOT restart the AD FS service. It is a read-only audit and
    reporting tool only — use the remediation playbooks in DKMACLHardening-A.md /
    DKMACLHardening-B.md to actually remediate.

    Run this on an AD FS farm node with the AD FS PowerShell module (ADFS) and the
    ActiveDirectory PowerShell module available. A single farm node is sufficient —
    the DKM container and its ACL are farm-wide, not per-node — but Windows update
    level should be checked per node since patching can lag across a farm.

.PARAMETER ComputerName
    One or more AD FS farm node names to audit remotely via Invoke-Command.
    If omitted, audits the local machine only. The DKM container ACL and registry
    checks reflect farm-wide/local-node state respectively — see .NOTES.

.PARAMETER OutputPath
    Folder to write the CSV/JSON audit output to. Defaults to the current directory.

.EXAMPLE
    .\Get-DKMACLHardeningAudit.ps1
    Audits the local AD FS server and writes results to the current directory.

.EXAMPLE
    .\Get-DKMACLHardeningAudit.ps1 -ComputerName adfs01,adfs02,adfs03 -OutputPath C:\Audits
    Audits patch level and registry state on three farm nodes remotely, and the
    (farm-wide, so only needs checking once) DKM container ACL from the first
    reachable node.

.NOTES
    Requires: AD FS PowerShell module (run on/against an actual AD FS server) and the
    ActiveDirectory PowerShell module (RSAT-AD-PowerShell) for the AD: PSDrive used to
    read the container ACL.
    Safe/unsafe: fully read-only. Does not require Domain Admin — reading the DKM
    container's ACL only requires whatever read access the running account already has;
    if that account is not one of the four baseline principals, the ACL summary will
    still return (ACL metadata is generally readable), but confirm your account has
    at least List Contents/Read Property rights on the container if results look empty.
    Does not attempt to determine tenant-wide farm topology automatically — supply every
    known farm node name via -ComputerName for multi-node coverage.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$ComputerName,

    [Parameter()]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$auditModeDate       = Get-Date '2026-07-14'
$enforcementModeDate = Get-Date '2026-10-13'
$secureBaselinePrincipals = @('Domain Admins', 'Enterprise Admins', 'SYSTEM')

function Get-NodeAuditData {
    param([string]$TargetComputerName)

    $result = [ordered]@{
        ComputerName        = $TargetComputerName
        OSCaption           = $null
        RelevantHotfixFound = $false
        RelevantHotfixDate  = $null
        PhaseForThisNode    = $null
        RemediateDkmAcl     = $null
        AdfsServiceAccount  = $null
        RecentDkmEvents     = @()
        Errors              = @()
    }

    try {
        $result.OSCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch {
        $result.Errors += "Could not read OS caption: $($_.Exception.Message)"
    }

    try {
        $hotfix = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn -ge $auditModeDate } |
            Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hotfix) {
            $result.RelevantHotfixFound = $true
            $result.RelevantHotfixDate  = $hotfix.InstalledOn
        }
    } catch {
        $result.Errors += "Could not enumerate hotfixes: $($_.Exception.Message)"
    }

    $today = Get-Date
    if (-not $result.RelevantHotfixFound) {
        $result.PhaseForThisNode = "PRE-AUDIT (unpatched — no DKM detection running)"
    } elseif ($today -ge $enforcementModeDate) {
        $result.PhaseForThisNode = "ENFORCEMENT (Oct 13 2026 update installed or later on this node's clock)"
    } else {
        $result.PhaseForThisNode = "AUDIT (detection active, remediation is opt-in only)"
    }

    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ADFS' -Name 'RemediateDkmAcl' -ErrorAction SilentlyContinue
        $result.RemediateDkmAcl = if ($reg) { $reg.RemediateDkmAcl } else { "<not set>" }
    } catch {
        $result.Errors += "Could not read RemediateDkmAcl registry value: $($_.Exception.Message)"
    }

    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='adfssrv'" -ErrorAction Stop
        $result.AdfsServiceAccount = $svc.StartName
    } catch {
        $result.Errors += "Could not identify adfssrv service account (is this an AD FS server?): $($_.Exception.Message)"
    }

    try {
        $events = Get-WinEvent -LogName 'AD FS/Admin' -FilterXPath `
            "*[System[(EventID=1132 or EventID=1133 or EventID=1134 or EventID=1135 or EventID=1136)]]" `
            -MaxEvents 10 -ErrorAction Stop
        $result.RecentDkmEvents = $events | Select-Object TimeCreated, Id, LevelDisplayName,
            @{N = 'Summary'; E = { $_.Message.Split("`n")[0] } }
    } catch {
        # No matching events is not an error condition — log entries for these IDs may simply not exist yet
        $result.Errors += "No DKM detection events found (expected if this node is pre-Audit-mode, or events have rolled over): $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

function Get-DkmContainerAclSummary {
    Write-Status "Reading DKM container ACL (farm-wide setting, checked once)..." "INFO"
    $summary = [ordered]@{
        ContainerDn          = $null
        InheritanceDisabled  = $null
        AllowAces            = @()
        MatchesSecureBaseline = $null
        Errors               = @()
    }

    try {
        $summary.ContainerDn = (Get-AdfsProperties -ErrorAction Stop).CertificateSharingContainer
    } catch {
        $summary.Errors += "Could not read CertificateSharingContainer via Get-AdfsProperties — is the AD FS PowerShell module available and the service configured on this node? $($_.Exception.Message)"
        return [pscustomobject]$summary
    }

    try {
        $acl = Get-Acl "AD:\$($summary.ContainerDn)" -ErrorAction Stop
        $summary.InheritanceDisabled = $acl.AreAccessRulesProtected
        $allowAces = $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }
        $summary.AllowAces = $allowAces | Select-Object IdentityReference, ActiveDirectoryRights

        # Heuristic baseline check: flag any Allow ACE whose identity name doesn't contain one of the
        # three well-known baseline group names or match the AD FS service account name we found on
        # this node. This is informational only — the AD FS service account name varies per environment
        # and this script does not attempt SID-resolution across domains/trusts.
        $unexpected = $allowAces | Where-Object {
            $name = $_.IdentityReference.Value
            -not ($secureBaselinePrincipals | Where-Object { $name -like "*$_*" })
        }
        $summary.MatchesSecureBaseline = ($unexpected.Count -le 1)  # allow exactly one (the service account)
        if ($unexpected.Count -gt 1) {
            $summary.Errors += "More than one non-baseline-group principal found on the DKM container ACL — review manually; this script cannot distinguish a legitimate AD FS service account from an unexpected extra principal without knowing the farm's actual service account name per node."
        }
    } catch {
        $summary.Errors += "Could not read DKM container ACL via AD: PSDrive — is the ActiveDirectory PowerShell module (RSAT-AD-PowerShell) installed, and does the current account have read access to the container? $($_.Exception.Message)"
    }

    return [pscustomobject]$summary
}

# ---- Main ----

Write-Status "AD FS DKM Container ACL Hardening Audit (CVE-2026-56155 / KB5121391)" "INFO"
Write-Status "Audit-mode start: $($auditModeDate.ToShortDateString())  |  Enforcement-mode start: $($enforcementModeDate.ToShortDateString())" "INFO"

$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }
$nodeResults = @()

foreach ($target in $targets) {
    Write-Status "Auditing node: $target" "INFO"
    try {
        if ($target -eq $env:COMPUTERNAME -or -not $ComputerName) {
            $nodeResults += Get-NodeAuditData -TargetComputerName $target
        } else {
            $nodeResults += Invoke-Command -ComputerName $target -ScriptBlock ${function:Get-NodeAuditData} -ArgumentList $target -ErrorAction Stop
        }
    } catch {
        Write-Status "Failed to audit $target : $($_.Exception.Message)" "ERROR"
        $nodeResults += [pscustomobject]@{ ComputerName = $target; Errors = @("Remote audit failed: $($_.Exception.Message)") }
    }
}

$aclSummary = Get-DkmContainerAclSummary

foreach ($node in $nodeResults) {
    $status = if ($node.PhaseForThisNode -like "PRE-AUDIT*") { "WARN" }
              elseif ($node.RemediateDkmAcl -eq "<not set>" -and $node.PhaseForThisNode -like "AUDIT*") { "WARN" }
              else { "OK" }
    Write-Status "$($node.ComputerName): $($node.PhaseForThisNode) | RemediateDkmAcl=$($node.RemediateDkmAcl)" $status
}

if ($aclSummary.ContainerDn) {
    Write-Status "DKM container: $($aclSummary.ContainerDn)" "INFO"
    Write-Status "Inheritance disabled: $($aclSummary.InheritanceDisabled)" $(if ($aclSummary.InheritanceDisabled) { "OK" } else { "WARN" })
    Write-Status "Appears to match secure baseline (heuristic): $($aclSummary.MatchesSecureBaseline)" $(if ($aclSummary.MatchesSecureBaseline) { "OK" } else { "WARN" })
} else {
    Write-Status "Could not determine DKM container — see errors in output for details." "ERROR"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
$jsonPath = Join-Path $OutputPath "DKMACLHardeningAudit-$timestamp.json"
$csvPath  = Join-Path $OutputPath "DKMACLHardeningAudit-NodeSummary-$timestamp.csv"

[ordered]@{
    RunTimestamp = Get-Date
    Nodes        = $nodeResults
    AclSummary   = $aclSummary
} | ConvertTo-Json -Depth 6 | Out-File $jsonPath

$nodeResults | Select-Object ComputerName, OSCaption, RelevantHotfixFound, RelevantHotfixDate, PhaseForThisNode, RemediateDkmAcl, AdfsServiceAccount |
    Export-Csv -Path $csvPath -NoTypeInformation

Write-Status "Full detail written to $jsonPath" "OK"
Write-Status "Node summary CSV written to $csvPath" "OK"

$preAuditCount = ($nodeResults | Where-Object { $_.PhaseForThisNode -like "PRE-AUDIT*" }).Count
$unremediated  = ($nodeResults | Where-Object { $_.RemediateDkmAcl -eq "<not set>" -and $_.PhaseForThisNode -notlike "PRE-AUDIT*" }).Count
if ($preAuditCount -gt 0) {
    Write-Status "$preAuditCount node(s) predate the July 2026 update — patch these first, they have zero DKM ACL visibility." "WARN"
}
if ($unremediated -gt 0) {
    Write-Status "$unremediated node(s) have not opted in to remediation yet — see DKMACLHardening-B.md Fix 2 / Fix 2b." "WARN"
}
if ($aclSummary.MatchesSecureBaseline -eq $false) {
    Write-Status "DKM container ACL does not appear to match the secure baseline — treat as a priority remediation item." "WARN"
}
