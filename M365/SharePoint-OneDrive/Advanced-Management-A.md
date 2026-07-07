# SharePoint Advanced Management (SAM) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**Covers:**
- Restricted Access Control (RAC) — group-based site access restriction
- Restricted Content Discovery (RCD) — hiding sites from tenant-wide search and Copilot
- Site Lifecycle Management — inactive site policies, site ownership policies, site attestation policies
- Data Access Governance (DAG) reports — permission snapshots, sensitivity label snapshots, sharing-link and EEEU activity reports, and PowerShell-driven site access reviews
- Idle session sign-out and Conditional Access authentication context for SharePoint/OneDrive (adjacent tenant-wide session controls that sit alongside SAM licensing but are documented as related capabilities)
- Block download policy, restricted site creation by apps, and change history reports at a reference level

**Does not cover:**
- SharePoint Syntex content processing (autofill columns, taxonomy tagging, content query, translation) — a related but distinct SharePoint Premium capability with its own licensing
- SharePoint Embedded
- Detailed Conditional Access policy authoring (see `Security/ConditionalAccess/`)
- Microsoft Purview retention/DLP/sensitivity label authoring (see `Security/Purview/`) — this runbook covers only how SAM *reports on* and *reacts to* labels, not how to create them

**Assumed role:** SharePoint Administrator or SharePoint Advanced Management Administrator in Entra ID; SharePoint Online Management Shell (`Microsoft.Online.SharePoint.PowerShell`) installed, version 16.0.25409 or later for Data Access Governance cmdlets specifically.

---

## How It Works

<details><summary>Full architecture</summary>

### What SAM actually is

SharePoint Advanced Management (SAM) is not a single product — it's a **licensing-gated feature bundle** layered on top of ordinary SharePoint Online admin capabilities. There is no separate SAM service, endpoint, or PowerShell module; SAM-gated cmdlets live in the same `Microsoft.Online.SharePoint.PowerShell` module as everything else, and simply return a licensing error if the tenant doesn't qualify. This matters operationally: there is no "SAM service health" to check — if a SAM cmdlet fails, the two most likely causes are (1) licensing/role and (2) the same kind of propagation delay that affects any other SPO tenant-wide setting.

Microsoft groups SAM's capabilities into four themes:

```
1. Manage content sprawl
   - Site ownership policy   - Inactive SharePoint sites (Site Lifecycle Management)
   - Site attestation policy

2. Manage the content lifecycle
   - Catalog management (group sites into logical categories)
   - Change history reports (180-day config change tracking)
   - Recent actions panel (30-day admin action tracking)
   - Restricted site creation by (non-Microsoft) apps

3. Prevent oversharing
   - Content management assessment hub
   - Block download policy
   - App insights (non-Microsoft app access to SharePoint content)
   - AI insights (pattern extraction from reports)
   - Restricted Access Control (RAC)
   - Restricted Content Discovery (RCD)
   - Data Access Governance (DAG) reports + site access reviews

4. Manage permissions and access
   - Conditional Access authentication contexts for SharePoint sites
   - Site policy comparison reports (AI-assisted, up to 10,000 target sites)
   - Agent access insights / SharePoint agent insights
   - Restrict OneDrive access via security groups (tenant-wide or per-user)
   - Restrict OneDrive/SharePoint site creation
```

### The licensing fork

There are **two independent paths** to unlocking SAM capability, and they unlock *different subsets*:

| Path | What it unlocks | Base subscription required |
|---|---|---|
| **At least 1 user assigned a Microsoft 365 Copilot licence** | The full Copilot-aligned SAM feature set (RAC, RCD, DAG reports, block download, site ownership/inactive/attestation policies, catalog management, change history, etc.) tenant-wide — the assigned user does **not** need to be a SharePoint admin | O365/M365 E3/E5/A5 (or E1 base + Copilot add-on) |
| **SharePoint Advanced Management Plan 1 add-on** (a.k.a. "SAM standalone") | Everything above, **plus** features not included in the Copilot bundle — e.g. Restricted site creation by apps, advanced tenant renaming for tenants with >10,000 sites | SharePoint K, P1, or P2 base subscription |

External/guest users never require a licence for SAM to apply to them. IT admins with only Microsoft 365 E5 licensing can access DAG *reporting* but not the full SAM feature set or remedial actions (snapshot reports and remediation are unavailable in that reduced tier).

