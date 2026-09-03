# Next-Gen Sharing / Hero Link (SharePoint & OneDrive) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate a hero-link sharing ticket in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> **Source note:** This is the "third-generation" Microsoft 365 sharing experience (Message Center **MC1454378**, rolling out worldwide late August through late October 2026). As of this writing there is no dedicated Microsoft Learn conceptual article yet — the detail below is sourced from the Message Center post text itself (via the M365 Admin community mirror) rather than a mature Learn page. Re-confirm specifics against the live Message Center post or Learn before treating anything here as permanently fixed, especially the "no tenant-wide setting" and "expiration policies don't govern hero links" points.

Run these first — results tell you which fix path to follow:

```powershell
# 1. Has this tenant/site actually received the hero-link rollout yet?
#    No PowerShell flag exists for "has this tile rolled out" — the fastest check is
#    opening the Share dialog on any file: a single primary link at the top with a
#    "Tutorial" callout on first use = hero link is live. Multiple stacked link options
#    with no single primary link = legacy sharing dialog, not yet rolled out.

# 2. What is this site/OneDrive's configured default hero-link audience?
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> |
    Select-Object Url, DefaultMainLinkScope, DefaultSharingLinkType, SharingCapability

# 3. Confirm the tenant-wide sharing capability isn't the actual blocker (unrelated but
#    frequently conflated with hero-link audience)
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, DefaultLinkPermission

# 4. For OneDrive personal sites, same property applies per-user site
Get-SPOSite -Filter {Url -like "*-my.sharepoint.com/personal*"} -IncludePersonalSite $true |
    Where-Object {$_.Owner -eq "<UPN>"} | Select-Object Url, DefaultMainLinkScope
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Recipient says a shared link "does nothing" / prompts for access request | Expected — `DefaultMainLinkScope` is `OnlyPeopleAdded` by default; the hero link itself grants no access until the sender adds the person or broadens the audience — Fix 1 |
| User expected a brand-new link but got the same URL as last time | Expected — changing the hero link's audience **updates the existing link**, it does not mint a new one, by design — Fix 2 |
| A tenant-wide link-expiration policy isn't affecting some shared files | Expected if those files were shared via hero link — expiration policies documented as applying to **legacy links only**, not hero links, as of this writing — Fix 3 |
| Recipient has access via a link but you can't find which link they used | Check "Other links" in the sharing dialog — legacy links from before rollout (or created via API/PowerShell) still exist alongside the hero link — Fix 4 |
| Org wants a different default audience for new sites | Set `DefaultMainLinkScope` per site/OneDrive — no tenant-wide switch exists yet — Fix 5 |
| Users in the same org see inconsistent sharing dialogs (some old, some new) | Expected mid-rollout — GA rollout spans late Aug–late Oct 2026, staged per-tenant, not simultaneous — Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant has received the MC1454378 rollout (staged, late Aug–late Oct 2026 — no
admin toggle to accelerate or defer it)
        │
File/folder has a hero link (every item gets exactly one primary link once rolled out)
        │
Hero link audience setting — governed per SITE COLLECTION or per-OneDrive by
DefaultMainLinkScope (OnlyPeopleAdded [default] | Organization)
   NOT governed by tenant-wide DefaultSharingLinkType/link-expiration settings
   — those continue to apply only to legacy (non-hero) links
        │
User broadens or narrows the hero link audience in the Share dialog
   (Only people added → Organization → Anyone, where org policy permits)
        │
Changing audience UPDATES the existing hero link in place
   (same URL persists — this is the core behavioral change vs. legacy "new
   link per audience choice" model)
        │
Effective access = most permissive combination of:
   direct permissions + inherited (site/library) permissions +
   group-based permissions (M365 Group / SPO group / Entra group) +
   hero-link audience + any surviving legacy links under "Other links"
```

**Key concept:** the hero link is **additive**, not a replacement for the underlying permission model. Adding people directly to a file, group membership, and inherited site permissions all still work exactly as before — the hero link is a new, simplified UI layer for the link-based access piece specifically, and its default posture (no access granted by the link alone) is deliberately more conservative than the pre-rollout default in many tenants.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the tenant/site is actually on the new experience**
Open the Share dialog on a test file. New: one primary "hero" link at top, `DefaultMainLinkScope`-governed. Old: multiple link-creation options with no single primary link.

