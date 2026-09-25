# Intune Win32 App Supersedence & Dependency Chains — Reference Runbook (Mode A: Deep Dive)
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

- **In scope:** relationships between Win32 apps in Intune: supersedence (update / replace, chains, auto-update for Available apps) and dependencies (detect / auto-install, recursive graphs), plus how they interact. This covers Win32 LOB apps and Enterprise App Catalog apps (which are Win32 under the hood).
- **Out of scope:** single-app install failures (`App-Deployment-A.md`), Store/WinGet apps (`StoreAppsWinGet-A.md`, no relationships), MSI LOB apps (no relationships), macOS PKG (`macOS/Troubleshooting/PKG-DMG-Apps-A.md`).
- **Sources:** Microsoft Learn *Add Win32 app supersedence* (updated Apr 2026) and *Add and assign Win32 apps* (Dependencies section); Graph beta `mobileAppRelationship` resources; Peter van der Woude (MVP) payload examples.
- **Caveat:** older Learn text said supersedence isn't supported during the Enrollment Status Page, and community reports match that (superseded apps skipped in ESP). The current page doesn't restate it. **Don't** put a superseding app in an ESP blocking list without testing.

---

## How It Works

<details><summary>Full architecture</summary>

### 1. The relationship object model

Both relationship kinds are stored as `mobileAppRelationship` objects **on the app that declares them** and mirrored on the target:

```
GET /beta/deviceAppManagement/mobileApps/{id}/relationships

 #microsoft.graph.mobileAppSupersedence
   targetId / targetDisplayName / targetDisplayVersion / targetPublisher
   targetType        child  = this app supersedes the target
                     parent = the target supersedes this app
   supersedenceType  update  (Uninstall previous version = No)
                     replace (Uninstall previous version = Yes)
   supersededAppCount / supersedingAppCount

 #microsoft.graph.mobileAppDependency
   targetType        child  = this app depends on the target
                     parent = the target depends on this app
   dependencyType    autoInstall (Automatically install = Yes)
                     detect      (Automatically install = No)
   dependentAppCount / dependsOnAppCount
```

The `win32LobApp` object also exposes roll-up counters (`dependentAppCount`, `supersedingAppCount`, `supersededAppCount`). They let you find related apps cheaply before you walk the relationships.

Creating or editing relationships needs the Intune RBAC permission **Mobile apps → Relate** (required since service release 2202).

### 2. Supersedence semantics

