# Apple Business Token Renewal — Reference Runbook (Mode A: Deep Dive)
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

- **Scope:** The Apple Business (ABM) / Apple School Manager (ASM) **server token** that Intune uses to (1) sync ADE/DEP device assignments and (2) manage VPP app licensing.
- **Explicitly out of scope:** The APNs push certificate — a separate, differently-scoped credential covered in `MDM-Certificate-Renewal-A.md`. This document assumes you have already ruled out APNs cert expiry as the cause (existing enrolled devices still check in normally).
- **Platforms:** macOS and iOS/iPadOS devices enrolled via ADE under the same ABM/ASM organization.
- **Admin access required:** ABM/ASM Administrator or a user with **MDM Server Assignment** permission in business.apple.com; Intune Global Administrator or Intune Administrator role.
- **Not covered:** ABM/ASM tenant setup from scratch, DEP profile design, or VPP purchasing workflows — see Apple's ABM onboarding documentation for those.

---

## How It Works

<details><summary>Full architecture</summary>

### What the token actually is

The ABM/ASM server token is a `.p7m` file — a PKCS#7 signed message containing a public key and metadata that cryptographically links a specific **MDM server entry** inside Apple Business to your **Intune tenant**. It is not a certificate in the X.509 sense used by APNs; it's an authorization artifact that lets Intune poll Apple's Device Enrollment Program (DEP) API on your organization's behalf.

```
Apple Business (business.apple.com)
        │
        │  Organization admin creates/manages an "MDM Server" entry
        │  (e.g., "Contoso Intune Production")
        ▼
Server Token generated (.p7m, contains public key + org identifier)
   Valid for 1 year from generation date
        │
        ▼
Token uploaded to Intune
   (Devices > Enrollment > Apple > Enrollment Program Tokens > Add)
        │
        ▼
Intune uses the token to authenticate to Apple's DEP/ABM API
   (https://deviceenrollment.apple.com and related endpoints)
```

### Two independent functions sharing one trust relationship

Once uploaded, the token backs **two logically separate but co-located functions**:

1. **Device enrollment sync (ADE/DEP)** — Intune polls Apple roughly every 15 minutes for devices that have been assigned to this MDM server entry in ABM. New devices purchased through Apple (or a reseller participating in ABM) appear automatically once assigned.

2. **VPP (Volume Purchase Program) app licensing** — a separate token type, managed in the same ABM/ASM portal, that authorizes Intune to assign and revoke app licenses purchased in bulk. Depending on how the org was originally configured, VPP may use the **same** server token entry or a **distinct** VPP-specific token (`Tenant administration > Connectors and tokens > Apple VPP Tokens`).

```
                     ┌─────────────────────────┐
                     │  Apple Business │
                     │  Organization Account   │
                     └────────────┬────────────┘
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
   MDM Server Assignment                      VPP Token (Content Tokens)
   (device enrollment token)                  (app licensing token)
              │                                       │
              ▼                                       ▼
   Intune: Enrollment Program Tokens          Intune: Apple VPP Tokens
   (Devices > Enrollment > Apple)             (Tenant admin > Connectors)
              │                                       │
              ▼                                       ▼
   Device sync every ~15 min                  License sync/assignment
   New devices appear for                     App install status per
   enrollment profile assignment              device/user
```

### Why this is a full-tenant risk, not a per-device issue

Unlike a device certificate that only affects one machine, the ABM server token is a **tenant-wide trust relationship**. If it lapses:
- No new devices sync from ABM — Autopilot-style zero-touch provisioning silently stops for any newly purchased or reset device
- VPP app assignments already delivered keep working (licenses already granted persist), but new assignments and revocations fail
- Devices already enrolled and checking in via APNs are **completely unaffected** — this is the key differentiator from an APNs cert outage, and the most common cause of misdiagnosis under time pressure

### Token lifecycle and Apple's silent-expiry behavior

Apple does **not** send a push notification or webhook to Intune when a token is about to expire. Intune's UI surfaces the expiry date passively (visible only if an admin checks the Enrollment Program Tokens blade). There is no automated alert unless the MSP has built one via Graph API polling (see Evidence Pack script below) or Azure Monitor / Log Analytics alerting on Intune diagnostic data.

