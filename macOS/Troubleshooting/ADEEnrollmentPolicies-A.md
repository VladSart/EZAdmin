# Apple ADE Enrollment Policies (Settings Catalog Migration) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Covers the platform migration of Apple ADE deployment configuration from classic `enrollmentProfiles` objects to Settings Catalog-based **Enrollment policies**, and the enrollment-time Entra group assignment capability that shipped alongside it.

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

Assumes an already-functioning Apple ADE deployment: a synced Apple Business Manager/School Manager token and at least one classic enrollment profile in Intune. This runbook covers the **object-model migration** — classic ADE `enrollmentProfiles` → Settings Catalog `configurationPolicies` — and its flagship new capability, enrollment-time Entra security group assignment. It does not cover ADE token renewal, MDM push certificate lifecycle, or general enrollment failures (see `ADE-Enrollment-A.md`/`-B.md` for those) — this topic sits *inside* an already-healthy ADE pipeline, changing how the configuration served at enrollment time is authored and stored, not the enrollment mechanics themselves.

There is no dedicated Microsoft Learn conceptual article for this migration as of this writing — Microsoft's own "What's new" entry covers only the enrollment-time-grouping GA in passing, and the primary in-product signal is a deprecation warning banner on the classic Profiles blade. This runbook's object-model and Graph-schema details are corroborated against independent community documentation (a hands-on walkthrough with screenshots and a working migration script) rather than a mature Learn page, and are flagged here rather than presented as officially settled.

---

## How It Works

<details><summary>Full architecture</summary>

**The old model.** Classic Apple ADE deployment configuration in Intune lived as `enrollmentProfiles` — typed objects (`#microsoft.graph.depIOSEnrollmentProfile`, `#microsoft.graph.depMacOSEnrollmentProfile`) nested under a `depOnboardingSettings` (enrollment program token) resource. This object type predates Intune's Settings Catalog unification and has its own bespoke property set: user affinity, authentication method, Setup Assistant screen toggles, device naming template, and an `isDefault` boolean marking the token's default profile per platform. tvOS and visionOS were never represented here at all — Apple ADE support for those platforms only exists in the new model.

**The new model.** Coming with the 2606 Intune service release, Apple ADE enrollment configuration moved onto the **Settings Catalog** — the same unified policy platform (`deviceManagement/configurationPolicies` in Graph) used for compliance policies, configuration profiles, and most other modern Intune policy types. A new-style enrollment policy is a Settings Catalog object with `technologies` including `'enrollment'`, a `TemplateReference.templateId` identifying it as an ADE enrollment template for a specific platform, and a `creationSource` value of the form `DepTokenId_<tokenId>` tying it back to a specific enrollment program token. Policies exist for **iOS/iPadOS, tvOS, visionOS, and macOS**.

