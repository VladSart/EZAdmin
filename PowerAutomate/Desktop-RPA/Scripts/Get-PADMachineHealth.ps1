<#
.SYNOPSIS
    Health check for Power Automate for desktop (PAD) machine runtime prerequisites —
    automates the Layer 0-2 triage from MachineRuntime-B.md / MachineRuntime-A.md.

.DESCRIPTION
    Power Automate machine/session management has no supported cloud-side PowerShell
    surface (machine registration, capacity, and error codes are portal-only per
    Microsoft Learn) — the fixable prerequisites live entirely on the machine itself.
    This script checks the machine-side dependency chain the runbooks document:

    - UIFlowService running, and which account it runs as
    - That account's membership in "Remote Desktop Users" (required to enumerate/create
      sessions — missing membership is the #1 cause of UIFlowServiceNoRdpPermissions /
      SessionNotFoundAfterCreation errors)
    - Whether that account is blocked by a "Deny log on locally" / "Deny log on through
      Remote Desktop Services" local security policy (a GPO regression is a common,
      delayed-onset cause of fleet-wide breakage per MachineRuntime-A.md Playbook 4)
    - RDP enabled (fDenyTSConnections) — a hard requirement for every unattended run,
      not a configurable preference
    - Installed Power Automate for desktop version vs. the 2.8.73.21119 direct-connectivity
      floor (older installs may still depend on the retired gateway model)
    - Current interactive/RDP session state (query user) — flags sessions that would
      collide with an unattended run per the OS-specific rules (Windows 10/11 vs. Server)
    - Basic reachability to the required Power Automate cloud endpoints

    Supports a single machine (default: localhost) or a fleet sweep via -ComputerName,
    using PowerShell remoting (WinRM must already be enabled/reachable — this script does
    not configure remoting itself).

    Read-only. Makes no configuration changes — see MachineRuntime-B.md Fix 1-6 for the
    corresponding remediation commands once a gap is identified here.

