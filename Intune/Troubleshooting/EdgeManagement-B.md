# Microsoft Edge for Business Policy Management (Edge management service + Intune + GPO) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Why an Edge setting isn't applying, or applies the wrong value, when policy can come from four places: **GPO**, **Intune/MDM** (Settings catalog / Edge security baseline), the **Microsoft Edge management service** (M365 admin center > Settings > Microsoft Edge, "Cloud" or "Intune"-type configuration policies), and **local registry**. Covers Windows primarily. macOS, iOS, and Android are covered where the Edge management service applies.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

On the affected Windows device, as the affected user:

```powershell
# 1. Edge version (management service needs 115.0.1901.7+; default-on from 115.1935)
(Get-Item "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion

# 2. Is the Edge management service switched OFF, pinned to a token, or overriding platform policy?
'HKLM:\SOFTWARE\Policies\Microsoft\Edge','HKCU:\SOFTWARE\Policies\Microsoft\Edge' | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue |
        Select-Object @{n='Hive';e={$_.PSPath -replace '.*::'}}, EdgeManagementEnabled, EdgeManagementEnrollmentToken,
                      EdgeManagementPolicyOverridesPlatformPolicy, EdgeManagementUserPolicyOverridesCloudMachinePolicy }

# 3. Which value is actually in the registry for the setting in question?
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name '<PolicyName>' -ErrorAction SilentlyContinue
Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Edge' -Name '<PolicyName>' -ErrorAction SilentlyContinue

# 4. Is a GPO touching Edge? (look for an Edge-related GPO in the applied list)
gpresult /r /scope computer | Select-String -Pattern "Applied Group Policy Objects" -Context 0,15

# 5. Open edge://policy in the browser → "Reload policies" → read the Source + Status columns for the setting
```

| What you see | What it means / next step |
|---|---|
| Setting missing from `edge://policy` entirely | Policy never reached the device/user. Check assignment and sign-in → Fix 1 (cloud) or Fix 2 (Intune) |
| Setting present, Source = *Platform*, value is not what the Edge management service says | GPO/MDM wins over the Edge management service by design → Fix 3 |
| Status shows **conflict** / a warning icon | The same policy is set by more than one source or scope → Fix 3 |
| `EdgeManagementEnabled = 0` | The Edge management service is disabled on this device, so cloud policies never download → Fix 4 |
| Cloud policy assigned, user signed into Edge with a **personal/MSA** or secondary profile | Cloud policy only applies to the **primary Entra work profile** → Fix 1 |
| Change made in the portal 10 min ago, not live yet | Check-in cadence is 90 min (policy assigned) or 24 h (no policy), **and Edge must restart** → Fix 5 |
| Partner/MSP admin can't see or edit Edge settings in M365 admin center | GDAP roles aren't fully supported for the Edge management service → Fix 6 |
| GCC tenant: Settings > Microsoft Edge missing | Edge management service isn't available for GCC plans → use Intune/GPO only |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Edge ≥ 115.0.1901.7 (management service default-on from 115.1935)
  └── Policy source(s) configured
        ├── [A] Edge management service (M365 admin center > Settings > Microsoft Edge)
        │     ├── Admin holds Microsoft Edge Administrator role (GDAP not fully supported)
        │     ├── Tenant is NOT GCC
        │     ├── Policy type: Cloud (all platforms, priority, extension requests, branding)
        │     │            or Intune (Windows only, synced to Intune > Devices > Configuration)
        │     ├── Assigned to Entra user group(s)  → delivered as USER-scope cloud policy
        │     │   OR policy ID pushed as EdgeManagementEnrollmentToken → DEVICE-scope cloud policy
        │     ├── EdgeManagementEnabled not set to 0 on the device
        │     └── User signed into Edge with Entra work account as PRIMARY profile
        ├── [B] Intune / MDM (Settings catalog "Microsoft Edge", Edge security baseline, ADMX)
        │     └── Device/user in assignment, filters match, device checked in
        └── [C] Group Policy (Edge ADMX in central store) → HKLM/HKCU\SOFTWARE\Policies\Microsoft\Edge
              └── Precedence resolution inside Edge
                    ├── Platform (GPO/MDM) beats Edge management service
                    │     unless EdgeManagementPolicyOverridesPlatformPolicy = 1 (registry-only policy)
                    ├── Cloud DEVICE (token) beats cloud USER (group assignment)
                    │     unless EdgeManagementUserPolicyOverridesCloudMachinePolicy = 1
                    ├── Multiple Cloud policies → lowest priority number wins (0 = highest)
                    └── Multiple Intune policies → NO priority; conflict isn't auto-resolved
                          └── Edge restarted → value visible and enforced in edge://policy
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm what Edge thinks.** Open `edge://policy`, click *Reload policies*, and find the setting.
   Good: the expected value, Status *OK*. The **Source** column tells you where it came from: Platform (GPO/MDM registry) or Cloud (Edge management service).
   Bad: missing, wrong source, or an error/conflict status.

