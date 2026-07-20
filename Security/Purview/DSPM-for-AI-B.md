# Microsoft Purview DSPM for AI — Hotfix Runbook (Mode B: Ops)
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

**Read this first if the client says "DSPM for AI":** as of 2026, Microsoft converged **DSPM for AI** and the general-purpose **DSPM** into a single, unified **Data Security Posture Management** solution built around "objectives" (Prevent data exposure in Copilot, Prevent oversharing, Prevent exfiltration, Discover sensitive data). The old standalone experiences now live on as **DSPM for AI (classic)** and **DSPM (classic)** — frozen, no new features, still fully functional. Half of "it doesn't look like the documentation/training I saw" tickets are simply someone landing in the classic portal instead of the unified one, or vice versa. Confirm which surface the client is actually looking at (**Purview portal → Solutions → DSPM** vs. **Solutions → DSPM for AI (classic)**) before doing anything else.

This is a **Purview-portal-first** solution — there is no `Get-DSPM*`/`Get-DataSecurityPosture*` cmdlet family, and the objectives dashboard, data risk assessments, and AI observability views are portal/API-only. Diagnosis here leans on the underlying Purview/Graph signals that feed DSPM (audit, licensing, DLP/IRM policies, sensitivity labels) rather than reading DSPM's own state directly.

```powershell
# 1. Confirm Purview Audit is on — the #1 silent blocker for Copilot/agent activity insights
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# 2. Confirm the caller/analyst has a DSPM-recognized role (Entra Compliance Administrator,
#    Entra Global Administrator, or Purview Compliance Administrator role group for full access;
#    Security Reader / Data Security Viewer / Entra AI Administrator / Purview Data Security AI
#    Viewer for view-only — note none of these alone unlock AI interaction CONTENT, see Fix 4)
Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '<userObjectId>'" |
    Select-Object RoleDefinitionId

# 3. Confirm Microsoft 365 Copilot licensing is actually assigned (no license = no Copilot/agent
#    activity to observe at all, regardless of DSPM configuration)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "Copilot" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# 4. Confirm the "DSPM for AI - *" default one-click policies exist and are enabled (a strong
#    signal onboarding was actually completed, not just visited)
Get-DlpCompliancePolicy | Where-Object { $_.Name -like "*DSPM for AI*" -or $_.Name -like "*Microsoft AI Hub*" } |
    Select-Object Name, Mode, Enabled

# 5. Confirm device onboarding + browser extension state if the complaint is about third-party
#    AI sites (ChatGPT/Gemini/etc. in a browser) specifically, not Microsoft 365 Copilot itself
# Purview portal → Settings → Device onboarding; Edge → managed policy for the Purview extension
```

| Command / observation result | Interpretation | Do this |
|---|---|---|
| Client references a feature/screen from documentation that doesn't match what they see | They're in the other version — classic vs. current — of the two coexisting experiences | Fix 1 |
| `UnifiedAuditLogIngestionEnabled` is `False` | No Copilot/agent activity insights possible at all until audit is turned on, then a backfill delay applies | Fix 2 |
| No `Copilot` SKU with consumed units | Nothing to observe — Copilot/agent activity requires an assigned Microsoft 365 Copilot license per user | Fix 3 |
| User can see reports/policies but "AI interaction" events show no prompt/response text | Missing the separate **Purview Data Security AI Content Viewer** (or Content Explorer Content Viewer) role — this is gated independently of general DSPM view access | Fix 4 |
| Default data risk assessment shows "no data yet" | First-run default assessment has a documented ~4-day delay before results populate; custom assessments need ~48 hours to stabilize | Fix 5 |
| Custom assessment with item-level scanning fails to authenticate | The one-time Entra app registration + Graph application permissions + admin consent prerequisite wasn't completed (or was completed with the wrong permission set) | Fix 6 |
| Fabric tab data risk assessment won't configure | Separate Entra app + Fabric admin-API service-principal tenant settings prerequisite, distinct from the Microsoft 365 item-level scanning app | Fix 7 |
| A "DSPM for AI" policy is missing prompts/responses even though a collection policy exists | Collection policies default to **not** capturing content — content capture is a separate, explicit setting on the policy | Fix 8 |
| Policy names show an odd **"Microsoft AI Hub -"** prefix instead of **"DSPM for AI -"** | Legacy naming from when this solution was in preview under its old name — cosmetic only, not a misconfiguration | Fix 9 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Purview tenant (Compliance Administrator / Global Administrator / Purview Compliance
Administrator role group for full DSPM access)
    │
    ├── Two coexisting solution surfaces (do not confuse them):
    │   ├── DSPM (current, unified)         → Purview portal → Solutions → DSPM
    │   │       ├── Objectives (guided workflows: exposure, oversharing, exfiltration, discovery)
    │   │       ├── AI observability (all AI apps/agents incl. Microsoft Agent 365)
    │   │       ├── Asset explorer (Agent tab + Standard tab)
    │   │       └── Data Security Investigations integration (proactive AI insights)
    │   ├── DSPM for AI (classic)           → Solutions → DSPM for AI (classic) — frozen, no new features
    │   └── DSPM (classic)                  → general-purpose predecessor — frozen, no new features
    │
    ▼