**Backward-compatibility mirroring.** For device-assignment UI and API compatibility, Intune mirrors every new-style policy into the *same* classic `enrollmentProfiles` collection under its owning token — so a single `GET .../depOnboardingSettings/{tokenId}/enrollmentProfiles` call returns both classic profiles and new-style policies side by side, and a plain `displayName` match works across both types. The mirrored entry's `id` is derived from the underlying Settings Catalog policy id (observed pattern: a prefix followed by `_<configurationPolicyId>`). Critically, **`isDefault` is never populated on the mirrored entry** — the classic property simply doesn't carry meaning for a Settings-Catalog-backed object, so any code (including Microsoft's own console, per community testing) that wants to find "the current default new-style policy" must fall back to querying `configurationPolicies` directly for the token's ADE template with `isAssigned eq false` (an unassigned-but-current-default heuristic, not an authoritative flag) rather than trusting `isDefault`.

**Field-for-field changes, not a straight port:**

| Area | Classic profile | New policy |
|---|---|---|
| Device group | Not available | Enrollment-time grouping via one static Entra security group |
| Supervised toggle (iOS) | Configurable | Removed — ADE devices always supervised |
| Company Portal install / VPP token (iOS) | Separate settings | Removed — handled automatically via modern auth |
| Sync with computers (iOS) | Configurable | Not exposed |
| Setup Assistant screens | Frozen list (stops receiving new screens) | Current list (Action Button, Emergency SOS, Terms of Address, Apple Intelligence, Lock Down Mode, Web Content Filtering, OS showcase, etc.) |
| Account settings (macOS) | Local admin / local primary account | Same, unchanged |
| Platforms | iOS/iPadOS, macOS only | iOS/iPadOS, tvOS, visionOS, macOS |

**Enrollment-time device grouping.** The headline new capability: a policy's **Device group** tab accepts exactly one **static** Microsoft Entra security group. When a device enrolls under that policy, Intune adds it to the group *during* enrollment — before Setup Assistant completes — rather than waiting for a subsequent dynamic-group evaluation pass. This closes the classic "device enrolled, but apps/policies took minutes to hours to arrive" gap that already didn't exist for Windows Autopilot or Android Enterprise (both had enrollment-time grouping first) but did for Apple ADE until this release. The mechanism depends on a specific service principal — **Intune Provisioning Client**, AppId `f1346770-5b25-470b-88bd-d5744ab7952c` — holding **owner** rights on the target group; without that ownership grant, the group assignment silently never happens (no error surfaced anywhere in the portal or in device enrollment logs). Only one static group per policy is supported; selecting a second group replaces rather than adds to the first, and dynamic groups are not supported as a target at all.

**Rollout mechanics that generate the most tickets.** All *newly created* enrollment policies for iOS/iPadOS/macOS automatically use the new Settings-Catalog-backed experience — there is no toggle to opt back into creating classic profiles. Existing classic profiles are **not migrated automatically** and continue to function exactly as before, just frozen (no new Setup Assistant screens, no path to enrollment-time grouping). Setting a new policy as a token's default affects only devices that sync into that token *afterward* — every device already imported from ABM/ASM keeps whatever profile/policy it was last assigned until explicitly reassigned, and reassignment itself only takes effect at the device's *next* enrollment (a wipe or hardware replacement), never retroactively on a device already in daily use. The Intune portal's device-assignment UI has no select-all/bulk-select control, making Graph-based bulk reassignment (see Remediation Playbook 2) the only practical path once a fleet exceeds a few dozen devices.

</details>

---

## Dependency Stack

```
Apple Business Manager / Apple School Manager (ABM/ASM)
   └─ Device Enrollment Program (DEP) token, synced to Intune
        └─ depOnboardingSettings (Graph: beta/deviceManagement/depOnboardingSettings/{id})
             │
             ├─ Classic path — enrollmentProfiles collection
             │    ├─ depIOSEnrollmentProfile / depMacOSEnrollmentProfile objects (native, isDefault-tracked)
             │    │    └─ FROZEN as of the 2606 release: no new Setup Assistant screens, no group assignment
             │    └─ Mirrored entries for every new-style policy (same collection, isDefault NEVER true)
             │
             └─ Settings Catalog path — configurationPolicies collection (technologies has 'enrollment')
                  └─ ADE enrollment policy (per platform: ios / tvOS / visionOS / macOS)
                       ├─ TemplateReference.templateId  (platform-specific ADE template)
                       ├─ creationSource = DepTokenId_<tokenId>  (ties policy back to its token)
                       ├─ Basics (name)
                       ├─ Device group (OPTIONAL, 0 or 1 static group)
                       │    └─ REQUIRES group owner = Intune Provisioning Client
                       │         (AppId f1346770-5b25-470b-88bd-d5744ab7952c) — silent no-op if missing
                       └─ Configuration settings (user affinity, auth method, naming, cellular,
                            Setup Assistant screen toggles — current, unlike the classic list)
                  └─ Device assignment: importedAppleDeviceIdentities.requestedEnrollmentProfileId
                       (per device, updated via updateDeviceProfileAssignment action — accepts serial
                       numbers, not object IDs; effective only at the device's NEXT enrollment)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| New Setup Assistant screen (e.g., Apple Intelligence) can't be suppressed | Device assigned to a classic profile, which never received screen updates | Triage step 1 — check profile `@odata.type` for the device's assigned profile |
| Device joined Entra group only after a delay | Classic profile has no grouping concept at all | Confirm device is assigned to a **new-style** policy, not a mirrored classic profile |
| Enrollment-time group never populates, policy looks fully configured | Intune Provisioning Client not an owner of the target group | `Get-MgGroupOwner` — look for AppId `f1346770-5b25-470b-88bd-d5744ab7952c` |
| "I set the new policy as default but nothing changed" | Default only governs devices syncing in *after* the change; already-imported devices are unaffected | Check `requestedEnrollmentProfileId` on the specific device against the new policy's mirrored ID |
| Automation querying `isDefault` can't find the current default policy | `isDefault` is never populated on Settings-Catalog-mirrored entries | Fall back to querying `configurationPolicies` for the token's ADE template with `isAssigned eq false` |
| Bulk reassignment attempted via portal times out / is abandoned | No select-all control exists in the device-assignment UI | Use Graph `updateDeviceProfileAssignment` directly or `Set-AppleADEDevicesToEnrollmentPolicy.ps1` |
| Second Entra group added to a policy, first group's devices stop getting expected grouping | Only one static group per policy is supported — second selection replaces the first | Re-check the policy's currently configured group before assuming both apply |

---

## Validation Steps

1. **Confirm token-level state (classic-only vs. hybrid vs. migrated).**
   ```powershell
   $profiles = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId/enrollmentProfiles"
   $profiles.value | Select-Object displayName, isDefault, '@odata.type'
   ```
   Good: a mix of classic (`depIOSEnrollmentProfile`) and mirrored new-style entries, or classic-only if not yet migrated. Bad/unexpected: a new-style mirrored entry showing `isDefault: true` — this should never happen; if it does, treat it as a signal the mirror behavior may have changed and re-verify against current Microsoft guidance before relying on it.

2. **Identify the actual current default for a platform (do not trust `isDefault` alone).**
   ```powershell
   $classicDefault = $profiles.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.depIOSEnrollmentProfile' -and $_.isDefault }
   if (-not $classicDefault) {
     $adeTemplateId = '27d20e9c-50c1-48f8-a44c-f37de4510051_1'  # iOS ADE template
     $filter = "(technologies has 'enrollment') and (platforms eq 'ios') and (TemplateReference/templateId eq '$adeTemplateId') and (creationSource eq 'DepTokenId_$tokenId') and (isAssigned eq false)"
     Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=$([uri]::EscapeDataString($filter))"
   }
   ```
   Good: exactly one candidate returned. Bad: zero (no default configured for this platform/token — new syncs fall back to Apple's own defaults) or more than one (ambiguous — treat as a configuration error and resolve manually before automating against it).

3. **Confirm enrollment-time grouping is live for a specific policy.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId?`$expand=settings" |
     Select-Object -ExpandProperty settings
   ```
   Good: a setting instance referencing the target group's object ID present in the payload. Bad: absent — either no group was configured, or a dynamic group was selected (unsupported, silently ignored by the policy).

4. **Confirm a specific device's actual assignment state.**
   ```powershell
   $devices = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId/importedAppleDeviceIdentities"
   $devices.value | Where-Object serialNumber -eq '<Serial>' | Select-Object serialNumber, requestedEnrollmentProfileId, enrollmentState
   ```
   Cross-reference the returned `requestedEnrollmentProfileId` against both the classic and mirrored entries from step 1 to determine whether the device is genuinely on the new policy or still on a classic/mirrored-stale assignment.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm object model in play.** Before troubleshooting any Setup Assistant/grouping symptom, always establish first whether the affected device's assigned profile is classic or new-style (Validation step 1 and 4). A large share of "missing feature" tickets are simply devices still on a classic, frozen profile — not a bug in the new policy.

**Phase 2 — Confirm default vs. assignment state.** "Default" and "assigned" are two independent axes. A policy can be the token's default (governs new ABM/ASM syncs going forward) while a specific already-imported device remains on an entirely different, previously assigned profile. Never assume setting a default retroactively touches existing inventory (Symptom → Cause Map row 4).

**Phase 3 — Confirm group-assignment prerequisites in isolation.** If enrollment-time grouping isn't working, check the three independent prerequisites separately rather than assuming a single root cause: (a) group is static, not dynamic; (b) Intune Provisioning Client holds owner rights; (c) only one static group is configured on the policy. Any one of these failing produces the identical symptom (device enrolls, group membership never appears) with zero differentiating error output.

**Phase 4 — For bulk-migration engagements, sequence rather than switch.** Recommended order: (1) recreate settings on a new policy per platform, (2) validate via a single test-device wipe/re-enroll, (3) set as default, (4) bulk-reassign already-imported devices via script (batched, `-WhatIf` first), (5) delete the old classic profile only after confirming zero devices remain assigned to it. Skipping straight to deletion of the classic profile before reassignment is complete will break enrollment for any device still pointed at it.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Full platform migration for a token (classic profile → new policy)</summary>

1. Inventory the classic profile's full settings (user affinity, auth method, naming template, cellular, Setup Assistant toggles) — there is no automated export; do this manually via the classic Profiles blade before starting.
2. Create the equivalent new policy under Enrollment policies for the same platform, reproducing every setting, and additionally configure the Device group tab if enrollment-time grouping is in scope.
3. Test: assign the new policy to a single device via the Devices blade > **Assign profile**, then wipe/re-enroll that device and confirm Setup Assistant, authentication, and (if configured) group membership all behave as expected.
4. Set the new policy as the token's default for that platform (policy context menu > **Set as default policy**). Confirm the classic Profiles blade's "Set default enrollment profile" dialog now shows an empty slot for the platform.
5. Bulk-reassign all already-imported devices for that platform (Playbook 2).
6. Once zero devices remain assigned to the old classic profile (verify via Validation step 4 across the full device list), delete it.

Rollback: at any point before step 6, reassign affected devices back to the classic profile using the same Assign-profile flow or `Set-AppleADEDevicesToEnrollmentPolicy.ps1 -PolicyName '<classic profile name>'`.

</details>

<details><summary>Playbook 2 — Bulk reassignment of already-imported devices (script-based)</summary>

The Graph action is `updateDeviceProfileAssignment`, called against the target profile/policy's mirrored `enrollmentProfiles` entry, accepting an array of **serial numbers** (not object IDs):

```powershell
$body = @{ deviceIds = @('<Serial1>','<Serial2>') } | ConvertTo-Json
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId/enrollmentProfiles/$targetId/updateDeviceProfileAssignment" `
  -Body $body
```

Use `Scripts/Set-AppleADEDevicesToEnrollmentPolicy.ps1` for anything beyond a handful of devices — it resolves the token's current default when no policy name is given (using the `isAssigned eq false` heuristic from Validation step 2, since `isDefault` cannot be trusted for new-style policies), batches serial numbers, and supports `-WhatIf`/`-SerialNumber` for staged, per-department rollouts. Reassignment takes effect only at the device's next enrollment cycle — it does not reconfigure a device already in active use.

Rollback: re-run targeting the previous profile/policy name.

</details>

<details><summary>Playbook 3 — Repair silently-broken enrollment-time grouping</summary>

1. Confirm the group is static (`Get-MgGroup` → `groupTypes` should NOT contain `DynamicMembership`).
2. Confirm ownership:
   ```powershell
   $sp = Get-MgServicePrincipal -Filter "appId eq 'f1346770-5b25-470b-88bd-d5744ab7952c'"
   Get-MgGroupOwner -GroupId $groupId | Where-Object Id -eq $sp.Id
   ```
   If empty, grant it:
   ```powershell
   New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)" }
   ```
3. Confirm the policy has exactly one group configured (Validation step 3) — if a second group was ever selected, only the most recent selection is honored; re-select the intended group explicitly.
4. Grouping cannot be backfilled onto an already-enrolled device — validate the fix via a single test-device wipe/re-enroll, not by inspecting an existing device's group membership.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Apple ADE enrollment policy migration state for escalation.
#>
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All","Group.Read.All" -NoWelcome

$tokens = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings").value

foreach ($t in $tokens) {
    Write-Output "=== Token: $($t.tokenName) ($($t.id)) ==="
    $profiles = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($t.id)/enrollmentProfiles").value
    $profiles | Select-Object displayName, isDefault, '@odata.type' | Format-Table | Out-String | Write-Output

    $policies = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'enrollment' and creationSource eq 'DepTokenId_$($t.id)'").value
    foreach ($p in $policies) {
        Write-Output "  Policy: $($p.name) / isAssigned=$($p.isAssigned)"
    }

    $devices = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($t.id)/importedAppleDeviceIdentities").value
    Write-Output "  Imported devices: $($devices.Count)"
    $devices | Group-Object requestedEnrollmentProfileId | Select-Object Name, Count | Format-Table | Out-String | Write-Output
}
```