### RAC: how the enforcement actually happens

RAC is evaluated **at time of access**, not cached at grant time. When a user opens a site or file:
1. SharePoint checks normal permissions (does the user have Read/Contribute/etc.?) — unchanged by RAC.
2. If the site has RAC enabled, SharePoint additionally checks whether the user is a member of one of up to 10 configured Microsoft Entra security groups or Microsoft 365 Groups (dynamic groups are supported).
3. Both checks must pass. RAC never grants access on its own — it can only narrow an already-permitted population.
4. Search results still show file *metadata* to users with direct permission even if they're outside the RAC group — but attempting to open the file is blocked. This is a deliberate compromise (findability vs. false-negative confusion) documented by Microsoft.

Group-connected (Microsoft 365 Group / Teams) sites get their connected group auto-populated as the default RAC group (tagged "Default group" in the UI) — you can add more groups but cannot remove the connected group without disconnecting the site from the group entirely. Shared and private Teams channel sites are **structurally separate** SharePoint sites that are not connected to the team's Microsoft 365 Group — RAC on the parent team never extends to them; each must be configured independently, and for shared channels, only internal users in the resource tenant are evaluated against RAC (external channel participants are excluded and fall back to normal site permissions).

### RCD: index-based, not permission-based

RCD does not touch permissions at all — a user who already has access to a file can still open it directly via a link or by navigating the library. What RCD removes is *discoverability*: the site's content stops appearing in tenant-wide search (SharePoint home, Office.com, Bing) and Microsoft 365 Copilot Business Chat grounding, **except** for content the requesting user owns or has recently interacted with. Because this is implemented via the search index, propagation is asynchronous and scales with content volume — Microsoft documents update latency exceeding a week for sites with 500,000+ items. RCD also has a direct trade-off: content removed from Copilot's discoverable set is content Copilot can no longer ground responses on, which can make Copilot answers less accurate/complete for legitimate users of that content.

### Site Lifecycle Management: activity detection and enforcement

Inactive site policies detect a site's last activity by inspecting **cross-workload** signals — SharePoint (views/edits/shares/syncs), Teams (messages/reactions/meetings), Viva Engage (posts/reads/likes), and Exchange (received mail). Crucially, **app-only token activity is never counted**, and user-token activity is only counted under specific User-Agent conditions (this is why automation/scripted access via PnP PowerShell with a user token is explicitly excluded from counting as activity — a site kept "alive" only by a scheduled PnP script will still be flagged inactive).

Policies run in two modes: **simulation** (one-time report, no enforcement, must be deleted and recreated if it fails) and **active** (runs monthly, sends up to 3 notifications via Outlook Actionable Messages, then applies the configured enforcement action — Do nothing / Read-only / Archive after a configurable read-only period via Microsoft 365 Archive). A site can be "certified" by its owner, which suppresses activity checking for a full year. Overlapping policies of the *same type* suppress duplicate notifications for 30 days — the execution report will show "Notified by another policy" rather than sending a second email.

### DAG reports: snapshot vs. activity, and the async report model

DAG reports split into two families:
- **Snapshot reports** (Site permissions, Site permissions for users, Sensitivity label distribution) — a point-in-time view, generated asynchronously via `Start-SPODataAccessGovernanceInsight`, tracked via `Get-SPODataAccessGovernanceInsight`, and downloaded via `Export-SPODataAccessGovernanceInsight`. The very first tenant-wide snapshot always takes up to 5 days regardless of tenant size; subsequent runs complete within 24 hours and can only be re-run once every 30 days per workload.
- **Activity reports** (Sharing links, EEEU) — cover only the last 28 days, and for tenants **without** a full SAM licence, require explicitly enabling audit data collection first via `Start-SPOAuditDataCollectionForActivityInsights` (data collection auto-pauses if no report is generated for 3 months).

Remediation from a DAG report can trigger a **site access review** (`Start-SPOSiteReview`), which emails the site owner asking them to review and update permissions — capped at 1,000 initiations per calendar month from the site permissions report, resetting monthly.

</details>

---

## Dependency Stack

