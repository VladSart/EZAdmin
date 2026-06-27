# Intune App Protection Policies (MAM) — Hotfix Runbook (Mode B: Ops)
> Fix App Protection Policy delivery, data wiping, and MAM enrollment failures in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

> **App Protection Policies (APP) ≠ App Configuration Policies.** APP = MAM policies (PIN, data protection, wipe). This runbook covers APP only.
> Connect with `Connect-MgGraph -Scopes "DeviceManagementApps.Read.All","DeviceManagementManagedDevices.Read.All"` first.

```powershell
# 1. Check if any APP policies exist and their platform targets
Get-MgDeviceAppManagementManagedAppPolicy -All |
  Select-Object DisplayName, @{N="OdataType";E={$_.'@odata.type'}}, Version

# 2. Check if a specific user has app protection status reported
$userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
Get-MgDeviceAppManagementManagedAppRegistration -Filter "userId eq '$userId'" -All |
  Select-Object AppIdentifier, DeviceName, ManagementSdkVersion, CreatedDateTime

# 3. List applied policies for a specific user
Get-MgDeviceAppManagementManagedAppRegistration -Filter "userId eq '$userId'" -All |
  ForEach-Object {
    Get-MgDeviceAppManagementManagedAppRegistrationAppliedPolicy -ManagedAppRegistrationId $_.Id |
      Select-Object DisplayName, @{N="App";E={$_.AppIdentifier}}
  }

# 4. Check if user is assigned to the APP policy
# (In portal: Apps > App Protection Policies > [policy] > Properties > Assignments)
# Via Graph:
Get-MgDeviceAppManagementManagedAppPolicyAssignment -ManagedAppPolicyId '<policyId>'

# 5. Check Intune service status (if all users affected)
# https://status.office.com → check Microsoft Intune
Invoke-RestMethod "https://manage.microsoft.com/EnrollmentServer/Discovery.svc" -Method GET
# Expected: 200 OK
```

**Interpretation table:**

| What you see | Most likely cause | Go to |
|---|---|---|
| No MAM registration for user | App hasn't checked in post-sign-in, or APP not assigned | Fix 1 |
| Registration present, no policies applied | Policy not assigned to user/group | Fix 2 |
| Policy applied but data restriction not enforced | App version doesn't support MAM SDK / wrong app variant | Fix 3 |
| PIN prompt not appearing | Minimum PIN length or requirement not configured | Fix 4 |
| Selective wipe not completing | MAM registration stale / device offline | Fix 5 |
| Android: "Your organization's data cannot be pasted here" | Copy/paste restriction working correctly — not a bug | — |

---
## Dependency Cascade

<details><summary>What must be true for App Protection Policy to apply to a user</summary>

```
Intune (Microsoft Endpoint Manager)
 └── App Protection Policy (MAM)
      ├── Platform target: iOS/iPadOS OR Android (separate policies required)
      ├── Assignment: User or Group (device assignment NOT supported for MAM-WE)
      └── App must be:
           ├── Listed in the policy's targeted apps list
           ├── Intune-wrapped or built with Intune App SDK (MSAL + MAM)
           │    └── App variants matter: iOS "Intune" builds ≠ AppStore standard builds for some apps
           └── Signed in with an account that:
                ├── Has an Entra ID identity (M365/Entra account)
                ├── Has Intune license (or license that includes Intune)
                └── Has triggered MAM registration (first app sign-in after policy assignment)

MAM-WE (Without Enrollment) flow:
  User signs into app → App calls Intune MAM service → Checks for registered policy
  → Downloads policy → Enforces on-device

MAM-CA (Conditional Access gated):
  App must pass MAM compliance → CA policy grants/denies token
  → Additional dependency: CA policy with "Require app protection policy" grant control
```

