# eSIM Cellular Profile Deployment (Windows Connected PCs) — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Intune has **two, mutually-exclusive-per-tenant-per-carrier** methods for bulk-deploying eSIM cellular profiles to Windows Connected PCs (Surface Pro/LTE-class devices): the older **CSV activation-code import** (public preview; Windows 10/11, one-time-use codes per device) and the newer, **recommended eSIM download server (SM-DP+) method** (Windows 11 only, Settings Catalog policy, no individual codes — the device authenticates to the operator's server directly by EID). A ticket describing "eSIM won't activate" must first identify which method is actually configured before troubleshooting, since the failure surfaces and fix paths are different. Intune **cannot remove an eSIM profile from a device** via either method — removal is either via device Entra-group removal (activation-code method only) or fully manual on the device.

Run these first, in this order:

```powershell
# 1 — Confirm the device is actually eSIM-capable and MDM-enrolled/synced recently.
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, Model, Manufacturer, LastSyncDateTime, OSVersion

# 2 — Identify which eSIM method is assigned to this device's group: CSV activation-code
#     subscription pool, or a Settings Catalog eSIM download-server profile.
Get-MgDeviceManagementConfigurationPolicy -Filter "contains(name,'eSIM')" |
    Select-Object Id, Name, LastModifiedDateTime

# 3 — For the CSV activation-code method: check the assigned subscription pool's deployment
#     status directly in the admin center (Devices > Manage devices > eSIM cellular profiles) —
#     there is no dedicated Graph cmdlet exposed for the friendly pool status view; the
#     Get-eSIMDeploymentStatus.ps1 script (Intune/Scripts/) queries the underlying Graph
#     resource directly if you need this scripted.

# 4 — For the download-server method: confirm the Settings Catalog profile's assignment
#     status for this device (a per-setting deployment status, distinct from actual eSIM
#     profile download/activation on the eUICC itself).
Get-MgDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId "<PolicyId>"
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| CSV import fails outright at upload | File format/structure violation, duplicate provider in an existing pool, or reused activation codes | Fix 1 |
| Activation-code device status shows "Device not synced" | Device hasn't checked in with Intune since the eSIM policy was created | Fix 2 |
| Activation-code device status shows "Activation fail" | Code already used, code expired, or operator-side (SM-DP+) rejection — not an Intune-side failure | Fix 3 |
| Download-server method: policy shows "Succeeded" but no eSIM profile appears on the device | Settings Catalog "Succeeded" only confirms policy delivery, not that the eUICC actually downloaded/activated a profile from the operator's SM-DP+ | Fix 4 |
| Download-server method assigned to a Windows 10 device | Not supported — download-server method is **Windows 11 only**; Windows 10 must use the CSV activation-code method instead | Fix 5 |
| Two mobile operators' activation-code CSVs both fail to import ("request is invalid") | Intune does not allow two active lists for the same provider — must consolidate into one updated CSV | Fix 6 |
| Admin expects Intune to remove/deactivate an eSIM profile remotely | Not supported for the download-server method at all; for the activation-code method, only removing the device from the assigned Entra group triggers removal — there is no direct "remove eSIM" action | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Windows device, MDM-enrolled and synced, physically eSIM-capable]
    │
    ├── CSV Activation-Code path (Windows 10/11, supported-but-not-recommended on Win11)
    │       └── [Mobile operator supplies 1 CSV: SM-DP+ FQDN + ICCID/Matching-ID pairs]
    │               └── [CSV imported without format error, no duplicate provider,
    │                    codes not previously used]
    │                       └── [Static Entra device group created, scoped to eSIM devices only]
    │                               └── [Group assigned to the imported subscription pool]
    │                                       └── [Device syncs → activation code installs →
    │                                            eSIM module contacts operator, downloads
    │                                            profile — Intune's role ends here]
    │
    └── eSIM Download-Server path (Windows 11 only, recommended)
            └── [Contract with mobile operator; operator's SM-DP+ FQDN obtained]
                    └── [Operator has operator-side eSIM profile provisioned per device EID]
                            └── [Settings Catalog policy: Server Name (FQDN), Auto Enable,
                                 Display Local UI configured]
                                    └── [Policy assigned to a static Entra device group]
                                            └── [Device syncs → contacts SM-DP+ directly using
                                                 its EID → operator authenticates + serves
                                                 profile — Intune's role ends at policy delivery]
```

