# Microsoft Security Copilot — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---
## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope:**
- Microsoft Security Copilot's three-layer RBAC model (Security Copilot roles, Microsoft Entra RBAC, plugin/service-specific RBAC) and how they combine to gate both the standalone portal and embedded experiences
- Security Compute Unit (SCU) capacity — provisioned vs. overage billing, auto-provisioning for Microsoft 365 E5/E7, and capacity-management permission requirements
- Plugin and promptbook publishing/sharing scope (personal vs. tenant)
- Multitenant/MSSP access models: B2B tenant switching, GDAP, and Azure Lighthouse

**Out of scope:**
- **Microsoft 365 Copilot** (the productivity assistant embedded in Word/Excel/Teams/Outlook) — an entirely different product with its own licensing and RBAC model. See `M365/Copilot/Copilot-A.md`.
- **Copilot in Intune** and other individual embedded-experience feature depth beyond the RBAC/licensing gate to reach them — each embedded surface's own feature behavior is documented by its host product, not here.
- **Microsoft Sentinel, Defender XDR, Intune, and Purview RBAC systems in full** — referenced only at the level needed to explain why a Security Copilot plugin does or doesn't return data. For deep RBAC troubleshooting in those services themselves, see the relevant domain folder (`Security/Defender/`, `Security/Purview/`, `Intune/Troubleshooting/`, `EntraID/Troubleshooting/`).
- **Conditional Access policy design for AI/Copilot access** — referenced only as a layering recommendation, not a CA design guide. See `Security/ConditionalAccess/`.
- **Custom agent/plugin development** — this runbook covers publishing and permission scope for existing plugins/agents, not building new ones.

**Assumptions:**
- Security Copilot has been onboarded for the tenant already (auto for eligible Microsoft 365 E5/E7 customers, or manually for others) — this runbook covers day-2 access/capacity troubleshooting, not initial onboarding.
- You have Azure and/or Entra admin access sufficient to inspect role assignments (`Global Reader`, `Security Reader`, or higher).

---
## How It Works

<details><summary>Full architecture — the three-layer RBAC model and capacity system</summary>

Security Copilot deliberately separates **platform access** from **data access**, and layers a third **compute capacity** gate on top of both. Understanding these as three genuinely independent systems — not one unified permission model — resolves the large majority of real-world access tickets.

**Layer 1 — Security Copilot RBAC (platform capabilities).** This is Security Copilot's *own* role system, not an Entra role: **Copilot Owner** and **Copilot Contributor**. These roles gate what a user can *do on the platform itself* — create sessions, manage personal or tenant-published custom plugins, manage promptbooks, view the usage dashboard, and manage capacity. They grant **zero** access to underlying security data by themselves. Security Copilot enforces a floor of two Owners at all times (the two cannot be removed) to prevent accidental lockout — several Entra, Intune, and Purview roles automatically inherit Copilot Owner specifically to guarantee this floor is always met even before anyone manually assigns roles: Global Administrator, Security Administrator, Billing Administrator, Intune Administrator, Entra Compliance Administrator, Purview Compliance Administrator, Purview Data Governance Administrator, and Purview Organization Management.

**Layer 2 — Microsoft Entra RBAC (cross-product access + Copilot role inheritance).** Beyond the auto-inheriting roles above, Entra RBAC is otherwise a *separate* concern from Security Copilot access — Entra roles determine access across the broader Microsoft portfolio, and Security Copilot layers on top of whatever a user's Entra roles already grant them elsewhere (e.g., holding Compliance Administrator gives access to Purview plugin data because that role already grants Purview access generally, not because Security Copilot grants it).

**Layer 3 — Plugin/service-specific RBAC (actual data access, via on-behalf-of authentication).** This is the layer most tickets trace back to. Security Copilot implements **on-behalf-of authentication**: every plugin invocation runs under the *signed-in user's own permissions* against that plugin's underlying service. Holding Copilot Owner/Contributor does not, by itself, grant access to Sentinel incidents, Intune device data, Defender XDR alerts, or Purview content — each of those requires its own service-specific role (`Microsoft Sentinel Reader`, an Intune RBAC role like `Endpoint Security Manager`, a Defender XDR Unified RBAC role, a Purview role) assigned independently. This is a deliberate Responsible AI / least-privilege design choice: Security Copilot cannot become a privilege-escalation vector, because it never sees more than the user already could.