**Key distinction:**
- **MAM-WE:** Policy applies regardless of device enrollment state. Works on personal (BYOD) devices.
- **MAM-CA:** Requires both APP assignment AND a Conditional Access policy gating the app. If CA is broken, users can't sign in at all.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the app is in the Targeted Apps list of the policy:**
   In Endpoint Manager portal: Apps → App protection policies → [policy] → Properties → Apps.
   The specific app bundle ID must be listed. "All apps" as a selection does NOT mean all apps — it means all Microsoft apps with the Intune SDK.

   ```powershell
   # List apps targeted by a policy
   Get-MgDeviceAppManagementManagedAppPolicyApp -ManagedAppPolicyId '<policyId>' |
     Select-Object MobileAppIdentifier, @{N="BundleID";E={$_.MobileAppIdentifier.BundleId}}
   ```

2. **Confirm the user has an Intune license:**
   ```powershell
   (Get-MgUserLicenseDetail -UserId '<UPN>').SkuPartNumber |
     Where-Object {$_ -match "INTUNE|EMS|EMS_EDU|SPE_|ENTERPRISEPACK"}
   # Must return at least one matching entry
   ```

3. **Check when MAM last checked in (registration recency):**
   ```powershell
   $userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
   Get-MgDeviceAppManagementManagedAppRegistration -Filter "userId eq '$userId'" -All |
     Select-Object AppIdentifier, DeviceName, LastSyncDateTime, ManagementSdkVersion |
     Sort-Object LastSyncDateTime -Descending
   ```
   Expected: `LastSyncDateTime` within 24 hours for active users.

4. **Check if the policy targets the right platform (iOS vs Android vs Windows):**
   A policy for iOS won't apply to Android apps. Check the `@odata.type` of the policy:
   - `#microsoft.graph.iosManagedAppProtection` → iOS only
   - `#microsoft.graph.androidManagedAppProtection` → Android only
   - `#microsoft.graph.mdmWindowsInformationProtectionPolicy` → Windows (WIP, legacy)
   - `#microsoft.graph.windowsManagedAppProtection` → Windows MAM (new, W11 22H2+)

5. **Test if MAM registration is being triggered (iOS/Android):**
   On device: Sign out of the target app → sign back in → check if Intune Company Portal shows a notification or the app prompts for PIN setup.
   No prompt = policy not reaching the device. App not registered with MAM service.

6. **Check for Conditional Access dependency (MAM-CA):**
   ```powershell
   # Check if any CA policies require App Protection Policy
   Get-MgIdentityConditionalAccessPolicy -All |
     Where-Object {$_.GrantControls.BuiltInControls -contains 'approvedApplication' -or
                   $_.GrantControls.BuiltInControls -contains 'compliantApplication'} |
     Select-Object DisplayName, State
   ```
   If CA is enabled with `compliantApplication` grant: APP assignment is required or the user gets blocked entirely.

---
## Common Fix Paths

<details><summary>Fix 1 — User has no MAM registration (policy never reached device)</summary>

**Symptom:** Graph shows no `ManagedAppRegistration` for the user. User says policy has never applied.

**Checklist:**
1. Verify the policy is **Enabled** (not Disabled) in portal: Apps → App protection policies → Status column.
2. Verify the user (or a group containing the user) is in **Assignments → Include**.
3. Confirm the app is signed in with the **work account** (Entra ID UPN), not a personal account.
4. On device: open the target app → sign out completely → sign back in with work account.
5. Wait 5-10 minutes for MAM check-in to complete.

**Force MAM check-in (iOS — Company Portal method):**
- Open Company Portal → tap the three dots → "Sync" device
- This forces all MAM registrations to refresh

**Force MAM check-in (Android):**
- Open any Intune-protected app → go to Settings/Info within the app → "Sync" or "Refresh policies" option

**If user is in an exclusion group — check exclusions:**
```powershell
Get-MgDeviceAppManagementManagedAppPolicyAssignment -ManagedAppPolicyId '<policyId>' |
  Where-Object {$_.Target.GroupId -ne $null} |
  Select-Object @{N="GroupId";E={$_.Target.GroupId}}, @{N="Intent";E={$_.Target.'@odata.type'}}
# odata.type: #microsoft.graph.groupAssignmentTarget = Include
#             #microsoft.graph.exclusionGroupAssignmentTarget = Exclude
```