**Step 2 — Confirm the hero link's current audience for the affected item**
```powershell
Get-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> |
    Select-Object Url, DefaultMainLinkScope
```
This is the **default for new items on that site** — an individual file's hero link may have since been broadened/narrowed by the end user in the Share dialog and will not show up here; confirm the specific file's link audience directly in its own Share dialog.

**Step 3 — Distinguish hero link vs. legacy link in a "why can't they access it" ticket**
In the Share dialog, check both the primary hero link **and** the "Other links" section. A recipient may hold a legacy link created before rollout (or via API/PowerShell `New-PnPSharingLink`-style flows) whose permission/expiration state is entirely independent of the hero link's current settings.

**Step 4 — Confirm this isn't a tenant-wide sharing capability issue instead**
```powershell
Get-SPOTenant | Select-Object SharingCapability
```
`SharingCapability = Disabled` or `ExistingExternalUserSharingOnly` at the tenant level overrides anything the hero link's own audience setting would otherwise allow for external recipients — check this before assuming the hero link itself is misconfigured.

**Step 5 — Confirm effective access holistically**
```powershell
Get-SPOUser -Site https://<tenantName>.sharepoint.com/sites/<siteName> -LoginName <UPN>
```
Remember: link-based access from the hero link is only one contributor to effective access — direct permissions and group membership can independently grant (or already have granted) access regardless of hero-link state.

---

## Common Fix Paths

<details><summary>Fix 1 — Recipient can't open a file the user "shared"</summary>

**Cause:** The default hero-link audience is `OnlyPeopleAdded` — copying/sending the hero link alone does not grant access unless the sender also explicitly added the recipient or broadened the link's audience.

**Remediation (end-user, no admin action needed):**
1. Sender re-opens the Share dialog on the item
2. Either adds the specific recipient directly ("Add people"), or broadens the hero link's audience to **People in \<organization\>** (or **Anyone**, if org policy permits) via the link's own settings
3. Confirm the change updated the *existing* link (same URL) rather than assuming a resend is needed — the recipient's original link/email now works without any new link being generated

**Admin-side prevention (optional):** if this ticket pattern is common for a specific site/OneDrive, consider setting that site's `DefaultMainLinkScope` to `Organization` so new hero links default to broader access:
```powershell
Set-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -DefaultMainLinkScope Organization
```

**Rollback:** `Set-SPOSite -Identity <url> -DefaultMainLinkScope OnlyPeopleAdded`

</details>

<details><summary>Fix 2 — User expected a new link but got the same URL</summary>

**Cause:** This is the hero link's defining behavioral change — broadening or narrowing the audience **updates the existing hero link**, it does not create a new one. This is different from the legacy model, where each distinct sharing action could produce a separate link with its own settings.

**Remediation:** Confirm this is expected behavior, not a fault. If the user genuinely needs a second, independently-revocable link with different settings (e.g., a time-boxed link for one specific external party while the main hero link stays internal-only), point them to **Other links** in the Share dialog, where legacy-style distinct links can still be created and managed separately from the hero link.

</details>

<details><summary>Fix 3 — Tenant link-expiration policy isn't being enforced on some shared content</summary>

**Cause:** Per the rollout's own documentation, existing default sharing-link settings and link-expiration policies continue to apply to **legacy links only** — they do not govern the hero link. A file shared exclusively via its hero link is not subject to a tenant-wide link-expiration policy the way a pre-rollout "Anyone" link would have been.

**Remediation:**
1. Confirm which link type is actually in use for the affected file/folder (hero link vs. an "Other links" legacy link) — Step 3 of Diagnosis
2. If compliance requires expiration enforcement, this is currently a **product gap for hero links specifically** as of this writing, not a misconfiguration — do not spend time hunting for a policy setting that doesn't exist yet for this link type
3. Document as a known limitation for any client with contractual/compliance link-expiration requirements; track for a Message Center update rather than attempting a workaround that doesn't exist in the platform today
4. Interim mitigation: for content with a hard compliance need, use a Sensitivity Label with encryption/access-expiration baked into the label itself (governs the *file*, independent of which link type is used to share it) rather than relying on link-level expiration

**Rollback:** N/A — not a misconfiguration to roll back.

</details>

<details><summary>Fix 4 — Can't tell which link a recipient actually has</summary>

**Cause:** Legacy links created before rollout, or via PowerShell/API-driven sharing flows, persist unchanged and appear under "Other links" alongside the new hero link.

