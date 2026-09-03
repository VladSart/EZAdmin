# Apple ADE Enrollment Policies (Settings Catalog Migration) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers the new Apple ADE **Enrollment policies** blade (iOS/iPadOS, macOS, tvOS, visionOS) that is replacing classic ADE **enrollment profiles**, and enrollment-time Entra group assignment. Distinct from general ADE/DEP token or push-cert failures — see `ADE-Enrollment-B.md` for those.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

Run from PowerShell with Graph access (`DeviceManagementServiceConfig.Read.All`):

```powershell
Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome

# 1. Is this tenant/token still on classic profiles only, or has a new-style policy been created?
$tokens = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings"
foreach ($t in $tokens.value) {
    $profiles = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$($t.id)/enrollmentProfiles"
    $profiles.value | Select-Object displayName, isDefault, '@odata.type' | Format-Table
}
# Classic profile type: #microsoft.graph.depIOSEnrollmentProfile / depMacOSEnrollmentProfile
# New-style policies mirror into this SAME collection but never set isDefault = true

# 2. Is the ticket's device actually assigned to the new policy, or still on the frozen old profile?
# Intune portal > Devices > Enrollment > Apple > Enrollment program tokens > [token] > Devices
# Look at "Enrollment profile assigned" column for the specific serial number

# 3. Check for the deprecation warning banner (confirms this tenant has new-style policies available)
# Intune portal > ... > Profiles blade > look for: "The iOS/iPadOS and macOS enrollment profiles are
# no longer being updated. We recommend that you create new Enrollment policies to replace them."

# 4. If the complaint is "group membership / apps didn't apply at Setup Assistant" — check whether
# the ENROLLMENT POLICY (not a classic profile) has a Device group configured
$policy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=technologies has 'enrollment'"
$policy.value | Select-Object name, id, technologies

# 5. Confirm the Intune Provisioning Client service principal owns the target static group
# (required for enrollment-time grouping to work at all)
Get-MgGroup -Filter "displayName eq '<GroupName>'" | ForEach-Object {
    Get-MgGroupOwner -GroupId $_.Id
}
# Expect an owner with AppId f1346770-5b25-470b-88bd-d5744ab7952c (Intune Provisioning Client)
```

| Symptom | Likely cause | Fix |
|---|---|---|
| New Setup Assistant screens (Action Button, Apple Intelligence, Terms of Address) can't be hidden | Device is still on a classic profile — those screens were never added to the classic profile editor | Fix 1 |
| Device didn't join the expected Entra group until minutes/hours after enrollment | Classic profile has no group-assignment concept at all — only new-style policies support enrollment-time grouping | Fix 2 |
| Set new policy as default, but devices already imported from ABM/ASM still enroll with old settings | Default only applies to devices that sync into the token *after* the change; already-imported devices keep their assigned profile until reassigned | Fix 3 |
| Enrollment-time group assignment silently doesn't happen | Static group is missing the Intune Provisioning Client (`f1346770-5b25-470b-88bd-d5744ab7952c`) as an owner, or the group is dynamic instead of static, or a second static group is already assigned to the same policy | Fix 4 |
| Portal shows profile assigned, but device still shows old Company Portal auto-install behavior on iOS | Classic-profile-specific option (Company Portal install / VPP token settings) — new policies handle this automatically via modern auth and don't expose the setting | Fix 5 |
| Bulk-reassigning hundreds of already-imported devices to the new policy | Intune portal device list has **no "select all"** — page-by-page only | Fix 6 (script) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Business Manager / School Manager (ABM/ASM)
   └─ Device Enrollment Program (DEP) token synced to Intune
        └─ Enrollment program token (depOnboardingSettings object)
             ├─ Classic collection: enrollmentProfiles
             │    ├─ depIOSEnrollmentProfile / depMacOSEnrollmentProfile (classic, FROZEN — no new features)
             │    └─ New-style policy, MIRRORED here (isDefault never populated on the mirror)
             └─ Settings Catalog collection: configurationPolicies (technologies has 'enrollment')
                  └─ ADE template reference (per platform) + creationSource = DepTokenId_<tokenId>
                       └─ Device group tab (OPTIONAL) → static Entra security group
                            └─ REQUIRES: Intune Provisioning Client (AppId f1346770-5b25-470b-88bd-d5744ab7952c)
                                          as group OWNER, or the assignment silently fails
                       └─ Configuration settings tab → user affinity, auth method, Setup Assistant
                            screen toggles, device naming, cellular — mirrors classic options but current
