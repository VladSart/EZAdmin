# Windows 365 Reserve — Hotfix Runbook (Mode B: Ops)
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

Windows 365 Reserve provides up to **10 days of Cloud PC access per user per year** from any device when a user's physical device is unavailable (loss, theft, damage, shipping delay). It is a **standalone offering**, not a disaster-recovery add-on — if the ticket mentions "Cross-region Disaster Recovery" or "Disaster Recovery Plus," stop and redirect to `Flex-B.md`/`Windows365-B.md`; those are separate, Enterprise/Flex-only add-ons that Reserve explicitly does not include.

```powershell
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All"

# 1. Confirm the user actually has a Windows 365 Reserve license (Cloud PC Overview report is
#    the authoritative source — group membership alone is not enough, see Fix 3)
#    Portal: Intune admin center > Reports > Cloud PC Overview > Windows 365 Reserve licensing

# 2. Confirm license assignment date — Reserve has a mandatory 7-day activation delay
Get-MgUserLicenseDetail -UserId "<user-upn>" | Where-Object { $_.SkuPartNumber -like "*Windows_365_Reserve*" }
# (assignment TIMESTAMP is not exposed on this object — cross-check against the Reports blade
#  or Microsoft 365 admin center license history for exactly when it was assigned)

# 3. Confirm existing Reserve Cloud PC state for this user (one active Reserve PC at a time, max)
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.UserPrincipalName -eq "<user-upn>" -and $_.ServicePlanName -like "*Reserve*" } |
    Select-Object DisplayName, Status, ServicePlanName

# 4. Confirm the provisioning policy's geography (not country/region) covers where the user is
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object DisplayName, ManagedBy, MicrosoftManagedDesktop

# 5. Confirm the user isn't attempting Entra hybrid join, custom VNet, or a custom image —
#    none are supported by Reserve at all
```