```
[Entra ID Tenant]
    │
    ▼
[M365 Base Subscription]
    O365 E3/E5/A5, M365 E1/E3/E5/A5  (RAC/RCD/DAG/Lifecycle path)
    OR SharePoint K/P1/P2            (SAM Plan 1 add-on path — required for app-restricted-site-creation, >10k-site tenant rename)
    │
    ▼
[Licence Gate]
    >=1 user with M365 Copilot licence   ──OR──   SharePoint Advanced Management Plan 1 add-on purchased
    │
    ▼
[Entra ID RBAC Role]
    SharePoint Administrator  or  SharePoint Advanced Management Administrator
    │
    ▼
[SharePoint Online Management Shell]
    Microsoft.Online.SharePoint.PowerShell, v16.0.25409+ for DAG cmdlets
    Connect-SPOService WITHOUT -Credential (interactive/MFA path only)
    │
    ▼
[Tenant-Level SAM Settings]  (Set-SPOTenant, up to 1hr propagation)
    EnableRestrictedAccessControl, DelegateRestrictedAccessControlManagement,
    AllowSharingOutsideRestrictedAccessControlGroups, DelegateRestrictedContentDiscoverabilityManagement
    │
    ▼
[Site-Level SAM Settings]  (Set-SPOSite, per site)
    RestrictedAccessControl + up to 10 RestrictedAccessControlGroups
    RestrictContentOrgWideSearch
    (Site Lifecycle/Ownership/Attestation policy scope is admin-center or bulk-CSV configured — no per-site cmdlet)
    │
    ▼
[Enforcement / Observable Layer]
    RAC:       evaluated live at every site/file open — no caching
    RCD:       search index propagation (minutes to >1 week depending on item count)
    Lifecycle: monthly policy run + Outlook Actionable Messages + Microsoft 365 Archive integration
    DAG:       async report queue (up to 5 days first run, 24h subsequent)
    │
    ▼
[Dependent/Adjacent Controls]
    Idle session sign-out    — tenant-wide only, requires Entra ID P1/P2 for CA-based per-user targeting
    Conditional Access auth context — requires Entra ID Conditional Access licensing
    Microsoft 365 Archive     — must be separately enabled for "Archive after read-only" enforcement action
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Any SAM cmdlet returns `You need a SharePoint Advanced Management license to perform this action` | No Copilot licence assigned anywhere in tenant, and SAM Plan 1 add-on not purchased | `Get-MgSubscribedSku` for Copilot SKU; Microsoft 365 admin center billing for SAM Plan 1 |
| `Set-SPOSite -RestrictedAccessControl $true` succeeds but produces a `WARNING: To apply restricted access control, enable the policy on the site` message | Tenant-level `EnableRestrictedAccessControl` never run, or still inside 1hr propagation | `Set-SPOTenant -EnableRestrictedAccessControl $true`; wait 1hr; retest |
| User in a RAC group still can't access content | RAC restricts, it doesn't grant — user lacks the underlying SharePoint permission | `Get-SPOUser -Site <url> -LoginName <upn>` |
| User NOT in a RAC group can still access content | Tenant/site RAC not actually enabled yet, `AllowSharingOutsideRestrictedAccessControlGroups` still `$true`, or it's a shared/private channel site not covered by parent policy | `Get-SPOSite \| Select RestrictedAccessControl*`; check `Template` for channel site types |
| RAC works on the main team site but not a private channel | Shared/private channel sites are structurally separate from the group-connected site | Configure RAC independently on the channel site URL |
| Site still appears in Copilot/org search after RCD enabled | Search index propagation lag (up to 1wk for 500k+ items) or user has recent interaction with the content (by design) | `Get-SPOSite \| Select RestrictContentOrgWideSearch`; `Start-/Get-SPORestrictedContentDiscoverabilityReport` |
| RCD applied to a OneDrive site has no effect | RCD explicitly cannot be applied to OneDrive sites | N/A — not supported, use RAC/OneDrive access restriction instead |
| Inactive site policy never sends notifications | Site is out-of-scope (OneDrive/system/app-catalog/root/home/tenant-admin/Teams-channel site), suppressed by an overlapping policy's 30-day window, or (GCC High/DoD) Actionable Messages provider not approved | Policy execution report "Action status" column; `InactiveSiteOAMProviderGCCH` approval state |
| Site goes read-only unexpectedly | Inactive site policy enforcement action triggered after 3 unanswered monthly notifications | Site page banner; policy execution report "Action taken on" column |
| Site owner can't remove read-only banner themselves | By design — only a tenant admin can unlock via Active sites → Unlock, or reactivate an archived site | SharePoint admin center → Active/Archived sites |
| DAG snapshot report stuck at `NotStarted`/`InQueue` on day 1 | First-ever report for that workload always takes up to 5 days | `Get-SPODataAccessGovernanceInsight -ReportEntity <entity>` |
| DAG activity report (Sharing links/EEEU) returns no data for a non-SAM-licensed tenant | Audit data collection was never enabled for that report entity | `Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity <entity>` |
| Sensitivity label DAG report missing labels | Label GUID/name mismatch, or querying `OneDriveForBusiness` workload (not supported for this report type) | `Get-Label` (Security & Compliance PowerShell) to confirm exact GUID/name |
| Idle session sign-out doesn't sign out a managed-device user | Expected — managed/compliant devices are exempt unless InPrivate or non-Edge/IE browser without device-state extension | `Get-SPOBrowserIdleSignOut`; confirm device compliance state in Intune/Entra |
| Custom idle sign-out warning/message not showing per-department | Idle session sign-out is a single tenant-wide setting — no per-site/per-user scoping exists | Use Conditional Access (requires Entra ID P1/P2) instead |
| Site access review not emailing the site owner | Monthly cap of 1,000 reviews from the site permissions report reached, or `ReportID`/`SiteID` pairing incorrect | `Get-SPOSiteReview -ReportEntity <entity>` |

---

## Validation Steps

**1. Confirm module version and SAM licensing gate**
```powershell
Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable | Select-Object Name, Version
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
Set-SPOSite -Identity "<any-test-site-url>" -RestrictedAccessControl $true -WhatIf
```
**Good:** No licensing error surfaces in the `-WhatIf` preview.
**Bad:** `You need a SharePoint Advanced Management license...` — stop here; resolve licensing before any further validation.

**2. Confirm tenant-level SAM toggles**
```powershell
Get-SPOTenant | Select-Object DelegateRestrictedAccessControlManagement, `
    AllowSharingOutsideRestrictedAccessControlGroups, DelegateRestrictedContentDiscoverabilityManagement, `
    RestrictedAccessControlForSitesErrorHelpLink
