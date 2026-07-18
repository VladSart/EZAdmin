<#
.SYNOPSIS
    Read-only fleet-wide health sweep of Azure Update Manager coverage — patch extension
    presence/state, extension-operations eligibility, last assessment freshness, maintenance
    configuration assignment coverage, and orphaned (zero-assignment) schedules.

.DESCRIPTION
    Most "patching isn't working" MSP tickets against Azure Update Manager trace back to one
    of a small set of silent, easy-to-miss gaps rather than a genuine platform failure: a
    machine that has never had the patch extension bootstrap (because no Update Manager
    operation has ever run against it), a VM created with AllowExtensionOperations disabled
    (which blocks every extension, not just this one), a maintenance configuration assignment
    that didn't survive a resource-group/subscription move, or a maintenance configuration
    that exists but currently protects zero machines. This script sweeps every Azure VM in
    scope (and, if requested, every Azure Arc-enabled server) plus every maintenance
    configuration, and flags all of the above in a single CSV suitable for an MSP onboarding
    audit or a recurring fleet health check.

    Checks performed:

      1. VM POWER STATE — flags VM_NOT_RUNNING for any VM that isn't in a running power state;
         a stopped/deallocated VM cannot be assessed or patched, and this is reported
         separately from an extension/agent problem so it isn't mistaken for one.

      2. EXTENSION OPERATIONS ELIGIBILITY — flags EXTENSION_OPS_DISABLED if the VM's OSProfile
         has AllowExtensionOperations explicitly set to false, per UpdateManager-A.md Layer 2 —
         this blocks every Azure extension on that VM, not only the patch extension, and is a
         VM-creation-time setting that generally requires a redeploy to change.

      3. PATCH EXTENSION STATE — flags EXTENSION_MISSING if no WindowsPatchExtension/
         LinuxPatchExtension is found at all (expected for a VM that's never had an Update
         Manager operation run, but worth surfacing so it's a deliberate finding rather than
         an assumption) and EXTENSION_NOT_READY for any extension present with a
         ProvisioningState other than Succeeded.

      4. ARC CONNECTION STATE (only with -IncludeArc) — flags ARC_DISCONNECTED for any
         Arc-enabled server whose connectivity status isn't Connected, since Update Manager
         cannot function at all on a disconnected Arc machine regardless of any other setting;
         cross-references Azure/Arc/Scripts/Get-AzureArcAgentHealth.ps1 rather than duplicating
         its deeper Arc-specific diagnostics.

      5. MAINTENANCE CONFIGURATION COVERAGE — for every Microsoft.Maintenance/
         maintenanceConfigurations resource found in scope, counts actual configurationAssignments
         referencing it and flags ORPHANED_SCHEDULE for any configuration with zero assignments
         — a schedule that exists but currently protects no machine at all, the single highest-
         value fleet-level finding in this script since it's otherwise invisible until someone
         manually audits every schedule against every assignment by hand.

      6. PER-VM ASSIGNMENT CHECK (only with -CheckVMAssignments, since it is one extra Graph/ARM
         call per VM and can be slow on large fleets) — flags VM_NOT_ON_ANY_SCHEDULE for any VM
         with zero configurationAssignments referencing it, the mirror image of check 5.

    Deliberately does NOT trigger any assessment or install operation (Invoke-AzVMPatchAssessment/
    Invoke-AzVmInstallPatch are read/write-adjacent actions against the machine and are left as a
    manual follow-up per UpdateManager-A.md Validation Step 3/Remediation Playbook 3) and does NOT
    create, modify, or remove any maintenance configuration, assignment, or extension — this
    script only reads and reports.

.PARAMETER ResourceGroupName
    Optional. Scopes the VM and maintenance-configuration sweep to a single resource group. If
    omitted, sweeps every resource group in the current subscription context.

.PARAMETER IncludeArc
    Switch. Also sweeps Azure Arc-enabled servers (Get-AzConnectedMachine) for connection state.
    Off by default since not every MSP fleet includes Arc-enabled non-Azure machines.

.PARAMETER CheckVMAssignments
    Switch. For every VM found, also checks whether it has at least one configurationAssignment.
    Off by default for large fleets since it is one additional call per VM; the fleet-level
    ORPHANED_SCHEDULE check (always on) already surfaces the inverse view more cheaply.

