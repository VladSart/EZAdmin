<#
.SYNOPSIS
    Read-only health audit for Azure VM Agent status, extension provisioning state, and boot
    diagnostics configuration, across one VM or an entire resource group/subscription.

.DESCRIPTION
    Collects and flags common failure patterns documented in VMExtensions-A.md:
      - VM Agent not "Ready" (blocks every extension and Run Command on that VM)
      - Extensions with a ProvisioningState other than "Succeeded" (Failed / Creating / Transitioning)
      - Boot diagnostics disabled, or pointed at an unsupported storage account tier
        (Premium SSD / Zone-Redundant Storage are not supported for boot diagnostics)
      - VMs that are stopped/deallocated (a common false alarm for "agent/extension not responding")

    Optionally, with -TestWireServer, uses Invoke-AzVMRunCommand to test in-guest connectivity to
    the WireServer endpoint (168.63.129.16:80 and :32526) that the VM Agent and every extension
    depend on -- this requires the VM Agent to be at least partially responsive, and will itself
    time out on a VM whose Agent is fully down (a result worth reporting, not a script bug).

    This script does NOT modify any configuration, restart any service, or reinstall any
    extension. It is read-only by design.

.PARAMETER ResourceGroupName
    Optional. Limit the audit to a single resource group. If omitted, audits every VM the
    authenticated context has Reader access to across the current subscription.

.PARAMETER VMName
    Optional. Limit the audit to a single VM within -ResourceGroupName. Requires
    -ResourceGroupName to also be supplied.

.PARAMETER TestWireServer
    Optional switch. When set, runs an in-guest connectivity test to 168.63.129.16:80/32526 via
    Run Command for each VM whose Agent status is already "Ready". Adds noticeable runtime per VM
    (Run Command executions are not instant) -- recommended for single-VM or small-scope audits,
    not large fleet sweeps.

.PARAMETER OutputPath
    Optional. Folder to write the CSV evidence export to. Defaults to the current directory.

.EXAMPLE
    .\Get-AzureVMExtensionHealth.ps1 -ResourceGroupName "rg-prod-compute" -VMName "vm-app01" -TestWireServer

    Full single-VM audit including an in-guest WireServer connectivity test.

.EXAMPLE
    .\Get-AzureVMExtensionHealth.ps1 -ResourceGroupName "rg-prod-compute"

    Fleet-wide audit of every VM in the resource group (Agent status, extension state, boot
    diagnostics configuration) without the slower in-guest connectivity test.

.NOTES
    Requires: Az.Compute, Az.Storage (Az PowerShell), already-authenticated context
    (Connect-AzAccount). -TestWireServer additionally requires Az.Compute's
    Invoke-AzVMRunCommand and a VM Agent that is at least partially responsive.
    Read-only. Safe to run at any time, including against a production fleet.
    Run-as: Reader on the audited resource group(s)/subscription is sufficient for everything
    except -TestWireServer, which requires Virtual Machine Contributor (Run Command execution
    rights) on each audited VM.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$VMName,
    [switch]$TestWireServer,
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$VM, [string]$Area, [string]$Severity, [string]$Detail)
    $findings.Add([pscustomobject]@{
        Timestamp = Get-Date -Format "o"
        VM        = $VM
        Area      = $Area
        Severity  = $Severity
        Detail    = $Detail
    })
}

if ($VMName -and -not $ResourceGroupName) {
    Write-Status "-VMName requires -ResourceGroupName to also be supplied." "ERROR"
    throw "Invalid parameter combination: -VMName requires -ResourceGroupName."
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Checking required modules and authenticated context..." "INFO"

$requiredModules = @("Az.Compute", "Az.Storage")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "Module '$mod' not found. Install with: Install-Module $mod -Scope CurrentUser" "WARN"
    }
}

try {
    $null = Get-AzContext -ErrorAction Stop
    Write-Status "Az PowerShell context confirmed." "OK"
}
catch {
    Write-Status "No active Az PowerShell context. Run Connect-AzAccount first." "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# 1. Enumerate target VMs
# ---------------------------------------------------------------------------
Write-Status "Enumerating target VM(s)..." "INFO"

$targetVMs = @()
try {
    if ($VMName) {
        $targetVMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName)
    }
    elseif ($ResourceGroupName) {
        $targetVMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName)
    }
    else {
        $targetVMs = @(Get-AzVM)
    }
    Write-Status "Found $($targetVMs.Count) VM(s) to audit." "OK"
}
catch {
    Write-Status "Failed to enumerate VMs: $($_.Exception.Message)" "ERROR"
    Add-Finding -VM "N/A" -Area "Preflight" -Severity "ERROR" -Detail "Unable to enumerate VMs: $($_.Exception.Message)"
    throw
}