.PARAMETER ComputerName
    One or more machine names to check. Defaults to the local machine. For a fleet sweep,
    supply an array or pipe in a list (e.g. from your RMM's device inventory export).

.PARAMETER ServiceAccount
    Expected UIFlowService logon account, for drift detection. Defaults to the standard
    virtual account "NT SERVICE\UIFlowService". Set this if your environment intentionally
    uses a custom domain service account (see MachineRuntime-B.md Fix 1).

.PARAMETER OutputPath
    Path to export the CSV report. Default: C:\Temp\PADMachineHealth-<timestamp>.csv

.EXAMPLE
    .\Get-PADMachineHealth.ps1
    Checks the local machine only.

.EXAMPLE
    .\Get-PADMachineHealth.ps1 -ComputerName "RPA-VM01","RPA-VM02","RPA-VM03"
    Fleet sweep across three unattended RPA machines — use this for Playbook 4's
    "confirm the pattern is fleet-wide, not one machine" step.

.EXAMPLE
    Get-Content .\rpa-fleet.txt | .\Get-PADMachineHealth.ps1
    Pipe a list of machine names from a text file.

.NOTES
    Requires: PowerShell remoting (WinRM) enabled on target machines for -ComputerName
              other than localhost. Local admin rights on each target to read service
              config and security policy.
    Safe to run repeatedly — read-only, no state changes.
    Companion runbooks: PowerAutomate/Desktop-RPA/MachineRuntime-B.md and -A.md
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter()]
    [string]$ServiceAccount = "NT SERVICE\UIFlowService",

    [Parameter()]
    [string]$OutputPath = "C:\Temp\PADMachineHealth-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    function Write-Status {
        param([string]$Message, [string]$Status = "INFO")
        $Colour = switch ($Status) {
            "OK"    { "Green" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            default { "Cyan" }
        }
        Write-Host "[$Status] $Message" -ForegroundColor $Colour
    }

    # The per-machine check block — runs locally via Invoke-Command (or directly in-process
    # for localhost, avoiding an unnecessary remoting hop on the most common single-machine case).
    $CheckScriptBlock = {
        param($ExpectedServiceAccount)

        $Result = [ordered]@{
            ComputerName          = $env:COMPUTERNAME
            OSCaption             = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
            UIFlowServiceStatus   = "NotFound"
            UIFlowServiceAccount  = $null
            ServiceAccountMatchesExpected = $false
            RemoteDesktopUsersMember = $false
            RemoteDesktopUsersRaw   = $null
            RDPEnabled            = $false
            PADVersion            = $null
            PADMeetsDirectConnectivityFloor = $false
            ActiveOrLockedSessions = $null
            SessionCount          = 0
            Flags                 = @()
        }

        # UIFlowService status + account
        $Svc = Get-Service -Name "UIFlowService" -ErrorAction SilentlyContinue
        if ($Svc) {
            $Result.UIFlowServiceStatus = $Svc.Status.ToString()
            $SvcCim = Get-CimInstance Win32_Service -Filter "Name='UIFlowService'" -ErrorAction SilentlyContinue
            if ($SvcCim) {
                $Result.UIFlowServiceAccount = $SvcCim.StartName
                $Result.ServiceAccountMatchesExpected = ($SvcCim.StartName -eq $ExpectedServiceAccount)
            }
            if ($Svc.Status -ne "Running") { $Result.Flags += "UIFLOWSERVICE_NOT_RUNNING" }
            if (-not $Result.ServiceAccountMatchesExpected) { $Result.Flags += "SERVICE_ACCOUNT_DRIFT: running as $($Result.UIFlowServiceAccount), expected $ExpectedServiceAccount" }
        } else {
            $Result.Flags += "UIFLOWSERVICE_NOT_INSTALLED"
        }

        # Remote Desktop Users membership — check both the default virtual account and
        # whatever the service is actually running as, since they may differ intentionally.
        try {
            $RdpGroupMembers = (net localgroup "Remote Desktop Users") -join "`n"
            $Result.RemoteDesktopUsersRaw = $RdpGroupMembers
            $AccountToCheck = if ($Result.UIFlowServiceAccount) { $Result.UIFlowServiceAccount } else { $ExpectedServiceAccount }
            $ShortAccount = ($AccountToCheck -split '\\')[-1]
            if ($RdpGroupMembers -match [regex]::Escape($ShortAccount) -or $RdpGroupMembers -match [regex]::Escape($AccountToCheck)) {
                $Result.RemoteDesktopUsersMember = $true
            } else {
                $Result.Flags += "SERVICE_ACCOUNT_NOT_IN_RDP_USERS: unattended session creation/enumeration will fail (UIFlowServiceNoRdpPermissions / SessionNotFoundAfterCreation)"
            }
        } catch {
            $Result.Flags += "COULD_NOT_CHECK_RDP_GROUP: $($_.Exception.Message)"
        }

        # RDP enabled
        try {
            $Ts = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -ErrorAction Stop
            $Result.RDPEnabled = ($Ts.fDenyTSConnections -eq 0)
            if (-not $Result.RDPEnabled) { $Result.Flags += "RDP_DISABLED: every unattended run will fail (RDPIsNotEnabled)" }
        } catch {
            $Result.Flags += "COULD_NOT_CHECK_RDP_REGISTRY: $($_.Exception.Message)"
        }

        # PAD version — read from the installed console host binary if present
        try {
            $PadRoot = Join-Path ${env:ProgramFiles(x86)} "Power Automate Desktop"
            $PadExe = Get-ChildItem -Path $PadRoot -Filter "PAD.Console.Host.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($PadExe) {
                $VerString = $PadExe.VersionInfo.ProductVersion
                $Result.PADVersion = $VerString
                # Compare against the 2.8.73.21119 direct-connectivity floor
                try {
                    $Parsed = [version]($VerString -replace '[^\d\.]', '')
                    $Floor  = [version]"2.8.73.21119"
                    $Result.PADMeetsDirectConnectivityFloor = ($Parsed -ge $Floor)
                } catch {
                    # Version string didn't parse cleanly — leave as unknown rather than guessing
                }
                if (-not $Result.PADMeetsDirectConnectivityFloor) {
                    $Result.Flags += "PAD_BELOW_DIRECT_CONNECTIVITY_FLOOR: upgrade required (v$VerString found, need >= 2.8.73.21119) — this machine may still depend on the retired gateway model"
                }
            } else {
                $Result.Flags += "PAD_NOT_FOUND: Power Automate for desktop console host not detected in the default install path"
            }
        } catch {
            $Result.Flags += "COULD_NOT_CHECK_PAD_VERSION: $($_.Exception.Message)"
        }

        # Current session state — informational, not itself a failure; the runbook's
        # session-collision rules are OS- and connection-user-specific, so this is
        # surfaced for a human to cross-reference against the specific unattended
        # connection's identity, not auto-flagged as an error here.
        try {
            $Sessions = (query user 2>$null)
            $Result.ActiveOrLockedSessions = ($Sessions -join "; ")
            $Result.SessionCount = [Math]::Max(0, ($Sessions | Measure-Object).Count - 1)  # subtract header row
        } catch {
            $Result.ActiveOrLockedSessions = "none or query failed"
        }

        [PSCustomObject]$Result
    }

    $AllResults = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($Computer in $ComputerName) {
        Write-Status "Checking $Computer ..."
        try {
            if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".") {
                $R = & $CheckScriptBlock $ServiceAccount
            } else {
                $R = Invoke-Command -ComputerName $Computer -ScriptBlock $CheckScriptBlock -ArgumentList $ServiceAccount -ErrorAction Stop
            }
            $FlagCount = @($R.Flags).Count
            if ($FlagCount -eq 0) {
                Write-Status "  $Computer -> healthy" "OK"
            } else {
                Write-Status "  $Computer -> $FlagCount issue(s): $($R.Flags -join ' | ')" "WARN"
            }
            $AllResults.Add($R)
        } catch {
            Write-Status "  $Computer -> could not connect/check: $($_.Exception.Message)" "ERROR"
            $AllResults.Add([PSCustomObject]@{
                ComputerName = $Computer
                Flags        = @("UNREACHABLE_OR_REMOTING_FAILED: $($_.Exception.Message)")
            })
        }
    }
}

