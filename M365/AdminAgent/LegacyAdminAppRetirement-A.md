# Legacy "Admin" App Retirement (Teams/Outlook/Microsoft365.com) — Reference Runbook (Mode A: Deep Dive)
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

This topic covers the retirement of Microsoft's first-party **Admin app** — a lightweight, "very small business" (VSB)-scoped application surfaced inside Microsoft Teams, Outlook, and Microsoft365.com that let an admin perform simplified tenant-management tasks without navigating to a dedicated admin portal. Announced via Message Center post **MC1462922** (originally posted 2026-08-28), rolling out mid-August 2026 through full retirement by mid-October 2026.

This is **not** a change to any underlying admin capability, RBAC model, or licensing — it is the removal of one specific, narrow-audience *surface* for accessing capabilities that remain fully available through the Microsoft 365 admin center, the Teams admin center, and (per Microsoft's own stated recommendation) the Microsoft 365 Admin Agent covered elsewhere in this folder. Assumes familiarity with basic Entra role assignment and the Teams App Catalog/policy model; does not assume prior familiarity with the Admin app itself, since it was a narrow-audience feature many MSP engineers will not have touched directly.

---
## How It Works

<details><summary>Full architecture</summary>

**What the app was.** The Admin app (`aka.ms/TeamsClientAdminApp`) was a first-party Teams-catalog application, pre-pinned by default for admins of tenants Microsoft classifies as "very small business" (VSB — a tenant-size segmentation Microsoft uses internally to tailor onboarding and default experiences, distinct from any customer-facing SKU or plan name). It surfaced a reduced set of common administrative tasks — user/license management, basic settings — directly inside Teams' left rail, and was also reachable from Outlook and the Microsoft365.com web launcher. It held no privilege of its own: like every admin surface in Microsoft 365, actions performed through it were gated by the signed-in user's existing Entra role assignments.

**Why it's retiring.** Microsoft's stated rationale (per MC1462922) is consolidation onto fewer, more capable admin surfaces — specifically the Microsoft 365 admin center and Teams admin center for traditional portal-based administration, and the Microsoft 365 Admin Agent (see `AdminAgent-A.md` in this same folder) as the natural-language successor to the app's original "simple tasks without leaving Teams" value proposition. This is a pattern also seen elsewhere in Microsoft 365's current product direction: narrow, single-purpose admin surfaces are being folded into either the full admin centers or the new agentic (Copilot-powered) admin experiences rather than maintained in parallel indefinitely.

**Two-stage rollout, not a single cutover date.** This is the detail most likely to cause confusion if missed:
- **Stage 1 (mid-August 2026):** the app stops being *pre-pinned/pre-installed* for admins newly classified as VSB. Existing installations for existing admins are unaffected at this stage — the app still functions if already present.
- **Stage 2 (mid-October 2026):** the app is fully retired — no longer supported or available in Teams, Outlook, or Microsoft365.com for ANY tenant or admin, regardless of prior install state. This is the date that actually removes functionality for admins who already had the app.

**No data or configuration loss.** Because the app performed no independent storage of its own — every action it took wrote through to the same underlying services (Entra ID, Exchange, Teams admin services) that the full admin centers also write to — there is no migration, export, or data-loss concern tied to this retirement. The only thing that changes is which UI the admin opens.

</details>

---
## Dependency Stack

```
Microsoft 365 tenant, classified as "very small business" (VSB) by Microsoft's internal segmentation
    │
    └── Admin app (Teams-catalog first-party app, aka.ms/TeamsClientAdminApp)
            │
            ├── Surfaced in: Microsoft Teams (left rail, pre-pinned by default pre-Aug-2026)
            ├── Surfaced in: Outlook (task-specific entry points)
            └── Surfaced in: Microsoft365.com (web launcher)
                    │
                    └── Every action gated by the signed-in admin's existing Entra role assignment
                        (the app is a UI convenience layer, not a separate privilege grant)
                                │
                                └── Writes through to the SAME backend services as the full admin
                                    centers (Entra ID, Exchange admin, Teams admin services) — no
                                    app-specific data store to migrate or lose
```

Post-retirement replacement paths (parallel, not sequential — an admin can use any/all):

```
Microsoft 365 admin center (admin.microsoft.com)  ─┐
Teams admin center (admin.teams.microsoft.com)      ├─→ Same underlying Entra-role-gated actions
Microsoft 365 Admin Agent (Copilot Chat / admin    ─┘   the Admin app used to surface
center Copilot button / SMB-scoped Teams surface)
    — see `AdminAgent-A.md`/`-B.md`, this same folder, for its own dependency stack
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Admin app icon missing from Teams for a newly-provisioned admin | Stage 1 rollout (mid-Aug 2026) — no longer pre-pinned for new VSB admins | Confirm date; confirm tenant is VSB-classified |
| Admin app was working, now shows unavailable/unsupported | Stage 2 full retirement (mid-Oct 2026) | Confirm date is on/after the Stage 2 window |
| Admin lost the ability to perform a task they used the app for | Almost never true — the underlying Entra role is unaffected | `Get-MgUserMemberOf`, confirm role assignment still present |
| A different, tenant-custom Teams app named "Admin" also disappeared or is being blamed | Name collision with the unrelated custom app, not this retirement | `Get-CsTeamsApp -Filter "startswith(displayName,'Admin')"`, check `DistributionMethod`/`ExternalId` |
| Admin wants an equivalent "quick, simple" experience post-retirement | Expected gap between the retired app and the full admin centers | Point to Microsoft 365 Admin Agent as the documented intended successor |

---
## Validation Steps

1. **Confirm rollout phase against today's date.**
   ```powershell
   Get-Date
   ```
   Good: date falls clearly into one of the three phases (pre-Aug-2026 / Aug-Oct-2026 / post-Oct-2026) — proceed with the matching guidance. Bad: ambiguous or disputed date — treat MC1462922's own text as authoritative over any third-party blog summary, and note that Microsoft's own rollout windows are typically communicated as approximate ("mid-August," "mid-October"), not exact calendar dates.

2. **Confirm the admin's Entra role assignment is unaffected.**
   ```powershell
   Get-MgUserMemberOf -UserId "<upn>" | Select-Object -ExpandProperty AdditionalProperties |
       Where-Object { $_.displayName -match "Administrator" }
   ```
   Good: one or more roles returned, unchanged from before the retirement. Bad: no roles returned — this is an unrelated access issue, do not attribute it to the app retirement.

3. **Confirm which app is actually being discussed, if there's any ambiguity.**
   ```powershell
   Get-CsTeamsApp -Filter "startswith(displayName,'Admin')" |
       Select-Object Id, DisplayName, DistributionMethod, ExternalId
   ```
   Good: a `store`-distributed, Microsoft-owned app matches — this is the retiring first-party app. Bad: only `sideloaded`/`organization`-distributed apps match — the retirement does not apply to what's being reported.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confusion/anxiety about the retirement (most common ticket type).** No technical fix required. Validate the admin's role is intact (Validation Step 2), explain the two-stage timeline in plain terms, and offer to walk through the replacement surface of their choice.

**Phase 2 — Admin app still functionally present but flagged for cleanup.** Between Stage 1 and Stage 2, the app may still be pinned for admins who had it before mid-August 2026. Optionally unpin it proactively via `Set-CsTeamsAppSetupPolicy` once the client has been walked through a replacement, rather than waiting for the Stage 2 hard cutover to surprise them.

**Phase 3 — Post-Stage-2 full retirement, app entirely gone.** Nothing to troubleshoot on the app itself — confirm the admin is set up on at least one replacement surface (Remediation Playbook 1 or 2) and close the ticket.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a VSB client from the Admin app to the Microsoft 365 admin center</summary>

1. Confirm the admin's current Entra role(s) via `Get-MgUserMemberOf` (unaffected by the app retirement, but worth confirming as a baseline).
2. Walk the admin to `admin.microsoft.com` and bookmark it (browser bookmark or Teams tab pin of the *web page*, not the retired app).
3. Map the 2-3 tasks the admin used the Admin app for most often (typically: add/remove a user, assign/remove a license, reset a password) to their equivalent admin center pages, and note them for the client.
4. If the admin also used Teams-specific settings via the app, separately bookmark `admin.teams.microsoft.com`.

No rollback needed — this playbook only adds a bookmark/habit change, it does not remove or reconfigure anything.

</details>

<details><summary>Playbook 2 — Set up the Microsoft 365 Admin Agent as the app's natural-language successor</summary>

This is Microsoft's own documented recommended path (MC1462922 explicitly names the Admin Agent alongside the two admin centers). See `AdminAgent-A.md`/`-B.md` in this same folder for full setup/triage detail. In short:

1. Confirm the admin has an Entra role — the Admin Agent mirrors existing role assignments and grants no new privilege (same trust model the retiring Admin app used).
2. Confirm the desired surface: Copilot Chat and the admin center's Copilot button work for any tenant; the Teams surface specifically is SMB-scoped (~300-user ceiling) and Worldwide Standard Multi-Tenant cloud only at GA — cross-check `AdminAgent-A.md`'s Dependency Stack before promising Teams-surface access to a client outside that scope.
3. Walk the admin through one or two example natural-language requests matching what they used the Admin app for, so the transition feels like a like-for-like replacement rather than a downgrade.

</details>

<details><summary>Playbook 3 — Fleet-wide MSP cleanup: unpin the retiring app proactively across managed VSB tenants</summary>

For MSPs managing multiple small-business tenants, proactively cleaning up the pinned app ahead of the Stage 2 hard cutover avoids a wave of simultaneous client tickets in October 2026.

1. For each managed VSB tenant, run the Command Cheat Sheet's `Get-CsTeamsAppSetupPolicy` check to confirm the app is currently pinned.
2. Communicate the change to each client BEFORE removing the pin (see Fix 4 in `LegacyAdminAppRetirement-B.md` for messaging guidance) — this is a client-facing change, not a silent backend cleanup.
3. Remove the pin via `Set-CsTeamsAppSetupPolicy` once the client has a replacement surface set up (Playbook 1 and/or 2).

No destructive rollback concern — unpinning an app does not delete any data, and the app can be re-pinned (until Stage 2 fully retires it) if needed.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects evidence for a Legacy Admin App retirement (MC1462922) ticket.
.DESCRIPTION Read-only. Confirms rollout phase, admin role intact, and current app pin state.
#>
$rolloutStageStart = Get-Date "2026-08-15"
$rolloutStageEnd   = Get-Date "2026-10-15"
$today = Get-Date

$phase = if ($today -lt $rolloutStageStart) { "Pre-rollout — app still fully pre-pinned" }
         elseif ($today -lt $rolloutStageEnd) { "Stage 1 — no longer pre-pinned for NEW VSB admins" }
         else { "Stage 2 — fully retired, unsupported in Teams/Outlook/Microsoft365.com" }

[PSCustomObject]@{
    EvidenceDate     = $today
    RolloutPhase     = $phase
    MessageCenterID  = "MC1462922"
} | Format-List

Get-CsTeamsApp -Filter "startswith(displayName,'Admin')" -ErrorAction SilentlyContinue |
    Select-Object Id, DisplayName, DistributionMethod, ExternalId | Format-Table -AutoSize
```

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Date` | Confirm which rollout phase (pre / Stage 1 / Stage 2) applies today |
| `Get-MgUserMemberOf -UserId "<upn>"` | Confirm the admin's Entra role assignment is unaffected |
| `Get-CsTeamsApp -Filter "startswith(displayName,'Admin')"` | Identify whether the app in question is the retiring first-party app vs. an unrelated custom app |
| `Get-CsTeamsAppSetupPolicy -Identity Global` | Check current pin/setup-policy state for the app |
| `Set-CsTeamsAppSetupPolicy` | Proactively unpin the retiring app once a replacement surface is set up |

---
## 🎓 Learning Pointers

- Treat every "an app/feature suddenly changed" ticket as a **Message Center search first** — `MC1462922` here — before assuming a bug or misconfiguration; Microsoft telegraphs the overwhelming majority of these changes 30-90 days ahead via the Message Center.
- "Very small business" (VSB) is a Microsoft-internal tenant segmentation used to tailor default onboarding/UI experiences — it is not a purchasable SKU name and won't appear on an invoice, but it does explain why some clients have features/apps others don't.
- This retirement is a useful teaching moment for the broader pattern in Microsoft 365 right now: narrow single-purpose admin surfaces (like this app) are increasingly being folded into either the full admin centers or agentic (Copilot-powered) experiences — see `AdminAgent-A.md` in this same folder for the specific successor Microsoft named.
- No PowerShell/Graph API ever existed to manage the Admin app as a distinct entity — it was governed entirely through standard Teams App Catalog/policy cmdlets (`Get`/`Set-CsTeamsAppSetupPolicy`), which is why this topic's Evidence Pack and Cheat Sheet lean on those rather than any app-specific module.
- References: [Neowin — Microsoft is retiring the Admin app for Teams and Outlook](https://www.neowin.net/news/microsoft-is-retiring-the-admin-app-for-teams-and-outlook/), [M365 Admin — Admin app retiring in Teams, Outlook and Microsoft365.com (MC1462922)](https://m365admin.handsontek.net/admin-app-retiring-teams-outlook-microsoft365-com/), [Microsoft 365 Admin Agent overview (Microsoft Learn)](https://learn.microsoft.com/en-gb/microsoft-365/copilot/copilot-ai-admin-agent)
