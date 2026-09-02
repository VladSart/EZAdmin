# Windows Update Maintenance Window (Preview) — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** the Maintenance Window Update Policy CSP is a **strict, hard-defined window for when update work (download/install/restart) is allowed to run** — a fundamentally different model from **Active hours**, which only suppresses restarts and does nothing to gate download/install timing. As of this writing, Microsoft's own [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) reference still marks the `MaintenanceWindow*` node family **Windows Insider Preview**, and there is **no native, friendly Intune Settings Catalog wizard for it yet** — it can currently only be deployed as a **custom Settings Catalog / OMA-URI profile** targeting the raw CSP nodes directly. Treat this as an experimental, test-first capability, not a GA feature to roll out broadly. The #1 triage mistake is confusing this with the long-standing **Active hours** setting in Update rings — they are different CSP families, control different things, and a ticket describing "updates installing at the wrong time" needs you to identify which one is actually in play before troubleshooting either.

Run these first, in this order:

```powershell
# 1 — Confirm which mechanism is actually configured on the device: Maintenance Window (new) vs
#     Active hours / Update rings (established). Check both registry locations.
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -EA SilentlyContinue |
    Select-Object *MaintenanceWindow*, *ActiveHours*

# 2 — Confirm the device build/servicing level is one where Maintenance Window has actually been
#     observed functioning (Windows 11 25H2 + Feb 2026 CU / KB5077212 / build 26200.7781, or later;
#     earlier builds may accept the policy but not act on it)
[System.Environment]::OSVersion.Version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" | Select-Object DisplayVersion, CurrentBuildNumber, UBR

# 3 — Confirm the policy actually landed via MDM (not just attempted)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\<EnrollmentGUID>\default\Update" -EA SilentlyContinue

# 4 — Check for MoUsoCoreWorker activity referencing the maintenance window at the next expected run
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 50 -EA SilentlyContinue |
    Where-Object { $_.Message -match "[Mm]aintenance [Ww]indow" }
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| Policy pushed, portal shows "Succeeded," but updates still install/restart outside the configured window | Server-side feature flighting gate (Known Issue Rollback-style flag) may not be enabled for this device — the feature can be silently OFF regardless of a correctly-applied policy | Fix 1 |
| Device is on a build below the confirmed-working floor | Feature not functionally present on this servicing level even if the CSP accepts the value | Fix 2 |
| Updates never install at all, even inside the configured window | Confusing Maintenance Window (governs *when allowed*) with deadlines/deferral (governs *whether due yet*) — both must be satisfied | Fix 3 |
| Admin expected Active hours behavior (no forced restart during work hours) but got a hard install/restart window instead | Wrong policy family used for the intent — Maintenance Window is not a drop-in replacement for Active hours | Fix 4 |
| No Settings Catalog UI entry visible for "Maintenance Window" | Expected — no native friendly UI exists yet; must be built as a custom profile against the raw CSP | Fix 5 |
| Recurrence (weekly/monthly) not behaving as expected | Enterprise policy ID mapping for recurrence type may be misconfigured (1=none, 2=daily, 3=weekly, 4=monthly, per current CSP behavior) | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for a Maintenance Window to actually govern update behavior</summary>

```
[Device on a build where the underlying feature is functionally present]
    │   (confirmed observed on Windows 11 25H2 + Feb 2026 CU / KB5077212 / build 26200.7781+;
    │    earlier Insider Preview builds may also work — verify per-build, don't assume)
    └── [Server-side feature flag enabled: Feature_Containment_UUS_Feature_MaintenanceWindow_*]
            │   (a Known-Issue-Rollback-style flighting gate — Microsoft controls this
            │    independently of whether your policy is correctly configured and applied)
            └── [Update Policy CSP: MaintenanceWindowEnabled = true, pushed via MDM]
                    └── [Start date/time, duration, recurrence type, and governed
                         update actions (download/install/restart) all configured]
                            └── [MoUsoCoreWorker.exe reads policy via
                                 GetAndValidateMaintenanceWindowConfiguration,
                                 calculates the next actual start/end time]
                                    └── [Update activity (scheduled scan or manual
                                         "Check for updates") only proceeds for the
                                         GOVERNED actions if current time falls inside
                                         the calculated window]
```

**Key fact:** a correctly-applied policy is necessary but not sufficient. The feature-flighting gate sits *above* your policy in this chain — if Microsoft hasn't enabled the underlying feature for that build/ring, your policy can show "Succeeded" in Intune while doing nothing on the device. This is the single most likely explanation for "I configured it and nothing changed."

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which policy family is actually in play.**
   `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update` — look for `MaintenanceWindow*` values distinct from `ActiveHoursStart`/`ActiveHoursEnd`. A ticket may describe symptoms that sound like one but are actually caused by the other.

2. **Confirm the build/servicing level.**
   `DisplayVersion`/`CurrentBuildNumber`/`UBR` — cross-reference against the current confirmed-working floor (25H2 + Feb 2026 CU as of this writing) before assuming a correctly-pushed policy should be having any effect at all.

3. **Confirm the MDM policy actually applied**, not just that a profile was assigned in Intune:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\<EnrollmentGUID>\default\Update" -EA SilentlyContinue
   ```
   Expected: values matching what was configured in the custom Settings Catalog/OMA-URI profile. Missing values here (even though Intune shows "Succeeded") point to a CSP-processing issue on the device, not a delivery issue.

4. **Check for MoUsoCoreWorker evidence of the calculated window.**
   `Microsoft-Windows-WindowsUpdateClient/Operational` log, filtered for maintenance-window-related entries — confirms Windows itself computed a next start/end time, not just that the policy value exists in the registry.

5. **If policy is present and correctly formed but nothing happens at the expected time:** this is the server-side feature-flag scenario (Fix 1) — there is no local diagnostic that can confirm or deny the flighting gate's state; it must be treated as a known current-limitation escalation, not chased further locally.

---
## Common Fix Paths

<details><summary>Fix 1 — Policy applied correctly but no observable effect (suspected feature-flighting gate)</summary>

1. Confirm build/servicing level is at or above the confirmed-working floor (Fix 2 first, if not already checked).
2. Confirm the MDM-side registry values are actually present and correctly formed (Diagnosis step 3) — rule out a delivery/parsing issue before assuming it's the flighting gate.
3. If both check out and the feature still shows no effect: **this is a known current limitation, not a misconfiguration.** The feature is explicitly still Preview-flagged in Microsoft's own documentation as of this writing, and its server-side enablement is outside admin control.
4. Do not attempt registry-level workarounds to force the feature flag (`Feature_Containment_UUS_Feature_MaintenanceWindow_*`) — this is an internal Windows feature-flighting mechanism, not a supported configuration surface, and altering it directly is unsupported and may produce unpredictable update behavior.
5. Fall back to Active hours + Update rings deadlines (the established, fully-supported mechanism) for any environment that needs guaranteed behavior today — treat Maintenance Window as pilot-only until it reaches GA.

</details>

<details><summary>Fix 2 — Device is below the confirmed-working build floor</summary>

1. Confirm current build against the floor observed as of this writing: Windows 11 25H2 with the February 2026 cumulative update (KB5077212, OS build 26200.7781) or later. Earlier builds — including Windows 11 24H2 Insider Preview builds where the ADMX policy first appeared — may accept the policy without functionally acting on it, or may not accept it at all.
2. This is not a supported-vs-unsupported OS-version question in the usual sense (see `FeatureUpdates-A.md`/`WUfB-A.md` for that) — it's specifically about whether *this* Preview feature has reached a given build, which changes over time as Microsoft ships it more broadly.
3. Re-verify the current floor against the live [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) page and recent community reporting before treating any specific build number as permanent — this is a fast-moving Preview feature.
4. If the device is below the floor and the business need is real and immediate, do not attempt to force-enable via unsupported registry edits — pilot-upgrade the device to a qualifying build first.

</details>

<details><summary>Fix 3 — Updates never install even inside the configured window</summary>

1. Maintenance Window governs **when update actions are *allowed* to run** — it does not by itself make an update *due*. Confirm the update is actually within its deferral/deadline window per the assigned Update ring policy (`FeatureUpdates-A.md`/`WUfB-A.md`) — a Maintenance Window with no due update inside it will correctly do nothing.
2. Confirm the Maintenance Window's **governed actions** setting actually includes the action you expect (download, install, restart can each be independently governed) — a window that only governs "restart" will not gate download/install timing.
3. Confirm the calculated next window (via the Diagnosis flow's event-log check) is actually in the future relative to when you're checking, not a window that already passed for this cycle.

</details>

<details><summary>Fix 4 — Wrong policy family used for the intended outcome</summary>

1. If the actual goal is "don't restart devices during working hours" (a soft, restart-only concern), **use Active hours in an Update ring policy** — this is the established, fully-supported, GA mechanism and remains the right tool for that specific job.
2. Use Maintenance Window only when the requirement is a **hard, exclusive window** for update work — e.g., a kiosk or frontline device that must only ever service during a fixed off-hours slot, and must NOT download/install/restart at any other time regardless of deadlines.
3. Document which mechanism is in use per device group — mixing both on the same device without understanding their interaction (Fix 3) is the most likely source of confusing, hard-to-reproduce ticket patterns.

</details>

<details><summary>Fix 5 — No Settings Catalog UI entry for "Maintenance Window"</summary>

1. This is expected as of this writing — no native, friendly Intune UI wizard exists yet for this policy family.
2. Build a custom **Settings Catalog** profile (Devices > Configuration > Create > New Policy > Windows 10 and later > Settings catalog) and search for the raw CSP setting names if they appear in your tenant's catalog, or use an **OMA-URI custom profile** targeting `./Vendor/MSFT/Policy/Config/Update/MaintenanceWindow*` paths directly if the friendly catalog entries are not yet present in your tenant.
3. Re-check periodically — Microsoft is actively rolling the friendly UI out; a manual OMA-URI approach built today may become unnecessary (and should be retired in favor of the native UI) once it ships.

</details>

<details><summary>Fix 6 — Recurrence not behaving as expected</summary>

1. Confirm the recurrence-type value maps correctly: **1 = no repeat, 2 = daily, 3 = weekly, 4 = monthly**, per the current CSP implementation observed as of this writing.
2. Confirm start date/time and duration are both set consistently with the intended recurrence — an incorrectly-scoped duration can cause a weekly window to appear to "not repeat" if it never completes within its allotted time.
3. Re-verify this mapping against the live CSP documentation before deploying broadly — as an actively-evolving Preview feature, value mappings are more likely to change here than in a GA CSP.

</details>

---
## Escalation Evidence

```
MAINTENANCE WINDOW (PREVIEW) — ESCALATION TEMPLATE
============================================
Tenant:                       <tenant name/ID>
Device(s) affected:           <device name(s)>
OS build / UBR:                <DisplayVersion / CurrentBuildNumber / UBR>
Profile type used:            <custom Settings Catalog / OMA-URI>
MaintenanceWindowEnabled:      <confirmed true/false via registry>
Governed actions configured:   <download / install / restart — which>
Recurrence configured:         <none / daily / weekly / monthly>
MDM policy landed on device:   <confirmed present in PolicyManager providers path — Y/N>
MoUsoCoreWorker event evidence: <paste relevant Windows Update Client Operational log entries>
Expected vs actual behavior:   <what should have happened vs what did>
Suspected cause:               <feature-flighting gate / build floor / policy conflict / other>
```

---
## 🎓 Learning Pointers

- This is an **Insider Preview-flagged CSP feature** as of this writing, with no native Intune Settings Catalog UI yet — treat any deployment as pilot/test-only, not a production-ready mechanism, and re-verify status against the live [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) page before broader rollout.
- **Maintenance Window is not "Active hours with a new name."** Active hours only suppresses restarts; Maintenance Window is a strict window governing when download/install/restart *are allowed to happen at all*. Choosing the wrong one for the intended outcome is the most common design mistake.
- The feature sits behind a server-side, Known-Issue-Rollback-style feature flag (`Feature_Containment_UUS_Feature_MaintenanceWindow_*`) that Microsoft controls independently of your policy — a correctly-applied policy showing "Succeeded" in Intune does not guarantee the underlying behavior is actually active on that build/ring.
- The confirmed-working build floor (25H2 + February 2026 CU / KB5077212 / build 26200.7781, per independent lab testing as of this writing) is a moving target for an actively-shipping Preview feature — don't treat any specific build number found in this runbook as a permanent fact; re-verify against current community/Microsoft reporting.
- This topic's technical detail (CSP node behavior, `MoUsoCoreWorker.exe`'s `GetAndValidateMaintenanceWindowConfiguration` processing, the enterprise-policy-ID recurrence mapping) is sourced from independent reverse-engineering/lab-testing reporting (Patch My PC's technical blog), not yet from a fully-fleshed-out Microsoft Learn conceptual article — corroborate against Microsoft's own CSP reference and watch for an official conceptual doc/Tech Community announcement as this feature matures toward GA.
- See `FeatureUpdates-A.md`/`WUfB-A.md` for the established, GA Update rings/deadlines/Active hours mechanism this feature supplements rather than replaces.