2. **Confirm the registry (platform) layer.** Triage #3.
   If a value exists under `HKLM\...\Policies\Microsoft\Edge` and you didn't expect one, find out who wrote it: `gpresult /h $env:TEMP\gp.html` for GPO, or Intune device > *Device configuration* for MDM.

3. **Confirm the cloud layer is reachable.** Triage #2. `EdgeManagementEnabled` must be absent or 1. Also check the user is signed in to Edge with their Entra account as the **primary** profile: `edge://settings/profiles`.

4. **Confirm assignment in the portal.** M365 admin center > Settings > Microsoft Edge > Configuration policies > *policy* > Assignments. The user must be in the group (nested groups are supported if they're Entra-created or synced). Cloud policies created in the Edge management service target **user groups only**.

5. **Confirm timing.** A user with a policy is re-checked every 90 min. With no policy it's every 24 h. On error, it's checked at next launch. **Policies apply only after Edge restarts**, except some privacy-control policies.

6. **Validate the fix.** Close all Edge windows (check Task Manager for `msedge.exe` background processes, including *Startup boost*). Reopen Edge, then check `edge://policy` again.

---
## Common Fix Paths

<details><summary>Fix 1 — Cloud (Edge management service) policy not arriving</summary>

1. Make sure the user is signed into Edge with their **work** account and that it's the **primary** profile. Only the primary account's policies apply on Windows.
2. Make sure the user is in an assigned **user** group, or that "All users" was chosen. Device groups can't be targeted from the Edge management service.
3. Force a refresh: close Edge fully, reopen it, go to `edge://policy`, and click *Reload policies*.
4. Alternative delivery that doesn't need group assignment: push the policy ID as the enrollment token (device scope):
```powershell
# Policy ID from M365 admin center > Settings > Microsoft Edge > policy > Deploy > Copy policy ID
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name EdgeManagementEnrollmentToken -Value '<policy-id>' -Type String
```
In production, deploy this through Intune (Settings catalog: *Microsoft Edge > Edge management enrollment token*) rather than a raw registry write.
</details>

<details><summary>Fix 2 — Intune-delivered Edge setting not arriving</summary>

1. Go to Intune > Devices > *device* > Device configuration and find the Edge profile's state. A **Conflict** status means another Intune profile sets the same setting. Intune configuration policies have **no priority**, so conflicts don't resolve automatically.
2. Resolve by removing the setting from all but one profile. Watch for overlap between the **Edge security baseline**, the Settings catalog, and an Intune-type policy created from the Edge management service (it syncs into Intune as a normal configuration profile).
3. Sync the device (`Company Portal > Sync`, or Intune > Sync). Restart Edge.
</details>

<details><summary>Fix 3 — Wrong value wins (source precedence)</summary>

Default order: **GPO/MDM (platform) > Edge management service**, and **cloud device (token) > cloud user (group)**.

- Preferred: remove the setting from the losing source so there's one source of truth.
- If the business decision is to let the Edge management service win over GPO/MDM:
```powershell
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name EdgeManagementPolicyOverridesPlatformPolicy -Value 1 -Type DWord
```
- If group-assigned (user) cloud policy should beat token (device) cloud policy:
```powershell
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name EdgeManagementUserPolicyOverridesCloudMachinePolicy -Value 1 -Type DWord
```
Restart Edge afterwards. **Rollback:** `Remove-ItemProperty` the same value name.

These are registry-only policies. Document them, because they silently change the precedence model for every setting.
</details>

<details><summary>Fix 4 — Edge management service disabled on the device</summary>

`EdgeManagementEnabled = 0` has been set by GPO, Intune, or a hardening script. Find the source (`gpresult /h`, Intune device configuration). Then remove the setting or set it to 1:
```powershell
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name EdgeManagementEnabled -Value 1 -Type DWord   # or remove the value
```
If a GPO keeps re-writing it, fix the GPO. A local change will be reverted at the next background refresh (around 90 minutes).
</details>

<details><summary>Fix 5 — "I changed it in the portal and nothing happened"</summary>

This is expected latency, not a fault. The next check-in can be up to 90 minutes away (or 24 hours if the user had no policy before), and the value takes effect only when Edge **restarts**. To speed it up for a test user: fully quit Edge (disable *Startup boost* or end `msedge.exe`), reopen it, and use *Reload policies* on `edge://policy`.
</details>

<details><summary>Fix 6 — MSP/GDAP admin can't manage Edge settings</summary>

Microsoft documents that GDAP roles aren't fully supported for the Edge management service. Options:
- Use a **named admin account in the customer tenant** with the *Edge Administrator* role (and PIM if available).
- Or manage Edge through **Intune** (Settings catalog), which works with GDAP Intune roles. Note that an Intune-type policy created **in Intune** gets scope tags, device targeting, exclusions, and filters that the Edge management service UI can't set.
</details>

---
## Escalation Evidence

```
Tenant / GCC?:                      <tenant-id> / <commercial|GCC>
User UPN + Edge primary profile:    <upn> / <work|personal>
Device: OS / join type:             <Win11 24H2, Entra joined | macOS 26 ...>
Edge version + channel:             <x.y.z / Stable>
Setting name (policy):              <PolicyName>
Expected value / actual value:      <..> / <..>
edge://policy Source / Status:      <Platform|Cloud> / <OK|Conflict|Error>
Sources configured for this setting:
   GPO:                             <GPO name | none>
   Intune profile(s):               <profile names | none>
   Edge management service policy:  <name, type Cloud|Intune, priority n | none>
EdgeManagementEnabled:              <absent|0|1>
EdgeManagementEnrollmentToken set:  <yes/no>
Override flags (Platform/UserCloud):<0|1> / <0|1>
Last Edge restart after change:     <time>
Get-EdgePolicySourceAudit.ps1 CSV:  <attached>
```

---
## 🎓 Learning Pointers
- Edge doesn't merge "the latest" setting across sources. It applies a **fixed precedence**: platform (GPO/MDM) > cloud device > cloud user, and two registry-only switches can flip it. Learn it once: [Get started with configuration policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-management-service).
- Only **Cloud**-type policies have priority ordering, extension requests, and org branding. **Intune**-type policies are Windows-only and have no priority. Choose the type deliberately, because you can't convert one into the other later without export/import (which drops Cloud-only settings).
- `edge://policy` is the ground truth. Always read the **Source** column before touching GPO or Intune. Full policy list: [Microsoft Edge browser policy documentation](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies).
- Background: `EdgeManagementEnabled`, `EdgeManagementEnrollmentToken`, and `EdgeManagementPolicyOverridesPlatformPolicy` each have their own policy page in the Edge policy docs. Worth bookmarking.
- Related in this repo: `Intune/Troubleshooting/Policy-Conflict-A.md` (general Intune conflict mechanics), `Intune/Troubleshooting/GP-to-CSP-A.md` (retiring Edge GPOs in favour of Intune), and `Scripts/Get-EdgePolicySourceAudit.ps1` for a one-shot local snapshot.
