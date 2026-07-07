# Windows Autopilot Device Preparation — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** Windows Autopilot device preparation (APDP) is a *distinct*, newer enrollment mode from classic Windows Autopilot (profile-based, hash-registered). It uses Entra join only (no hybrid join, no Autopilot-for-existing-devices via traditional profiles), enrollment-time device group membership instead of dynamic groups, and does **not** use the Enrollment Status Page (ESP). If ESP is showing, you are not looking at a device preparation deployment — see Fix 1. For classic Autopilot issues, use `Profile-Not-Assigned-B.md`, `ESP-Stuck-B.md`, or `HybridJoin-Autopilot-B.md` instead.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run these in order. Device preparation has almost no client-side PowerShell surface during OOBE — most triage is portal-side (Intune admin center → **Devices → Enrollment → Device preparation → Monitor**) plus these checks:

| # | Check | Where | If X → Do Y |
|---|-------|-------|-------------|
| 1 | Windows build meets minimum | Device (`winver`) | Win11 24H2+, or 23H2/22H2 with KB5035942+. If below → deployment silently never launches, device falls through to normal OOBE. Update media/OEM image first. |
| 2 | Device already Autopilot-registered or has a classic profile assigned | Intune admin center → Windows enrollment → Windows Autopilot devices | If registered/assigned → the **classic Autopilot profile takes precedence** and device prep never fires. Deregister the device or remove the profile assignment. |
| 3 | ESP displaying during deployment | Device screen | Device prep **never uses ESP**. If ESP shows, you are in a classic Autopilot or plain Entra-join flow, not device prep — go to `ESP-Stuck-B.md`. |
| 4 | Deployment status report | Intune admin center → Monitor tab → device preparation deployments | Look for `Skipped` apps/scripts (→ Fix 4), stuck `In progress` past 60 min on Windows 365/Cloud PC (→ Fix 5), or the deployment never appearing at all (→ Fix 2/3). |
| 5 | Device security group ownership | Entra admin center → Groups → \<policy's device group\> → Owners | Owner must be **Intune Provisioning Client** (AppID `f1346770-5b25-470b-88bd-d5744ab7952c`; may display as **Intune Autopilot ConfidentialClient** — same AppID, same thing). Missing/wrong owner → Fix 2. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows 11 24H2 (or 23H2/22H2 + KB5035942) preinstalled/imaged
    │
    ▼
Device NOT registered as Windows Autopilot device
Device NOT targeted by a classic Windows Autopilot profile
    (classic profile always wins over device prep policy)
    │
    ▼
Windows automatic Intune (MDM) enrollment enabled in Entra ID
Users permitted to Entra-join devices (or corporate identifiers used
    if personal-device join is blocked via enrollment restrictions)
    │
    ▼
Device preparation policy exists, targets a USER group,
    and has a DEVICE security group selected
    │
    ▼
Device security group:
    - is a plain ASSIGNED group (not dynamic)
    - is NOT "assignable to Entra roles"
    - has "Intune Provisioning Client" (f1346770-5b25-470b-88bd-d5744ab7952c)
      set as OWNER (this is what lets Intune add devices to it at enroll time)
    │
    ▼
Admin creating/editing the policy has RBAC permission:
    "Enrollment time device membership assignment" (+ "Device configurations: Assign")
    │
    ▼
User authenticates during OOBE, is a member of the policy's user group
    │
    ▼
[Enrollment Time Grouping fires]
    Device is added DIRECTLY to the device security group (not via dynamic rule)
    │
    ▼
Apps/scripts assigned to that device group AND selected in the
    device prep policy itself are installed during OOBE
    (must be targeted to install in SYSTEM context — no signed-in user yet)
    │
    ▼
Policies assigned to the group are synced (NOT tracked as pass/fail
    during OOBE — may finish before or after OOBE completes)
    │
    ▼
User reaches desktop as Standard user (default) or Administrator,
    per the policy's "User account type" setting
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm this is actually a device-prep deployment, not classic Autopilot.**
   Check Intune admin center → Windows enrollment → Windows Autopilot devices for the serial number.
   *Expected:* not present, or present with no profile assigned.
   *Bad:* device is registered and/or has a classic Autopilot profile assigned — that always wins. Deregister via `Autopilot/Scripts/Upload-Hash-Enroll2Autopilot.ps1`'s companion deregistration step, or the portal.

2. **Confirm device group ownership.**
   Entra admin center → Groups → search the device group referenced in the device prep policy → **Owners**.
   *Expected:* `Intune Provisioning Client` or `Intune Autopilot ConfidentialClient` listed, AppID `f1346770-5b25-470b-88bd-d5744ab7952c`.
   *Bad:* no owner, wrong owner, or the service principal doesn't exist in the tenant yet (needs to be added via PowerShell first — see MS Learn "Adding the Intune Provisioning Client service principal").

