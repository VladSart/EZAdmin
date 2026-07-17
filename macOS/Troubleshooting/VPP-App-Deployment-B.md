# macOS VPP / Apple Business Manager App Deployment — Hotfix Runbook (Mode B: Ops)
> Fix or escalate volume-purchased (VPP) app deployment failures on managed Macs in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

VPP (Volume Purchase Program) apps — now called **location tokens** inside Apple Business Manager,
still labeled "Apple VPP tokens" in the Intune UI — fail in one of a small number of ways: the token
itself, license availability, or a licensing-type mismatch. Almost never the app or the Mac itself.
Run these first, in this order:

```
# 1. Check every VPP/location token's status and expiry (admin-side, portal)
Intune admin center → Tenant administration → Connectors and tokens → Apple VPP tokens
# Look at the Status column and Expiration date for every token
# Bad: any token shows Expired, Invalid, or Duplicate → Fix 1

# 2. Confirm the specific app is still associated with a non-expired, non-duplicate token
Intune admin center → Apps → All apps → filter/search the app → check "VPP token name" column
# Bad: token name blank or points at an expired/removed token → Fix 1

# 3. Check license consumption for the app
Intune admin center → Apps → All apps → <app> → Overview → Total/Available/Used licenses
# Bad: Available = 0 while assignment group is larger than Total → Fix 2 (oversubscription)

# 4. Confirm assignment type and licensing type are sane for this scenario
Intune admin center → <app> → Properties → Edit assignments
# Bad: same device/user has BOTH a device-licensed and user-licensed assignment for this app → Fix 3
# Bad: user-licensed app assigned to a device group, or to a Kiosk-mode device → Fix 4

# 5. On the Mac itself — confirm what's actually installed vs. what Intune thinks is assigned
system_profiler SPApplicationsDataType 2>/dev/null | grep -i -A3 "<AppName>"
sudo profiles -P | grep -i -B1 -A3 "<AppBundleID>"
# Bad: app missing locally despite "Installed" status in Intune → Fix 5 (stale device record / sync issue)
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Token status Expired | Fix 1 — renew the location token from Apple Business Manager |
| Token status Invalid | Fix 1 — Managed Apple Account issue (password/domain/disabled), not the token file itself |
| Token status Duplicate | Fix 1 — same Token Location uploaded twice, remove the duplicate |
| Available licenses = 0, assignment group larger than purchased count | Fix 2 — oversubscription, purchase more licenses or shrink the group |
| Device shows error `0x87D13B9F` | Benign — see Learning Pointers. No action needed if device/user is still in the Required/Available assignment |
| Both device- and user-licensed assignments target the same device/user | Fix 3 — remove one; this combination is explicitly unsupported |
| User-licensed app not installing on a Kiosk/Single App Mode device | Fix 4 — re-assign as device-licensed; user licensing is not recommended for Kiosk mode |
| App shows Installed in Intune but isn't on the Mac | Fix 5 — force a device check-in/sync; if still absent, treat as a stale device record |
| App was removed from assignment, still shows "update available" | Expected behavior — Intune stops pushing updates to unassigned apps even if it originally installed them; re-assign or set Uninstall intent |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Business Manager (or Apple School Manager) account for the org
        │
Content/location token purchased & downloaded
   (ABM → Preferences → Payments and Billing → Apps and Books → Content Tokens → Download)
   Valid 1 year. Usable with exactly ONE device management solution, ONE Intune tenant, at a time.
        │
Location token uploaded to Intune
   (Tenant administration → Connectors and tokens → Apple VPP tokens)
        │
Intune syncs token with Apple (daily by default, manual sync available)
   → pulls app names, metadata, and license counts
        │
App visible under Apps → All apps, tagged with its VPP token name
        │
App assigned to an Entra group
   ├── Licensing type: Device (no sign-in, 1 license/device) OR User (unique Apple Account, 1
   │    license for up to 5 devices) — NEVER both for the same device/user
   └── Intent: Required / Available / Uninstall
        │
Device checks in → Intune tells Apple which app license to assign to which device/user
   (Intune does NOT perform the install itself)
        │
Apple's own App Store / MDM install channel installs the app on the device
        │
App present on device, license marked Used against the token
```