```
**Good:** Values reflect intended tenant policy (e.g. delegation off unless deliberately enabled).
**Bad:** Unexpected `$true`/`$false` — someone changed tenant-wide behaviour without a documented change request; check the Change history report.

**3. Confirm RAC state and group population on a specific site**
```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" |
    Select-Object RestrictedAccessControl, RestrictedAccessControlGroups
```
**Good:** `RestrictedAccessControl = $true` and `RestrictedAccessControlGroups` contains 1-10 valid GUIDs.
**Bad:** `$true` with an empty groups list — policy enabled but effectively unenforceable/misconfigured.

**4. Confirm RCD state and index enrolment**
```powershell
Get-SPOSite -Identity "https://<tenant>.sharepoint.com/sites/<sitename>" | Select-Object RestrictContentOrgWideSearch
Start-SPORestrictedContentDiscoverabilityReport
Get-SPORestrictedContentDiscoverabilityReport
```
**Good:** Property is `$true` and the site appears once the insights report completes.
**Bad:** Property is `$true` but report never lists the site after a reasonable wait — escalate as a genuine platform issue, not user error.

**5. Confirm DAG report pipeline health**
```powershell
Start-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers -ReportType Snapshot -Workload SharePoint -CountOfUsersMoreThan 0 -Name "ValidationRun"
Get-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers
```
**Good:** New report shows `Status: NotStarted` immediately after creation, progressing to `InQueue`/`Completed` over the following hours/days.
**Bad:** Report status never changes after 5+ days — genuine issue, escalate with the returned `ReportId`.

**6. Confirm idle session sign-out configuration**
```powershell
Get-SPOBrowserIdleSignOut
```
**Good:** `Enabled: True` with sane `WarnAfter`/`SignOutAfter` values (`SignOutAfter` > `WarnAfter`).
**Bad:** `Enabled: False` when the org expects it on, or values reversed (SignOutAfter <= WarnAfter is rejected at set-time, so this indicates a stale/failed prior configuration attempt).

---

## Troubleshooting Steps by Phase

### Phase 1 — Licensing & Access

1. Confirm base subscription tier (O365/M365 E-series, or SharePoint K/P1/P2 for the add-on path).
2. Confirm at least one Copilot licence is assigned tenant-wide, OR the SAM Plan 1 add-on is purchased.
3. Confirm the requester holds SharePoint Administrator or SharePoint Advanced Management Administrator in Entra ID.
4. Confirm SPO Management Shell is current (v16.0.25409+ for DAG).

### Phase 2 — Restricted Access Control

1. Confirm tenant-level `EnableRestrictedAccessControl` and allow 1hr propagation.
2. Confirm per-site `RestrictedAccessControl` + `RestrictedAccessControlGroups` (max 10).
3. Distinguish group-connected sites (default group auto-populated) from non-group sites (must add groups manually) from shared/private channel sites (always separate, never inherited).
4. Confirm the affected user has both direct/group SharePoint permission AND RAC group membership — these are two independent gates.
5. If sharing links are the leak vector rather than direct access, check `AllowSharingOutsideRestrictedAccessControlGroups`.

### Phase 3 — Restricted Content Discovery

1. Confirm the tenant has a Copilot licence assigned (RCD's stated eligibility condition).
2. Confirm the setting is not being applied to a OneDrive site (unsupported).
3. Confirm via `Start-/Get-SPORestrictedContentDiscoverabilityReport` that the site is actually enrolled.
4. Account for index propagation time proportional to item count before concluding it's broken.
5. Remember RCD does not affect eDiscovery/autolabeling (Purview) or content-in-use Copilot scenarios (e.g. "summarize this document" in Word) — only tenant-wide search and Copilot Business Chat discovery.

### Phase 4 — Site Lifecycle Management

1. Confirm the site template is in-scope (communication, classic, Teams-connected, or group-connected templates only).
2. Confirm the site isn't excluded (OneDrive, app catalog, root/home/tenant-admin, Teams channel sites are always out of scope).
3. Check for policy overlap suppressing notifications (30-day same-type-policy rule).
4. For GCC High/DoD, confirm `InactiveSiteOAMProviderGCCH` approval and Outlook version compliance for Actionable Messages rendering.
5. If a site is in read-only/archived state and this is unexpected, check whether it's a different policy type's lock (excluded from further scope) vs. this policy's own lock (included, marked "previously actioned").

### Phase 5 — Data Access Governance Reports & Remediation

1. Confirm module version supports DAG cmdlets (16.0.25409+) and connection was made without `-Credential`.
2. For non-SAM-licensed tenants (E5-only reporting access), confirm audit data collection was explicitly enabled for activity report entities.
3. Track report status via `Get-SPODataAccessGovernanceInsight` before assuming failure — first snapshot runs take up to 5 days.
4. For remediation, confirm the monthly cap of 1,000 site access reviews (from the site permissions report specifically) hasn't been reached.
5. Cross-reference sensitivity label report gaps against `Get-Label` output — label GUID/name typos are the most common cause of empty results.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Roll out Restricted Access Control (RAC) to a sensitive site</summary>

```powershell
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"