**Remediation:**
1. Open the Share dialog and check **both** the primary hero link's settings and every entry under "Other links"
2. Ask the recipient to paste the exact URL they're using — the hero link and any legacy link will typically have visibly different URL patterns/tokens
3. Each link's own permission/expiration state is independent — fixing the hero link's audience does not retroactively fix a broken legacy link the recipient may actually hold, and vice versa

**Rollback:** N/A — diagnostic step only.

</details>

<details><summary>Fix 5 — Org wants a different default sharing posture for new content</summary>

**Cause:** No tenant-wide hero-link-audience setting exists as of this writing — it must be set per site collection or per-OneDrive.

**Remediation (per site):**
```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com
Set-SPOSite -Identity https://<tenantName>.sharepoint.com/sites/<siteName> -DefaultMainLinkScope Organization
```

**At scale (all sites of a given template, e.g. all Team sites):**
```powershell
Get-SPOSite -Limit All -Template "GROUP#0" | ForEach-Object {
    Set-SPOSite -Identity $_.Url -DefaultMainLinkScope Organization
}
```
Test on a small pilot list first — this changes the *default* for new items on the site; it does not retroactively change hero links that already exist with a different audience.

**Rollback:** Re-run with `-DefaultMainLinkScope OnlyPeopleAdded`.

</details>

<details><summary>Fix 6 — Inconsistent sharing dialog behavior across users in the same org</summary>

**Cause:** MC1454378 is a **staged** rollout (late August–late October 2026, worldwide) — it does not land for every user/tenant simultaneously, and Microsoft does not publish a per-tenant rollout-completion indicator.

**Remediation:**
1. Confirm this is genuinely a rollout-timing artifact and not a real permission/config difference — check `DefaultMainLinkScope` and `SharingCapability` are consistent across the sites in question first
2. If confirmed rollout-timing, this self-resolves without admin action by late October 2026 — communicate the expected timeline rather than troubleshooting further
3. Update internal end-user documentation/training materials now, since some staff will already be on the new experience while others train against outdated screenshots for several weeks

**Rollback:** N/A — not something to roll back; it's a Microsoft-controlled staged rollout.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Hero Link / Next-Gen Sharing Issue
=====================================
Site/OneDrive URL:         [url]
DefaultMainLinkScope:      [OnlyPeopleAdded / Organization]
Tenant SharingCapability:  [output of Get-SPOTenant]
Affected file/folder:      [path]
Link type in use:          [Hero link / legacy "Other links" entry / unknown]
Recipient UPN or external email: [value]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed tenant/site is on the new sharing experience (Share dialog check)
[ ] Confirmed DefaultMainLinkScope for the site/OneDrive
[ ] Checked both hero link and "Other links" for the specific item
[ ] Confirmed tenant-wide SharingCapability isn't the actual blocker
[ ] Confirmed effective access via Get-SPOUser / group membership
[ ] Ruled out rollout-timing inconsistency (Fix 6) as the explanation
```

---

## 🎓 Learning Pointers

- **The hero link's default (`OnlyPeopleAdded`) grants zero access by itself.** This is a more conservative default than many tenants' pre-rollout link behavior — the single most common new-ticket pattern will be "I sent them the link and it doesn't work," which is expected behavior, not a bug, until the sender explicitly broadens the audience or adds the person directly.

- **Broadening a hero link's audience updates the SAME link, it does not mint a new one.** This is the core UX change from the legacy multi-link model — internalize it before troubleshooting "wrong link" tickets, since the fix is very often "nothing to fix, the existing link now works."

- **Link-expiration policies do not (yet) govern hero links, only legacy links.** Flag this explicitly to any client with compliance/contractual link-expiration requirements — it is a genuine, documented gap as of this writing, not a misconfiguration to chase.

- **There is no tenant-wide default-audience switch.** `DefaultMainLinkScope` is a per-site/per-OneDrive PowerShell property only — plan any org-wide default-posture change as a scripted sweep, not a single admin-center toggle. [MC1454378 — Microsoft 365: The Next Generation of File & Folder Sharing (M365 Admin mirror)](https://m365admin.handsontek.net/sharepoint-next-generation-file-folder-sharing/)

- **This is a staged rollout through late October 2026** — inconsistent sharing-dialog behavior across users in the same tenant during this window is expected, not a config drift issue. Re-verify current admin-control surface against Microsoft Learn once a dedicated conceptual article is published, since this runbook is sourced from the Message Center post text rather than a mature Learn page as of this writing.
