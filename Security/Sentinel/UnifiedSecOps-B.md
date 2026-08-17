# Unified Security Operations Platform (Sentinel + Defender XDR) — Hotfix Runbook (Mode B: Ops)
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

This runbook is for the "connect Sentinel to the Defender portal" onboarding itself and the breakage that follows it — not for ordinary Sentinel data-connector or analytics-rule issues once already onboarded (those live in `DataConnectors-B.md` / `AnalyticsRules-B.md`). Typical tickets: onboarding fails with a permission error despite being an Owner, analytics rules that used to fire on Defender for Endpoint/Office/Identity alerts go quiet after onboarding, an MSSP can't see a client's Sentinel data through a Lighthouse-delegated session, or someone needs to know whether they're even required to do this yet.

```
1. Confirm current onboarding state
   Defender portal (security.microsoft.com) → System → Settings → Microsoft Sentinel → Workspaces
   → shows Connected/primary/secondary status, or "Connect a workspace" if not yet onboarded

2. Confirm the Owner role assignment is UNCONDITIONAL at subscription scope (the #1 silent
   onboarding blocker) — in the Azure portal:
   Subscription → Access control (IAM) → Role assignments → filter Owner → check Condition column

3. Check for lingering standalone data connectors that should have auto-disconnected on
   primary-workspace onboarding (MDE, MDA, MDI, Defender for Office 365, Entra ID Protection)
   Sentinel (Azure portal) → Data connectors → search each product name → Status column

4. Confirm which workspace is PRIMARY (only one per tenant gets Defender XDR data/correlation)
   Defender portal → System → Settings → Microsoft Sentinel → Workspaces → Primary column
```

| Result | Interpretation |
|---|---|
| Onboarding fails with a permission/access error despite Owner role held | Owner assignment is **conditional** (ABAC-scoped) — onboarding requires an **unconditional** Owner assignment at subscription scope. Conditional access-control assignments silently fail this check. |
| Analytics rules relying on MDE/MDA/MDI/Defender for Office 365/Entra ID Protection data go quiet post-onboarding | Expected — those standalone connectors auto-disconnect on primary onboarding to avoid duplicate tenant-based alerts; rules need to be re-pointed at the unified pipeline's tables/incidents, not the old standalone connector tables. |
| MSSP/Lighthouse-delegated session can't see Sentinel data in the Defender portal | Expected, not a bug — GDAP/Azure Lighthouse is **not supported** for Sentinel data in the Defender portal. Use Microsoft Entra B2B guest access instead. |
| A secondary workspace shows Sentinel data but no Defender XDR incidents/alerts | Expected — Defender XDR incidents/alerts sync **only** to the primary workspace. |
| "Our tenant is blocked by a stale Unified Security Operations Platform / Defender XDR backend workspace association" error | A known platform-state edge case reported via Microsoft Q&A — not self-service resolvable; escalate to Microsoft support with tenant ID. |
| Everything looks correctly connected, still confused about behavior differences vs. the Azure portal | Expected — this is architectural, not a fault; see Dependency Cascade below and the Learning Pointers for what changes and what doesn't. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra tenant (single tenant per Defender portal connection — no cross-tenant
  Lighthouse/GDAP support for this specific integration)
  └── Log Analytics workspace with Microsoft Sentinel enabled exists
        └── Onboarding role held: Security Administrator (Entra ID) AND
            (Owner — UNCONDITIONAL at subscription scope — OR User Access
            Administrator + Microsoft Sentinel Contributor)
              └── Workspace connected via Defender portal: System > Settings >
                  Microsoft Sentinel > Connect a workspace
                    └── ONE workspace designated PRIMARY (only one per tenant) —
                        any additional connected workspaces become SECONDARY
                          ├── PRIMARY: gets Defender XDR alert/incident correlation,
                          │     unified incident queue, shared advanced hunting with
                          │     Defender XDR tables, bi-directional Azure<->Defender sync
                          └── SECONDARY: Sentinel-only in the Defender portal — no
                                Defender XDR incidents/alerts sync, continues to
                                function autonomously for its own tenant/subsidiary
                                  └── Standalone data connectors auto-disconnected on
                                      PRIMARY onboarding (MDE, MDA, MDI, Defender for
                                      O365, Entra ID Protection) — becomes tenant-based
                                      alerting instead, to avoid duplicate ingestion
                                        └── Dependent analytics rules/automation built
                                            on the OLD standalone connector's raw
                                            tables may go silent until re-pointed
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm onboarding status and which workspace is primary.**
   Defender portal → **System → Settings → Microsoft Sentinel → Workspaces**.
   Expected: exactly one workspace marked Primary; any others (if present) marked Secondary.

2. **If onboarding itself is failing, verify the Owner role assignment condition.**
   Azure portal → target subscription → **Access control (IAM) → Role assignments** → filter to Owner → inspect the **Condition** column for the account attempting onboarding. Expected: "None" (unconditional). A populated condition (ABAC constraint) blocks onboarding even though the role name shows as "Owner."

3. **If detections/automations went quiet after onboarding, check for a standalone connector that should have auto-disconnected but is showing stale data instead of a clean disconnect state.**
   Sentinel (Azure portal, on the **primary** workspace) → **Data connectors** → search MDE/MDA/MDI/Defender for Office 365/Entra ID Protection → confirm each shows the auto-disconnected/tenant-based state, not an orphaned partial connection.

4. **If an MSSP delegated-access session can't see Sentinel data**, confirm the access model in use — GDAP/Lighthouse is explicitly unsupported for Sentinel-in-Defender-portal data; the session needs Entra ID B2B guest access with the appropriate role (Sentinel Reader/Contributor or Security Administrator, per task) instead.