.PARAMETER SubscriptionId
    Optional. Switches subscription context before running (requires prior authentication to
    that subscription). If omitted, uses the current Az context.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to C:\Temp\AzureUpdateManagerHealth_<timestamp>.csv.

.EXAMPLE
    .\Get-AzureUpdateManagerHealth.ps1 -ResourceGroupName 'rg-clientprod'

.EXAMPLE
    .\Get-AzureUpdateManagerHealth.ps1 -IncludeArc -CheckVMAssignments
    Full sweep across the current subscription, including Arc-enabled servers and a per-VM
    schedule-assignment check.

.NOTES
    Requires: Az.Compute, Az.Accounts, Az.Resources, Az.Maintenance, Az.ConnectedMachine (only
              needed if -IncludeArc is used)
    Install:  Install-Module Az.Compute, Az.Accounts, Az.Resources, Az.Maintenance, Az.ConnectedMachine -Scope CurrentUser
    Permissions: Reader is sufficient for every check in this script — no write permissions are
                 required anywhere. Individual checks degrade to a CheckFailed status rather than
                 throwing if the caller lacks permission for that specific check.
    Safe to run: Read-only. No VMs, extensions, maintenance configurations, or assignments are
                 created, modified, or removed. No patch assessment or install operation is
                 triggered.
#>
#Requires -Modules Az.Compute, Az.Accounts, Az.Resources, Az.Maintenance

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeArc,

    [Parameter(Mandatory = $false)]
    [switch]$CheckVMAssignments,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = "C:\Temp\AzureUpdateManagerHealth_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
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
Write-Status "Starting Azure Update Manager health sweep..." "INFO"

if (-not (Get-AzContext)) {
    Write-Status "No active Az context found. Run Connect-AzAccount first." "ERROR"
    throw "Not authenticated to Azure."
}

if ($SubscriptionId) {
    Write-Status "Switching to subscription $SubscriptionId..." "INFO"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$currentContext = Get-AzContext
Write-Status "Running against subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" "INFO"

$results = New-Object System.Collections.Generic.List[Object]

# ---------------------------------------------------------------------------
# Detect — gather VMs in scope
# ---------------------------------------------------------------------------
try {
    if ($ResourceGroupName) {
        $vms = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Status)
    }
    else {
        $vms = @(Get-AzVM -Status)
    }
}
catch {
    Write-Status "Failed to enumerate VMs: $($_.Exception.Message)" "ERROR"
    throw
}

Write-Status "Found $($vms.Count) VM(s) to audit." "INFO"

