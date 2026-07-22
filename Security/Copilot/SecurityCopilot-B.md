# Microsoft Security Copilot — Hotfix Runbook (Mode B: Ops)
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
# 1. Confirm the user's Entra directory roles (certain roles auto-inherit Security Copilot Owner)
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" -NoWelcome
Get-MgUserMemberOf -UserId "<user@domain.com>" |
    Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
    Select-Object -ExpandProperty AdditionalProperties |
    Select-Object displayName

# 2. Confirm the user has an Azure RBAC role (Contributor/Owner) if they're trying to provision capacity
Connect-AzAccount
Get-AzRoleAssignment -SignInName "<user@domain.com>" -Scope "/subscriptions/<sub-id>" |
    Select-Object DisplayName, RoleDefinitionName, Scope

# 3. Confirm a Security Copilot capacity resource actually exists in the target subscription
Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities"

# 4. Check current SCU capacity resource details (units, region) — requires the specific resource
Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties | Select-Object Name, Properties

# 5. Confirm plugin-specific access — example for the Microsoft Sentinel plugin
Get-AzRoleAssignment -SignInName "<user@domain.com>" -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<sentinel-workspace>" |
    Where-Object { $_.RoleDefinitionName -match "Sentinel" }
```

| Result | Meaning | Do this |
|---|---|---|
| No Copilot-owner-inheriting Entra role AND not individually assigned Copilot Owner/Contributor | User has no access to the Security Copilot platform at all | Go to [Fix 1](#common-fix-paths) |
| User has Copilot Owner/Contributor but the specific plugin (e.g. Sentinel, Intune, Defender XDR) shows no data | Missing the plugin's own underlying service RBAC role — Copilot never grants access beyond what the user already has | Go to [Fix 2](#common-fix-paths) |
| No `Microsoft.SecurityCopilot/capacities` resource found in subscription | Capacity was never provisioned (not applicable to M365 E5/E7 auto-provisioned tenants) | Go to [Fix 3](#common-fix-paths) |
| User has Security Administrator but can't provision/change capacity | Capacity provisioning requires **both** an Entra security role (Security Administrator+) **and** Azure Contributor/Owner on the subscription/RG — one alone isn't enough | Go to [Fix 4](#common-fix-paths) |
| "You are out of Security Compute Units" errors mid-session | Provisioned SCUs exhausted for the current clock hour and no overage capacity configured | Go to [Fix 5](#common-fix-paths) |
| Custom plugin or promptbook built by one user isn't visible to others | Never published/shared to the tenant — still personal-scope only | Go to [Fix 6](#common-fix-paths) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Security Copilot onboarded for the tenant (auto for M365 E5/E7, manual otherwise)
        │
        ▼
Security Copilot platform access ─── Copilot Owner or Copilot Contributor role
        │        (own RBAC system — NOT an Entra role; some Entra/Intune/Purview
        │         roles auto-inherit Owner: Global Admin, Security Admin,
        │         Billing Admin, Intune Admin, Compliance Admin, Purview
        │         Data Governance Admin, Purview Organization Management)
        ▼
SCU capacity available ─── auto-provisioned (M365 E5/E7) OR manually
        │                   provisioned (needs Azure Contributor/Owner on
        │                   sub/RG + Security Administrator+ in tenant)
        ▼
Session created in standalone portal OR embedded experience invoked
        │                              (Defender XDR / Purview / Intune / Entra —
        │                               each embedded surface needs its own license
        │                               and the user's Copilot role)
        ▼
Plugin invoked in the prompt ─── on-behalf-of authentication: Copilot only
        │                        sees what the SIGNED-IN USER already has access
        │                        to via that plugin's OWN service-specific RBAC
        │                        (Sentinel Reader, Intune role, Defender XDR
        │                         Unified RBAC role, Purview role, etc.)
        ▼
Result returned — bounded by the narrowest permission in the chain above
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm Security Copilot platform access.** Check whether the user holds Copilot Owner/Contributor directly, or inherits Owner via an Entra role (Global Administrator, Security Administrator, Billing Administrator, Intune Administrator, Compliance Administrator) or a Purview role (Organization Management, Data Governance Administrator).
   ```powershell
   Get-MgUserMemberOf -UserId "<user@domain.com>" | Select-Object -ExpandProperty AdditionalProperties
   ```
   No matching role and no direct Copilot role assignment = the user cannot open the platform or any embedded experience at all.

2. **Confirm the specific plugin's underlying RBAC.** Security Copilot's own role never substitutes for a plugin's service-specific permission. For Sentinel, check `Microsoft Sentinel Reader`/`Contributor`; for Intune, check the relevant Intune RBAC role (e.g. `Endpoint Security Manager`); for Defender XDR, check the user's Unified RBAC assignment.

3. **Confirm capacity exists and isn't exhausted.**
   ```powershell
   Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ExpandProperties
   ```
   No resource in a non-E5/E7 tenant = capacity was never provisioned. Resource present but users hitting SCU errors = provisioned capacity exhausted for the current clock-hour block with no overage configured.

4. **Confirm capacity-provisioning permissions specifically**, if the ticket is about someone being unable to change capacity (not use Copilot). This needs **both** Azure Contributor/Owner at the subscription or resource group scope **and** Security Administrator or higher in the tenant — missing either one blocks the action with no clearer error than "insufficient permissions."

5. **Confirm plugin/promptbook publish scope**, if content built by one user isn't visible to others. Custom plugins and promptbooks are personal by default; publishing to the tenant is a separate, explicit action — and publishing custom plugins tenant-wide is Owner-only unless a Contributor has been explicitly granted that ability.

---
## Common Fix Paths

<details><summary>Fix 1 — User has no Security Copilot platform access</summary>

Assign the user (preferably via a security group, not individually) the **Copilot Contributor** role:
1. Security Copilot portal → home menu → **Role assignment** → **Add members**
2. Search for the user or group → select → choose **Copilot Contributor** (or **Copilot Owner** if administrative capabilities are needed)
3. **Add**

If the tenant still has the **Everyone** group assigned to Contributor, note that removing it is a one-way door — once removed it cannot be reassigned, and the recommended replacement is the **Recommended Microsoft Security roles** group (or a custom group). Don't remove **Everyone** without confirming an intended replacement is ready first.

**Rollback:** Role assignment removal (Role assignment → remove member) instantly revokes platform access; safe to reverse.

</details>

<details><summary>Fix 2 — Plugin visible but returns no data / "insufficient permissions"</summary>

This is the single most common Security Copilot ticket: the user has Copilot access but not the underlying plugin's own service RBAC role. Copilot performs **on-behalf-of** authentication — it never grants access beyond what the signed-in user's own permissions already allow on that service.

Assign the plugin-appropriate role, for example:
- Microsoft Sentinel plugin → `Microsoft Sentinel Reader` (or `Contributor`) on the Sentinel-enabled Log Analytics workspace
- Microsoft Intune plugin → an Intune RBAC role such as `Endpoint Security Manager` scoped appropriately
- Microsoft Defender XDR (embedded or plugin) → the relevant Defender XDR Unified RBAC role
- Microsoft Purview plugin → a Purview role such as `Compliance Administrator`

```powershell
# Example: grant Sentinel Reader on a specific workspace
New-AzRoleAssignment -SignInName "<user@domain.com>" -RoleDefinitionName "Microsoft Sentinel Reader" `
    -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
```

