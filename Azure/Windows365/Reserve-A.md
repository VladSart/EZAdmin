# Windows 365 Reserve — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the business-continuity model and its licensing constraints, not just the fix commands.

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

This runbook covers **Windows 365 Reserve** — a standalone Windows 365 offering providing short-term, on-demand Cloud PC access (up to 10 days per user per year) for users whose physical device is temporarily unavailable due to loss, theft, damage, shipping delay, or temporary staffing needs. Reserve reuses the same underlying Cloud PC provisioning pipeline, Intune management model, and AVD-based connection broker documented in `Windows365-A.md`, but layers a materially different licensing, capacity, and lifecycle model on top — this runbook covers only what's Reserve-specific.

Reserve is deliberately **not** a disaster-recovery add-on and shares no mechanism with **Windows 365 Cross-region Disaster Recovery** or **Windows 365 Disaster Recovery Plus** (both covered in `Flex-A.md`) beyond the general "business continuity" marketing category — those add-ons protect and fail over an *existing, already-provisioned* Enterprise/Flex Cloud PC image to another region; Reserve provisions a *fresh, generic* Cloud PC for a user with no Cloud PC of their own at all, and explicitly excludes disaster-recovery add-ons from its own feature set.

**Assumes:**
- Microsoft Graph PowerShell SDK (beta module): `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `CloudPC.ReadWrite.All`, `DeviceManagementConfiguration.Read.All` scopes
- Tenant already has standard Windows 365 Enterprise or Flex prerequisites in place (Reserve shares the same base licensing prerequisites, per Microsoft's own FAQ)
- Windows 365 Reserve licenses purchased separately — Reserve licenses cannot be pooled, shared, or substituted for Enterprise/Flex licenses

**Not covered:** Windows 365 Enterprise/Flex/Business provisioning pipeline and domain join models (see `Windows365-A.md`); Windows 365 Cross-region Disaster Recovery and Disaster Recovery Plus add-ons (see `Flex-A.md`); Windows 365 Cloud Apps (see `CloudApps-A.md` — not supported by Reserve at all).

---
## How It Works

<details><summary>Full architecture</summary>

### What Reserve actually is: a short-term access product, not a backup of the user's PC

Windows 365 Reserve provisions a **fresh, generically-configured Cloud PC** — preloaded with Microsoft 365 corporate apps, settings, and Intune-managed security policies — for a user whose physical device is temporarily unavailable. Critically, **a Reserve Cloud PC is not a copy or snapshot of the user's actual PC**: local data from the user's original device is never restored onto it. This distinguishes Reserve sharply from a physical loaner PC (which at least preserves the org's standard image but requires shipping logistics and hardware overhead) and from disaster-recovery add-ons (which replicate a *specific, already-existing* Cloud PC's image).

### The licensing and eligibility model — a deliberately front-loaded design

Reserve's licensing carries constraints that only make sense once understood as intentionally *anti-just-in-time*:

- **One license per user, no pooling.** Unlike Flex Shared mode (where licenses are pooled across a group), Reserve is strictly one license = one user = one Cloud PC, never shared or stacked.
- **A mandatory 7-day activation delay.** A user's Cloud PC only becomes eligible for provisioning starting 7 days after their license is *first* assigned — or after any lapse in license coverage. This delay cannot be bypassed by any admin action. The practical consequence: an organization cannot "wait until the incident happens" to assign Reserve licenses — the entire value proposition depends on licenses being pre-assigned to an at-risk population well in advance. This is the single most consequential design decision in the product for BCDR planning purposes.
- **10 days per user per year, non-shareable, non-extendable at GA.** The clock starts at provisioning and stops at deprovisioning. Days can't be pooled across users or extended/stacked once exhausted within a license term.
- **One active Reserve Cloud PC per user, always** — even if the user is targeted by multiple Reserve provisioning policies and licenses are available, only one Reserve Cloud PC can be active for a given user at any time.

### No capacity guarantee — the opposite of what "business continuity" implies

Reserve **does not preallocate or guarantee Cloud PC capacity** in any geography. If the configured geography has limited availability or a service health issue at the moment of a provisioning request, the Cloud PC simply may not provision until capacity frees up. This stands in direct architectural contrast to **Windows 365 Disaster Recovery Plus**, which exists specifically to pre-allocate capacity in an alternate region to guarantee a fast (~30-minute) RTO. Reserve's own FAQ acknowledges this directly: during major outages or large-scale events, availability "may be impacted by network connectivity, underlying service dependencies, or service load" — precisely the conditions under which Reserve is most likely to be needed. Microsoft's only documented mitigation is operational (prioritize critical users first during mass provisioning), not architectural.

### Fixed configuration, geography-only targeting

Reserve offers **zero configuration choice**: every Reserve Cloud PC provisions at a fixed 4 vCPU / 16 GB RAM / 128 GB storage spec (with backup SKUs substituted automatically if the primary spec is capacity-constrained), using the latest of the three most recent Windows 11 gallery images (with or without Microsoft 365 Apps, admin-selectable at the policy level). Provisioning policies select a **geography** (a broad region grouping like "Europe" or "US Central/East/West") rather than a specific country/region — a deliberate trade of provisioning precision for availability, since geography-level targeting lets the platform draw from a wider pool of available capacity across countries within that geography.

### The deprovisioning asymmetry — the product's sharpest data-loss trap

Two deprovisioning paths exist, and they behave very differently:

- **Natural 10-day expiry**: the service automatically takes a **retention snapshot** before deprovisioning, explicitly to minimize data-loss risk.
- **Manual deprovision** ("Return," available to both admins in Intune and users in the Windows App): **no snapshot is taken, and there is no grace period.** All non-backed-up local Cloud PC data is deleted immediately upon confirmation. Both paths require a second consent prompt specifically because of this asymmetry, but a user who doesn't read the prompt has no recovery path afterward.

Deprovisioning as soon as a Reserve Cloud PC is no longer needed is Microsoft's own documented guidance (it conserves remaining days of access within the license term) — which puts the very action that saves quota directly at odds with the action that protects data, unless users are trained to back up to OneDrive/SharePoint proactively throughout the session.

### Reporting and the first-assigned-policy-wins rule

A known limitation, not a bug: **a user only ever appears under the first Reserve provisioning policy assigned to them**, even if they belong to groups targeted by multiple Reserve policies. Combined with the fact that only *licensed* users show under a policy's Cloud PC users list at all, a user "missing" from where an admin expects them has exactly two possible causes — policy-assignment precedence, or insufficient licenses in the tenant — and Microsoft provides one dedicated report (Cloud PC Overview → Windows 365 Reserve licensing) purpose-built to distinguish between the two.

### Unsupported-by-design feature list — a long, explicit boundary

At GA, Reserve explicitly does **not** support: Cloud PC/storage size specification, FedRAMP or GCC environments, the Microsoft Remote Desktop or LG WebOS clients, Entra hybrid join, Entra B2B, Azure Network Connections/custom virtual networks, custom images or Windows 10-and-earlier gallery images, country/region-level provisioning precision, customer-managed keys, multiple concurrent Reserve Cloud PCs per user, point-in-time snapshots/restore, several device actions (collect diagnostics, rename, resize, restore, sync, full/quick scan, power off/on, troubleshoot, update Windows Defender), grace periods, Cloud Apps, Windows 365 Switch, third-party partner connectors (Citrix, Omnissa, HP Anyware), AI-powered recommendations, disaster recovery add-ons, GPU-enabled Cloud PCs, and several reporting categories (connection quality, utilization, agent health, recommendations). Two notable **supported** capabilities worth calling out because they're genuinely useful for BCDR/kiosk-adjacent scenarios: **Windows 365 Boot** (local device boots directly into the Reserve Cloud PC) and **Windows 365 Link** are both fully compatible.

### Bulk provisioning ceiling

A documented, current-generation limitation: bulk provisioning is capped at **100 devices per minute**. Requesting more in a single batch starts all of them, but some may fail and require individual retry — a real operational constraint during a genuine mass-incident response that admins should plan around (batched provisioning with prioritization) rather than assume is unlimited.

</details>

---
## Dependency Stack

```
Windows 365 Reserve license (standalone SKU, same base prerequisites as Enterprise/Flex)
  └── Assigned to user — starts the mandatory 7-day activation delay clock
        (cannot be bypassed; applies on first assignment AND after any coverage lapse)
          └── User has ZERO other active Reserve Cloud PC (hard 1-per-user limit,
                independent of license count or number of provisioning policies)
                └── Reserve provisioning policy — geography selection only (not country/region)
                      └── Capacity check at REQUEST TIME — NOT pre-allocated/guaranteed
                            (contrast: Disaster Recovery Plus DOES pre-allocate capacity)
                              └── Cloud PC provisions: fixed 4 vCPU/16GB/128GB (or backup SKU),
                                  latest-3 Windows 11 gallery image (M365 Apps optional)
                                    ├── Windows 365 Boot — compatible, boots straight into it
                                    ├── Windows 365 Link — compatible
                                    └── LOB app access — VPN/similar required (no ANC support)
                                          └── User connects from ANY device (Web, Windows,
                                              macOS, iOS, Android) — Windows App or web portal
                                                └── 10-day access clock (per user, per year)
                                                      ├── Natural expiry → retention snapshot
                                                      │     TAKEN → then deprovisioned
                                                      └── Manual deprovision (Return, admin
                                                          or user) → NO snapshot, NO grace
                                                          period, immediate data loss for
                                                          anything not backed up externally
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Provisioning blocked, license was assigned recently | Mandatory 7-day activation delay from first assignment (or a coverage lapse) — not bypassable | License assignment date vs. today's date |
| Second Reserve provisioning attempt fails for a user who already has one | Hard 1-active-Reserve-Cloud-PC-per-user limit, regardless of license count/policy count | Existing Cloud PC inventory filtered to `ServicePlanName -like "*Reserve*"` for that user |
| User in the assigned group but missing from a policy's Cloud PC users list | Either first-assigned-policy-wins precedence (user is linked elsewhere), or zero remaining licenses in the tenant | Cloud PC Overview → Windows 365 Reserve licensing report, search by user |
| Client expects guaranteed fast recovery / pre-allocated capacity | Confusing Reserve with Disaster Recovery Plus — architecturally unrelated products | Whether the actual requirement is "cover a user with no Cloud PC" (Reserve) vs. "recover an existing Cloud PC's image" (DR add-ons, see `Flex-A.md`) |
| Provisioning fails/slow specifically during a regional outage | No capacity pre-allocation — documented, expected during large-scale events | Service health status for the target geography; whether provisioning requests are being prioritized for critical users first |
| Data missing after a user "Returned" their Cloud PC | Manual deprovision takes no snapshot and has no grace period, unlike natural 10-day expiry | Whether deprovision was manual (Return) vs. automatic expiry |
| Request for custom image, hybrid join, B2B, custom VNet, GPU, or a specific country | Explicitly unsupported-by-design feature | Cross-check against the documented Not Supported list |
| Bulk provisioning of many users partially fails | 100-devices-per-minute platform ceiling | Batch size and timing of the provisioning request |
| A device action (rename, resize, restore, diagnostics collection) is unavailable in the portal | Explicitly unsupported device action for Reserve, unlike Enterprise/Flex Cloud PCs | Cross-check against the Not Supported device-actions list |

