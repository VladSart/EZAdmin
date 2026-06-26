# Power Platform DLP Policies — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**Covers:**
- Power Platform Data Loss Prevention (DLP) policies — connector classification and enforcement
- Power Automate flow suspension and save failures due to DLP violations
- Power Apps canvas app DLP constraints
- Tenant-level vs environment-level policy scoping
- Custom connector classification and HTTP endpoint filtering
- DLP policy migration from two-group to three-group model

**Does not cover:**
- Microsoft Purview DLP policies (email/SharePoint/Teams — separate runbook)
- Power BI workspace DLP (sensitivity labels) — separate product
- Azure Logic Apps (different DLP model — uses Azure Policy)
- Dataverse security roles and column-level security

**Assumed:** You have Power Platform Admin or Tenant Admin access. PowerShell module installed:
```powershell
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Force -Scope CurrentUser
Install-Module -Name Microsoft.PowerApps.PowerShell -Force -Scope CurrentUser
Add-PowerAppsAccount
```

---
## How It Works

<details><summary>Full architecture — Power Platform DLP enforcement engine</summary>

### What DLP Policies Actually Do

Power Platform DLP policies classify **connectors** into groups. The policy engine then enforces a rule: **connectors from different groups cannot appear in the same flow or app**. The goal is to prevent data from moving between systems with different trust levels — for example, preventing SharePoint data from flowing to a personal Dropbox account.

**This is NOT the same as Purview DLP**: Purview DLP inspects content (what data is moving). Power Platform DLP inspects connector topology (which services are connected), with no visibility into actual data payloads.

---

### The Three-Group Model (Current)

As of 2023, Power Platform DLP has three connector groups:

| Group | Meaning | Enforcement |
|-------|---------|-------------|
| **Business** | Approved for corporate data | Can connect to other Business connectors freely |
| **Non-Business** | Allowed but isolated | Can connect only to other Non-Business connectors |
| **Blocked** | Not allowed at all | Cannot be used in any flow/app in the scoped environments |

A connector not explicitly listed in any group defaults to **Non-Business**.

**Data boundary rule:** A flow may use connectors from the Business group OR from the Non-Business group, but NEVER both. This is the "data boundary" — preventing corporate data (Business connectors) from leaking to personal services (Non-Business connectors).

---

### Policy Scope: Tenant-Level vs Environment-Level

**Tenant-level policy (IsGlobal = True)**
- Created by Tenant Admins only
- Can apply to: All environments, All environments except selected ones, or Selected environments
- Environment admins CANNOT see or modify tenant-level policies
- Enforcement is additive — the most restrictive classification across all applicable policies wins

**Environment-level policy (IsGlobal = False)**
- Created by Environment Admins or Tenant Admins
- Applies only to environments explicitly specified
- Environment admins CAN create these for their own environments
- Subject to tenant-level policy restrictions — cannot override a Blocked classification set at tenant level

**Conflict resolution:**
```
Blocked (tenant) + Business (env) → BLOCKED (tenant wins)
Non-Business (tenant) + Business (env) → Non-Business (tenant wins)
Business (tenant) + Business (env) → Business (consistent)
Not listed (tenant) + Business (env) → Non-Business (default) + Business (env) → env setting used
```

The most restrictive classification across all applicable policies for any given environment determines the effective classification.

---

### When DLP is Evaluated

**At flow save time:**
- Power Automate validates the flow's connector graph against all applicable DLP policies
- If any violation detected → save is blocked with error message naming the offending connector

**At flow activation time (turning on a suspended flow):**
- Same validation runs
- If still violating → flow remains suspended

**At runtime (trigger fires):**
- DLP is re-evaluated at runtime
- A flow that was compliant when saved may be suspended later if a new DLP policy is applied
- Existing flows are suspended (turned off) — not deleted — when a new policy blocks them
- Owner receives an email notification

**HTTP connector special case:**
- The generic HTTP action is classified per the HTTP connector policy
- But it can also be governed by **Endpoint Filtering** (premium feature) which allows the HTTP connector but restricts it to approved URLs

---

