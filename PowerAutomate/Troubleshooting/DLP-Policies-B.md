# Power Platform DLP Policies — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# 1. Connect to Power Platform Admin PowerShell
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Force -Scope CurrentUser
Add-PowerAppsAccount

# 2. List all DLP policies in the tenant
Get-AdminDlpPolicy | Select-Object DisplayName, PolicyName, CreatedTime, IsGlobal | Format-Table

# 3. Check which environments a specific policy applies to
$policyName = "<POLICY_GUID>"  # From Get-AdminDlpPolicy output
Get-AdminDlpPolicy -PolicyName $policyName |
    Select-Object -ExpandProperty Environments | Format-Table

# 4. Check connector classification for a specific policy
Get-AdminDlpPolicy -PolicyName $policyName |
    Select-Object -ExpandProperty BusinessDataGroup |
    Select-Object id, name | Format-Table

# 5. Check connector in "No Business Data" group (blocked)
Get-AdminDlpPolicy -PolicyName $policyName |
    Select-Object -ExpandProperty NonBusinessDataGroup |
    Select-Object id, name | Format-Table
```

| Output | Interpretation | Next Step |
|--------|---------------|-----------|
| Flow fails with "This connector is blocked" | DLP policy has connector in NonBusinessDataGroup or Blocked group | [Fix 1 — Identify and Reclassify Blocked Connector](#fix-1--identify-and-reclassify-blocked-connector) |
| Flow worked yesterday, fails today | New DLP policy applied to environment | [Fix 2 — Identify Newly Applied Policy](#fix-2--identify-newly-applied-policy) |
| Connector appears in two groups | Policy misconfiguration — connector in multiple classifications | [Fix 3 — Resolve Connector Classification Conflict](#fix-3--resolve-connector-classification-conflict) |
| Custom connector blocked | Custom connectors default to "Non-Business" unless explicitly allowed | [Fix 4 — Exempt Custom Connector](#fix-4--exempt-custom-connector) |
| DLP policy not showing in Power Automate error | Policy is tenant-wide and hidden from env admins | Check if policy `IsGlobal = True` — requires tenant admin to modify |
| User can't save a flow | Cross-group connector mixing (Business + Non-Business in same flow) | [Fix 5 — Resolve Cross-Group Connector Mix](#fix-5--resolve-cross-group-connector-mix) |

---
## Dependency Cascade

<details><summary>What must be true for a flow to pass DLP validation</summary>

```
Power Platform DLP Policy
  └── Applies to: Specific Environments / All Environments (global)
        └── Three connector groups:
              ├── Business (allowed, can share data with each other)
              ├── Non-Business (allowed, CANNOT share data with Business group)
              │     └── Connectors in Non-Business can only connect to other Non-Business connectors
              └── Blocked (connector cannot be used at all in flows in this environment)
                    │
                    ▼
        Flow trigger + all actions checked at SAVE time and at RUN time
              └── If any connector crosses group boundary → flow is suspended
                    └── Existing flows: suspended (turned off)
                    └── New flows: cannot be saved
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Get the exact error from the flow**
```powershell
# In Power Automate portal: open flow → Run History → failed run → click error
# Error message will include the connector name that triggered the violation
# Common error format:
# "Flow suspended. The connector '<CONNECTOR_NAME>' is not allowed in this environment."
```

**Step 2 — Identify which policy is causing the block**
```powershell
# List all policies affecting the environment where the flow lives
$envName = "<ENVIRONMENT_NAME>"  # Format: Default-<GUID> or display name

Get-AdminDlpPolicy | Where-Object {
    $_.Environments -eq $null -or  # Global policies apply everywhere
    $_.Environments.name -eq $envName
} | Select-Object DisplayName, PolicyName, IsGlobal | Format-Table
```

**Step 3 — Check the connector's current classification**
```powershell
$policyName = "<POLICY_GUID>"
$connectorId = "/providers/Microsoft.PowerApps/apis/shared_<CONNECTOR_NAME>"
# e.g., shared_sharepointonline, shared_office365, shared_dropbox

$policy = Get-AdminDlpPolicy -PolicyName $policyName

$inBusiness    = $policy.BusinessDataGroup    | Where-Object { $_.id -eq $connectorId }
$inNonBusiness = $policy.NonBusinessDataGroup | Where-Object { $_.id -eq $connectorId }
$inBlocked     = $policy.BlockedGroup         | Where-Object { $_.id -eq $connectorId }

Write-Host "Business group:     $($inBusiness    -ne $null)"
Write-Host "Non-Business group: $($inNonBusiness -ne $null)"
Write-Host "Blocked group:      $($inBlocked     -ne $null)"
```

**Step 4 — Validate after fix**
```powershell
# After reclassifying the connector, re-check and then re-enable the suspended flow
# In Power Automate portal: My Flows → select the suspended flow → Turn On
# Or via PowerShell:
Set-AdminFlowOwnerRole -EnvironmentName $envName -FlowName $flowName  # re-enable via portal - no direct PS cmdlet for flow state
```

---
## Common Fix Paths

