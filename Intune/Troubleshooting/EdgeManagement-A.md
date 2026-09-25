# Microsoft Edge for Business Policy Management (Edge management service + Intune + GPO) — Reference Runbook (Mode A: Deep Dive)
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

**In scope**
- How Microsoft Edge (Chromium, 115+) receives and resolves enterprise policy from:
  - Group Policy (Edge ADMX)
  - Intune/MDM (Settings catalog *Microsoft Edge* category, Edge security baseline)
  - The **Microsoft Edge management service** in the Microsoft 365 admin center (*Settings > Microsoft Edge*), with its two policy types, **Cloud** and **Intune**
- The precedence switches, the check-in/refresh model, extension management through configuration policies, and MSP/GDAP constraints.

**Out of scope / see elsewhere**
- Edge app protection / MAM on mobile: `Intune/Troubleshooting/AppProtection-A.md`.
- Purview DLP in Edge: `Security/Purview/`.
- Generic Intune policy conflicts: `Intune/Troubleshooting/Policy-Conflict-A.md`.
- Moving Edge GPOs to Intune: `Intune/Troubleshooting/GP-to-CSP-A.md`.

**Assumptions**
- Facts come from the Microsoft Learn article *Get started with configuration policies* (`deployedge/microsoft-edge-management-service`, `updated_at` 2026-06-15), fetched on 2026-09-25.
- The exact labels in the `edge://policy` *Source* column can vary by Edge version. Treat "Platform" and "Cloud" as the two families.
- Windows is the primary platform. Cloud-type policies also cover macOS, iOS, and Android. Intune-type policies are Windows-only.

---
## How It Works

<details><summary>Full architecture</summary>

```
                         ┌─────────────────────────── Microsoft 365 admin center ───────────────────────────┐
                         │  Settings > Microsoft Edge > Configuration policies  (Edge Administrator role)   │
                         │   ┌─────────────────────────┐        ┌──────────────────────────────────────┐    │
                         │   │ CLOUD-type policy        │        │ INTUNE-type policy (Windows only)    │    │
                         │   │ - all platforms          │        │ - needs Intune licence               │    │
                         │   │ - priority (0 = highest) │        │ - synced both ways with Intune >     │    │
                         │   │ - extension requests     │        │   Devices > Configuration            │    │
                         │   │ - org branding           │        │ - NO priority; conflicts unresolved  │    │
                         │   │ - user-group assignment  │        │ - scope tags/filters/device targets  │    │
                         │   └───────────┬─────────────┘        │   only when authored IN Intune        │    │
                         │               │                       └──────────────────┬───────────────────┘    │
                         └───────────────┼──────────────────────────────────────────┼────────────────────────┘
                                         │ Cloud Policy service                     │ Intune MDM channel
         group assignment → USER-scope   │   token (policy ID) → DEVICE-scope       │
                                         ▼                                          ▼
   Group Policy (Edge ADMX) ─────▶  HKLM/HKCU\SOFTWARE\Policies\Microsoft\Edge   ◀── Intune writes the same keys
                                         │  ("Platform" policy)                     (ADMX-backed Settings catalog)
                                         ▼
                              ┌──────────────── msedge.exe policy engine ────────────────┐
                              │  1. Platform (GPO/MDM)          ◀─ wins by default       │
                              │  2. Cloud DEVICE (token)                                 │
                              │  3. Cloud USER (group assignment)                        │
                              │  Switches: EdgeManagementPolicyOverridesPlatformPolicy   │
                              │            EdgeManagementUserPolicyOverridesCloudMachine │
                              │  Applied at Edge (re)start → edge://policy               │
                              └──────────────────────────────────────────────────────────┘
```

**Two policy types in the Edge management service**
- **Cloud** policies live only in the Edge management service. Edge fetches them directly from the Cloud Policy service when a work account signs in. They're the only type with **priority** conflict resolution, **extension requests** (users request, admins approve or deny), and **organization branding**. They cover every Edge platform.
- **Intune** policies are created in the Edge management service but stored as normal Intune configuration profiles. Edits sync both ways. They inherit Intune's lack of priority: two Intune profiles setting the same value produce a conflict that isn't resolved automatically. They support **Windows only**.
- Limitation: an Intune-type policy authored *from the Edge management service* can't set scope tags, device targets, exclusions, or assignment filters. Author it in Intune if you need those.