**Capacity (SCUs) — a fourth, orthogonal gate.** Independent of all three RBAC layers, every Security Copilot action (standalone portal prompts, embedded-experience invocations, agent invocations) consumes **Security Compute Units (SCUs)**, billed against **provisioned capacity** (fixed hourly allocation, minimum 1 SCU, refreshing on clock-hour boundaries and *not* rolling over) plus optional **overage capacity** (consumption-based, billed to one decimal place, capped or unlimited). Microsoft 365 E5/E7 tenants get an auto-provisioned **Default Security Copilot Capacity** (400 SCU/month per 1,000 paid licenses, up to 10,000 SCU/month, at no additional cost) the moment inclusion is enabled; everyone else must provision capacity manually before Security Copilot functions at all. Provisioning or changing capacity itself requires **both** Azure RBAC (Contributor/Owner on the subscription/resource group) **and** Entra RBAC (Security Administrator or higher) simultaneously — neither alone is sufficient, and this dual requirement is a frequent source of "I have admin rights but still can't change this" tickets.

**Multitenant/MSSP access** adds a fifth dimension for partner-managed environments: **B2B guest accounts with tenant switching** (built into the standalone portal, requires an external member account provisioned in the target tenant with roles assigned there), **GDAP** via Partner Center, and **Azure Lighthouse** via the Azure portal — three distinct mechanisms for three distinct scenarios (ad hoc cross-tenant analyst access, delegated partner administration, and Azure-resource-scoped delegation, respectively).

</details>

---
## Dependency Stack