| Scenario (new B supersedes old A) | Required intent | Available intent |
|---|---|---|
| A on device, **replace** | Uninstall A (even if A isn't targeted), then install B | Only B visible in Company Portal |
| A on device, **update** | Install B; A's removal is up to B's installer | Only B visible |
| A not on device | Install B | B visible |

Key rules:
- **No automatic targeting.** An untargeted superseding app is ignored by IME. If B is targeted, supersedence happens whether or not A is targeted.
- **Detection gates everything.** In replace mode, IME uninstalls A, then **re-detects A**. B installs only if A is no longer detected. If both are detected, A is uninstalled. If only B is detected, nothing happens.
- **Chains collapse to the head.** In A→B→C, every older app is treated as superseded by C, the head of the chain. Devices with nothing get C directly.
- **Limits:** max **11 nodes per supersedence graph** (superseding + superseded + all related apps). The Supersedence step allows at most 10 related nodes. An app can have at most **10 superseding apps**.
- **AVD multi-session:** only system-context (device) apps can take part in supersedence.

### 3. Auto-update (Available apps)

- Set on the **superseding** app's *Available for enrolled devices* assignment (Auto-update column).
- Only users who installed the superseded app **from Company Portal** get it. Intune creates a hidden device-based assignment that records the user's consent at install time.
- Needs two available check-ins (roughly 1–8 h, then about 8 h later, so 8–16 h in total). The user must be signed in.
- **Consent is destroyed** if, after install, the user leaves the targeted group, the assignment is removed, or the intent changes (e.g. to Uninstall/Exclude). Re-adding Available doesn't restore it. Uninstall intent beats Available.
- A failed auto-update retries indefinitely until the user starts an install from Company Portal.

### 4. Dependency semantics

- The dependency (child) installs **before** the parent. The child needs **no assignment** of its own. That's the opposite of supersedence.
- `autoInstall`: IME installs missing children (recursively). `detect`: IME only checks. If the child is missing, the parent waits.
- Each child follows normal Win32 retry (3 attempts, 5 min apart) and the 24-hour global re-evaluation.
- The dependency graph can hold up to **100 apps** including the parent and recursive children. Circular dependencies are rejected.
- Only targeted apps show install status in the portal. A child installed only as a dependency has no status row of its own, so troubleshoot it from IME logs.

### 5. Interactions (documented by Microsoft)

```
 A ─depends→ B ,  C ─supersedes→ B        ⇒ CONFLICT reported
 A ─depends→ B & C ,  B ─supersedes→ C    ⇒ supersedence does NOT go through
 A ─depends→ B ,  C ─replaces→ A          ⇒ C installs, A replaced, B ORPHANED on device
```
Enforcement prefers supersedence over dependency where both apply. Microsoft also says supersedence can't be used to swap an app into or out of the dependency role.

### 6. Where to see it on the device

`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload.log` (current IME) or `IntuneManagementExtension.log` (older IME). Search for `supersed`, `dependen`, `conflict` and the app GUID. The per-app state and enforcement results are under `HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps\<userSID or 000…>\<appId>`.

</details>

---

## Dependency Stack

```
Layer 6  Outcome        New app present, old removed/updated, children present
Layer 5  Enforcement    IME: uninstall → re-detect → install (supersedence); child-first install (dependency)
Layer 4  Detection      Detection rule of EVERY node in the subgraph (old, new, children)
Layer 3  Targeting      Superseding/parent app assigned + applicable (requirements, filters); children exempt
Layer 2  Graph design   ≤11 nodes supersedence, ≤100 apps dependency, no dep/supersede conflict, correct direction
Layer 1  Objects        mobileAppSupersedence / mobileAppDependency on the declaring app
Layer 0  RBAC           Mobile apps: Relate
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Nothing happens after adding supersedence | Superseding app not assigned | `/mobileApps/{new}/assignments` |
| Old app uninstalled, new never installs | Old app's detection still true after uninstall | Run old detection rule as SYSTEM |
| Both versions installed | *Update* type and the installer is side-by-side | `supersedenceType` |
| Old app uninstalled though it wasn't targeted | Expected for replace + required | Learn behaviour table |
| "Conflict" install status | Dependency on an app that's superseded in the same subgraph | Relationships of the dependency target |
| Parent stuck "Waiting for install status" | `detect` dependency missing, or child detection failing | `dependencyType`; IME log |
| Old dependency left on devices after replacing the parent | Documented orphan behaviour | Add a cleanup Uninstall assignment |
| Can't add more superseded apps | 11-node graph limit | Audit script node count |
| Available app not auto-updated | Auto-update off, not installed via Company Portal, or consent lost | Assignment settings; history of assignment edits |
| Relationships tab missing for an admin | No **Relate** permission | Role definition |
| App skipped during ESP | Supersedence in ESP (historically unsupported) | ESP blocking list |

---

## Validation Steps

1. **Topology**: `.\Get-Win32AppRelationshipAudit.ps1`. Good: every graph ≤ 9 nodes (headroom), no `UntargetedSuperseding`, no `DependencyOnSuperseded` rows.
2. **Relationship detail for one app**
   ```powershell
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<appId>/relationships").value |
       Select-Object '@odata.type', targetDisplayName, targetType, supersedenceType, dependencyType
   ```
   Good: the direction matches your intent (the new app shows the old one as `child`).
3. **Detection truth on a pilot device** (after enforcement): old app detection → false (replace), new app detection → true. Bad: the old app is still detected, so the new app is blocked.
4. **IME log**
   ```powershell
   Select-String -Path 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload*.log' -Pattern '<newAppId>|<oldAppId>' | Select-Object -Last 40
   ```
   Good: a sequence of uninstall → detection → install for the new app, with no "conflict".
5. **Portal**: the new app's device install status shows Installed on the pilot, and the old app's status (if still targeted) moves to Not installed / Not applicable.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Design check (tenant-side, 5 min).** Direction, type, targeting, graph size and conflicts, all from the audit script. Most cases end here.

**Phase 2 — Detection check (device-side).** Evaluate the old, new and child detection rules exactly as IME does (SYSTEM for device-context apps, the user for user-context apps, 32/64-bit as configured).

**Phase 3 — Enforcement trace.** Find the app GUIDs in AppWorkload.log and follow the sequence. Look for uninstall exit codes on the *old* app. A replace depends on the **old** app's uninstall command, which is often untested because nobody uninstalled v1 before.

**Phase 4 — Auto-update specifics.** Confirm the user installed via Company Portal (the device's install status for that user). Check the audit log for assignment edits after that date (Tenant administration → Audit logs, filter "Mobile app assignment").

**Phase 5 — Clean-up and chain hygiene.** Trim long chains, retire orphaned dependencies, and document the head version.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Safe version roll (update or replace)</summary>

1. Upload v2 as a **new** Win32 app, with a version-specific detection rule (e.g. file version `>= 2.0` or `DisplayVersion -eq '2.0.x'`).
2. Add supersedence on v2 → v1. Choose **replace** unless you've verified the vendor installer upgrades in place and v1 detection then returns false.
3. Test v1's **uninstall command** as SYSTEM on a lab device (replace mode depends on it).
4. Assign v2 to a pilot group with the same intent as v1. For Available with auto-update, set Auto-update on v2's Available assignment.
5. Validate (Validation 3–5), then widen v2's assignment to v1's groups.
6. Once v1's installed count is 0, remove v1's assignments. Keep v1 in the chain until the fleet is clean, then trim.
**Rollback:** remove v2's assignment (supersedence stops being enforced). Devices already on v2 stay there, so redeploy v1 as Required only if you have to.
</details>

<details><summary>Playbook 2 — Resolve a dependency/supersedence conflict</summary>

```
Before: A ─depends→ B(v1) ,  B(v2) ─supersedes→ B(v1)   ⇒ conflict
Step 1: Edit A → Dependencies → remove B(v1), add B(v2) (autoInstall)
Step 2: Repeat for every parent of B(v1) (audit script lists them)
Step 3: Keep or remove the B(v2)→B(v1) supersedence (it's now harmless) and retire B(v1)
```
**Rollback:** re-add B(v1) as A's dependency.
</details>

<details><summary>Playbook 3 — Trim an over-long chain</summary>

1. From the audit CSV, pick the graph at 10–11 nodes.
2. For each of the oldest versions: confirm install count = 0 (App → Device install status), remove its assignments, then remove the relationship row on the app that supersedes it (App → Properties → Supersedence → Edit → delete).
3. Delete the retired app objects.
**Rollback:** relationships can be re-added (Relate permission required). Deleted app objects can't be restored, so keep the `.intunewin` source.
</details>

<details><summary>Playbook 4 — Recover lost auto-update consent</summary>

Create a dynamic device group, or use the old app's install-status export, for devices that still have v1. Assign v2 as **Required** to that group, and use a filter if needed. When they report installed, remove the Required assignment and keep v2 Available with Auto-update for new installs.
</details>

<details><summary>Playbook 5 — Clean orphaned dependencies</summary>

After "C replaces A" leaves B behind: assign B with **Uninstall** intent to the affected devices. Check first that no other parent still depends on B (audit CSV `DependedOnBy`), because the uninstall will break those parents.
</details>

---

## Evidence Pack

```powershell
# Collect-Win32RelationshipEvidence.ps1 — run elevated on the affected device
$out = "C:\Temp\Win32RelEvidence_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory $out -Force | Out-Null
$logs = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
Copy-Item "$logs\AppWorkload*.log","$logs\IntuneManagementExtension*.log","$logs\AgentExecutor*.log" -Destination $out -ErrorAction SilentlyContinue
reg export "HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps" "$out\Win32Apps.reg" /y | Out-Null
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Select-Object DisplayName, DisplayVersion, Publisher, PSChildName, UninstallString | Export-Csv "$out\installed-apps.csv" -NoTypeInformation
Get-Service IntuneManagementExtension | Select-Object Status, StartType | Out-File "$out\ime-service.txt"
(Get-Item 'C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe' -ErrorAction SilentlyContinue).VersionInfo.FileVersion | Out-File "$out\ime-version.txt"
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```
Pair this with the tenant-side CSV from `Intune/Scripts/Get-Win32AppRelationshipAudit.ps1`.

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Connect | `Connect-MgGraph -Scopes DeviceManagementApps.Read.All` |
| App relationships | `Invoke-MgGraphRequest GET .../deviceAppManagement/mobileApps/<id>/relationships` |
| App assignments | `Invoke-MgGraphRequest GET .../mobileApps/<id>/assignments` |
| All Win32 apps | `Invoke-MgGraphRequest GET ".../mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"` |
| Tenant topology audit | `.\Get-Win32AppRelationshipAudit.ps1` |
| IME log search | `Select-String "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\AppWorkload*.log" -Pattern 'supersed\|dependen\|conflict'` |
| Force re-evaluation | `Restart-Service IntuneManagementExtension` |
| Installed inventory | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` |
| IME per-app state | `HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps` |

---

## 🎓 Learning Pointers

- **The authoritative behaviour tables:** [Add Win32 app supersedence](https://learn.microsoft.com/en-us/intune/app-management/deployment/configure-win32-supersedence). The eight single-hop cases and eight chained cases are worth learning by heart, because every ticket maps to one of them.
- **Dependencies and the 100-app graph:** [Add and assign Win32 apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32) (Step 5 — Dependencies).
- **Graph object model:** the beta `mobileAppSupersedence` / `mobileAppDependency` resources. See [Peter van der Woude](https://petervanderwoude.nl/post/working-with-supersedence-relationships-for-win32-apps/) for a real payload that shows parent/child direction.
- **Troubleshooting Win32 apps generally:** [Troubleshoot Win32 app issues](https://learn.microsoft.com/en-us/intune/app-management/deployment/troubleshoot-win32) and `App-Deployment-A.md` (detection rules, exit codes, IME logs).
- **Catalog apps and long chains:** if you manage Enterprise App Catalog major-version bumps with supersedence (`EnterpriseAppManagement-A.md`), each bump adds a node. Trim chains before a long-lived catalog app reaches the 11-node limit.