**Key concept:** Intune is a license broker and assignment engine here, not the installer. Every VPP
failure ultimately traces back to one of three things: the **token** is bad (expired/invalid/duplicate),
the **licenses** are exhausted or misassigned, or the **licensing type** doesn't match the deployment
scenario (Kiosk mode, User Enrollment, blocked App Store access).

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm token health**
```
Intune admin center → Tenant administration → Connectors and tokens → Apple VPP tokens
```
Check Status (should be a healthy/active state, not Expired/Invalid/Duplicate) and Expiration date.

**Step 2 — Confirm the app-to-token association and license count**
```
Intune admin center → Apps → All apps → <app> → Overview
```
Note Total, Available, and Used license counts, and the VPP token name column.

**Step 3 — Confirm assignment configuration**
```
Intune admin center → <app> → Properties → Edit assignments
```
Check licensing type (Device/User), intent (Required/Available/Uninstall), and target group size vs.
available licenses.

**Step 4 — Confirm actual device-side state**
```bash
system_profiler SPApplicationsDataType 2>/dev/null | grep -i -A3 "<AppName>"
```
Confirms whether the app is physically present, independent of what Intune's portal reports.

**Step 5 — Force a re-check if state looks stale**
```
Intune admin center → device → Sync
```
Then re-check Step 4 after the device has had time to check in (up to a few minutes, longer if the
device was offline).

---
## Common Fix Paths

<details><summary>Fix 1 — Token expired, invalid, or duplicate</summary>

**Cause:** Location tokens are valid for exactly one year and expire silently unless proactively
renewed. "Invalid" almost always means the Managed Apple Account tied to the token had its domain,
password, or account status change. "Duplicate" means the same Token Location was uploaded twice.

```
# Renew (works the same for Expired or Invalid):
# 1. Go to https://business.apple.com (or school.apple.com)
# 2. Preferences → Payments and Billing → Apps and Books → Content Tokens → Download
# 3. In Intune: Tenant administration → Connectors and tokens → Apple VPP tokens
# 4. Select the token → Edit → Basics → upload the new token file → Save
# 5. Sync the token manually to confirm it comes back healthy
```
```
# Duplicate token:
# 1. Identify which of the two uploaded tokens is the one actively in use (check Sync history)
# 2. Delete the redundant one — deleting a token also revokes its associated app licenses, so confirm
#    you're deleting the unused duplicate, not the live one, before proceeding
```

