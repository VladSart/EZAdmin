<#
.SYNOPSIS
    Read-only audit of Azure VM boot/disk repair readiness -- classifies encryption state,
    generation, managed-disk status, and recommends the correct repair path per VM.

.DESCRIPTION
    Companion script to VMBootRepair-A.md / VMBootRepair-B.md. For one VM or an entire
    resource group, collects the facts needed to choose a repair path BEFORE a repair-VM
    is created, so the wrong (ineligible) method isn't attempted:
      - Power/provisioning state and HyperV generation (Gen 1 vs Gen 2 -- determines which
        bcdedit command syntax applies if a BCD repair is later needed)
      - Azure Disk Encryption (ADE) status and, if encrypted, extension version --
        version 1.x (dual-pass) has NO automated unlock path; version 2.x+ (single-pass)
        supports both the automated and semi-automated `az vm repair` unlock methods
      - Managed vs. unmanaged OS disk (unmanaged disks use a materially different, out-of-
        scope attach/repair mechanic -- see VMBootRepair-A.md's Scope & Assumptions)
      - Boot diagnostics enabled state (a prerequisite for classifying a boot symptom at all)
      - Existing snapshots of the OS disk, so an operator can see at a glance whether a
        pre-repair rollback point already exists or still needs to be taken
      - A computed `RecommendedRepairPath` string pointing at the correct Playbook/Fix
        section in VMBootRepair-A.md / -B.md for that VM's specific state

    This script does NOT create, attach, or detach any disk, snapshot, or repair VM. It is
    read-only by design -- it answers "which procedure applies here" before any offline
    repair work begins, per VMBootRepair-A.md's Phase 2 ("establish the repair-path
    prerequisites before creating any repair VM or snapshot").

.PARAMETER ResourceGroupName
    Optional. Limit the audit to a single resource group. If omitted, audits every VM the
    authenticated context has Reader access to across the current subscription.

.PARAMETER VMName
    Optional. Limit the audit to a single VM within -ResourceGroupName. Requires
    -ResourceGroupName to also be supplied.

.PARAMETER IncludeBootDiagnosticsScreenshot
    Optional switch. When set, also attempts to pull the current boot diagnostics screenshot
    and serial log for each audited VM to -OutputPath (one subfolder per VM). Adds noticeable
    runtime per VM -- recommended for single-VM audits, not large fleet sweeps.

.PARAMETER OutputPath
    Optional. Folder to write the CSV evidence export (and, if requested, boot diagnostics
    data) to. Defaults to the current directory.

.EXAMPLE
    .\Get-AzureVMBootRepairAudit.ps1 -ResourceGroupName "rg-prod-compute" -VMName "vm-app01" -IncludeBootDiagnosticsScreenshot

    Full single-VM readiness audit including a fresh boot diagnostics pull.

.EXAMPLE
    .\Get-AzureVMBootRepairAudit.ps1 -ResourceGroupName "rg-prod-compute"

    Fleet-wide repair-readiness audit of every VM in the resource group (encryption state/
    version, generation, managed-disk status, existing snapshots, recommended repair path)
    without pulling boot diagnostics data.

.NOTES
    Requires: Az.Compute, Az.KeyVault (Az PowerShell), already-authenticated context
    (Connect-AzAccount).
    Read-only. Safe to run at any time, including against a production fleet.
    Run-as: Reader on the audited resource group(s)/subscription is sufficient for everything
    except -IncludeBootDiagnosticsScreenshot, which requires read access to the boot
    diagnostics storage account's blobs (typically granted alongside Reader via the storage
    account's own RBAC, but verify if using a customer-managed non-managed storage account).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeBootDiagnosticsScreenshot,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if ($VMName -and -not $ResourceGroupName) {
    Write-Status "-VMName requires -ResourceGroupName to also be supplied." "ERROR"
    return
}

