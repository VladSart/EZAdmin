# Microsoft Entra Tenant Governance — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Microsoft Entra Tenant Governance** (generally available since mid-2026), a native Entra capability for discovering, centrally administering, and monitoring configuration drift across multiple Microsoft Entra tenants — the multi-tenant sprawl scenario (mergers/acquisitions, workload-partitioning tenants, test tenants, user-created "shadow IT" tenants, and MSP/CSP/MSSP customer management).

**In scope:**
- **Related tenants** — signal-based discovery (B2B, multitenant app consent, shared billing) of tenants connected to yours
- **Governance relationships** — the governing/governed directional trust model, the invitation → request → accept handshake, relationship lifecycle states, and the four supported scenarios (cross-tenant delegated administration, multitenant application management, tenant configuration management, secure tenant creation)
- **Configuration management** — baselines, monitors, monitoring results, configuration drifts, and snapshot jobs, built on the (GA) Microsoft Graph Tenant Configuration Management APIs
- **Secure tenant creation** — governed add-on tenant creation tied to a commerce billing account, with automatic governance-relationship establishment
- The explicit, documented **mutual exclusion with Partner Center GDAP** relationships between the same tenant pair
- The MSP/CSP/MSSP use case, which Microsoft explicitly supports and documents

**Assumes:**
- Microsoft Graph PowerShell SDK (beta) for the Graph calls in this runbook: `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- A user holding **Tenant Governance Administrator** (or **Global Administrator**) to enable discovery and manage relationships/policy templates; **Tenant Governance Reader**/**Global Reader** is sufficient for the read-only checks throughout this runbook
- Tenant Governance licensing is understood to vary by capability tier (free / Basic / Premium) — confirm the specific feature in question is actually licensed before troubleshooting it as broken
- Where GDAP is referenced for comparison, familiarity with `GDAP-A.md`/`-B.md` is assumed but not required

**Not covered:**
- Partner Center GDAP relationship mechanics and lifecycle in their own right (see `GDAP-A.md`/`-B.md`) — this runbook only covers the point of interaction (mutual exclusion) between the two systems
- The **multitenant organization** feature for end-user cross-tenant Microsoft 365 collaboration (Teams/OneDrive/People Search across tenants) — a related but functionally separate feature; see [FAQ — General](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/faq) for how Microsoft distinguishes the two
- Ordinary B2B guest collaboration and Cross-Tenant Access Settings (XTAS) for individual user access — see `CrossTenant-A.md`/`-B.md` and `ExternalIdentities-A.md`/`-B.md`
- Full detail on every one of the 200+ configuration-management resource types (Entra/Intune/Exchange Online/Teams/Defender/Purview) — this runbook covers the baseline/monitor/drift *mechanism*, not a catalog of every monitorable property
- Quarantine workflows for unsanctioned/unrecognized related tenants (a separate, narrower admin action) — see [Quarantine unsanctioned tenants](https://learn.microsoft.com/en-us/entra/fundamentals/quarantine-unsanctioned-tenants)

---
## How It Works

<details><summary>Full architecture</summary>

### The problem this solves

Large organizations rarely run a single Entra tenant. Mergers and acquisitions, regulatory or workload partitioning, test/sandbox tenants, and — the harder-to-see category — **user-created "shadow IT" tenants** that central IT doesn't administer and often doesn't know exist, all create a multi-tenant footprint that's difficult to inventory, let alone govern consistently. Before Tenant Governance, an organization's only options were manual tenant-by-tenant tracking, B2B guest accounts per admin per tenant (an operational and security burden that scales linearly with tenant count), or — for MSPs specifically — Partner Center GDAP, which requires a CSP partner relationship and doesn't help with tenants an organization owns directly (M&A subsidiaries, internal shadow IT).

Tenant Governance addresses this with four largely independent but interlocking capabilities: **discover** what tenants exist and how they relate to yours, **govern** the ones you need administrative reach into, **monitor** their configuration against a declared baseline, and **secure** the creation of any *new* tenant so it's never ungoverned from birth.

### Related tenants: discovery without assumed ownership

Related-tenant discovery is **signal-based**, not manually curated. Three discovery signals populate the list:
- **B2B signal** — inbound/outbound B2B guest invitations, registrations, and administrative access between your tenant and the other
- **Multitenant application signal** — registered multitenant apps with permissions in your tenant, or your apps with access in theirs
- **Billing signal** — shared Commerce billing accounts (either tenant is an associated billing tenant for the other)

Critically, a related tenant is **not implied ownership**. This is a deliberate design distinction from governance relationships: discovery is purely evidentiary (something already happened that created a detectable connection), while governance is an explicit, mutually-agreed administrative trust. An organization can — and often will — have related tenants it never governs (a partner's tenant showing up because of routine B2B collaboration is not a governance candidate; a forgotten subsidiary tenant sharing your billing account very likely is).

Enabling discovery (`POST /directory/tenantGovernance/settings/enableRelatedTenants`) is a **one-way action** — `isRelatedTenantsEnabled` cannot be reverted to `false` once set. This is unusual for a "settings" API and worth flagging explicitly in any change-management review before enabling in a production tenant: this is a permanent posture change, not a reversible experiment.

### Governance relationships: the governing/governed trust model

A governance relationship is a **directional** connection: one tenant (**governing**) administers another (**governed**). Four scenarios ride on top of an established relationship:

1. **Cross-tenant delegated administration** — least-privileged administrative access without B2B guest accounts or local admin accounts per tenant. This is architecturally the closest analog to GDAP, and per Microsoft's own FAQ, is positioned as often *easier to maintain* than per-tenant B2B accounts for multitenant administration.
2. **Multitenant application management** — centrally managing a custom multitenant app's permissions across every governed tenant, reducing the configuration-drift risk of managing each tenant's app registration independently.
3. **Tenant configuration management** — layering the baseline/monitor/drift system (below) on top of the delegated administrative access this relationship already grants.
4. **Secure tenant creation** — when a governed relationship's home tenant spins up a new add-on tenant, Tenant Governance auto-establishes governance over it using a default policy template, so the new tenant is never ungoverned even for a moment.

**The handshake** is a three-step process requiring both tenants' agreement on the *specific roles and permissions* the governing tenant will hold:
1. Future governed tenant sends a **governance invitation**
2. Future governing tenant responds with a **governance request** carrying a selected **governance policy template** (the specific role/permission bundle being requested)
3. Future governed tenant reviews and **accepts**, which establishes the relationship

Two shortcuts skip the invitation step: tenants already identified as related via a shared billing account, and tenants already in an active relationship updating or renewing it.

**Relationship states** progress `Pending` (request sent, awaiting response) → `Accepted`/`Rejected` (request outcome) → and, once established, `Active` → `Termination requested` → `Terminated` (both sides' resources deleted). **A governed tenant can always unilaterally terminate**, regardless of what the governing tenant wants — this is a deliberate design choice protecting the governed party, not a gap.

**Supported topology:** one governing tenant can govern many tenants, and many governing tenants can govern one tenant (useful where an organization uses multiple specialized MSPs for different domains). **Multi-tier chains are explicitly not supported** — if Tenant A governs Tenant B, Tenant B cannot also govern Tenant C; the platform rejects any API call that would create this shape. The one documented exception: a *governed* tenant can still create new add-on tenants (secure tenant creation scenario), which it then governs — this is additive, not a violation of the no-multi-tier rule, because the new add-on tenant wasn't part of any prior chain.

**PIM interaction** is asymmetric and easy to get backwards: PIM for Groups can front the security group that grants delegated access, requiring a governing-tenant admin to *activate* membership before using that access — this works as expected. What does **not** work: PIM policies configured *inside the governed tenant*, applied to a governing-tenant administrator's access. The governed tenant has no PIM-level control over how the governing tenant's admins use their granted access; governance is enforced entirely through the relationship's own role assignments, not through governed-tenant PIM policy.

### Configuration management: baselines, monitors, drift

This capability is explicitly built on the (already generally available) **Microsoft Graph Tenant Configuration Management APIs** — Tenant Governance is a consumer/UI layer over an existing, separately-documented Graph capability, not a wholly new backend. Five object types matter:

- **Resource** — a macro configuration component (e.g., `microsoft.entra.conditionalaccesspolicy`), one of 200+ types spanning Entra, Intune, Exchange Online, Teams, and Security & Compliance (Defender/Purview). Each resource type exposes specific manageable properties (for a CA policy: `ExcludedUsers`, `IncludedGroups`, `State`, etc.).
- **Baseline** — the declarative JSON desired-state document: a list of resource instances and their target property values. Author manually, or bootstrap from a **snapshot** of a known-good tenant.
- **Monitor** — the object that actually runs continuous comparison against a baseline, on a name/description/schedule/mode. **Monitors run every 6 hours** — this interval is not currently configurable.
- **Monitoring result** — produced on every scheduled run: duration, success/failure status, and a drift *count* (not detail — drift detail requires querying the drift objects themselves).
- **Configuration drift** — the actual delta record: which resource, which properties, what the baseline expected vs. what's actually configured. Drifts auto-resolve to `fixed` on the next monitor run after remediation — there's no manual "acknowledge" step required.
- **Snapshot job** — an async job producing a downloadable JSON snapshot of current resource state, schema-compatible with baselines (use as-is to seed a new monitor). **Snapshots and their jobs are deleted after a 7-day retention window** — download and archive promptly if the snapshot is needed for audit purposes.

**Quotas matter operationally**: 200 resource instances per baseline, 800 resource instances per tenant per day across *all* monitors combined. A tenant running several monitors can silently hit this ceiling — a new monitor or snapshot job simply **fails to create** once the daily total would be exceeded, with no partial/degraded mode.

**Conflicting baselines are allowed but confusing**: if two monitors define different desired states for the same resource/property, both run independently and each reports drift relative to its *own* baseline — Microsoft's own FAQ calls this out explicitly as something to avoid by defining a single desired state per resource, not something the platform will prevent for you.

### Secure tenant creation: governance from birth

This capability controls *who* can create new add-on tenants (via Commerce billing account access) and ensures every newly created tenant is immediately wrapped in a governance relationship using a default policy template — closing the classic "a departing employee was the only admin of a tenant nobody remembers creating" failure mode. It depends on a **Microsoft Entra ID Free billing asset**: a permanent, non-expiring record tied to exactly one tenant that demonstrates commercial/legal ownership and that Microsoft Support can use to restore access if the tenant becomes orphaned. Creating an add-on tenant requires owner/contributor rights on a Microsoft Customer Agreement (MCA) subscription — this is a commerce-layer gate, not an Entra RBAC gate.

### The GDAP mutual exclusion — and why it exists

Microsoft's own FAQ is explicit: **a Tenant Governance relationship and a Partner Center GDAP relationship cannot coexist between the same two tenants.** If a Partner Center GDAP relationship already exists with a customer, it must be removed before a Tenant Governance relationship can be created with that same tenant pair (and the reverse ordering is also blocked). This isn't presented as a temporary Preview-era limitation — it's a structural design decision, likely because both systems independently manage a governing-tenant-to-governed-tenant administrative trust and role-assignment model, and running both simultaneously would create two competing, unreconciled sources of truth for "who can do what in this tenant." For an MSP already invested in mature GDAP tooling and processes, migrating to Tenant Governance is a deliberate cutover decision (see `TenantGovernance-B.md` Fix 3), not an additive rollout.

</details>

---
## Dependency Stack

```
Entra ID (Identity) — governing tenant AND governed tenant
  └── Tenant Governance licensed (free / Basic / Premium — capability varies by tier)
        ├── [Discovery path] isRelatedTenantsEnabled = true (ONE-WAY, irreversible)
        │     └── Discovery signals accrue (B2B / multitenant app / billing)
        │           └── Related tenants surfaced (NOT implied ownership)
        └── [Governance path] Relationship handshake completed
              (invitation -> request w/ policy template -> accept)
              └── governanceRelationship.status = Active
                    ├── MUST NOT coexist with a Partner Center GDAP relationship
                    │     to the same tenant pair (platform-enforced exclusion)
                    ├── delegatedAdministrationRoleAssignments
                    │     (security group <-> Entra role template, governing tenant)
                    │     └── Admin is ACTIVE member of that group
                    │           └── (optional) PIM for Groups activation
                    │                 (governed-tenant PIM policy has NO effect here)
                    ├── multiTenantApplicationsToProvision (optional)
                    └── [Configuration management, optional layer on top]
                          └── Unified Tenant Configuration Management service
                              principal granted read permission on baseline
                              resource types (per resource-type auth setup)
                                └── Baseline (JSON) authored or from snapshot
                                      └── Monitor created (<=200 resources/baseline,
                                          <=800 resources/tenant/day)
                                            └── Runs every 6h -> monitoringResult
                                                  └── configurationDrift objects
                                                        (auto-resolves to "fixed" on
                                                         next run after remediation)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|--------------------|-------|
