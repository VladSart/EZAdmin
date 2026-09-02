<#
.SYNOPSIS
    Audits a device (local or remote) for Secure Boot 2011-to-2023 certificate
    transition status ahead of the June/October 2026 expiration of the original
    2011-issued certificates.

.DESCRIPTION
    Reads the documented Secure Boot servicing registry keys and, where supported,
    decodes the live firmware DB/KEK certificate content to confirm ground truth.
    Reports:
    - Whether Secure Boot is enabled at all (prerequisite)
    - UEFICA2023Status (NotStarted / InProgress / Updated) and UEFICA2023Error
    - WindowsUEFICA2023Capable (0 = cert not in DB, 1 = in DB, 2 = in DB AND booting
      from the 2023-signed boot manager) — the key field for distinguishing a
      transient NotStarted state from a permanent hardware/firmware ceiling
    - Deployment trigger state (AvailableUpdates, AvailableUpdatesPolicy,
      HighConfidenceOptOut, MicrosoftUpdateManagedOptIn)
    - OS build/version, since the confidence-driven automatic rollout targets
      specific supported versions

    Supports -ComputerName for remote audit via Invoke-Command (WinRM), or omit for
    local execution. Designed for fleet sweeps ahead of the June 2026 deadline —
    run against a device list and export to CSV for prioritization.

    This script does NOT and CANNOT:
    - Read the underlying firmware/OEM-side reason a device is Incapable (only that
      it is)
    - Force a firmware update
    - Guarantee -Decoded certificate parsing succeeds on very old builds (falls back
      to a text note rather than failing the whole run)

.PARAMETER ComputerName
    One or more remote computer names to audit via WinRM. Omit to run locally only.

.PARAMETER TriggerDeployment
    If set, and the audited device shows UEFICA2023Status NotStarted with no
    existing policy-driven trigger (AvailableUpdatesPolicy unset), sets
    AvailableUpdates to 0x5944 and forces the servicing scheduled task to run.
    Prompts for confirmation per device. Omit to run in pure read-only audit mode
    (the default and recommended usage for fleet-wide sweeps).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\SecureBoot2023-Audit-<date>.csv.

.EXAMPLE
    # Audit the local device only
    .\Get-SecureBoot2023CertStatus.ps1

.EXAMPLE
    # Audit a list of remote devices
    .\Get-SecureBoot2023CertStatus.ps1 -ComputerName (Get-Content .\devices.txt)

.EXAMPLE
    # Audit and trigger deployment on any NotStarted device with no policy trigger
    .\Get-SecureBoot2023CertStatus.ps1 -ComputerName "DESKTOP-CORP01" -TriggerDeployment

.NOTES
    Requires: local admin (or remote admin via WinRM) to read HKLM\SYSTEM keys and
      run Get-SecureBootUEFI / Confirm-SecureBootUEFI.
    -Decoded parameter support for Get-SecureBootUEFI requires a sufficiently recent
      Windows 11 build; older builds will show a fallback note rather than cert names.
    Default mode (no -TriggerDeployment) is fully read-only and safe to run broadly.
    -TriggerDeployment makes a real registry change and forces a scheduled task —
      use deliberately, prefer GPO/Intune for production fleet-wide rollout instead.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [string[]]$ComputerName,

    [Parameter()]
    [switch]$TriggerDeployment,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\SecureBoot2023-Audit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