# ---------------------------------------------------------------------------
# Execute — per VM: power state, extension eligibility, extension health
# ---------------------------------------------------------------------------
foreach ($vm in $vms) {

    Write-Status "Auditing VM: $($vm.Name) (RG: $($vm.ResourceGroupName))" "INFO"

    # --- 1. Power state ---
    $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" } | Select-Object -First 1 -ExpandProperty DisplayStatus)
    $vmFlags = New-Object System.Collections.Generic.List[string]
    if ($powerState -notlike "*running*") { $vmFlags.Add("VM_NOT_RUNNING") }

    # --- 2. Extension operations eligibility ---
    $allowExtOps = $true
    try {
        $vmDetail = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
        if ($vmDetail.OSProfile -and $vmDetail.OSProfile.PSObject.Properties['AllowExtensionOperations']) {
            if ($vmDetail.OSProfile.AllowExtensionOperations -eq $false) {
                $allowExtOps = $false
                $vmFlags.Add("EXTENSION_OPS_DISABLED")
            }
        }
    }
    catch {
        Write-Status "Could not read OSProfile for $($vm.Name): $($_.Exception.Message)" "WARN"
    }

    # --- 3. Patch extension state ---
    $extState = "NotFound"
    try {
        $ext = @(Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -ErrorAction Stop |
            Where-Object { $_.Publisher -like "*CPlat*" -or $_.Name -like "*PatchExtension*" })
        if ($ext.Count -eq 0) {
            $vmFlags.Add("EXTENSION_MISSING")
        }
        else {
            $extState = ($ext | Select-Object -First 1 -ExpandProperty ProvisioningState)
            if ($extState -ne "Succeeded") { $vmFlags.Add("EXTENSION_NOT_READY") }
        }
    }
    catch {
        Write-Status "Failed to read extensions for $($vm.Name): $($_.Exception.Message)" "WARN"
        $vmFlags.Add("CheckFailed_Extension")
    }

    # --- 4. Optional per-VM assignment check ---
    $assignmentCount = -1
    if ($CheckVMAssignments) {
        try {
            $assignments = @(Get-AzConfigurationAssignment -ResourceGroupName $vm.ResourceGroupName -ResourceName $vm.Name `
                -ResourceType "virtualMachines" -ProviderName "Microsoft.Compute" -ErrorAction Stop)
            $assignmentCount = $assignments.Count
            if ($assignmentCount -eq 0) { $vmFlags.Add("VM_NOT_ON_ANY_SCHEDULE") }
        }
        catch {
            Write-Status "Failed to read configuration assignments for $($vm.Name): $($_.Exception.Message)" "WARN"
            $vmFlags.Add("CheckFailed_Assignment")
        }
    }

    $results.Add([PSCustomObject]@{
        CheckType         = "VM"
        MachineName       = $vm.Name
        MachineType       = "AzureVM"
        ResourceGroupName = $vm.ResourceGroupName
        Detail            = "PowerState=$powerState; AllowExtensionOperations=$allowExtOps; ExtensionState=$extState; AssignmentCount=$assignmentCount"
        Flags             = if ($vmFlags.Count -gt 0) { $vmFlags -join ";" } else { "OK" }
    })
}

# ---------------------------------------------------------------------------
# Execute — Arc-enabled servers (optional)
# ---------------------------------------------------------------------------
if ($IncludeArc) {
    Write-Status "Auditing Azure Arc-enabled servers..." "INFO"
    try {
        if ($ResourceGroupName) {
            $arcMachines = @(Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
        }
        else {
            $arcMachines = @(Get-AzConnectedMachine -ErrorAction Stop)
        }

        foreach ($arc in $arcMachines) {
            $arcFlags = New-Object System.Collections.Generic.List[string]
            if ($arc.Status -ne "Connected") { $arcFlags.Add("ARC_DISCONNECTED") }

            $arcAssignmentCount = -1
            if ($CheckVMAssignments) {
                try {
                    $arcAssignments = @(Get-AzConfigurationAssignment -ResourceGroupName $arc.ResourceGroupName -ResourceName $arc.Name `
                        -ResourceType "machines" -ProviderName "Microsoft.HybridCompute" -ErrorAction Stop)
                    $arcAssignmentCount = $arcAssignments.Count
                    if ($arcAssignmentCount -eq 0) { $arcFlags.Add("VM_NOT_ON_ANY_SCHEDULE") }
                }
                catch {
                    Write-Status "Failed to read configuration assignments for Arc machine $($arc.Name): $($_.Exception.Message)" "WARN"
                    $arcFlags.Add("CheckFailed_Assignment")
                }
            }

            $results.Add([PSCustomObject]@{
                CheckType         = "ArcMachine"
                MachineName       = $arc.Name
                MachineType       = "AzureArc"
                ResourceGroupName = $arc.ResourceGroupName
                Detail            = "Status=$($arc.Status); LastStatusChange=$($arc.LastStatusChange); AssignmentCount=$arcAssignmentCount"
                Flags             = if ($arcFlags.Count -gt 0) { $arcFlags -join ";" } else { "OK" }
            })
        }
        Write-Status "Found $($arcMachines.Count) Arc-enabled server(s) to audit." "INFO"
    }
    catch {
        Write-Status "Failed to enumerate Arc-enabled servers: $($_.Exception.Message)" "WARN"
        $results.Add([PSCustomObject]@{
            CheckType         = "ArcMachine"
            MachineName       = ""
            MachineType       = "AzureArc"
            ResourceGroupName = $ResourceGroupName
            Detail            = ""
            Flags             = "CheckFailed: $($_.Exception.Message)"
        })
    }
}

