# Intune Enterprise App Management — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

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

Enterprise App Management (EAM) is the feature that lets you add and auto-update **Enterprise App Catalog** apps — a Microsoft-curated, Microsoft-hosted library of pre-packaged Win32 apps. Under the hood, catalog apps flow through the **exact same IME/Win32 delivery pipeline** as any admin-uploaded `.intunewin` app (see `App-Deployment-A.md`) — the only difference is who packages the content and who maintains the detection rules/version metadata. If the symptom is a generic "install failed" error code, go to `App-Deployment-B.md` first. This runbook is for catalog-specific behavior: content sync, auto-update, licensing, and catalog lifecycle.

```powershell
# 1. Confirm the app is actually an Enterprise App Catalog app (not a look-alike admin-uploaded Win32 app)
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"
Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<AppName>'" |
    Select Id, DisplayName, "@odata.type", PublishingState

# 2. Check the app's current install/update status on the device (Intune admin center)
#    Devices > Monitor > Certificates is NOT this — use:
#    Apps > All apps > <AppName> > Device install status
#    Apps > Monitor > App install status, or the Managed Apps report:
#    Reports > Apps > Managed Apps report

# 3. On the device — confirm IME is processing app policy at all (shared pipeline with all Win32 apps)
Get-Service -Name "IntuneManagementExtension" | Select Status, StartType
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 200 |
    Select-String -Pattern "error|fail|EnterpriseAppCatalog" -CaseSensitive:$false

# 4. Confirm tenant licensing covers Enterprise App Management (standalone SKU or Intune Suite)
#    Entra admin center > Billing > Your products, or:
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "INTUNE|EMS|SPE" } | Select SkuPartNumber, ConsumedUnits, PrepaidUnits
```

| If... | Then... |
|---|---|
| App shows **"content is still being prepared"** for more than a few hours | Catalog content sync/validation delay — see Fix 1 |
| Auto-update pushed a version that's now broken/crashing | **No rollback exists for auto-update by design** — see Fix 2 |
| App tile disappeared / can no longer be found in the catalog | Vendor requested removal from the catalog — existing installs are unaffected, see Fix 3 |
| Same app appears to be fighting itself (two tiles, reinstall loop) | The same app is deployed **both** as an EAC catalog app **and** a separately-uploaded Win32 package | Fix 4 |
| Auto-update app can't be added as an ESP/Autopilot Device Prep blocking app | **Documented limitation** — auto-update apps aren't supported as blocking apps | Fix 5 |
| Catalog shows a newer version available but device never updates | Auto-update not enabled (requires **Required** assignment) — see Fix 6 |
| Generic install failure (0x87D1041C, 0x80070005, stuck Pending, etc.) | Not an EAM-specific issue — this is the standard Win32/IME pipeline | Go to `App-Deployment-B.md` |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Tenant licensed for Enterprise App Management]  (standalone SKU or Intune Suite)
        │
        ▼
[Enterprise App Catalog]  (Microsoft-curated, Microsoft-hosted Win32 apps — exe/msi only)
        │  Update pipeline: Ingestion → Automated Validation (~24h target) → Manual Validation (up to 7d) → Catalog Availability
        │  Content cached up to 1 hour — freshly-published versions may lag briefly
        ▼
[Admin adds catalog app to tenant]  (Intune prefills install/uninstall cmd + detection rule — Windows only)
        │
        ▼
