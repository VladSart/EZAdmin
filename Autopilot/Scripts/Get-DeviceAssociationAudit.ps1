<#
.SYNOPSIS
    Audits a device's eligibility for Windows Autopilot device association, and (optionally)
    the tenant's device preparation policy inventory.

.DESCRIPTION
    Device-local + optional tenant-level diagnostic supporting
    Autopilot/Troubleshooting/DeviceAssociation-A.md and DeviceAssociation-B.md.

    Local checks (always run):
      - TPM presence/ready/enabled state and Reduced Functionality Mode flag
        (association hard-fails on any of these being unmet)
      - OS build number and presence of the servicing update required for device association
        (KB5120998, Windows 11 24H2/25H2)
      - Physical vs. virtual hardware detection (VMs are never supported for device association)
      - Windows edition (association is limited to Pro / Pro Education / Pro for Workstations /
        Enterprise / Education / Enterprise LTSC)

    Tenant checks (only if -IncludeTenantChecks is passed and Microsoft.Graph.Beta is available
    and connected):
      - Enumerates device preparation policies (device association only applies to these,
        never to classic hardware-hash Autopilot deployment profiles)
      - Enumerates subscribed SKUs as a coarse licensing-eligibility signal

    There is no documented, stable Graph endpoint (as of this writing) to read a specific
    device's association state (Pre-associated / Associated) — that must be confirmed manually
    via Intune admin center > Devices > Enrollment > Device association > Devices. This script
    flags that as a manual-check reminder rather than attempting to fake a read.

    Read-only. Makes no configuration changes and does not run the association-removal script.

.PARAMETER IncludeTenantChecks
    Also query tenant-level device preparation policies and subscribed SKUs via Microsoft Graph
    (beta endpoint). Requires an existing Connect-MgGraph session with
    DeviceManagementConfiguration.Read.All and Organization.Read.All scopes.

.EXAMPLE
    .\Get-DeviceAssociationAudit.ps1

    Runs local hardware/OS eligibility checks only.

.EXAMPLE
    .\Get-DeviceAssociationAudit.ps1 -IncludeTenantChecks

    Also pulls device preparation policy and licensing signals from Graph.

.NOTES
    Requires: Local admin for TPM/CIM queries. For -IncludeTenantChecks, Microsoft.Graph.Beta
    module and an active Connect-MgGraph session.
    Companion runbook: Autopilot/Troubleshooting/DeviceAssociation-A.md and DeviceAssociation-B.md
    Does NOT read or clear the UEFI tenant-affinity marker itself — see DeviceAssociation-B.md
    Fix 5 for the (on-device, script-based) removal path.
#>

[CmdletBinding()]
param(
    [switch]$IncludeTenantChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Check, [string]$Result, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Check = $Check; Result = $Result; Detail = $Detail })
}

Write-Status "Starting Windows Autopilot device association eligibility audit on $env:COMPUTERNAME"

