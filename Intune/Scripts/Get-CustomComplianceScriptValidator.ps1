<#
.SYNOPSIS
    Validates an Intune Custom Compliance discovery script locally and cross-references
    fleet-wide compliance state via Graph.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/CustomCompliance-B.md and -A.md.

    Custom Compliance failures fall into two buckets that this script targets directly:
      1. LOCAL — the discovery script itself is broken (non-JSON output, wrong key
         names, exceptions, timeout). CustomCompliance-B.md Fix 1/Fix 2 and -A.md's
         "Boolean serialisation gotcha" Learning Pointer both call these out as the
         most common root causes.
      2. FLEET — the script is fine, but devices are stuck in `error`/`nonCompliant`/
         `unknown` because of IME health, assignment gaps, or the ~8h evaluation
         interval (per -A.md Symptom -> Cause Map and Dependency Stack).

    Local mode (-ScriptPath supplied, run ON a Windows endpoint):
      - Executes the discovery script exactly as IME would (captures STDOUT only,
        applies a configurable timeout mirroring IME's 30s default)
      - Validates the captured output is parseable JSON
      - Reports the JSON key names and types found, so they can be diff'd by eye
        against the compliance rule "Setting name" values in the Intune portal
      - Flags any [bool] values that would have serialised as the string "True"/
        "False" instead of a JSON boolean (the gotcha in CustomCompliance-A.md)

    Fleet mode (-PolicyId supplied, run from an admin workstation with Graph):
      - Pulls per-device compliance status for the named custom compliance policy
      - Buckets devices into Compliant / NonCompliant / Error / Unknown / InGracePeriod
      - Flags devices whose LastReportedDateTime is older than one evaluation cycle
        (~8h, configurable via -StaleHours) as STALE_EVALUATION — these haven't
        re-run the script since the last policy/script change and may show old state

    Both modes can be run together or independently. This script makes no policy,
    script-upload, or device changes — it is a read-only diagnostic.

.PARAMETER ScriptPath
    Path to a local discovery script (.ps1) to test. Run this on the affected Windows
    device, ideally as SYSTEM (e.g., via PsExec -s -i) to mirror IME's actual context.

.PARAMETER TimeoutSeconds
    Timeout applied when executing the local script, mirroring IME's discovery script
    timeout. Default: 30 (matches the Intune default per CustomCompliance-A.md).

.PARAMETER PolicyId
    Intune custom compliance policy ID to pull fleet-wide device status for via Graph.

.PARAMETER StaleHours
    Hours since LastReportedDateTime before a device's status is flagged STALE_EVALUATION.
    Default: 9 (slightly above the ~8h default evaluation interval).

.PARAMETER OutputPath
    Folder to write the fleet CSV report to. Default: current directory.

.EXAMPLE
    .\Get-CustomComplianceScriptValidator.ps1 -ScriptPath "C:\Scripts\FirewallCheck.ps1"
    Runs the discovery script locally, captures STDOUT only, and validates the JSON.

.EXAMPLE
    .\Get-CustomComplianceScriptValidator.ps1 -PolicyId "<compliancePolicyId>"
    Pulls fleet-wide device compliance status for the named policy via Graph.

.EXAMPLE
    .\Get-CustomComplianceScriptValidator.ps1 -ScriptPath ".\Discover.ps1" -PolicyId "<id>"
    Runs both local script validation and the fleet-wide Graph report in one pass.

.NOTES
    Requires (local mode):  Windows PowerShell 5.1+, run as SYSTEM for a faithful test
                            (PsExec -s -i powershell.exe -File Get-CustomComplianceScriptValidator.ps1 ...)
    Requires (fleet mode):  Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    Scopes (fleet mode):    DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All
    Safe/Unsafe:            Fully read-only against Graph. Local mode executes the target
                            script itself, so treat -ScriptPath contents with the same
                            caution as running any untrusted script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 30,

    [Parameter(Mandatory = $false)]
    [string]$PolicyId,

    [Parameter(Mandatory = $false)]
    [int]$StaleHours = 9,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not $ScriptPath -and -not $PolicyId) {
    Write-Status "Provide at least one of -ScriptPath or -PolicyId. See -Examples (Get-Help .\Get-CustomComplianceScriptValidator.ps1 -Examples)." "ERROR"
    return
}

