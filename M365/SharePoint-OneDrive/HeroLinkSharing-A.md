# Next-Gen Sharing / Hero Link (SharePoint & OneDrive) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why the third-generation sharing model changes admin/support behavior, not just what to click.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- The hero link model — one primary sharing link per file/folder, its default audience posture, and the update-in-place behavior that replaces "one link per audience choice"
- The `DefaultMainLinkScope` admin control surface (per site collection / per-OneDrive), and the explicit absence of a tenant-wide equivalent
- How the hero link interacts with (and does not override) the pre-existing SharePoint/OneDrive permission model — direct permissions, inheritance, group-based access, and legacy links
- The documented scope gap between hero links and tenant-wide default-sharing-link/expiration policies
- The staged worldwide rollout (late August–late October 2026) and its support implications

**Out of scope:**
- SharePoint permission inheritance and the layered permission model itself (see `Permissions-A.md`) — this document assumes that baseline and focuses only on what changes with the hero link
- SharePoint Advanced Management (RAC/RCD/DAG) — an architecturally separate, higher-privilege governance layer (see `Advanced-Management-A.md`)
- Sensitivity Label-based encryption/access control — mentioned only as an interim mitigation for the expiration-policy gap, not covered in depth here

**Assumptions:**
- Reader has SharePoint Online Administrator (or Global Administrator) rights and SharePoint Online Management Shell access
- **Source-confidence note:** as of this writing, Microsoft has not published a dedicated Learn conceptual article for the hero link / third-generation sharing experience. This document is built from the Message Center post (**MC1454378**) text itself, mirrored by third-party M365 admin community sites, rather than a Learn page. Treat the architectural framing as accurate to the Message Center's own description, but re-verify the admin-control surface (`DefaultMainLinkScope` and any future tenant-wide setting) against Microsoft Learn once a conceptual article exists — this is exactly the kind of early-rollout gap that gets backfilled with more precise documentation over the following months.

---

## How It Works

<details><summary>Full architecture</summary>

### Why a Third-Generation Sharing Model

SharePoint/OneDrive sharing has historically allowed a file or folder to accumulate an arbitrary number of independent sharing links over its lifetime — each "Copy Link" or "Share" action could mint a new link with its own audience, permission level, and expiration, with no single link acting as the item's canonical access point. This is flexible but creates two recurring support/security problems: end users lose track of which link they actually sent to which recipient, and admins/auditors reviewing a file's exposure have to enumerate every link ever created rather than reading one authoritative state.

The hero link model collapses this to a single canonical link per item:

```
LEGACY MODEL:
  File → [Link A: Anyone, view, expires in 30d]
       → [Link B: Org only, edit, no expiration]
       → [Link C: Specific people, view]
       (no single "the" link — sender must remember which one they sent)

HERO LINK MODEL:
  File → [HERO LINK: one link, one audience setting, updatable in place]
       → [Other links: legacy links created before rollout, or via API/PowerShell,
          preserved unchanged and separately manageable]
```

Every file and folder gets exactly one hero link, displayed as the primary option in the Share dialog regardless of how the user chooses to share (copy link, email, browser URL bar) — the underlying link identity is consistent across all three surfaces.

### Update-in-Place Semantics

The hero link's single most consequential architectural property: **changing its audience updates the existing link object rather than creating a new one.** If a sender initially shares with "Only people added" and a recipient can't open the file, broadening the audience to "People in the organization" does not generate a new URL — the recipient's original link (already in their inbox) now resolves successfully. This eliminates an entire category of legacy support ticket ("I fixed the sharing but they still have the old broken link") by construction, but it also means an admin/auditor reading a file's current hero-link state is reading its *current* posture only — the item's link-sharing history prior to the most recent change is not separately visible through the hero link itself.

### Default Posture: Deliberately Conservative

`DefaultMainLinkScope` defaults to `OnlyPeopleAdded` — meaning a freshly created hero link, by itself, grants **no** access to anyone. This is a meaningfully more conservative default than many tenants' legacy `DefaultSharingLinkType`/`DefaultLinkPermission` configuration, which in many environments defaulted new links to organization-wide or even anonymous access depending on tenant sharing capability settings. Explicitly adding people to the file remains unchanged and is described as "the simplest way to share" — the hero link's audience setting is a secondary, broaden-as-needed control layered alongside direct people-adding, not a replacement for it.

### Coexistence With Legacy Links