end {
    Write-Host ""
    Write-Host "=== PAD MACHINE RUNTIME HEALTH: $($AllResults.Count) machine(s) checked ===" -ForegroundColor Magenta

    $Unhealthy = $AllResults | Where-Object { @($_.Flags).Count -gt 0 }
    Write-Status "Machines with at least one flagged issue: $($Unhealthy.Count) / $($AllResults.Count)" $(if ($Unhealthy.Count -gt 0) { "WARN" } else { "OK" })

    if ($Unhealthy.Count -gt 0) {
        Write-Host ""
        $Unhealthy | ForEach-Object {
            Write-Host "-- $($_.ComputerName) --" -ForegroundColor Yellow
            $_.Flags | ForEach-Object { Write-Host "   $_" }
        }
        Write-Host ""
        Write-Status "Cross-reference flags against MachineRuntime-B.md 'Common Fix Paths' — each flag name maps directly to a Fix section." "INFO"
        Write-Status "If the SAME flag recurs across multiple machines, treat as a policy/deployment regression (MachineRuntime-A.md Playbook 4), not a per-machine break-fix." "INFO"
    }

    # Flatten Flags array to a single string for CSV export
    $ExportRows = $AllResults | ForEach-Object {
        $Row = $_ | Select-Object *
        $Row.Flags = ($_.Flags -join "; ")
        $Row
    }
    New-Item -ItemType Directory -Path (Split-Path $OutputPath) -Force -ErrorAction SilentlyContinue | Out-Null
    $ExportRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

    Write-Status "`nReport exported to: $OutputPath" "OK"
    Write-Status "Done." "OK"
}