[Standard Win32/IME delivery pipeline]  ← same as App-Deployment-A.md, no shortcuts here
        │
        ├──► [Self-updating app?]  Intune only ensures ≥ minimum version; vendor's own updater does the rest
        │        (may need firewall/network rules allowing the vendor's update endpoint)
        │
        └──► [Auto-update enabled?]  Required assignment + Windows 10/11 only
                 │  All targeted devices update simultaneously — no rings, no phased rollout
                 │  No automatic rollback if the new version is broken
                 │
                 └──► [Referenced as ESP / Autopilot Device Prep blocking app?]
                          Only non-auto-update catalog apps are supported in this role
```

If any step above is being diagnosed with `.intunewin` packaging steps, IntuneWinAppUtil, or a custom detection rule you wrote yourself, you're likely troubleshooting a *look-alike* admin-uploaded Win32 app, not an actual catalog app — verify with Triage step 1.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm licensing covers Enterprise App Management**
Portal: **Microsoft Intune admin center > Tenant administration > Licenses**, or Entra admin center > Billing.
Expected: Enterprise App Management standalone SKU or Microsoft Intune Suite present with available seats. Without this, the Enterprise App Catalog won't appear as an app source at all.

**Step 2 — Confirm the app source is genuinely the catalog**
```powershell
Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<AppName>'" | Select Id, DisplayName, "@odata.type"
```
Catalog apps carry Microsoft-managed metadata distinguishing them from admin-uploaded Win32 apps in the portal's **Apps > Enterprise App Catalog apps** view — if the app isn't listed there, it's not a catalog app and this runbook doesn't apply.

**Step 3 — Check catalog content readiness**
Portal: **Apps > Enterprise App Catalog apps** → select the app → confirm content shows **Ready**, not **"content is still being prepared."** The catalog is cached up to one hour; a version bump can briefly show stale data.

**Step 4 — Check device-side processing (shared Win32 pipeline)**
```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 300 |
    Select-String -Pattern "error|fail|0x8" -CaseSensitive:$false
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log" -Tail 200 |
    Select-String -Pattern "error|exitcode|fail" -CaseSensitive:$false
```
If these logs show generic Win32 install/detection failures, hand off to `App-Deployment-B.md` — the catalog origin of the app doesn't change IME's behavior here.

**Step 5 — Check auto-update configuration and assignment type**
Portal: **Apps > Enterprise App Catalog apps** → the app → **Properties > Assignments**.
Auto-update only applies to apps with a **Required** assignment. If the assignment is **Available**, there is no auto-update — updates require a manual supersedence relationship instead.

**Step 6 — Check for a duplicate/conflicting deployment of the same app**
```powershell
Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'<AppNamePrefix>')" | Select Id, DisplayName, "@odata.type"
```
Look for more than one app object targeting the same underlying application (one EAC catalog app + one admin-uploaded Win32 app). Both installing/uninstalling each other in a loop is the classic symptom (Fix 4).

---
## Common Fix Paths

<details><summary>Fix 1 — App stuck "content is still being prepared" for hours</summary>

This is a documented, not-fully-explained state: catalog content sync occasionally stalls past the normal ~1-hour cache window.

1. Wait at least 1 hour after adding/updating the app before treating this as broken — cache lag alone explains most short delays.
2. If it's still showing "being prepared" after several hours, Microsoft's own guidance is: **delete the app and re-add it from the catalog.** There is no supported "retry content sync" action.
3. After re-adding, re-confirm assignment (it is not preserved across delete/re-add) and re-assign to the target group.

**Rollback:** N/A — this is itself the recovery step. Deleting an app that's stuck in this state has no install-base impact since it never successfully deployed.

</details>

<details><summary>Fix 2 — Auto-update pushed a broken version</summary>

Auto-update has **no rollback and no automatic uninstall remediation** by design (documented limitation). You must act manually:

1. Confirm the bad version via the Managed Apps report or:
   ```powershell
   Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" |
       Get-ItemProperty | Where-Object DisplayName -like "*<AppName>*" | Select DisplayName, DisplayVersion
   ```
2. Immediate mitigation options (pick one):
   - Assign an **Uninstall** intent for the app to affected devices, then re-add a Required assignment once a fixed version is available in the catalog.
   - Deploy a Proactive Remediation script that detects the bad version and rolls back/reinstalls a known-good version from a separately packaged Win32 app.
3. **Disable auto-update** on the app (Properties > Assignments) until you've confirmed the next catalog version is stable — this does not undo the current bad install, it only stops future automatic pushes.
4. If Microsoft has flagged the version as malicious, they've already pulled it from the catalog — that stops *new* installs, but you're still responsible for identifying and remediating devices that got it before the pull. Check the Intune admin center notification feed for a malicious-version notice.

**Rollback:** none available at the platform level — this fix path *is* the rollback, performed manually.

</details>

<details><summary>Fix 3 — App removed from the Enterprise App Catalog (vendor request)</summary>

Vendors occasionally request removal of their app from the catalog (documented precedent: think-cell). When this happens:

1. Existing deployments and installed instances on user devices **are not affected** — they continue to function normally.
2. **No new deployments are possible** — the app can no longer be added to additional devices/groups from the catalog.
3. For future deployments, either work directly with the vendor for their own installer, or package it yourself as a traditional admin-uploaded Win32 app (`App-Deployment-A.md` Playbook 3).

**Rollback:** N/A — this is a vendor-driven catalog change, not something to undo locally.

</details>

<details><summary>Fix 4 — Same app deployed via both EAC and a separate Win32 upload</summary>

Symptom: reinstall loop, or the app alternates between installed/uninstalled with no admin action.

1. Inventory every app object referencing this application:
   ```powershell
   Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'<AppNamePrefix>')" | Select Id, DisplayName, "@odata.type"
   ```
2. Pick one deployment type to be authoritative — the Enterprise App Catalog version if you want auto-update, or your own Win32 package if you need phased rollout rings (which EAC auto-update doesn't support).
3. Remove the assignment (not necessarily the app object) for the non-authoritative version, or uninstall it entirely if it's fully redundant.
4. Force a sync and confirm only one deployment type is active for the app going forward.

**Rollback:** re-adding the removed assignment restores the prior (broken) dual-deployment state — don't, unless you're deliberately reverting this fix.

</details>

<details><summary>Fix 5 — Auto-update app rejected as an ESP/Autopilot Device Prep blocking app</summary>

This is a documented, hard limitation — not a bug: apps with auto-update enabled cannot be selected as a blocking app in the Enrollment Status Page or Autopilot Device Preparation profile.

Fix: pick one of:
- Disable auto-update on that specific catalog app, accepting that you'll manage its version manually going forward, or
- Use a different (non-auto-update) catalog app or a traditional Win32 package for the blocking-app role, and keep auto-update enabled on the separate, non-blocking deployment of the app elsewhere.

**Rollback:** re-enabling auto-update simply re-triggers the same restriction; no data risk either way.

</details>

<details><summary>Fix 6 — Catalog shows a new version but device never updates</summary>

1. Confirm the app's assignment is **Required**, not Available — auto-update does not apply to Available/user-initiated apps.
   Portal: **Apps > Enterprise App Catalog apps** → the app → **Assignments**.
2. Confirm auto-update is actually toggled on for this app (Step 6 of "Assignments" when adding/editing the app) — it is opt-in per app, not a tenant-wide default.
3. If auto-update is off by design, use **Apps > Enterprise App Catalog apps with updates** to see available versions, then use **guided update supersedence** to push the new version manually rather than waiting on auto-update.
4. If auto-update is on and Required but still not updating, remember: **no rollout rings** — it should hit all targeted devices simultaneously once processed. Check whether the device has checked in recently (`Get-ScheduledTask -TaskPath "\Microsoft\Intune\"`).