Links that existed before a site/tenant received the rollout continue to function exactly as before and surface under **Other links** in the Share dialog. This is a deliberate non-breaking design choice — no existing recipient's access silently changes at rollout time. The practical consequence for troubleshooting: a file can simultaneously have a hero link with one audience/permission posture and one or more legacy links with entirely different, independently-governed postures. "Effective access" for link-based sharing on any given item is the union of whichever links (hero + any surviving legacy links) a given recipient actually holds a URL for.

### The Expiration-Policy Scope Gap

Per the Message Center post's own admin-controls section: "Existing default sharing link settings and link expiration policies continue to apply to legacy links and do not govern hero links." This is stated plainly as current behavior, not flagged as a bug or temporary limitation — meaning any tenant relying on a tenant-wide link-expiration policy for compliance purposes has a genuine, currently-unaddressed gap for any content shared via the new hero link going forward. This is the single highest-stakes fact in this topic for MSPs supporting regulated clients (finance, healthcare, legal) and should be proactively surfaced to those clients rather than discovered reactively during an audit.

### No Tenant-Wide Default-Audience Control

`DefaultMainLinkScope` is documented as a per-site-collection/per-OneDrive SharePoint PowerShell parameter with **no tenant-wide equivalent** as of this writing. For an MSP managing dozens or hundreds of sites per tenant, achieving a consistent org-wide default posture requires a scripted sweep across every site collection (and every OneDrive, individually) rather than a single admin-center or tenant-PowerShell setting — a materially different operational model from most other SharePoint tenant-wide sharing controls (`Get-SPOTenant`/`Set-SPOTenant`), which apply globally by default.

</details>

---

## Dependency Stack

