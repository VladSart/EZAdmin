# macOS VPP / Apple Business Manager App Deployment — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Location tokens (the current Apple Business Manager term for what's still labeled "Apple VPP
  tokens" in the Intune UI) — upload, renewal, sync, and multi-tenant/multi-MDM exclusivity rules
- App licensing models: Device licensing vs. User licensing, and their distinct install/update/
  revocation behavior on macOS specifically
- Store apps (public App Store) and Custom Apps (privately distributed to your organization) acquired
  via Apple Business Manager
- License lifecycle: assignment, revocation, the macOS-specific 30-day grace period, and deletion
- Assignment scenarios that interact with licensing type: BYOD, Kiosk/Single App Mode, User Enrollment

**Does not cover:**
- Apple Business Manager device/DEP token sync for enrollment itself — see `ABM-Token-Renewal-A.md`
  for that (device enrollment tokens and VPP/content tokens are separate credentials that can be, but
  are not required to be, tied to the same Managed Apple Account)
- eBooks purchased through the same volume-purchase mechanism — a related but distinct Intune workflow
- Custom App development/signing requirements — this covers deployment only, not how a developer
  registers a Custom App with Apple
- iOS/iPadOS-specific behavior (User Enrollment via account-driven enrollment, Shared iPad license
  reclamation) except where explicitly contrasted against macOS behavior

**Assumptions:**
- The organization already has an active Apple Business Manager (or Apple School Manager) account and
  Content Manager role assigned to at least one admin who can purchase and download tokens
- Devices are Intune-enrolled via any supported macOS enrollment method (ADE, User-Approved MDM, etc.)
  — VPP app assignment does not itself require ADE/supervision, though some scenarios (Kiosk mode) do

---
## How It Works

<details><summary>Full architecture — tokens, licensing models, and the install handoff to Apple</summary>

### From VPP to location tokens to "Apps and Books"

What MSPs still colloquially call "VPP" (Volume Purchase Program) is, as of recent Apple Business
Manager changes, formally the **location token** system, itself in the process of being subsumed into
a broader **Apps and Books** purchasing model. Functionally, for an Intune admin, none of this renaming
changes the mechanics described below — Intune's UI still says "Apple VPP tokens," the file you
download from Apple Business Manager is still referred to as a location token, and it's still valid for
exactly one year. The one thing that does matter operationally: Apple is actively encouraging
purchasers to migrate to the newer Apps and Books structure, and if a customer's Content Manager
completes that migration, **the Intune-side token must be re-downloaded and re-uploaded** — see the
Remediation Playbooks section.

### Two licensing models, and why they behave completely differently on macOS

Apple offers exactly two ways to license a volume-purchased app, and the choice has architectural
consequences far beyond "how many devices can use it":

**Device licensing** ties a license to the device's hardware identity. No Apple Account sign-in is
required at all — the app installs and updates silently through the MDM channel (Company Portal on
macOS), which is precisely why device licensing is the default and recommended model for
corporate-owned, single-purpose, or supervised fleets. One license is consumed per device, period.

**User licensing** ties a license to a specific Apple Account (or Managed Apple Account for User
Enrollment scenarios). The end user must sign in to the App Store with that account when prompted. One
user license covers up to five devices signed into the same personal Apple Account — but note the
gotcha: an end user who has both a personal Apple Account **and** a Managed Apple Account registered in
Intune consumes **two** separate app licenses, not one, because Intune tracks them as independent
identities.

These aren't just cosmetic differences — they gate entirely different feature availability:

| Capability | Device Licensing | User Licensing |
|---|---|---|
| Apple Account sign-in required | No | Yes, per user |
| Works with User Enrollment | Not supported | Supported (via Managed Apple Accounts only) |
| eBooks | Not supported | Supported |
| License scope | 1 per device | 1 per Apple Account, covers up to 5 devices |
| Silent migration between models | Can migrate User→Device silently (Required intent only) | Cannot migrate Device→User at all |

