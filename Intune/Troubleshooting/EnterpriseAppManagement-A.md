# Intune Enterprise App Management — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Microsoft Intune **Enterprise App Management (EAM)** — the licensed feature and the **Enterprise App Catalog** it unlocks
- Catalog app lifecycle: Microsoft's ingestion/validation/publication pipeline (SLOs), content caching, and vendor-initiated removal
- Adding a catalog app to a tenant, prefilled install/detection metadata, self-updating apps vs. platform auto-update
- Auto-update mechanics and its documented limitations (no rollback, no rings, cache lag, ESP/Autopilot exclusion, deployment-type conflicts)
- Windows Autopilot ESP / Autopilot Device Preparation integration for catalog apps used as blocking apps
- Licensing model (standalone SKU vs. Intune Suite) and co-management interaction

**Does not cover:**
- Generic Win32 app packaging, IME internals, detection rule mechanics, dependency/supersedence troubleshooting — **all of that is identical for catalog and non-catalog apps** and lives in `App-Deployment-A.md`/`-B.md`. This runbook only documents what's *different* about catalog-sourced apps.
- Microsoft 365 Apps (Office) deployment/update channels — separate pipeline, see `M365/Apps/Deployment-UpdateChannels-A.md`.
- macOS, iOS, or Android app management — Enterprise App Catalog is a **Windows-only** feature.
- General Autopilot ESP/Device Preparation profile design — see `Autopilot/` — this runbook only covers the narrow intersection where a *catalog app specifically* is used as a blocking app.

**Assumed role:** Intune Administrator or Global Administrator, with the tenant licensed for Enterprise App Management (standalone SKU or as part of Microsoft Intune Suite).

**Environment:** Windows 10 or Windows 11 devices, Entra joined or hybrid joined, IME present (same prerequisite as any Win32 app).

---
## How It Works

<details><summary>Full architecture</summary>

### What the Enterprise App Catalog actually is

The Enterprise App Catalog is a Microsoft-curated collection of prepared **Win32 apps** (`.exe`/`.msi` installers, packaged the same way any admin would package a Win32 app) that Microsoft hosts and maintains centrally. Instead of an admin downloading vendor.exe, running `IntuneWinAppUtil.exe`, and hand-writing detection rules, they pick the app from the catalog and Intune **prefills**:

- Install command
- Uninstall command
- Detection rule(s) — though these can still be manually edited or replaced with a custom detection script if needed

The app then flows through the **identical IME/Win32 delivery pipeline** documented in `App-Deployment-A.md` — same CDN content delivery, same Delivery Optimization peer-caching, same SYSTEM/user execution context split, same detection-rule re-evaluation after install. Nothing about *device-side* processing changes. What changes is entirely upstream: who authors the package, and a small set of catalog-specific lifecycle behaviors layered on top.

### The catalog content pipeline (Service Level Objectives, not Agreements)

Microsoft publishes an update-processing pipeline for catalog app versions:

```
[App update ingested from vendor/data source]
        │  SLO clock starts here
        ▼
[Automated Validation]  — compatibility and compliance checks
        │  Target: 80-90% of updates processed and available within 24 hours of ingestion
        ▼
[Manual Validation]  — only if automated validation needs more testing
        │  Completed within 7 days
        ▼
[Catalog Availability]  — published, appears as an available version in the tenant's catalog view
```

Exception handling: security-critical updates can be expedited (~48-hour goal). Apps that fail **both** automated and manual validation are flagged unsupported and won't reach Catalog Availability. These are **SLOs (Service Level Objectives)** — target timelines Microsoft aims for — not **SLAs (Service Level Agreements)** with contractual guarantees. Don't quote them to a client as a guarantee.

Separately, already-published catalog content is **cached for up to one hour**. A version bump can briefly show stale metadata in the tenant's view purely due to this cache — not a fault.

### Self-updating apps vs. platform auto-update — two distinct mechanisms

These are easy to conflate but are architecturally different:

