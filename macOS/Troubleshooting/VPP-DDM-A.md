# Apple VPP App Management via DDM — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **Declarative Device Management (DDM) management type** for Apple Volume Purchase Program (VPP) apps, introduced for Microsoft Intune in service release 2608 (August 2026). It assumes a working Apple Business Manager or Apple School Manager tenant with at least one location token (VPP token) already uploaded to Intune, and familiarity with conventional MDM-managed VPP app deployment (`VPP-App-Deployment-A.md`).

This is explicitly **not**:
- Software update enforcement via DDM (`DDM-A.md`) — a different declarative surface governing OS update deadlines, not app deployment.
- App configuration/restriction settings via DDM (`AppSettings-A.md`) — a different declarative surface governing per-app managed settings once an app is already installed.
- The general MDM-based VPP token/app management workflow (token upload, license assignment, revocation) — that full lifecycle is unchanged by DDM and remains covered in `VPP-App-Deployment-A.md`; this runbook covers only what changes when Management type is set to DDM.

**Source-confidence note:** the Intune What's New announcement for this feature states an OS-version floor of iOS/iPadOS 17.2+ and macOS 26+. The general VPP management reference page states, in its Management type field description, "Declarative Device Management (DDM) uses Apple's policy-based management model for app deployment and configuration on devices running iOS/iPadOS 18 and later." These two floors have not been reconciled here — verify the live, current floor on the Learn page before using it as a hard compatibility gate, consistent with this repo's standing practice for recently-announced features whose documentation is still stabilizing (see `macOS15MinimumVersion-A.md` for the same pattern applied to a different topic).

---
## How It Works

<details><summary>Full architecture</summary>

Historically, all Intune-managed VPP app deployment — regardless of Apple platform — has used the classic **MDM command-and-response model**: Intune issues an `InstallApplication` MDM command to the device, the device attempts the install, and reports success/failure back via the standard MDM check-in cycle. This model is reliable but coarse-grained: status visibility is check-in-cycle-bound (not real-time), and per-app configuration options are limited to what the MDM protocol's install command supports.

**Declarative Device Management (DDM)** inverts this. Instead of Intune issuing an imperative command and waiting for a response, Intune publishes a **declaration** describing the desired app state (which apps, which version behavior, which assignment posture). The device itself is responsible for continuously evaluating its own state against that declaration and reporting status changes proactively — the same general architecture already used elsewhere in this repo's Apple coverage for software update enforcement (`DDM-A.md`) and app configuration (`AppSettings-A.md`), now extended to cover the **app installation/delivery layer itself**.

```
                    MDM MODEL (default, unchanged)              DDM MODEL (new, 2608+)
                    ───────────────────────────────             ───────────────────────
Intune               "Install this app"                          "Here is the declared
                       (imperative command)                        app state for this
                                                                    device — required,
                                                                    version behavior,
                                                                    associated domains"
                              │                                           │
                              ▼                                           ▼
Device                Executes install on                        Continuously evaluates
                       next MDM check-in,                         local state vs. the
                       reports result at                          declaration; reports
                       next check-in                              proactively on change
                              │                                           │
                              ▼                                           ▼
Intune Admin           Status reflects the                        Status reflects
Center                 last completed                             near-real-time device-
                       check-in cycle                              side evaluation
```

The practical consequences this repo's engineers hit most often:

1. **Assignment model gap.** DDM's declaration model, as currently implemented, only expresses two app postures cleanly: "this app must be present" (Required) and "this app must not be present" (Uninstall). The MDM model's third posture — "this app may optionally be installed by the user via Company Portal" (Available) — has no DDM declaration equivalent yet. This is a genuine, current product gap, not a configuration error.

2. **Token-level, not app-level, scoping.** Management type is a property of the **token**, set once at token creation. Every app synced through a given token inherits that token's management type. This means an organization wanting a mix of DDM-delivered Required apps and MDM-delivered Available apps needs **two separate tokens** against the same Apple Business Manager location (or two locations), not one token with mixed per-app behavior.

3. **New per-app settings surface.** Because DDM apps carry a richer declaration than a bare MDM install command, Microsoft introduced new per-app settings alongside this feature — most notably a dedicated **Automatic app updates** toggle at the app level, and expanded per-app associated-domains attribute options. These are additive to, not replacements for, the existing token-level "Allow automatic updates" setting used by MDM-managed apps.

</details>

---
## Dependency Stack