<details><summary>Fix 1 — Identify and Reclassify Blocked Connector</summary>

**Symptom:** Flow error mentions a connector that is in the "Blocked" group.

**Important:** Only Power Platform admins or tenant admins can modify DLP policies. Environment admins cannot change tenant-level policies marked `IsGlobal = True`.

```powershell
$policyName   = "<POLICY_GUID>"
$connectorId  = "/providers/Microsoft.PowerApps/apis/shared_<CONNECTOR_NAME>"
$connectorName = "<FRIENDLY_NAME>"  # e.g., "SharePoint"

# Get current policy object
$policy = Get-AdminDlpPolicy -PolicyName $policyName

# Move connector from Blocked/NonBusiness group to Business group
# First, build the updated Business group by adding the connector
$newBusinessConnector = @{
    id   = $connectorId
    name = $connectorName
    type = "Microsoft.PowerApps/apis"
}

$updatedBusinessGroup = @($policy.BusinessDataGroup) + $newBusinessConnector

# Remove from BlockedGroup if present
$updatedBlockedGroup = $policy.BlockedGroup | Where-Object { $_.id -ne $connectorId }

# Apply the update
Set-AdminDlpPolicy -PolicyName $policyName `
    -BusinessDataGroup $updatedBusinessGroup `
    -BlockedGroup $updatedBlockedGroup

Write-Host "Connector moved to Business group. Re-enable affected flows in the Power Automate portal."
```

**After:** Wait ~5 minutes for policy propagation, then re-enable suspended flows.

</details>

<details><summary>Fix 2 — Identify Newly Applied Policy</summary>

**Symptom:** Flows that worked before are now suspended. No changes were made to the flows themselves.

```powershell
# Find policies sorted by creation date — newest first
Get-AdminDlpPolicy | Sort-Object CreatedTime -Descending |
    Select-Object DisplayName, PolicyName, CreatedTime, IsGlobal | Format-Table

# Check if a recent policy now applies to the affected environment
$recentPolicies = Get-AdminDlpPolicy | Sort-Object CreatedTime -Descending | Select-Object -First 5
foreach ($p in $recentPolicies) {
    Write-Host "`nPolicy: $($p.DisplayName) (Created: $($p.CreatedTime))"
    Write-Host "Is Global: $($p.IsGlobal)"
    Write-Host "Environments: $($p.Environments.name -join ', ')"
}
```

**Resolution options:**
1. If the policy is wrong: modify it to not apply to the affected environment
2. If the policy is correct: the flow needs to be updated to only use compliant connectors
3. If it's a test environment: create a dedicated DLP policy for test envs with fewer restrictions

```powershell
# Remove a specific environment from a policy's scope
$policy = Get-AdminDlpPolicy -PolicyName "<POLICY_GUID>"
$envToRemove = "<ENVIRONMENT_NAME>"

$updatedEnvs = $policy.Environments | Where-Object { $_.name -ne $envToRemove }
Set-AdminDlpPolicy -PolicyName $policy.PolicyName -Environments $updatedEnvs
```

</details>

<details><summary>Fix 3 — Resolve Connector Classification Conflict</summary>

**Symptom:** Connector appears to be in multiple groups, or DLP admin made conflicting changes across multiple policies.

```powershell
# A connector can only be in one group PER POLICY
# But different policies can classify the same connector differently
# The most restrictive classification wins: Blocked > Non-Business > Business

# Audit connector classification across ALL policies
$connectorId = "/providers/Microsoft.PowerApps/apis/shared_<CONNECTOR_NAME>"

Get-AdminDlpPolicy | ForEach-Object {
    $p = $_
    $bizMatch    = $p.BusinessDataGroup    | Where-Object { $_.id -eq $connectorId }
    $nonBizMatch = $p.NonBusinessDataGroup | Where-Object { $_.id -eq $connectorId }
    $blkMatch    = $p.BlockedGroup         | Where-Object { $_.id -eq $connectorId }

    $classification = if ($blkMatch) { "BLOCKED" } elseif ($nonBizMatch) { "Non-Business" } elseif ($bizMatch) { "Business" } else { "Not listed (defaults to Non-Business)" }

    [PSCustomObject]@{
        Policy         = $p.DisplayName
        IsGlobal       = $p.IsGlobal
        Classification = $classification
    }
} | Format-Table
```

**Resolution:** If multiple policies conflict, the effective classification is the most restrictive. Ensure Business classification exists in all applicable policies, or reorganise policies so they're not duplicating coverage of the same environments.

</details>

<details><summary>Fix 4 — Exempt Custom Connector</summary>

**Symptom:** A custom connector (or HTTP connector) is being blocked by DLP. Custom connectors not explicitly listed default to the Non-Business group.

```powershell
# Custom connector IDs follow the format:
# /providers/Microsoft.PowerApps/apis/<ENVIRONMENT_ID>/<CONNECTOR_ID>
# Find custom connector IDs from the environment
Get-AdminPowerAppConnector -EnvironmentName "<ENVIRONMENT_NAME>" |
    Where-Object { $_.ConnectorType -eq "CustomConnector" } |
    Select-Object ConnectorName, DisplayName | Format-Table