| Mechanism | What it does | Requirements |
|---|---|---|
| **Self-updating app** | The app has its own internal updater (e.g., a browser or client with built-in auto-update). Intune's job is only to ensure the device has *at least* the target minimum version — it considers the app "installed" as long as the detected version meets that floor, regardless of how the device got there. | May require tenant network rules that allow the app's own update traffic out to the vendor's servers — Intune doesn't manage this traffic. |
| **Platform auto-update** | Intune itself detects a newer catalog version and pushes/reinstalls the app via the standard Win32 pipeline, with no admin action required per version. | Only for catalog apps with a **Required** assignment. Only supported on Windows 10 and Windows 11. Opt-in per app (Step 6: Assignments when adding/editing the app). |

An app can be self-updating from the vendor's side *and* have Intune's platform auto-update disabled (admin manages major version bumps manually via supersedence) — these two switches are independent.

### Windows Autopilot integration

Enterprise App Catalog apps are supported as **blocking apps** in both the Enrollment Status Page (ESP) and the Autopilot Device Preparation Page (DPP) profile. The practical benefit: because the app reference in the ESP/DPP profile points at a *catalog app object*, not a pinned package version, an admin can update which version installs during Autopilot simply by letting the catalog app's version advance — without needing to edit and republish the ESP/DPP profile itself.