**Delivery and scope**
- **Group assignment** in the Edge management service delivers the settings as **user** policy.
- **`EdgeManagementEnrollmentToken`** (value = the policy ID, from *Deploy > Copy policy ID*) delivers the same policy as **device** policy, independent of group membership. You push the token itself through GPO or Intune.
- Group-assigned and token-delivered policies are additive. Conflicts resolve as device over user, unless the switch below is set.

**Precedence switches** (registry-only, under `HKLM` or `HKCU\SOFTWARE\Policies\Microsoft\Edge`)
- `EdgeManagementPolicyOverridesPlatformPolicy = 1`: the Edge management service beats GPO/MDM.
- `EdgeManagementUserPolicyOverridesCloudMachinePolicy = 1`: cloud user policy beats cloud device policy.
- `EdgeManagementEnabled = 0`: Edge stops contacting the Edge management service at all. It's on by default from 115.1935.

**Refresh model**
- First Edge sign-in: immediate check.
- User has a policy: re-check every **90 min**.
- User has no policy: re-check every **24 h**.
- No change since last check: next check in **24 h**.
- Error: check at next launch.
- If Edge wasn't running at the scheduled time, the check happens at the next launch.
- New values take effect **on Edge restart**, the same as Group Policy. Some privacy-control policies are the exception.
- On Windows, only the **primary** signed-in account's cloud policies apply. Switching the primary account needs a restart.
- **Nested groups** work if the groups are Entra-created or synced.

**Conflicting cloud policies**: the lowest priority number wins. You can make a tenant-wide ("All users") policy, but its assignment **can't be changed after creation**.

**Import/export**: both policy types export to JSON. Importing into the Edge management service (either type) strips Cloud-only settings such as branding. You can't import directly into the Intune portal.

**Access & availability**: you need the **Microsoft Edge Administrator** role. **GDAP roles aren't fully supported**, which matters a lot for MSPs. The service **isn't available for GCC** plans. Edge 115.0.1901.7 or later is required.
</details>

---
## Dependency Stack

```
L0  Tenant: commercial (not GCC); Intune licence only if Intune-type policies are used
L1  Admin identity: Edge Administrator (native account; GDAP partially unsupported)
L2  Policy objects: Cloud-type (priority) | Intune-type (no priority) | GPO | Intune Settings catalog / baseline
L3  Targeting: Entra user groups (nested OK) | All users (immutable) | enrollment token (device) | Intune device/user groups + filters
L4  Device: Edge ≥115.0.1901.7 · EdgeManagementEnabled ≠ 0 · network to the Cloud Policy service · MDM/GPO healthy
L5  Session: Entra work account signed into Edge as PRIMARY profile
L6  Resolution: Platform > Cloud device > Cloud user (unless override switches) · Cloud priority · Intune = unresolved conflict
L7  Activation: Edge restart → edge://policy shows value + source + status
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Cloud setting never appears in `edge://policy` | User not in the assigned group; not signed in; non-primary profile; `EdgeManagementEnabled=0` | Assignments, `edge://settings/profiles`, registry |
| Cloud setting shows but a different value is enforced | GPO/MDM sets the same policy (platform wins) | Source column; `gpresult`; Intune device config |
| Value flips between two options across users | Two Cloud policies with different priorities, or user-vs-device scope | Priority order; token vs group assignment |
| Intune profile shows **Conflict** | Two Intune profiles (or baseline + Settings catalog + Intune-type Edge policy) set the same setting | Intune per-setting status |
| Change takes hours | 90 min / 24 h cadence plus restart requirement | Timing; Startup boost keeps Edge "running" |
| Extension request workflow missing | Policy is Intune-type (extension requests are Cloud-only) | Policy type |
| Org branding not applied | Intune-type policy, or branding lost after import | Policy type; re-add branding |
| Can't target devices / add filters from the Edge management service | Edge management service assigns user groups only | Author in Intune instead |
| MSP admin sees an access error | GDAP not fully supported | Use a native tenant admin with the Edge Administrator role |
| Settings > Microsoft Edge missing in the portal | GCC tenant, or lacking the role | Tenant type; role assignment |
| Policy applies for user A but not for user B on the same shared PC | Cloud user policy follows the Edge-signed-in primary account | Each user's Edge profile |
| macOS/iOS/Android not getting a policy | Intune-type policies are Windows-only | Use Cloud-type |