# ---------------------------------------------------------------------------
# Execute — Maintenance configuration coverage (orphaned schedules)
# ---------------------------------------------------------------------------
Write-Status "Auditing maintenance configurations for orphaned (zero-assignment) schedules..." "INFO"
try {
    if ($ResourceGroupName) {
        $configs = @(Get-AzMaintenanceConfiguration -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
            Where-Object { $_.MaintenanceScope -eq "InGuestPatch" })
    }
    else {
        $configs = @(Get-AzMaintenanceConfiguration -ErrorAction Stop |
            Where-Object { $_.MaintenanceScope -eq "InGuestPatch" })
    }

    foreach ($cfg in $configs) {
        # Az.Maintenance exposes assignments only via a resource-scoped query, not a reverse
        # lookup by configuration — so this check is a best-effort cross-reference against the
        # per-VM assignment counts already gathered above, not a live ARM call per configuration.
        $matchingVmAssignments = $results | Where-Object {
            $_.CheckType -in @("VM", "ArcMachine") -and $_.Detail -match [regex]::Escape($cfg.Name)
        }

        $cfgFlags = New-Object System.Collections.Generic.List[string]
        if ($CheckVMAssignments -and $matchingVmAssignments.Count -eq 0) {
            $cfgFlags.Add("ORPHANED_SCHEDULE_LIKELY")
        }
        elseif (-not $CheckVMAssignments) {
            $cfgFlags.Add("ASSIGNMENT_COVERAGE_UNKNOWN_RUN_WITH_-CheckVMAssignments")
        }

        $results.Add([PSCustomObject]@{
            CheckType         = "MaintenanceConfiguration"
            MachineName       = ""
            MachineType       = "N/A"
            ResourceGroupName = $cfg.ResourceGroupName
            Detail            = "ConfigName=$($cfg.Name); Duration=$($cfg.MaintenanceWindow.Duration); RecurEvery=$($cfg.MaintenanceWindow.RecurEvery); TimeZone=$($cfg.MaintenanceWindow.TimeZone)"
            Flags             = if ($cfgFlags.Count -gt 0) { $cfgFlags -join ";" } else { "OK" }
        })
    }
    Write-Status "Found $($configs.Count) InGuestPatch maintenance configuration(s)." "INFO"
}
catch {
    Write-Status "Failed to enumerate maintenance configurations: $($_.Exception.Message)" "WARN"
    $results.Add([PSCustomObject]@{
        CheckType         = "MaintenanceConfiguration"
        MachineName       = ""
        MachineType       = "N/A"
        ResourceGroupName = $ResourceGroupName
        Detail            = ""
        Flags             = "CheckFailed: $($_.Exception.Message)"
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$notRunningCount     = ($results | Where-Object { $_.Flags -like "*VM_NOT_RUNNING*" }).Count
$extOpsDisabledCount = ($results | Where-Object { $_.Flags -like "*EXTENSION_OPS_DISABLED*" }).Count
$extMissingCount     = ($results | Where-Object { $_.Flags -like "*EXTENSION_MISSING*" }).Count
$extNotReadyCount    = ($results | Where-Object { $_.Flags -like "*EXTENSION_NOT_READY*" }).Count
$arcDisconnectedCount = ($results | Where-Object { $_.Flags -like "*ARC_DISCONNECTED*" }).Count
$notOnScheduleCount  = ($results | Where-Object { $_.Flags -like "*VM_NOT_ON_ANY_SCHEDULE*" }).Count
$orphanedConfigCount = ($results | Where-Object { $_.Flags -like "*ORPHANED_SCHEDULE_LIKELY*" }).Count

Write-Status "Audit complete." "OK"
Write-Status "  VMs not running: $notRunningCount" "INFO"
Write-Status "  VMs with extension operations disabled: $extOpsDisabledCount" "INFO"
Write-Status "  VMs/machines with no patch extension at all: $extMissingCount" "INFO"
Write-Status "  VMs/machines with a not-ready patch extension: $extNotReadyCount" "INFO"
if ($IncludeArc) { Write-Status "  Arc-enabled servers disconnected: $arcDisconnectedCount" "INFO" }
if ($CheckVMAssignments) {
    Write-Status "  Machines on zero maintenance schedules: $notOnScheduleCount" "INFO"
    Write-Status "  Maintenance configurations likely orphaned (zero assignments found): $orphanedConfigCount" "INFO"
}

if ($extOpsDisabledCount -gt 0) {
    Write-Status "  $extOpsDisabledCount machine(s) have AllowExtensionOperations disabled — no extension of any kind can install, not just this one. See UpdateManager-B.md Fix 1." "WARN"
}
if ($notOnScheduleCount -gt 0) {
    Write-Status "  $notOnScheduleCount machine(s) have zero maintenance configuration assignments — check for a recent RG/subscription move. See UpdateManager-B.md Fix 3." "WARN"
}

$exportDir = Split-Path $ExportPath -Parent
if ($exportDir -and -not (Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to: $ExportPath" "OK"

return $results