---
## Validation Steps

**1. Confirm Graph connection and required scopes**
```powershell
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: Both scopes present.

**2. Confirm license assignment and 7-day eligibility window**
```
Portal only for assignment timestamp: Microsoft 365 admin center > Billing > Licenses >
Windows 365 Reserve, or Intune admin center > Reports > Cloud PC Overview > Windows 365
Reserve licensing. No Graph property exposes the assignment timestamp directly on the
license detail object.
```
Expected: License assigned at least 7 days ago for a first-time or post-lapse assignment.

**3. Confirm no existing active Reserve Cloud PC for the user**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.UserPrincipalName -eq "<user-upn>" -and $_.ServicePlanName -like "*Reserve*" } |
    Select-Object DisplayName, Status, ServicePlanName
```
Expected: No results if the user genuinely needs a new provision; if the ticket is about the existing PC, results show its current status.

**4. Confirm provisioning policy geography and assignment**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object DisplayName, Id
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId "<policy-id>"
```
Expected: The user's group is assigned, and the geography configured on the policy realistically covers where the user needs service.

**5. Confirm the request doesn't rely on an unsupported capability**
```
Cross-check against the Scope & Assumptions "Not covered" list and the full unsupported-
feature list in How It Works before spending further diagnostic time.
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Licensing & Eligibility