**Rollback:** `Remove-AzRoleAssignment` with the same parameters.

</details>

<details><summary>Fix 3 — No SCU capacity resource provisioned</summary>

Not applicable to onboarded Microsoft 365 E5/E7 tenants, which receive an auto-provisioned **Default Security Copilot Capacity**. For all other tenants, capacity must be manually provisioned before Security Copilot can be used at all:

1. Confirm the acting user has **both** Azure Contributor/Owner on the target subscription/resource group **and** Security Administrator or higher in the tenant
2. Azure portal → create a **Security Copilot capacity** resource (`Microsoft.SecurityCopilot/capacities`), specifying region and starting SCU count (minimum 1)
3. Attach the capacity to the Security Copilot workspace

**Rollback:** Deprovisioning capacity stops billing but also stops all Security Copilot functionality for the tenant — confirm no active investigations depend on it before removing.

</details>

<details><summary>Fix 4 — User can't change capacity despite having a security role</summary>

Capacity management requires **two separate role systems simultaneously** — this is the #1 confusing-permissions ticket for Security Copilot admins:
- **Azure RBAC:** Contributor or Owner on the subscription or resource group holding the capacity resource
- **Entra RBAC:** Security Administrator or higher in the tenant

```powershell
# Grant the missing half — Azure RBAC example
New-AzRoleAssignment -SignInName "<user@domain.com>" -RoleDefinitionName "Contributor" `
    -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>"
