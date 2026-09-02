<#
.SYNOPSIS
    Audits Windows devices for SSO Permission Auto-Accept (AutoAcceptSsoPermission) eligibility and policy state.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/SSOPermissionAutoAccept-A.md and -B.md.

    Checks, on the local or a remote computer:
      - OS version/build eligibility (Windows 11 24H2/25H2)
      - Presence of the prerequisite July 2026+ cumulative/security update (KB5101650 or later)
      - The AutoAcceptSsoPermission registry policy value under
        HKLM\SOFTWARE\Policies\Microsoft\Windows\AAD
      - Device join/management state via dsregcmd (Entra joined / hybrid Entra joined / workplace
        joined) to flag devices that are structurally out of scope for this policy regardless of the
        registry value
      - The currently signed-in account's UPN as a best-effort signal for personal-vs-work account use

    This script does NOT and cannot determine whether the SSO consent prompt behavior has actually been
    suppressed end-to-end for a given user/app combination — that is a runtime UI behavior with no
    reliable headless equivalent. Use the -A.md Validation Steps for behavioral confirmation.

    Exit codes / status flags follow the Preflight -> Detect -> Execute -> Validate -> Report model.

.PARAMETER ComputerName
    One or more computer names to audit. Defaults to the local computer. Remote auditing requires
    WinRM/PowerShell Remoting connectivity and appropriate rights on the target.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to the current user's temp folder.

.EXAMPLE
    .\Get-SSOPermissionAutoAcceptAudit.ps1

    Audits the local computer and writes a CSV report to $env:TEMP.

.EXAMPLE
    .\Get-SSOPermissionAutoAcceptAudit.ps1 -ComputerName PC01,PC02 -ExportPath C:\Reports\SSOAudit.csv

    Audits two remote computers via PowerShell Remoting and exports to a specific path.