**Rollback:** N/A — corrective configuration check only.

</details>

---
## Escalation Evidence

```
Ticket: Intune Enterprise App Management issue
─────────────────────────────────────────
App name (as shown in Enterprise App Catalog apps):  <____________________>
Confirmed via Graph this is a catalog app, not a look-alike upload?  Y / N
Tenant licensed for EAM (standalone or Intune Suite)?  Y / N
Assignment type (Required / Available):  <____________________>
Auto-update enabled for this app?  Y / N
Catalog content status (Ready / "still being prepared" / unknown):  <__________>
Device(s) affected (name(s) or "fleet-wide"):  <____________________>
IME service status on affected device:  <____________________>
Any duplicate app objects for the same underlying app?  Y / N
Was this app recently removed/re-added, or was a version recently auto-updated?  <__________>
Time this was first noticed: <____________________>
```

---
## 🎓 Learning Pointers

- **Enterprise App Catalog apps ride the exact same IME/Win32 pipeline as anything you'd package yourself.** The catalog only changes who authors the content and detection rules — Microsoft does. Generic install failures (bad detection rule, access denied, dependency missing) are still `App-Deployment-B.md`/`-A.md` problems, not EAM problems. [Microsoft Intune Enterprise Application Management](https://learn.microsoft.com/en-us/intune/app-management/deployment/enterprise-app-management)

- **Auto-update has no rollback, no phased rollout, and no version history — by design.** This makes it fundamentally different from a controlled Win32 deployment. Before enabling auto-update on a business-critical app, weigh whether the convenience is worth losing rollout rings and rollback capability. [Auto-update for Enterprise App Catalog apps](https://learn.microsoft.com/en-us/intune/app-management/deployment/enterprise-app-management#auto-update-for-enterprise-app-catalog-apps)

- **"Content still being prepared" for hours has exactly one supported fix: delete and re-add.** There's no supported way to force a re-sync of stuck catalog content — don't spend triage time hunting for one.

- **Auto-update apps are explicitly excluded from ESP/Autopilot Device Prep blocking-app roles.** If a client wants both "always the latest version" and "must install before the user reaches the desktop," they can't have both on the same app object — this is a real design trade-off to surface during onboarding conversations, not a configuration mistake to fix.

- **Enterprise App Management doesn't use Winget.** Catalog apps are installed directly by the Intune Management Extension, same as any other Win32 app — don't chase Winget-specific logs or the separate Microsoft Store (new)/Winget app type when troubleshooting a catalog app. [Enterprise App Management FAQ](https://learn.microsoft.com/en-us/intune/app-management/deployment/enterprise-app-management#frequently-asked-questions-faq)