1. Confirm the user has a Windows 365 Reserve license via the Cloud PC Overview report
2. Confirm the 7-day activation delay has elapsed since first assignment (or since any coverage lapse)
3. If within the delay window, this is not fixable — plan around it, don't escalate as a bug

### Phase 2: Concurrency

1. Confirm the user has no other active Reserve Cloud PC
2. If one exists and a new one is genuinely needed, confirm with the user/stakeholder that deprovisioning the old one (data-loss risk per Phase 4) is acceptable before proceeding

### Phase 3: Policy & Capacity

1. Confirm provisioning policy assignment and geography coverage
2. If provisioning is failing during a known outage/large-scale event, treat as expected best-effort behavior — prioritize critical users, don't assume a fault exists

### Phase 4: Deprovisioning & Data

1. Before any deprovision (manual or otherwise), confirm the user has saved anything needed to OneDrive/SharePoint
2. If data loss is already reported, confirm whether the deprovision was manual (no recovery possible) or natural expiry (retention snapshot may exist — engage Microsoft Support to check)

### Phase 5: Feature Expectations

1. Cross-check any "why can't I do X" ticket against the documented unsupported-feature list before treating it as a defect
2. For disaster-recovery-shaped requests specifically, redirect to `Flex-A.md`'s Cross-region Disaster Recovery / Disaster Recovery Plus coverage

