<#
.SYNOPSIS
    Audits Microsoft Sentinel data connector health for a given Log Analytics workspace —
    workspace ingestion caps, per-table ingestion gaps, Data Collection Rule associations,
    and AMA/Arc agent status for the machines behind agent-based connectors.

.DESCRIPTION
    Sentinel connectors fail across three different mechanisms (agent/DCR, API/service,
    diagnostic-settings), and the portal's "Connected" badge only confirms wiring/consent —
    not that data is actually landing. This script checks the things that are NOT visible
    from the connector status badge:
    - Workspace daily ingestion cap / quota state
    - Last-ingested timestamp per common table (gap detection)
    - Data Collection Rules present in the resource group and their destinations
    - Data Collection Rule Associations for a supplied list of target resources
    - AMA extension provisioning state for supplied VMs (Azure-managed only; Arc servers
      should be checked locally with azcmagent show)

    Exports results to CSV and prints a colour-coded console summary.

    Does NOT cover:
    - API/service connector consent state (Office 365, Entra ID, Defender XDR) — these have
      no locally queryable state; check via Sentinel portal → Data connectors → connector page
    - Analytics rule health or workbook rendering
    - Custom/CCP (Codeless Connector Platform) connector-specific schemas

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace (and typically the DCRs).

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace that Sentinel is enabled on.

.PARAMETER TargetResourceIds
    Optional array of full ARM resource IDs (VMs or Arc machines) to check for DCR
    association health. If omitted, DCR association checks are skipped.

.PARAMETER TablesToCheck
    Table names to check for ingestion gaps. Defaults to the most common Sentinel tables.

.PARAMETER OutputPath
    Directory for CSV export. Default: C:\Temp\Sentinel-ConnectorHealth-<timestamp>

.EXAMPLE
    .\Get-SentinelConnectorHealth.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod"