try {
    $context = Get-AzContext
    if (-not $context) {
        throw "No active Az context."
    }
    Write-Status "Authenticated as $($context.Account.Id) against subscription $($context.Subscription.Name)" "OK"
}
catch {
    Write-Status "Not authenticated. Run Connect-AzAccount before this script." "ERROR"
    return
}

if (-not (Test-Path -Path $OutputPath)) {
    Write-Status "OutputPath '$OutputPath' does not exist -- creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Detect -- enumerate the VM(s) in scope
# ---------------------------------------------------------------------------

Write-Status "Enumerating VMs in scope..." "INFO"

$vmList = @()
if ($VMName) {
    $vmList = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName)
}
elseif ($ResourceGroupName) {
    $vmList = @(Get-AzVM -ResourceGroupName $ResourceGroupName)
}
else {
    $vmList = @(Get-AzVM)
}

if ($vmList.Count -eq 0) {
    Write-Status "No VMs found in the specified scope." "WARN"
    return
}

Write-Status "Auditing $($vmList.Count) VM(s)." "INFO"

# ---------------------------------------------------------------------------
# Execute -- per-VM audit
# ---------------------------------------------------------------------------

$results = New-Object System.Collections.Generic.List[Object]

foreach ($vmRef in $vmList) {
    $rg = $vmRef.ResourceGroupName
    $name = $vmRef.Name
    Write-Status "Auditing $rg / $name" "INFO"

    try {
        $vmStatus = Get-AzVM -ResourceGroupName $rg -Name $name -Status
        $vmFull = Get-AzVM -ResourceGroupName $rg -Name $name
    }
    catch {
        Write-Status "  Could not retrieve VM details for $name -- $($_.Exception.Message)" "ERROR"
        continue
    }

    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus
    $provisioningState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' } | Select-Object -First 1).DisplayStatus
    $generation = $vmFull.HyperVGeneration
    $osDisk = $vmFull.StorageProfile.OsDisk
    $isManaged = [bool]$osDisk.ManagedDisk
    $bootDiagEnabled = $vmFull.DiagnosticsProfile.BootDiagnostics.Enabled

    $adeEncrypted = "Unknown"
    $adeVersion = "N/A"
    try {
        $encStatus = Get-AzVmDiskEncryptionStatus -ResourceGroupName $rg -VMName $name -ErrorAction SilentlyContinue
        if ($encStatus) {
            $adeEncrypted = $encStatus.OsVolumeEncrypted
        }
        $adeExt = Get-AzVMExtension -ResourceGroupName $rg -VMName $name -ErrorAction SilentlyContinue |
            Where-Object { $_.ExtensionType -like "*DiskEncryption*" } |
            Select-Object -First 1
        if ($adeExt) {
            $adeVersion = $adeExt.TypeHandlerVersion
        }
    }
    catch {
        Write-Status "  Could not determine ADE status for $name -- $($_.Exception.Message)" "WARN"
    }

    $existingSnapshots = @()
    try {
        if ($isManaged -and $osDisk.ManagedDisk.Id) {
            $diskId = $osDisk.ManagedDisk.Id
            $existingSnapshots = @(Get-AzSnapshot -ResourceGroupName $rg -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationData.SourceResourceId -eq $diskId } |
                Select-Object -ExpandProperty Name)
        }
    }
    catch {
        Write-Status "  Could not enumerate snapshots for $name -- $($_.Exception.Message)" "WARN"
    }

    # ---- Recommendation logic (mirrors VMBootRepair-A.md's Symptom/Resolution matrix) ----
    $recommendedPath = "Unable to determine -- verify ADE and managed-disk state manually"
    $isDualPassADE = $false
    if ($adeVersion -ne "N/A" -and $adeVersion -match '^1\.') {
        $isDualPassADE = $true
    }

    if (-not $isManaged) {
        $recommendedPath = "Unmanaged disk -- out of scope for automated/semi-automated repair; see unmanaged-disk-offline-repair (MS Learn)"
    }
    elseif ($adeEncrypted -eq "Encrypted" -and $isDualPassADE) {
        $recommendedPath = "ADE v1 (dual-pass) encrypted -- manual KEK/BEK unwrap only (Playbook 4)"
    }
    elseif ($adeEncrypted -eq "Encrypted") {
        $recommendedPath = "ADE v2+ (single-pass) encrypted -- automated 'az vm repair --unlock-encrypted-vm' (Playbook 2) if public IP allowed, else semi-automated BEK-volume method (Playbook 3)"
    }
    elseif ($adeEncrypted -eq "NotEncrypted") {
        $recommendedPath = "Unencrypted managed disk -- automated 'az vm repair' (Playbook 2), fastest eligible path"
    }

    $flagStopped = ($powerState -notlike "*running*")
    $flagNoBootDiag = (-not $bootDiagEnabled)
    $flagNoSnapshot = ($existingSnapshots.Count -eq 0)

    $results.Add([PSCustomObject]@{
        ResourceGroup        = $rg
        VMName               = $name
        PowerState           = $powerState
        ProvisioningState    = $provisioningState
        HyperVGeneration     = $generation
        OsDiskManaged        = $isManaged
        OsDiskName           = $osDisk.Name
        ADEEncrypted         = $adeEncrypted
        ADEExtensionVersion  = $adeVersion
        ADEIsDualPassV1      = $isDualPassADE
        BootDiagnosticsOn    = $bootDiagEnabled
        ExistingOsSnapshots  = ($existingSnapshots -join '; ')
        FlagVMNotRunning     = $flagStopped
        FlagNoBootDiagnostics = $flagNoBootDiag
        FlagNoExistingSnapshot = $flagNoSnapshot
        RecommendedRepairPath = $recommendedPath
    })

    if ($IncludeBootDiagnosticsScreenshot) {
        $vmOutDir = Join-Path -Path $OutputPath -ChildPath "$rg-$name-BootDiag"
        try {
            if (-not (Test-Path -Path $vmOutDir)) {
                New-Item -Path $vmOutDir -ItemType Directory -Force | Out-Null
            }
            Get-AzVMBootDiagnosticsData -ResourceGroupName $rg -Name $name -Windows -LocalPath $vmOutDir -ErrorAction Stop | Out-Null
            Write-Status "  Boot diagnostics data written to $vmOutDir" "OK"
        }
        catch {
            Write-Status "  Could not retrieve boot diagnostics data for $name -- $($_.Exception.Message)" "WARN"
        }
    }
}