### Custom Connectors

Custom connectors are not listed in default policies. They can be:
1. Added explicitly to a group (Business, Non-Business, or Blocked) by a policy admin
2. Left unclassified → defaults to Non-Business
3. Controlled via the custom connector pattern (URL-based classification, available in Pay-As-You-Go or managed environments)

Custom connectors are environment-scoped — a connector created in Environment A is not automatically available in Environment B. Each environment's connectors must be classified per policy.

---

### The Default Environment Problem

Every Microsoft 365 user automatically has access to the Default Power Platform environment. Flows created "casually" (from Teams, SharePoint, etc.) often land in the Default environment. This environment:
- Cannot be deleted
- Is shared by all users in the tenant
- Should have the MOST restrictive DLP policy (minimal connector set)
- Is a frequent source of "why did my flow break" complaints when admins properly lock it down

Best practice: Apply a strict DLP policy to Default that only allows essential connectors (Office 365, SharePoint, Teams, Approvals). Create separate managed environments for development/production with appropriate DLP policies.

</details>

---
## Dependency Stack

```
Tenant Admin Centre (admin.powerplatform.microsoft.com)
  └── DLP Policies (tenant-level and environment-level)
        ├── Tenant-level (IsGlobal=True)
        │     ├── Scope: All Environments / Exclude Selected / Include Selected
        │     └── Only modifiable by Tenant Admins
        │
        └── Environment-level (IsGlobal=False)
              ├── Scope: Specific environments
              └── Modifiable by Environment Admins (for their environments)
                    │
                    ▼
        Connector Classification Engine
              ├── Business group connectors
              ├── Non-Business group connectors
              ├── Blocked group connectors
              └── Unclassified → defaults to Non-Business
                    │
                    ▼
        Power Automate Flow / Power Apps Canvas App
              ├── Each connector in flow/app checked at save + activation + runtime
              ├── Violation = connector from Business AND Non-Business in same flow
              ├── Violation = any connector in Blocked group
              └── Result: save blocked OR flow suspended
                    │
                    └── Flow owner receives email: "Your flow has been suspended"
                          └── Subject: "Action Required: Flow <Name> has been suspended"
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| "This connector is blocked" on save | Connector is in Blocked group in an applicable policy | `Get-AdminDlpPolicy` — check BlockedGroup |
| "Flow uses connectors that are not allowed to share data" on save | Flow mixes Business and Non-Business connectors | Identify each connector's group classification |
| Flow suspended, owner gets email | New DLP policy applied after flow was created; or existing policy modified | Check recently created/modified policies — sort by `CreatedTime` |
| All flows in an environment suspended simultaneously | New tenant-level policy applied with Blocked or Non-Business classification | Check for new `IsGlobal=True` policy |
| Works in dev environment, fails in prod | Different DLP policies per environment | Compare policies scoped to each environment |
| Custom connector blocked unexpectedly | Not listed in any policy group → defaults to Non-Business; violates data boundary | Add custom connector explicitly to Business group |
| DLP policy shows in admin centre but flow doesn't see it | Policy propagation delay (up to 60 min) | Wait and retry |
| HTTP requests blocked | HTTP connector classified as Non-Business or Blocked; or endpoint not in approved list | Check HTTP connector group; check endpoint filtering config |
| Premium connector now blocked | Licensing or policy change; premium connectors require per-user or per-flow license | Verify licensing and policy |
| Policy change didn't take effect | API caching; policy propagation delay | Wait 15–60 min; clear browser cache |

---
## Validation Steps

**Step 1 — List all DLP policies and their scope**
```powershell
Get-AdminDlpPolicy | Sort-Object CreatedTime -Descending | ForEach-Object {
    $p = $_
    $envScope = if ($p.IsGlobal) { "ALL ENVIRONMENTS" }
                elseif ($p.Environments) { ($p.Environments.name -join ", ") }
                else { "No specific environments" }

    [PSCustomObject]@{
        DisplayName = $p.DisplayName
        PolicyName  = $p.PolicyName
        IsGlobal    = $p.IsGlobal
        Created     = $p.CreatedTime
        Scope       = $envScope
    }
} | Format-Table -AutoSize
```
Expected: a manageable number of policies with clear scoping. Warning sign: many overlapping policies on the same environments.

**Step 2 — Identify which policies apply to a specific environment**
```powershell
$targetEnv = "<ENVIRONMENT_NAME>"  # Display name or Default-<GUID>

