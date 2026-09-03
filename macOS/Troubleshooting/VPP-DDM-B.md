# Apple VPP App Management via DDM — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** starting with Intune service release 2608 (August 2026), a VPP/location token's **Management type** can be set to **DDM** (Declarative Device Management) instead of the long-standing default **MDM**. This is a **token-level setting chosen when the token is created**, not a per-app or per-device toggle — every app synced through that token deploys using whichever model the token was configured with. This is a different DDM surface than `DDM-A/B.md` (software update enforcement) or `AppSettings-A/B.md` (app configuration/restriction settings) — this one governs **how the VPP app itself is delivered and installed**.

The single most common ticket on this topic: **"I set this app to Available for self-service install and nobody can install it."** DDM-managed VPP apps **only support Required or Uninstall assignment intent** — Available isn't supported yet. That's not a bug.

Run these first, in this order:

```
# 1. Confirm which management type the affected app's token uses
Intune admin center → Tenant administration → Connectors and tokens → Apple VPP tokens
→ select the token → check "Management type" (MDM or DDM)

# 2. If DDM, confirm the assignment intent on the app itself
Intune admin center → Apps → All apps → select the app → Properties → Assignments
# Bad: assignment intent is "Available" on a DDM-managed app → Fix 1

# 3. Confirm the target device's OS version against the DDM floor
# iOS/iPadOS and macOS minimum version requirements are stated on the token's
# own documentation — confirm against the CURRENT Microsoft Learn page before
# assuming a specific floor, since the announced floor and the reference-page
# floor have not fully converged as of this writing (see Learning Pointers)
Get device OS version: Devices → All devices → select device → Device details

# 4. Confirm the app was actually associated with a DDM-type token, not a legacy MDM token
Intune admin center → Apps → All apps → filter/search app → check "VPP token name" column
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| App assigned as "Available" never appears for self-service install | DDM-managed VPP apps don't support Available assignment yet | Fix 1 |
| App doesn't install on some devices in a fleet, works fine on others | Devices below the DDM OS-version floor associated with a DDM-only token | Fix 2 |
| Admin expected to flip an existing MDM token to DDM in place, can't find the control | Management type is chosen when a token is uploaded/created — not confirmed editable on an existing token after creation | Fix 3 |
| App status shows stale/inconsistent info in the admin center | DDM's real-time status reporting depends on the device actually checking in against its declarative status channel — a device that hasn't synced recently will show old status | Fix 4 |
| Automatic app updates not happening for a DDM-managed app | Automatic app updates is a new **per-app** setting under DDM — confirm it was actually turned on for that app, don't assume DDM implies auto-update | Fix 5 |
| Ticket mentions "associated domains" or per-app settings gaps for a DDM VPP app | Expected — DDM expands per-app attribute options (e.g. associated domains) but the exact settings surface is still maturing; confirm current capability against the live Learn page before promising a specific setting exists | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for a DDM-managed VPP app to install</summary>

```
[Apple Business Manager / Apple School Manager account]
    └── [Location token (VPP token) downloaded and uploaded to Intune]
            └── [Token Settings page: Management type = DDM
                 (chosen at token creation; MDM is the default)]
                    ├── [Device meets the DDM OS-version floor
                    │    (iOS/iPadOS and macOS — confirm current exact floor
                    │     against the live Learn page; announced as 17.2+/macOS 26+
                    │     in the What's New post)]
                    │        └── [App assignment intent = Required or Uninstall
                    │             (Available NOT supported under DDM)]
                    │                └── [Device declarative-status channel reports
                    │                     back to Intune — near-real-time app status]
                    └── [Device below the OS floor → select MDM for that
                         token/app population instead; DDM has no documented
                         automatic per-device fallback]
```

</details>

---
## Diagnosis & Validation Flow

1. **Identify the token's management type.** Tenant administration > Connectors and tokens > Apple VPP tokens > select token > check the **Management type** field directly — don't assume based on token age (only tokens created/re-configured after the 2608 release could even offer DDM).

2. **Cross-check the app's assignment intent.** Apps > All apps > app > Properties > Assignments. If Management type is DDM and intent is `Available`, this is the expected-behavior explanation, not a fault — see Fix 1.

3. **Confirm device OS version against the floor.** Devices > All devices > device > Device details. Compare against the current documented floor on the live Learn page rather than a cached number, since Preview-era feature floors can shift between announcement and full documentation maturity.

4. **Check the app's per-app Automatic app updates setting**, if update behavior is the complaint. This is new and DDM-specific — it does not inherit from the token-level VPP "Automatic app updates" toggle used by MDM-managed apps.

5. **Confirm token status is healthy overall** (not Expired/Invalid/Duplicate) — a DDM-configured token is still subject to every ordinary VPP token health requirement covered in `VPP-App-Deployment-B.md`; this runbook only adds the DDM-specific layer on top.

---
## Common Fix Paths

<details><summary>Fix 1 — App set to "Available" isn't installable under DDM</summary>

No configuration fix exists yet — DDM-managed VPP apps only support **Required** and **Uninstall** intents.

Options:
1. Change the assignment intent to **Required** if self-service optionality isn't a hard requirement.
2. If self-service Available-style install is a hard requirement, move that specific app to an **MDM-managed token** instead (a separate token upload, since management type is chosen at token creation).

```
Intune admin center → Apps → All apps → select app → Properties → Edit next to
Assignments → change intent from Available to Required (or reassign under an
MDM-type token if Available is a hard requirement)
```
Rollback: revert the assignment intent change; no device-side rollback needed since Available assignments were never functional under DDM to begin with.
</details>

<details><summary>Fix 2 — Some devices in the fleet don't get the app (OS floor)</summary>

```
# Identify devices below the DDM floor
Intune admin center → Devices → All devices → filter by Operating system version
# Compare against the current documented DDM floor before treating a device as
# non-compliant — confirm on the live Learn page, not from memory
```

Because DDM has no documented automatic per-device fallback to MDM within the same token, devices below the floor associated with a DDM-only token will not receive the app at all. Either:
1. Maintain a **separate MDM-type token** for the sub-floor device population and assign the app there as well, or
2. Hold the DDM migration until fleet-wide OS adoption clears the floor.

Rollback: reassign affected devices' groups to the MDM-token-based app assignment instead.
</details>

<details><summary>Fix 3 — Can't find a control to convert an existing MDM token to DDM</summary>

As of this writing, Management type is presented as a **Settings**-page choice during token **creation** (Basics > Settings > Management type: MDM or DDM). Whether this is editable on an already-created token via **Edit** has not been independently confirmed in this runbook — treat "convert in place" as unverified rather than assuming it's unsupported outright.

Safe path regardless: **upload the location token again as a new token entry** with Management type = DDM, and reassign the desired apps to the new token. Do not delete the original MDM token or its app assignments until the new DDM-token assignments are confirmed working, per the standard token-migration caution in `VPP-App-Deployment-A.md`.
</details>

<details><summary>Fix 4 — App status looks stale in the admin center</summary>

```
# Force a token sync first (refreshes token-side metadata, not device status)
Intune admin center → Tenant administration → Connectors and tokens →
Apple VPP tokens → select token → Sync

# Then confirm the device itself has checked in recently
Devices → All devices → select device → check Last check-in time
```
DDM's "real-time" status framing depends on the device actually being online and checking in against its declarative status channel — a device that has been offline or unsynced for an extended period will show outdated status regardless of the DDM model's normal responsiveness.

Rollback: none — this is a sync/timing issue, not a configuration change.
</details>

<details><summary>Fix 5 — Automatic app updates not happening under DDM</summary>

```
Intune admin center → Apps → iOS/iPadOS or macOS → select the DDM-managed VPP app
→ Properties → confirm the app-level Automatic app updates setting is turned On
```
This is a new **per-app** setting introduced alongside DDM management type — it is independent of the token-level "Allow automatic updates" toggle used for MDM-managed apps under the same or a different token. Don't assume one implies the other.

Rollback: turn the per-app setting Off to return to manual/Company-Portal-initiated updates.
</details>

<details><summary>Fix 6 — Expected per-app setting (e.g. associated domains) not available yet</summary>

DDM's expanded per-app attribute options are new and still maturing as a documented, stable settings surface. Before promising a specific capability to a requester, verify it against the current Microsoft Learn reference page rather than the original What's New announcement, since announcement posts often describe capability direction ahead of full settings-catalog implementation.
</details>

---
## Escalation Evidence

```
=== VPP DDM App Management — Escalation Template ===
Token name:
Token Management type (MDM/DDM):
Token status (Active/Expired/Invalid/Duplicate):
App name:
App assignment intent (Required/Available/Uninstall):
Target device name(s) + OS version:
Device last check-in time:
Automatic app updates (per-app setting) state:
Expected behavior vs. observed behavior:
Screenshot of app Properties > Assignments pane:
Screenshot of token Settings > Management type field:
```

---
## 🎓 Learning Pointers

- DDM management type is a **token-level choice made at creation**, not a per-app or per-device switch — plan which apps go under a DDM token vs. an MDM token *before* uploading, since converting in place is unverified. [Manage Apple Volume-Purchased Apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)
- **Available assignment intent is not supported under DDM** — this single limitation explains the large majority of early tickets on this feature. Confirm assignment intent first, before investigating anything else.
- The announced OS-version floor (iOS/iPadOS 17.2+, macOS 26+, per the Intune What's New post) and the general VPP reference page's stated floor (iOS/iPadOS 18+) have not been independently reconciled in this runbook — verify the current authoritative floor on the live Learn page before communicating a specific number to a customer or using it as a hard go/no-go gate.
- This is a **third, distinct DDM application area** in this repo's coverage: `DDM-A/B.md` governs software update enforcement, `AppSettings-A/B.md` governs app configuration/restriction settings, and this topic governs VPP **app deployment and delivery** itself. All three are part of Apple's same underlying Declarative Device Management framework but are independently configured, independently gated by OS floors, and independently troubleshot.
- Because this is a service-release-era feature (2608, August 2026), treat any specific settings-surface claim beyond the core Management type/assignment-intent/automatic-update behavior as subject to change — re-verify against the live Learn page before it's used as the basis for a customer commitment.