</details>

---

## Dependency Stack

```
Apple ID (organizational role account, not personal)
        │
        ▼
Apple Business / Apple School Manager organization
        │
        ├── MDM Server Assignment entry (1:1 with Intune tenant, usually)
        │        │
        │        ▼
        │   Server Token (.p7m) — 1 year validity
        │        │
        │        ▼
        │   Intune: Enrollment Program Tokens
        │   (Devices > Enrollment > Apple)
        │        │
        │        ├──▶ ADE/DEP device sync (~15 min poll interval)
        │        │        │
        │        │        ▼
        │        │   Enrollment Profile assignment
        │        │        │
        │        │        ▼
        │        │   Device auto-enrolls on first boot / Setup Assistant
        │        │
        │        └──▶ (if VPP shares this token) License assignment
        │
        └── VPP Content Token (may be separate entry)
                 │
                 ▼
            Intune: Apple VPP Tokens
            (Tenant administration > Connectors and tokens)
                 │
                 ▼
            App license pool → assignment to users/devices
                 │
                 ▼
            Company Portal / Managed App install
```

**Critical dependency not to overlook:** the Apple ID used to originally create the MDM Server Assignment entry does **not** need to be preserved for renewal (unlike APNs), but the ABM/ASM **organization account itself** must remain active and someone in the org must retain Administrator or "People Manager with MDM Server Assignment" access — otherwise nobody can generate a new token at all, and Apple's account recovery process for ABM/ASM organizations is not fast.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New/reset devices never appear in Intune's Enrollment Program Tokens device list | ABM server token expired or expiring | Intune > Devices > Enrollment > Apple > Enrollment Program Tokens > expiry date |
| Existing enrolled devices check in fine; only new devices affected | Confirms ABM token issue, not APNs | Compare device counts (see Validation Step 3) |
| VPP app install status stuck at "Not Installed" for newly assigned apps | VPP token expired/invalid (may be separate from device token) | Intune > Apps > Policies > App licenses; check token status |
| Sync error explicitly states "token invalid" or "unauthorized" | Token was revoked, deleted from ABM, or a stale/wrong file was uploaded | business.apple.com > Preferences > MDM Server Assignment — confirm entry exists |
| Device count in Intune is lower than ABM's assigned count and the gap is growing | Token nearing expiry, sync degrading before hard failure | Build a routine comparison — see Evidence Pack script |
| MDM Server Assignment entry itself is missing from ABM | Entry deleted by another admin, or org restructuring in ABM | Escalate — this requires Apple support for bulk device reassignment |
| Renewal uploaded but sync still fails | Used "Add" instead of "Renew" in Intune, creating an orphaned duplicate entry | Intune > Enrollment Program Tokens — check for duplicate token entries |
| Token shows valid in Intune but ABM shows a different/newer token was generated | Someone else in the org regenerated the token without coordinating | Confirm only one token was downloaded and uploaded; re-sync |

---

## Validation Steps