Get-AdminDlpPolicy | Where-Object {
    $_.IsGlobal -eq $true -or
    ($_.Environments | Where-Object { $_.name -eq $targetEnv }) -ne $null
} | Select-Object DisplayName, PolicyName, IsGlobal | Format-Table
```

**Step 3 — Check a specific connector's effective classification across all applicable policies**
```powershell
$connectorId = "/providers/Microsoft.PowerApps/apis/shared_dropbox"  # Example
$targetEnv   = "<ENVIRONMENT_NAME>"

$applicablePolicies = Get-AdminDlpPolicy | Where-Object {
    $_.IsGlobal -eq $true -or
    ($_.Environments | Where-Object { $_.name -eq $targetEnv }) -ne $null
}

$effectiveClassification = "Business"  # Start optimistic

foreach ($policy in $applicablePolicies) {
    $blk    = $policy.BlockedGroup         | Where-Object { $_.id -eq $connectorId }
    $nonBiz = $policy.NonBusinessDataGroup | Where-Object { $_.id -eq $connectorId }
    $biz    = $policy.BusinessDataGroup    | Where-Object { $_.id -eq $connectorId }

    if ($blk)    { $effectiveClassification = "BLOCKED";      Write-Warning "$($policy.DisplayName): BLOCKED" }
    elseif ($nonBiz) { if ($effectiveClassification -ne "BLOCKED") { $effectiveClassification = "Non-Business" }
                   Write-Warning "$($policy.DisplayName): Non-Business" }
    elseif ($biz) { Write-Host   "$($policy.DisplayName): Business" -ForegroundColor Green }
    else          { Write-Host   "$($policy.DisplayName): Not listed (defaults to Non-Business)" -ForegroundColor Yellow }
}

Write-Host "`nEffective classification in $targetEnv: $effectiveClassification" -ForegroundColor Cyan
```

**Step 4 — Verify flow suspension status**
```powershell
# List suspended flows in an environment (requires environment admin)
Get-AdminFlow -EnvironmentName "<ENVIRONMENT_NAME>" |
    Where-Object { $_.Properties.state -eq "Suspended" } |
    Select-Object @{n="FlowName";e={$_.Properties.displayName}},
                  @{n="Owner";e={$_.Properties.creator.email}},
                  @{n="State";e={$_.Properties.state}} |
    Format-Table
```

**Step 5 — Validate policy propagation (post-fix)**
```powershell
# After modifying a DLP policy, propagation can take up to 60 minutes
# Monitor by checking if suspended flows can be turned on:
# Power Automate portal → My Flows → turn on a previously suspended flow
# If "This flow uses connectors that violate DLP" → policy not propagated yet; wait and retry
```

---
## Troubleshooting Steps by Phase

### Phase 1 — Identify Scope of Impact

```powershell
# How many flows are suspended in the affected environment?
$env = "<ENVIRONMENT_NAME>"
$suspended = Get-AdminFlow -EnvironmentName $env |
             Where-Object { $_.Properties.state -eq "Suspended" }
Write-Host "Suspended flows: $($suspended.Count)"

# Group by owner to understand impact
$suspended | Group-Object { $_.Properties.creator.email } |
    Select-Object Name, Count | Sort-Object Count -Descending | Format-Table
```

---

### Phase 2 — Root Cause a Single Flow

```powershell
$flowId  = "<FLOW_GUID>"
$envName = "<ENVIRONMENT_NAME>"

$flow = Get-AdminFlow -FlowName $flowId -EnvironmentName $envName
Write-Host "Flow: $($flow.Properties.displayName)"
Write-Host "State: $($flow.Properties.state)"