```
Layer 5:  Device-side declarative status evaluation & reporting (near-real-time)
Layer 4:  Intune app object — assignment intent constrained to Required/Uninstall
              under DDM (Available unsupported); per-app Automatic app updates setting
Layer 3:  Location token — Management type = DDM (set at token creation;
              MDM remains the default for new and existing tokens)
Layer 2:  Device OS floor — iOS/iPadOS and macOS minimum version
              (confirm current authoritative floor on the live Learn page;
               see Scope & Assumptions source-confidence note)
Layer 1:  Apple Business Manager / Apple School Manager location token,
              downloaded and uploaded to Intune (standard VPP prerequisite,
              unchanged by DDM — see VPP-App-Deployment-A.md)
```

A gap at Layer 2 (device below the OS floor) or Layer 1 (unhealthy token) makes the DDM-specific Layer 3-5 behavior moot — troubleshoot bottom-up, same discipline as every other Apple declarative-management topic in this repo.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| App assigned Available never installs via self-service | DDM doesn't support Available intent | Assignment intent on the app |
| App simply absent on some devices, present on others under the same token | Absent devices are below the DDM OS floor | Device OS version vs. current documented floor |
| Admin can't locate a "convert to DDM" control on an existing token | Management type selection may only be exposed at token creation | Token Settings page; consider new-token-upload workaround |
| App status in admin center looks stale compared to DDM's "real-time" framing | Device hasn't checked in / declarative status channel hasn't synced recently | Device Last check-in time |
| Automatic updates not happening despite "DDM should handle this automatically" assumption | Automatic app updates is an explicit per-app toggle, not implicit under DDM | App Properties > Automatic app updates setting |
| Per-app setting (e.g. associated domains) requested by a stakeholder doesn't appear configurable | Settings surface still maturing post-announcement | Compare live Learn page against announcement-era claims |
| Mixed Required/Available strategy for the same app population breaks under DDM | Architectural limitation — one token can't express both postures per-app under DDM | Split into a second token if Available is a hard requirement |

---
## Validation Steps

1. **Confirm token Management type.**
   Tenant administration > Connectors and tokens > Apple VPP tokens > select token. Good: field explicitly reads `DDM`. Bad: field reads `MDM` when DDM behavior was expected — the app is not actually under DDM management, and none of this runbook's DDM-specific behavior applies.

2. **Confirm assignment intent compatibility.**
   Apps > All apps > app > Properties > Assignments. Good: intent is `Required` or `Uninstall`. Bad: intent is `Available` — this configuration is currently unsupported under DDM and won't function as intended regardless of device health.

