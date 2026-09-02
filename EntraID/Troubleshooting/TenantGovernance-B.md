# Microsoft Entra Tenant Governance — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## ⚠ A note before you start — this is not GDAP, and the two don't coexist

Tenant Governance is a **native Entra capability** (GA since summer 2026) for discovering and centrally administering multiple tenants — including the MSP/CSP/MSSP "manage many customer tenants from one place" scenario. It looks similar to GDAP but is a **different object model** with one hard incompatibility: **a Tenant Governance relationship cannot coexist with a Partner Center GDAP relationship between the same two tenants.** If you already have GDAP with this customer, you must remove the Partner Center GDAP relationship first. If the ticket is about an existing CSP/GDAP relationship specifically (not this feature), go to `GDAP-B.md` instead.

---
## Triage

Run these signed into **Microsoft Graph in the GOVERNING tenant** (the tenant that administers others) unless noted otherwise.

```powershell
# 1. Connect with the read scope needed for every check below
Connect-MgGraph -Scopes "TenantGovernance-Relationship.Read.All" -NoWelcome
(Get-MgContext).TenantId

# 2. List all governance relationships involving this tenant (as governing OR governed)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Select-Object id, status, governingTenantName, governedTenantName, creationDateTime |
    Format-Table -AutoSize

# 3. Check whether related-tenant discovery is even enabled (it's a one-way switch — see Learning Pointers)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings"

# 4. Confirm you're not colliding with an existing Partner Center GDAP relationship to the same customer
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Select-Object DisplayName, Status, Customer

# 5. If a relationship exists, inspect its policy snapshot (role assignments, provisioned multitenant apps)
$relId = "<governanceRelationshipId>"
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships/$relId").policySnapshot |
    ConvertTo-Json -Depth 6
```