# Get connector list (from flow definition)
$flow.Properties.definition.actions | ForEach-Object {
    $action = $_
    # Connector info is in the action type: "OpenApiConnection" with host.connection.referenceName
}
# Note: Full connector mapping requires Power Automate portal — the portal shows which group each connector is in
```

**Practical approach:** Open the flow in the Power Automate portal. The error banner on a suspended flow names the specific connector and which DLP policy triggered the suspension. Use this as your starting point for PowerShell investigation.

---

### Phase 3 — Implement Policy Changes

**Principle of least disruption:** Before modifying a production DLP policy, test in a non-production environment. Policy changes take effect immediately and can suspend flows en masse.

```powershell
# Safe pattern for modifying a DLP policy:
# 1. Export current state
$policyName = "<POLICY_GUID>"
$policy = Get-AdminDlpPolicy -PolicyName $policyName
$policy | ConvertTo-Json -Depth 20 | Out-File "C:\Temp\DLPPolicy_Backup_$(Get-Date -Format yyyyMMdd).json"

# 2. Validate your intended change in a test environment first
# 3. Apply the change
# 4. Wait 30-60 minutes for propagation
# 5. Verify affected flows can be re-enabled
```

---

### Phase 4 — Re-enable Suspended Flows at Scale

After a DLP fix, flows that were suspended do NOT automatically re-enable. Owners must manually turn them on, OR an admin can re-enable them at scale:

```powershell
$envName = "<ENVIRONMENT_NAME>"

# Get all suspended flows
$suspendedFlows = Get-AdminFlow -EnvironmentName $envName |
                  Where-Object { $_.Properties.state -eq "Suspended" }

Write-Host "Found $($suspendedFlows.Count) suspended flows"

# Re-enable each flow
# Note: There is no direct "Set-AdminFlow -State Enabled" cmdlet in the standard module
# The recommended approach is using the Power Platform API directly:

$token = (Get-PowerAppAuthToken).token
foreach ($flow in $suspendedFlows) {
    $flowId = $flow.FlowName
    $uri = "https://management.azure.com/providers/Microsoft.ProcessSimple/environments/$envName/flows/$flowId/start?api-version=2016-11-01"
    try {
        Invoke-RestMethod -Method POST -Uri $uri -Headers @{ Authorization = "Bearer $token" }
        Write-Host "Re-enabled: $($flow.Properties.displayName)" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to re-enable $($flow.Properties.displayName): $_"
    }
}
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Design a DLP policy structure from scratch (MSP template)</summary>

```powershell
<#
.SYNOPSIS  Create a structured DLP policy set for an MSP-managed tenant
.NOTES     Run as Tenant Admin; establishes three policies:
           1. Strict policy on Default environment
           2. Managed policy on Production environments
           3. Open policy on Developer environments
#>

Add-PowerAppsAccount

# === POLICY 1: Default Environment (strict) ===
# Only Microsoft connectors allowed; everything else blocked
$defaultStrictPolicy = @{
    DisplayName = "Default Environment - Strict"
    IsGlobal    = $false
    Environments = @(@{ name = "Default-<TENANT_ID>"; id = "Default-<TENANT_ID>"; type = "Microsoft.CommonDataModel/environments" })
}

# Define Business group (approved Microsoft connectors only)
$strictBusinessConnectors = @(
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_sharepointonline";    name = "SharePoint";          type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_office365";           name = "Office 365 Outlook";  type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_teams";               name = "Microsoft Teams";     type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_approvals";           name = "Approvals";           type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_onedriveforbusiness"; name = "OneDrive for Business";type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_office365users";      name = "Office 365 Users";    type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_commondataservice";   name = "Dataverse";           type = "Microsoft.PowerApps/apis" }
)

# Create the policy
New-AdminDlpPolicy `
    -DisplayName $defaultStrictPolicy.DisplayName `
    -BusinessDataGroup $strictBusinessConnectors `
    -Environments $defaultStrictPolicy.Environments `
    -PolicyType "SingleEnvironment"

Write-Host "Default environment strict policy created." -ForegroundColor Green

# === POLICY 2: Production Managed Environment ===
# Standard corporate connectors in Business; personal cloud storage blocked
# ... (extend with additional approved connectors for production needs)

# === POLICY 3: Developer Environment ===
# Most connectors in Non-Business; only truly dangerous ones blocked
# Block consumer social media connectors:
$devBlockedConnectors = @(
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_twitter"; name = "Twitter"; type = "Microsoft.PowerApps/apis" },
    @{ id = "/providers/Microsoft.PowerApps/apis/shared_facebook"; name = "Facebook"; type = "Microsoft.PowerApps/apis" }
)
Write-Host "Extend with production and dev policies as needed for your client environments."
```