# Step 1: Enable tenant-level RAC (one-time, up to 1hr propagation)
Set-SPOTenant -EnableRestrictedAccessControl $true

# Step 2: (Optional) Delegate day-to-day management to site admins, with mandatory justification
Set-SPOTenant -DelegateRestrictedAccessControlManagement $true

# Step 3: After propagation, enable RAC on the target site with its permitted groups
$siteUrl = "https://<tenant>.sharepoint.com/sites/<sitename>"
Set-SPOSite -Identity $siteUrl -RestrictedAccessControl $true
Set-SPOSite -Identity $siteUrl -AddRestrictedAccessControlGroups "<group-guid-1>,<group-guid-2>"

# Step 4: Confirm
Get-SPOSite -Identity $siteUrl | Select-Object RestrictedAccessControl, RestrictedAccessControlGroups

# Step 5: (Optional) Tighten sharing so RAC-excluded users can't be added via a sharing link either
Set-SPOTenant -AllowSharingOutsideRestrictedAccessControlGroups $false

# Step 6: (Optional) Customize the access-denied "Learn more" link so blocked users get context
Set-SPOTenant -RestrictedAccessControlForSitesErrorHelpLink "https://<intranet>/access-policy"
```

**Rollback:**
```powershell
Set-SPOSite -Identity $siteUrl -ClearRestrictedAccessControl
Set-SPOTenant -AllowSharingOutsideRestrictedAccessControlGroups $true
# Recommended: audit and clean up permissions afterward — RAC removal doesn't retroactively
# remove direct permissions granted while the policy was active
```

</details>

<details><summary>Playbook 2 — Prepare high-risk sites for Copilot with Restricted Content Discovery (RCD)</summary>

```powershell
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"

