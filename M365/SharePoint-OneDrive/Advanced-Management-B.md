# SharePoint Advanced Management (SAM) — Hotfix Runbook (Mode B: Ops)
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

SharePoint Advanced Management (SAM) is the umbrella name for Restricted Access Control (RAC), Restricted Content Discovery (RCD), Site Lifecycle Management (inactive/ownership/attestation policies), Data Access Governance (DAG) reports, and a handful of adjacent oversharing/session controls. Most "it's not working" tickets trace back to licensing gates or propagation delays, not broken configuration. Run these from an admin workstation:

```powershell
# 1. Confirm SPO Management Shell module + version (DAG PowerShell needs 16.0.25409+)
Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable | Select-Object Name, Version

# 2. Connect and confirm role — do NOT use -Credential (not supported for SAM cmdlets)
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"

# 3. Check tenant-level SAM toggles
Get-SPOTenant | Select-Object DelegateRestrictedAccessControlManagement, `
    AllowSharingOutsideRestrictedAccessControlGroups, DelegateRestrictedContentDiscoverabilityManagement, `
    RestrictedAccessControlForSitesErrorHelpLink

# 4. Check the specific site's SAM state
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" |
    Select-Object Url, LockState, SharingCapability, RestrictedAccessControl, `
    RestrictedAccessControlGroups, RestrictContentOrgWideSearch

# 5. If the symptom is idle sign-out, check the tenant-wide setting (there is no per-site override)
Get-SPOBrowserIdleSignOut
```

| Result | Meaning | Action |
|---|---|---|
| Cmdlet errors `You need a SharePoint Advanced Management license to perform this action` | Tenant has neither a Copilot licence assigned to any user nor the SAM Plan 1 add-on | Go to Fix 1 — confirm licensing path |
| `RestrictedAccessControl` is `$false` on the site but was configured today | Under the 1-hour tenant propagation window, or `EnableRestrictedAccessControl` was never actually turned on at tenant level | Go to Fix 2 |
| `RestrictContentOrgWideSearch` is `$true` but the site still surfaces in Copilot/search | Index propagation not complete (can take >1 week on sites with 500k+ items), or the requesting user recently interacted with the content | Go to Fix 3 |
| Site lifecycle emails never arrive | Outlook Actionable Messages not approved (GCC High/DoD) or custom domain not configured for email customization | Go to Fix 4 |
| `Get-SPOBrowserIdleSignOut` shows `Enabled: True` but managed-device users are never signed out | Expected behaviour — managed/compliant devices are exempt by design unless using InPrivate/non-Edge | Go to Fix 5 |
| DAG report `Status` stuck at `NotStarted`/`InQueue` for days | First-ever snapshot report for a workload always takes up to 5 days; subsequent runs complete within 24h | Not a fault — set expectations, re-check with `Get-SPODataAccessGovernanceInsight` |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
M365 base subscription (O365 E3/E5/A5 or M365 E1/E3/E5/A5)
    │
    ├── At least one user assigned a Microsoft 365 Copilot licence   ──OR──   SharePoint Advanced Management Plan 1 add-on
    │   (unlocks SAM's Copilot-aligned feature set tenant-wide,                (required for features NOT gated by Copilot,
    │    no SAM add-on purchase required)                                       e.g. Restricted site creation by apps)
    ▼
Entra ID RBAC role assignment
    - SharePoint Administrator (baseline access to SharePoint admin center)
    - SharePoint Advanced Management Administrator (adds: view content metadata at scale,
      remove permissions at scale, manage SAM features specifically)
    ▼
SharePoint Online Management Shell — Microsoft.Online.SharePoint.PowerShell module
    - v16.0.25409+ required for Data Access Governance (DAG) cmdlets specifically
    - Connect-SPOService WITHOUT -Credential (interactive/MFA only)
    ▼
Tenant-level SAM toggles (Set-SPOTenant ...) — up to 1 hour to propagate
    - EnableRestrictedAccessControl / DelegateRestrictedAccessControlManagement
    - AllowSharingOutsideRestrictedAccessControlGroups
    - DelegateRestrictedContentDiscoverabilityManagement
    ▼
Site-level SAM configuration (Set-SPOSite ...) — per-site, up to 10 groups for RAC
    - RestrictedAccessControl + RestrictedAccessControlGroups
    - RestrictContentOrgWideSearch (RCD)
    - LockState (read-only/no access — set indirectly by Site Lifecycle Management enforcement, not directly by admin for that purpose)
    ▼
Enforcement / observable surface
    - Site open / file access evaluation (RAC — checked at time of access, not cached)
    - Search index + Copilot grounding (RCD — index propagation lag, especially on large sites)
    - Monthly policy run + Outlook Actionable Messages (Site Lifecycle Management)
    - Conditional Access + Entra ID P1/P2 (idle session sign-out, authentication context policies)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the licensing gate isn't the actual root cause**
```powershell
# There's no single "is SAM licensed" property to query directly — the most reliable signal
# is attempting a SAM-gated action and reading the exact error text.
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictedAccessControl $true -WhatIf
```
Expected: no licensing error in the `-WhatIf` output.
Bad: `You need a SharePoint Advanced Management license to perform this action` → confirm Copilot licence assignment or SAM Plan 1 add-on purchase before troubleshooting further — nothing below this will work without it.

**Step 2 — Confirm tenant-level RAC is actually enabled (not just delegated)**
```powershell
# EnableRestrictedAccessControl itself has no documented Get- property; verify indirectly
# by attempting to set it on a test/non-production site and checking for the tenant-gate warning:
Set-SPOSite -Identity "<test-site-url>" -RestrictedAccessControl $true -WhatIf
```
Expected: no `WARNING: To apply restricted access control, enable the policy on the site... Refer https://aka.ms/RACPolicyForSites` message.
Bad: warning present → tenant-level `Set-SPOTenant -EnableRestrictedAccessControl $true` was never run, or it's still inside its up-to-1-hour propagation window.