# ---------------------------------------------------------------------------
# Validate / Report
# ---------------------------------------------------------------------------

$notRunningCount = ($results | Where-Object FlagVMNotRunning).Count
$noBootDiagCount = ($results | Where-Object FlagNoBootDiagnostics).Count
$noSnapshotCount = ($results | Where-Object FlagNoExistingSnapshot).Count
$dualPassCount = ($results | Where-Object ADEIsDualPassV1).Count

Write-Status "Audit complete: $($results.Count) VM(s) processed." "OK"
if ($notRunningCount -gt 0) { Write-Status "$notRunningCount VM(s) are not currently running." "WARN" }
if ($noBootDiagCount -gt 0) { Write-Status "$noBootDiagCount VM(s) have boot diagnostics disabled -- cannot classify a boot symptom until enabled." "WARN" }
if ($noSnapshotCount -gt 0) { Write-Status "$noSnapshotCount VM(s) have no existing OS disk snapshot on record -- take one before any offline repair." "WARN" }
if ($dualPassCount -gt 0) { Write-Status "$dualPassCount VM(s) use ADE v1 (dual-pass) encryption -- no automated unlock path exists for these." "WARN" }

$csvPath = Join-Path -Path $OutputPath -ChildPath ("AzureVMBootRepairAudit_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Results exported to $csvPath" "OK"

$results | Format-Table ResourceGroup, VMName, PowerState, HyperVGeneration, ADEEncrypted, ADEExtensionVersion, OsDiskManaged, RecommendedRepairPath -AutoSize
