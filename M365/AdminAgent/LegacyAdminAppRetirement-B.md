# Legacy "Admin" App Retirement (Teams/Outlook/Microsoft365.com) — Hotfix Runbook (Mode B: Ops)
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

Microsoft is retiring the standalone **Admin app** — a lightweight, "very small business" (VSB)-targeted app pinned inside Teams, Outlook, and Microsoft365.com that let an admin handle basic tasks (users, licenses, simple settings) without leaving those apps. This is announced via Message Center post **MC1462922**, rolling out mid-August 2026 and completing by mid-October 2026. **This is a retirement notice, not an outage** — nothing is currently broken; the job here is almost always proactive client communication, not firefighting.

```powershell
# 1. Confirm you're dealing with THIS app, not a Teams/Outlook/M365.com general outage —
#    check the client is otherwise functioning normally
Get-Date  # sanity-check timestamp against MC1462922's rollout window (mid-Aug – mid-Oct 2026)

# 2. Confirm tenant size/segment — this app targeted "very small business" tenants; larger
#    tenants with the full M365 admin center as their primary surface are less likely to
#    notice the change at all
(Get-MgOrganization).AdditionalProperties.assignedPlans.Count  # rough SKU-count sanity check, not authoritative

# 3. Check whether the Admin app is currently pinned/visible for this tenant's Teams users
Get-CsTeamsAppSetupPolicy -Identity Global | Select-Object Identity, PinnedAppBarApps

# 4. Search the Teams App Catalog for an app matching "Admin" to confirm what's actually
#    installed before assuming it's THIS specific first-party app (custom/LOB apps can share the name)
Get-CsTeamsApp -Filter "startswith(displayName,'Admin')" -ErrorAction SilentlyContinue |
    Select-Object Id, DisplayName, DistributionMethod

# 5. Confirm the admin has an alternative path already available (this should always be true —
#    Admin Center/Teams Admin Center access is not new)
Get-MgUserMemberOf -UserId "<upn>" | Where-Object { $_.AdditionalProperties.displayName -match "Administrator" }
```

| Result | Interpretation |
|---|---|
| Today's date is before mid-Aug 2026 | App still fully pinned/available for new VSB admins; retirement hasn't started |
| Today's date is Aug–Oct 2026 | Rollout window — app no longer pre-pinned for NEW VSB admins in Teams, but still usable if already installed |
| Today's date is after mid-Oct 2026 | App fully retired — no longer supported/available in Teams, Outlook, or Microsoft365.com, regardless of prior installation |
| Admin has no other admin-role visibility into M365/Teams admin center | Real access gap — this is the actual issue to fix, not the app retirement itself |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Very Small Business (VSB) tenant classification
    │
    └── Admin app pinned/installed in Teams (and/or surfaced in Outlook, Microsoft365.com)
            │
            ├── Aug 2026: no longer PRE-PINNED for new VSB admins (existing installs unaffected until Oct)
            │
            └── Oct 2026: app entirely unsupported/unavailable across all three surfaces,
                regardless of install state
                        │
                        └── Admin must fall back to one of:
                                ├── Microsoft 365 admin center (admin.microsoft.com) — full functionality superset
                                ├── Teams admin center (admin.teams.microsoft.com) — Teams-specific settings
                                └── Microsoft 365 Admin Agent (Copilot Chat / admin center Copilot button /
                                    SMB-scoped Teams surface) — see `AdminAgent-A.md`/`-B.md` in this same folder
                                    for the natural-language replacement path
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the ticket is actually about this retirement, not a bug.** Ask what the admin was trying to do when the app "disappeared" or "stopped working." If the app is simply gone from the Teams app bar with no error, and the date is in or after the MC1462922 rollout window, this is expected behavior, not a defect.
   - Expected: app icon absent from Teams left rail; no error dialog, no support ticket needed on Microsoft's side.
   - Unexpected/escalate: an active error message, a crash, or data loss — this is NOT a symptom of this retirement and needs its own investigation.

2. **Confirm the admin still has admin access at all.** The Admin app never granted privilege of its own — it surfaced tasks the admin's existing Entra role already permitted. Losing the app does not mean losing the role.
   ```powershell
   Get-MgUserMemberOf -UserId "<upn>" | Select-Object -ExpandProperty AdditionalProperties |
       Where-Object { $_.displayName -match "Administrator" }
   ```
   - Good: one or more admin roles listed — access is intact, only the *surface* changed.
   - Bad: no admin roles found — this is a separate, pre-existing access issue; do not conflate it with the app retirement.