**Step 3 — Confirm site-level RAC/RCD state matches what was configured**
```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" |
    Select-Object RestrictedAccessControl, RestrictedAccessControlGroups, RestrictContentOrgWideSearch
```
Expected: values match what was configured in the admin center or via PowerShell.
Bad: `RestrictedAccessControlGroups` is empty while `RestrictedAccessControl` is `$true` → policy is enabled but has zero groups, meaning nobody is exempted and everyone is likely blocked, or (paradoxically) no restriction is actually enforced yet — always add at least one group in the same operation.

**Step 4 — Confirm the user actually has BOTH content permission AND RAC group membership**
```powershell
# RAC does not grant access — it only restricts. The user needs the underlying SharePoint
# permission AND membership in one of the RestrictedAccessControlGroups.
Get-SPOUser -Site "https://<tenant>.sharepoint.com/sites/<sitename>" -LoginName "<user@domain.com>"
# Then separately confirm group membership in Entra ID for each GUID in RestrictedAccessControlGroups
```
Expected: user appears with a valid permission level AND is a member of one of the listed groups.
Bad: user has permission but isn't in any RAC group → this is by design, not a bug — add them to a permitted group.

**Step 5 — Check whether you're inside a documented propagation window**
```
RAC tenant enablement:        up to 1 hour
RCD site-level toggle:        "changes can take time"; index reprocessing for 500k+ item sites: up to 1 week
Site Lifecycle notifications:  monthly cadence — a "missing" notification may simply not be due yet
DAG first snapshot report:     up to 5 days (subsequent runs: within 24h)
```
If the elapsed time is inside these windows, the system is working as designed — do not escalate yet.

---
## Common Fix Paths

<details><summary>Fix 1 — SAM feature unavailable / licensing error</summary>

**Symptom:** Any SAM cmdlet or admin center page returns a licensing error, or the feature toggle is greyed out.

**Cause:** Neither a Copilot licence is assigned to any user in the tenant, nor is the SharePoint Advanced Management Plan 1 add-on purchased (required for SharePoint K/P1/P2 base subscriptions, and for features not covered by the Copilot-aligned set, e.g. Restricted site creation by apps).

```powershell
# Confirm the base M365/O365 subscription is one of: O365 E3/E5/A5, M365 E1/E3/E5/A5
# (check in Microsoft 365 admin center > Billing > Your products, or via Get-MgSubscribedSku)
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# Look for a Copilot SKU already assigned to at least one user
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -like "*COPILOT*" }
```