---
## Validation Steps

1. **Edge version**: `(Get-Item "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe").VersionInfo.ProductVersion` → 115.0.1901.7 or later. Below that, the Edge management service isn't supported.
2. **Service gate**: `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Edge -Name EdgeManagementEnabled -EA 0` → absent or 1. A value of 0 means the cloud channel is off.
3. **Account**: `edge://settings/profiles` → the primary profile is the Entra work account, and sync/sign-in shows as work.
4. **Ground truth**: `edge://policy` → *Reload policies* → the setting shows the expected value, a Source, and Status OK. A conflict or error status means you need to resolve the sources.
5. **Platform layer**: `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Edge`, and the same for `HKCU`. Any unexpected value there beats cloud policy by default.
6. **Portal side**: the policy lists the user's group, the priority is as intended, and the policy type (Cloud/Intune) fits the feature you need.
7. **Intune side** (Intune-type or Settings catalog): per-setting status on the device is Succeeded, not Conflict.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Design / authoring**
- Decide on one source of truth for each setting. The usual MSP pattern is Intune for security baselines and device-scoped hardening, and the Edge management service (Cloud type) for user-experience settings, extensions, and branding.
- Don't let the Edge security baseline and an Intune-type Edge policy both set the same setting.

**Phase 2 — Delivery**
- *Cloud*: check the group assignment, the sign-in state, `EdgeManagementEnabled`, and outbound HTTPS to Microsoft endpoints.
- *Token*: check that the token value equals the current policy ID. A copied or deleted policy has a different ID.
- *Intune*: check the device check-in, assignment, and filters.
- *GPO*: check `gpresult`, and that the ADMX version in the central store is current enough to contain the setting.

**Phase 3 — Resolution**
- Read the Source column.
- Platform beats cloud. Cloud device beats cloud user. Cloud priority orders cloud policies. Intune conflicts stay unresolved.
- Check both override switches in HKLM **and** HKCU.

**Phase 4 — Activation**
- Restart Edge fully. Startup boost and background mode can keep `msedge.exe` alive after the windows are closed.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Consolidate a setting to a single source</summary>

1. Inventory: run `Scripts/Get-EdgePolicySourceAudit.ps1 -PolicyName <name>` on an affected device, and export the Edge management service policies to JSON.
2. Remove the setting from every source except the chosen one (GPO → *Not configured*; Intune → remove the setting from the profile; Edge management service → delete the setting).
3. Wait for GPO/MDM refresh, then restart Edge and verify in `edge://policy`.

**Rollback:** re-add the setting to the previous source. Keep the exported JSON and GPO backup (`Backup-GPO`).
</details>

<details><summary>Playbook 2 — Deploy an Edge management service policy by token via Intune</summary>

1. Copy the policy ID: M365 admin center > Settings > Microsoft Edge > policy > Deploy > *Copy policy ID*.
2. In Intune, go to the Settings catalog > *Microsoft Edge* and configure the enrollment-token setting with that ID. Assign it to a **device** group.
3. Result: the policy applies as **device** policy on those machines for any work-signed-in user. It outranks group-assigned user policy unless `EdgeManagementUserPolicyOverridesCloudMachinePolicy = 1`.

**Rollback:** unassign or delete the Intune profile. The token value is removed at the next MDM sync, and cloud device policy stops after the next Edge check-in and restart.
</details>

<details><summary>Playbook 3 — Let the Edge management service win over legacy GPO during a migration</summary>

1. Deploy `EdgeManagementPolicyOverridesPlatformPolicy = 1` (DWORD, `HKLM\SOFTWARE\Policies\Microsoft\Edge`) through an Intune remediation or a platform script. It's documented as registry-only.
2. Pilot on a small group and confirm the Source column now reflects cloud values for overlapping settings.
3. Retire the Edge GPOs, then **remove the override**. Leaving it in place permanently hides future MDM hardening.

**Rollback:** `Remove-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Edge -Name EdgeManagementPolicyOverridesPlatformPolicy`, then restart Edge.
</details>

<details><summary>Playbook 4 — Move from Intune-type to Cloud-type (e.g. to gain priority/extension requests/macOS)</summary>