---
## Remediation Playbooks

<details><summary>Playbook 1 — Proactive Reserve Rollout for BCDR Readiness</summary>

Use when: Standing up Reserve ahead of time for an at-risk user population (the only way to make Reserve actually useful during a real incident, given the 7-day delay).

```powershell
# Step 1: Identify the at-risk population and purchase one Windows 365 Reserve license
# per user (no pooling — plan headcount exactly).

# Step 2: Create the Reserve provisioning policy with an appropriate geography
$body = @{
    "@odata.type" = "#microsoft.graph.cloudPcProvisioningPolicy"
    displayName   = "<Reserve-Policy-Name>"
    description   = "Windows 365 Reserve — BCDR standby"
    # Reserve-specific service plan targeting is configured via the assignment, not the
    # policy body itself, in current Graph beta implementations — confirm exact schema
    # against the current beta metadata before scripting broadly, since this is a newer
    # product surface still evolving.
}
$policy = New-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -BodyParameter $body

# Step 3: Assign the policy to the target group, geography-scoped, not country-scoped.

# Step 4: Assign Reserve licenses to all in-scope users NOW, not when an incident occurs —
# start the 7-day eligibility clock immediately so licenses are actually usable if needed.

# Step 5: Communicate to the user population: Reserve Cloud PCs are fresh/generic (not a
# copy of their PC), 10-day/year cap, and "Return" deletes unsaved local data immediately.

# Step 6: Periodically re-verify eligibility (Cloud PC Overview report) as part of a
# standing DR-readiness check, since coverage lapses (e.g., license removed and
# re-added) reset the 7-day clock.
```

**Rollback:** Unassign Reserve licenses to stop the offering for a user population; already-eligible users lose access on next license cycle, no destructive action against existing data.

</details>

<details><summary>Playbook 2 — Incident-Time Mass Provisioning</summary>

Use when: An actual incident has occurred and multiple pre-licensed users need Reserve Cloud PCs provisioned now.

```
Step 1: Confirm which affected users are already past their 7-day eligibility window
        (Cloud PC Overview report) — only these can be provisioned immediately.

Step 2: Prioritize the most business-critical users first, per Microsoft's own guidance,
        since capacity is not guaranteed during large-scale events.

Step 3: Batch provisioning requests in groups of 100 or fewer to respect the documented
        bulk-provisioning rate limit; stagger batches with a short delay.

Step 4: Monitor Intune admin alerts for provisioning/deprovisioning failures and retry
        failed individual requests rather than re-submitting the full batch.

Step 5: Communicate to users as they come online: this is a fresh Cloud PC with corporate
        apps/policy, not a restore of their original device — set expectations before
        they start looking for local files that were never there.
```

**Rollback:** N/A — this is incident response, not a reversible configuration change.

</details>

<details><summary>Playbook 3 — Safe Deprovisioning</summary>

Use when: A Reserve Cloud PC is no longer needed and should be returned to conserve remaining annual days.