.NOTES
    Requires: PowerShell 5.1+. Remote auditing requires WinRM enabled on targets and appropriate
    administrative rights. Read-only — makes no configuration changes.
    Safe to run in production; does not require elevation for local read-only checks, though some
    registry paths under HKLM may return incomplete data without local administrator rights.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "SSOPermissionAutoAccept-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-SSOAutoAcceptState {
    param([string]$Target)

    $result = [ordered]@{
        ComputerName            = $Target
        Reachable               = $false
        OSProductName           = $null
        OSBuildNumber           = $null
        BuildEligible           = $false
        PrerequisiteKBInstalled = $false
        InstalledUpdateSample   = $null
        RegistryValuePresent    = $false
        RegistryValue           = $null
        PolicyEffective         = $false
        JoinState               = $null
        JoinStateEligible       = $false
        SignedInUPN             = $null
        OverallStatus           = "UNKNOWN"
    }

    try {
        $scriptBlock = {
            $ci = Get-ComputerInfo -ErrorAction SilentlyContinue
            $kb = Get-HotFix -ErrorAction SilentlyContinue |
                Where-Object { $_.HotFixID -in @("KB5101650", "KB5094126") }
            $recentKb = Get-HotFix -ErrorAction SilentlyContinue |
                Sort-Object InstalledOn -Descending | Select-Object -First 1
            $regValue = $null
            try {
                $regValue = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AAD" `
                    -Name "AutoAcceptSsoPermission" -ErrorAction SilentlyContinue).AutoAcceptSsoPermission
            } catch { }
            $dsreg = $null
            try { $dsreg = (dsregcmd /status | Out-String) } catch { }
            $upn = $null
            try { $upn = whoami /upn 2>$null } catch { }

            [pscustomobject]@{
                OSProductName = $ci.WindowsProductName
                OSBuildNumber = $ci.OsBuildNumber
                KBFound       = [bool]$kb
                RecentKB      = if ($recentKb) { "$($recentKb.HotFixID) ($($recentKb.InstalledOn))" } else { $null }
                RegistryValue = $regValue
                DsregOutput   = $dsreg
                SignedInUPN   = $upn
            }
        }

        if ($Target -eq $env:COMPUTERNAME -or $Target -eq "localhost" -or $Target -eq ".") {
            $data = & $scriptBlock
        } else {
            $data = Invoke-Command -ComputerName $Target -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        $result.Reachable = $true
        $result.OSProductName = $data.OSProductName
        $result.OSBuildNumber = $data.OSBuildNumber

        # 24H2 minimum build family is 26100.x; treat >= 26100 with the KB present as eligible.
        # This is a best-effort build-family check, not an exact minimum-build database.
        if ($data.OSBuildNumber -and ([int]($data.OSBuildNumber.ToString().Split('.')[0]) -ge 26100)) {
            $result.BuildEligible = $true
        }

        $result.PrerequisiteKBInstalled = [bool]$data.KBFound
        $result.InstalledUpdateSample = $data.RecentKB
        $result.RegistryValuePresent = $null -ne $data.RegistryValue
        $result.RegistryValue = $data.RegistryValue
        $result.SignedInUPN = $data.SignedInUPN

        if ($data.DsregOutput) {
            $aadJoined = $data.DsregOutput -match "AzureAdJoined\s*:\s*YES"
            $domainJoined = $data.DsregOutput -match "DomainJoined\s*:\s*YES"
            $workplaceJoined = $data.DsregOutput -match "WorkplaceJoined\s*:\s*YES"
            if ($aadJoined) {
                $result.JoinState = if ($domainJoined) { "HybridEntraJoined" } else { "EntraJoined" }
                $result.JoinStateEligible = $true
            } elseif ($workplaceJoined) {
                $result.JoinState = "WorkplaceJoined-OutOfScope"
                $result.JoinStateEligible = $false
            } else {
                $result.JoinState = "NotJoined-OutOfScope"
                $result.JoinStateEligible = $false
            }
        }

        $result.PolicyEffective = $result.BuildEligible -and $result.PrerequisiteKBInstalled -and
            $result.RegistryValuePresent -and ($result.RegistryValue -eq 1) -and $result.JoinStateEligible

        $result.OverallStatus = if ($result.PolicyEffective) {
            "EFFECTIVE"
        } elseif (-not $result.BuildEligible -or -not $result.PrerequisiteKBInstalled) {
            "NOT_ELIGIBLE_MISSING_UPDATE"
        } elseif (-not $result.JoinStateEligible) {
            "NOT_ELIGIBLE_JOIN_STATE"
        } elseif (-not $result.RegistryValuePresent) {
            "ELIGIBLE_POLICY_NOT_DEPLOYED"
        } elseif ($result.RegistryValue -ne 1) {
            "ELIGIBLE_POLICY_DISABLED"
        } else {
            "REVIEW_REQUIRED"
        }
    } catch {
        $result.Reachable = $false
        $result.OverallStatus = "UNREACHABLE: $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

Write-Status "Starting SSO Permission Auto-Accept audit for $($ComputerName.Count) target(s)..." "INFO"

$report = foreach ($computer in $ComputerName) {
    Write-Status "Auditing $computer..." "INFO"
    $state = Get-SSOAutoAcceptState -Target $computer
    switch -Wildcard ($state.OverallStatus) {
        "EFFECTIVE"                     { Write-Status "$computer : Policy effective" "OK" }
        "NOT_ELIGIBLE*"                 { Write-Status "$computer : $($state.OverallStatus)" "WARN" }
        "ELIGIBLE_POLICY_NOT_DEPLOYED"  { Write-Status "$computer : Eligible but policy not deployed" "WARN" }
        "ELIGIBLE_POLICY_DISABLED"      { Write-Status "$computer : Eligible but policy explicitly disabled (0)" "WARN" }
        "UNREACHABLE*"                  { Write-Status "$computer : $($state.OverallStatus)" "ERROR" }
        default                          { Write-Status "$computer : $($state.OverallStatus)" "WARN" }
    }
    $state
}

$report | Select-Object ComputerName, Reachable, OSProductName, OSBuildNumber, BuildEligible, `
    PrerequisiteKBInstalled, RegistryValuePresent, RegistryValue, JoinState, JoinStateEligible, `
    SignedInUPN, OverallStatus |
    Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Status "Report exported to $ExportPath" "OK"
$report | Format-Table ComputerName, OSBuildNumber, PrerequisiteKBInstalled, RegistryValue, JoinState, OverallStatus -AutoSize