---
## Common Fix Paths

<details><summary>Fix 1 — Onboarding fails despite holding the Owner role</summary>

1. Confirm the Owner assignment is conditional (Diagnosis Step 2).
2. Either remove the condition (if appropriate for this account/scope) or have someone with an unconditional Owner (or User Access Administrator + Microsoft Sentinel Contributor combination) perform the onboarding instead.
3. Retry: **Defender portal → System → Settings → Microsoft Sentinel → Connect a workspace**.

No rollback needed — this is a pure permissions gate, not a destructive action.

</details>

<details><summary>Fix 2 — Analytics rules/automations went silent after onboarding</summary>

1. Identify which standalone connector the affected rule depended on (MDE, MDA, MDI, Defender for Office 365, Entra ID Protection) — these are the five specifically called out as auto-disconnected on primary onboarding.
2. Re-point the rule's query at the unified Defender XDR-sourced tables/incident data now flowing through the primary workspace, rather than the old standalone-connector ingestion path.
3. For Microsoft Defender for Cloud specifically: confirm you're using the **Tenant-based (Preview)** connector on the primary workspace, not the legacy **Subscription-based (Legacy)** connector — the legacy connector must be disconnected from every workspace in the tenant to avoid duplicate/conflicting alert delivery.
4. For Microsoft Purview Insider Risk Management: this must be configured **before** onboarding (or explicitly opted out) — install the Microsoft Purview Insider Risk Management solution from Content hub on the primary workspace and configure its connector; if the direct M365 Insider Risk Management connector is still active on any *secondary* workspace, disconnect it before proceeding.

</details>

<details><summary>Fix 3 — MSSP/Lighthouse-delegated session can't see Sentinel data in the Defender portal</summary>

This is a documented, permanent platform gap, not a misconfiguration to keep chasing (same class of limitation as the Lighthouse/Watchlist cross-workspace gap already documented in `Watchlists-A.md`).

1. Stop troubleshooting Lighthouse/GDAP permissions for this specific scenario — it is unsupported by design for Sentinel data in the Defender portal.
2. Set up **Microsoft Entra B2B** guest access for the delegated analyst instead, scoped with the appropriate Sentinel/Security role in the client tenant.
3. Continue using Lighthouse/GDAP for anything that remains Azure-portal-native (e.g., non-Sentinel Azure resource management) — the gap is specific to this integration, not Lighthouse generally.

</details>

<details><summary>Fix 4 — Changing which workspace is primary</summary>

1. **Defender portal → System → Settings → Microsoft Sentinel → Workspaces** → select the workspace to promote → **Set as primary** → review the listed product changes → **Confirm and proceed**.
2. Understand the immediate effect: the Defender XDR connector **automatically disconnects from the former primary and connects to the new one** — any analytics rules/automation on the former primary that depended on Defender XDR-correlated data go stale the moment this switch completes.
3. Plan the switch as a change window, not a casual toggle — notify anyone relying on the outgoing primary's unified incident queue.

</details>

---
## Escalation Evidence

```
=== Unified SecOps Onboarding Escalation Packet ===
Tenant ID:                         <tenant>
Primary workspace:                 <workspace name/ID>
Secondary workspace(s):            <list, or none>
Onboarding date:                   <date, or "auto-onboarded post-Jul 1 2025" if applicable>
Owner role condition (if failing): <unconditional / conditional — details>
Standalone connectors status:      <MDE/MDA/MDI/O365/EntraIDProtection — connected/auto-disconnected/orphaned>
Defender for Cloud connector type: <Tenant-based (Preview) / Subscription-based (Legacy) / both — flag if both>
Insider Risk Management status:    <configured pre-onboarding / opted out / not yet addressed>
Affected rules/automations:        <list, last-fired timestamp before/after onboarding>
MSSP access model in use:          <Lighthouse/GDAP (unsupported for this) / Entra B2B (supported)>
Requested action:                  <permission grant / rule re-pointing / primary-workspace change / MS support ticket>
```

---
## 🎓 Learning Pointers

- Onboarding requires an **unconditional** Owner role assignment at subscription scope — a conditional (ABAC) Owner assignment looks correct in the role list but silently fails onboarding. See [Connect Microsoft Sentinel to the Microsoft Defender portal — Microsoft Learn](https://learn.microsoft.com/en-us/unified-secops/microsoft-sentinel-onboard) (updated 2026-08-07).
- Customers onboarding to Microsoft Sentinel **after July 1, 2025** are automatically onboarded to the Defender portal — if a client insists they "never set this up," check the tenant's Sentinel creation date before assuming a config error.
- Only **one primary workspace per tenant** gets Defender XDR incident/alert correlation; any number of secondary workspaces can be connected but remain Sentinel-only in the Defender portal. See [Multiple Microsoft Sentinel workspaces in the Defender portal — Microsoft Learn](https://learn.microsoft.com/en-us/azure/sentinel/workspaces-defender-portal) (updated 2026-06-01).
- Five standalone data connectors auto-disconnect on primary onboarding to prevent duplicate ingestion: Defender for Office 365, Entra ID Protection, Defender for Cloud Apps, Defender for Endpoint, Defender for Identity. Any analytics rule or automation still pointed at their old standalone tables needs re-pointing, not re-connecting.
- GDAP with Azure Lighthouse is explicitly **not supported** for Sentinel data in the Defender portal — use Entra ID B2B instead for MSSP delegated access to this specific data. This is a real, current gap MSPs need to plan around, not a temporary bug.
- Microsoft Sentinel in the Azure portal is scheduled for retirement **March 31, 2027** — this is the forcing function behind the push to the unified Defender portal experience; frame client conversations about this migration as "when," not "if."