```
Tenant onboarding: Security Copilot enabled
    (auto for eligible Microsoft 365 E5/E7 — manual capacity provisioning otherwise)
    │
Layer 1 — Security Copilot RBAC: Copilot Owner or Copilot Contributor
    (own role system; some Entra/Intune/Purview admin roles auto-inherit Owner)
    │
Layer 4 — SCU capacity available for the current clock-hour
    (provisioned capacity refreshes hourly and does not roll over;
     overage capacity absorbs spikes if configured)
    │
Session created (standalone portal) OR embedded experience reached
    (each embedded surface — Defender XDR, Purview, Intune, Entra —
     needs its own license/enablement plus the Layer 1 role)
    │
Layer 3 — Plugin invoked: on-behalf-of authentication against the
    plugin's own underlying service RBAC (Sentinel, Intune, Defender XDR,
    Purview, etc. — each independent of Layers 1 and 2)
    │
Result bounded by the MOST RESTRICTIVE layer in the chain
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| User cannot open the Security Copilot portal or any embedded experience at all | No Copilot Owner/Contributor role, direct or inherited | Check Entra directory role membership against the auto-inheriting role list; check direct Copilot role assignment |
| Portal/embedded experience opens, but a specific plugin returns no data or "insufficient permissions" | Missing the plugin's own service-specific RBAC role (Layer 3) — the single most common ticket type | Check the user's role on the specific underlying service (Sentinel, Intune, Defender XDR, Purview) |
| "You are out of Security Compute Units" mid-session | Provisioned SCUs exhausted for the current clock-hour, no overage configured | Check `Microsoft.SecurityCopilot/capacities` resource and Manage capacity settings |
| Admin has Security Administrator but can't provision or resize capacity | Missing the *other* required role — Azure Contributor/Owner on the subscription/RG (both are required simultaneously) | Check Azure RBAC assignment at the capacity resource's subscription/RG scope |
| Custom plugin built by one user isn't visible to colleagues | Still personal-scope; never published to the tenant | Check plugin publish scope; confirm publisher had rights (Owner-only by default) |
| Promptbook built by one user isn't visible to colleagues | Not shared with the tenant at creation or afterward | Check promptbook sharing scope — this action is available to both Owner and Contributor, unlike custom plugin publishing |
| MSSP/partner analyst can't access a customer tenant's Security Copilot | Wrong multitenant mechanism for the scenario, or role not assigned on the external account | Confirm whether the scenario needs B2B tenant switching, GDAP, or Azure Lighthouse — they are not interchangeable |
| Recipient of a shared session link sees data they shouldn't have plugin access to themselves | Expected behavior, not a bug — shared sessions do not re-evaluate the viewer's plugin permissions | Confirm this is a policy/sharing-practice question, not an access-control defect |
| "Everyone" group was removed from Contributor access and now can't be restored | Expected — this is explicitly a one-way action per Microsoft's design | Confirm the intended replacement (Recommended Microsoft Security roles or custom group) is now in place instead |
| Region-specific: session sharing via email doesn't work | Expected in South Africa North and UAE North — not supported in those regions | Confirm tenant/session region before troubleshooting further |

---
## Validation Steps

1. **Confirm Security Copilot role (Layer 1).**
   ```powershell
   Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" -NoWelcome
   Get-MgUserMemberOf -UserId "<user@domain.com>" |
       Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
       Select-Object -ExpandProperty AdditionalProperties | Select-Object displayName
   ```
   Good: at least one auto-inheriting role, or a direct Copilot Owner/Contributor assignment (verify the latter in the Security Copilot portal's Role assignment page — it isn't exposed via this Graph call). Bad: no matching role at all.

2. **Confirm plugin-specific service RBAC (Layer 3)** for the plugin in question. Example for Sentinel:
   ```powershell
   Get-AzRoleAssignment -SignInName "<user@domain.com>" -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>" |
       Where-Object { $_.RoleDefinitionName -match "Sentinel" }
   ```
   Good: a Sentinel Reader/Contributor (or equivalent) assignment present. Bad: no matching role — this is the layer most tickets are missing.

3. **Confirm SCU capacity exists and its provisioned/overage configuration.**
   ```powershell
   Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties |
       Select-Object Name, Location, Properties
   ```
   Good: a capacity resource present with a sane SCU count for tenant size. Bad: no resource found in a non-E5/E7 tenant, or a resource present but visibly under-provisioned relative to reported usage complaints.

4. **Confirm dual-role requirement for capacity changes**, if the ticket is about provisioning/resizing failing.
   ```powershell
   Get-AzRoleAssignment -SignInName "<user@domain.com>" -Scope "/subscriptions/<sub-id>"
   # Separately, confirm Entra Security Administrator (or higher) via the Entra admin center or Get-MgUserMemberOf above
   ```
   Good: both Azure Contributor/Owner and Entra Security Administrator+ present. Bad: only one of the two.

5. **Confirm publish/share scope** for a plugin or promptbook reported as "invisible to others."
   Check the item's settings in the Security Copilot portal for personal-vs-tenant scope, and confirm the creator's role permitted publishing (Owner-only by default for custom plugins; either role for promptbooks).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Platform access.** Run Validation Step 1. If the user has no path to Copilot Owner/Contributor (direct or inherited), nothing else in this runbook applies until that's granted.

**Phase 2 — Data access.** Run Validation Step 2 for every plugin/embedded experience in the ticket. Since each plugin has independent RBAC, a user can be fully correct on some plugins and missing the role on others — check each one named in the ticket individually rather than assuming a single fix covers all of them.

**Phase 3 — Capacity.** Run Validation Step 3. If SCU exhaustion is suspected, correlate the timestamp of the failure against the tenant's clock-hour billing boundaries (capacity resets on the hour, not on a rolling basis) before concluding capacity itself is undersized.

**Phase 4 — Capacity management permissions**, only if the ticket is specifically about an admin being unable to change capacity (not use Copilot). Run Validation Step 4.

**Phase 5 — Publishing/sharing scope**, only if the ticket concerns content visibility between users rather than raw access. Run Validation Step 5.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Grant baseline Security Copilot access via group-based Contributor role</summary>

Rather than assigning individual users, create (or use) a role-assignable Entra security group and assign it Contributor:
```powershell
# Requires Entra role-assignable group already created — see Microsoft Learn:
# "Creating role-assignable groups in Entra ID"
```
Then, in the Security Copilot portal: home menu → **Role assignment** → **Add members** → select the group → **Copilot Contributor** → **Add**.

If the tenant currently has **Everyone** assigned and needs to move to a scoped model, first assign the **Recommended Microsoft Security roles** group (or a custom group), verify it covers the intended population, and only then remove **Everyone** — this action cannot be undone once **Everyone** is removed.

**Rollback:** Remove the group's role assignment; individual members lose access immediately.

</details>

<details><summary>Playbook 2 — Diagnose and close a Layer 3 (plugin RBAC) gap systematically</summary>

For each plugin named in a ticket, identify and verify its specific RBAC requirement rather than guessing:

| Plugin | Underlying RBAC to check |
|---|---|
| Microsoft Sentinel | `Microsoft Sentinel Reader` / `Contributor` on the Log Analytics workspace |
| Microsoft Intune | An Intune RBAC role scoped to the relevant device/policy set (e.g. `Endpoint Security Manager`) |
| Microsoft Defender XDR | Defender XDR Unified RBAC role assignment |
| Microsoft Purview | A Purview role such as `Compliance Administrator` |
| Microsoft Entra ID | Entra role appropriate to the queried data (e.g. sign-in logs, risk data) |

```powershell
# Generic pattern — substitute the correct resource scope and role name per plugin
New-AzRoleAssignment -SignInName "<user@domain.com>" -RoleDefinitionName "<role-name>" -Scope "<resource-scope>"
```
For non-Azure-RBAC-based services (Intune, Defender XDR Unified RBAC, Purview), grant the role through that service's own admin center rather than Az PowerShell.

**Rollback:** `Remove-AzRoleAssignment` with matching parameters, or remove the role via the owning service's admin center.

</details>

<details><summary>Playbook 3 — Right-size SCU capacity and configure overage</summary>

1. Review usage patterns via the Security Copilot usage monitoring dashboard (Owner-only) before changing provisioned capacity
2. Increase/decrease provisioned SCUs to match steady-state baseline load — remember changes apply from the next clock-hour boundary, not retroactively within the current hour
3. Configure overage capacity (capped or unlimited) to absorb spikes without hard-stopping user sessions:
   - Security Copilot portal → **Manage capacity settings** (requires Copilot Owner)
4. Re-verify via:
   ```powershell
   Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties
   ```

**Rollback:** Reduce provisioned SCUs or disable overage at any time — takes effect at the next billing boundary for provisioned capacity, immediately for overage limits.

</details>

<details><summary>Playbook 4 — Set up MSSP/cross-tenant access correctly</summary>

Choose the mechanism that matches the actual scenario — they are not interchangeable:

- **Ad hoc analyst access via B2B guest/tenant switching:** provision an external member account for the analyst in the target (Security-Copilot-provisioned) tenant, assign the necessary Copilot and plugin roles on that external account, then have the analyst sign in with their home-tenant credential and use tenant switching in the standalone portal.
- **Delegated partner administration via GDAP:** set up through Partner Center — see [Grant MSSPs access to Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/grant-access-external-users).
- **Azure-resource-scoped delegation via Azure Lighthouse:** set up through the Azure portal — same reference as above.

**Rollback:** Remove the external member account's role assignments (B2B), revoke the GDAP relationship in Partner Center, or remove the Lighthouse delegation, as appropriate to the mechanism used.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Security Copilot access/capacity evidence for a specific user, for escalation.
.NOTES     Read-only. Requires Microsoft.Graph and Az.Resources modules, and appropriate
           Graph/Azure read permissions. Does not modify any role assignment or capacity setting.
#>
param(
    [Parameter(Mandatory)] [string] $UserPrincipalName,
    [string] $SubscriptionId
)

Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" -NoWelcome
if ($SubscriptionId) { Connect-AzAccount -Subscription $SubscriptionId | Out-Null }

$evidence = [ordered]@{
    Timestamp        = (Get-Date).ToString('u')
    UserPrincipalName= $UserPrincipalName
    EntraDirectoryRoles = (Get-MgUserMemberOf -UserId $UserPrincipalName |
        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
        ForEach-Object { $_.AdditionalProperties.displayName }) -join '; '
}

if ($SubscriptionId) {
    $evidence.AzureRoleAssignments = (Get-AzRoleAssignment -SignInName $UserPrincipalName -Scope "/subscriptions/$SubscriptionId" |
        ForEach-Object { "$($_.RoleDefinitionName) @ $($_.Scope)" }) -join '; '
    $evidence.CapacityResources = (Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" |
        ForEach-Object { "$($_.Name) ($($_.Location))" }) -join '; '
}

$evidence | ConvertTo-Json -Depth 4 | Out-File "$env:TEMP\SecurityCopilotEvidence_$($UserPrincipalName -replace '[^a-zA-Z0-9]','_').json"
Write-Host "Evidence written to `$env:TEMP\SecurityCopilotEvidence_...json" -ForegroundColor Green
```

Pair with: a screenshot of the Security Copilot portal's **Role assignment** page, the **Manage capacity** page, and the exact error text/screenshot from the affected session.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All"` | Connect to Graph for Entra role checks |
| `Get-MgUserMemberOf -UserId <upn>` | List a user's Entra directory role memberships |
| `Connect-AzAccount` | Connect to Azure for RBAC/resource checks |
| `Get-AzRoleAssignment -SignInName <upn> -Scope <scope>` | Check Azure RBAC assignments at a given scope |
| `New-AzRoleAssignment -SignInName <upn> -RoleDefinitionName <role> -Scope <scope>` | Grant an Azure RBAC role (e.g. Sentinel Reader, Contributor) |
| `Remove-AzRoleAssignment -SignInName <upn> -RoleDefinitionName <role> -Scope <scope>` | Revoke an Azure RBAC role |
| `Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities"` | List Security Copilot capacity resources in scope |
| `Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties` | Get capacity resource details (SCU count, region) |
| Portal: Security Copilot → home menu → **Role assignment** | Manage Copilot Owner/Contributor assignments |
| Portal: Security Copilot → **Manage capacity settings** | Provision/resize SCUs, configure overage (Owner only) |
| Portal: Security Copilot → usage dashboard | Monitor SCU consumption over time (Owner only) |