```
Tenant receives the MC1454378 staged rollout (late Aug–late Oct 2026, worldwide,
no admin-controlled acceleration/deferral mechanism documented)
   │
Every file/folder is assigned exactly one hero link (primary link, consistent
across copy-link / email / browser-URL sharing surfaces)
   │
Hero link audience governed per SITE COLLECTION / per-ONEDRIVE via
DefaultMainLinkScope (OnlyPeopleAdded [default] | Organization)
   │  NOT inherited from or overridden by tenant-wide DefaultSharingLinkType,
   │  DefaultLinkPermission, or link-expiration policy settings — those remain
   │  scoped to legacy (pre-existing / non-hero) links only
   ▼
End user broadens/narrows audience in the Share dialog UI
   │
   ▼
Hero link object is UPDATED IN PLACE (same URL/token persists across audience
changes — no new link minted per change)
   │
   ▼
Effective link-based access = hero link's current audience setting
   UNION any surviving legacy links under "Other links" the recipient
   separately holds a URL for
   │
   ▼
Effective TOTAL access = the above UNION direct permissions, inherited
site/library permissions, and group-based (M365 Group / SPO group / Entra
group) permissions — entirely unchanged by the hero link rollout
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Recipient can't open a "shared" file at all | Hero link default `OnlyPeopleAdded` grants no access by itself | Confirm sender added the person directly or broadened the hero link audience |
| Same URL keeps "not working" even after sender says they "re-shared" | Sender broadened the existing hero link (update-in-place) — recipient should retry the SAME link, not expect a new one | Confirm recipient is using the original URL, not searching for a newer one |
| Compliance/audit finds content with no enforced expiration despite a tenant policy | Hero links are not governed by legacy expiration policies (documented gap) | Confirm which link type the content is actually shared via |
| Two recipients of "the same file" have different access levels | Both a hero link and a distinct legacy link exist for the item, each independently configured | Check both the hero link and "Other links" in the Share dialog |
| Inconsistent sharing UI/behavior across users in one tenant | Staged rollout, not simultaneous | Confirm rollout window (late Aug–late Oct 2026); not a config issue |
| Org-wide default-audience change didn't apply everywhere | No tenant-wide `DefaultMainLinkScope` equivalent — must be set per site/OneDrive | Confirm a scripted per-site/per-OneDrive sweep was actually run, not a single tenant setting |

---

## Validation Steps

**1. Confirm the site/OneDrive's default hero-link audience:**
```powershell
Get-SPOSite -Identity <url> | Select-Object Url, DefaultMainLinkScope
```
Expected values: `OnlyPeopleAdded` (default) or `Organization`.

**2. Confirm tenant-wide sharing capability isn't independently restricting external access:**
```powershell
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, DefaultLinkPermission
```

**3. Confirm which link(s) actually exist for a specific item (manual, UI-based):**
Open the item's Share dialog → note the hero link's current audience → expand "Other links" and note every legacy link's audience/permission/expiration independently.

**4. Confirm effective access for a specific user (permission-model baseline, unchanged by hero link):**
```powershell
Get-SPOUser -Site <url> -LoginName <UPN>
```

**5. Confirm rollout status is the actual explanation for UI inconsistency, not a red herring:**
Cross-reference the ticket date against the documented rollout window (late August–late October 2026). Outside that window, treat inconsistency as a genuine config issue, not rollout timing.

---

## Troubleshooting Steps (by phase)

### Phase 1: Confirm Rollout State and Terminology
1. Confirm whether the affected tenant/site has the new hero-link Share dialog at all (UI check — no PowerShell flag exists for this as of this writing).
2. If not yet rolled out, all hero-link-specific fixes are inapplicable — troubleshoot using the legacy sharing model instead.

### Phase 2: Isolate Hero Link vs. Legacy Link
1. For any "can't access" or "wrong permissions" ticket, always check both the hero link and every "Other links" entry before assuming a single, unified link state.
2. Confirm which link the affected recipient is actually holding (ask for the exact URL if possible).

### Phase 3: Audience/Access Diagnosis
1. Check `DefaultMainLinkScope` for the site/OneDrive (the *default* for new items — not necessarily the current state of an existing, already-modified item).
2. Check the specific item's current hero-link audience directly in its Share dialog.
3. Cross-check tenant-wide `SharingCapability` isn't independently blocking external recipients regardless of hero-link audience.

### Phase 4: Compliance/Governance Gap Assessment
1. For any client with contractual or regulatory link-expiration requirements, proactively audit whether hero links are in use for sensitive content.
2. If the expiration-policy gap is a genuine risk for that client, recommend Sensitivity Label-based access controls as an interim, file-level mitigation independent of link type.

### Phase 5: Org-Wide Default Changes
1. Confirm there is no tenant-wide `DefaultMainLinkScope` setting before promising a single-command fix to a client.
2. Script a per-site-collection (and, separately, per-OneDrive) sweep; pilot on a small subset before a full rollout.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Set a consistent default hero-link audience across all sites of a given template</summary>

```powershell
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# Example: all Team sites (Group#0 template) — adjust -Template for other site types
$sites = Get-SPOSite -Limit All -Template "GROUP#0"
foreach ($site in $sites) {
    try {
        Set-SPOSite -Identity $site.Url -DefaultMainLinkScope Organization -ErrorAction Stop
        Write-Host "Updated: $($site.Url)" -ForegroundColor Green
    } catch {
        Write-Host "FAILED: $($site.Url) — $($_.Exception.Message)" -ForegroundColor Red
    }
}
```

**Verify:** re-run `Get-SPOSite -Limit All -Template "GROUP#0" | Select-Object Url, DefaultMainLinkScope` and confirm no unexpected `OnlyPeopleAdded` stragglers.

**Rollback:** re-run the loop with `-DefaultMainLinkScope OnlyPeopleAdded`.

</details>

<details><summary>Playbook 2 — Compliance gap mitigation for content requiring enforced expiration</summary>

Use when a client has a genuine contractual/regulatory need for link expiration that hero links do not currently support.

1. Identify sensitive content currently shared via hero links using an ad hoc review (no bulk PowerShell surface exists to enumerate hero-link audience across a tenant as of this writing — this is a genuine tooling gap, flag it as such)
2. Apply a Sensitivity Label with content encryption and an access-expiration/revocation capability to the specific files/sites involved — this governs the file itself, independent of which link type (hero or legacy) is used to access it
3. Document the gap and the interim mitigation explicitly in the client's compliance file, with a note to revisit once Microsoft extends expiration-policy support to hero links

**Verify:** confirm the applied Sensitivity Label's access controls actually restrict the file post-expiration, independent of any link-sharing state.

**Rollback:** remove the Sensitivity Label if the compliance requirement changes; document the change.

</details>

<details><summary>Playbook 3 — End-user education rollout ahead of/during the staged tenant migration</summary>

Use proactively for any client with heavy cross-org collaboration, ahead of confirmed rollout in their tenant.

1. Update internal "how to share a file" documentation to describe the single hero-link model and its default `OnlyPeopleAdded` posture
2. Brief power users specifically on the update-in-place behavior (broadening access updates the existing link, no resend needed)
3. Flag the "Other links" location for any workflow that genuinely needs multiple, independently-configured links per item (e.g., time-boxed external-partner links alongside a permanent internal hero link)

**Verify:** spot-check a sample of users post-rollout to confirm the updated guidance matches what they're actually seeing in the Share dialog.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect hero-link / sharing-configuration evidence for a site or set of sites
.NOTES     Read-only. Requires SharePoint Online Management Shell and SPO admin rights.
#>

param(
    [Parameter(Mandatory=$true)][string]$AdminUrl,
    [string[]]$SiteUrls
)

Connect-SPOService -Url $AdminUrl

$OutputDir = ".\HeroLinkSharing-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Tenant-wide sharing posture (unchanged baseline, still relevant)
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, DefaultLinkPermission |
    Out-File "$OutputDir\TenantSharingSettings.txt"

# Per-site DefaultMainLinkScope (the hero-link-specific control surface)
if (-not $SiteUrls) { $SiteUrls = (Get-SPOSite -Limit All).Url }
$results = foreach ($url in $SiteUrls) {
    try {
        $site = Get-SPOSite -Identity $url -ErrorAction Stop
        [PSCustomObject]@{
            Url                = $site.Url
            DefaultMainLinkScope = $site.DefaultMainLinkScope
            SharingCapability    = $site.SharingCapability
        }
    } catch {
        [PSCustomObject]@{ Url = $url; DefaultMainLinkScope = "ERROR"; SharingCapability = $_.Exception.Message }
    }
}
$results | Export-Csv "$OutputDir\SiteHeroLinkSettings.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Connect
Connect-SPOService -Url https://<tenantName>-admin.sharepoint.com

# Site-level hero-link default audience
Get-SPOSite -Identity <url> | Select-Object Url, DefaultMainLinkScope
Set-SPOSite -Identity <url> -DefaultMainLinkScope Organization   # or OnlyPeopleAdded

# OneDrive personal site equivalent
Get-SPOSite -Filter {Url -like "*-my.sharepoint.com/personal*"} -IncludePersonalSite $true |
    Where-Object {$_.Owner -eq "<UPN>"} | Select-Object Url, DefaultMainLinkScope

# Tenant-wide sharing posture (unchanged, still governs legacy links + external access gate)
Get-SPOTenant | Select-Object SharingCapability, DefaultSharingLinkType, DefaultLinkPermission

# Bulk sweep across all sites of a template
Get-SPOSite -Limit All -Template "GROUP#0" |
    ForEach-Object { Set-SPOSite -Identity $_.Url -DefaultMainLinkScope Organization }

# Confirm a specific user's effective site access (permission-model baseline, unrelated to hero link)
Get-SPOUser -Site <url> -LoginName <UPN>
```