$auditScriptBlock = {
    param([bool]$DoTrigger)

    $result = [ordered]@{
        ComputerName             = $env:COMPUTERNAME
        SecureBootEnabled        = $null
        OSDisplayVersion         = $null
        OSBuild                  = $null
        UEFICA2023Status         = $null
        UEFICA2023Error          = $null
        WindowsUEFICA2023Capable = $null
        BucketHash               = $null
        ConfidenceLevel          = $null
        AvailableUpdates         = $null
        AvailableUpdatesPolicy   = $null
        HighConfidenceOptOut     = $null
        MicrosoftUpdateManagedOptIn = $null
        DbHasWindowsUEFICA2023   = $null
        TriggerAction            = "None"
        Notes                    = @()
    }

    try {
        $result.SecureBootEnabled = Confirm-SecureBootUEFI
    }
    catch {
        $result.Notes += "Confirm-SecureBootUEFI failed: $($_.Exception.Message)"
    }

    if ($result.SecureBootEnabled -ne $true) {
        $result.Notes += "Secure Boot not enabled - certificate transition status not applicable until firmware Secure Boot is on."
    }

    $osInfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    if ($osInfo) {
        $result.OSDisplayVersion = $osInfo.DisplayVersion
        $result.OSBuild = "$($osInfo.CurrentBuild).$($osInfo.UBR)"
    }

    $servicing = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -ErrorAction SilentlyContinue
    if ($servicing) {
        $result.UEFICA2023Status = $servicing.UEFICA2023Status
        $result.UEFICA2023Error = $servicing.UEFICA2023Error
        $result.WindowsUEFICA2023Capable = $servicing.WindowsUEFICA2023Capable
        $result.BucketHash = $servicing.BucketHash
        $result.ConfidenceLevel = $servicing.ConfidenceLevel
    }
    else {
        $result.Notes += "Servicing registry key not present - device may predate this rollout mechanism or updates have not reached it yet."
    }

    $trigger = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -ErrorAction SilentlyContinue
    if ($trigger) {
        $result.AvailableUpdates = $trigger.AvailableUpdates
        $result.AvailableUpdatesPolicy = $trigger.AvailableUpdatesPolicy
        $result.HighConfidenceOptOut = $trigger.HighConfidenceOptOut
        $result.MicrosoftUpdateManagedOptIn = $trigger.MicrosoftUpdateManagedOptIn
    }

    try {
        $db = Get-SecureBootUEFI -Name db -Decoded -ErrorAction Stop
        $dbText = ($db | Out-String)
        $result.DbHasWindowsUEFICA2023 = ($dbText -match "Windows UEFI CA 2023" -or $dbText -match "Microsoft UEFI CA 2023")
    }
    catch {
        $result.Notes += "Get-SecureBootUEFI -Decoded not supported on this build or failed: $($_.Exception.Message)"
    }

    # Optional guarded deployment trigger
    if ($DoTrigger -and $result.SecureBootEnabled -eq $true) {
        $alreadyTriggered = ($result.AvailableUpdates -and $result.AvailableUpdates -ne 0) -or
                             ($result.AvailableUpdatesPolicy -and $result.AvailableUpdatesPolicy -ne 0)
        if ($result.UEFICA2023Status -eq "NotStarted" -and -not $alreadyTriggered) {
            try {
                reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot" /v AvailableUpdates /t REG_DWORD /d 0x5944 /f | Out-Null
                Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update" -ErrorAction SilentlyContinue
                $result.TriggerAction = "Triggered (AvailableUpdates=0x5944, task started)"
            }
            catch {
                $result.TriggerAction = "Trigger attempt failed: $($_.Exception.Message)"
            }
        }
        elseif ($alreadyTriggered) {
            $result.TriggerAction = "Skipped - a deployment trigger already exists (policy or manual)"
        }
        else {
            $result.TriggerAction = "Skipped - status is not NotStarted ($($result.UEFICA2023Status))"
        }
    }

    $result.Notes = ($result.Notes -join " | ")
    [PSCustomObject]$result
}

#region Run locally or remotely
Write-Status "Starting Secure Boot 2023 certificate transition audit..." -Status SECTION

$results = @()

if ($ComputerName) {
    foreach ($cn in $ComputerName) {
        Write-Status "Auditing $cn..." -Status INFO
        try {
            if ($TriggerDeployment) {
                if ($PSCmdlet.ShouldProcess($cn, "Audit and potentially trigger Secure Boot 2023 certificate deployment")) {
                    $results += Invoke-Command -ComputerName $cn -ScriptBlock $auditScriptBlock -ArgumentList $true -ErrorAction Stop
                }
            }
            else {
                $results += Invoke-Command -ComputerName $cn -ScriptBlock $auditScriptBlock -ArgumentList $false -ErrorAction Stop
            }
        }
        catch {
            Write-Status "Failed to audit $cn : $($_.Exception.Message)" -Status ERROR
            $results += [PSCustomObject]@{ ComputerName = $cn; Notes = "Remote audit failed: $($_.Exception.Message)" }
        }
    }
}
else {
    if ($TriggerDeployment) {
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Audit and potentially trigger Secure Boot 2023 certificate deployment")) {
            $results += & $auditScriptBlock $true
        }
    }
    else {
        $results += & $auditScriptBlock $false
    }
}
#endregion

#region Report
Write-Status "Audit results" -Status SECTION
foreach ($r in $results) {
    $statusColour = switch ($r.UEFICA2023Status) {
        "Updated"    { "OK" }
        "InProgress" { "INFO" }
        "NotStarted" { "WARN" }
        default      { "ERROR" }
    }
    if ($r.WindowsUEFICA2023Capable -eq 0 -and $r.UEFICA2023Status -ne "Updated") {
        $statusColour = "ERROR"
    }
    Write-Status "$($r.ComputerName): Status=$($r.UEFICA2023Status) Capable=$($r.WindowsUEFICA2023Capable) Error=$($r.UEFICA2023Error) SecureBoot=$($r.SecureBootEnabled)" -Status $statusColour
}

$results | Format-Table ComputerName, SecureBootEnabled, UEFICA2023Status, WindowsUEFICA2023Capable, UEFICA2023Error, OSDisplayVersion -AutoSize
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" -Status OK

$notStarted = ($results | Where-Object { $_.UEFICA2023Status -eq "NotStarted" }).Count
$incapable  = ($results | Where-Object { $_.WindowsUEFICA2023Capable -eq 0 -and $_.UEFICA2023Status -ne "Updated" }).Count
$errored    = ($results | Where-Object { $_.UEFICA2023Error -and $_.UEFICA2023Error -ne 0 }).Count

Write-Status "Summary: $notStarted not-started, $errored with errors, $incapable potentially hardware-incapable. Prioritize incapable/error devices for OEM/firmware follow-up." -Status $(if ($incapable -gt 0 -or $errored -gt 0) { "WARN" } else { "OK" })
#endregion