| Can't create a Tenant Governance relationship with a known customer | An active Partner Center GDAP relationship already exists to that tenant | `Get-MgTenantRelationshipDelegatedAdminRelationship` filtered to the target tenant ID |
| Related tenants list stays empty after enabling discovery | Discovery is signal-based and needs prior B2B/app/billing interaction history; also takes time to populate | Confirm `isRelatedTenantsEnabled = true`; confirm actual interaction history exists |
| A tenant appears in Related Tenants that nobody recognizes | Working as designed — related ≠ owned; investigate billing/B2B/app signals before acting | FAQ decision tree: check shared billing first, then B2B/app signals |
| Relationship request never gets accepted | Request/invitation queue confusion, or requester lacks Tenant Governance Administrator/Global Administrator | Confirm counterparty is checking the correct queue (Requests vs. Invitations) and requester's role |
| Relationship Active, but governing-tenant admin has no actual access in governed tenant | Admin not an active member of the delegated security group, or PIM-eligible-but-not-activated | `policySnapshot.delegatedAdministrationRoleAssignments` + group membership + PIM activation state |
| Relationship suddenly gone / Terminated with no governing-tenant action taken | Governed tenant unilaterally terminated — always their right | Check relationship status history; contact governed-tenant admin, this is not a technical fault |
| Trying to set up a 3-tenant governance chain (A→B→C) | Multi-tier governance relationships are not supported by design | Redesign around a flat one-to-many or many-to-one model instead |
| New configuration monitor fails to create | Daily 800-resource-instance tenant quota exceeded, or the 200-per-baseline limit exceeded | Sum resource instances across existing monitors before adding a new one |
| Monitor shows no drift for a change made minutes ago | Fixed 6-hour run interval — not yet due | Check `monitoringResult` timestamp of the last run vs. now |
| Same resource shows conflicting drift status across two monitors | Two monitors define different desired states for the same resource/property — both evaluate independently | Consolidate to a single baseline defining one desired state per resource |
| Snapshot job succeeded last week but the JSON is gone | 7-day snapshot/job retention — expired and deleted | Re-run the snapshot job; download and archive promptly next time |
| New add-on tenant created but has no governance relationship | No default governance policy template was configured for secure tenant creation | Configure a default template under Tenant Governance > Secure tenant creation before the next tenant is created |