### Intune as broker, Apple as installer

This is the single most important mental model for troubleshooting VPP deployment issues: **Intune
does not install the app.** When an admin assigns a VPP app to a group, Intune's job is to call Apple's
VPP/Apps-and-Books API and tell it "assign a license for app X to device/user Y." From that point, the
actual download and installation happens through Apple's own App Store / MDM install-command channel on
the device, entirely outside Intune's direct control. This explains two behaviors that otherwise look
like bugs:

1. **A license can show "assigned" in Intune while the app is still not present on the device** — the
   assignment (license broker step) succeeded; the install (Apple's own channel) hasn't completed yet,
   or failed for a device-side reason Intune has limited visibility into.
2. **Intune's update-push behavior depends on assignment membership, not install history.** If a
   device/user is removed from an app's Required or Available assignment, Intune stops pushing future
   updates for that app — even to a device where Intune itself originally performed the install. The
   app doesn't get removed (unless a separate Uninstall intent is set), it simply stops receiving
   update pushes, which produces "why is this app frozen on an old version" tickets that have nothing
   to do with the app, the device, or a broken token.

### The end-user prompt matrix, and why it matters for troubleshooting "why did the user get a sign-in prompt"

Apple's documented behavior for VPP install prompts varies across eight distinct combinations of
enrollment type (BYOD / Corporate), supervision state, licensing type, and Kiosk mode — each producing
a different combination of (a) whether the user gets invited to the VPP program at all, (b) whether an
install-confirmation prompt appears, and (c) whether an Apple Account sign-in prompt appears. The
practical takeaway: an unexpected sign-in or install prompt is very often not a malfunction — it's the
documented behavior for that specific combination of licensing type and device state. Before treating a
prompt as a bug, identify which of the eight scenarios applies (see the Symptom → Cause Map).

### Revocation and the macOS-specific 30-day grace period

Revoking a license is a two-step process on both platforms: first remove the app assignment (this alone
does not reclaim the license — the app just stops being offered for further installs), then explicitly
set the assignment intent to **Uninstall** to actually reclaim the license and, on iOS/iPadOS, remove
the app. **macOS behaves differently here**: after a license is revoked, the app remains usable on the
Mac — it simply can no longer receive updates through the VPP channel — for a **30-day grace period**
before Apple removes it. This is a deliberate design choice by Apple (not an Intune limitation) and
matters when planning offboarding: a revoked license doesn't guarantee immediate app removal on macOS
the way it functionally does on iOS/iPadOS.

</details>

---
## Dependency Stack

```
Apple Business Manager / Apple School Manager account, Content Manager role
        │
Location token purchased, apps/licenses assigned to it in ABM
   (1-year validity; usable with exactly ONE MDM solution and ONE Intune tenant at a time)
        │
Location token downloaded from ABM, uploaded to Intune
   (Tenant administration → Connectors and tokens → Apple VPP tokens)
        │
Daily automatic sync (or manual) — Intune pulls app metadata + license counts from Apple
        │
App visible in Intune (Apps → All apps), tagged with source VPP token name
        │
App assignment to an Entra group
   ├── Licensing type: Device (hardware-bound, no sign-in) or User (Apple-Account-bound)
   │    — mutually exclusive per device/user target, never both
   └── Intent: Required / Available / Uninstall
        │
Device check-in → Intune calls Apple's VPP/Apps-and-Books API → license reservation
        │
Apple's own App Store / MDM install channel performs the actual download+install on-device
   (Intune has assignment-level visibility, not fine-grained install-progress visibility)
        │
License marked Used; app present on device
```

A break at ANY layer above the device check-in step is an admin-side/portal problem, not a device
problem — this is why local device diagnostics play a smaller role in this topic than in most other
macOS runbooks in this repo.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No apps under this token sync/install for ANY device | Token expired, invalid, or duplicate | Apple VPP tokens list — Status column |
| Only SOME group members get the app, others don't | License oversubscription | App → Overview → Available vs. group size |
| Error `0x87D13B9F` on a device that already has the app | Benign — update pending next check-in cycle | Confirm device/user still in Required/Available assignment |
| App frozen on an old version, was working before | Device/user was removed from the assignment group | Assignment membership vs. app version history |
| User prompted for Apple Account sign-in unexpectedly | Combination of User licensing + non-supervised or BYOD device — expected per Apple's prompt matrix | Cross-reference licensing type + supervision state against the 8-scenario table |
| App won't install on a Kiosk-mode device | User licensing assigned to a Kiosk-mode device — not recommended | Assignment licensing type |
| User-licensed app not offered on a User Enrollment device | Device licensing was assigned instead — User Enrollment only supports user licensing via Managed Apple Accounts | Assignment licensing type + enrollment type |
| Revoked license, app still present and usable on the Mac weeks later | Expected — macOS has a 30-day grace period post-revocation, unlike iOS/iPadOS | Confirm revocation date vs. current date |
| Can't delete a VPP app from Intune | Licenses still assigned/used; must revoke all licenses (and confirm in ABM) first | App → App licenses → Revoke licenses |
| Token shows "Duplicate" | Same Token Location uploaded twice | Compare Token Location values across uploaded tokens |
| License count in Intune doesn't match what was purchased in ABM | Sync hasn't run yet (daily default) or a manual sync is needed | Trigger manual Sync on the token |

---
## Validation Steps

**1. Confirm token status and expiry**
```
Intune → Tenant administration → Connectors and tokens → Apple VPP tokens
```
Expected: Active/healthy status, expiry well in the future. Bad: Expired/Invalid/Duplicate.

**2. Confirm app-to-token association**
```
Intune → Apps → All apps → <app> → VPP token name column
```
Expected: points to a live, healthy token.

**3. Confirm license utilization**
```
Intune → Apps → All apps → <app> → Overview → Total / Available / Used
```
Expected: Available > 0 relative to the assignment group size, or an intentional oversubscription
that's understood and accepted.

**4. Confirm assignment configuration**
```
Intune → <app> → Properties → Edit assignments
```
Expected: exactly one licensing type per device/user target, intent matches the deployment goal.

**5. Confirm device-side install state**
```bash
system_profiler SPApplicationsDataType 2>/dev/null | grep -i -A3 "<AppName>"
```
Expected: app present with a version that's current relative to what's published in the App Store.

**6. Confirm role permissions if a custom admin role can't see/manage VPP content**
```
Intune → Roles → <custom role> → Permissions → Mobile apps (view/manage VPP apps)
                                              → Managed apps (manage VPP tokens themselves)
```
Note: viewing/managing VPP apps only requires the **Mobile apps** permission (a change from earlier
behavior that required **Managed apps**); Intune for Education tenants still require **Managed apps**.

---
## Troubleshooting Steps (by phase)

### Phase 1: Token health
1. Confirm token status is not Expired/Invalid/Duplicate.
2. If Invalid, treat as a Managed Apple Account problem first (password expiry, domain change, account
   disabled) — the token FILE itself is rarely the root cause of an "Invalid" status.

### Phase 2: License availability
1. Confirm Total/Available/Used counts against the actual assignment group size.
2. Remember Intune does not block an oversubscribed assignment — it silently fails the excess members.

### Phase 3: Assignment configuration
1. Confirm licensing type (Device vs. User) matches the deployment scenario (Kiosk mode, User
   Enrollment, BYOD, App Store access policy).
2. Confirm no device/user has both a device-licensed AND user-licensed assignment for the same app —
   this is explicitly unsupported and produces inconsistent install/update behavior.

### Phase 4: Device-side confirmation
1. Confirm actual presence via `system_profiler SPApplicationsDataType` — don't rely solely on the
   Intune portal's reported install state, since Intune's visibility into Apple's own install channel
   is assignment-level, not install-progress-level.
2. Force a Sync if state looks stale, then re-check after the device has had time to check in.

### Phase 5: Lifecycle edge cases
1. For revocation tickets on macOS, remember the 30-day grace period before Apple actually removes an
   app whose license was revoked — don't treat "still installed" as a failure within that window.
2. For deletion requests, confirm all licenses are revoked (assignment groups removed, intent set to
   Uninstall) and reflected in Apple Business Manager before attempting to delete the app object in
   Intune, or the deletion will fail with an in-use error.

---
## Remediation Playbooks

<details>
<summary>Playbook 1 — Migrating a legacy VPP purchaser to Apps and Books</summary>

**Scenario:** Apple Business Manager prompts (or the org proactively decides) to migrate a VPP
purchaser's content to the newer Apps and Books structure.

```
1. Only migrate ONE VPP purchaser per location — if multiple purchasers migrate to a single unique
   location, ALL licenses (assigned and unassigned) move together; migrating them separately to
   different locations fragments the license pool
2. Invite VPP purchasers to join the organization in ABM/ASM and have each select a unique location
3. Confirm every purchaser has completed the invitation/location-selection step before proceeding
4. Verify in ABM/ASM that purchased apps and licenses have migrated into Apps and Books
5. Download the NEW location token: ABM/ASM → Preferences → Payments and Billing → Apps and Books →
   Content Tokens → Download
6. In Intune: Tenant administration → Connectors and tokens → Apple VPP tokens → select the existing
   token → Edit → upload the new token file → Save
7. Do NOT delete the existing legacy VPP token or its app assignments in Intune during this process —
   doing so would require recreating every assignment from scratch
```

**Rollback:** N/A for a successful token re-upload (existing assignments are preserved). If the
migration itself needs to be aborted mid-process in ABM, that's an Apple-side operation outside Intune's
control — coordinate with the Content Manager before touching the Intune-side token.

</details>

<details>
<summary>Playbook 2 — Recovering from a purchased-but-unassignable app due to a Duplicate token</summary>

**Scenario:** An app's licenses show as purchased in Apple Business Manager but the app either doesn't
sync into Intune correctly or license counts look wrong, and a token shows Duplicate status.

```
1. Identify BOTH tokens sharing the same Token Location (Intune → Apple VPP tokens list)
2. Check each token's Sync history/last successful sync date to determine which one is actively in use
3. Confirm no live app assignments depend specifically on the token you're about to remove (Apps →
   All apps → filter by VPP token name)
4. Delete the redundant/unused token — this revokes ITS associated app licenses and assignments, so
   confirm you've identified the correct (unused) one first
5. Trigger a manual Sync on the remaining, correct token
6. Re-verify app and license visibility in Intune matches Apple Business Manager
```

**Rollback:** If the wrong token was deleted, its app assignments must be manually recreated — Intune
cannot "undelete" a token or restore its prior assignment state automatically.

</details>

<details>
<summary>Playbook 3 — Bulk license reclamation ahead of a fleet offboarding/refresh</summary>

**Scenario:** A batch of Macs is being retired or reassigned, and licenses need to be reclaimed cleanly
before the devices leave Intune management.

```
1. For each affected app, change the assignment intent from Required/Available to Uninstall for the
   affected device/user group (or remove them from the group if the group is used elsewhere)
2. Confirm devices check in and process the Uninstall intent
3. Confirm license reclamation in Intune (App → Overview → Available count should increase)
4. Remember: on macOS, the app may remain installed and usable for up to 30 days after revocation even
   though the license itself is reclaimed immediately — this is expected, not a stuck uninstall
5. Do NOT remove the device from Intune management before this process completes — licenses are NOT
   automatically reclaimed when a device is simply removed from Intune (only Uninstall intent or user
   deletion from Entra ID reliably reclaims them)
```

**Rollback:** If reclamation was premature, re-assign the app with Required/Available intent to the
affected devices/users — a new license will be consumed from the pool as normal.

</details>

---
## Evidence Pack

```powershell
# Run in a PowerShell session with the Microsoft Graph module connected.
# Collects VPP token health and license utilization for every app tied to a given token, or for
# every token in the tenant if -TokenName is omitted. Read-only.
# Use Get-VPPAppLicenseAudit.ps1 in Scripts/ for the full automated fleet-wide sweep.

Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome

$tokens = Get-MgDeviceAppManagementVppToken -All
foreach ($t in $tokens) {
    [PSCustomObject]@{
        TokenName       = $t.OrganizationName
        AppleId         = $t.AppleId
        State           = $t.State
        ExpirationDate  = $t.ExpirationDateTime
        LastSyncDate    = $t.LastSyncDateTime
        LastSyncStatus  = $t.LastSyncStatus
    } | Format-List
}
Write-Host "Cross-reference each token's expiry/state against Apps > All apps > VPP token name column" -ForegroundColor Yellow
Write-Host "for the specific app(s) in question, and check Total/Available/Used license counts there." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Task | Where |
|---|---|
| Check VPP/location token status and expiry | Intune → Tenant administration → Connectors and tokens → Apple VPP tokens |
| Renew a token | Same location → select token → Edit → upload new file |
| Manually sync a token | Same location → select token → Sync |
| Check app-to-token association | Intune → Apps → All apps → <app> → VPP token name column |
| Check license counts | Intune → Apps → All apps → <app> → Overview |
| Edit app assignment (licensing type / intent) | Intune → <app> → Properties → Edit assignments |
| Revoke a specific license | Intune → <app> → App licenses → Revoke licenses |
| Confirm app present locally on Mac | `system_profiler SPApplicationsDataType \| grep -i -A3 "<AppName>"` |
| Force device check-in | Intune → device → Sync |
| Check custom role VPP permissions | Intune → Roles → <role> → Permissions → Mobile apps / Managed apps |
| Download/renew token from Apple | business.apple.com (or school.apple.com) → Preferences → Payments and Billing → Apps and Books → Content Tokens |

---
## 🎓 Learning Pointers

- **Intune is a license broker, Apple is the installer — this single fact resolves most confusing VPP
  tickets.** Assignment success and install success are two different, loosely-coupled events. Always
  separate "is the license assigned" (Intune's job) from "did the install/update actually run" (Apple's
  job, limited Intune visibility) when triaging. [Manage Apple Volume-Purchased Apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)

- **The eight-scenario end-user prompt matrix means an unexpected sign-in prompt is often correct
  behavior, not a bug.** Before escalating a "user got an unexpected Apple ID prompt" ticket, identify
  which combination of licensing type + supervision + Kiosk mode applies — it's very likely documented,
  expected behavior for that exact combination.

- **macOS's 30-day post-revocation grace period is genuinely different from iOS/iPadOS behavior.**
  This is a real, deliberate platform difference (Apple's decision, not Intune's) that trips up admins
  used to iOS/iPadOS's more immediate-feeling app removal on revocation — build this into offboarding
  timeline expectations, not just technical troubleshooting.

- **VPP → Apps and Books migration is a live, ongoing Apple-side transition** as of 2026 — if a
  customer mentions a new prompt or portal experience in Apple Business Manager, check whether it's
  this migration before assuming something broke. The Intune-side re-upload step is mandatory and easy
  to miss. [Manage Apple Volume-Purchased Apps — Migrate from VPP to Apps and Books](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)

- **Oversubscription and the 50%-utilization alert are your only early-warning system.** There's no
  hard block on assigning an app to more users than you have licenses for — Intune just silently fails
  the excess. Treat the 50% alert in Enrollment alerts as an operational signal worth actually watching,
  not noise.

- **A location token is single-tenant, single-MDM-vendor by design.** Reusing the same token file
  across multiple Intune tenants, or failing to formally revoke it from a prior MDM vendor before
  bringing it to Intune, is a documented way to silently corrupt license assignment and user records —
  always treat a token as belonging to exactly one MDM relationship at a time.