Attach this output plus the affected device's serial number and the specific symptom to any escalation.

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| List all tokens | `Invoke-MgGraphRequest GET beta/deviceManagement/depOnboardingSettings` |
| List profiles/policies (mirrored, single collection) for a token | `.../depOnboardingSettings/{id}/enrollmentProfiles` |
| List new-style policies directly (Settings Catalog) | `beta/deviceManagement/configurationPolicies?$filter=technologies has 'enrollment'` |
| List imported devices for a token | `.../depOnboardingSettings/{id}/importedAppleDeviceIdentities` |
| Reassign devices to a profile/policy | `POST .../enrollmentProfiles/{id}/updateDeviceProfileAssignment` with `{ deviceIds: [serials] }` |
| Get group owners | `Get-MgGroupOwner -GroupId <id>` |
| Add Intune Provisioning Client as group owner | `New-MgGroupOwnerByRef` with AppId `f1346770-5b25-470b-88bd-d5744ab7952c` |
| Check whether a policy is currently default (mirrored entries never say so) | Fall back to `configurationPolicies` `isAssigned eq false` heuristic |
| Portal: classic profiles | Devices > Enrollment > Apple > Enrollment program tokens > [token] > **Profiles** |
| Portal: new-style policies | Devices > Enrollment > Apple > Enrollment program tokens > [token] > **Enrollment policies** |
| Portal: assign a device | Token > **Devices** blade > select device > **Assign profile** (no select-all) |