**Fix:**
1. If Copilot is not licensed anywhere in the tenant: purchase and assign at least one Microsoft 365 Copilot licence (any user — doesn't need to be a SharePoint admin), **or**
2. Purchase the **SharePoint Advanced Management Plan 1** add-on via Microsoft 365 admin center → Billing → Purchase services, a CSP, or volume licensing.
3. Re-run the SAM-gated action after purchase — no propagation delay is documented for licence assignment itself, but Entra ID role/licence sync can take a few minutes.

**Rollback:** N/A — this is an enablement fix, not a config change.

</details>

<details><summary>Fix 2 — Restricted Access Control (RAC) configured but not enforcing</summary>

**Symptom:** RAC is set on a site, but users outside the specified groups still access content.

**Cause (in order of likelihood):** (1) tenant-level RAC not enabled or still inside the 1-hour propagation window, (2) site is a Microsoft 365 Group-connected/Teams site and the group-connected default behaviour wasn't understood, (3) it's a shared/private Teams channel site which is NOT covered by the parent team's RAC policy, (4) `AllowSharingOutsideRestrictedAccessControlGroups` is still `$true`, so sharing (not direct access) is bypassing the intent.

```powershell
# Step 1: Confirm tenant-level enablement
Set-SPOTenant -EnableRestrictedAccessControl $true
# Allow up to 1 hour before re-testing

# Step 2: Re-apply RAC on the specific site with at least one group
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictedAccessControl $true
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" `
    -AddRestrictedAccessControlGroups "<entra-security-group-or-m365-group-guid>"

# Step 3: If it's a shared/private Teams channel site, RAC must be applied separately —
# it is NOT inherited from the parent team's group-connected site
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<channelsite>" | Select-Object Template

# Step 4: If sharing (not open access) is the actual leak, tighten the sharing boundary too
Set-SPOTenant -AllowSharingOutsideRestrictedAccessControlGroups $false
```

**Rollback:**
```powershell
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -ClearRestrictedAccessControl
# Recommended follow-up: review site permissions and remove users who no longer need access
Set-SPOTenant -AllowSharingOutsideRestrictedAccessControlGroups $true
```

</details>

<details><summary>Fix 3 — Restricted Content Discovery (RCD) not hiding content from search/Copilot</summary>

**Symptom:** RCD is toggled on for a site, but it still appears in tenant-wide search or Copilot Business Chat responses.

**Cause:** Index propagation lag (documented as potentially over a week for sites with 500,000+ items), or the requesting user had a "recent interaction" with the content (RCD explicitly still allows discovery of files a user owns or recently touched — this is by design, not a bug).

```powershell
# Confirm the setting actually took
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" | Select-Object RestrictContentOrgWideSearch

# Check item count — large sites take proportionally longer to reprocess
Connect-PnPOnline -Url "https://<tenant>.sharepoint.com/sites/<sitename>" -Interactive
(Get-PnPList -Identity "Documents").ItemCount

# Generate an insights report to confirm the site is actually enrolled
Start-SPORestrictedContentDiscoverabilityReport
Get-SPORestrictedContentDiscoverabilityReport
```

**Fix:** If the setting is confirmed `$true` and item count is large, this is expected latency — re-check in a week. If the user reporting the issue simply has recent interaction with the content, explain the by-design behaviour; RCD does not hide content from users who already engage with it directly.

**Rollback:**
```powershell
Set-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" -RestrictContentOrgWideSearch $false
```

</details>

<details><summary>Fix 4 — Site Lifecycle Management notifications never arrive</summary>

**Symptom:** Site owners never receive inactive-site / ownership / attestation notification emails.

**Cause:** In GCC High/DoD, Outlook Actionable Messages require explicit one-time admin approval of the `InactiveSiteOAMProviderGCCH` provider. In any environment, email customization requires a configured custom send domain first. Also check whether the site is simply out of policy scope (OneDrive sites, app catalog, root/home/tenant admin sites, and shared/private Teams channel sites are always excluded).

**Fix (commercial cloud):**
1. Confirm the site template is in-scope: `SitePagePublishing#0`, `STS#0/1/2`, `WIKI#0`, `STS#3`/`Group#0`, etc. — OneDrive and system sites are never in scope regardless of policy config.
2. Confirm the site isn't already governed by an overlapping policy of the same type (suppresses duplicate notifications for 30 days) — check the policy execution report for "Notified by another policy."
3. Confirm the user/site isn't on the policy's exclusion list (up to 100 entries).

**Fix (GCC High / DoD only):**
```
1. Go to https://outlook.office365.us/connectors/oam/Admin
2. Filter Provider Status = "Approved by Microsoft – Pending Your Approval"
3. Locate and Approve "InactiveSiteOAMProviderGCCH"
4. Allow up to 24 hours for propagation
```

**Rollback:** N/A — this is an enablement fix.

</details>

<details><summary>Fix 5 — Idle session sign-out not behaving as expected</summary>

**Symptom:** Users report being signed out too aggressively, or not being signed out at all despite the policy being enabled.

**Cause:** Idle session sign-out is a single **tenant-wide** setting — it cannot be scoped to specific sites or users (use Conditional Access for that, which requires Entra ID P1/P2). It also does not apply to managed/compliant devices unless the browser is Chrome without the device-state extension, or InPrivate mode is used.

```powershell
# Check current config
Get-SPOBrowserIdleSignOut

# Reconfigure — both -WarnAfter and -SignOutAfter are required, SignOutAfter must exceed WarnAfter
Set-SPOBrowserIdleSignOut -Enabled $true `
    -WarnAfter (New-TimeSpan -Minutes 45) `
    -SignOutAfter (New-TimeSpan -Minutes 60)
```
Allow ~15 minutes for the change to take effect; it does not affect sessions already in progress.

**Rollback:**
```powershell
Set-SPOBrowserIdleSignOut -Enabled $false -WarnAfter (New-TimeSpan -Minutes 45) -SignOutAfter (New-TimeSpan -Minutes 60)
```

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — SharePoint Advanced Management (SAM) Issue
=================================================================
Date/Time:                _______________
Raised by:                _______________
Severity:                 _______________

FEATURE AFFECTED
  [ ] Restricted Access Control (RAC)
  [ ] Restricted Content Discovery (RCD)
  [ ] Site Lifecycle Management (inactive/ownership/attestation)
  [ ] Data Access Governance (DAG) reports
  [ ] Idle session sign-out
  [ ] Other: _______________

LICENSING
  Base subscription:              _______________  (O365/M365 Exx or Axx)
  Copilot licence assigned to any user:  Yes / No
  SharePoint Advanced Management Plan 1 add-on purchased:  Yes / No
  RBAC role held by requester:    _______________

SITE / TENANT DETAILS
  Tenant admin URL:               _______________
  Affected site URL(s):           _______________
  SPO Management Shell version:   _______________  (Get-Module -ListAvailable)

CONFIGURATION STATE (paste raw output)
  Get-SPOTenant (relevant properties):     _______________
  Get-SPOSite (relevant properties):       _______________

TIMING
  When was the setting configured:  _______________
  Elapsed time since configuration: _______________
  Is this inside a documented propagation window (1hr RAC / up to 1wk RCD index / 5-day first DAG report)?  Yes / No

ERROR OBSERVED
  Exact error/warning text:       _______________
  Reproducible via PowerShell -WhatIf:  Yes / No

PREVIOUS STATE
  Did this ever work correctly?   Yes / No
  Recent changes (licence, roles, tenant settings):  _______________
```

---
## 🎓 Learning Pointers

- **SAM is a licence gate wrapped around otherwise-normal SPO cmdlets.** Nearly every "feature isn't working" ticket is actually a licensing or role gap, not a config bug — always confirm the exact error text before assuming a functional defect. See [Prerequisites for SharePoint Advanced Management](https://learn.microsoft.com/en-us/sharepoint/sharepoint-advanced-management-prerequisites).

- **RAC restricts, it doesn't grant.** Adding a user to a Restricted Access Control group never gives them access by itself — they still need the underlying SharePoint permission. This is the single most common source of "I added them to the group and it still doesn't work" tickets. See [Restrict SharePoint site access with Microsoft 365 groups and Microsoft Entra security groups](https://learn.microsoft.com/en-us/sharepoint/restricted-access-control).

- **RCD and search index propagation are not instant.** For very large sites, the documented latency can exceed a week. Set that expectation with the requester up front instead of re-toggling the setting repeatedly, which doesn't speed anything up. See [Restrict discovery of SharePoint sites and content](https://learn.microsoft.com/en-us/sharepoint/restricted-content-discovery).

- **Shared and private Teams channel sites are always separate from the parent team's site policies.** RAC, sharing, and most SAM controls applied to a Team's main site do not automatically extend to its shared/private channel sites — each must be configured independently.

- **Idle session sign-out is tenant-wide only.** If a request is "make this apply just to contractors" or "just to this one site," the correct tool is a Conditional Access policy (requires Entra ID P1/P2), not this setting. See [Sign out inactive users](https://learn.microsoft.com/en-us/sharepoint/sign-out-inactive-users).

- **First-run DAG snapshot reports take up to 5 days by design.** Don't treat a report stuck at `NotStarted` on day one as a fault — subsequent reports for the same workload complete within 24 hours. See [Manage Data access governance reports by using SharePoint Online PowerShell](https://learn.microsoft.com/en-us/sharepoint/powershell-for-data-access-governance).