# Add custom connector to Business group in the relevant policy
$policyName          = "<POLICY_GUID>"
$customConnectorId   = "/providers/Microsoft.PowerApps/apis/<ENV_ID>/<CONNECTOR_ID>"
$customConnectorName = "<FRIENDLY_NAME>"

$policy = Get-AdminDlpPolicy -PolicyName $policyName
$newEntry = @{ id = $customConnectorId; name = $customConnectorName; type = "Microsoft.PowerApps/apis" }
$updatedBiz = @($policy.BusinessDataGroup) + $newEntry

Set-AdminDlpPolicy -PolicyName $policyName -BusinessDataGroup $updatedBiz
Write-Host "Custom connector added to Business group."
```

**Note on HTTP connector:** The generic HTTP connector cannot be classified — it is handled via the "HTTP with Azure AD" connector and connector endpoint filtering (available in Pay-As-You-Go or managed environments). If HTTP connector is a concern, enable endpoint filtering to allow only approved URLs.

</details>

<details><summary>Fix 5 — Resolve Cross-Group Connector Mix</summary>

**Symptom:** Flow uses both SharePoint (Business) and a Non-Business connector (e.g., Dropbox). DLP prevents saving because data could flow between the two groups.

**This is a design issue — the DLP is working as intended.** Resolution options:

1. **Move the Non-Business connector to Business group** (if approved by security team)
2. **Split the flow into two separate flows** — one using only Business connectors, one using only Non-Business connectors, connected via a shared data store (SharePoint list, Dataverse, etc.)
3. **Use an Azure Logic App** instead of Power Automate — Logic Apps have different DLP enforcement (resource-level policies via Azure Policy, not Power Platform DLP)

```powershell
# Option 1: Move connector to Business group (see Fix 1)

# Option 2 pattern (document for developer):
# Flow A (Business connectors only):
#   Trigger → Get data from SharePoint → Write intermediate record to Dataverse

# Flow B (Non-Business connectors only):
#   Trigger on Dataverse record → Upload to Dropbox

Write-Host "Document the split-flow pattern for the flow developer."
Write-Host "No PowerShell action required — this is a flow redesign task."
```

</details>

---
## Escalation Evidence

```
TICKET ESCALATION: Power Platform DLP Policy Issue
===================================================
Tenant ID:              ___________________________
Environment name:       ___________________________
Environment ID:         ___________________________
Affected flow name:     ___________________________
Affected flow owner:    ___________________________
Policy name(s):         ___________________________
Policy GUID(s):         ___________________________
Connector causing error:___________________________
Connector group:        Business / Non-Business / Blocked
Error message (exact):  ___________________________
Flow state:             Suspended / Cannot save
Number of flows affected:__________________________
Date issue started:     ___________________________
Was a new policy applied? Yes / No / Unknown
Admin who made changes: ___________________________
Power Automate portal URL: https://make.powerautomate.com
Admin centre URL:       https://admin.powerplatform.microsoft.com
```

---
## 🎓 Learning Pointers

- **DLP enforcement is at save and run time**: A flow is evaluated against DLP when saved AND when triggered. An existing flow that was previously compliant will be suspended if a new DLP policy reclassifies one of its connectors. This is why "nothing changed" flows suddenly break — check for new or modified policies in the Power Platform Admin Centre. [MS Docs — DLP policies](https://learn.microsoft.com/en-us/power-platform/admin/wp-data-loss-prevention)
- **Three groups, not two**: The 2024+ DLP model has three groups — Business, Non-Business, and Blocked. Older documentation shows only two (Business Data Allowed / No Business Data). Blocked connectors cannot be used at all in flows within scope environments, regardless of which other connectors are present. Know which model your tenant is using.
- **Tenant-level vs Environment-level policies**: `IsGlobal = True` policies apply to all environments and can only be managed by Tenant Admins. Environment admins have no ability to override or exempt environments from global policies. This distinction matters enormously for MSPs managing multi-tenant environments with different compliance requirements per client.
- **Default environment is a common trap**: Microsoft's DLP best practice is to have a restrictive policy on the Default environment (where all users land initially) and a more permissive policy on managed/developer environments. If you find flows broken by "unexpected" DLP, check whether the flow was accidentally created in the Default environment rather than a managed environment.
- **Endpoint filtering for HTTP and custom connectors**: Premium-only feature. Allows you to permit the HTTP or HTTP+Swagger connector but restrict it to approved endpoints (e.g., only allow calls to `*.yourcompany.com`). This is the correct answer for Power Automate flows calling internal APIs without fully blocking HTTP. [Endpoint filtering](https://learn.microsoft.com/en-us/power-platform/admin/connector-endpoint-filtering)
- **Audit log captures DLP changes**: DLP policy creation and modification events are logged in the Microsoft 365 Unified Audit Log under the `PowerPlatformAdministratorActivity` category. If flows were suddenly suspended and you don't know why, search the audit log for `DLPRuleCreate` or `DLPRuleModify` events in the timeframe before the breakage.