**Rollback:** N/A for renewal (token upload doesn't remove existing assignments). For duplicate
removal, deleting the WRONG token revokes real licenses — always confirm via Sync history/date before
deleting either one.

</details>

<details><summary>Fix 2 — License oversubscription</summary>

**Cause:** More group members than purchased licenses. Intune assigns licenses first-come, the rest
fail silently with no obvious error banner unless someone checks the app's license count.

```
# 1. Confirm: Apps → All apps → <app> → Overview → Available = 0
# 2. Either:
#    a) Purchase additional licenses in Apple Business Manager, then Sync the token in Intune, OR
#    b) Reduce the assignment group to fit the number of licenses actually owned
# 3. An alert automatically appears under Intune's Enrollment alerts tab once usage crosses 50% —
#    use that as an early warning before hitting 100% next time
```

**Rollback:** N/A — not a destructive action.

</details>

<details><summary>Fix 3 — Device and user licensing both assigned to the same target</summary>

**Cause:** Explicitly unsupported per Microsoft's own guidance — can cause install/update failures
that look random and are hard to reproduce consistently.

```
# 1. Apps → All apps → <app> → Properties → Edit assignments
# 2. Identify the duplicate assignment (same group or overlapping group membership under both a
#    Device-licensed and a User-licensed assignment for this app)
# 3. Remove one — keep whichever licensing type matches your actual deployment model (device-licensed
#    is almost always the right default for corporate-owned macOS fleets)
# 4. Sync affected devices
```

**Rollback:** N/A — removing the redundant assignment is not destructive to the surviving one.

</details>

<details><summary>Fix 4 — Wrong licensing type for the deployment scenario</summary>

**Cause:** User licensing requires an interactive Apple Account sign-in and is not supported on User
Enrollment for device-licensed apps, not recommended for Kiosk/Single App Mode, and doesn't work if a
device policy blocks App Store access (the invitation flow itself needs App Store access).

```
# 1. Identify the scenario: Kiosk mode, User Enrollment, or App Store access blocked by policy
# 2. Re-assign the app as Device-licensed instead of User-licensed for Kiosk/blocked-App-Store cases
# 3. For User Enrollment specifically, use a Managed Apple Account for user licensing rather than a
#    personal Apple Account
```

**Rollback:** N/A — reassignment, not destructive.

</details>

<details><summary>Fix 5 — App shows Installed in Intune but is missing on the Mac</summary>

**Cause:** Stale device record — Intune's install-state reporting relies on the device's own check-in;
if the device was offline, reimaged outside Intune's knowledge, or the app was manually removed by the
user, the portal can lag reality.

```
# 1. Force a sync
Intune admin center → device → Sync
# 2. Re-check locally after check-in completes
system_profiler SPApplicationsDataType 2>/dev/null | grep -i -A3 "<AppName>"
# 3. If still absent and the app's intent is Required, Intune should re-push the install on next
#    check-in automatically — if it doesn't within a couple of check-in cycles, escalate with the
#    Evidence Pack below rather than repeatedly forcing syncs
```

**Rollback:** N/A — read/diagnostic only.

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — macOS VPP App Deployment Issue
=====================================
Device Name:                  [hostname]
Serial Number:                 [Intune → device → Hardware → Serial number]
macOS Version:                 [sw_vers -productVersion]
App Name / Bundle ID:          [name / com.example.app]
VPP Token Name:                [Intune → Apps → All apps → app → VPP token name column]

Token status (Expired/Invalid/Duplicate/OK):        [status]
Token expiration date:                                [date]
Licenses (Total / Available / Used):                  [x / x / x]
Licensing type assigned (Device / User):               [type]
Assignment intent (Required / Available / Uninstall):  [intent]
App present locally (system_profiler check):            [Yes/No]
Error code observed (if any, e.g. 0x87D13B9F):          [code]

Steps already attempted:
[ ] Confirmed token status and expiry
[ ] Confirmed license availability (Total/Available/Used)
[ ] Confirmed no device+user licensing conflict for this device/user
[ ] Confirmed licensing type matches deployment scenario (Kiosk/User Enrollment/App Store policy)
[ ] Forced a device sync and re-checked local install state
```

---
## 🎓 Learning Pointers

- **Intune is a license broker, not the installer.** For VPP apps, Intune tells Apple which license to
  assign to which device/user; the actual install happens between Apple and the device. When triaging,
  separate "is the license assigned" from "did the install actually run" — they can fail independently. [Manage Apple Volume-Purchased Apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)

- **Oversubscription fails silently.** Assigning an app to a group larger than your purchased license
  count doesn't produce an error banner in the main Apps view — only the first N group members get the
  license, and Intune only visibly alerts once usage crosses 50%. Check license counts as a matter of
  routine when a "some users have the app, others don't" ticket comes in.

- **`0x87D13B9F` ("installed but a newer version is available") is usually not an actionable error.**
  It means the device checked in but the auto-update didn't complete that cycle — Intune retries on the
  next check-in as long as the assignment is still in place. Don't chase this unless it persists across
  multiple check-in cycles.

- **VPP is being renamed "Apps and Books" and legacy tokens are being phased toward migration.**
  If a customer references "the old VPP portal" or a purchaser sees a prompt to move to a new location
  in Apple Business Manager, that's the VPP → Apps and Books migration path — treat it as a planned
  change, not a fault, and follow Microsoft's migration steps rather than troubleshooting it as broken. [Manage Apple Volume-Purchased Apps — Migrate from VPP to Apps and Books](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)

- **Device and user licensing are mutually exclusive per target, by design — never assign both.**
  This isn't a soft recommendation; Microsoft documents it as an unsupported combination that causes
  install/update issues, and it's a surprisingly easy mistake when an app has assignments built by
  different admins at different times.