This benefit has a hard boundary: **auto-update apps are not supported as blocking apps.** The blocking-app role requires deterministic, synchronous completion during provisioning; an app that can silently swap versions mid-flight (auto-update's behavior) isn't compatible with that model. If an app needs to be both "always current" and "a blocking app," those are two separate requirements this feature cannot satisfy simultaneously on one app object.

### Licensing and Configuration Manager interaction

Enterprise App Management can be purchased as a **standalone SKU** or as part of the **Microsoft Intune Suite**. It's an Intune-only feature — Configuration Manager doesn't directly support deploying Enterprise App Catalog apps. However, in a co-managed environment, a co-managed client **can** receive catalog apps as long as the app itself is targeted from the Intune side — the app workload doesn't need to be fully switched to Intune authority for this to work, only that specific app's deployment source does.

### What Microsoft does and doesn't guarantee about catalog content

Microsoft hosts and distributes the app content, and screens it through the validation pipeline above, but explicitly does **not** guarantee authorization, authenticity, or integrity of the underlying vendor software. The customer remains responsible for ensuring apps meet their own security/compliance requirements — the catalog is a *convenience and delivery* mechanism, not a security review process to rely on in place of your own vendor risk assessment.

Similarly, Intune provides **no running-application-usage detection** for catalog apps — install/detection state only. You can know an app is installed; you cannot learn from this feature whether or how often it's actually being used.

### Catalog lifecycle: removal

Vendors can request removal of their app from the catalog (documented precedent: think-cell apps were removed at the vendor's request). When this happens:
- Existing installs on already-targeted devices are unaffected and continue to function.
- No *new* deployments of that app from the catalog are possible going forward.
- Future deployments require either working directly with the vendor for their installer, or packaging it as a traditional Win32 app.

</details>

---
## Dependency Stack

```
Tenant licensing (EAM standalone SKU OR Microsoft Intune Suite)
        │
        ▼
Enterprise App Catalog (Microsoft-hosted, Microsoft-validated Win32 content — Windows only)
        │  Ingestion → Automated Validation (~24h SLO) → Manual Validation (≤7d SLO) → Catalog Availability
        │  Published content cached up to 1 hour
        ▼
Catalog app added to tenant (Intune prefills install/uninstall cmd + detection rule; admin can edit)
        │
        ▼
Standard Win32 / IME delivery pipeline  ─── identical to any admin-uploaded Win32 app, see App-Deployment-A.md
        │
        ├──► Self-updating app path (optional, vendor-controlled; needs network egress to vendor update endpoint)
        │
        └──► Platform auto-update path (optional, opt-in per app)
                 requires: Required assignment + Windows 10/11
                 behavior: all targeted devices updated simultaneously, no rings, no rollback, no version history
                 │
                 └──► ESP / Autopilot Device Preparation blocking-app reference
                          only compatible with non-auto-update catalog apps
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| App stuck "content is still being prepared" for hours | Catalog content sync/cache lag, or a stalled backend publish | Wait ~1hr for cache; if unresolved after several hours, delete and re-add the app (no supported force-resync) |
| Auto-update pushed a broken/crashing version | Auto-update has no rollback or automatic uninstall remediation by design | Manually assign Uninstall intent or remediation script; disable auto-update until the next version is confirmed stable |
| App tile / catalog entry disappeared entirely | Vendor requested removal from the catalog | Existing installs unaffected; no new deployments possible; switch to vendor-direct or traditional Win32 packaging |
| Same app reinstalling/uninstalling in a loop, two app tiles for one product | Same app deployed simultaneously as an EAC catalog app **and** a separate admin-uploaded Win32 package | Consolidate to a single deployment type per app |
| Can't add an auto-update-enabled app as an ESP/Autopilot Device Prep blocking app | Documented, hard limitation — not a bug | Disable auto-update on that app, or use a different app/package for the blocking-app role |
| Reporting shows inconsistent per-device status right after a version rolled out | Version changes mid-processing across the fleet; some devices haven't checked in yet; reporting reflects latest state only, no history | Wait for a full check-in cycle (up to 8h default), re-pull the Managed Apps report |
| App only deployable on Windows, not macOS/iOS/Android | Enterprise App Catalog is explicitly Windows-only | Use a platform-appropriate deployment method for non-Windows devices |
| Catalog shows a new version but device never updates | Assignment is Available (not Required), or auto-update wasn't opted in for this specific app | Confirm Required assignment; confirm auto-update toggle; otherwise use guided update supersedence manually |
| Self-updating app shows an old version despite Intune reporting "Installed" | Intune only enforces a minimum version floor for self-updating apps — it doesn't force the vendor's own updater to run | Confirm detected version ≥ configured minimum; check whether tenant network rules block the vendor's own update traffic |
| Generic install failure code (0x87D1041C, 0x80070005, etc.) on a catalog app | Not catalog-specific — standard Win32/IME failure mode | Diagnose via `App-Deployment-A.md`/`-B.md`; catalog origin doesn't change device-side behavior |

---
## Validation Steps

**1. Confirm EAM licensing is present**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "INTUNE|EMS|SPE|EAM" } |
    Select SkuPartNumber, ConsumedUnits, @{N='Prepaid';E={$_.PrepaidUnits.Enabled}}
```
_Good:_ a SKU covering Enterprise App Management or Intune Suite shows available seats.
_Bad:_ no matching SKU — the Enterprise App Catalog app source won't be usable tenant-wide.

**2. Confirm the app object is genuinely a catalog app**
```powershell
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All"
Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<AppName>'" | Select Id, DisplayName, "@odata.type", PublishingState
```
_Good:_ app appears under **Apps > Enterprise App Catalog apps** in the portal.
_Bad:_ app only appears under the general Win32 apps list — it's a look-alike admin-uploaded package, not a catalog app; this runbook doesn't apply.

**3. Check catalog content readiness**
Portal: **Apps > Enterprise App Catalog apps** → select app → content status.
_Good:_ **Ready**.
_Bad:_ **"content is still being prepared"** persisting past ~1 hour.

**4. Confirm assignment type and auto-update state**
Portal: the app → **Properties > Assignments**.
_Good:_ Required assignment shown, with Auto-update toggle in the expected state for this app's intended behavior.
_Bad:_ Available assignment with an expectation of auto-update — auto-update never applies to Available.

**5. Confirm device-side IME processing (shared pipeline)**
```powershell
Get-Service -Name "IntuneManagementExtension" | Select Status, StartType
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 300 |
    Select-String -Pattern "EnterpriseAppCatalog|error|fail" -CaseSensitive:$false
```
_Good:_ service Running, log shows normal processing or a clear success line.
_Bad:_ service stopped, or log shows a generic Win32 failure — route to `App-Deployment-B.md`.

**6. Check for duplicate app objects targeting the same application**
```powershell
Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'<AppNamePrefix>')" | Select Id, DisplayName, "@odata.type"
```
_Good:_ exactly one app object per underlying application.
_Bad:_ two or more — one likely an EAC catalog app, one an admin-uploaded duplicate — a conflict source (Fix 4 in the B-file).

**7. Pull the Managed Apps report for device-level catalog app state**
Portal: **Reports > Apps > Managed Apps report** (or Graph device management reports API).
_Good:_ current version and install state consistent across the target device group, accounting for check-in timing.
_Bad:_ wide version skew with no recent check-in explanation — investigate device check-in health, not the catalog itself.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Confirm this is actually a catalog-app issue, not a generic Win32 issue

1. Run Validation Step 2 — confirm `@odata.type` and the portal's Enterprise App Catalog apps blade both agree this is a catalog app.
2. If it's not a catalog app, stop here and use `App-Deployment-A.md`/`-B.md` instead — nothing catalog-specific in this runbook applies.
3. If it is confirmed a catalog app, proceed to the phase matching the reported symptom below.

### Phase 2 — Content never becomes available ("still being prepared")

1. Note the time the app was added or the version last changed.
2. If less than 1 hour has passed, wait — this is within normal cache lag.
3. If several hours have passed with no change, there is no supported "force resync" action. Delete the app object and re-add it fresh from the catalog (Playbook 1).
4. Re-assign the group after re-adding — assignments are not preserved across delete/re-add.

### Phase 3 — Auto-update rolled out a bad version

1. Confirm via the Managed Apps report or local registry check which version is actually on affected devices (Symptom → Cause Map row 2).
2. Check whether Microsoft has already pulled the version as malicious (Intune admin center notification feed) — if so, new installs already stopped, but existing bad installs still need remediation.
3. Execute Playbook 2 (manual rollback via Uninstall intent or remediation script).
4. Disable auto-update on the app until the next version is independently verified.

### Phase 4 — Catalog app vanished / can't add new deployments

1. Confirm via **Apps > Enterprise App Catalog apps** whether the app still appears in the catalog search.
2. If it's gone and existing deployments still show installed/healthy, this is a vendor-removal event (Symptom → Cause Map row 3) — not a fault to fix, just a lifecycle change to plan around.
3. Execute Playbook 3 (transition plan for future deployments).

### Phase 5 — App fighting itself (dual deployment)

1. Run Validation Step 6 to enumerate all app objects for the underlying application.
2. Decide which deployment type should be authoritative (Playbook 4 walks the decision criteria).
3. Remove or disable the non-authoritative deployment's assignment.

### Phase 6 — ESP / Autopilot Device Prep blocking-app rejection

1. Confirm the app has auto-update enabled (Properties > Assignments).
2. This is the root cause in effectively all cases of this specific rejection — see Playbook 5 for the two valid resolutions.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Delete and re-add a stuck catalog app</summary>

```powershell
# 1. Capture the current assignment before deleting (assignments are not preserved)
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"
$app = Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<AppName>'"
Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.Id | Select TargetGroupId, Intent | Format-Table

# 2. Delete the stuck app object (do this in the portal: Apps > <AppName> > Delete —
#    Graph deletion of Enterprise App Catalog apps should be done via the same
#    Add/Remove flow the portal uses; confirm in a test tenant if scripting this at scale)

# 3. Re-add from Apps > Enterprise App Catalog apps > Add, selecting the same app/version

# 4. Re-apply the assignment captured in step 1

# 5. Force a device check-in to pick up the fresh app policy
$session = New-CimSession
Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DMClient -MethodName TriggerDMSession -Arguments @{ ProviderID = "MS DM Server" } -CimSession $session
```

**Rollback:** none needed — recovering a stuck app has no negative side effect on devices, since content never successfully deployed.

</details>

<details><summary>Playbook 2 — Manual rollback of a bad auto-update</summary>

```powershell
# Option A: force uninstall via Intune assignment (portal-driven — assign Uninstall intent to affected group)

# Option B: local remediation script pattern for Proactive Remediations
# Detection script (exit 1 if the bad version is present):
$badVersion = "<BadVersionString>"
$app = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" |
    Get-ItemProperty | Where-Object { $_.DisplayName -like "*<AppName>*" }
if ($app -and $app.DisplayVersion -eq $badVersion) { exit 1 } else { exit 0 }

# Remediation script (silently reinstall a known-good version from a separately packaged Win32 app,
# or run the vendor's own uninstaller/installer pair):
# & "<UninstallCommand>"
# & "<KnownGoodInstallerPath>" /S /silent
```

Then, in the portal: **Apps > Enterprise App Catalog apps > <App> > Properties > Assignments** — turn off auto-update until the next catalog version is independently confirmed stable.

**Rollback:** re-enabling auto-update simply resumes automatic updates; only do this once you trust the next version.

</details>

<details><summary>Playbook 3 — Transition plan when a catalog app is vendor-removed</summary>

1. Inventory current install base:
   ```powershell
   Get-MgDeviceManagementDetectedApp -Filter "displayName eq '<AppName>'" |
       Select DisplayName, Version, DeviceCount
   ```
2. Confirm with the client/vendor whether a direct-download or MSI/EXE installer is still available outside the catalog.
3. Package it as a standard Win32 app per `App-Deployment-A.md` Playbook 3 (`IntuneWinAppUtil.exe`) for any *future* deployments — existing installs need no action.
4. Update any documentation/runbooks referencing the app as an EAC catalog app, since new deployments will now follow the standard Win32 path.

**Rollback:** N/A — this is forward-looking migration guidance, not a reversible action.

</details>

<details><summary>Playbook 4 — Resolve a dual EAC + Win32 deployment conflict</summary>

```powershell
Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'<AppNamePrefix>')" | Select Id, DisplayName, "@odata.type"
```

Decision criteria for which deployment to keep authoritative:
- Need **auto-update convenience, no rollout rings**? → keep the EAC catalog app; remove the Win32 duplicate's assignment.
- Need **phased rollout rings, rollback capability, or a platform other than Windows**? → keep the admin-uploaded Win32 app; remove the EAC catalog app's assignment.

```powershell
# Remove assignment from the non-authoritative app object (portal-driven is safest;
# scripted removal via Graph requires DeviceAppManagementMobileAppAssignment delete calls
# and should be tested in a non-production tenant first)
```

**Rollback:** re-adding the removed assignment restores the dual-deployment conflict — don't, unless deliberately reverting.

</details>

<details><summary>Playbook 5 — Resolve ESP/Autopilot Device Prep blocking-app rejection</summary>

Pick one:

**Option A — Keep the app as a blocking app, give up auto-update:**
Portal: the app → Properties > Assignments → turn **off** auto-update. Manage version updates manually via guided update supersedence going forward.

**Option B — Keep auto-update, use a different app for the blocking-app role:**
Select a different (non-auto-update) catalog app or a traditional admin-packaged Win32 app for the ESP/DPP blocking-app slot, and leave the original app's auto-update enabled for its normal (non-blocking) deployment.

**Rollback:** switching back re-triggers the same restriction; no data risk in either direction.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collect Enterprise App Management diagnostic evidence (tenant + device-local).
.NOTES Run tenant-side portion anywhere with Microsoft Graph PowerShell + DeviceManagementApps.Read.All.
       Run device-local portion on the affected Windows device as Administrator.
#>
param(
    [string]$AppNameFilter = "*",
    [string]$OutputPath = "$env:TEMP\EAM-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# Tenant licensing
try {
    Connect-MgGraph -Scopes "Organization.Read.All","DeviceManagementApps.Read.All" -NoWelcome
    Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "INTUNE|EMS|SPE|EAM" } |
        Select SkuPartNumber, ConsumedUnits, @{N='Prepaid';E={$_.PrepaidUnits.Enabled}} |
        Export-Csv "$OutputPath\eam-licensing.csv" -NoTypeInformation

    # Matching app objects (catalog + look-alike Win32 duplicates)
    Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'$AppNameFilter')" -All |
        Select Id, DisplayName, "@odata.type", PublishingState, CreatedDateTime, LastModifiedDateTime |
        Export-Csv "$OutputPath\matching-app-objects.csv" -NoTypeInformation
} catch {
    "Graph collection failed: $($_.Exception.Message)" | Out-File "$OutputPath\graph-errors.txt"
}

# Device-local IME state (shared Win32 pipeline)
if (Get-Service -Name "IntuneManagementExtension" -ErrorAction SilentlyContinue) {
    Get-Service "IntuneManagementExtension" | Select * | Export-Csv "$OutputPath\ime-service.csv" -NoTypeInformation
    $logPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    if (Test-Path $logPath) { Get-Content $logPath -Tail 500 | Out-File "$OutputPath\ime-log.txt" }
    $agentLog = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log"
    if (Test-Path $agentLog) { Get-Content $agentLog -Tail 500 | Out-File "$OutputPath\agentexecutor-log.txt" }
}

# Installed apps for cross-reference
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" -ErrorAction SilentlyContinue |
    Get-ItemProperty | Select DisplayName, DisplayVersion, Publisher, InstallDate |
    Where-Object { $_.DisplayName -like $AppNameFilter } |
    Export-Csv "$OutputPath\installed-apps.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check EAM/Intune Suite licensing | `Get-MgSubscribedSku \| Where-Object SkuPartNumber -match "INTUNE\|EMS\|SPE"` |
| Confirm app is a catalog app | `Get-MgDeviceAppManagementMobileApp -Filter "displayName eq '<App>'" \| Select "@odata.type"` |
| Find duplicate/conflicting app objects | `Get-MgDeviceAppManagementMobileApp -Filter "startswith(displayName,'<Prefix>')"` |
| Check IME service (shared pipeline) | `Get-Service "IntuneManagementExtension"` |
| View IME log | `Get-Content "...\IntuneManagementExtension.log" -Tail 200 \| Select-String "EnterpriseAppCatalog\|error"` |
| Force device check-in | `Invoke-CimMethod -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DMClient -MethodName TriggerDMSession -Arguments @{ProviderID="MS DM Server"}` |
| Check installed version (registry) | `Get-ChildItem "HKLM:\SOFTWARE\...\Uninstall\" \| Get-ItemProperty \| Select DisplayName,DisplayVersion` |
| Pull detected-app device count | `Get-MgDeviceManagementDetectedApp -Filter "displayName eq '<App>'"` |
| Portal: catalog app content status | Apps > Enterprise App Catalog apps > *App* |
| Portal: apps with available updates | Apps > Enterprise App Catalog apps with updates |
| Portal: per-device catalog app state | Reports > Apps > Managed Apps report |

---
## 🎓 Learning Pointers

- **Everything device-side is shared with generic Win32 apps — the catalog only changes the authoring layer.** Don't build separate device-side mental models for "catalog app troubleshooting" vs. "Win32 app troubleshooting." Once content lands on the device, it's the exact same IME pipeline documented in `App-Deployment-A.md`. [Microsoft Intune Enterprise Application Management](https://learn.microsoft.com/en-us/intune/app-management/deployment/enterprise-app-management)

- **SLOs are targets, not guarantees — plan client expectations accordingly.** The 24-hour automated validation target and 7-day manual validation window are Microsoft's internal goals, explicitly documented as SLOs rather than contractual SLAs. Don't promise a client "the new browser version will always be in the catalog within a day."

- **Auto-update trades control for convenience — know which apps deserve that trade.** No rollback, no rings, no version history, and incompatibility with ESP/Autopilot blocking-app roles are permanent, documented properties of the feature, not gaps that will be patched. Reserve auto-update for low-risk, easily-tolerant apps (browsers, PDF readers) rather than line-of-business software where a bad version could halt work.

- **A vendor can pull their app from the catalog at any time, with no advance notice requirement documented.** The think-cell precedent shows this is a real operational risk, not theoretical. For business-critical apps sourced from the catalog, keep a fallback plan (a traditional Win32 package or direct vendor relationship) rather than treating catalog availability as permanent infrastructure.

- **Enterprise App Management is fully automatable via Microsoft Graph** — the same `deviceAppManagement/mobileApps` resource used for any Intune app, filtered by `@odata.type` to distinguish catalog apps from admin-uploaded ones. Useful for building tenant-wide catalog-app inventory/drift reports at MSP scale. [Working with Intune in Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/resources/intune-graph-overview)

- **Co-managed clients can still receive catalog apps without a full workload switch.** Only that specific app's deployment needs to originate from the Intune side — a useful, non-obvious option when a client is mid-migration from ConfigMgr and wants to pilot Enterprise App Catalog apps for one product line before committing further workloads. [Microsoft Intune Enterprise Application Management — FAQ](https://learn.microsoft.com/en-us/intune/app-management/deployment/enterprise-app-management#frequently-asked-questions-faq)