# Step 1: Identify candidate sites using a DAG site permissions report first (see Playbook 4)
# Step 2: Apply RCD to the shortlisted sites
$highRiskSites = @(
    "https://<tenant>.sharepoint.com/sites/LegalHold",
    "https://<tenant>.sharepoint.com/sites/ExecBoard"
)
foreach ($site in $highRiskSites) {
    Set-SPOSite -Identity $site -RestrictContentOrgWideSearch $true
}

# Step 3: Confirm enrolment
Start-SPORestrictedContentDiscoverabilityReport
Start-Sleep -Seconds 30
Get-SPORestrictedContentDiscoverabilityReport

# Step 4: (Optional) Delegate to site admins with mandatory justification
Set-SPOTenant -DelegateRestrictedContentDiscoverabilityManagement $true
```

**Rollback:**
```powershell
foreach ($site in $highRiskSites) {
    Set-SPOSite -Identity $site -RestrictContentOrgWideSearch $false
}
# Note: removing RCD re-enrolls the site into search/Copilot discovery, subject to the same
# asynchronous index propagation delay as enabling it
```

</details>

<details><summary>Playbook 3 — Build a tenant-scale inactive site policy (simulation → active)</summary>

**In the SharePoint admin center** (Site Lifecycle Management has no PowerShell cmdlet for policy creation as of this writing — configuration is admin-center or bulk-CSV only):

1. Policies → Site lifecycle management → Inactive site policies → Create policy.
2. Scope: choose "sites at scale" or upload a CSV (up to 10,000 URLs, exported from the Active sites page, same-tenant domain only, no duplicates).
3. Configure: inactivity period, notify site owners and/or admins, up to 100 exclusion entries (individual users or groups — group exclusion only suppresses notification when the group is directly added to the site).
4. Choose enforcement: Do nothing / Read-only / Archive after a 3/6/9/12-month mandatory read-only period (requires Microsoft 365 Archive enabled).
5. Set policy mode to **Simulation** first — it runs once, generates a report, and must be deleted/recreated if it needs changes.
6. Validate the simulation report, then convert to **Active** mode (runs monthly).

**Verify via PowerShell (read-only, indirect signals — no direct policy cmdlet exists):**
```powershell
# Confirm current lock state as a proxy for enforcement having already occurred
Get-SPOSite -Identity "<site-url>" | Select-Object Url, LockState

# To reverse an enforcement action taken by this policy:
# Unlock via admin center: Active sites -> select site -> Unlock
# Reactivate an archived site via admin center: Archived sites -> select site -> Reactivate
```

**Rollback:** Delete the policy (simulation) or disable/adjust the active policy in the admin center; unlock/reactivate any sites already actioned as shown above. Note enforcement actions already taken (read-only/archive) are not automatically reversed by deleting the policy — sites must be unlocked/reactivated individually.

</details>

<details><summary>Playbook 4 — Generate a DAG site permissions report and initiate a remediation review</summary>

```powershell
Connect-SPOService -Url "https://<tenant>-admin.sharepoint.com"
# IMPORTANT: do not use -Credential — interactive/MFA sign-in only

# Step 1: Generate the org-wide permissions snapshot (SharePoint workload)
Start-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers -ReportType Snapshot `
    -Workload SharePoint -CountOfUsersMoreThan 0 -Name "OrgWidePermissionedUsersReport"

# Step 2: Poll for completion (first run: up to 5 days; subsequent: within 24h)
Get-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers

# Step 3: Download once completed
Export-SPODataAccessGovernanceInsight -ReportID "<report-guid-from-step-2>" `
    -DownloadPath "C:\Temp\DAGReports"