---
## 🎓 Learning Pointers

- Treat Security Copilot access tickets as a four-gate checklist every time: platform role (Layer 1), plugin-specific service RBAC (Layer 3), SCU capacity availability, and — only for capacity-management tickets specifically — the dual Azure+Entra role requirement. Most "Copilot doesn't work" tickets resolve to exactly one of these four, and checking them in this order avoids wasted effort. See [Understand authentication in Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/authentication).
- The on-behalf-of authentication model is a genuine architectural guarantee, not a configurable setting — Security Copilot is designed so it can never be used to see more security data than the signed-in user could already see through their own existing permissions. This is worth explaining to clients who ask whether Copilot access needs to be more tightly locked down than their existing RBAC — the existing RBAC already is the control.
- SCU capacity billing on fixed clock-hour blocks (not rolling windows, no rollover) is a subtle but high-impact detail for cost-conscious clients — resizing capacity mid-hour doesn't help that hour's shortfall, and over-provisioning "just in case" wastes SCUs that silently expire unused every single hour. See [Security Compute Units and capacity](https://learn.microsoft.com/en-us/copilot/security/security-compute-units-capacity).
- The requirement for **both** Azure RBAC and Entra RBAC to manage capacity is a deliberate separation-of-duties design (cloud infrastructure control vs. tenant security administration) — don't treat a client's "our admin has Global Admin, why can't they resize capacity" question as a bug report; it's the intended two-key control.
- Three genuinely different mechanisms exist for cross-tenant/MSSP Security Copilot access (B2B tenant switching, GDAP, Azure Lighthouse) — picking the wrong one for the scenario (e.g. trying to use GDAP for what's really an ad hoc single-analyst access need) creates unnecessary administrative overhead. Match the mechanism to the actual access pattern before building it out.