3. **Confirm the group itself is eligible.**
   Group properties → **Microsoft Entra roles can be assigned to this group** must be **No**, and the group type must be a plain assigned security group (not dynamic).
   *Bad:* "role-assignable" set to Yes, or group is dynamic — both block Intune from adding devices at enrollment time.

4. **Check the deployment status report for the specific device.**
   Intune admin center → Devices → Enrollment → Device preparation → **Monitor** tab → find device → expand.
   *Expected:* Apps/Scripts show `Installed`.
   *Bad:* `Skipped` → app/script isn't assigned to the device group (Fix 4), or isn't set to run in System context.

5. **For Windows 365 / Cloud PC device prep specifically, check elapsed time.**
   *Expected:* completes within the configured "Minutes allowed before device preparation fails" value.
   *Bad:* deployment silently times out at 60 minutes regardless of a higher configured value if too many blocking apps are assigned — reduce blocking-app count as a workaround (was resolved for most tenants Feb 2026, but worth ruling out on older Cloud PC images).

---
## Common Fix Paths

<details><summary>Fix 1 — ESP is displaying; this isn't a device prep deployment</summary>

Device preparation **never shows ESP**. If ESP is on screen:
1. Confirm via Windows Autopilot devices list whether the serial is registered.
2. If registered with a classic profile assigned → that's why. Either intentionally use classic Autopilot for this device (go to `Profile-Not-Assigned-B.md`/`ESP-Stuck-B.md` instead), or deregister it so device prep can take over:
   - Portal: Devices → Enrollment → Windows Autopilot devices → select device → **Delete**.
3. Re-run OOBE (`shift+F10` → `wpeutil reboot`, or factory reset the device) after deregistration — device prep only evaluates at the start of OOBE.

No rollback needed; deregistering doesn't affect Entra device objects already created by a prior join.

</details>

<details><summary>Fix 2 — Device security group not saving / shows "0 groups assigned" / owner errors</summary>

Symptoms: policy save fails with `There was a problem with the device security group...` or `Failed to update security group device preparation setting...`, or the group shows 0 groups assigned despite being selected.

```powershell
# Connect with Graph
Connect-MgGraph -Scopes "Group.ReadWrite.All","Application.Read.All"

# Find the Intune Provisioning Client service principal (AppID is fixed/global)
$spAppId = "f1346770-5b25-470b-88bd-d5744ab7952c"
$sp = Get-MgServicePrincipal -Filter "appId eq '$spAppId'"
if (-not $sp) {
    Write-Warning "Service principal not found in tenant — must be created first (see MS Learn: Adding the Intune Provisioning Client service principal)."
}

# Set it as owner of the device group used in the policy
$groupId = "<deviceGroupObjectId>"
New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)"
}
```

If the service principal genuinely doesn't exist in the tenant yet, it must be provisioned first — this is a one-time tenant setup step, not a per-policy fix. Confirm via `Get-MgServicePrincipal -Filter "appId eq 'f1346770-5b25-470b-88bd-d5744ab7952c'"` returning null before assuming this path.