**Key fact common to both paths:** Intune's own "Succeeded"/"Active" status only confirms that Intune successfully delivered its half of the configuration (activation code installed, or Settings Catalog policy applied). The actual eSIM profile download and cellular activation happens as a **separate, operator-side handshake** between the device and the mobile operator's SM-DP+ server — a step Intune does not control and has limited visibility into. A device-side or operator-side failure at that stage will not necessarily be reflected as an Intune-side error.

</details>

---
## Diagnosis & Validation Flow

1. **Identify which of the two deployment methods is in play** (Triage step 2) — this determines which of the two Dependency Cascade branches and which Fix paths apply. Do not assume; verify.

2. **Confirm device eligibility and recency:**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
       Select-Object DeviceName, Model, LastSyncDateTime, OSVersion
   ```
   A device that hasn't synced since the policy/pool was created/assigned will show "Device not synced" (activation-code method) or a stale assignment status (download-server method) — neither is a deployment failure yet.

3. **For the activation-code method, check the admin center's Deployment Status and Device Status views** (Devices > Manage devices > eSIM cellular profiles > select subscription > Device Status) — this is the authoritative per-device activation state (Device not synced / Activation pending / Active / Activation fail) and currently has no direct 1:1 Graph cmdlet equivalent for the friendly view; use `Get-eSIMDeploymentStatus.ps1` (Intune/Scripts/) for a scripted read against the underlying resource.

4. **For the download-server method, separate policy delivery from actual activation:**
   - Policy delivery: Settings Catalog assignment status (Graph or admin center) — confirms the FQDN/Auto Enable/Display Local UI values reached the device.
   - Actual activation: only observable **on the device itself** — Settings > Network & Internet > Cellular > Manage eSIM profiles. Intune has no remote visibility into eUICC profile state for this method.

5. **If both delivery is confirmed and on-device activation is still missing**, this is very likely an **operator-side (SM-DP+) issue** — wrong/mistyped FQDN, device EID not yet provisioned on the operator's server, or an operator-side outage — not an Intune configuration problem. Escalate to the mobile operator with the device's EID and the configured Server Name.

---
## Common Fix Paths

<details><summary>Fix 1 — CSV import fails at upload</summary>

1. Confirm the file is genuinely `.csv` and follows the required structure: **row 1** = the SM-DP+ FQDN alone (no `https://`, no trailing comma); **row 2 onward** = `ICCID,MatchingID` pairs, comma-separated, no trailing comma.
2. Confirm the file contains activation codes for **one mobile operator and one billing plan only** — mixed-operator files are not supported and will fail import validation.
3. Confirm none of the codes were previously imported — activation codes are one-time-use; re-importing a previously-used code is not supported and can cause deployment problems even if the import itself technically succeeds.
4. Maximum 1,000 activation codes per CSV — split larger batches across multiple correctly-separated files if needed (still one operator/plan per file).

</details>

<details><summary>Fix 2 — Device shows "Device not synced"</summary>

1. Confirm the device has actually checked in with Intune since the policy/pool was created — trigger a manual sync (`Sync` device action, or on-device via Company Portal/Settings) if the last check-in predates the deployment.
2. This is a transient, expected state for a freshly-assigned policy — don't escalate until at least one full sync cycle has elapsed with no status change.

</details>

<details><summary>Fix 3 — Activation-code device shows "Activation fail"</summary>

1. This is explicitly an **operator-side or code-side failure**, not an Intune delivery failure — Intune's role (installing the activation code) already succeeded to reach this state.
2. Confirm the code wasn't already used on another device (activation codes are strictly one-time-use; Intune randomly distributes codes across targeted devices, so a code intended for one device may already be consumed).
3. Check the **Cellular status** column in Device Status (provided by the mobile operator, not Intune) for an operator-supplied reason — follow up with the mobile operator directly using this status, since Intune has no further diagnostic authority once activation is attempted.

</details>

<details><summary>Fix 4 — Download-server policy "Succeeded" but no profile on device</summary>

