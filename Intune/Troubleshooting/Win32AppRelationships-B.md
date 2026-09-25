# Intune Win32 App Supersedence & Dependency Chains — Hotfix Runbook (Mode B: Ops)
> Fix or escalate a Win32 app that won't update, won't replace the old version, installs the wrong thing, or reports a relationship conflict — in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

> Scope: Win32 apps (`win32LobApp`, and Enterprise App Catalog `win32CatalogApp`) only. General install failures (detection rules, exit codes, content download) are in `App-Deployment-B.md`. This runbook is for **relationship** problems: supersedence (update/replace) and dependencies (detect/auto-install).

Run these first — the first block on the device (elevated), the second from an admin workstation:

```powershell
# --- ON THE DEVICE ---
# 1. Is IME processing relationships? (newer IME logs Win32 work to AppWorkload.log; older to IntuneManagementExtension.log)
$logs = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
Select-String -Path "$logs\AppWorkload*.log","$logs\IntuneManagementExtension*.log" -Pattern 'supersed|dependen|conflict' -ErrorAction SilentlyContinue |
    Select-Object -Last 30 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(300, $_.Line.Length)) }

# 2. Is the OLD version still detected? (supersedence decisions are driven by detection, not by what you think is installed)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object DisplayName -like '*<AppName>*' | Select-Object DisplayName, DisplayVersion, PSChildName

# --- FROM ADMIN WORKSTATION ---
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
# 3. Relationships on the app in question
(Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<appId>/relationships").value |
    ForEach-Object { [PSCustomObject]@{ Type=$_.'@odata.type'; Target=$_.targetDisplayName; Dir=$_.targetType; Super=$_.supersedenceType; Dep=$_.dependencyType } }

# 4. Is the superseding app actually assigned?
(Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<appId>/assignments").value |
    Select-Object intent, @{n='Target';e={$_.target.'@odata.type'}}, @{n='GroupId';e={$_.target.groupId}}
```

| Result | Meaning | Go to |
|---|---|---|
| Superseding app has **no assignments** | Supersedence is ignored — superseding apps are never auto-targeted | Fix 1 |
| Old app still detected after a **replace** | Uninstall didn't remove what the detection rule looks for, so IME won't install the new app | Fix 2 |
| Old **and** new both present after an **update** | Expected for update type; the new installer didn't remove the old one | Fix 2 (switch to replace) or accept |
| Portal/IME shows **conflict** | App is both a dependency and superseded in the same subgraph (e.g. A depends on B, C supersedes B) | Fix 3 |
| Can't add another superseded app / save fails on the Supersedence step | Graph node limit (max 11 nodes per supersedence graph) | Fix 4 |
| Available app didn't auto-update | Auto-update not set on the Available assignment, user never installed via Company Portal, or assignment changed after install (consent lost) | Fix 5 |
| Parent app "waiting" / never starts | Dependency not installed and **Automatically install** off, or dependency detection failing | Fix 6 |
| Admin can't see the Supersedence/Dependencies step | Custom role lacks **Mobile apps → Relate** | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Admin role has Mobile apps: Relate]
        │
        ▼
[Relationship configured on the NEW/PARENT app]
   Supersedence: New ──supersedes──► Old   (Uninstall previous version: Yes = replace │ No = update)
   Dependency:   Parent ──depends on──► Child (Automatically install: Yes = autoInstall │ No = detect)
        │
        ▼
[Graph limits respected] supersedence graph ≤ 11 nodes │ dependency graph ≤ 100 apps │ no dep↔supersede conflict
        │
        ▼
[Superseding/parent app is ASSIGNED + applicable] (requirements/filters) — dependencies don't need assignment
        │
        ▼
[Device check-in → IME evaluates the whole subgraph]
        │
        ▼