</details>

<details><summary>Fix 2 — Registration exists but no policy applied</summary>

**Symptom:** MAM registration visible in portal. Under Assignments, user appears included. But no applied policy shown.

**Most common causes:**
- Policy targets a different group than the user is in — verify direct group membership (nested groups not always evaluated)
- Policy is scoped to a specific app but the user's version of the app is not the SDK-enabled variant

**Check nested group membership (MAM doesn't support transitive/nested groups in some tenants):**
```powershell
$userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
$groupId = '<policyAssignmentGroupId>'
# Check direct membership
Get-MgGroupMember -GroupId $groupId | Where-Object {$_.Id -eq $userId}
# If empty, user is not a direct member — MAM may not traverse nested groups
```

**Fix:** Add the user directly to the assignment group, or change the policy assignment to target the user directly (or "All Users").

**Trigger policy re-sync:**
- Remove user from the assignment → Save → wait 2 min → Re-add → Save → have user re-sync Company Portal

</details>

<details><summary>Fix 3 — Policy applied but data restrictions not enforced in app</summary>

**Symptom:** User can copy corporate data to personal apps despite "Restrict cut/copy/paste" being configured.

**Diagnose — app variant:**
Some apps (e.g. Adobe Acrobat, third-party) have two variants:
- Standard AppStore version: No MAM SDK → policy cannot enforce
- Intune-wrapped or SDK-enabled version: Policy enforces

```powershell
# Check ManagementSdkVersion — if null or very old, app may not support all controls
Get-MgDeviceAppManagementManagedAppRegistration -Filter "userId eq '$userId'" -All |
  Select-Object AppIdentifier, ManagementSdkVersion
```

**MAM SDK minimum versions for key restrictions:**
| Feature | Minimum iOS SDK | Minimum Android SDK |
|---|---|---|
| PIN enforcement | 7.0+ | 6.0+ |
| Copy/paste restriction | 7.0+ | 6.0+ |
| Screen capture block | N/A (iOS enforces) | 6.0+ |
| Open-in restriction | 7.0+ | 6.1+ |

**Fix:** If the app doesn't support the needed controls:
1. Check if an Intune-wrapped version exists in the app store
2. Contact the ISV for SDK status
3. As interim control: block the app via Conditional Access or CA-enforced MAM (requires managed device)

</details>

<details><summary>Fix 4 — PIN prompt not appearing</summary>

**Symptom:** Policy has PIN required, but users open apps without any PIN prompt.

**Check policy PIN settings:**
In portal: Apps → App protection policies → [policy] → Access requirements:
- PIN for access: **Required** (not "Not required")
- PIN type: **Numeric** or **Passcode**
- Minimum PIN length: set (recommend 6)
- Timeout: **30 minutes** (default) — if user opened the app within 30 min, PIN not re-prompted

**Check if device PIN satisfies the "override with device PIN" setting:**
- If "Override PIN with biometrics" is On AND device has biometric = user sees biometric instead of PIN
- If "Override PIN after number of days" is enabled = PIN is bypassed on returning users

```powershell
# Read PIN settings from policy
Get-MgDeviceAppManagementManagedAppProtection -ManagedAppProtectionId '<policyId>' |
  Select-Object PinRequired, PinCharacterSet, MinimumPinLength, PinRequiredInsteadOfBiometricTimeout
```

**Fix:** Set `PinRequired = true`, `MinimumPinLength = 6`, `PinCharacterSet = Numeric`. Set biometric override to **Off** for high-security environments. Save and force MAM sync on device.

**Note:** PIN timeout resets when the user switches between MAM-protected apps. If they use Teams → Outlook → Teams, they won't be re-prompted within the timeout window — this is by design.

</details>

<details><summary>Fix 5 — Selective wipe not completing</summary>

**Symptom:** Admin issued selective wipe (Apps → App protection policies → Actions → Wipe). Portal shows pending. User reports app still has corporate data.

**Check wipe status:**
```powershell
$userId = (Get-MgUser -Filter "userPrincipalName eq '<UPN>'").Id
# List pending wipe requests
Get-MgDeviceAppManagementManagedAppRegistration -Filter "userId eq '$userId'" -All |
  Select-Object AppIdentifier, DeviceName, LastSyncDateTime
```

**Wipe delivery requires:**
1. Device must be online and the app must open at least once (wipe command is pull-based via MAM check-in, not push)
2. User must sign into the app with the work account after the wipe was issued

**If wipe has been pending >24h:**
- The device is offline, app was uninstalled before wipe, or the work account was removed before the wipe check-in
- **Alternative:** Block access immediately using Conditional Access → create a CA policy targeting the user → "Block" → this is faster than waiting for wipe check-in
- **For full device wipe on enrolled devices:** use Intune device wipe instead (Devices → [device] → Wipe)

**Re-issue the wipe:**
In portal: Apps → App protection policies → [policy] → App selective wipe → [user] → [registration] → Wipe

There is no Graph API to re-issue a wipe at this time (portal only).

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Intune App Protection Policy (MAM)

Tenant ID:              _______________
Policy Name:            _______________
Policy ID:              _______________
Affected UPN:           _______________
Platform:               [iOS / Android / Windows]
App Name + Version:     _______________
App Bundle ID:          _______________
ManagementSdkVersion:   _______________

MAM Registration Present?  YES / NO
LastSyncDateTime:           _______________
Policies Applied (names):   _______________

Intune License Assigned?  YES / NO
License SKU:              _______________

Symptom:
_______________________________________________

CA Policy requiring App Protection? YES / NO / NA
CA Policy Name (if applicable):     _______________

Steps already attempted:
- [ ] Confirmed policy enabled
- [ ] Confirmed user in assignment group (direct membership verified)
- [ ] Re-synced Company Portal / app
- [ ] Signed out and back in to app with work account
- [ ] Verified app bundle ID in policy targeted apps list
- [ ] Checked ManagementSdkVersion compatibility
```

---
## 🎓 Learning Pointers

- **MAM ≠ MDM — no device enrollment required:** App Protection Policies work entirely at the app layer. The device never needs to be enrolled in Intune. This is the entire point of MAM for BYOD. If someone tells you "the device needs to be enrolled for MAM to work," that's incorrect — MAM-WE is specifically designed for unenrolled devices.

- **Policy assignment only supports users/groups, not devices:** Unlike device compliance or configuration profiles, APP policies target **users**. Device groups are ignored. If users report "my policy isn't applying," the very first check is always whether the **user** (not the device) is in the assignment group.

- **Two variants of "All apps" in APP policy:** When configuring targeted apps, "All apps" only covers Microsoft first-party apps with the Intune SDK. Third-party apps require explicit addition by bundle ID. If a partner app isn't in the targeted list, policy will not apply to it — no error is raised.

- **MAM-CA vs. MAM-WE distinction matters for Conditional Access:** If you enable CA with "Require app protection policy," users on devices without MAM enrollment will be blocked from the resource entirely — even if they have an APP policy assigned. This is MAM-CA mode and requires careful planning before enablement. Test in report-only mode first. See: [App-based Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/app-based-conditional-access)

- **Selective wipe is pull-based, not push:** The wipe command does not reach the device until the app checks in. On a device that's offline or where the work account has already been removed, a wipe may never complete. For time-sensitive data protection, use CA block first, then wipe.

- **Windows MAM (W11 22H2+) is separate from iOS/Android MAM:** Microsoft released Windows-native MAM for Windows 11 22H2+. It requires a `windowsManagedAppProtection` policy (different from WIP/Windows Information Protection which is legacy). iOS/Android APP policies do not apply to Windows. See: [Windows MAM overview](https://learn.microsoft.com/en-us/mem/intune/apps/app-protection-policy-settings-windows)