**1. Confirm token expiry state in Intune**
```
Intune admin center > Devices > Enrollment > Apple > Enrollment Program Tokens
```
Expected "good": Expiry date is more than 30 days out.
"Bad": Expiry date is within 30 days, or already in the past (shown in red/warning state by Intune's UI).

---

**2. Confirm the ABM organization side matches**
```
business.apple.com > Preferences > MDM Server Assignment > [server entry name]
```
Expected "good": Entry exists, token generation date is recent (within the last year), and the entry name matches what's referenced in Intune.
"Bad": Entry missing entirely, or shows a token generated more recently than what's uploaded to Intune (someone regenerated it elsewhere).

---

**3. Compare device counts between ABM and Intune**
```
ABM: Devices tab, filter by "Assigned to: [your MDM server name]" — note total count
Intune: Enrollment Program Tokens > [token] > Devices tab — note total count
```
Expected "good": Counts match (small variance acceptable for devices mid-transit or newly purchased in the last 15 minutes).
"Bad": A persistent, growing gap — Intune count meaningfully lower than ABM count and not closing on repeated checks. This is often the **earliest** signal of degradation, appearing before the token's hard expiry.

---

**4. Confirm existing device check-ins are unaffected (rules out APNs)**
```
Intune admin center > Devices > All devices > filter by platform macOS/iOS
Sort by "Last check-in" — spot-check several devices
```
Expected "good": Recent check-in timestamps (within the last several hours), confirming APNs is healthy and the issue is isolated to ABM/ADE sync.
"Bad": Widespread stale check-ins across the fleet — this points to APNs cert expiry instead; pivot to `MDM-Certificate-Renewal-A.md`.

---

**5. Check VPP token status independently**
```
Intune admin center > Apps > Policies > App licenses
(or Tenant administration > Connectors and tokens > Apple VPP Tokens, depending on Intune UI version)
```
Expected "good": Token status shows "Active", license counts populate correctly.
"Bad": Status shows "Invalid" or "Expired", or license counts show as zero/unavailable despite known purchased licenses.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm scope of impact
1. Check Intune Enrollment Program Tokens expiry (Validation Step 1)
2. Check whether existing devices are checking in normally (Validation Step 4) — this determines whether you're dealing with ABM token expiry alone or a combined APNs + ABM outage
3. Determine whether VPP licensing is affected independently (Validation Step 5) — VPP may use a different token than device sync

### Phase 2 — Confirm ABM organization-side state
1. Log into business.apple.com with an account that has **MDM Server Assignment** access
2. Navigate to Preferences > MDM Server Assignment
3. Confirm the entry corresponding to your Intune tenant still exists
4. Note the token's last-generated date shown in ABM (if visible) — compare against what's in Intune

### Phase 3 — Renew and re-upload
1. In business.apple.com, select the MDM Server Assignment entry, click **Download Token**
2. In Intune, navigate to the existing Enrollment Program Tokens entry — **do not click Add**
3. Click **Renew Token** on the existing entry, upload the new `.p7m` file
4. Confirm the new expiry date reflects ~1 year from today

### Phase 4 — Force sync and validate
1. In Intune, trigger a manual sync on the renewed token entry
2. Wait 15-30 minutes for the DEP poll cycle to complete
3. Re-run the device count comparison (Validation Step 3) — the gap should close
4. Confirm any devices that were pending assignment now appear and pick up their enrollment profile

### Phase 5 — VPP-specific remediation (if affected independently)
1. Identify whether VPP uses the same token entry or a separate one (Tenant administration > Connectors and tokens)
2. If separate, repeat the download/renew/upload cycle for the VPP token specifically
3. Validate by checking install status on a test app assignment — should progress from "Not Installed" to "Installing" within one sync cycle

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full token renewal (device sync + VPP combined)</summary>

**Scenario:** Single ABM server token backs both device sync and VPP; token is expired or expiring.

1. business.apple.com > Preferences > MDM Server Assignment > [entry] > **Download Token**
2. Intune > Devices > Enrollment > Apple > Enrollment Program Tokens > select existing entry > **Renew Token**
3. Upload the downloaded `.p7m`
4. Force sync:
```
Intune portal > Devices > Enrollment > Apple > Enrollment Program Tokens > [token] > Sync
```
5. Validate device count parity (Validation Step 3) after 15-30 minutes
6. Validate VPP app install progression on one test assignment

**Rollback:** Not applicable — renewal is additive and does not disturb existing device-to-profile assignments when done via "Renew" (not "Add").

</details>

<details><summary>Playbook 2 — Recovering from an accidental "Add" instead of "Renew"</summary>

**Scenario:** An admin uploaded a new token using **Add** rather than **Renew**, creating a second, unlinked Enrollment Program Tokens entry. Devices previously assigned under the old token are no longer syncing correctly, and enrollment profile assignments appear to have vanished for some devices.

```
1. Intune > Devices > Enrollment > Apple > Enrollment Program Tokens
   → Identify both entries (old token, near/past expiry; new token, freshly added)

2. Note which enrollment profiles and device groups were assigned under the OLD token entry
   (Enrollment Program Tokens > [old token] > Profiles tab)

3. Re-create the same enrollment profile assignments under the NEW token entry
   (Enrollment Program Tokens > [new token] > Profiles > Assign)

4. Once assignments are confirmed correct on the new token entry, delete the OLD token entry
   → This is safe only after confirming profile assignments were replicated —
     deleting first would orphan any devices still referencing the old entry

5. Force a sync on the new (now sole) token entry and validate device counts
```

**Rollback:** If profile reassignment causes unexpected re-provisioning prompts on already-enrolled devices, the enrollment profile itself was likely misconfigured during recreation — review profile settings against the original before re-assigning.

</details>

<details><summary>Playbook 3 — MDM Server Assignment entry deleted from ABM (major incident)</summary>

**Scenario:** The MDM Server Assignment entry itself no longer exists in business.apple.com — not just an expired token, but the entry that ties devices to your MDM server is gone. All devices under that entry are now orphaned from an ABM perspective.

```
1. Confirm the entry is genuinely gone (not just renamed) —
   check ABM audit history if available, or with other ABM administrators

2. This requires creating a NEW MDM Server Assignment entry in ABM:
   business.apple.com > Preferences > MDM Server Assignment > Add

3. Generate and download a token for the new entry

4. In Intune, this cannot use "Renew" (there is no valid prior linked entry) —
   must Add as a new Enrollment Program Tokens entry

5. CRITICAL: device-to-server assignment in ABM must be redone.
   In business.apple.com > Devices, bulk-select affected devices,
   assign them to the newly created MDM Server entry

6. For large device counts, this bulk reassignment may need to be done via
   Apple's DEP API directly or may require Apple Business support
   if the device count is large enough that manual reassignment isn't practical

7. Once devices are reassigned in ABM, allow the new token's sync cycle
   to pick them up in Intune (15-30 min), then verify enrollment profile
   assignment still triggers correctly on next device check-in/reset
```

**Rollback:** Not applicable — this is an organizational recovery path. Document thoroughly and treat as a P1/P2 incident given fleet-wide scope.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Apple Enrollment Program Token health and device-count parity evidence.
.DESCRIPTION Queries Graph API for Apple Enrollment Program Token expiry, sync status, and
             device counts to support escalation or proactive monitoring. Read-only.
.NOTES       Requires: Microsoft.Graph.Authentication module, DeviceManagementServiceConfig.Read.All scope.
             Run: Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$outputDir = "$env:TEMP\ABM-Token-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# 1. Enrollment Program Tokens — expiry and basic metadata
$tokens = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/depOnboardingSettings" `
    -OutputType PSObject

$tokens.value | Select-Object @{N='TokenName';E={$_.tokenName}},
    @{N='AppleIdentifier';E={$_.appleIdentifier}},
    @{N='TokenExpirationDateTime';E={$_.tokenExpirationDateTime}},
    @{N='LastSyncDateTime';E={$_.lastSyncDateTime}},
    @{N='LastSyncErrorCode';E={$_.lastSyncErrorCode}},
    @{N='SyncedDeviceCount';E={$_.syncedDeviceCount}},
    @{N='EnrollmentProfileCount';E={$_.enrollmentProfileCount}} |
    Export-Csv "$outputDir\enrollment-program-tokens.csv" -NoTypeInformation

Write-Host "[OK] Token metadata exported."

# 2. Days-to-expiry calculation with warning flags
$tokenHealth = $tokens.value | ForEach-Object {
    $expiry = [datetime]$_.tokenExpirationDateTime
    $daysLeft = ($expiry - (Get-Date)).Days
    [PSCustomObject]@{
        TokenName    = $_.tokenName
        ExpiryDate   = $expiry
        DaysUntilExpiry = $daysLeft
        Status       = if ($daysLeft -lt 0) { "EXPIRED" }
                       elseif ($daysLeft -le 30) { "WARN - RENEW SOON" }
                       else { "OK" }
        LastSyncError = $_.lastSyncErrorCode
    }
}
$tokenHealth | Export-Csv "$outputDir\token-expiry-health.csv" -NoTypeInformation
$tokenHealth | Format-Table -AutoSize

# 3. Managed device counts by platform (for comparison against ABM's assigned count)
$devices = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS' or operatingSystem eq 'iOS'&`$select=deviceName,operatingSystem,enrolledDateTime,managementAgent" `
    -OutputType PSObject

$appleDeviceCount = $devices.value.Count
Write-Host "[INFO] Apple devices currently managed in Intune: $appleDeviceCount"
"Apple devices in Intune: $appleDeviceCount" | Out-File "$outputDir\device-count-intune.txt"

Write-Host "`n[OK] Evidence collected to: $outputDir"
Write-Host "Manually record the equivalent count from business.apple.com > Devices (filtered by MDM server) to complete the parity check."
```

---

## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check token expiry | Intune > Devices > Enrollment > Apple > Enrollment Program Tokens |
| Renew token (preserve assignments) | Select token entry > **Renew Token** (never Add) |
| Force device sync | Enrollment Program Tokens > [token] > **Sync** |
| Check MDM Server Assignment (ABM side) | business.apple.com > Preferences > MDM Server Assignment |
| Check VPP token status | Intune > Apps > Policies > App licenses (or Tenant admin > Connectors and tokens) |
| Compare device counts (ABM) | business.apple.com > Devices, filter by assigned MDM server |
| Compare device counts (Intune) | Enrollment Program Tokens > [token] > Devices tab |
| Query token health via Graph | `GET /deviceManagement/depOnboardingSettings` |
| Query managed Apple devices via Graph | `GET /deviceManagement/managedDevices?$filter=operatingSystem eq 'macOS'` |
| Confirm existing device check-ins (rule out APNs) | Devices > All devices > sort by Last check-in |

---

## 🎓 Learning Pointers

- **This token is a tenant-wide trust artifact, not a per-device credential — treat its expiry monitoring like you would a domain-wide certificate, not a single machine's issue.** A single missed renewal silently breaks zero-touch provisioning for every new or reset device in the organization while leaving the existing fleet completely unaffected, which is exactly what makes it easy to miss until someone tries to deploy new hardware. [MS Docs: Enrollment Program Tokens](https://learn.microsoft.com/en-us/mem/intune/enrollment/device-enrollment-program-enroll-ios)

- **Apple provides no proactive expiry notification for this token — build your own via the Graph API `depOnboardingSettings` endpoint.** The Evidence Pack script above can be scheduled (e.g., as a weekly Azure Automation runbook or scheduled task) to alert 30-60 days before expiry, closing the gap Apple's tooling leaves open.

- **"Renew" vs "Add" is the single most consequential decision in this whole workflow.** Renew preserves the link between the token and every enrollment profile assignment built on top of it. Add creates a parallel, disconnected entry that requires manually rebuilding every profile assignment — turning a five-minute renewal into a multi-hour cleanup, especially at scale. Always default to Renew unless you have positively confirmed the original entry is unrecoverable.

- **Device count parity between Apple Business and Intune is a leading indicator, not a lagging one.** Sync degradation (partial failures, API throttling, or an in-progress token issue) tends to show up as a growing but non-total device count gap days before the token's hard expiry date. Build this comparison into routine health checks rather than only reacting to expiry-date warnings in Intune's UI.

- **VPP and device-sync tokens are logically separate even when they share the same underlying ABM entry — diagnose them independently.** A client can report "new Macs aren't showing up" while VPP licensing is completely healthy, or vice versa. Don't assume fixing one resolves the other; validate both explicitly (Validation Steps 3 and 5).

- **ABM/ASM organization access should never be tied to a single individual's Apple ID.** Because token renewal requires "MDM Server Assignment" permission in the ABM/ASM portal, losing every admin who has that access effectively locks the org out of provisioning new devices, and Apple's account recovery for business accounts is a multi-day process at best. Cross-reference this with `MDM-Certificate-Renewal-A.md`'s note on the APNs Apple ID — these are two separate single-points-of-failure that deserve two separate documented backup admins.