**Workaround if the existing group is stuck showing 0 groups assigned even with correct ownership:** create a *new* assigned device security group with the service principal pre-set as owner, then reassign the policy to the new group — this was a known intermittent bug (resolved July 2024, but re-verify on your tenant's current build if it recurs).

No rollback risk — group ownership changes don't affect existing group membership.

</details>

<details><summary>Fix 3 — Deployment experience never launches during OOBE</summary>

Checklist, in likelihood order:
1. Windows build below minimum (`winver`, or check OEM image build) → re-image with updated media from the Microsoft 365 admin center (VLSC/subscriptions), which ships with the latest cumulative update pre-slipstreamed.
2. Device is registered as Autopilot / has a classic profile → see Fix 1.
3. Signing-in user isn't a member of the policy's **user group** → add them, or verify the correct user group is referenced in the policy.
4. Policy has **no device group selected at all** — a device prep policy can be saved without one. Re-open the policy and confirm a device group is chosen.
5. Corporate identifiers required but missing (only relevant if enrollment restrictions block personal-device Entra join) → add the device's serial/manufacturer/model via Intune → Enrollment restrictions → Corporate identifiers.
6. Windows automatic MDM enrollment not configured, or users blocked from Entra-joining devices → check Entra ID → Devices → Device settings.

</details>

<details><summary>Fix 4 — Apps or PowerShell scripts show "Skipped"</summary>

Two independent causes, check both:
1. **Not assigned to the device group** — the app/script must be assigned (Intune) to the *specific* device security group referenced in the device prep policy, in addition to being selected inside the policy itself. Being selected in the policy alone is not enough; add the group assignment.
2. **Not set to run in System context** — during OOBE, no user is signed in yet, so any app/script configured for User context is skipped by design. Change the install/run context to System.
3. **Managed Installer policy is Active for the tenant** — Win32, WinGet, and Enterprise App Catalog apps are deliberately skipped during OOBE when Managed Installer is enabled (this is documented, expected behavior, not a bug) and instead install after the user reaches the desktop. Education tenants have this on by default (Windows 11 SE requirement). If immediate OOBE delivery is required, Managed Installer must be disabled for the tenant — weigh this against its security purpose before changing it.

</details>

<details><summary>Fix 5 — Windows 365 / Cloud PC device prep times out around 60 minutes</summary>

Known issue: the "Minutes allowed before device preparation fails" value in the Cloud PC provisioning policy doesn't always apply correctly to device prep, causing a hard ~60-minute ceiling regardless of the configured value. Largely resolved February 2026, but on older/un-patched tenants:
- Reduce the number of apps/scripts marked as **blocking** in the device prep policy.
- Move non-essential apps to post-OOBE delivery (assign to the device group without selecting them in the policy) rather than blocking OOBE completion.
- If still hitting the ceiling on a current build, treat as a live regression — escalate with the Evidence Pack below rather than continuing to trim the app list indefinitely.

</details>

<details><summary>Fix 6 — Device stuck at 100% during OOBE / user reaches desktop as wrong account type</summary>

- **Stuck at 100%:** known issue with no fix at time of writing — have the end user manually restart the device; deployment resumes correctly after restart. Not data-destructive.
- **Wrong account type (user ends up admin when Standard was expected, or vice versa):** check for the documented conflict between the device prep policy's **User account type** setting and Entra ID's **Local administrator settings** (Entra admin center → Devices → Device settings). These two settings can silently conflict and cause provisioning to be skipped entirely, leaving the user at the desktop without the expected apps. See the Deep Dive (`DevicePreparation-A.md`) for the exact supported setting combinations — don't guess-toggle these in production without checking the table first, since the wrong combination re-triggers the same conflict.

</details>

---
## Escalation Evidence

```
=== Windows Autopilot Device Preparation — Escalation Template ===
Tenant:                 <tenantName>
Device serial:          <serialNumber>
Windows build:          <winver output>
Device prep policy name:<policyName> (priority: <n>)
Device group (Object ID):<deviceGroupObjectId>
  - Intune Provisioning Client owner confirmed:   Yes / No
  - Role-assignable set to No:                    Yes / No
  - Group type (assigned/dynamic):                <type>
User group (Object ID): <userGroupObjectId>
Signing-in user UPN:    <UPN>
  - Member of user group:                         Yes / No
Registered as classic Autopilot device:           Yes / No
Classic profile assigned:                         Yes / No (name: <profileName>)
ESP displayed during deployment:                  Yes / No
Deployment Monitor status (Intune):               <Not started / In progress / Failed / Succeeded>
Apps shown Skipped:                                <list>
Scripts shown Skipped:                             <list>
Managed Installer policy tenant state:            Active / Not configured
Elapsed deployment time:                          <minutes>
Configured timeout (if Cloud PC):                 <minutes>
Corporate identifiers required/configured:        Yes / No / N/A
Screenshot/export of Monitor tab detail attached: Yes / No
```

---
## 🎓 Learning Pointers
- Device preparation is architecturally separate from classic Autopilot — it uses **Enrollment Time Grouping** (direct group assignment at join time) instead of dynamic-group evaluation, which is *why* it's faster and more reliable, but also why group ownership/eligibility rules are so strict. See [Overview of Windows Autopilot device preparation](https://learn.microsoft.com/en-us/autopilot/device-preparation/overview).
- The "classic profile always wins" precedence rule is the single most common reason device prep silently doesn't fire — always rule this out first, before touching policy config. See the [troubleshooting FAQ](https://learn.microsoft.com/en-us/autopilot/device-preparation/troubleshooting-faq).
- Keep the [known issues page](https://learn.microsoft.com/en-us/autopilot/device-preparation/known-issues) bookmarked — this feature ships fast and several "bugs" (BitLocker defaulting to 128-bit, UTC-only OOBE, stuck-at-100%) are actively tracked/dated there rather than being tenant misconfiguration.
- Custom compliance and device health scripts are **not supported** during device prep deployments (initial-release limitation) — don't spend time debugging why a custom compliance script "isn't running" during OOBE; it's by design.
- The RBAC permission "Enrollment time device membership assignment" is specific to this feature and easy to miss when building a custom Autopilot admin role — see [Required RBAC permissions](https://learn.microsoft.com/en-us/autopilot/device-preparation/requirements?tabs=rbac#required-rbac-permissions).
- If migrating a fleet from classic Autopilot to device prep, plan the cutover per-device (deregister from classic first) rather than assuming device prep policies simply "take over" — they don't, by design.