3. **Confirm device OS version against the current documented floor.**
   Devices > All devices > device > Device details, compared against the live Learn page (not this runbook's cached numbers, given the source-confidence caveat above). Good: device meets or exceeds the floor. Bad: device below floor and no MDM-token fallback assignment exists for it.

4. **Confirm per-app Automatic app updates state**, if update timing is in question.
   Apps > iOS/iPadOS or macOS > app > Properties. Good: explicit On/Off state visible and matches expected behavior. Bad: assumption that DDM auto-updates without checking this setting.

5. **Confirm device check-in recency** before treating status as stale.
   Devices > All devices > device > Last check-in time. Good: recent (within normal check-in cadence for the platform). Bad: stale check-in explains apparently-stale DDM status without any DDM-specific fault.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Token-level validation.** Confirm Management type, token health (Active, not Expired/Invalid/Duplicate — see `VPP-App-Deployment-A.md`), and that the affected app is actually synced through the token believed to be in play (multiple tokens can each surface an app separately in the Apps list).

**Phase 2 — Assignment model validation.** Confirm assignment intent is Required or Uninstall. This single check resolves the majority of early DDM-VPP tickets and should be checked before any device-side investigation begins.

**Phase 3 — Device eligibility.** Confirm OS version against the current floor. For a mixed-OS fleet, determine whether the organization needs a parallel MDM-token assignment for sub-floor devices, since DDM has no documented automatic per-device fallback within a single token.

**Phase 4 — App-level settings.** Confirm the per-app Automatic app updates toggle and any other DDM-specific per-app settings match the expected configuration — these are new, additive settings that don't inherit from token-level MDM-era defaults.

**Phase 5 — Device-side timing.** If status appears stale, rule out simple check-in recency before escalating as a DDM reporting defect.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrating a set of Required VPP apps from MDM to DDM management</summary>

1. Confirm the target app population is entirely **Required** or **Uninstall** intent today — any app currently assigned Available must either move to Required or remain on the MDM token permanently.
2. Confirm target device population meets the current documented OS floor; segment out any devices that don't for a continued MDM-token assignment.
3. Upload the Apple Business Manager location token again as a **new** token entry in Intune, setting Management type to DDM on the Settings page during creation.
4. Reassign the target apps' assignments to the new DDM token's synced app objects (the same underlying App Store apps will appear as new entries associated with the new token, per the standard "an app can appear multiple times if associated with multiple tokens" VPP behavior).
5. Pilot on a small device cohort — confirm install success and status reporting before expanding.
6. Once confirmed, remove the old MDM-token assignment for the migrated apps (do not delete the original token itself, and do not revoke licenses prematurely — follow the standard token-migration caution in `VPP-App-Deployment-A.md`).
7. Document which apps live under which token and why, since the admin center doesn't surface historical rationale for a given token's management type choice.

Rollback: reassign the affected apps back to the original MDM token's app objects; DDM assignment removal does not uninstall already-installed apps by itself unless explicitly set to Uninstall intent.

</details>

<details><summary>Playbook 2 — Handling a mixed-OS-floor fleet that needs both DDM and MDM coverage for the same app</summary>

1. Segment the target Entra device/user groups into "meets DDM floor" and "below DDM floor" populations based on current OS version data.
2. Maintain **two** token/app assignment pairs for the same underlying app: one DDM-managed token assigned as Required to the above-floor group, one MDM-managed token assigned (Required or Available, as needed) to the below-floor group.
3. Monitor OS version adoption over time; as devices cross the floor, move their group membership from the MDM-targeted group to the DDM-targeted group rather than leaving them on dual assignment (dual assignment of the same app via two tokens to the same device is not a supported/tested configuration).
4. Retire the MDM-side assignment once fleet-wide adoption clears the floor, consistent with a standard OS-floor sunset pattern (see `macOS15MinimumVersion-A.md` for the analogous end-state discipline on a different feature).

Rollback: move affected device groups back to the MDM-token assignment at any point; this doesn't require token deletion or license revocation.

</details>

---
## Evidence Pack

```
# Manual evidence collection — no dedicated Graph/PowerShell surface for VPP
# token Management type or DDM app declaration status has been confirmed as of
# this writing; collect the following directly from the Intune admin center UI.

1. Tenant administration > Connectors and tokens > Apple VPP tokens
   → screenshot of the token list showing Management type column for the
     affected token(s)

2. Apps > All apps > affected app > Properties
   → screenshot of Assignments (intent) and, if present, Automatic app updates
     setting

3. Devices > All devices > affected device(s) > Device details
   → OS version, Last check-in time

4. Tenant administration > Connectors and tokens > Apple VPP tokens > token
   → Status and Expiration date (rule out ordinary token health issues per
     VPP-App-Deployment-A.md before treating this as DDM-specific)
```

```powershell
# Supporting device-side OS version check via Graph (read-only), useful for
# bulk floor-compliance checks ahead of a DDM migration
# Requires: Microsoft.Graph.DeviceManagement module, DeviceManagementManagedDevices.Read.All
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
    Select-Object DeviceName, OperatingSystem, OsVersion, UserPrincipalName |
    Sort-Object OsVersion
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check a token's Management type | Tenant administration > Connectors and tokens > Apple VPP tokens > token |
| Set Management type at token creation | Create VPP token > Settings page > Management type: MDM or DDM |
| Check an app's assignment intent | Apps > All apps > app > Properties > Assignments |
| Check per-app Automatic app updates | Apps > iOS/iPadOS or macOS > app > Properties |
| Force a token sync | Apple VPP tokens > token > Sync |
| Check device OS version | Devices > All devices > device > Device details |
| Check device last check-in | Devices > All devices > device > Overview |
| Bulk-check macOS device OS versions (Graph) | `Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'"` |
| Reassign an app to a different token | Upload the location token again as a new token entry, then reassign app groups |

---
## 🎓 Learning Pointers

- DDM for VPP apps inverts the classic MDM install-command model: instead of Intune telling the device what to do and waiting for a check-in response, Intune publishes a declaration and the device proactively evaluates and reports its own state. This is the same architectural family as `DDM-A.md` (software updates) and `AppSettings-A.md` (app configuration), now extended to app delivery itself. [Manage Apple Volume-Purchased Apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/manage-vpp-apple)
- **Management type is chosen once per token, at creation** — it is not a per-app or per-device setting, and converting an existing token in place is unverified in current documentation. Plan token architecture (how many tokens, which apps go where) before the first DDM token upload, not after.
- **Available assignment intent has no DDM equivalent yet.** This single limitation is the most consequential current constraint on adoption — any app population that genuinely needs optional self-service install must stay on an MDM-managed token.
- The announced OS floor (17.2+/macOS 26+) and the general reference page's stated floor (18+) diverge in current Microsoft documentation. Don't repeat either number to a stakeholder as settled fact without checking the live page first — this is the same discipline this repo applies to other recently-announced, still-stabilizing features.
- New per-app settings (Automatic app updates, expanded associated-domains options) are **additive to, not inherited from,** the token-level settings used by MDM-managed apps under the classic model — don't assume DDM apps pick up MDM-era token defaults automatically.