---

## 🎓 Learning Pointers

- **The update-in-place behavior is the single biggest mental-model shift.** Every prior generation of SharePoint/OneDrive sharing training assumed "new audience = new link." That assumption is now wrong for the hero link specifically — retrain support staff on this before the rollout window closes, not after the tickets start.

- **`DefaultMainLinkScope` has no tenant-wide equivalent.** Build a reusable script now (Playbook 1) for any client wanting a consistent default posture — this will be a recurring MSP request as more tenants receive the rollout through October 2026.

- **The link-expiration policy gap is a genuine, currently-unaddressed compliance exposure**, not a misunderstanding to correct. Proactively flag it to any client with contractual/regulatory link-expiration requirements rather than waiting for it to surface in an audit.

- **This topic is sourced from a Message Center post, not a mature Learn conceptual article, as of this writing.** Re-check for a dedicated Microsoft Learn page once the rollout completes in late October 2026 — early-rollout Message Center language sometimes gets refined or corrected in the eventual Learn documentation. [MC1454378 — Microsoft 365: The Next Generation of File & Folder Sharing (M365 Admin mirror)](https://m365admin.handsontek.net/sharepoint-next-generation-file-folder-sharing/)

- **No bulk PowerShell surface exists (as of this writing) to enumerate hero-link audience state across all items in a tenant** — only the site/OneDrive-level *default* (`DefaultMainLinkScope`) is queryable, not each individual item's current, possibly-since-modified hero link audience. Keep this limitation in mind before promising a client a full "audit every file's current sharing state" deliverable.
