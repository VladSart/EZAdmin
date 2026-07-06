<#
.SYNOPSIS
    Audits DFS namespace configuration for ABE consistency and referral/site-costing overrides.

.DESCRIPTION
    Complements Test-DFSHealth.ps1 (which checks service state and replication backlog) by auditing
    the two configuration areas that most often cause "it looks healthy but behaves wrong" tickets:

    1. Access-Based Enumeration (ABE) consistency
       - Namespace-root ABE flag vs. the per-server SMB share FolderEnumerationMode on every folder target
       - Flags any target where the two settings don't match (the #1 cause of "ABE isn't working")

    2. Referral ordering / site-costing overrides
       - Manual ReferralPriorityClass / ReferralPriorityRank overrides on folder targets
       - Flags any target NOT using the default "SiteCost" class, since a forgotten manual override
         is the most common reason a client keeps hitting a remote/DR target unexpectedly

    Read-only. Makes no changes to any namespace, share, or folder target.

.PARAMETER DomainNamespace
    Specific namespace root to audit (e.g. \\contoso.com\files). If omitted, audits all
    domain-based namespaces discoverable from this machine.

.PARAMETER OutputPath
    Path to export CSV reports. Default: $env:TEMP\DFSNamespaceAudit-<date>

.EXAMPLE
    .\Get-DFSNamespaceConfigAudit.ps1

.EXAMPLE
    .\Get-DFSNamespaceConfigAudit.ps1 -DomainNamespace "\\contoso.com\files"

.NOTES
    Requires: RSAT-DFS-Mgmt-Con PowerShell module, WinRM access to folder target servers
    Run as:   Domain Admin or delegated DFS admin with remote PowerShell rights to target servers
    Safe to run repeatedly — read-only, no changes made.
    Companion runbooks: DFS/Troubleshooting/ABE/DFS-ABE-A.md, DFS-ABE-B.md,
                         DFS/Troubleshooting/SiteCosting/DFS-SiteCosting-A.md, DFS-SiteCosting-B.md
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$DomainNamespace = "",
    [string]$OutputPath = "$env:TEMP\DFSNamespaceAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