Prerequisites (gate what DSPM can actually observe/act on):
    ├── Microsoft Purview Audit enabled (default on for new tenants; REQUIRED for Copilot/agent
    │   activity insights — this is the #1 real-world blocker)
    ├── Microsoft 365 Copilot license assigned per user (no license = nothing to observe for that user)
    ├── Microsoft Purview browser extension + device onboarding (REQUIRED for third-party AI
    │   site visibility — ChatGPT, Gemini, etc. — and for Endpoint DLP on those sites)
    ├── Edge configuration policy (REQUIRED to activate Purview integration/DLP inside Edge itself)
    └── Pay-as-you-go billing configured (REQUIRED for AI apps other than Microsoft 365 Copilot/
        Microsoft Facilitator — e.g., Copilot in Fabric, Security Copilot, Entra-registered AI apps)
    │
    ▼
Default one-click policies (created on first use, editable only from their OWNING solution area,
never inside DSPM itself):
    ├── DLP policies              → owned by Data Loss Prevention
    ├── Insider Risk policies      → owned by Insider Risk Management (often triggers Adaptive
    │                                Protection turn-on as a side effect — see AdaptiveProtection-A.md)
    ├── Communication Compliance   → owned by Communication Compliance
    └── Collection policies        → owned by the Collection policies solution (content capture is
                                     an explicit opt-in per policy, off by default)
    │
    ▼
Data risk assessments (oversharing detection):
    ├── Default assessment  → auto-runs weekly, top 100 SharePoint sites by usage, ~4-day first-run delay
    ├── Custom assessment    → Microsoft 365 tab (SharePoint/OneDrive) or Fabric tab
    │   ├── Basic scan level  → no extra auth required
    │   └── Item-level scan   → REQUIRES a dedicated Entra app registration (Application.Read.All,
    │       Directory.Read.All, Files.ReadWrite.All, SensitivityLabels.Read.All, Sites.ReadWrite.All,
    │       User.Read.All + admin consent) — OneDrive NOT supported, max 10 sites, 200,000 item cap
    └── Fabric assessment   → REQUIRES a SEPARATE Entra app (federated credential or client secret)
        registered as a Fabric admin-API service principal, enabled via Fabric admin portal tenant
        settings — this is a different prerequisite chain from the M365 item-level one above
    │
    ▼
Role-gated visibility (the single most missed layer — see Escalation Evidence):
    View posture/objectives/reports  → any DSPM view-only role
    View AI interaction prompts/responses → SEPARATE role: Purview Data Security AI Content Viewer
                                             (or Content Explorer Content Viewer) — NOT implied by
                                             general DSPM view access, even for Compliance Administrator
    Security Copilot prompts in DSPM  → requires Data Security Viewer role specifically
```

</details>

---
## Diagnosis & Validation Flow

1. **Establish which of the two experiences the client is actually describing.**
   - Ask them to confirm the exact portal path: **Solutions → DSPM** (current/unified) vs. **Solutions → DSPM for AI (classic)** vs. **Solutions → DSPM (classic)**.
   - Good: matches what you're about to troubleshoot.
   - Bad: a mismatch — most "the feature I read about isn't there" tickets are this, not a real fault. Go to Fix 1.

2. **Confirm Audit is on before troubleshooting any missing Copilot/agent activity.**
   ```powershell
   Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
   ```
   - Good: `True`.
   - Bad: `False` → nothing downstream can work; this is always Fix 2 first, regardless of the original complaint.

3. **Confirm licensing for the specific AI surface in question** — Microsoft 365 Copilot license for Copilot/agent activity; pay-as-you-go billing for everything else (Fabric, Security Copilot, Entra-registered AI apps, ChatGPT Enterprise).
   - Good: appropriate license/billing model confirmed active.
   - Bad: missing → Fix 3.

4. **If the complaint is "I can see the report but not the actual prompt/response text," check the AI Content Viewer role specifically — not general DSPM access.**
   - Good: user holds Purview Data Security AI Content Viewer (or Content Explorer Content Viewer).
   - Bad: they don't, even if they're a Compliance Administrator → Fix 4. This is the most commonly missed permission in this entire topic.

5. **If a data risk assessment shows no/stale results, check elapsed time against the documented delays before assuming a fault.**
   - Default assessment: ~4 days on first creation, weekly refresh thereafter.
   - Custom assessment: ~48 hours to stabilize, 30-day expiration (duplicate to re-run).
   - Good: within the expected window.
   - Bad: well past it → Fix 5, then escalate as a genuine platform issue.

6. **If item-level scanning or Fabric assessments fail, verify the CORRECT Entra app prerequisite was completed** — these are two independent app registrations with different permission sets and different admin roles required to create them (Cloud/Application Administrator or Privileged Role Administrator for both, plus Fabric Administrator for the Fabric tenant-setting step).
   - Good: the app registration matching the specific assessment type (M365 vs. Fabric) exists with the right permissions and admin consent granted.
   - Bad: wrong app used, permissions incomplete, or consent not granted → Fix 6 or Fix 7.

---
## Common Fix Paths

<details><summary>Fix 1 — Client is in the wrong DSPM experience (classic vs. current)</summary>

**When to use:** Client describes a feature, screen, or workflow that doesn't match what they're looking at.

1. Confirm exact navigation: **Purview portal → Solutions → DSPM** (current, unified — where all new features land) vs. **Solutions → DSPM for AI (classic)** / **DSPM (classic)** (frozen, function identically to how they always have, receive no new capability).
2. If they need current-generation features (Objectives, AI observability with Agent 365, Asset explorer, Data Security Investigations integration), they must use the current **DSPM** solution — there is no migration switch, both simply coexist.
3. If they're specifically trying to re-locate a task they used to do in one of the classic versions, use the direct mapping rather than guessing: [Find familiar tasks that you did in DSPM for AI or in DSPM](https://learn.microsoft.com/en-us/purview/dspm-task-mapping).

**Rollback:** N/A — navigation/education fix, no configuration changed.

</details>

<details><summary>Fix 2 — Purview Audit is disabled</summary>

**When to use:** `UnifiedAuditLogIngestionEnabled` returns `False`, blocking all Copilot/agent activity insight.

```powershell
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```

1. Enable auditing per the command above (requires appropriate Exchange Online/compliance role).
2. Set client expectations on backfill — auditing only captures activity going forward from when it's enabled; there is no retroactive backfill of prior Copilot interactions.
3. Re-check DSPM reports after the normal audit ingestion delay (allow at least a day) before concluding the fix didn't work.

**Rollback:** `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $false` — rarely appropriate; disabling audit removes visibility across many other Purview features simultaneously, not just DSPM.

</details>

<details><summary>Fix 3 — Missing Copilot license or pay-as-you-go billing</summary>

**When to use:** A specific user or AI app shows no activity at all in DSPM.

1. For Microsoft 365 Copilot/agents: confirm and assign the license via the M365 admin center or `Update-MgUserLicense`.
2. For Copilot in Fabric, Security Copilot, Entra-registered AI apps, ChatGPT Enterprise, and other non-Copilot AI apps: confirm pay-as-you-go billing is configured for the tenant — DSPM surfaces in-UI notifications when this billing model applies but hasn't been set up.
3. Re-check after allowing normal propagation time (licensing changes are near-immediate; first activity capture can take longer).

**Rollback:** Remove license/billing config if assigned in error — no DSPM-specific rollback needed.

</details>

<details><summary>Fix 4 — User can't see AI interaction prompt/response content</summary>

**When to use:** User has legitimate DSPM access (even Compliance Administrator) but "AI interaction" events in Activity explorer show no prompt/response text, or the flyout pane is empty/redacted.

1. This is a **deliberately separate** permission from general DSPM access — assign one of:
   - **Purview Data Security AI Content Viewer** role, or
   - **Content Explorer Content Viewer** role
2. Do not assume Global Administrator, Compliance Administrator, or even Data Security Viewer implies this — per Microsoft's own permissions matrix, none of them do.
3. Confirm the underlying collection/DLP policy actually has **content capture** enabled (see Fix 8) — the role alone doesn't produce content that was never captured.

**Rollback:** Remove the role via Purview role assignment if granted in error — this role can expose sensitive prompt/response content broadly, so scope it carefully.

</details>

<details><summary>Fix 5 — Data risk assessment shows no/stale results</summary>

**When to use:** Default or custom data risk assessment appears empty or unchanged.

1. Confirm elapsed time: default assessment ≈ 4 days on first creation then weekly; custom assessment ≈ 48 hours to stabilize.
2. For a custom assessment past its 30-day expiration showing stale data, use **Duplicate** to create a fresh assessment with the same scope — there is no in-place "refresh now" action.
3. If well past the documented window with zero results and the scope (users/sites) is confirmed non-empty, escalate as a genuine platform issue rather than re-running repeatedly.

**Rollback:** N/A — assessments are read-only reporting constructs; deleting/duplicating has no destructive side effect on the underlying data.

</details>

<details><summary>Fix 6 — Microsoft 365 item-level scanning authentication fails</summary>

**When to use:** Custom data risk assessment with item-level scan level fails at the Authenticate step.

1. Confirm a dedicated Entra app registration exists (**not** reused from an unrelated integration) with **Application permissions**: `Application.Read.All`, `Directory.Read.All`, `Files.ReadWrite.All`, `SensitivityLabels.Read.All`, `Sites.ReadWrite.All`, `User.Read.All`.
2. Confirm admin consent was actually granted for the tenant — a created-but-unconsented app registration will authenticate the app identity but fail at the permission-check stage.
3. Re-enter the Application (client) ID and client secret in the assessment's Authenticate step; client secrets are shown once at creation — if lost, generate a new one rather than trying to recover the old value.
4. Remember the hard scope limits regardless of a successful auth: OneDrive is not supported for item-level scanning, and there's a current cap of 10 SharePoint sites per item-level assessment.

**Rollback:** Remove the app registration's Graph permissions or delete the app entirely via Entra ID → App registrations if no longer needed.

</details>

<details><summary>Fix 7 — Fabric data risk assessment won't configure</summary>

**When to use:** The Fabric tab of data risk assessments fails to accept configuration ("Set config" step).

1. Confirm this uses a **separate** Entra app registration from the Microsoft 365 item-level scanning app (Fix 6) — the two are not interchangeable and have different permission requirements.
2. Confirm the app was added as a member of a security group, and that a **Fabric Administrator** (not just a Purview/Compliance role) enabled both **Service principals can access read-only admin APIs** and **Service principals can access admin APIs used for updates** in the Fabric admin portal, scoped to that specific security group.
3. Prefer federated credentials over a client secret where the client's environment supports it — Microsoft's own guidance calls this the more secure option.

**Rollback:** Remove the security group's admin-API access in the Fabric admin portal, or delete the app registration, if configured in error.

</details>

<details><summary>Fix 8 — Prompts/responses missing from an otherwise-working collection policy</summary>

**When to use:** A "DSPM for AI - Capture interactions..." collection policy exists and shows activity, but Activity explorer never shows prompt/response text for those events.

1. Open the collection policy in its owning solution area (not inside DSPM) and check whether **content capture** is enabled — several default one-click policies (notably the network/SASE-based one) are created with content capture **off** by default, detection-only.
2. Enable content capture explicitly if the business requirement calls for reviewing actual prompt/response text (weigh this against privacy/compliance expectations before enabling broadly).
3. Re-confirm the requester also holds the AI Content Viewer role from Fix 4 — content capture being on and the viewer role being present are two independent requirements, both must be true.

**Rollback:** Disable content capture on the policy if enabled in error — existing already-captured content is not automatically purged by disabling capture going forward.

</details>

<details><summary>Fix 9 — Policy names show a "Microsoft AI Hub -" prefix</summary>

**When to use:** Some default policies show **Microsoft AI Hub -** instead of the expected **DSPM for AI -** prefix.

1. Confirm with the client whether this tenant had DSPM for AI enabled during its public preview period — Microsoft explicitly does not rename policies created back then, they permanently retain the old preview-era prefix.
2. Treat this as cosmetic only — functionally identical to a policy created with the current prefix. Do not attempt to rename or recreate the policy to "fix" the prefix; this risks losing policy history/tuning for no functional benefit.

**Rollback:** N/A — no action required.

</details>

---
## Escalation Evidence

```
=== DSPM for AI Escalation ===
Ticket #:
Client / Tenant:
DSPM surface confirmed:                    [ ] Current/Unified DSPM  [ ] DSPM for AI (classic)  [ ] DSPM (classic)
Audit enabled (Y/N):
Copilot license / PAYG billing confirmed (Y/N):
Requesting user's DSPM role:
AI Content Viewer role held (Y/N, if content-visibility issue):
Affected objective / assessment / policy name:
Assessment type:                           [ ] Default M365  [ ] Custom M365 item-level  [ ] Fabric
Entra app registration confirmed (Y/N, if item-level/Fabric):
When did the issue start:
What changed (client-reported):
Escalation target:                         [ ] Microsoft Support   [ ] Internal L3   [ ] Underlying-policy owner
```

---
## 🎓 Learning Pointers

- **DSPM for AI and general-purpose DSPM converged into one solution in 2026 — but the old ones didn't disappear.** Classic versions remain fully functional and frozen; all new capability lands only in the current, unified DSPM. Confirm which surface a client is describing before troubleshooting — this single mix-up explains a large share of "the docs don't match what I see" tickets. See [Learn about Data Security Posture Management](https://learn.microsoft.com/en-us/purview/data-security-posture-management-learn-about).

- **Viewing prompts and responses is gated by a role that general DSPM access does not imply.** Even a Compliance Administrator needs the separate Purview Data Security AI Content Viewer (or Content Explorer Content Viewer) role to see actual AI interaction content — plan for this explicitly in any client access request rather than assuming broader admin roles cover it. See [Permissions for Data Security Posture Management](https://learn.microsoft.com/en-us/purview/data-security-posture-management-permissions).

- **Data risk assessments have real, documented lag — don't chase a "bug" that's actually a timing window.** Default assessments take ~4 days on first run; custom assessments need ~48 hours to stabilize and expire after 30 days. See [Prevent oversharing with data risk assessments](https://learn.microsoft.com/en-us/purview/data-security-posture-management-oversharing).

- **Item-level scanning and Fabric assessments each need their OWN dedicated Entra app registration** with different Graph/Fabric permission sets — reusing one app for both, or assuming one covers the other, is a common and completely avoidable setup failure. See [Considerations for deploying DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai-considerations#prerequisites-for-fabric-data-risk-assessments).

- **Content capture on collection policies is opt-in and off by default on several one-click policies.** A policy showing detection activity with zero visible prompt/response text is very likely working as designed, not broken — check the policy's content-capture setting before escalating. See [Collection policies overview](https://learn.microsoft.com/en-us/purview/collection-policies-solution-overview#content-capture-for-ai-interactions).

- **Generative AI amplifies oversharing risk specifically because it's fast and proactive about surfacing content** that a human would have had to manually search for — obsolete, over-permissioned, or ungoverned SharePoint/OneDrive content becomes a live risk the moment Copilot can summarize it. Data risk assessments exist specifically to get ahead of this before a Copilot rollout, not just audit after the fact. See [Prevent oversharing with data risk assessments](https://learn.microsoft.com/en-us/purview/data-security-posture-management-oversharing).