---

## 🎓 Learning Pointers

- This is a rare case of a fully invisible-by-default platform migration: nothing breaks, nothing is forced, and the only in-product signal is a deprecation banner most admins won't see until they happen to open the classic Profiles blade. Proactively check token state (Validation step 1) for every Apple ADE client rather than waiting for a ticket. [Intune what's new](https://learn.microsoft.com/en-us/intune/whats-new/)
- The `isDefault`-never-populated-on-mirrored-entries behavior is the single most Graph-automation-breaking detail here — any existing script or report built against the classic `enrollmentProfiles` collection's `isDefault` field will silently misreport "no default configured" the moment a tenant migrates its default to a new-style policy. Audit any existing ADE automation for this dependency before a client migrates.
- Enrollment-time grouping's silent-failure mode (missing service-principal ownership) has no error surface anywhere — portal, Graph response, or device enrollment logs. Treat "group not populating" as a checklist to walk (static? owned by the right SP? only one group?) rather than a single diagnosable fault.
- tvOS and visionOS ADE support exists *only* in the new policy model — if a client asks about buying into tvOS/visionOS zero-touch deployment, the answer starts with "you'll be on the new policy type by necessity," which is a useful lever for getting reluctant fleets to migrate proactively rather than reactively.
- No official Microsoft Learn conceptual page exists for this migration as of this writing — this runbook's Graph-schema details (template IDs, `creationSource` format, mirrored-ID pattern) are sourced from independent, hands-on community documentation rather than a primary Microsoft source. Re-verify template IDs and schema details against the live tenant before trusting them blindly in unfamiliar environments, and revisit this runbook if Microsoft publishes an official reference.