| Result | Action |
|--------|--------|
| No Windows 365 Reserve license shown for the user in Cloud PC Overview | → [Fix 1 — License Not Assigned or Not Yet Eligible](#fix-1--license-not-assigned-or-not-yet-eligible) |
| License assigned, but provisioning fails/blocked and it's within 7 days of assignment | → [Fix 1 — License Not Assigned or Not Yet Eligible](#fix-1--license-not-assigned-or-not-yet-eligible) |
| User already has an active Reserve Cloud PC and a second provisioning attempt fails | → [Fix 2 — One Active Reserve Cloud PC Per User, Hard Limit](#fix-2--one-active-reserve-cloud-pc-per-user-hard-limit) |
| User is a member of the assigned group but doesn't appear under the provisioning policy's Cloud PC users | → [Fix 3 — User Missing from Provisioning Policy (First-Assigned-Policy-Wins)](#fix-3--user-missing-from-provisioning-policy-first-assigned-policy-wins) |
| User assumed disaster-recovery add-on behavior (guaranteed capacity, fast RTO) | → [Fix 4 — Reserve Is Not a Disaster-Recovery Add-On](#fix-4--reserve-is-not-a-disaster-recovery-add-on) |
| Provisioning fails during a regional outage / major incident with no capacity | → [Fix 5 — No Capacity Guarantee](#fix-5--no-capacity-guarantee) |
| User or admin deprovisioned and now says data is missing | → [Fix 6 — No Snapshot on Manual Deprovision](#fix-6--no-snapshot-on-manual-deprovision) |
| Bulk provisioning of many users at once is failing intermittently | → [Fix 7 — Bulk Provisioning Rate Limit](#fix-7--bulk-provisioning-rate-limit) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Windows 365, include the provisioning policy name and exact timestamp |

---
## Dependency Cascade

<details><summary>What must be true for a user to get a working Reserve Cloud PC</summary>

```
Windows 365 Reserve license assigned to the user
  └── 7-day activation delay elapses (first assignment, or after any coverage lapse — cannot
        be waited-out-and-assigned-just-in-time)
        └── User has NO other active Windows 365 Reserve Cloud PC
              (hard 1-per-user limit, even with multiple provisioning policies/spare licenses)
                └── Reserve provisioning policy assigned, geography (not country/region) selected
                      └── Capacity available in that geography at request time
                            (NOT pre-allocated — no guarantee, unlike Disaster Recovery Plus)
                              └── Cloud PC provisions: fixed 4 vCPU/16GB/128GB (or backup SKU
                                  if capacity-constrained), latest-3 Windows 11 gallery image
                                    └── User connects via Windows App / web from ANY device
                                        (managed or unmanaged) — no physical PC involved
                                          └── 10-day access clock running from provision time
                                                ├── Expires naturally → retention snapshot
                                                │     taken, THEN deprovisioned (data preserved)
                                                └── Admin/user manually deprovisions (Return)
                                                      → NO snapshot, NO grace period
                                                        (unbacked-up data is gone)
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm license and eligibility timing**
```
Intune admin center > Reports > Cloud PC Overview > Windows 365 Reserve licensing
```
Expected: The user appears with a license shown as available/assigned. Cross-check the assignment date against "today minus 7 days" — a user assigned today cannot provision until 7 days from now, full stop, regardless of urgency.

**Step 2 — Confirm no existing active Reserve Cloud PC**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.UserPrincipalName -eq "<user-upn>" -and $_.ServicePlanName -like "*Reserve*" }
```
Expected: Zero results, or one Cloud PC the user is actively trying to reuse. A second concurrent Reserve Cloud PC for the same user is never possible even if multiple provisioning policies exist and licenses are available.

**Step 3 — Confirm provisioning policy assignment and geography match**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId "<policy-id>"
```
Expected: The user's group is assigned, and the policy's configured geography (a broad region like "Europe" or "US Central/East/West," never a specific country) covers where the user needs to connect from.

**Step 4 — Confirm the request isn't relying on an unsupported capability**
```
Cross-check the ticket against the documented Not Supported list: Cloud PC/storage size
selection, FedRAMP/GCC, Entra hybrid join, Entra B2B, custom VNets/ANC, custom or Windows-10-
and-earlier images, country/region-level targeting, multiple concurrent Reserve Cloud PCs,
point-in-time snapshots/restore, disaster recovery add-ons, GPU-enabled Cloud PCs, and several
device actions (collect diagnostics, rename, resize, restore, sync, power off/on). If the
ticket is asking for any of these, this is an expectation-setting conversation, not a bug.
```

---
## Common Fix Paths

<details><summary>Fix 1 — License Not Assigned or Not Yet Eligible</summary>

**When:** No license shows for the user, or provisioning fails and the license was assigned fewer than 7 days ago.

```
Reserve deliberately does NOT support "assign the license the day it's needed" — a Cloud PC
only becomes eligible for provisioning 7 days after the FIRST license assignment (or after
any lapse in coverage). This is a planning requirement, not a fixable fault:

1. Confirm exact assignment date via Microsoft 365 admin center license history or the
   Cloud PC Overview report.
2. If within the 7-day window, there is no override — the only options are waiting it out
   or using an alternative interim solution (loaner device, standard Windows 365
   Enterprise/Flex Cloud PC if available).
3. For future incidents, recommend the client pre-assign Reserve licenses to their at-risk
   user population well ahead of any anticipated need — this is the single most important
   proactive step for this product.
```

**Rollback:** N/A — this is a fixed platform waiting period, not a configuration to undo.

</details>

<details><summary>Fix 2 — One Active Reserve Cloud PC Per User, Hard Limit</summary>

**When:** A user (or admin on their behalf) tries to provision a second Reserve Cloud PC while one is already active.

```powershell
# Confirm the existing active Reserve Cloud PC
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.UserPrincipalName -eq "<user-upn>" -and $_.ServicePlanName -like "*Reserve*" }

# The only path to a "new" Reserve Cloud PC is deprovisioning the existing one first —
# there is no concurrent-second-PC option regardless of license count or number of
# provisioning policies the user is assigned to.
```

**Fix:** Confirm with the user that their existing Reserve Cloud PC should be deprovisioned (Return, in Windows App, or admin-initiated) before a new one can be requested. Warn the user this is NOT a snapshot-protected action (see Fix 6) — confirm any needed data is backed up first.

**Rollback:** N/A — this is the documented, permanent per-user concurrency limit.

</details>

<details><summary>Fix 3 — User Missing from Provisioning Policy (First-Assigned-Policy-Wins)</summary>

**When:** A user is a member of the group assigned to a Reserve provisioning policy, but doesn't appear under that policy's Cloud PC users list.

```
Two independent causes, both diagnosable from the same report:

Cloud PC Overview > Windows 365 Reserve licensing report shows every user assigned to a
policy and/or license, and which policy each is actually linked to.

Cause A — Policy assignment precedence: a user only ever appears under the FIRST
provisioning policy assigned to them, even if they're in groups targeted by multiple
Reserve policies. Search the report for the user to find their actual primary policy link.

Cause B — Insufficient licenses: if "Available licenses in tenant" shows 0 in the report,
not every user in the assigned group received a license — purchase more Windows 365
Reserve licenses, or adjust policy/group assignments to free up unused ones.
```

**Rollback:** N/A — diagnostic/licensing correction, not a destructive change.

</details>

<details><summary>Fix 4 — Reserve Is Not a Disaster-Recovery Add-On</summary>

**When:** A stakeholder expects Reserve to behave like Windows 365 Cross-region Disaster Recovery or Disaster Recovery Plus — guaranteed capacity, fast RTO, full desktop image replication.

```
This is an expectation-setting conversation, not a technical fault. Reserve and the DR
add-ons solve genuinely different problems and are NOT interchangeable:

  Windows 365 Reserve:
    - Standalone product, works for ANY Windows 365 customer
    - Up to 10 days/user/year, one Reserve Cloud PC at a time
    - Fresh, generic Cloud PC (M365 apps + Intune policy) — NOT a copy of the user's
      original desktop or its local data
    - No capacity guarantee

  Windows 365 Cross-region Disaster Recovery / Disaster Recovery Plus:
    - Add-ons for Windows 365 Enterprise/Flex Cloud PCs ONLY — requires an existing
      provisioned Cloud PC to protect in the first place
    - Replicates that SPECIFIC Cloud PC's image to another region from its latest
      restore point
    - Disaster Recovery Plus pre-allocates capacity for ~30-minute RTO; standard
      cross-region recovery is ~4 hours
    - Explicitly listed as NOT supported for Reserve Cloud PCs

If the client's actual requirement is "recover this specific user's existing Cloud PC
desktop after a regional outage," Reserve is the wrong product — route to `Flex-A.md`/
`Windows365-A.md` disaster recovery coverage instead.
```

**Rollback:** N/A — this is a scoping clarification, not a change.

</details>

<details><summary>Fix 5 — No Capacity Guarantee</summary>

**When:** Provisioning fails or is delayed during a major outage or large-scale event, specifically when many users are requesting Reserve Cloud PCs simultaneously.

```
Documented, expected behavior: Windows 365 Reserve does NOT preallocate or guarantee
capacity in any geography. During major disruptions, availability may be materially
impacted by network connectivity, underlying Azure service health, or overall service
load — the exact moment Reserve is most needed is also when capacity risk is highest.

There is no admin-side override or capacity reservation mechanism for Reserve. The only
mitigation is operational: prioritize provisioning for the most critical users first when
performing multiple provisioning actions during an incident, and set client expectations
in advance that Reserve is best-effort during large-scale events, not a guaranteed-capacity
service like Disaster Recovery Plus.
```

**Rollback:** N/A — platform behavior, not a fault.

</details>

<details><summary>Fix 6 — No Snapshot on Manual Deprovision</summary>

**When:** A user or admin deprovisioned (Returned) a Reserve Cloud PC and now reports data loss.

```
This is expected, documented behavior, not a bug — but it's the single biggest data-loss
trap in this product:

  - Natural 10-day EXPIRY: the service takes a retention snapshot automatically before
    deprovisioning, minimizing data-loss risk.
  - Manual deprovision (admin action in Intune, OR user selecting "Return" in Windows App):
    NO snapshot is taken and there is NO grace period. All non-backed-up local Cloud PC
    data is deleted immediately and is NOT recoverable.

Both admin and user-initiated deprovisioning require a second consent/confirmation prompt
specifically because this action is irreversible — if the user clicked through it without
reading it, there is no recovery path afterward.
```

**Fix:** For future incidents, proactively instruct users to save work to OneDrive/SharePoint (not local Cloud PC storage) throughout their Reserve session, and to deprovision only once confirmed nothing local needs to survive.

**Rollback:** None available — this is unrecoverable data loss by design once deprovisioning completes.

</details>

<details><summary>Fix 7 — Bulk Provisioning Rate Limit</summary>

**When:** Provisioning many Reserve Cloud PCs at once (e.g., a simulated or real large-scale incident) results in some successes and some failures.

```
Documented limitation: bulk provisioning is capped at 100 devices per minute. Requesting
more than that in one batch (via Intune portal or PowerShell/Graph) starts all of them, but
some may fail and require a retry — this is an as-of-this-writing platform ceiling
Microsoft has stated they are working to resolve, not a tenant misconfiguration.

Fix: batch provisioning requests in groups of 100 or fewer, with a short delay between
batches, and re-run any failed requests individually. Prioritize the most critical users in
the first batch.
```

**Rollback:** N/A — retry-based fix, no destructive action taken.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== WINDOWS 365 RESERVE ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s): _______________
Tenant ID: _______________
Provisioning Policy Name: _______________
Policy Geography: _______________

SYMPTOM:
[ ] License not assigned / within 7-day activation delay
[ ] Second concurrent Reserve Cloud PC attempted (1-per-user limit)
[ ] User missing from provisioning policy Cloud PC users list
[ ] Disaster-recovery-add-on expectations mismatch
[ ] No capacity available (large-scale event)
[ ] Data loss after manual deprovision (no snapshot)
[ ] Bulk provisioning rate limit (>100/minute)
[ ] Other: _______________

TRIAGE RESULTS:
License assignment date (Cloud PC Overview report): _______________
Existing active Reserve Cloud PC for user (Y/N): _______________
Available licenses in tenant (per report): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID / Request ID: _______________
```

---
## 🎓 Learning Pointers

- **The 7-day activation delay is the #1 planning gotcha, and it inverts the intuitive workflow.** Most admins assume "assign the license when the incident happens" — Reserve requires the opposite: pre-assign licenses to at-risk users well before any incident, since day-of assignment guarantees a week of no access. Build this into any client's BCDR plan explicitly. Read: [Windows 365 Reserve FAQ](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-reserve-faq)
- **"Business continuity" in the name doesn't mean "guaranteed capacity."** Unlike Disaster Recovery Plus, which pre-allocates capacity for a ~30-minute RTO, Reserve provisions on-demand with zero guarantee — precisely when a regional outage makes demand spike is also when capacity is least certain. Set this expectation with clients before an incident, not during one.
- **Manual deprovision (Return) and natural 10-day expiry behave completely differently on data.** Expiry snapshots first; Return does not. This asymmetry is easy to miss until it causes a real data-loss ticket — train users explicitly that "Return" means immediate, unrecoverable deletion of anything not already in OneDrive/SharePoint.
- **A Reserve Cloud PC is not a copy of the user's PC.** It's a fresh, generically-provisioned desktop with corporate apps/policy from Intune — local data from the original device is never restored onto it. Set this expectation alongside the disaster-recovery-add-on distinction (Fix 4) to avoid a client assuming Reserve replaces proper backup/DR planning for endpoint data.
- **Policy-assignment precedence quietly hides users, and it looks like a licensing bug until you know the rule.** A user only shows under the FIRST Reserve provisioning policy assigned to them — always check the Cloud PC Overview report by username rather than assuming a missing entry means a missing license. Read: [Managing Windows 365 Reserve](https://learn.microsoft.com/en-us/windows-365/enterprise/windows-365-reserve-manage)