1. Export the Intune-type policy to JSON from the Edge management service.
2. Create a new **Cloud** policy and import the JSON. Cloud-only settings aren't in the source anyway.
3. Assign it to the same user groups, and set its priority.
4. Unassign and then delete the Intune-type policy. That also removes the synced Intune profile.

**Rollback:** reassign the original Intune-type policy. Keep it unassigned rather than deleted until the change is validated.
</details>

---
## Evidence Pack

```powershell
# Edge policy evidence pack — run as the affected user (admin not required). Read-only.
$out = Join-Path $env:TEMP ("EdgePolicyEvidence_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$exe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
       Where-Object { Test-Path $_ } | Select-Object -First 1
"EdgeVersion: " + $(if ($exe) { (Get-Item $exe).VersionInfo.ProductVersion } else { 'not found' }) | Out-File "$out\summary.txt"
foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge','HKCU:\SOFTWARE\Policies\Microsoft\Edge',
               'HKLM:\SOFTWARE\Policies\Microsoft\Edge\Recommended','HKCU:\SOFTWARE\Policies\Microsoft\Edge\Recommended') {
    $safe = ($k -replace '[:\\]', '_')
    if (Test-Path $k) {
        (Get-ItemProperty $k).PSObject.Properties | Where-Object Name -notlike 'PS*' |
            Select-Object Name, @{n='Value';e={ if ($_.Name -eq 'EdgeManagementEnrollmentToken') { '<redacted>' } else { $_.Value } }} |
            Export-Csv "$out\$safe.csv" -NoTypeInformation
    }
}
gpresult /h "$out\gpresult.html" /f 2>$null
dsregcmd /status > "$out\dsregcmd.txt"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' -ErrorAction SilentlyContinue |
    Where-Object PSChildName -match 'edge' | Select-Object PSChildName | Export-Csv "$out\mdm_edge_areas.csv" -NoTypeInformation
Write-Host "Also: open edge://policy > 'Export to JSON' and save it into $out"
Write-Host "Evidence written to $out"
```

---
## Command Cheat Sheet

| Command / location | Purpose |
|---|---|
| `edge://policy` → Reload policies / Export to JSON | Ground truth: value, source, status |
| `edge://settings/profiles` | Primary account check |
| `edge://management` | Shows whether the browser is managed, and by whom |
| `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Edge` | Machine platform policy |
| `Get-ItemProperty HKCU:\SOFTWARE\Policies\Microsoft\Edge` | User platform policy |
| `...\Policies\Microsoft\Edge\Recommended` | Recommended (user-overridable) values |
| `gpresult /h $env:TEMP\gp.html` | Which GPO set Edge policies |
| `EdgeManagementEnabled` | Cloud channel on/off |
| `EdgeManagementEnrollmentToken` | Device-scope cloud policy by ID |
| `EdgeManagementPolicyOverridesPlatformPolicy` | Cloud beats GPO/MDM |
| `EdgeManagementUserPolicyOverridesCloudMachinePolicy` | Cloud user beats cloud device |
| M365 admin center > Settings > Microsoft Edge | Edge management service |
| Intune > Devices > Configuration (Settings catalog: Microsoft Edge) | MDM Edge settings / synced Intune-type policies |
| `Scripts/Get-EdgePolicySourceAudit.ps1` | One-shot local audit + CSV |

---
## 🎓 Learning Pointers
- Chromium-based Edge resolves policy by **source rank, not timestamp**. Once you know the rank (platform > cloud device > cloud user) and the two override switches, almost every "my setting doesn't apply" ticket becomes a 2-minute read of `edge://policy`. Reference: [Get started with configuration policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-management-service).
- The **policy type is a design decision**. Cloud type gives priority, extension requests, branding, and cross-platform reach. Intune type gives RBAC, scope tags, filters, and device targeting (when authored in Intune). Pick per use case, and write the choice down in the client's standards doc.
- For MSPs, the **GDAP gap** is the operational catch. Plan a native Edge Administrator account (ideally PIM-eligible) per customer, or keep Edge management in Intune.
- Extensions: the `ExtensionSettings` policy is the most powerful and most misconfigured Edge policy. Read [Detailed guide to the ExtensionSettings policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-manage-extensions-ref-guide) before building allow/block lists.
- Browse or search every setting and its GPO/registry name in the [Microsoft Edge browser policy documentation](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies).