# ---------------------------------------------------------------------------
# LOCAL MODE — validate the discovery script's output exactly as IME would
# ---------------------------------------------------------------------------
if ($ScriptPath) {
    Write-Status "=== Local Discovery Script Validation ===" "INFO"

    if (-not (Test-Path $ScriptPath)) {
        Write-Status "Script not found at path: $ScriptPath" "ERROR"
    }
    else {
        Write-Status "Executing '$ScriptPath' with a ${TimeoutSeconds}s timeout (mirrors IME behaviour)..."

        $job = Start-Job -ScriptBlock {
            param($path)
            & $path
        } -ArgumentList $ScriptPath

        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Write-Status "Script did NOT complete within ${TimeoutSeconds}s — IME would report 'error' for a timeout." "ERROR"
        }
        else {
            # Only STDOUT-equivalent (Output stream) matters — mirrors IME's parser.
            $stdOut = Receive-Job -Job $job 2>$null
            $errStream = $job.ChildJobs[0].Error

            if ($errStream.Count -gt 0) {
                Write-Status "Script wrote to the error stream (would be discarded by IME, but indicates a caught/uncaught exception):" "WARN"
                $errStream | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
            }

            $outputText = ($stdOut | Out-String).Trim()

            if ([string]::IsNullOrWhiteSpace($outputText)) {
                Write-Status "Script produced no STDOUT output — IME would report 'error' (empty payload)." "ERROR"
            }
            else {
                try {
                    $json = $outputText | ConvertFrom-Json -ErrorAction Stop
                    Write-Status "Output is valid JSON." "OK"

                    $props = $json.PSObject.Properties
                    Write-Status "Keys found ($($props.Count)):" "INFO"
                    foreach ($p in $props) {
                        $typeName = $p.Value.GetType().Name
                        $warn = ""
                        if ($typeName -eq "String" -and ($p.Value -eq "True" -or $p.Value -eq "False")) {
                            $warn = "  <-- WARNING: looks like a stringified boolean, not a real JSON bool. Cast source value as [bool] before ConvertTo-Json."
                        }
                        Write-Host "    $($p.Name) = $($p.Value)  [$typeName]$warn" -ForegroundColor $(if ($warn) { "Yellow" } else { "Gray" })
                    }
                    Write-Status "Compare these key names EXACTLY (case-insensitive but must match) against the compliance rule 'Setting name' values in the Intune portal." "INFO"
                }
                catch {
                    Write-Status "Output is NOT valid JSON — IME would report 'error'. This is the #1 custom compliance failure mode per CustomCompliance-B.md Fix 1." "ERROR"
                    Write-Host "--- Raw captured output ---" -ForegroundColor DarkGray
                    Write-Host $outputText -ForegroundColor DarkGray
                    Write-Host "----------------------------" -ForegroundColor DarkGray
                }
            }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# FLEET MODE — Graph-side compliance state for the policy
# ---------------------------------------------------------------------------
if ($PolicyId) {
    Write-Status "=== Fleet Compliance Status (Policy: $PolicyId) ===" "INFO"

    try {
        $context = Get-MgContext
        if (-not $context) {
            Write-Status "Not connected. Connecting with required scopes..." "WARN"
            Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome
        }
        else {
            Write-Status "Connected as $($context.Account)" "OK"
        }
    }
    catch {
        Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        throw
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportFile = Join-Path $OutputPath "CustomComplianceFleetStatus-$timestamp.csv"

    try {
        $statuses = Get-MgDeviceManagementCompliancePolicyDeviceStatus -DeviceCompliancePolicyId $PolicyId -All
    }
    catch {
        Write-Status "Failed to retrieve device statuses for policy '$PolicyId': $($_.Exception.Message)" "ERROR"
        throw
    }

    $staleThreshold = (Get-Date).AddHours(-$StaleHours)
    $report = $statuses | ForEach-Object {
        $lastReported = $_.LastReportedDateTime
        $flags = New-Object System.Collections.Generic.List[string]

        if ($_.Status -eq "error") { $flags.Add("SCRIPT_OR_JSON_ERROR") }
        if ($_.Status -eq "unknown") { $flags.Add("NOT_YET_EVALUATED_OR_NOT_ASSIGNED") }
        if ($lastReported -and $lastReported -lt $staleThreshold) { $flags.Add("STALE_EVALUATION") }

        [PSCustomObject]@{
            DeviceName          = $_.DeviceDisplayName
            UserName            = $_.UserName
            Status              = $_.Status
            LastReportedDateTime = $lastReported
            GracePeriodExpiration = $_.ComplianceGracePeriodExpirationDateTime
            Flags               = ($flags -join "; ")
        }
    }

    $report | Sort-Object Status, DeviceName | Export-Csv -Path $reportFile -NoTypeInformation

    Write-Host ""
    Write-Status "Compliant:        $(@($report | Where-Object Status -eq 'compliant').Count)" "OK"
    Write-Status "NonCompliant:     $(@($report | Where-Object Status -eq 'nonCompliant').Count)" "WARN"
    Write-Status "Error:            $(@($report | Where-Object Status -eq 'error').Count)" "ERROR"
    Write-Status "Unknown:          $(@($report | Where-Object Status -eq 'unknown').Count)" "WARN"
    Write-Status "STALE_EVALUATION (>${StaleHours}h): $(@($report | Where-Object { $_.Flags -match 'STALE_EVALUATION' }).Count)" "WARN"
    Write-Host ""
    Write-Status "Full fleet report exported to: $reportFile" "OK"

    if (@($report | Where-Object Status -eq 'error').Count -gt 0) {
        Write-Status "Devices in 'error' state almost always mean the discovery script itself is broken on those devices (non-JSON output, exception, or timeout) — re-run this script with -ScriptPath against a representative failing device (as SYSTEM) to confirm." "WARN"
    }
}