</details>

<details><summary>Playbook 2 — Audit and report all DLP policy configurations</summary>

```powershell
<#
.SYNOPSIS  Generate comprehensive DLP policy audit report
.NOTES     Run as Tenant Admin; exports to CSV for governance review
#>

Add-PowerAppsAccount
$outDir = "C:\Temp\DLPAudit_$(Get-Date -Format yyyyMMdd)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$allPolicies = Get-AdminDlpPolicy

# Policy overview
$allPolicies | Select-Object DisplayName, PolicyName, CreatedTime, IsGlobal,
    @{n="EnvironmentCount";e={($_.Environments | Measure-Object).Count}},
    @{n="BusinessConnectorCount";e={($_.BusinessDataGroup | Measure-Object).Count}},
    @{n="BlockedConnectorCount";e={($_.BlockedGroup | Measure-Object).Count}} |
    Export-Csv "$outDir\Policies_Overview.csv" -NoTypeInformation

# Connector classification per policy
$connectorReport = foreach ($policy in $allPolicies) {
    foreach ($conn in $policy.BusinessDataGroup)    { [PSCustomObject]@{ Policy=$policy.DisplayName; Connector=$conn.name; Group="Business" } }
    foreach ($conn in $policy.NonBusinessDataGroup) { [PSCustomObject]@{ Policy=$policy.DisplayName; Connector=$conn.name; Group="Non-Business" } }
    foreach ($conn in $policy.BlockedGroup)         { [PSCustomObject]@{ Policy=$policy.DisplayName; Connector=$conn.name; Group="Blocked" } }
}
$connectorReport | Export-Csv "$outDir\Connector_Classifications.csv" -NoTypeInformation

# Suspended flows across all environments
$allEnvs = Get-AdminEnvironment
$suspendedReport = foreach ($env in $allEnvs) {
    Get-AdminFlow -EnvironmentName $env.EnvironmentName -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties.state -eq "Suspended" } |
        Select-Object @{n="Environment";e={$env.DisplayName}},
                      @{n="FlowName";e={$_.Properties.displayName}},
                      @{n="Owner";e={$_.Properties.creator.email}},
                      @{n="State";e={$_.Properties.state}}
}
$suspendedReport | Export-Csv "$outDir\Suspended_Flows.csv" -NoTypeInformation

Write-Host "DLP audit report written to $outDir" -ForegroundColor Green
Write-Host "Files: Policies_Overview.csv, Connector_Classifications.csv, Suspended_Flows.csv"
```

</details>

<details><summary>Playbook 3 — Migrate from two-group to three-group DLP model</summary>