function Test-RemoteFolderEnumerationMode {
    param([string]$ComputerName, [string]$ShareName)
    try {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            param($Share)
            (Get-SmbShare -Name $Share -ErrorAction Stop).FolderEnumerationMode
        } -ArgumentList $ShareName -ErrorAction Stop
    } catch {
        return "UNREACHABLE"
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$AbeResults      = [System.Collections.Generic.List[PSObject]]::new()
$ReferralResults = [System.Collections.Generic.List[PSObject]]::new()

Write-Status "DFS Namespace Config Audit started — $(Get-Date)" "INFO"
Write-Status "Export path: $OutputPath" "INFO"
Write-Host ""

# ─── Discover namespaces ───────────────────────────────────────────────────────

$Namespaces = if ($DomainNamespace) {
    @($DomainNamespace)
} else {
    try {
        (Get-DfsnRoot -ErrorAction Stop).Path
    } catch {
        Write-Status "Could not enumerate namespace roots — specify -DomainNamespace manually" "WARN"
        @()
    }
}

if ($Namespaces.Count -eq 0) {
    Write-Status "No namespaces to audit. Exiting." "WARN"
    exit 0
}

foreach ($Ns in $Namespaces) {

    Write-Host "=== $Ns ===" -ForegroundColor Magenta

    # ── ABE audit ──
    try {
        $RootAbe = (Get-DfsnRoot -Path $Ns -ErrorAction Stop).EnableAccessBasedEnumeration
    } catch {
        Write-Status "Could not read namespace root ABE flag: $($_.Exception.Message)" "ERROR"
        continue
    }

    Write-Status "Namespace-root ABE flag: $RootAbe" $(if ($RootAbe) { "OK" } else { "WARN" })

    try {
        $Folders = Get-DfsnFolder -Path $Ns -ErrorAction Stop
    } catch {
        Write-Status "Could not enumerate folders under $Ns : $($_.Exception.Message)" "WARN"
        continue
    }

    foreach ($Folder in $Folders) {
        $Targets = Get-DfsnFolderTarget -Path $Folder.Path -ErrorAction SilentlyContinue
        foreach ($Target in $Targets) {

            $UncParts  = $Target.TargetPath.TrimStart('\') -split '\\'
            $Server    = $UncParts[0]
            $ShareName = $UncParts[1]

            $ShareAbeMode = Test-RemoteFolderEnumerationMode -ComputerName $Server -ShareName $ShareName
            $Mismatch = ($RootAbe -eq $true -and $ShareAbeMode -ne "AccessBased") -or
                        ($RootAbe -eq $false -and $ShareAbeMode -eq "AccessBased")
            $Status = if ($ShareAbeMode -eq "UNREACHABLE") { "WARN" } elseif ($Mismatch) { "ERROR" } else { "OK" }

            Write-Status "  [$($Folder.Path)] target $($Target.TargetPath) — share mode: $ShareAbeMode" $Status

            $AbeResults.Add([PSCustomObject]@{
                Namespace         = $Ns
                Folder            = $Folder.Path
                Target            = $Target.TargetPath
                NamespaceRootABE  = $RootAbe
                ShareEnumMode     = $ShareAbeMode
                Mismatch          = $Mismatch
                Status            = $Status
            })

            # ── Referral priority audit (same target loop, no extra remote calls needed) ──
            $PriorityClass = $Target.ReferralPriorityClass
            $PriorityRank  = $Target.ReferralPriorityRank
            $IsOverride    = $PriorityClass -and $PriorityClass -ne "SiteCost"
            $RefStatus     = if ($IsOverride) { "WARN" } else { "OK" }

            if ($IsOverride) {
                Write-Status "  [$($Folder.Path)] target $($Target.TargetPath) — manual override: $PriorityClass (rank $PriorityRank)" "WARN"
            }

            $ReferralResults.Add([PSCustomObject]@{
                Namespace            = $Ns
                Folder               = $Folder.Path
                Target               = $Target.TargetPath
                ReferralPriorityClass = $PriorityClass
                ReferralPriorityRank  = $PriorityRank
                ManualOverride        = $IsOverride
                Status                = $RefStatus
            })
        }
    }
    Write-Host ""
}

# ─── Summary ───────────────────────────────────────────────────────────────────

$AbeMismatches      = $AbeResults      | Where-Object Status -eq "ERROR"
$AbeUnreachable     = $AbeResults      | Where-Object Status -eq "WARN"
$ReferralOverrides  = $ReferralResults | Where-Object ManualOverride -eq $true

Write-Host "=== SUMMARY ===" -ForegroundColor Magenta
Write-Status "Namespaces audited:            $($Namespaces.Count)"
Write-Status "Folder targets checked (ABE):  $($AbeResults.Count)"
Write-Status "ABE mismatches:                $($AbeMismatches.Count)" $(if ($AbeMismatches.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "Unreachable target servers:    $($AbeUnreachable.Count)" $(if ($AbeUnreachable.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "Manual referral overrides:     $($ReferralOverrides.Count)" $(if ($ReferralOverrides.Count -gt 0) { "WARN" } else { "OK" })

if ($AbeMismatches.Count -gt 0) {
    Write-Host ""
    Write-Host "ABE MISMATCHES — namespace-root flag and share-level mode disagree:" -ForegroundColor Red
    $AbeMismatches | Format-Table Namespace, Folder, Target, NamespaceRootABE, ShareEnumMode -AutoSize
    Write-Status "See DFS-ABE-B.md Fix 2 to align share-level FolderEnumerationMode." "WARN"
}

if ($ReferralOverrides.Count -gt 0) {
    Write-Host ""
    Write-Host "MANUAL REFERRAL OVERRIDES — may be intentional (DR) or forgotten:" -ForegroundColor Yellow
    $ReferralOverrides | Format-Table Namespace, Folder, Target, ReferralPriorityClass, ReferralPriorityRank -AutoSize
    Write-Status "See DFS-SiteCosting-B.md Fix 6 to confirm intent and reset if forgotten." "WARN"
}

# ─── Export ────────────────────────────────────────────────────────────────────

$AbeResults      | Export-Csv "$OutputPath\abe-audit.csv"      -NoTypeInformation
$ReferralResults | Export-Csv "$OutputPath\referral-audit.csv" -NoTypeInformation

Write-Status "`nFull reports: $OutputPath" "INFO"
Write-Status "Done." "OK"