---
## Validation Steps

**1. Confirm Graph connection and role**
```powershell
Connect-MgGraph -Scopes "TenantGovernance-Relationship.Read.All"
Get-MgContext | Select-Object Scopes, TenantId
```
Expected: scope present; confirm you're connected to the intended (governing or governed) tenant.

**2. Confirm licensing and discovery state**
```powershell
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings"
```
Expected: a response with `isRelatedTenantsEnabled`. Cross-check the specific capability being tested against [Microsoft Entra licensing](https://learn.microsoft.com/en-us/entra/fundamentals/licensing#microsoft-entra-tenant-governance) — free/Basic/Premium gate different features, not an all-or-nothing switch.

**3. Enumerate governance relationships**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Select-Object id, status, governingTenantName, governedTenantName, creationDateTime
```
Expected: every relationship where the calling tenant is either governing or governed.

**4. Confirm no GDAP collision for a target tenant**
```powershell
Get-MgTenantRelationshipDelegatedAdminRelationship |
    Where-Object { $_.Customer.TenantId -eq "<targetTenantId>" } |
    Select-Object DisplayName, Status
```
Expected: no active GDAP relationship to a tenant you're trying to bring under Tenant Governance.

**5. Confirm delegated access is actually usable**
```powershell
$rel = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value |
    Where-Object id -eq "<relationshipId>"
$rel.policySnapshot.delegatedAdministrationRoleAssignments | ForEach-Object {
    Get-MgGroupMember -GroupId $_.group.id | Select-Object Id, AdditionalProperties
}
```
Expected: the admin in question is listed as a member.

**6. Confirm configuration monitor health (if configured)**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors").value |
    Select-Object id, displayName, state
```
Expected: monitors show a healthy `state`; drill into `configurationMonitoringResult` for the most recent run.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Licensing & Discovery
1. Confirm the specific capability in question (related tenants / governance relationships / configuration management / secure tenant creation) is covered by the tenant's licensing tier
2. Confirm `isRelatedTenantsEnabled` state before troubleshooting an empty related-tenants list as a "bug"
3. Remember this setting is one-way — don't enable it in a production tenant to "just test it"

### Phase 2 — Relationship Establishment
1. Confirm which side (governing vs. governed) initiated, and which queue (Invitations vs. Requests) the counterparty should check
2. Confirm the requesting admin's role (Tenant Governance Administrator / Global Administrator)
3. **Before creating a new relationship, always check for an existing Partner Center GDAP relationship to the same tenant** — this is the single highest-value early check given the platform's hard mutual exclusion

### Phase 3 — Delegated Access
1. Confirm relationship `status = Active`
2. Confirm the admin's group membership against `policySnapshot.delegatedAdministrationRoleAssignments`
3. If PIM for Groups fronts that group, confirm activation (not just eligibility) — and remember governed-tenant PIM policy has no bearing here

### Phase 4 — Configuration Management (if in use)
1. Confirm the Unified Tenant Configuration Management service principal has read permission on every resource type referenced in the baseline
2. Confirm quota headroom (200/baseline, 800/tenant/day) before assuming a creation failure is a platform bug
3. Confirm the 6-hour run cadence before treating "no drift detected yet" as a fault
4. If two monitors disagree on the same resource, consolidate baselines rather than troubleshooting further — this is documented expected behavior, not a bug

### Phase 5 — Lifecycle Events
1. For an unexpected termination, confirm it was governed-tenant-initiated (always allowed) before treating it as an incident
2. For secure tenant creation gaps, confirm a default governance policy template was configured *before* the tenant was created — it cannot be retroactively applied to a tenant created without one

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate an existing customer from Partner Center GDAP to Tenant Governance</summary>

Use when: consolidating multi-tenant customer management onto Tenant Governance and moving off GDAP for a specific customer.

```
Step 1: Inventory the existing GDAP relationship's role assignments
        (Get-MgTenantRelationshipDelegatedAdminRelationshipAccessAssignment)
        and map each Entra role to the equivalent role template needed in a
        Tenant Governance policy template. Confirm feature parity — GDAP's
        per-role, time-boxed granularity may not have a 1:1 Tenant Governance
        equivalent for every role in use.

Step 2: Build (or select an existing) governance policy template in the
        governing tenant reflecting that role set.

Step 3: Coordinate a cutover window with the customer/governed-tenant admin —
        terminate the Partner Center GDAP relationship first (this is a
        platform-enforced prerequisite, not optional staging).

Step 4: Immediately send the Tenant Governance invitation/request using the
        template from Step 2. Minimize the gap between GDAP termination and
        Tenant Governance activation to avoid an administrative-access gap.

Step 5: Once Active, validate delegated access end-to-end (Validation Step 5)
        before considering the migration complete. Do not decommission any
        parallel access method (e.g., break-glass B2B account) until this
        validation passes.
```

**Rollback:** Once GDAP is terminated, restoring it requires a fresh customer approval in Partner Center — this migration is not cleanly reversible mid-flight. Communicate this to the customer before starting the cutover window.

</details>

<details><summary>Playbook 2 — Stand up configuration drift monitoring for a governed tenant</summary>

Use when: a governance relationship is Active and delegated access is confirmed, and the goal is ongoing configuration compliance monitoring.

```
Step 1: Generate a snapshot of a KNOWN-GOOD reference tenant (ideally the
        governed tenant itself, at a point already confirmed compliant, or a
        template/gold-standard tenant) via the Snapshot API. Download the
        result promptly — 7-day retention.

Step 2: Edit the snapshot JSON into the desired baseline — remove
        environment-specific values that shouldn't be enforced identically
        everywhere (e.g., specific display names), keep the compliance-
        relevant properties (CA policy state, exclusion lists, etc.).

Step 3: Confirm the Unified Tenant Configuration Management service principal
        has read access to every resource type in the baseline (see
        Authentication setup requirements) BEFORE creating the monitor — a
        permission gap surfaces as evaluation failures, not a clear error.

Step 4: Create the monitor referencing the baseline. Confirm total resource
        instances (this baseline + any existing monitors) stays under the
        800/tenant/day ceiling.

Step 5: Wait at least one 6-hour cycle, then review the first
        monitoringResult and any configurationDrift objects. Tune the
        baseline for false positives (e.g., properties that legitimately
        vary and shouldn't have been included) before treating drift counts
        as a compliance signal to report upward.

Step 6: Reuse the same baseline file to stand up equivalent monitors in other
        governed tenants for consistent, comparable compliance reporting
        across the whole managed estate.
```

**Rollback:** Delete the monitor to stop evaluation; the baseline JSON file itself is just a local/stored artifact and can be re-used to recreate the monitor later.

</details>

<details><summary>Playbook 3 — Diagnose "relationship Active, but nothing works"</summary>

Use when: `governanceRelationship.status = Active` but the governing tenant's admin reports no usable access.

```
Step 1: Confirm the admin's identity and the group referenced in
        policySnapshot.delegatedAdministrationRoleAssignments — a common gap
        is the WRONG admin testing access (e.g., a colleague who isn't
        actually in the delegated group).

Step 2: Confirm active group membership (not just an invite sent, or a
        request pending elsewhere).

Step 3: If PIM for Groups fronts the group, confirm the admin has ACTIVATED
        (not merely eligible) membership, and that the activation was done
        in the GOVERNING tenant specifically.

Step 4: Confirm the role templates in the policy snapshot actually grant the
        permission the admin is attempting to use — a policy template scoped
        to (for example) Global Reader will never allow a write operation,
        regardless of how correctly everything else is wired.

Step 5: If all of the above check out and access still fails, confirm
        there isn't a competing, more restrictive Conditional Access policy
        in the GOVERNED tenant blocking the governing-tenant admin's sign-in
        pattern (e.g., a location or device-compliance requirement the
        governing admin's session doesn't satisfy) — this is a normal CA
        interaction, not a Tenant Governance-specific fault.
```

**Rollback:** N/A — diagnostic playbook only.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Microsoft Entra Tenant Governance diagnostic evidence for escalation
.NOTES     Requires Microsoft.Graph.Beta module and TenantGovernance-Relationship.Read.All scope.
           Run from the GOVERNING tenant unless investigating from the governed side.
#>

$outputPath = "C:\TenantGovernance_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# Tenant Governance settings (discovery enablement state)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings" |
    ConvertTo-Json -Depth 4 | Out-File "$outputPath\tenant_governance_settings.json"

# All governance relationships
$relationships = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value
$relationships | Select-Object id, status, governingTenantId, governingTenantName, governedTenantId, governedTenantName, creationDateTime |
    Export-Csv "$outputPath\governance_relationships.csv" -NoTypeInformation

# Full policy snapshot per relationship (role assignments, provisioned apps)
foreach ($rel in $relationships) {
    $rel.policySnapshot | ConvertTo-Json -Depth 6 | Out-File "$outputPath\policy_snapshot_$($rel.id).json"
}

# Existing Partner Center GDAP relationships (mutual-exclusion cross-check)
try {
    Get-MgTenantRelationshipDelegatedAdminRelationship |
        Select-Object Id, DisplayName, Status, Customer |
        Export-Csv "$outputPath\gdap_relationships.csv" -NoTypeInformation
} catch {
    Write-Host "Could not retrieve GDAP relationships (may not be a CSP partner tenant): $($_.Exception.Message)" -ForegroundColor Yellow
}

# Configuration monitors and recent results
try {
    $monitors = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors").value
    $monitors | Select-Object id, displayName, state | Export-Csv "$outputPath\configuration_monitors.csv" -NoTypeInformation
} catch {
    Write-Host "Could not retrieve configuration monitors: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Connect with the read scope needed for every check below
Connect-MgGraph -Scopes "TenantGovernance-Relationship.Read.All"

# Tenant Governance settings (discovery enablement state — one-way once true)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings"

# Enable related-tenant discovery (IRREVERSIBLE)
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/settings/enableRelatedTenants"

# List all governance relationships (governing or governed)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships").value

# Get one relationship's full policy snapshot
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/tenantGovernance/governanceRelationships/<id>"

# List existing Partner Center GDAP relationships (mutual-exclusion check)
Get-MgTenantRelationshipDelegatedAdminRelationship | Select DisplayName,Status,Customer

# List configuration monitors
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directory/configurationManagement/configurationMonitors").value

# Confirm PIM for Groups activation state for a delegated-access group
Get-MgIdentityGovernancePrivilegedAccessGroupAssignmentScheduleInstance -Filter "principalId eq '<adminObjectId>'"

# Confirm group membership backing a delegated administration role assignment
Get-MgGroupMember -GroupId "<securityGroupId>"
```

---
## 🎓 Learning Pointers

- **Tenant Governance and Partner Center GDAP are structurally exclusive, not competing options to mix-and-match**: this is the single highest-value fact for any MSP evaluating the feature — plan a deliberate cutover per customer, don't attempt to run both against the same tenant pair. Reference: [Tenant Governance FAQ — Governance relationships](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/faq)
- **"Related" is evidentiary, not administrative**: a related tenant is surfaced because of observed B2B/app/billing activity, not because you have any rights over it — resist the urge to treat every related tenant as an immediate governance target. Reference: [Related tenants](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/related-tenants)
- **Enabling discovery is permanent**: unlike almost every other Entra tenant-level toggle, `isRelatedTenantsEnabled` has no off-switch once enabled — treat it with the same change-control rigor as an irreversible schema migration, not a feature flag. Reference: [Enable tenant discovery](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/how-to-enable-tenant-discovery)
- **Configuration management here is a UI/relationship layer over the already-GA Microsoft Graph Tenant Configuration Management APIs** — understanding the underlying `configurationBaseline`/`configurationMonitor`/`configurationDrift`/`configurationSnapshotJob` resource model pays off even outside the Tenant Governance UI, since the same APIs are usable standalone within a single tenant. Reference: [Overview of Tenant Configuration Management](https://learn.microsoft.com/en-us/graph/unified-tenant-configuration-management-concept-overview)
- **The governed tenant always holds the trump card**: it can terminate a governance relationship unilaterally at any time, and the governing tenant has no override — build any dependency on a governance relationship (automation, compliance monitoring, reporting) with the assumption that access can end at the governed tenant's discretion, not yours.
- **PIM interacts with governance relationships in only one direction**: PIM for Groups can gate the governing-tenant admin's activation of delegated access, but PIM policy configured in the governed tenant has zero effect on that same admin — a subtlety worth explicitly calling out to any security team assuming governed-tenant PIM policy provides a compensating control here. Reference: [Tenant Governance FAQ — Governance relationships](https://learn.microsoft.com/en-us/entra/id-governance/tenant-governance/faq)
