# Samsung Knox E-FOTA Firmware Update Management — Hotfix Runbook (Mode B: Ops)
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

Corporate-owned Samsung Android Enterprise devices aren't showing up in Knox E-FOTA, or a firmware campaign shows devices stuck at "Pending"/no status. Before assuming the campaign config is wrong, confirm which link in the connector→app→policy→registration chain is actually broken.

```powershell
# 1. Confirm Graph connection
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All","DeviceManagementApps.Read.All","DeviceManagementManagedDevices.Read.All"

# 2. Confirm the two required Managed Google Play apps are assigned Required and installed
Get-MgDeviceAppManagementMobileApp -Filter "contains(displayName,'Knox E-FOTA') or contains(displayName,'Knox Service Plugin')" |
    Select-Object DisplayName, Id, PublishingState

# 3. Confirm the OEMConfig profile (device policy controls / firmware controls / E-FOTA client install & launch) is assigned and reporting Succeeded
Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'OEMConfig')" |
    Select-Object DisplayName, Id

# 4. Pull the device's own managed-device record to confirm it's Android Enterprise COBO/COSU/COPE, not device admin or BYOD
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" |
    Select-Object DeviceName, OperatingSystem, ManagedDeviceOwnerType, AndroidDeviceManagerState
```

| Result | Interpretation |
|---|---|
| Device is Android device-administrator or a personally-owned work profile | **Not supported.** Knox E-FOTA only supports Android Enterprise COBO, COSU, and COPE corporate-owned enrollments. Stop here — re-enroll under a supported ownership/management type. |
| Knox E-FOTA / Knox Service Plugin apps show `notInstalled` or aren't assigned at all | App deployment gap, not a firmware/campaign issue — go to [Fix 1](#common-fix-paths). |
| Apps installed but OEMConfig profile not applied, or firmware/device-policy-control toggles left off | Device policy controls disabled — Samsung side can't reach the device — go to [Fix 2](#common-fix-paths). |
| Apps + OEMConfig both applied but device never shows in the Knox E-FOTA connector's device registration status report | Most likely the end-user never opened the Knox E-FOTA app to accept terms — go to [Fix 3](#common-fix-paths). |
| Device shows `Registered` in the status report but a campaign never reaches it | Campaign targeting (device model / sales code / CSC / firmware version) doesn't match the device, or the device isn't in the group assigned to the campaign — go to [Fix 4](#common-fix-paths). |
| Connector itself shows disconnected, or setup never completed | Samsung connector auth issue — go to [Fix 5](#common-fix-paths). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant prerequisites
    ├── Samsung Knox E-FOTA license (Samsung-side, separate purchase — NOT included with Intune)
    ├── Microsoft 365 E3 (minimum) on the tenant
    └── Managed Google Play configured for the tenant
            └── Samsung connector (Tenant admin > Connectors and tokens > Firmware over-the-air update)
                    └── Connect + authorize with a Samsung Knox administrator account
                        (separate credential from Intune Administrator — this is the #1
                         setup-time blocker)
                            └── Required apps deployed via Managed Google Play, assigned "Required":
                                    ├── Knox E-FOTA (com.samsung.android.knox.efota)
                                    └── Knox Service Plugin (com.samsung.android.knox.kpu)
                                            └── OEMConfig profile assigned to the SAME group:
                                                    ├── Enable device policy controls = true
                                                    ├── Enable firmware controls = true
                                                    └── Enable E-FOTA client installation & launch = true
                                                            └── Security group(s) added to the Samsung
                                                                connector + "Register" selected
                                                                    └── Device-side: end user must open the
                                                                        Knox E-FOTA app and accept terms &
                                                                        conditions — registration does NOT
                                                                        complete without this manual step
                                                                            └── E-FOTA campaign created
                                                                                (device model + sales code +
                                                                                 CSC + firmware version must
                                                                                 match target devices)
                                                                                    └── Samsung executes;
                                                                                        Intune status refreshes
                                                                                        hourly from Samsung
    └── RBAC (separate from the above):
            Android FOTA permission — register/manage firmware updates
            Mobile apps permission — deploy the two required apps
            Device configurations permission — create/assign the OEMConfig template
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm device eligibility first.** Only Android Enterprise corporate-owned fully managed (COBO), corporate-owned dedicated (COSU), and corporate-owned work profile (COPE) devices are supported. Device administrator and personally-owned work profile (BYOD) devices are never eligible — this is a hard platform limit, not a configuration gap.

2. **Confirm both required apps actually installed, not just assigned.** "Required" assignment alone doesn't mean installed — check the app's device install status, not just the assignment.
   ```powershell
   Get-MgDeviceAppManagementMobileAppDeviceStatus -MobileAppId "<knox-efota-app-id>"
   ```
   Expected: `installed` for the target device. `notInstalled`/`failed` means Managed Google Play sync or device connectivity is the actual blocker — treat as a standard app-deployment issue, not an E-FOTA issue.

3. **Confirm the OEMConfig profile's three toggles are all `true` and the policy reports Succeeded on the device**, not just assigned. A profile stuck at "Pending" on the device blocks Samsung's E-FOTA client from functioning even if the apps installed cleanly.

4. **Check the device registration status report for this specific device.**
   Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung > **Monitor** tab. Data refreshes hourly from Samsung — a device missing for under an hour after the user accepted terms is not yet a failure.
   Expected states: `Pending` (apps/policy applied, user hasn't opened the app yet) → `Registered` (user accepted terms, ready for campaigns).

5. **If registered but not receiving a campaign, cross-check campaign targeting criteria against the device's actual model/sales code/CSC/firmware.** A campaign built against the wrong sales code silently excludes matching-model devices sold through a different carrier/region channel — this is the most common "campaign shows 0 progress" root cause once registration itself is confirmed working.

---
## Common Fix Paths

<details><summary>Fix 1 — Required apps not installed on target devices</summary>

1. Confirm Managed Google Play is connected and syncing (Tenant administration > Connectors and tokens > Managed Google Play).
2. Confirm both apps — Knox E-FOTA and Knox Service Plugin — are added from Managed Google Play (not sideloaded) and assigned **Required** to the same security group used for E-FOTA registration.
3. Force a device sync and re-check install status after the next Android Enterprise sync cycle.
4. If install still fails, check the device's own Company Portal / Play Store sign-in state — a device not properly enrolled in Managed Google Play won't receive Required app pushes at all.

Rollback: not applicable — this is a deployment gap, not a change to roll back.

</details>

<details><summary>Fix 2 — OEMConfig profile not applying or toggles left off</summary>

1. Re-open the OEMConfig profile (Devices > Configuration > the OEMConfig policy) and confirm all three settings are explicitly set to **true**: Enable device policy controls, Enable firmware controls, Enable E-FOTA client installation & launch.
2. Confirm the profile is assigned to the same group as the two required apps — a mismatched group is a common copy/paste error when these are built as separate steps.
3. Force sync and re-check policy status; a profile that never leaves "Pending" after multiple sync cycles points to a device-side conflict (another OEMConfig profile targeting the same device) rather than a Samsung-side issue.

Rollback: setting the three toggles back to false removes device policy/firmware control but does not un-register an already-registered device from Knox E-FOTA — treat registration as a one-way state absent Samsung-side action.

</details>

<details><summary>Fix 3 — Apps + policy applied, but device never completes registration</summary>

1. Confirm with the end user (or via remote view/Company Portal messaging) that the Knox E-FOTA app is actually present on the device and was opened at least once.
2. Registration requires the user to accept terms and conditions inside the Knox E-FOTA app itself — this step cannot be automated or bypassed remotely. Despite E-FOTA's "no user interaction" marketing for the *update deployment* phase, initial *registration* is not unattended.
3. For kiosk/COSU devices with no interactive user, build this step into the device provisioning checklist (a technician opens the app and accepts terms during initial device staging) rather than assuming Autopilot-style zero-touch coverage.
4. Re-check the Monitor tab an hour after confirming the user opened the app — status data refreshes hourly, not in real time.

Rollback: not applicable.

</details>

<details><summary>Fix 4 — Device registered, but a firmware campaign never reaches it</summary>

1. Open the campaign (Devices > Android > Manage updates > Android FOTA deployments) and confirm the selected device model, sales code, and CSC exactly match the target device's actual hardware/carrier variant.
2. Confirm the campaign's assigned group actually contains the registered device — a device can be Knox-registered but excluded from the specific campaign's target group.
3. Check the campaign's deployment schedule and installation schedule/device condition settings — a narrow install window or a device-condition gate (e.g. charging + Wi-Fi required) can silently delay execution well past when the admin expects it.
4. Cross-reference in the Knox Admin Portal directly if Intune-side status is ambiguous — the portal is the source of truth Intune's Monitor tab summarizes hourly.

Rollback: canceling or deleting the campaign from the Monitor tab's summary stops further rollout; devices that already received the firmware update are not reverted by canceling the campaign.

</details>

<details><summary>Fix 5 — Samsung connector shows disconnected or setup never completed</summary>

1. Confirm the account attempting setup holds the **Intune Administrator** role, and a separate, valid **Samsung Knox administrator** account is available to complete the Samsung-side authorization — these are two distinct credentials on two distinct platforms.
2. Re-run Connect from Tenant administration > Connectors and tokens > Firmware over-the-air update > Samsung, and complete the Samsung Knox Admin Portal sign-in/authorization prompt fully rather than closing it partway through.
3. If disconnected unexpectedly after previously working, check whether the Knox administrator account's credentials or MFA state changed on the Samsung side — the connector authorization can silently lapse if the authorizing account is disabled or has its password/MFA reset.
4. Confirm required network/firewall endpoints for Samsung Knox services are reachable (see Samsung's own Knox firewall exceptions documentation) if the connector fails to authorize even with valid credentials.

Rollback: Disconnect (same menu, **Disconnect** button) fully unlinks the tenant from Knox E-FOTA; previously registered devices remain registered on the Samsung side but stop receiving Intune-orchestrated campaign visibility until reconnected.

</details>

---
## Escalation Evidence

```
=== Samsung Knox E-FOTA — Escalation Template ===
Tenant ID:                                        <fill in>
Affected device name(s) / model / sales code / CSC: <fill in>
Ownership/enrollment type (must be COBO/COSU/COPE): <fill in>
Knox E-FOTA + Knox Service Plugin install status on device: <fill in>
OEMConfig profile status (Succeeded/Pending/Error):  <fill in>
Device registration status report state (Pending/Registered/absent): <fill in>
Campaign name and targeting criteria (model/sales code/CSC/firmware): <fill in>
Time end user last opened the Knox E-FOTA app (if known):  <fill in>
Samsung connector status (Connected/Disconnected):   <fill in>
Business impact:                                     <fill in>
Requested next step:                                 <fill in>
```

---
## 🎓 Learning Pointers

- Knox E-FOTA registration is **not** fully unattended despite the feature's "no user interaction required" language for firmware *deployment* — initial registration requires the end user (or a provisioning technician) to physically open the Knox E-FOTA app and accept terms and conditions. Build this into device staging checklists for kiosk/COSU fleets with no regular interactive user. See [Integrate Samsung Knox E-FOTA with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-updates/android/setup-samsung-knox).
- Only Android Enterprise corporate-owned enrollments (COBO, COSU, COPE) are supported — device administrator and personally-owned work profile (BYOD) devices are never eligible, regardless of app/policy configuration.
- The Samsung Knox E-FOTA license is a **separate Samsung-side purchase** from any Microsoft licensing — a tenant meeting the M365 E3 floor with no Knox E-FOTA license will see the connector fail to provide real firmware management despite Intune-side setup appearing complete.
- Connector setup requires two distinct admin credentials on two distinct platforms: an Intune Administrator to configure the connector, and a Samsung Knox administrator account to authorize it. Missing or lapsed Knox-side credentials are a common silent-disconnect cause.
- All Knox E-FOTA status data — both the device registration status report and campaign Monitor tab — refreshes **hourly** from Samsung, not in real time. Don't chase a "missing" device or "stalled" campaign inside the first hour after a change.
- Related but distinct: this is firmware-level OS update management, separate from Intune's standard Android OS/security patch compliance reporting — a device can be firmware-current via E-FOTA and still show a different (app-level) update status elsewhere in Intune.