3. **Point the admin to a replacement surface appropriate to what they were doing.**
   - Simple user/license/group tasks → Microsoft 365 admin center (`admin.microsoft.com`)
   - Teams-specific policy/settings tasks → Teams admin center (`admin.teams.microsoft.com`)
   - "I just want to ask in plain English and have it done for me" (the app's original value proposition) → Microsoft 365 Admin Agent, see `AdminAgent-A.md`/`-B.md` in this same folder — this is Microsoft's own documented recommended replacement in MC1462922

---
## Common Fix Paths

<details><summary>Fix 1 — Admin app icon disappeared from Teams for a new admin, no error shown</summary>

Expected behavior from mid-August 2026 onward for VSB tenants — the app is no longer pre-pinned for *new* admins. Confirm the date and tenant segment, then redirect:

```powershell
# No remediation needed. Verify the admin's role is intact, then point them to a replacement surface.
Get-MgUserMemberOf -UserId "<upn>" | Select-Object -ExpandProperty AdditionalProperties |
    Where-Object { $_.displayName -match "Administrator" }
```

Client-facing script: *"Microsoft is retiring that simplified admin app as of October 2026 (Message Center post MC1462922) — your admin access itself hasn't changed. I'll get you set up on the Microsoft 365 admin center [and/or the new Microsoft 365 Admin Agent, which is closer to what the app did]."*

</details>

<details><summary>Fix 2 — Admin app still installed but stopped working entirely (post-October 2026)</summary>

Expected — full retirement means the app is no longer supported or available regardless of install state. This is not fixable; do not spend time troubleshooting the app itself.

```powershell
# Optional cleanup: unpin/remove the now-dead app tile so it stops confusing admins
Get-CsTeamsAppSetupPolicy -Identity Global | Select-Object PinnedAppBarApps
# Remove the Admin app entry via Set-CsTeamsAppSetupPolicy if it's still listed (confirm exact
# app ID in-tenant first via Get-CsTeamsApp — Microsoft has not published a fixed GUID for this app)
```

</details>

<details><summary>Fix 3 — Admin wants the same "ask in plain English, get it done" experience the app provided</summary>

This is the actual intended replacement path, not a workaround. Set the admin up with the Microsoft 365 Admin Agent — see `AdminAgent-B.md` in this folder for its own triage/entry points, and confirm the admin's tenant is on Worldwide Standard Multi-Tenant cloud if they specifically want the Teams surface (SMB-scoped, ~300-user ceiling at GA).

</details>

<details><summary>Fix 4 — Client (esp. very small business owner-operators) confused or anxious about "losing" their admin tool</summary>

This is a communication task, not a technical one. Lead with what does NOT change (their admin role/permissions, their data, their ability to manage the tenant) before what does (which app they open to do it). Offer to do a short walkthrough of the Microsoft 365 admin center or set up the Admin Agent as their new primary surface.

</details>

<details><summary>Fix 5 — Custom/LOB Teams app also named "Admin" is being confused with this retirement</summary>

Confirm identity before assuming scope — the retirement is specific to Microsoft's own first-party VSB Admin app (`aka.ms/TeamsClientAdminApp`), not any tenant-custom app that happens to share the word "Admin" in its name.

```powershell
Get-CsTeamsApp -Filter "startswith(displayName,'Admin')" |
    Select-Object Id, DisplayName, DistributionMethod, ExternalId
# DistributionMethod = "store" and a Microsoft-owned ExternalId indicates the first-party app;
# "sideloaded"/"organization" indicates a tenant-custom app, unaffected by MC1462922
```

</details>

---
## Escalation Evidence

```
Ticket: Admin app retirement (MC1462922) — [confusion/access question/other]
Tenant segment: [VSB / SMB / larger — confirm from admin center org profile]
Date of report: <date>
Rollout phase observed: [pre-Aug-2026 / Aug-Oct-2026 rollout / post-Oct-2026 full retirement]
Admin's Entra role(s) confirmed intact: [Yes/No — paste Get-MgUserMemberOf output]
Replacement surface offered: [M365 admin center / Teams admin center / M365 Admin Agent]
Custom/LOB app name collision ruled out: [Yes/No]
Notes:
```

---
## 🎓 Learning Pointers

- This is a **Message Center-driven retirement**, not a bug report — always check the Microsoft 365 admin center's Message Center (or a service like this one) for a matching MC number before troubleshooting an app that "just disappeared." Search: `MC1462922`.
- The Admin app targeted **very small business (VSB)** tenants specifically — a tenant-size segmentation Microsoft uses for several simplified-experience rollouts; larger tenants were less likely to have had it as a primary surface at all.
- Microsoft's own documented replacement path explicitly includes the **Microsoft 365 Admin Agent** (see `AdminAgent-A.md`/`-B.md` in this same folder) alongside the traditional admin centers — this is a rare case where a retiring legacy tool and this repo's own AI-agent topic are directly, officially linked.
- No dedicated PowerShell/Graph cmdlet exists to query "is the Admin app installed" directly — it's a Teams-catalog app like any other, so `Get-CsTeamsApp`/Teams admin center is the closest available signal, not a purpose-built check.
- Reference: [Neowin — Microsoft is retiring the Admin app for Teams and Outlook](https://www.neowin.net/news/microsoft-is-retiring-the-admin-app-for-teams-and-outlook/), [M365 Admin — Admin app retiring in Teams, Outlook and Microsoft365.com (MC1462922)](https://m365admin.handsontek.net/admin-app-retiring-teams-outlook-microsoft365-com/)