```powershell
<#
.SYNOPSIS  Migrate an existing two-group DLP policy to three-group model
.NOTES     Two-group: Business / No Business Data
           Three-group: Business / Non-Business / Blocked
           The Non-Business group in 3-group = "No Business Data" in 2-group
           New Blocked group must be explicitly populated
#>

Add-PowerAppsAccount

$policyName = "<POLICY_GUID>"
$policy = Get-AdminDlpPolicy -PolicyName $policyName

# Backup
$policy | ConvertTo-Json -Depth 20 |
    Out-File "C:\Temp\DLPPolicy_PreMigration_$(Get-Date -Format yyyyMMdd).json"

# In the 3-group model, NonBusinessDataGroup maps to old "No Business Data"
# The policy object already has NonBusinessDataGroup in the API
# Key change: define connectors to move from NonBusiness → Blocked

# Connectors recommended to Block for most organisations:
$connectorsToBlock = @(
    "/providers/Microsoft.PowerApps/apis/shared_twitter",
    "/providers/Microsoft.PowerApps/apis/shared_facebook",
    "/providers/Microsoft.PowerApps/apis/shared_instagram",
    "/providers/Microsoft.PowerApps/apis/shared_dropbox",
    "/providers/Microsoft.PowerApps/apis/shared_googledrive",
    "/providers/Microsoft.PowerApps/apis/shared_box"
)

$currentNonBiz  = $policy.NonBusinessDataGroup
$newNonBiz      = $currentNonBiz | Where-Object { $_.id -notin $connectorsToBlock }
$newBlocked     = $currentNonBiz | Where-Object { $_.id -in $connectorsToBlock }

Write-Host "Moving $($newBlocked.Count) connectors to Blocked group:"
$newBlocked | Select-Object name | Format-Table

Set-AdminDlpPolicy -PolicyName $policyName `
    -NonBusinessDataGroup $newNonBiz `
    -BlockedGroup $newBlocked

Write-Host "Migration complete. Verify in admin.powerplatform.microsoft.com → Policies → Data policies" -ForegroundColor Green
Write-Host "Monitor for newly suspended flows over the next 60 minutes."
```

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Power Platform DLP evidence for escalation or governance review
.NOTES     Run as Tenant Admin or Power Platform Admin
#>

Add-PowerAppsAccount

$outDir = "C:\Temp\DLPEvidence_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 1. All policies
Get-AdminDlpPolicy | ConvertTo-Json -Depth 20 |
    Out-File "$outDir\AllPolicies_Full.json"

Get-AdminDlpPolicy | Select-Object DisplayName, PolicyName, IsGlobal, CreatedTime |
    Export-Csv "$outDir\Policies_Summary.csv" -NoTypeInformation

# 2. All environments
Get-AdminEnvironment | Select-Object DisplayName, EnvironmentName, EnvironmentType, Location |
    Export-Csv "$outDir\Environments.csv" -NoTypeInformation

# 3. Suspended flows per environment
$allEnvs = Get-AdminEnvironment
foreach ($env in $allEnvs) {
    $flows = Get-AdminFlow -EnvironmentName $env.EnvironmentName -ErrorAction SilentlyContinue |
             Where-Object { $_.Properties.state -eq "Suspended" }
    if ($flows) {
        $flows | Select-Object @{n="FlowName";e={$_.Properties.displayName}},
                               @{n="Owner";e={$_.Properties.creator.email}} |
                 Export-Csv "$outDir\SuspendedFlows_$($env.DisplayName -replace '[^\w]','_').csv" -NoTypeInformation
    }
}

Write-Host "Evidence collected: $outDir" -ForegroundColor Green
Compress-Archive -Path $outDir -DestinationPath "$outDir.zip"
Write-Host "ZIP: $outDir.zip — attach to support ticket or governance review"
```

---
## Command Cheat Sheet

```powershell
# --- CONNECT ---
Add-PowerAppsAccount

# --- LIST POLICIES ---
Get-AdminDlpPolicy                                                              # All policies
Get-AdminDlpPolicy | Sort-Object CreatedTime -Descending                       # Sorted by newest
Get-AdminDlpPolicy -PolicyName "<GUID>"                                        # Specific policy detail

# --- ENVIRONMENTS ---
Get-AdminEnvironment                                                            # List all environments
Get-AdminEnvironment -EnvironmentName "<NAME>"                                  # Specific environment

# --- FLOWS ---
Get-AdminFlow -EnvironmentName "<ENV>"                                          # All flows in environment
Get-AdminFlow -EnvironmentName "<ENV>" | Where-Object { $_.Properties.state -eq "Suspended" }  # Suspended flows