[Detection rules run for EVERY node] ◄── the #1 root cause: bad detection on the old/child app
        │
        ▼
 replace: uninstall Old → re-detect Old = absent → install New
 update:  install New (Old removal is up to New's installer)
 dependency: install/verify Child first (3 tries, 5 min apart) → install Parent
```
</details>

---

## Diagnosis & Validation Flow

1. **Confirm relationship direction and type**
   ```powershell
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/<appId>/relationships").value |
       ForEach-Object { [PSCustomObject]@{ Type=$_.'@odata.type'; Target=$_.targetDisplayName; Dir=$_.targetType; Super=$_.supersedenceType; Dep=$_.dependencyType } }
   ```
   `Dir = child` means *this* app supersedes, or depends on, the target. `parent` means the target supersedes, or depends on, *this* app. A common mistake is building the relationship on the old app instead of the new one.

2. **Confirm targeting of the superseding app**: Step 4 of the triage must return at least one `required` or `available` assignment for the device's user or device group. No assignment means nothing happens.

3. **Run the OLD app's detection rule by hand on the device.** Copy it from Intune → App → Properties → Detection rules. For a registry or file rule, check it with `Test-Path` / `Get-ItemProperty`. For a script rule, run the script as SYSTEM (`psexec -s`) and check that it writes to STDOUT and exits 0.
   Expected after a replace: the old app is **not** detected. If it's still detected, IME won't install the new app (Microsoft documents this: "If the detection continues to detect A as present, then the agent won't install B").

4. **Check IME's view**: Company Portal → the app shows the superseding version only (Available intent). For Required intent, the device's app install status should flip within one to two check-ins. To force a re-evaluation, restart the IME service: `Restart-Service IntuneManagementExtension`.

5. **Check for a conflict**: in the portal, the app's **Supersedence** and **Dependencies** tabs, plus the per-device install status. A "conflict" status means the relationship design is invalid (Fix 3). It isn't a device problem.

---

## Common Fix Paths

<details><summary>Fix 1 — Superseding app not assigned</summary>

Superseding apps don't inherit the old app's targeting. Assign the new app to the **same groups/intent** as the old one (or broader). You can leave the old app's assignment in place. If the new app is targeted, supersedence runs whether or not the old one is.

```powershell
# Compare assignments old vs new
'<oldAppId>','<newAppId>' | ForEach-Object {
  $a = (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$_/assignments").value
  [PSCustomObject]@{ App=$_; Assignments=($a | ForEach-Object { "$($_.intent):$($_.target.groupId)" }) -join '; ' }
}
```
</details>

<details><summary>Fix 2 — Replace/update not removing the old version</summary>

- **Replace** (`Uninstall previous version = Yes`): check the **old** app's uninstall command (run it as SYSTEM by hand) and its detection rule. The detection must return *absent* after the uninstall.
- **Update** (`= No`): Intune never uninstalls the old app. If the vendor installer leaves the old version side by side, either switch the relationship to *replace* or fix the old app's detection so it's version-specific (e.g. `DisplayVersion -eq '9.7.1'`, not "key exists").
- Changing Yes/No: App → Properties → Supersedence → Edit → toggle → Review + save. **Rollback:** toggle back. The change only affects future evaluations.
</details>

<details><summary>Fix 3 — Dependency ↔ supersedence conflict</summary>

Microsoft-documented patterns:
- A depends on B, and C supersedes B → **conflict** reported.
- A depends on B and C, and B supersedes C → supersedence **won't go through**.
- A depends on B, and C replaces A → C installs and A is replaced, but **B is left behind**.

Fix: point the parent at the **new** version as its dependency first (edit A's Dependencies: remove B, add C). Then retire B. If B is shared by many parents, update each parent before you add any supersedence on B.
</details>

<details><summary>Fix 4 — Supersedence graph too big (≥ 11 nodes)</summary>

Every app ever chained counts (v1 → v2 → … → v10). Break the chain:
1. Make sure the current version is targeted and the old versions are no longer detected on the fleet (the install status report shows 0 installed).
2. Remove the supersedence from the **oldest** links (edit the app that holds the relationship, delete the row).
3. Delete retired app objects.
Keep chains short: supersede only the last one or two versions actually in the field.
</details>

<details><summary>Fix 5 — Available app not auto-updating</summary>

Requirements (all must be true):
- The new app supersedes the old one **and** the new app's **Available for enrolled devices** assignment has **Auto-update** selected.
- The user originally installed the old app **from Company Portal**. Required-intent installs never auto-update through this path.
- The user is signed in. It takes two available check-ins (typically 8–16 h).
- No assignment change since the install. Removing the user from the group, removing the assignment, or switching intent **deletes the consent**, and re-adding Available doesn't restore it.

If consent was lost: deploy the new app as **Required** to a group of devices that still have the old app (dynamic group or a filter), then revert.
</details>

<details><summary>Fix 6 — Parent app blocked on a dependency</summary>

- **Automatically install = No** (`detect`): the parent only proceeds if the child is already detected. Either pre-deploy the child or switch the dependency to **Yes**.
- **Automatically install = Yes**: IME installs the child first (3 attempts, 5 minutes apart), then re-evaluates on the 24-hour cycle. Check the child's detection and install as in Diagnosis step 3. The child doesn't need its own assignment.
- The dependency graph max is 100 apps (parent plus recursive dependencies).
</details>

<details><summary>Fix 7 — Admin can't configure relationships</summary>

Custom Intune role → **Mobile apps → Relate** permission (built-in *Application Manager* and *School Administrator* have it). Tenant administration → Roles → the role → Properties → Permissions → Mobile apps → Relate = Yes.
</details>

---

## Escalation Evidence

```
=== Win32 App Relationship Escalation ===
Ticket #:                    ____________
Tenant ID:                   ____________
New/parent app (name, id):   ____________ / ____________
Old/child app (name, id):    ____________ / ____________
Relationship:                Supersedence (update / replace)  │  Dependency (detect / autoInstall)
Supersedence graph nodes:    ____  (Get-Win32AppRelationshipAudit.ps1)
New app assignments:         intent ____ groups ____________
Device name / IME version:   ____________ / ____________
Old app detected on device?  Yes / No   (rule tested manually as SYSTEM: Yes / No)
Portal install status (old / new):  ____________ / ____________
Conflict reported?           Yes / No
IME log excerpt (AppWorkload.log, lines w/ supersed|dependen|conflict): attached Yes / No
```

---

## 🎓 Learning Pointers

- **Detection is the engine behind supersedence.** Every "replace didn't work" ticket comes down to the old app's detection rule still returning true after the uninstall. Microsoft's case tables spell this out: [Add Win32 app supersedence](https://learn.microsoft.com/en-us/intune/app-management/deployment/configure-win32-supersedence).
- **Supersedence needs targeting, dependencies don't.** That asymmetry explains most "nothing happened" tickets. Dependency behaviour (auto-install, retry, 100-app graph): [Add and assign Win32 apps — Dependencies](https://learn.microsoft.com/en-us/intune/app-management/deployment/add-win32).
- **Auto-update is consent-based and fragile.** Any assignment change after install permanently breaks it for that user. Plan assignments before you ship v1.
- **Graph shows the true topology:** `mobileApps/{id}/relationships` returns both `mobileAppSupersedence` and `mobileAppDependency` objects with direction (`targetType`). Background and example payloads: [Peter van der Woude — supersedence relationships](https://petervanderwoude.nl/post/working-with-supersedence-relationships-for-win32-apps/).
- **Related:** general install failures → `App-Deployment-B.md`. Enterprise App Catalog version updates and auto-update → `EnterpriseAppManagement-B.md`. WinGet/Store apps (no supersedence) → `StoreAppsWinGet-B.md`.