```

- **New policies exist for iOS/iPadOS, tvOS, visionOS, and macOS** — tvOS and visionOS were never available as classic profiles at all.
- **Supervised (iOS) is no longer a toggle** — ADE devices are always supervised under the new model.
- **Company Portal install / VPP token settings are gone** — handled automatically with modern authentication.
- Every device stays on whatever profile/policy it was assigned when it last enrolled/re-enrolled — reassignment only takes effect at the *next* enrollment (wipe, replacement, or a fresh sync-in).

</details>

---

## Diagnosis & Validation Flow

1. **Confirm which type of object the device is actually assigned to.**
   ```powershell
   $devices = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId/importedAppleDeviceIdentities"
   $devices.value | Where-Object serialNumber -eq '<Serial>' | Select-Object serialNumber, requestedEnrollmentProfileId, enrollmentState
   ```
   Cross-reference `requestedEnrollmentProfileId` against the profile list from Triage step 1. If it matches a classic `depIOSEnrollmentProfile`/`depMacOSEnrollmentProfile` object ID, the device is on the frozen classic path — expected output for an unmigrated device, not a bug.

2. **Confirm the new policy is actually the token's default.**
   Portal: Enrollment program tokens > [token] > Enrollment policies blade > policy context menu > check for "Unset as default" (present only on the current default). The old Profiles blade's "Set default enrollment profile" dialog should show an empty slot for that platform once a new policy is default — a populated slot there means the classic profile is still default and no new-style policy has taken over.

3. **Confirm the Device group tab is actually configured (not just present in the UI).**
   ```powershell
   $policyDetail = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$policyId?`$expand=settings"
   # Look for a setting instance referencing the enrollment-time group template; absence means no group configured
   ```
   Expected good output: the target static group's object ID appears in the policy's settings payload. Bad: no group-related setting present — the policy was created without one, or with a dynamic group (unsupported — only static groups work).

4. **Confirm the owner requirement on the target group.**
   ```powershell
   Get-MgGroupOwner -GroupId $groupId | Select-Object Id, AdditionalProperties
   ```
   Expected good: one owner entry with `AppId` = `f1346770-5b25-470b-88bd-d5744ab7952c`. Bad: no owners, or only human/service-principal owners unrelated to Intune — enrollment-time grouping will not populate membership even though the policy looks fully configured.

---

## Common Fix Paths

<details><summary>Fix 1 — Migrate a classic profile to a new-style policy so current Setup Assistant screens/features apply</summary>

1. Portal: Enrollment program tokens > [token] > **Enrollment policies** blade (next to the classic Profiles blade) > **Create**.
2. Recreate the classic profile's settings on the new policy: user affinity, auth method, device naming, cellular, Setup Assistant screen toggles (the list is current — includes Action Button, Emergency SOS, Terms of Address, Apple Intelligence, Lock Down Mode, Web Content Filtering, OS showcase).
3. Test on one device first: token's **Devices** blade > select device > **Assign profile** > pick the new policy > wipe/re-enroll the test device to confirm.
4. Once validated, set the new policy as default (policy context menu > **Set as default policy**). This affects only devices that sync in *after* this point — see Fix 3 for already-imported devices.
5. Leave the old classic profile in place (non-default) until all devices are confirmed migrated (Fix 6), then delete it.

Rollback: reassign affected devices back to the classic profile via the same `Assign profile` flow or the script in Fix 6 with `-PolicyName '<old profile name>'`.

</details>

<details><summary>Fix 2 — Enable enrollment-time device group assignment</summary>

1. Create a **static** Microsoft Entra security group (dynamic groups are not supported for this).
2. Add the Intune Provisioning Client service principal as an **owner**:
   ```powershell
   $sp = Get-MgServicePrincipal -Filter "appId eq 'f1346770-5b25-470b-88bd-d5744ab7952c'"
   New-MgGroupOwnerByRef -GroupId $groupId -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)" }
   ```
3. In the enrollment policy's **Device group** tab, select the group. Only **one** static group per policy — a second attempt overwrites the first, it does not add a second group.
4. Devices assigned to this policy join the group during enrollment itself, before Setup Assistant completes — not after a background dynamic-group evaluation cycle.

</details>

<details><summary>Fix 3 — Migrate already-imported devices to the new default policy (setting default alone does nothing for them)</summary>

Setting a policy as default only affects devices that sync into the token afterward. Every device already imported from ABM/ASM keeps its previously assigned profile/policy until explicitly reassigned. The portal device list has no select-all — for more than a handful of devices, use Graph directly via `updateDeviceProfileAssignment`, which accepts serial numbers:

```powershell
$body = @{ deviceIds = @('<Serial1>', '<Serial2>') } | ConvertTo-Json
Invoke-MgGraphRequest -Method POST `
  -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/$tokenId/enrollmentProfiles/$policyId/updateDeviceProfileAssignment" `
  -Body $body
```

For bulk migration of an entire token, use `Set-AppleADEDevicesToEnrollmentPolicy.ps1` (supports `-WhatIf`, batches serial numbers, and can target a named policy or the token's current default). Reassignment takes effect at the device's *next* enrollment (wipe/replacement) — it does not retroactively reconfigure a device already in daily use.

</details>

<details><summary>Fix 4 — Fix silent enrollment-time-group failure</summary>

1. Confirm the group is **static**, not dynamic — dynamic groups are not supported as the enrollment-time target.
2. Confirm the Intune Provisioning Client owns the group (see Diagnosis step 4). If missing, add it (Fix 2, step 2) — no error surfaces anywhere in the portal when this is missing, the device simply never joins the group.
3. Confirm only one static group is targeted on the policy — if a second was ever selected, the first was silently replaced, not added alongside it.
4. Re-test with a single device wipe/re-enroll after correcting ownership; enrollment-time group membership cannot be backfilled onto an already-enrolled device without re-enrolling it.

</details>

<details><summary>Fix 5 — "Missing" classic-only settings on a new policy (expected, not a bug)</summary>

The following classic profile options have **no equivalent** in the new policy model and should not be chased as a defect:
- iOS Supervised toggle — always on for ADE devices now.
- Install Company Portal app / VPP token settings — handled automatically via modern auth.
- Sync with computers (iOS) — not exposed in the new wizard.

Confirm with the requester whether the underlying business need (e.g., "app not auto-installing") is actually caused by one of these removed settings before treating it as broken policy configuration.

</details>

<details><summary>Fix 6 — Bulk device reassignment (script reference)</summary>

See `Scripts/Set-AppleADEDevicesToEnrollmentPolicy.ps1`. Always run with `-WhatIf` first:

```powershell
.\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -Platform ios -WhatIf
.\Set-AppleADEDevicesToEnrollmentPolicy.ps1 -Platform ios
```

Rollback: re-run against the previous policy/profile name with `-PolicyName '<old name>'`.

</details>

---

## Escalation Evidence

```
=== ADE Enrollment Policy Escalation ===
Tenant ID: <TenantId>
Enrollment program token name: <TokenName>
Affected platform: <ios / macOS / tvOS / visionOS>
Device serial number(s): <Serial(s)>

Profile/policy currently assigned (Triage step 1 output): <paste>
Is this a classic profile (depIOSEnrollmentProfile/depMacOSEnrollmentProfile) or a new-style policy?: <Yes/No>
New policy set as token default?: <Yes/No>

Device group configured on the policy?: <Yes/No — group name if yes>
Intune Provisioning Client (f1346770-5b25-470b-88bd-d5744ab7952c) confirmed as group owner?: <Yes/No>

Symptom observed:
<paste — e.g. Setup Assistant screen list stale / group membership delayed / device stuck on old profile>

Steps already attempted:
<list>
```

---

## 🎓 Learning Pointers

- The new policies aren't a UI reskin — they're **Settings Catalog objects** (`deviceManagement/configurationPolicies`, `technologies has 'enrollment'`) instead of the classic `enrollmentProfiles` object type, which is *why* new Apple features (new Setup Assistant screens, group assignment) only ever land here going forward. [What's new in Intune](https://learn.microsoft.com/en-us/intune/whats-new/)
- Intune mirrors every new-style policy back into the classic `enrollmentProfiles` collection for backward compatibility (device assignment UI, this runbook's Triage step 1) — but `isDefault` is never populated on that mirrored entry, which is the single biggest gotcha for any automation written against the classic collection alone.
- Enrollment-time grouping for Apple ADE reached GA the same release wave this migration shipped in — it was previously Windows Autopilot/Android Enterprise-only. Don't assume a classic profile "just needs a setting turned on" to get it; the capability literally does not exist outside the new policy type.
- "Set as default" is forward-only. This is the most common source of "I migrated but nothing changed" tickets — always check whether the specific device was *already* imported before the default was flipped (Fix 3).
- No confirmed retirement date has been published for classic ADE profiles as of this writing — they still function, just frozen. Don't tell a client migration is mandatory on a deadline; frame it as "new features require the new policy type," not "the old one stops working on X date."