# --- POLICY MODIFICATION ---
Set-AdminDlpPolicy -PolicyName "<GUID>" -BusinessDataGroup $array              # Update Business group
Set-AdminDlpPolicy -PolicyName "<GUID>" -BlockedGroup $array                   # Update Blocked group
Set-AdminDlpPolicy -PolicyName "<GUID>" -NonBusinessDataGroup $array           # Update Non-Business group
New-AdminDlpPolicy -DisplayName "<NAME>" -BusinessDataGroup $array             # Create new policy
Remove-AdminDlpPolicy -PolicyName "<GUID>"                                     # Delete policy (careful!)

# --- CONNECTORS ---
Get-AdminPowerAppConnector -EnvironmentName "<ENV>"                            # List connectors in env
Get-AdminPowerAppConnector -EnvironmentName "<ENV>" | Where-Object { $_.ConnectorType -eq "CustomConnector" }  # Custom only

# --- USEFUL CONNECTOR IDs ---
# /providers/Microsoft.PowerApps/apis/shared_sharepointonline   = SharePoint
# /providers/Microsoft.PowerApps/apis/shared_office365          = Office 365 Outlook
# /providers/Microsoft.PowerApps/apis/shared_teams              = Microsoft Teams
# /providers/Microsoft.PowerApps/apis/shared_commondataservice  = Dataverse
# /providers/Microsoft.PowerApps/apis/shared_onedriveforbusiness= OneDrive for Business
# /providers/Microsoft.PowerApps/apis/shared_dropbox            = Dropbox
# /providers/Microsoft.PowerApps/apis/shared_googledrive        = Google Drive
# /providers/Microsoft.PowerApps/apis/shared_twitter            = Twitter/X
```

---
## 🎓 Learning Pointers

- **DLP policies are about connector topology, not content**: Power Platform DLP does not inspect what data flows through connectors — it only checks which connectors appear in the same flow. A flow can move every secret in your SharePoint to a SQL Server database without DLP concern (both are Business connectors). DLP's threat model is specifically about cross-boundary leakage — corporate to personal services. Complement with Purview sensitivity labels and Conditional Access for content-level controls. [MS Docs — DLP overview](https://learn.microsoft.com/en-us/power-platform/admin/wp-data-loss-prevention)
- **The Default environment is a governance liability**: Microsoft creates it automatically and every user can build flows in it. Without a strict DLP policy on the Default environment, any user can connect SharePoint to their personal Gmail, Dropbox, or Twitter. Locking down the Default environment with a restrictive DLP policy is the single highest-impact governance action in a new tenant. [Default environment guidance](https://learn.microsoft.com/en-us/power-platform/admin/environments-overview#the-default-environment)
- **Managed Environments unlock endpoint filtering**: The HTTP connector is a DLP grey area — blocking it breaks legitimate integrations, but allowing it enables arbitrary outbound calls. Managed Environments (part of Power Platform Premium or add-on) enable endpoint filtering: allow the HTTP connector but restrict it to an approved URL list (e.g., `*.yourcompany.com`, `api.approved-vendor.com`). This is the production-grade answer for HTTP governance. [Endpoint filtering](https://learn.microsoft.com/en-us/power-platform/admin/connector-endpoint-filtering)
- **Policy propagation is asynchronous**: DLP policy changes do not take effect instantly. The Power Platform backend queues policy updates and applies them to environments asynchronously — typically within 15–60 minutes. Don't troubleshoot immediately after a policy change and assume it hasn't worked. Wait at least 30 minutes before concluding propagation failed. If after 60 minutes the policy still isn't applied, open a Microsoft support ticket.
- **Flow suspension is non-destructive**: A suspended flow is not deleted. The flow definition, run history, and connections are all preserved. Once the DLP violation is resolved, the flow can be re-enabled by the owner (or an admin). This is important to communicate to users — their automation isn't gone, it's paused pending a policy correction.
- **CoE Starter Kit provides DLP reporting at scale**: Microsoft's free Center of Excellence (CoE) Starter Kit includes Power BI dashboards that visualise DLP violations, suspended flows, and connector usage across all environments. For MSPs managing large tenants, the CoE kit is essential — building equivalent visibility from PowerShell alone is time-consuming. [CoE Starter Kit](https://learn.microsoft.com/en-us/power-platform/guidance/coe/starter-kit)