1. Confirm this is genuinely a Windows 11 device — the download-server method silently doesn't work on Windows 10 (see Fix 5) even though a misassigned policy may still show as delivered.
2. On the device itself (Settings > Network & Internet > Cellular > Manage eSIM profiles), confirm whether any profile attempt is visible at all — absence here, despite confirmed policy delivery, points to an operator-side SM-DP+ issue (wrong FQDN, EID not yet provisioned) rather than an Intune problem.
3. Double-check the configured **Server Name** value for typos — it must be the bare FQDN (e.g., `smdp.example.com`), no `https://` prefix. Intune only supports **a single Server Name value** per policy even if multiple are technically enterable — extras are silently ignored.
4. Confirm with the mobile operator that this device's **EID** has been provisioned on their SM-DP+ server — this is an operator-side manual/contractual step (via EID manifest or manual submission) that must happen before the device's automated contact attempt can succeed.

</details>

<details><summary>Fix 5 — Download-server method assigned to a Windows 10 device</summary>

1. This configuration is not supported — reassign the device to the CSV activation-code method instead (the only Windows 10-compatible option), or upgrade the device to Windows 11 if the download-server method's per-device convenience (no individual codes) is required long-term.
2. Confirm via device inventory (`OSVersion`/`Model`) before spending further time troubleshooting an unsupported configuration.

</details>

<details><summary>Fix 6 — Two CSVs for the same provider both fail import</summary>

1. Intune does not support two simultaneous lists for the same mobile operator/provider.
2. To add more devices under the same operator: **remove** the existing CSV/pool, then **re-upload a new CSV** containing both the original device/ICCID pairs and the new ones — there is no supported "append" operation.

</details>

<details><summary>Fix 7 — Admin expects a remote "remove eSIM" action</summary>

1. No such direct action exists in Intune for either method.
2. For the **activation-code method only**: removing the device from the assigned Entra group causes the eSIM profile to be removed the next time the device checks in and evaluates the updated (now-unassigned) policy.
3. For the **download-server method**: there is currently no supported remote removal path at all — removal must be performed manually on the device (Settings > Network & Internet > Cellular > Manage eSIM profiles).
4. Either method: the profile is also removed automatically when the device is retired, unenrolled, or wiped.
5. Set expectations that removing the Intune-side profile/policy **does not automatically stop mobile operator billing** — that requires a separate conversation with the operator.

</details>

---
## Escalation Evidence

```
eSIM DEPLOYMENT — ESCALATION TEMPLATE
============================================
Tenant:                         <tenant name/ID>
Device name / EID:              <device name, EID if known>
Deployment method:              <CSV activation-code / eSIM download server>
Windows version:                <10 / 11, build>
Subscription pool / policy name: <name>
Intune-side status:              <Device not synced / Activation pending / Active / Activation fail
                                  — or Settings Catalog assignment status for download-server method>
On-device profile visible:       <Y/N — Settings > Network & Internet > Cellular > Manage eSIM profiles>
Mobile operator:                <name>
SM-DP+ FQDN configured:          <value, verify no https:// prefix>
Mobile operator's own status:    <if available — cellular status column, or operator support ticket>
```

---
## 🎓 Learning Pointers

- **Identify the deployment method first, every time.** CSV activation-code and eSIM download-server are architecturally different (individual one-time codes vs. EID-based server authentication), have different Windows-version support, and fail differently — troubleshooting the wrong method's fix paths wastes time. See [Enable eSIM data connections in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-configuration/templates/enable-esim) and [eSIM configuration of a download server](https://learn.microsoft.com/en-us/intune/device-configuration/templates/configure-esim-download-server).
- **Intune's "Succeeded" status is a delivery confirmation, not an activation confirmation**, for both methods — the actual eSIM profile handshake happens directly between the device and the mobile operator's SM-DP+ server, a step Intune has limited-to-no visibility into. A confirmed-delivered policy with no on-device profile is very often an operator-side issue, not an Intune misconfiguration.
- **There is no remote "remove eSIM profile" action.** The only Intune-mediated removal path (Entra group membership change) exists solely for the activation-code method — plan lifecycle/offboarding expectations accordingly, and don't promise end users or customers a capability that doesn't exist for the download-server method.
- The activation-code (CSV) method is explicitly marked **"supported, but not recommended"** on Windows 11 in current Microsoft documentation, in favor of the download-server method — steer new deployments toward download-server on Windows 11 fleets where the mobile operator supports it.
- Windows has supported eSIM since 2017, but **enterprise bulk deployment via Intune remains a public-preview feature** for the CSV method as of this writing — treat both methods' rough edges (single-Server-Name limitation, no append-to-CSV, no remote removal) as current, documented limitations rather than bugs to chase.
