# Windows Update Maintenance Window (Preview) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers the **Maintenance Window** setting for OS, driver, and quality/feature updates — a Windows Update Policy CSP feature currently marked **Windows Insider Preview** in Microsoft's own [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) reference, with no native Intune Settings Catalog friendly UI as of this writing. It defines a strict, scheduled window during which specific update actions (download, install, restart) are permitted to run — a fundamentally different control model from the long-established Active hours/Update rings mechanism.

Assumes: cloud-managed Windows devices enrolled in Intune, targeting Windows 11 (24H2 Insider Preview builds onward for initial policy-definition support; functionally confirmed working on 25H2 with the February 2026 cumulative update in independent lab testing as of this writing). Does **not** cover: the established, GA Update rings Active hours/deferral/deadline model (see `WUfB-A.md`/`FeatureUpdates-A.md`) except by contrast; Autopatch's own scheduling/deployment-ring model (see `Autopatch-A.md`), which operates at a different layer and is not directly modified by this feature; Configuration Manager (SCCM/MECM) maintenance windows, an unrelated, long-standing, separately-implemented concept in that product despite the similar name.

**Source-confidence note:** the technical mechanics in this runbook — CSP node names, the `MoUsoCoreWorker.exe`/`GetAndValidateMaintenanceWindowConfiguration` processing flow, the enterprise-policy-ID-to-recurrence-type mapping (1=none, 2=daily, 3=weekly, 4=monthly), and the server-side feature-flighting gate (`Feature_Containment_UUS_Feature_MaintenanceWindow_*`) — are sourced primarily from independent reverse-engineering and lab-testing reporting (Patch My PC's technical blog, last updated 2026-06-25), cross-referenced against Microsoft's own CSP reference page confirming the `MaintenanceWindowEnabled` node's existence. This is **not yet** backed by a full Microsoft Learn conceptual/how-to article at the time of writing. Treat implementation-level detail here as accurate as of the source's last-verified date and re-confirm against official Microsoft documentation as this feature matures toward GA — an actively-flighted Preview feature is one of the faster-moving topics in this repository.

---
## How It Works

<details><summary>Full architecture</summary>

**The core distinction — window of permission vs. suppression of disruption:**

- **Active hours** (established, GA): a *defensive* setting. It tells Windows "don't restart the device during these hours" but does nothing to constrain *when downloads or installs* happen — those can and do proceed at any time outside a deadline/grace-period constraint.
- **Maintenance Window** (this topic, Preview): a *permissive-exclusive* setting. It tells Windows "update work — potentially including download and install, not just restart — is **only** allowed to run inside this window," full stop. Outside the window, the governed actions simply do not execute, regardless of deadlines elsewhere in Update ring policy (see the interaction caveat in Troubleshooting Steps, Phase 3).

This makes Maintenance Window a fundamentally different scheduling primitive, not a rebrand or extension of Active hours — it is designed for scenarios where Active hours' softer "avoid disruption" model is insufficient: shared/kiosk devices, frontline endpoints, and any cloud-managed fleet where update timing needs to be deterministic rather than merely non-disruptive.

**How the policy reaches the device and takes effect — the four-stage discovery chain (reconstructed from independent reverse-engineering, not an official architecture diagram):**

1. **Policy definition (ADMX layer):** the `Maintenance Window` policy first appeared in `WindowsUpdate.admx`, backed by a `Maintenance Window Enabled` value, marked supported for Windows 11 24H2 Insider Preview builds, and explicitly scoped to control update **actions** (download, install, restart) rather than being a cosmetic toggle.

2. **MDM/WMI bridge (MOF layer):** the same setting is projected through the WMI bridge MOF definitions used to expose MDM-backed settings into WMI — confirming this was built as a modern-management-surface feature from the start, not a legacy Group Policy-only addition later retrofitted for MDM.

3. **CSP layer:** the [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) exposes the full settings family: enable/disable, start date/time, duration, repeat schedule (none/daily/weekly/monthly), and which update actions the window governs. This is the layer Intune's eventual native UI will configure, and the layer a custom Settings Catalog/OMA-URI profile targets today.

4. **Runtime processing (MoUsoCoreWorker.exe):** on the device, `MoUsoCoreWorker.exe`'s `GetAndValidateMaintenanceWindowConfiguration` function reads the policy at update-activity time (scheduled scan or manual "Check for updates"). It first checks a server-side feature-flighting gate (`Feature_Containment_UUS_Feature_MaintenanceWindow_*`, a Known-Issue-Rollback-style mechanism) via `Windows::GetEnterprisePolicy` — if this returns not-enabled, the function falls back to pre-existing (non-Maintenance-Window) update behavior regardless of what the CSP policy says. If enabled, it reads the governed-actions set via `Windows::Policy::GetMaintenanceWindowGovernedActions`, then the recurrence type via enterprise policy ID 70 (1=none, 2=daily, 3=weekly, 4=monthly), and dispatches to one of four generator functions (`GenerateNoRepeatConfiguration`/`GenerateDailyConfiguration`/`GenerateWeeklyConfiguration`/`GenerateMonthlyConfiguration`) that compute the actual next start/end time from the current clock and the configured schedule.

**The critical operational implication:** stage 4's feature-flighting check sits *above* your policy in the effective decision chain. A device can have a perfectly well-formed, successfully-delivered MDM policy and still exhibit zero observable behavior change, because Microsoft has not (yet) enabled the underlying feature for that build/ring/region via server-side flighting. This is architecturally similar to other Windows Known Issue Rollback mechanisms, but inverted in effect: KIR typically *disables* a problematic change; this flighting gate *withholds* a not-yet-fully-rolled-out feature. Either way, the practical lesson for an admin is the same — a "Succeeded" status in Intune confirms policy *delivery*, not feature *activation*.

</details>

---
## Dependency Stack

```
Layer 5:  Runtime execution — MoUsoCoreWorker.exe evaluates the calculated window
          against current time when update activity begins (scheduled scan or
          manual check); governed actions proceed only inside the window
              ↑ requires
Layer 4:  Policy processing — GetAndValidateMaintenanceWindowConfiguration computes
          next start/end time from recurrence type + start date/time + duration
              ↑ requires
Layer 3:  Server-side feature-flighting gate — Feature_Containment_UUS_Feature_
          MaintenanceWindow_* must be enabled for this build/ring by Microsoft;
          entirely outside admin control, no local override
              ↑ requires
Layer 2:  CSP delivery — Update Policy CSP MaintenanceWindow* nodes successfully
          pushed via MDM (custom Settings Catalog / OMA-URI profile, since no
          native friendly UI exists yet) and landed in the device's
          PolicyManager registry hive
              ↑ requires
Layer 1:  Device eligibility — Windows 11 build supporting the underlying feature
          (24H2 Insider Preview onward for policy acceptance; 25H2 + Feb 2026 CU
          confirmed functionally working in independent testing as of this writing)
```

Reading this stack for triage: a symptom sitting at Layer 5 (wrong-time execution) is diagnosed by walking *down* the stack, not by re-tuning Layer 5 settings — most real-world "it's not working" tickets resolve to a Layer 3 gate (outside admin control, documented and accepted as a current limitation) or a Layer 1 build-eligibility gap, not a Layer 2 configuration mistake.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Policy shows "Succeeded" in Intune, zero behavior change on device | Layer 3 feature-flighting gate not enabled for this build/ring | Cannot be confirmed locally; treat as current limitation |
| Policy doesn't apply / registry values absent despite assignment | Layer 2 delivery failure — custom profile misconfigured, or device below Layer 1 build floor | PolicyManager registry hive, device build |
| Governed action (e.g., restart) happens outside the configured window | Governed-actions set may not include the action that occurred, or a competing Update ring deadline forced it regardless (see Troubleshooting Phase 3 interaction caveat) | Governed actions config, Update ring deadline settings |
| Weekly/monthly recurrence not repeating as expected | Enterprise policy ID 70 mapping misconfigured, or duration too short to complete the cycle | Recurrence value, duration value |
| No Settings Catalog UI entry found for this setting | Expected — no native UI exists yet | Use custom Settings Catalog/OMA-URI targeting raw CSP paths |
| Confusion between this and Active hours | Different settings families entirely — Active hours suppresses restarts only; Maintenance Window gates all governed actions | `WUfB-A.md` for Active hours' actual scope |
| Confusion between this and SCCM/MECM "maintenance windows" | Unrelated feature in an unrelated product despite the shared name | N/A — different product entirely |

---
## Validation Steps

1. **Confirm device build eligibility.**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
       Select-Object DisplayVersion, CurrentBuildNumber, UBR
   ```
   Compare against the current confirmed-working floor — re-verify this floor against live sources rather than trusting a static number, since this is an actively-shipping Preview feature.

2. **Confirm CSP delivery to the device.**
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\<EnrollmentGUID>\default\Update" -EA SilentlyContinue
   ```
   Expected good output: `MaintenanceWindowEnabled` and related values matching the assigned custom profile. Absence here despite an assigned/succeeded profile in Intune indicates a Layer 2 delivery or parsing issue, not a Layer 3 flighting issue.

3. **Confirm effective (current) policy state**, distinct from the raw MDM delivery path:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -EA SilentlyContinue |
       Select-Object *MaintenanceWindow*
   ```

4. **Look for runtime evidence of window calculation**, confirming Layer 4/5 activity rather than just policy presence:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 100 -EA SilentlyContinue |
       Where-Object { $_.Message -match "[Mm]aintenance [Ww]indow" } |
       Select-Object TimeCreated, Id, Message
   ```
   Presence of window-calculation log entries is strong evidence the Layer 3 gate is enabled for this device; complete absence over multiple update cycles, despite correct Layer 1/2 state, is the strongest indirect evidence the gate is not yet enabled here.

5. **Cross-check against a known good/bad reference device** if available (e.g., a lab device on a confirmed-working build/ring) — since there is no direct, supported way to query Layer 3 gate state, differential testing against a device known to work is currently the most reliable diagnostic technique for this specific layer.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Eligibility and delivery verification**
- Confirm build floor and CSP delivery (Validation Steps 1-3) before assuming any behavioral symptom is a configuration problem.
- For a custom Settings Catalog/OMA-URI profile, double-check exact node paths against the current live CSP reference — as an actively-evolving Preview CSP, node paths and value semantics are more likely to shift release-over-release than a stable, GA CSP.

**Phase 2 — Runtime confirmation**
- Use the event-log evidence check (Validation Step 4) across at least one full expected cycle (a full day for a daily recurrence, a full week for weekly) before concluding the feature is inactive — a single missed check isn't conclusive.

**Phase 3 — Interaction with existing Update ring policy (important, currently under-documented)**
- Maintenance Window and Update ring deadlines are not confirmed by Microsoft to have a single, definitively-documented precedence order as of this writing. The safest operational assumption, pending clearer official documentation, is that **Update ring deadlines can still force an install/restart outside a configured Maintenance Window** once the deadline/grace-period is fully exhausted — treat Maintenance Window as an additional, narrower constraint layered on top of the existing deadline model, not a hard override of it. Test this interaction explicitly in a pilot ring before assuming otherwise.
- Document any empirically-observed precedence behavior found during pilot testing, since this is a genuine, currently-open documentation gap rather than a settled fact this runbook can assert with confidence.

**Phase 4 — Rollout discipline for a Preview feature**
- Given the server-side flighting gate (Layer 3) is entirely outside admin control, do not commit to a broad rollout timeline for this feature — pilot continuously and be prepared for the feature's effective behavior to change without a corresponding change on the admin side, purely because Microsoft adjusted flighting.
- Retire any custom OMA-URI profile in favor of the native Settings Catalog UI once it ships, to reduce long-term maintenance overhead and reduce risk from raw-CSP-path drift.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Piloting Maintenance Window on a kiosk/shared-device cohort</summary>

1. Confirm the pilot cohort meets the current build floor; upgrade first if not.
2. Build a custom Settings Catalog (or OMA-URI, if the friendly catalog entries aren't yet present in your tenant) profile targeting the `Update/MaintenanceWindow*` CSP family: enable, start date/time, duration, recurrence type, governed actions.
3. Assign to a small pilot group only — this is explicitly Preview/experimental as of this writing.
4. Run the full Validation Steps sequence across at least one full recurrence cycle.
5. Explicitly test the Phase 3 interaction question: configure a due update with an approaching Update ring deadline that falls *outside* the Maintenance Window, and observe whether the device waits for the next window or is forced by the deadline — document the actual observed behavior for your environment/build combination rather than assuming.
6. Only expand beyond pilot once both the feature-flighting gate is confirmed active (via consistent event-log evidence) and the deadline-interaction behavior is understood and acceptable for the target use case.

</details>

<details><summary>Playbook 2 — Diagnosing a "policy applied, nothing happened" report</summary>

1. Walk the Dependency Stack top-down is tempting but inefficient here — walk it **bottom-up** instead: confirm Layer 1 (build), then Layer 2 (delivery), then look for Layer 4/5 runtime evidence (Validation Step 4).
2. If Layers 1-2 check out and Layer 4/5 evidence is absent across a full cycle, document this as a suspected Layer 3 flighting gate and stop local troubleshooting — there is no supported diagnostic to confirm Layer 3 state directly, and further local investigation will not resolve it.
3. If a fix is business-critical, fall back to Active hours + Update ring deadlines (the established, GA mechanism) for that specific device/cohort rather than continuing to chase a Preview feature's server-side state.

</details>

---
## Evidence Pack

```powershell
# Windows Update Maintenance Window — Evidence Pack (run locally on the device)

$evidence = [PSCustomObject]@{
    ComputerName          = $env:COMPUTERNAME
    DisplayVersion        = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
    CurrentBuildNumber    = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
    UBR                   = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
    EffectivePolicyValues = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" -EA SilentlyContinue |
                                Select-Object *MaintenanceWindow*
    RecentMWEventLogHits  = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 200 -EA SilentlyContinue |
                                Where-Object { $_.Message -match "[Mm]aintenance [Ww]indow" } |
                                Select-Object TimeCreated, Id, Message
}

$evidence | ConvertTo-Json -Depth 5 | Out-File "$env:TEMP\MaintenanceWindow-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$evidence
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Confirm build eligibility | `Get-ItemProperty "HKLM:\...\CurrentVersion" \| Select DisplayVersion,CurrentBuildNumber,UBR` |
| Confirm MDM delivery (raw provider path) | `HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\<GUID>\default\Update` |
| Confirm effective policy state | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update` |
| Runtime evidence (window calculation) | `Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational"` filtered for "Maintenance Window" |
| Build a custom profile | Intune > Devices > Configuration > Settings catalog (search for the setting) or OMA-URI targeting `./Vendor/MSFT/Policy/Config/Update/MaintenanceWindow*` |
| Official CSP reference | [Update Policy CSP — MaintenanceWindowEnabled](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled) |
| Compare against Active hours (established mechanism) | `Get-ItemProperty ... \| Select *ActiveHours*` — see `WUfB-A.md` |

---
## 🎓 Learning Pointers

- This is a genuinely **Preview, still-flighting** feature — the single most important operational discipline is not committing production timelines around it, since a server-side gate entirely outside admin control determines whether a correctly-delivered policy has any actual effect. [Update Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#maintenancewindowenabled)
- **Maintenance Window and Active hours solve different problems and are not interchangeable.** Active hours is defensive/restart-only; Maintenance Window is a strict, exclusive window potentially governing download and install as well as restart. Pick the mechanism that matches the actual requirement.
- The **interaction between Maintenance Window and existing Update ring deadlines is not yet clearly documented by Microsoft** — this runbook's Phase 3 guidance (deadlines likely still force action outside the window once exhausted) is a reasoned operational assumption pending clearer official documentation, not a confirmed architectural guarantee. Pilot-test this explicitly for your environment.
- Much of this feature's implementation detail comes from independent reverse-engineering (Patch My PC, last verified 2026-06-25) rather than a mature Microsoft Learn conceptual article — treat CSP node names and behavior as subject to change, and re-verify against the live CSP reference before broad deployment.
- Don't confuse this feature with **Configuration Manager (SCCM/MECM) maintenance windows** — same name, unrelated implementation, unrelated product, no shared configuration surface.
- Watch for this feature's eventual native Settings Catalog UI and official conceptual documentation as signals it's approaching GA — retire any custom OMA-URI profile built today in favor of the native experience once available, to reduce long-term drift risk from hand-maintained raw CSP paths.