```
Step 1: Confirm with the user that all needed data has been saved to OneDrive/SharePoint
        or otherwise exported off the Cloud PC — there is NO snapshot on manual deprovision.

Step 2: Have the user select Return in Windows App, or an admin deprovision from Intune.
        Both require a second confirmation prompt — make sure whoever clicks through it
        understands this step is irreversible.

Step 3: Confirm deprovisioning completed via Cloud PC status (should no longer appear as
        an active Reserve Cloud PC for the user).

Step 4: Note remaining annual day balance for the user if tracking BCDR readiness at a
        population level (no direct Graph property for remaining-days-in-term as of this
        writing — track via provisioning/deprovisioning event history if precise tracking
        is required).
```

**Rollback:** None — deprovisioning (manual path) is a one-way action with no data recovery available afterward.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows 365 Reserve diagnostic evidence for a specific user or tenant-wide
.NOTES     Requires Microsoft.Graph.Beta module and CloudPC.Read.All scope
#>

param(
    [string]$UserPrincipalName
)

$outputPath = "C:\W365Reserve_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$allCloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ServicePlanName -like "*Reserve*" }

if ($UserPrincipalName) {
    $allCloudPcs = $allCloudPcs | Where-Object { $_.UserPrincipalName -eq $UserPrincipalName }
}

$allCloudPcs | Select-Object DisplayName, UserPrincipalName, Status, ServicePlanName, ProvisioningPolicyId |
    Export-Csv "$outputPath\reserve_cloudpcs.csv" -NoTypeInformation

Write-Host "NOTE: License assignment timestamp (needed to evaluate the 7-day eligibility" -ForegroundColor Yellow
Write-Host "delay) is not exposed via this Graph object. Capture a screenshot of Intune" -ForegroundColor Yellow
Write-Host "admin center -> Reports -> Cloud PC Overview -> Windows 365 Reserve licensing" -ForegroundColor Yellow
Write-Host "and attach it alongside this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# List all active Reserve Cloud PCs tenant-wide
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All | Where-Object { $_.ServicePlanName -like "*Reserve*" }

# Reserve Cloud PC(s) for a specific user
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.UserPrincipalName -eq "<upn>" -and $_.ServicePlanName -like "*Reserve*" }

# Reserve provisioning policy detail
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<name>'"

# Policy assignment (group targeting)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId "<id>"

# User's Windows 365 Reserve license detail (assignment timestamp NOT included — portal only)
Get-MgUserLicenseDetail -UserId "<upn>" | Where-Object { $_.SkuPartNumber -like "*Windows_365_Reserve*" }

# NOT available via Graph as of this writing — portal only:
#   - License assignment timestamp (needed for 7-day eligibility calculation)
#   - Cloud PC Overview / Windows 365 Reserve licensing report (first-assigned-policy-wins view)
#   - Remaining annual day balance for a user's 10-day allotment
```

---
## 🎓 Learning Pointers

- **The 7-day activation delay is the product's central design constraint, and it means Reserve only works if planned for in advance.** Any client treating Reserve as an at-the-moment-of-incident purchase decision has misunderstood the product entirely — this needs to be surfaced during initial BCDR planning conversations, not discovered during an actual outage. Read: [Windows 365 Reserve FAQ](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-reserve-faq)
- **Reserve and the Disaster Recovery add-ons solve different problems and share no mechanism** — Reserve provisions a fresh Cloud PC for a user with none; the DR add-ons fail over an existing Cloud PC's actual image to another region. Conflating them during a sales or planning conversation sets the wrong expectations for both. See `Flex-A.md` for the DR add-ons.
- **"Business continuity" doesn't imply capacity guarantees here** — that's specifically what Disaster Recovery Plus adds on top of standard Cloud PC provisioning, and Reserve explicitly excludes it. Reserve is best-effort by design, most acutely during the exact large-scale events it's marketed to help with.
- **The manual-deprovision-has-no-snapshot behavior is the sharpest edge in this product** — train users explicitly, since the platform's own guidance to "deprovision promptly to conserve days" is in direct tension with data safety unless external backup habits are already in place.
- **First-assigned-policy-wins is a silent precedence rule with no error message** — a user "missing" from a provisioning policy's Cloud PC users list is never actually missing; they're linked elsewhere or unlicensed, and the Cloud PC Overview report is the only tool that disambiguates the two. Read: [Managing Windows 365 Reserve](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-reserve-manage)
