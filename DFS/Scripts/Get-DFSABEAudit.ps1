<#
.SYNOPSIS
    Audits Access-Based Enumeration (ABE) configuration across a DFS namespace, every folder,
    and every folder target server — surfacing the namespace/share configuration drift that
    causes "ABE works on one target but not another."

.DESCRIPTION
    ABE is enforced at two independent layers that do not inherit or replicate from one another:
      1. The DFS Namespace root property (EnableAccessBasedEnumeration) — AD-replicated for
         domain-based namespaces, local-only for standalone namespaces.
      2. The SMB Share property (FolderEnumerationMode) on each physical folder-target server —
         a per-server Server Service setting that DFSR never touches, even between targets
         serving identical replicated content.
    This script walks every folder under a namespace, queries every folder target's SMB share
    remotely via Invoke-Command, and reports any target whose FolderEnumerationMode does not
    match AccessBased when the namespace itself expects ABE. It also flags standalone namespaces
    (no HA/replication for the ABE setting) and unreachable target servers.

    What it does NOT do: it does not evaluate NTFS ACLs / effective access for the "folder
    visible when it shouldn't be" symptom — that's Playbook 2 in DFS-ABE-A.md and requires a
    specific test-user context, which is out of scope for a fleet-wide config audit.

.PARAMETER NamespacePath
    UNC path to the DFS namespace root, e.g. \\contoso.com\Public

.PARAMETER OutputPath
    Folder to write the CSV report and transcript to. Defaults to C:\Temp\DFS-ABE-Audit.

.EXAMPLE
    .\Get-DFSABEAudit.ps1 -NamespacePath "\\contoso.com\Public"

.EXAMPLE
    .\Get-DFSABEAudit.ps1 -NamespacePath "\\contoso.com\Public" -OutputPath "D:\Reports\ABE"

.NOTES
    Requires: RSAT DFS Management Tools (DFSN module) on the machine running this script.
    Requires: WinRM/PSRemoting enabled on every folder-target server (uses Invoke-Command).
    Requires: Rights to query Get-DfsnRoot/Get-DfsnFolder/Get-DfsnFolderTarget and to run
              Get-SmbShare remotely on each target server.
    Safe/Read-only: This script makes no configuration changes. See DFS-ABE-A.md Playbook 1
    for the corresponding remediation script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NamespacePath,

    [string]$OutputPath = "C:\Temp\DFS-ABE-Audit"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
if (-not (Get-Module -ListAvailable -Name DFSN)) {
    Write-Status "DFSN module not found. Install RSAT DFS Management Tools." "ERROR"
    exit 1
}
Import-Module DFSN -ErrorAction Stop

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$results = [System.Collections.Generic.List[object]]::new()

# --- Detect: namespace root state ---
Write-Status "Querying namespace root: $NamespacePath"
try {
    $root = Get-DfsnRoot -Path $NamespacePath
} catch {
    Write-Status "Could not query namespace root. $_" "ERROR"
    exit 1
}

$namespaceABE = $root.EnableAccessBasedEnumeration
$namespaceType = $root.Type
Write-Status "Namespace type: $namespaceType | EnableAccessBasedEnumeration: $namespaceABE" $(if ($namespaceABE) { "OK" } else { "WARN" })

if ($namespaceType -eq "Standalone") {
    Write-Status "Standalone namespace — ABE setting is local to this single server, no AD replication/HA." "WARN"
}

# --- Execute: walk every folder and every target ---
Write-Status "Enumerating folders under $NamespacePath ..."
$folders = Get-DfsnFolder -Path "$NamespacePath\*" -ErrorAction SilentlyContinue

if (-not $folders) {
    Write-Status "No folders found under this namespace, or access denied." "WARN"
}

foreach ($folder in $folders) {
    $targets = Get-DfsnFolderTarget -Path $folder.Path -ErrorAction SilentlyContinue
    foreach ($target in $targets) {
        $parts = $target.TargetPath.TrimStart('\') -split '\\'
        $server = $parts[0]
        $shareName = $parts[1]

        $row = [PSCustomObject]@{
            Folder                = $folder.Path
            TargetServer           = $server
            TargetPath              = $target.TargetPath
            TargetState             = $target.State
            NamespaceABE            = $namespaceABE
            ShareFolderEnumMode      = $null
            Reachable                = $false
            Compliant                = $false
            Notes                    = ""
        }

        try {
            $shareInfo = Invoke-Command -ComputerName $server -ScriptBlock {
                param($share)
                Get-SmbShare -Name $share -ErrorAction Stop | Select-Object -ExpandProperty FolderEnumerationMode
            } -ArgumentList $shareName -ErrorAction Stop

            $row.Reachable = $true
            $row.ShareFolderEnumMode = $shareInfo

            if ($namespaceABE -and $shareInfo -eq "AccessBased") {
                $row.Compliant = $true
                $row.Notes = "OK"
            } elseif ($namespaceABE -and $shareInfo -ne "AccessBased") {
                $row.Notes = "DRIFT: namespace expects ABE, share is $shareInfo"
            } elseif (-not $namespaceABE) {
                $row.Notes = "Namespace-level ABE not enabled — share setting irrelevant until namespace flag is set"
            }
        } catch {
            $row.Notes = "UNREACHABLE: $($_.Exception.Message)"
        }

        $results.Add($row)
    }
}

# --- Validate / summarize ---
$driftCount       = ($results | Where-Object { $_.Notes -like "DRIFT*" }).Count
$unreachableCount = ($results | Where-Object { $_.Notes -like "UNREACHABLE*" }).Count
$compliantCount   = ($results | Where-Object { $_.Compliant }).Count

Write-Host ""
Write-Status "=== SUMMARY ===" "INFO"
Write-Status "Total folder targets checked : $($results.Count)" "INFO"
Write-Status "Compliant (ABE matches)      : $compliantCount" "OK"
Write-Status "Configuration drift          : $driftCount" $(if ($driftCount -gt 0) { "WARN" } else { "OK" })
Write-Status "Unreachable targets          : $unreachableCount" $(if ($unreachableCount -gt 0) { "WARN" } else { "OK" })

if ($driftCount -gt 0) {
    Write-Host ""
    Write-Status "Targets with drift:" "WARN"
    $results | Where-Object { $_.Notes -like "DRIFT*" } | Format-Table Folder, TargetServer, ShareFolderEnumMode, Notes -AutoSize
}

# --- Report ---
$csvPath = Join-Path $OutputPath "DFS-ABE-Audit-$ts.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Full report exported to: $csvPath" "OK"