# ---------------------------------------------------------------------------
# 1. Physical vs. virtual hardware — hard requirement, no VM support at all
# ---------------------------------------------------------------------------
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $virtualIndicators = @('Virtual', 'VMware', 'Hyper-V', 'KVM', 'Xen', 'VirtualBox', 'Bochs')
    $isLikelyVM = $virtualIndicators | Where-Object { $cs.Model -match $_ -or $cs.Manufacturer -match $_ }

    if ($isLikelyVM) {
        Write-Status "Device appears to be VIRTUAL ($($cs.Manufacturer) / $($cs.Model)) — device association is NOT supported on VMs" "ERROR"
        Add-Finding "Physical hardware" "FAIL" "Manufacturer='$($cs.Manufacturer)' Model='$($cs.Model)' matched a virtualization indicator"
    } else {
        Write-Status "Device appears physical ($($cs.Manufacturer) / $($cs.Model))" "OK"
        Add-Finding "Physical hardware" "PASS" "Manufacturer='$($cs.Manufacturer)' Model='$($cs.Model)'"
    }
} catch {
    Write-Status "Could not query Win32_ComputerSystem: $($_.Exception.Message)" "ERROR"
    Add-Finding "Physical hardware" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. TPM state — presence, readiness, enablement, Reduced Functionality Mode
# ---------------------------------------------------------------------------
try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady -and $tpm.TpmEnabled -and -not $tpm.TpmRestrictedMode) {
        Write-Status "TPM is present, ready, enabled, and not in Reduced Functionality Mode" "OK"
        Add-Finding "TPM state" "PASS" "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady) Enabled=$($tpm.TpmEnabled) RestrictedMode=$($tpm.TpmRestrictedMode)"
    } else {
        Write-Status "TPM does not meet device association requirements" "ERROR"
        Add-Finding "TPM state" "FAIL" "Present=$($tpm.TpmPresent) Ready=$($tpm.TpmReady) Enabled=$($tpm.TpmEnabled) RestrictedMode=$($tpm.TpmRestrictedMode) — all four must be Present/Ready/Enabled=True and RestrictedMode=False"
    }
} catch {
    Write-Status "Could not query TPM state (Get-Tpm failed — module missing, no TPM, or insufficient privileges): $($_.Exception.Message)" "ERROR"
    Add-Finding "TPM state" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 3. OS build, edition, and servicing update
# ---------------------------------------------------------------------------
try {
    $osInfo = Get-ComputerInfo -ErrorAction Stop
    $buildNumber = $osInfo.OsBuildNumber
    $supportedEditions = @(
        'Windows 11 Pro', 'Windows 11 Pro Education', 'Windows 11 Pro for Workstations',
        'Windows 11 Enterprise', 'Windows 11 Education', 'Windows 11 Enterprise LTSC'
    )
    $editionMatch = $supportedEditions | Where-Object { $osInfo.WindowsProductName -like "*$_*" -or $osInfo.WindowsProductName -eq $_ }

    Write-Status "OS build: $buildNumber ($($osInfo.WindowsProductName))" "INFO"
    if ([int]$buildNumber -ge 26100) {
        Add-Finding "OS build" "PASS (build check)" "Build $buildNumber — consistent with 24H2/25H2; confirm KB5120998 separately below"
    } else {
        Add-Finding "OS build" "FAIL" "Build $buildNumber — device association requires Windows 11 24H2 or 25H2"
    }

    if ($editionMatch) {
        Add-Finding "OS edition" "PASS" "$($osInfo.WindowsProductName) is a supported edition"
    } else {
        Add-Finding "OS edition" "FAIL" "$($osInfo.WindowsProductName) is not in the documented supported-edition list"
    }

    $kb = Get-HotFix -Id 'KB5120998' -ErrorAction SilentlyContinue
    if ($kb) {
        Write-Status "KB5120998 (or a superseding update matching this ID) is installed" "OK"
        Add-Finding "Servicing update" "PASS" "KB5120998 installed on $($kb.InstalledOn)"
    } else {
        Write-Status "KB5120998 not found via Get-HotFix — confirm via Windows Update history, as CU rollups can supersede the discrete KB ID" "WARN"
        Add-Finding "Servicing update" "WARN" "KB5120998 not found by Get-HotFix — verify manually; a later cumulative update likely supersedes it"
    }
} catch {
    Write-Status "Could not query OS build/edition info: $($_.Exception.Message)" "ERROR"
    Add-Finding "OS build/edition" "ERROR" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 4. Manual-check reminder — no stable Graph read for per-device association state
# ---------------------------------------------------------------------------
Write-Status "Association state (Pre-associated / Associated) has no documented stable Graph read as of this writing" "WARN"
Add-Finding "Association state" "MANUAL CHECK REQUIRED" "Confirm in Intune admin center > Devices > Enrollment > Device association > Devices"

# ---------------------------------------------------------------------------
# 5. Optional tenant-level checks
# ---------------------------------------------------------------------------
if ($IncludeTenantChecks) {
    Write-Status "Running tenant-level checks via Microsoft Graph (beta)..." "INFO"
    try {
        $context = Get-MgContext -ErrorAction Stop
        if (-not $context) {
            throw "No active Graph session. Run Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','Organization.Read.All' first."
        }

        try {
            $policies = Get-MgBetaDeviceManagementAutopilotDevicePreparationPolicy -ErrorAction Stop
            if ($policies) {
                Write-Status "Found $($policies.Count) device preparation policy(ies) in tenant" "OK"
                Add-Finding "Device preparation policies" "INFO" ($policies | ForEach-Object { $_.DisplayName }) -join '; '
            } else {
                Write-Status "No device preparation policies found — device association cannot apply without at least one" "WARN"
                Add-Finding "Device preparation policies" "WARN" "Zero device preparation policies found in tenant"
            }
        } catch {
            Write-Status "Could not enumerate device preparation policies: $($_.Exception.Message)" "ERROR"
            Add-Finding "Device preparation policies" "ERROR" $_.Exception.Message
        }

        try {
            $skus = Get-MgSubscribedSku -ErrorAction Stop
            $eligibleSkuHints = @('SPE_E3', 'SPE_E5', 'EMS', 'M365_BUSINESS_PREMIUM', 'AAD_PREMIUM', 'INTUNE')
            $matches = $skus | Where-Object { $sku = $_.SkuPartNumber; $eligibleSkuHints | Where-Object { $sku -match $_ } }
            if ($matches) {
                Write-Status "Found $($matches.Count) subscribed SKU(s) consistent with Autopilot device preparation licensing" "OK"
                Add-Finding "Licensing signal" "INFO" (($matches | ForEach-Object { $_.SkuPartNumber }) -join '; ')
            } else {
                Write-Status "No subscribed SKU matched common eligible-licensing patterns — verify manually, this is a coarse heuristic only" "WARN"
                Add-Finding "Licensing signal" "WARN" "No SKU matched heuristic list — confirm actual entitlement manually"
            }
        } catch {
            Write-Status "Could not enumerate subscribed SKUs: $($_.Exception.Message)" "ERROR"
            Add-Finding "Licensing signal" "ERROR" $_.Exception.Message
        }
    } catch {
        Write-Status "Tenant-level checks skipped: $($_.Exception.Message)" "ERROR"
        Add-Finding "Tenant checks" "SKIPPED" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Device Association Eligibility Summary ===" -ForegroundColor Cyan
$findings | Format-Table -AutoSize -Wrap

$failCount = ($findings | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Status "$failCount blocking finding(s) — device association will not succeed until these are resolved" "ERROR"
} else {
    Write-Status "No blocking hardware/OS findings — device is locally eligible. Confirm pre-association/association state and tenant licensing/policy separately." "OK"
}

$outPath = ".\DeviceAssociationAudit_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$findings | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Results exported to: $outPath" -ForegroundColor Green