.EXAMPLE
    .\Get-SentinelConnectorHealth.ps1 -ResourceGroupName "rg-sentinel-prod" -WorkspaceName "law-sentinel-prod" `
        -TargetResourceIds @("/subscriptions/xxx/resourceGroups/rg-vms/providers/Microsoft.Compute/virtualMachines/VM01")

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Monitor, Az.Compute modules; authenticated
              Az PowerShell session (Connect-AzAccount) with Log Analytics Reader (minimum) on
              the workspace, and Reader on any target resources checked for DCR association.
    Run As: Any account with the above RBAC — no elevated/admin rights required.
    Safe: Fully read-only. No connector, DCR, or workspace configuration is modified.
    Cross-references: Security/Sentinel/DataConnectors-B.md (Fixes 1-5) and DataConnectors-A.md
                       (Playbooks 1-3) for remediation once a gap is identified here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [string[]]$TargetResourceIds = @(),

    [string[]]$TablesToCheck = @("SecurityEvent", "SigninLogs", "AuditLogs", "OfficeActivity", "AzureActivity", "Heartbeat", "CommonSecurityLog", "Syslog"),

    [string]$OutputPath = "C:\Temp\Sentinel-ConnectorHealth-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

# ───────────────────────────────────────────────────────────────
# 1. Workspace capping / quota state
# ───────────────────────────────────────────────────────────────
Write-Status "Checking workspace ingestion cap..." "INFO"
try {
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
    $capInfo = [PSCustomObject]@{
        WorkspaceName   = $WorkspaceName
        Sku             = $ws.Sku
        RetentionDays   = $ws.RetentionInDays
        DailyQuotaGb    = $ws.WorkspaceCapping.DailyQuotaGb
        QuotaEnabled    = if ($ws.WorkspaceCapping.DailyQuotaGb -eq -1) { $false } else { $true }
        CollectedAt     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    $capInfo | Export-Csv "$OutputPath\01-WorkspaceCapping.csv" -NoTypeInformation

    if ($capInfo.QuotaEnabled) {
        Write-Status "Daily quota is capped at $($capInfo.DailyQuotaGb) GB — verify this is intentional, not a silent ingestion blocker" "WARN"
    } else {
        Write-Status "No daily quota cap set (unlimited)" "OK"
    }
} catch {
    Write-Status "Failed to read workspace: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 2. Ingestion gap check per table
# ───────────────────────────────────────────────────────────────
Write-Status "Checking last-ingested timestamp per table..." "INFO"
$tableResults = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $customerId = $ws.CustomerId
    foreach ($table in $TablesToCheck) {
        $query = "$table | summarize LastSeen = max(TimeGenerated), RowCount1h = countif(TimeGenerated > ago(1h))"
        try {
            $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $query -ErrorAction Stop
            $row = $result.Results | Select-Object -First 1
            $lastSeen = $row.LastSeen
            $gapMinutes = if ($lastSeen) { [math]::Round(((Get-Date).ToUniversalTime() - [datetime]$lastSeen).TotalMinutes, 1) } else { "N/A" }

            $tableResults.Add([PSCustomObject]@{
                TableName       = $table
                LastSeen        = $lastSeen
                GapMinutes      = $gapMinutes
                RowsLastHour    = $row.RowCount1h
            })
        } catch {
            $tableResults.Add([PSCustomObject]@{
                TableName    = $table
                LastSeen     = "Query failed"
                GapMinutes   = "N/A"
                RowsLastHour = "N/A — $($_.Exception.Message)"
            })
        }
    }
} catch {
    Write-Status "Table gap check failed entirely: $($_.Exception.Message)" "ERROR"
}
$tableResults | Export-Csv "$OutputPath\02-TableIngestionGaps.csv" -NoTypeInformation
foreach ($t in $tableResults) {
    if ($t.GapMinutes -is [double] -and $t.GapMinutes -gt 180) {
        Write-Status "  $($t.TableName): gap of $($t.GapMinutes) minutes — investigate" "WARN"
    } elseif ($t.GapMinutes -eq "N/A") {
        Write-Status "  $($t.TableName): no data or query error" "WARN"
    } else {
        Write-Status "  $($t.TableName): last seen $($t.GapMinutes) min ago" "OK"
    }
}

# ───────────────────────────────────────────────────────────────
# 3. Data Collection Rules in the resource group
# ───────────────────────────────────────────────────────────────
Write-Status "Enumerating Data Collection Rules in $ResourceGroupName..." "INFO"
try {
    $dcrs = Get-AzDataCollectionRule -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    $dcrs | Select-Object Name, Kind, Id, ProvisioningState |
        Export-Csv "$OutputPath\03-DataCollectionRules.csv" -NoTypeInformation
    Write-Status "Found $($dcrs.Count) DCR(s)" "OK"
} catch {
    Write-Status "Failed to enumerate DCRs: $($_.Exception.Message)" "ERROR"
}

# ───────────────────────────────────────────────────────────────
# 4. DCR Association health for supplied target resources
# ───────────────────────────────────────────────────────────────
$assocResults = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($TargetResourceIds.Count -gt 0) {
    Write-Status "Checking DCR associations for $($TargetResourceIds.Count) target resource(s)..." "INFO"
    foreach ($resId in $TargetResourceIds) {
        try {
            $assocs = Get-AzDataCollectionRuleAssociation -TargetResourceId $resId -ErrorAction Stop
            if ($assocs) {
                foreach ($a in $assocs) {
                    $assocResults.Add([PSCustomObject]@{
                        ResourceId       = $resId
                        AssociationName  = $a.Name
                        DataCollectionRuleId = $a.DataCollectionRuleId
                        ProvisioningState = $a.ProvisioningState
                    })
                }
            } else {
                $assocResults.Add([PSCustomObject]@{
                    ResourceId       = $resId
                    AssociationName  = "NONE FOUND"
                    DataCollectionRuleId = "N/A"
                    ProvisioningState = "MISSING"
                })
                Write-Status "  $resId — NO DCR association found (likely ingestion gap)" "WARN"
            }
        } catch {
            $assocResults.Add([PSCustomObject]@{
                ResourceId       = $resId
                AssociationName  = "ERROR"
                DataCollectionRuleId = "N/A"
                ProvisioningState = $_.Exception.Message
            })
            Write-Status "  $resId — failed to query: $($_.Exception.Message)" "ERROR"
        }
    }
    $assocResults | Export-Csv "$OutputPath\04-DCRAssociations.csv" -NoTypeInformation
} else {
    Write-Status "No TargetResourceIds supplied — skipping DCR association check" "INFO"
}

# ───────────────────────────────────────────────────────────────
# 5. AMA extension state for supplied Azure VM resources
# ───────────────────────────────────────────────────────────────
$amaResults = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($resId in $TargetResourceIds) {
    if ($resId -match "/providers/Microsoft.Compute/virtualMachines/") {
        try {
            $parts = $resId -split "/"
            $vmRg = $parts[4]
            $vmName = $parts[-1]
            $ext = Get-AzVMExtension -ResourceGroupName $vmRg -VMName $vmName -Name "AzureMonitorWindowsAgent" -ErrorAction SilentlyContinue
            if (-not $ext) {
                $ext = Get-AzVMExtension -ResourceGroupName $vmRg -VMName $vmName -Name "AzureMonitorLinuxAgent" -ErrorAction SilentlyContinue
            }
            $amaResults.Add([PSCustomObject]@{
                VMName            = $vmName
                ExtensionFound    = [bool]$ext
                ProvisioningState = if ($ext) { $ext.ProvisioningState } else { "AMA extension not found" }
            })
        } catch {
            $amaResults.Add([PSCustomObject]@{
                VMName            = $resId
                ExtensionFound    = $false
                ProvisioningState = "Error: $($_.Exception.Message)"
            })
        }
    }
}
if ($amaResults.Count -gt 0) {
    $amaResults | Export-Csv "$OutputPath\05-AMAExtensionState.csv" -NoTypeInformation
}

# ─── Summary ───
Write-Host "`n=== Sentinel Connector Health Summary ===" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspaceName" -ForegroundColor Cyan
$tableResults | Format-Table TableName, LastSeen, GapMinutes, RowsLastHour -AutoSize
if ($assocResults.Count -gt 0) { $assocResults | Format-Table ResourceId, AssociationName, ProvisioningState -AutoSize }
Write-Status "Full results exported to: $OutputPath" "OK"
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Status "Zipped to: $OutputPath.zip" "OK"