# Step 4: Review the CSV, identify an overshared site, and initiate a site access review
Start-SPOSiteReview -ReportID "<report-guid>" -SiteID "<site-guid-from-csv>" `
    -Comment "Flagged for broad EEEU access — please review and tighten permissions."

# Step 5: Track review completion
Get-SPOSiteReview -ReportEntity PermissionedUsers
```

**Rollback:** N/A — this playbook is read-only reporting plus a notification-based remediation workflow; no tenant configuration is changed. Respect the documented cap of 1,000 site access review initiations per calendar month from this report type.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects SharePoint Advanced Management (SAM) diagnostics for escalation
.PARAMETER TenantAdminUrl  SharePoint admin center URL
.PARAMETER SiteUrl         Optional specific site URL to inspect in detail
.NOTES     Read-only. Requires SharePoint Administrator or SharePoint Advanced Management
           Administrator role. Connect-SPOService must be used WITHOUT -Credential.
#>
param(
    [Parameter(Mandatory)][string]$TenantAdminUrl,
    [Parameter()][string]$SiteUrl
)

$outFile = "$env:TEMP\SAMDiag_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"

function Write-Section {
    param([string]$Title)
    "`n" + ("=" * 60) + "`n$Title`n" + ("=" * 60) | Tee-Object -FilePath $outFile -Append | Write-Host -ForegroundColor Cyan
}

"SharePoint Advanced Management Diagnostics — $(Get-Date)" | Tee-Object -FilePath $outFile | Write-Host

Connect-SPOService -Url $TenantAdminUrl

Write-Section "MODULE VERSION"
Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable |
    Select-Object Name, Version | Tee-Object -FilePath $outFile -Append | Format-Table

Write-Section "TENANT-LEVEL SAM SETTINGS"
Get-SPOTenant | Select-Object DelegateRestrictedAccessControlManagement,
    AllowSharingOutsideRestrictedAccessControlGroups, DelegateRestrictedContentDiscoverabilityManagement,
    RestrictedAccessControlForSitesErrorHelpLink | Tee-Object -FilePath $outFile -Append | Format-List

Write-Section "IDLE SESSION SIGN-OUT"
try {
    Get-SPOBrowserIdleSignOut | Tee-Object -FilePath $outFile -Append | Format-List
} catch {
    "Could not retrieve idle session sign-out settings: $_" | Tee-Object -FilePath $outFile -Append | Write-Warning
}

if ($SiteUrl) {
    Write-Section "SITE-LEVEL SAM SETTINGS — $SiteUrl"
    Get-SPOSite -Identity $SiteUrl |
        Select-Object Url, LockState, SharingCapability, RestrictedAccessControl,
        RestrictedAccessControlGroups, RestrictContentOrgWideSearch, Template |
        Tee-Object -FilePath $outFile -Append | Format-List
}

Write-Section "RECENT DAG REPORT STATUS"
try {
    Get-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers |
        Select-Object -First 5 | Tee-Object -FilePath $outFile -Append | Format-Table
} catch {
    "Could not retrieve DAG report status: $_" | Tee-Object -FilePath $outFile -Append | Write-Warning
}