```
Entra role assignment (Security Administrator) is done via the Entra admin center or `New-MgRoleManagementDirectoryRoleAssignment`, not Az PowerShell. Confirm both sides before re-testing — having only one produces the same generic "insufficient permissions" symptom.

**Rollback:** Remove either role assignment via the same portal/cmdlet path used to grant it.

</details>

<details><summary>Fix 5 — SCU capacity exhausted mid-session</summary>

Provisioned SCUs refresh on fixed clock-hour blocks (e.g., 9:00–10:00) and do **not** roll over — once exhausted, requests fail unless overage capacity is configured.

**Immediate relief:** wait for the next clock-hour boundary, or increase provisioned SCUs (Security Copilot portal → **Manage capacity** → increase SCU count; takes effect at the next hour boundary, not instantly mid-hour for provisioned capacity).

**Longer-term fix:** enable overage capacity with either a capped maximum or unlimited, so unexpected spikes don't hard-stop user sessions:
1. Security Copilot portal (Owner only) → **Manage capacity settings**
2. Configure an overage limit (or set unlimited)
3. Save

**Rollback:** Overage can be disabled or capped back down at any time; this only affects future consumption, not already-billed usage.

</details>

<details><summary>Fix 6 — Custom plugin/promptbook not visible to other users</summary>

Custom plugins and promptbooks are personal-scope by default. To make them tenant-visible:
- **Promptbooks:** the creator (any role) chooses to publish/share it for the tenant at creation time, or edits sharing scope afterward — this capability is available to both Owner and Contributor.
- **Custom plugins:** publishing a custom plugin tenant-wide is **Owner-only by default**. A Contributor can only be granted this ability if an Owner explicitly enables "Allow contributors to publish custom plugins for the tenant" in settings.

**Rollback:** Un-publishing reverts the item to personal scope; no data is lost.

</details>

---
## Escalation Evidence

```
=== Microsoft Security Copilot Escalation ===
Tenant ID:                    <tenant-id>
Affected user UPN:            <user@domain.com>
Entra directory roles held:   <output from Get-MgUserMemberOf>
Security Copilot role:        <Owner / Contributor / None — from Role assignment page>
Plugin(s) involved:           <e.g. Microsoft Sentinel, Intune, Defender XDR>
Underlying service RBAC role: <role name and scope, or "not assigned">
SCU capacity resource:        <resource name/region, or "not found">
Provisioned SCUs / Overage:   <values from Manage capacity>
Time of last SCU exhaustion:  <timestamp if applicable>
Error message (verbatim):     <paste exact error text/screenshot>
Embedded experience or standalone portal:  <which one>
Ticket priority:               <P1/P2/P3>
```

---
## 🎓 Learning Pointers

- Security Copilot access is governed by **three separate RBAC systems that must all line up**: Security Copilot's own Owner/Contributor roles (platform access), Microsoft Entra RBAC (which roles auto-inherit Copilot Owner), and each plugin's own service-specific RBAC (what data Copilot can actually retrieve on the user's behalf). A ticket that looks like "Copilot is broken" is very often just layer three missing. See [Understand authentication in Microsoft Security Copilot](https://learn.microsoft.com/en-us/copilot/security/authentication).
- Security Copilot performs **on-behalf-of** authentication — it is architecturally incapable of showing a user data they couldn't already see themselves through the underlying service. This is a deliberate least-privilege design, not a bug to route around by escalating the user's Entra role.
- SCU capacity refreshes on **fixed clock-hour blocks**, not rolling windows — provisioning 3 SCUs at 9:00 gives exactly 3 SCUs for 9:00–10:00 regardless of when in that hour they're used, and none of it carries into 10:00–11:00. Size provisioned capacity for baseline load and lean on overage for spikes rather than over-provisioning "just in case." See [Security Compute Units and capacity](https://learn.microsoft.com/en-us/copilot/security/security-compute-units-capacity).
- Removing the **Everyone** group from Contributor access is irreversible — it cannot be reassigned once removed. Always confirm the replacement group (Recommended Microsoft Security roles, or a custom group) is fully configured before making that change.
- Shared Security Copilot sessions do **not** re-check the recipient's plugin permissions — the recipient sees exactly what was generated for the original user, even if the recipient personally lacks access to that data. This is a real data-exposure consideration worth flagging to clients who share session links broadly, not a permissions bug to "fix."