| Result | Action |
|--------|--------|
| No relationship found for a customer you expect to already govern | → [Fix 1 — Set Up a New Governance Relationship](#fix-1--set-up-a-new-governance-relationship) |
| Relationship `status = Pending` and stuck | → [Fix 2 — Resolve a Stuck Handshake](#fix-2--resolve-a-stuck-handshake) |
| A GDAP relationship already exists to the same customer | → [Fix 3 — Retire Partner Center GDAP Before Creating Tenant Governance](#fix-3--retire-partner-center-gdap-before-creating-tenant-governance) |
| Admin in the governing tenant can't actually act in the governed tenant despite `status = Active` | → [Fix 4 — Fix Delegated Administration Access](#fix-4--fix-delegated-administration-access) |
| Governed tenant terminated the relationship unexpectedly | → [Fix 5 — Confirm and Respond to a Termination](#fix-5--confirm-and-respond-to-a-termination) |
| Configuration monitor exists but isn't reporting drift / new monitor fails to create | → [Fix 6 — Configuration Monitor Not Reporting](#fix-6--configuration-monitor-not-reporting) |
| Related tenants missing / discovery never populates | → [Fix 7 — Related-Tenant Discovery Not Populating](#fix-7--related-tenant-discovery-not-populating) |
| All checks pass, still broken | → Escalate — capture the Evidence Pack below and open a support case referencing the `governanceRelationship` `id` |

---
## Dependency Cascade

<details><summary>What must be true for cross-tenant governance to actually work</summary>

```
Entra ID (Identity) — both tenants
  └── Tenant Governance licensed (Basic or Premium — feature availability varies by tier)
        └── Related-tenant discovery enabled (isRelatedTenantsEnabled = true — irreversible once set)
              └── Relationship handshake completed
                    (governed tenant sends invitation → governing tenant sends request
                     with a governance policy template → governed tenant accepts)
                    └── Governance relationship status = Active
                          ├── NOT also a Partner Center GDAP relationship to the same
                          │   tenant pair — hard mutual exclusion, first-created wins
                          ├── delegatedAdministrationRoleAssignments provisioned
                          │     (security group in governing tenant ↔ Entra role
                          │      template in governed tenant)
                          │     └── Governing-tenant admin is a MEMBER of that group
                          │           └── (optional) PIM for Groups — admin must
                          │                 ACTIVATE membership before GDAP-style
                          │                 access applies (PIM policies configured
                          │                 IN the governed tenant do NOT apply here)
                          └── multiTenantApplicationsToProvision (if used)
                                └── App consent/provisioning succeeded in governed tenant
                    └── (optional) Configuration management layer
                          └── Unified Tenant Configuration Management service principal
                                has read permission on baseline resource types
                                └── Monitor created, referencing a JSON baseline
                                      └── Runs every 6 hours → configurationDrift objects
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm licensing and that discovery is enabled**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings"
```
Expected: `isRelatedTenantsEnabled: true`. If `false`, related tenants have never been turned on for this tenant — that's a one-time, one-way action (see Fix 7), separate from governance relationships themselves (a relationship can still be created manually without discovery being on).

**Step 2 — Confirm the relationship exists and its status**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Select-Object id, status, governingTenantId, governedTenantId, creationDateTime
```
Expected: `status = Active` for a working relationship. `Pending` means the handshake never completed — the counterparty tenant hasn't accepted yet. There is no `status` value for a relationship that was rejected long ago; a rejected request simply doesn't appear as an active relationship (check request history in the admin center under **Tenant Governance > Governance relationships > Requests**).

**Step 3 — Confirm no competing Partner Center GDAP relationship exists**
```powershell
Get-MgTenantRelationshipDelegatedAdminRelationship | Select-Object DisplayName, Status, Customer
```
Expected: no active GDAP relationship to the same customer tenant ID as the Tenant Governance relationship. If one exists, the Tenant Governance relationship creation would have failed outright (or, if GDAP was created second, that creation attempt fails) — this is enforced by the platform, not a soft warning.

**Step 4 — Confirm delegated administration access is actually usable**
```powershell
# From the GOVERNING tenant, confirm the admin's group membership backing the relationship
Get-MgGroupMember -GroupId "<securityGroupId-from-policySnapshot>" | Select-Object Id, AdditionalProperties

# If PIM for Groups is in play, confirm the admin has ACTIVATED (not just eligible) membership
Get-MgIdentityGovernancePrivilegedAccessGroupAssignmentScheduleInstance -Filter "principalId eq '<adminObjectId>'"
```
Expected: admin is an active (not merely eligible, unless activated) member of the group referenced in the relationship's `policySnapshot.delegatedAdministrationRoleAssignments`. A common trap: the admin is eligible via PIM but never activated, so the relationship looks perfectly healthy from the Graph side while the admin still can't do anything in the governed tenant.

**Step 5 — Confirm configuration monitors are running (if configured)**
```powershell
# Requires being signed into the GOVERNED (target) tenant with delegated admin access from Step 4
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors"
```
Expected: monitor `state` healthy and a recent `configurationMonitoringResult`. Monitors run on a fixed 6-hour interval — a monitor created minutes ago will not have a result yet; that's expected, not a fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Set Up a New Governance Relationship</summary>

**When:** No relationship exists yet between your tenant and a customer/related tenant you need to govern.

Portal (recommended for the first relationship with a new customer): **Microsoft Entra admin center > Tenant Governance > Governance relationships > + New request**, select the target tenant, choose or build a **governance policy template**, and send. The customer/governed tenant admin must accept.

If the future governed tenant already sent you an invitation (check **Tenant Governance > Governance relationships > Invitations** first), respond to that invitation with a request rather than starting a fresh one — tenants related via a shared billing account can skip the invitation step entirely.

```powershell
# Read-only confirmation once accepted
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Where-Object governedTenantId -eq "<targetTenantId>"
```

**Rollback:** A relationship in `Pending` state can be withdrawn from the portal before the counterparty accepts. Once `Active`, terminate via **Governance relationships > [relationship] > Terminate** (see Fix 5 for the termination lifecycle).

</details>

<details><summary>Fix 2 — Resolve a Stuck Handshake</summary>

**When:** A governance request has sat in `Pending` for longer than expected.

1. Confirm the invitation/request actually reached the counterparty tenant — ask the governed-tenant admin to check **Tenant Governance > Governance relationships > Requests** (not Invitations — request vs. invitation are different queue objects depending on who initiated).
2. Confirm the requesting admin holds a role permitted to send governance requests (**Tenant Governance Administrator** or **Global Administrator**) — a request sent by an under-privileged account can silently fail to notify the counterparty correctly.
3. Re-send the request if the original may have been dismissed unseen; there's no automatic expiry/reminder documented for a pending request, so stale requests require a manual resend.

**Rollback:** N/A — diagnostic/resend only.

</details>

<details><summary>Fix 3 — Retire Partner Center GDAP Before Creating Tenant Governance</summary>

**When:** You need a Tenant Governance relationship with a customer you already manage via Partner Center GDAP.

```powershell
# Identify the existing GDAP relationship
$gdap = Get-MgTenantRelationshipDelegatedAdminRelationship | Where-Object { $_.Customer.TenantId -eq "<customerTenantId>" }
$gdap | Select-Object Id, DisplayName, Status
```

1. In Partner Center (or via Graph), terminate the existing GDAP relationship. Full termination procedure and impact analysis is out of scope here — see `GDAP-B.md`/`-A.md` for that relationship's own lifecycle and what access is lost when it ends.
2. Only after the GDAP relationship shows `Terminated`, create the Tenant Governance relationship (Fix 1).

**This is a real trade-off, not just a technical gate:** GDAP has more mature per-role, time-boxed granularity that some MSPs rely on today; Tenant Governance's group-based model plus PIM for Groups is a different (and, per Microsoft's FAQ, often easier-to-maintain) shape but is not a feature-for-feature drop-in. Confirm the target role/access set is actually representable in a Tenant Governance policy template before retiring a working GDAP relationship.

**Rollback:** Terminating GDAP is the customer-tenant's (or your) own action in Partner Center and is not easily undone — re-establishing GDAP requires a fresh customer approval. Don't do this step until the Tenant Governance relationship's policy template has been reviewed and approved by both sides.

</details>

<details><summary>Fix 4 — Fix Delegated Administration Access</summary>

**When:** The relationship shows `Active` but an admin in the governing tenant still can't perform expected actions in the governed tenant.

```powershell
# Confirm which security group + role templates the relationship actually grants
$relId = "<governanceRelationshipId>"
$rel = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships/$relId"
$rel.policySnapshot.delegatedAdministrationRoleAssignments | ConvertTo-Json -Depth 5

# Add the admin to the group backing that role assignment (governing tenant)
Add-MgGroupMember -GroupId "<securityGroupId>" -DirectoryObjectId "<adminObjectId>"
```

If PIM for Groups fronts that security group, the admin must **activate** membership (not just hold eligibility) before delegated access applies — activation happens in the governing tenant; PIM policies configured inside the governed tenant have no effect on this activation (documented limitation, not a bug).

**Rollback:** Remove the admin from the group to revoke access without touching the relationship itself.

</details>

<details><summary>Fix 5 — Confirm and Respond to a Termination</summary>

**When:** A relationship that was `Active` is now gone or shows `Terminated`, and nobody in the governing tenant remembers ending it.

A **governed** tenant can unilaterally terminate a governance relationship at any time — this is by design (the governed tenant always retains the right to end being governed). The governing tenant's admins see the relationship move to `Termination requested` then `Terminated` and should receive an email notification.

```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Where-Object status -in @("Termination requested","Terminated") |
    Select-Object id, status, governedTenantName, creationDateTime
```

If this was unexpected, contact the governed tenant's admin directly — Tenant Governance has no override to force a relationship to stay active against the governed tenant's will. If access is business-critical, this is a relationship (contract/customer) conversation, not a technical fix.

**Rollback:** N/A — a governed tenant's termination is final; a new relationship must go through the full handshake again if both sides agree to re-establish it.

</details>

<details><summary>Fix 6 — Configuration Monitor Not Reporting</summary>

**When:** A configuration monitor exists but shows no recent results, or a new monitor/snapshot job fails to create.

```powershell
# Check monitor state and last result
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors/<monitorId>"

# Check for quota exhaustion — 200 resource instances per baseline, 800 per tenant per day
$monitors = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors").value
$monitors | ForEach-Object { [pscustomobject]@{ Name = $_.displayName; ResourceCount = $_.baseline.resources.Count } }
```

Common causes:
1. **Daily 800-resource-instance tenant quota exceeded** — a new monitor creation fails outright if it would push the tenant over the limit; reduce scope on an existing monitor or consolidate baselines.
2. **Unified Tenant Configuration Management service principal lacks read permission** on one or more resource types in the baseline — grant per the authentication-setup requirements before the monitor can evaluate those resources.
3. **Six-hour run interval not yet elapsed** — a monitor created recently has no result yet; this is expected, not a fault.

**Rollback:** Deleting a monitor stops future evaluation immediately; existing `configurationDrift` records remain queryable until the monitor itself is deleted.

</details>

<details><summary>Fix 7 — Related-Tenant Discovery Not Populating</summary>

**When:** Related tenants was enabled but the list stays empty, or a tenant you expect to see (e.g., a known shadow-IT tenant) never appears.

```powershell
# Confirm discovery is actually enabled
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings"

# If not enabled, enable it (ONE-WAY — cannot be reverted once set to true)
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings/enableRelatedTenants"
```

Discovery is signal-based (B2B collaboration, multitenant app consent, shared billing account) and synthesized from existing activity — it is **not instantaneous** and can take time to populate after enabling, and it will never surface a tenant with zero B2B/app/billing interaction history with yours (no interaction = nothing to discover, not a bug).

**Rollback:** None — `isRelatedTenantsEnabled` cannot be reverted to `false` once set. Confirm this is actually wanted (and licensed) before enabling in a production tenant.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== TENANT GOVERNANCE ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Governing tenant ID: _______________
Governed/related tenant ID: _______________
Governance relationship ID: _______________

SYMPTOM:
[ ] Cannot create a new governance relationship
[ ] Relationship stuck in Pending
[ ] Relationship Active but delegated access not working
[ ] Unexpected termination
[ ] Configuration monitor / drift detection not working
[ ] Related-tenant discovery not populating
[ ] Conflict with existing GDAP relationship
[ ] Other: _______________

TRIAGE RESULTS:
isRelatedTenantsEnabled: _______________
Relationship status: _______________
Competing GDAP relationship found (Y/N): _______________
Admin group membership confirmed (Y/N): _______________
PIM for Groups activation confirmed, if applicable (Y/N): _______________
Configuration monitor state / last result: _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
```

---
## 🎓 Learning Pointers

- **Enabling related-tenant discovery is a one-way door**: `isRelatedTenantsEnabled` cannot be reverted to `false` once set to `true`. Treat it as a deliberate, licensed decision, not a toggle to experiment with in production. Reference: [Enable tenant discovery](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/how-to-enable-tenant-discovery)
- **Tenant Governance and Partner Center GDAP are mutually exclusive per tenant pair, not complementary**: this is the single most common surprise for an MSP already running GDAP — plan the cutover (Fix 3) deliberately rather than discovering the conflict mid-incident.
- **A related tenant is not an owned tenant**: discovery surfaces *evidence of a relationship* (B2B, app consent, shared billing) — it implies nothing about ownership or administrative control. Don't treat an unrecognized related tenant as automatically actionable; investigate via the billing/B2B/app signals before reaching out. Reference: [FAQ — Related tenants](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/faq)
- **Multi-tier governance isn't supported (with one narrow exception)**: a tenant can't be both governing and governed in a chain (A governs B, B governs C is rejected outright) — except that a *governed* tenant can still create new add-on tenants, which it then governs. Don't design a delegation hierarchy around multi-tier chaining.
- **PIM for Groups activation happens in the governing tenant, full stop**: PIM policies configured inside the governed tenant have zero effect on a governing-tenant admin's access — this trips up admins who assume PIM settings "belong" to whichever tenant they're trying to protect.
- **Configuration monitors run every 6 hours on a fixed schedule with hard daily quotas** (200 resource instances/baseline, 800/tenant/day) — a "monitor isn't detecting my change yet" ticket opened 10 minutes after the change is very likely just waiting for the next scheduled run, not a fault.