Write-Host "`nDiagnostic file saved to: $outFile" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Check SPO module version | `Get-Module Microsoft.Online.SharePoint.PowerShell -ListAvailable` |
| Connect (no -Credential) | `Connect-SPOService -Url https://<tenant>-admin.sharepoint.com` |
| Enable tenant-level RAC | `Set-SPOTenant -EnableRestrictedAccessControl $true` |
| Delegate RAC to site admins | `Set-SPOTenant -DelegateRestrictedAccessControlManagement $true` |
| Restrict sharing outside RAC groups | `Set-SPOTenant -AllowSharingOutsideRestrictedAccessControlGroups $false` |
| Enable RAC on a site | `Set-SPOSite -Identity <url> -RestrictedAccessControl $true` |
| Add RAC group(s) | `Set-SPOSite -Identity <url> -AddRestrictedAccessControlGroups <guid,guid>` |
| View RAC state | `Get-SPOSite -Identity <url> \| Select RestrictedAccessControl, RestrictedAccessControlGroups` |
| Clear RAC from a site | `Set-SPOSite -Identity <url> -ClearRestrictedAccessControl` |
| Enable RCD on a site | `Set-SPOSite -Identity <url> -RestrictContentOrgWideSearch $true` |
| Check RCD insights report | `Start-SPORestrictedContentDiscoverabilityReport` / `Get-SPORestrictedContentDiscoverabilityReport` |
| Generate DAG snapshot report | `Start-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers -ReportType Snapshot -Workload SharePoint -CountOfUsersMoreThan 0 -Name <n>` |
| Track DAG report | `Get-SPODataAccessGovernanceInsight -ReportID <guid>` |
| Download DAG report | `Export-SPODataAccessGovernanceInsight -ReportID <guid> -DownloadPath <path>` |
| Enable audit collection (non-SAM tenant) | `Start-SPOAuditDataCollectionForActivityInsights -ReportEntity <entity>` |
| Initiate a site access review | `Start-SPOSiteReview -ReportID <guid> -SiteID <guid> -Comment <text>` |
| Check idle session sign-out | `Get-SPOBrowserIdleSignOut` |
| Set idle session sign-out | `Set-SPOBrowserIdleSignOut -Enabled $true -WarnAfter <span> -SignOutAfter <span>` |
| Check restricted site creation for apps | `Get-SPORestrictedSiteCreationForApps` |

---

## 🎓 Learning Pointers

- **SAM has no separate "service" to troubleshoot — it's a licence gate on existing SPO cmdlets.** Nearly all reported "SAM bugs" resolve to either the licensing/role check or the same kind of propagation delay every other tenant-wide SPO setting has. Confirm the exact error text before assuming a functional defect. See [Prerequisites for SharePoint Advanced Management](https://learn.microsoft.com/en-us/sharepoint/sharepoint-advanced-management-prerequisites).

- **RAC and RCD solve different problems and are frequently confused.** RAC changes who can *access* content (an authorization control, evaluated live on every open). RCD changes who can *find* content via search/Copilot (a discoverability control, propagated through the search index) without touching permissions at all. Choosing the wrong one for a given governance requirement is the most common design mistake. See [Restrict SharePoint site access with Microsoft 365 groups and Microsoft Entra security groups](https://learn.microsoft.com/en-us/sharepoint/restricted-access-control) and [Restrict discovery of SharePoint sites and content](https://learn.microsoft.com/en-us/sharepoint/restricted-content-discovery).

- **Activity detection for site lifecycle policies deliberately excludes app-token automation.** A site kept technically "active" only by a scheduled script running under an app-only token (or most PnP PowerShell user-token activity) will still be flagged inactive — this is intentional, to prevent automation from masking genuine abandonment. Build this into any automated site-keepalive assumptions. See [Manage inactive sites using inactive site policies](https://learn.microsoft.com/en-us/sharepoint/site-lifecycle-management).

- **DAG reports are asynchronous and rate-limited by design, not broken.** The first tenant-wide snapshot report always takes up to 5 days; each workload's snapshot report can only be regenerated once every 30 days; and site access review initiation from the site permissions report is capped at 1,000/month. Plan governance campaigns around these limits rather than fighting them. See [Manage Data access governance reports by using SharePoint Online PowerShell](https://learn.microsoft.com/en-us/sharepoint/powershell-for-data-access-governance).

- **Two licensing paths unlock overlapping-but-different feature sets.** A Copilot licence unlocks most SAM capability tenant-wide without a separate SAM purchase, but a small number of features (notably restricted site creation by apps, and advanced tenant renaming above 10,000 sites) require the dedicated SharePoint Advanced Management Plan 1 add-on regardless of Copilot licensing. Don't assume "we have Copilot" answers every SAM licensing question. See [SharePoint Advanced Management features in Microsoft 365 Copilot licenses](https://learn.microsoft.com/en-us/sharepoint/sharepoint-advanced-management-features-copilot-license).

- **Idle session sign-out is tenant-wide only — Conditional Access is the scoping tool.** Requests to vary sign-out timing by department, role, or site should be redirected to a Conditional Access session control (requiring Entra ID P1/P2), not this SharePoint-specific setting, which explicitly cannot be scoped below the tenant level. See [Sign out inactive users](https://learn.microsoft.com/en-us/sharepoint/sign-out-inactive-users).