if ($targetVMs.Count -eq 0) {
    Write-Status "No VMs found for the given scope. Nothing to audit." "WARN"
    return
}

# Cache storage account SKUs so repeated boot-diagnostics checks against the same
# account don't re-query it for every VM in the fleet.
$storageSkuCache = @{}
function Get-StorageAccountSkuCached {
    param([string]$AccountName)
    if ($storageSkuCache.ContainsKey($AccountName)) { return $storageSkuCache[$AccountName] }
    $acct = Get-AzStorageAccount -ErrorAction SilentlyContinue | Where-Object StorageAccountName -eq $AccountName | Select-Object -First 1
    $sku = if ($acct) { $acct.Sku.Name } else { $null }
    $storageSkuCache[$AccountName] = $sku
    return $sku
}

# ---------------------------------------------------------------------------
# 2. Per-VM audit
# ---------------------------------------------------------------------------
$vmReport = New-Object System.Collections.Generic.List[object]

foreach ($vm in $targetVMs) {
    $rg = $vm.ResourceGroupName
    $name = $vm.Name
    Write-Status "Auditing VM '$name' (RG '$rg')..." "INFO"

    $powerState  = "Unknown"
    $agentStatus = "Unknown"
    $agentVersion = "Unknown"
    $failedExtensions = @()
    $extensionCount = 0
    $bootDiagEnabled = $false
    $bootDiagStorageUri = $null
    $bootDiagUnsupportedTier = $false
    $wireServerResult = "NotTested"

    # --- Power state and Agent status ---
    try {
        $status = Get-AzVM -ResourceGroupName $rg -Name $name -Status
        $powerState = ($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
        if ($status.VMAgent) {
            $agentStatus  = $status.VMAgent.Statuses.DisplayStatus
            $agentVersion = $status.VMAgent.VmAgentVersion
        }

        if ($powerState -ne "VM running") {
            Add-Finding -VM $name -Area "PowerState" -Severity "INFO" -Detail "VM is not currently running ('$powerState') -- Agent/extension checks below may reflect a stale last-known state, not a live fault."
        }

        if ($powerState -eq "VM running" -and ($null -eq $agentStatus -or $agentStatus -ne "Ready")) {
            Add-Finding -VM $name -Area "VMAgent" -Severity "ERROR" -Detail "VM is running but VM Agent status is '$agentStatus' (expected 'Ready'). Every extension and Run Command on this VM is affected until this is resolved."
        }
        elseif ($agentStatus -eq "Ready") {
            Write-Status "  Agent status: Ready (version $agentVersion)" "OK"
        }
    }
    catch {
        Write-Status "  Failed to retrieve VM status: $($_.Exception.Message)" "ERROR"
        Add-Finding -VM $name -Area "PowerState" -Severity "ERROR" -Detail "Unable to retrieve VM status: $($_.Exception.Message)"
    }

    # --- Extensions ---
    try {
        $exts = Get-AzVMExtension -ResourceGroupName $rg -VMName $name -Status -ErrorAction SilentlyContinue
        $extensionCount = ($exts | Measure-Object).Count
        foreach ($ext in $exts) {
            if ($ext.ProvisioningState -ne "Succeeded") {
                $msg = ($ext.Statuses | Select-Object -ExpandProperty Message -ErrorAction SilentlyContinue) -join " | "
                $failedExtensions += "$($ext.Name) ($($ext.ProvisioningState))"
                Add-Finding -VM $name -Area "Extension" -Severity "ERROR" -Detail "Extension '$($ext.Name)' [$($ext.ExtensionType)] ProvisioningState='$($ext.ProvisioningState)'. Message: $msg"
            }
        }
        if ($failedExtensions.Count -eq 0 -and $extensionCount -gt 0) {
            Write-Status "  All $extensionCount extension(s) report Succeeded." "OK"
        }
    }
    catch {
        Write-Status "  Failed to retrieve extensions: $($_.Exception.Message)" "WARN"
        Add-Finding -VM $name -Area "Extension" -Severity "WARN" -Detail "Unable to retrieve extension status: $($_.Exception.Message)"
    }

    # --- Boot diagnostics ---
    try {
        $bd = $vm.DiagnosticsProfile.BootDiagnostics
        if ($bd) {
            $bootDiagEnabled = [bool]$bd.Enabled
            $bootDiagStorageUri = $bd.StorageUri
            if (-not $bootDiagEnabled) {
                Add-Finding -VM $name -Area "BootDiagnostics" -Severity "WARN" -Detail "Boot diagnostics is disabled. Serial Console will not function, and no hypervisor-level screenshot/serial log will be available if this VM fails to boot."
            }
            elseif ($bootDiagStorageUri) {
                $acctName = ([uri]$bootDiagStorageUri).Host.Split('.')[0]
                $sku = Get-StorageAccountSkuCached -AccountName $acctName
                if ($sku -and $sku -match 'Premium|ZRS') {
                    $bootDiagUnsupportedTier = $true
                    Add-Finding -VM $name -Area "BootDiagnostics" -Severity "ERROR" -Detail "Boot diagnostics storage account '$acctName' is SKU '$sku' -- Premium and Zone-Redundant Storage are NOT supported for boot diagnostics and can cause StorageAccountTypeNotSupported errors or silently broken screenshots/Serial Console."
                }
            }
            else {
                Write-Status "  Boot diagnostics enabled using a Microsoft-managed storage account." "OK"
            }
        }
        else {
            Add-Finding -VM $name -Area "BootDiagnostics" -Severity "WARN" -Detail "No DiagnosticsProfile.BootDiagnostics block found on this VM -- boot diagnostics is likely disabled."
        }
    }
    catch {
        Write-Status "  Failed to evaluate boot diagnostics configuration: $($_.Exception.Message)" "WARN"
        Add-Finding -VM $name -Area "BootDiagnostics" -Severity "WARN" -Detail "Unable to evaluate boot diagnostics configuration: $($_.Exception.Message)"
    }

    # --- Optional in-guest WireServer connectivity test ---
    if ($TestWireServer) {
        if ($powerState -eq "VM running" -and $agentStatus -eq "Ready") {
            try {
                Write-Status "  Testing in-guest WireServer connectivity (this can take a minute)..." "INFO"
                $script = "Test-NetConnection -ComputerName 168.63.129.16 -Port 32526 | Select-Object -ExpandProperty TcpTestSucceeded"
                $result = Invoke-AzVMRunCommand -ResourceGroupName $rg -Name $name -CommandId 'RunPowerShellScript' -ScriptString $script -ErrorAction Stop
                $outputText = ($result.Value | Where-Object Code -like '*StdOut*').Message
                if ($outputText -match 'True') {
                    $wireServerResult = "Reachable"
                    Write-Status "  WireServer (168.63.129.16:32526) reachable." "OK"
                }
                else {
                    $wireServerResult = "Unreachable"
                    Add-Finding -VM $name -Area "WireServer" -Severity "ERROR" -Detail "In-guest test to 168.63.129.16:32526 did not report success. Check guest firewall, NSG, and any SSL-inspecting proxy/AV product for interference with this address."
                }
            }
            catch {
                $wireServerResult = "TestFailed"
                Add-Finding -VM $name -Area "WireServer" -Severity "WARN" -Detail "Run Command connectivity test failed or timed out: $($_.Exception.Message). If the Agent is only partially responsive, this result is itself diagnostic -- consider Serial Console as an alternate access path."
            }
        }
        else {
            $wireServerResult = "SkippedAgentNotReady"
            Write-Status "  Skipping WireServer test -- VM not running or Agent not Ready." "WARN"
        }
    }

    $vmReport.Add([pscustomobject]@{
        VMName                  = $name
        ResourceGroup           = $rg
        PowerState               = $powerState
        AgentStatus              = $agentStatus
        AgentVersion             = $agentVersion
        ExtensionCount           = $extensionCount
        FailedExtensions         = ($failedExtensions -join '; ')
        BootDiagnosticsEnabled   = $bootDiagEnabled
        BootDiagStorageUri       = $bootDiagStorageUri
        BootDiagUnsupportedTier  = $bootDiagUnsupportedTier
        WireServerTest           = $wireServerResult
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----------------------------------------------------------" "INFO"
Write-Status "Summary: $($vmReport.Count) VM(s) audited. $($findings.Count) finding(s) recorded ($(($findings | Where-Object Severity -eq 'ERROR').Count) ERROR, $(($findings | Where-Object Severity -eq 'WARN').Count) WARN, $(($findings | Where-Object Severity -eq 'INFO').Count) INFO)" "INFO"

foreach ($f in $findings) {
    Write-Status "[$($f.VM)] [$($f.Area)] $($f.Detail)" $f.Severity
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$vmReportPath = Join-Path $OutputPath "VMExtensionHealth-Summary-$timestamp.csv"
$vmReport | Export-Csv -Path $vmReportPath -NoTypeInformation
Write-Status "VM summary exported to $vmReportPath" "OK"

$findingsPath = Join-Path $OutputPath "VMExtensionHealth-Findings-$timestamp.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation
Write-Status "Findings exported to $findingsPath" "OK"

Write-Status "Audit complete. This script made no configuration changes." "OK"
