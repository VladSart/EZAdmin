# Selective Response Actions — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Selective Response Actions** in Microsoft Defender for Endpoint — a capability that lets an organization onboard Tier-0 systems and other high-value assets (domain controllers, ADFS servers, and similar critical infrastructure) with a *restricted* set of cloud-initiated response actions, rather than the default full remote-response capability set. Source: Microsoft Learn, last updated 2026-06-15.

Assumes: a Microsoft Defender for Endpoint tenant with Windows devices being onboarded (or already onboarded) via the Defender deployment tool (DDT). Does **not** cover: general onboarding mechanics unrelated to restricted mode (see `MDE-Onboarding-A.md`/`-B.md`), standard response-action usage on a Full-mode device (see [Take response actions on a device](https://learn.microsoft.com/en-us/defender-endpoint/respond-machine-alerts)), or predictive shielding's autonomous hardening actions (a related but architecturally distinct capability — see `PredictiveShielding-A.md`).

**Why this exists:** deploying MDE onto Tier-0 assets creates a real tension. The whole value of MDE is its powerful remote response capability (isolate a device, run Live Response scripts, etc.) — but on a domain controller or ADFS server, that same remote-response power is itself an attack surface: a compromised cloud admin account or a stolen API token now has a path to remotely isolate, script against, or otherwise disrupt your most sensitive infrastructure. Organizations with strict privileged-access-management policies often want MDE's detection and protection on these assets without extending cloud-initiated administrative reach onto them. Selective Response Actions resolves this by making the response-action surface itself a configurable, onboarding-time decision.

---
## How It Works

<details><summary>Full architecture</summary>

Selective Response Actions is not a policy object pushed to a device after the fact — it's a property baked into the **onboarding package** itself, generated via the Defender deployment tool (DDT), and it becomes immutable for that device instance once onboarding completes.

**The two onboarding modes:**

- **Full functionality** (default) — every response action available to any user/API caller with the right RBAC permission.
- **Restricted functionality** — a curated onboarding package that disallows specific *categories* of high-impact response actions, chosen individually at package-generation time.

**The four capability categories:**

| Category | What it covers | Notes |
|---|---|---|
| Basic response | Run AV scan, collect file, collect investigation package | "Collect file" here means the **File** page portal action, distinct from the `GetFile` Live Response command |
| Advanced response | Isolate device, restrict app execution, request remediation | "Request remediation" initiates vulnerability-remediation requests, not malware remediation |
| Live response | Allows Live Response *sessions* to the device | Interactive session access — see the hard exception below |
| Device protection | Automated investigation and response (AIR), both auto-triggered and manually initiated | Governs whether AIR can act on this device at all |

**The hard, unconditional exception:** regardless of which categories are checked when generating a Restricted package, **Live Response script execution is always disabled** on a Restricted-mode device. Microsoft is explicit that this is enforced "by design to ensure script-based actions remain blocked" — and that "Restricted mode with all response actions allowed is **not** equivalent to full functionality" for exactly this reason. A Restricted package with every box checked still cannot run Live Response scripts; only a Full-functionality onboarding removes that specific block.

**Immutability by design:** once a device is onboarded, its security-operations configuration cannot be edited in place. The only way to change it — tighten or loosen — is to offboard the device and re-onboard it with a newly generated package reflecting the desired capability set. The device ID and all historical alert/timeline/investigation data survive this cycle unchanged; only the go-forward response-action capability set changes.

**What restriction does NOT affect:** detection, alerting, sensor coverage, and telemetry are completely unaffected by Restricted mode. This is a deliberate design boundary — Selective Response Actions constrains *remote administrative reach*, not *protective/detective capability*. A Restricted-mode device is exactly as visible to the SOC as a Full-mode one; it is only less remotely actionable.

</details>

---
## Dependency Stack

```
Layer 5:  Onboarding-time decision (immutable until offboard/re-onboard)
              ↑ requires
Layer 4:  Defender deployment tool (DDT) package generation with capability selection
              ↑ requires
Layer 3:  Tenant feature switch — Advanced features >
          "Allow restricted security operations during onboarding" (OFF by default)
              ↑ requires
Layer 2:  Prerequisite Sense sensor build (10.8798+) and, on most in-support OS
          versions, a specific 2025-era cumulative update installed BEFORE onboarding
              ↑ requires
Layer 1:  Base Microsoft Defender for Endpoint licensing + tenant enrollment
          (Plan 2 / Defender for Business — same baseline any MDE deployment needs)
```

Reading this stack top-down for troubleshooting: a symptom at Layer 5 (can't change an onboarded device's capabilities) is *always* resolved by going back through Layer 4 (generate a new package) — there is no shortcut that operates purely at Layer 5. A symptom at Layer 3 (Restricted option missing from the DDT UI) has nothing to do with Layers 1-2 being wrong; check the switch first.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Restricted" option absent from DDT package screen | Tenant feature switch is off | Settings > Endpoints > Advanced features |
| Device onboarding fails or silently produces a Full-mode device despite selecting Restricted | Sense build/KB prerequisite not met on the target OS at onboarding time | OS build + KB table in Learning Pointers |
| One response-action category fails for one device, others work fine | That specific category was unchecked at onboarding | Device Security Operations pane |
| Live Response session opens but no script will execute | Restricted-mode hard exception (unconditional, independent of category selection) | Device Security Operations pane — confirm Restricted |
| Can't find a way to loosen restrictions without downtime | Expected — no in-place edit exists | Remediation Playbook 1 |
| Detections/alerts seem degraded on a Restricted device | Misattribution — restriction never touches detection/alerting | Sensor health path (`MDE-Onboarding` runbook), not this topic |
| Automation/SOAR playbook silently fails a response action against a Tier-0 device | API-level enforcement of the same restriction; caller lacks visibility into device-level restriction state unless it checks first | `RestrictedDeviceSecurityOperations` via Advanced Hunting, or a pre-flight Graph read |

---
## Validation Steps

1. **Confirm tenant-level enablement.**
   ```
   security.microsoft.com > Settings > Endpoints > Advanced features
   > "Allow restricted security operations during onboarding" = On
   ```
   Expected good output: toggle shows enabled; DDT package screen subsequently offers Restricted as an option.
   Bad output: toggle off — Restricted will not appear as an onboarding choice anywhere, tenant-wide.

2. **Confirm OS/KB eligibility before generating a package for a specific asset class.**
   Cross-check the target OS build against the currently-documented KB/Sense-version floor (Learning Pointers has the full table) — this is a silent prerequisite with no dedicated onboarding-time error if unmet.

3. **Generate and inspect the package configuration screen** for the exact categories selected before distributing it — this is the only point where the capability set can be reviewed pre-deployment.

4. **Post-onboarding, confirm actual device state, not intended state:**
   ```
   Device inventory > device > Security operations column = Full or Restricted
   Device page > "Restricted security operations" tag present (if Restricted)
   Device page > View security operations information > per-category enabled/disabled
   ```

5. **Cross-validate via Advanced Hunting** (works even when portal state appears stale):
   ```kusto
   DeviceInfo
   | where DeviceId == "<deviceId>"
   | project Timestamp, DeviceName, RestrictedDeviceSecurityOperations
   | order by Timestamp desc
   | take 1
   ```

6. **Confirm API-level enforcement** by attempting a disallowed action programmatically and capturing the explicit error — the single strongest piece of evidence that restriction (not an unrelated RBAC/permission issue) is the actual blocker.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-onboarding planning**
- Identify the true Tier-0/HVA population first (domain controllers, ADFS servers, PKI issuing CAs, other assets where cloud-initiated remote action itself is the risk to manage) — Restricted mode is a deliberate tradeoff, not a default-safe setting to apply everywhere.
- Decide the capability set per asset class with the actual stakeholders (security ops needs AIR and basic response for detection value; PAM/identity teams may want Live Response and Advanced response withheld).

**Phase 2 — Package generation and distribution**
- Use short, descriptive, uniquely-named packages per asset class/cohort (e.g., `DC-Tier0-Restricted-2026Q3`) with the shortest reasonable expiration — long-lived packages sitting in a file share are a standing risk if leaked.
- Confirm the OS/KB prerequisite per target device before mass-distributing a package to avoid a partial-rollout mess of Full/Restricted-attempted-but-failed devices.

**Phase 3 — Post-onboarding verification**
- Reconcile actual onboarded state (Device inventory) against intended state (the package's configuration) for every device in the rollout batch — do not assume the package did what it says without checking at least a sample.

**Phase 4 — Ongoing operations**
- Any automation (SOAR, scheduled remediation scripts, Logic Apps calling the public API) targeting a mixed Full/Restricted device population needs to either pre-check `RestrictedDeviceSecurityOperations` or gracefully handle the explicit API rejection — a script written and tested only against Full-mode devices will fail unexpectedly the first time it targets a Restricted Tier-0 asset.

**Phase 5 — Change requests**
- Treat "loosen/tighten this device's restrictions" as a standard change requiring a maintenance window (offboard + re-onboard), not a live-fire portal click — see Remediation Playbook 1.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Reconfiguring an already-onboarded device's capability set</summary>

1. Determine the new target capability set and generate a fresh DDT package accordingly (new Restricted selection, or Full functionality).
2. Schedule a maintenance window for the target device(s) — this is a genuine service interruption to remote-response capability during the transition, and for Full→Restricted changes, a deliberate reduction in operational flexibility that stakeholders should sign off on for Tier-0 assets.
3. Offboard the device (standard MDE offboarding — portal or API/Graph).
4. Confirm offboarded state in Device inventory before proceeding (avoid a race where re-onboarding starts before offboarding fully propagates).
5. Re-onboard using the new package.
6. Verify final state via both the Device page tag and the `RestrictedDeviceSecurityOperations` Advanced Hunting property.
7. Confirm the device ID is unchanged and historical alert/incident/timeline data is intact — this should require no data-recovery action; if history appears missing, that's a separate, escalatable data-integrity issue, not an expected side effect of this procedure.

**Rollback:** the same procedure in reverse (new package, offboard, re-onboard) — there is no faster rollback path; budget for a second maintenance window if the change needs reverting.

</details>

<details><summary>Playbook 2 — Rolling out Selective Response Actions to a new Tier-0 cohort</summary>

1. Enable the tenant feature switch if not already on.
2. Classify the cohort by required capability set — don't assume every Tier-0 asset needs identical restrictions (e.g., an ADFS server the identity team actively remediates via Live Response scripts may need Live response left available, understanding the unconditional script-execution block still applies).
3. Verify Sense build/KB eligibility across the whole cohort before generating packages — flag any down-level devices for a prerequisite update pass first.
4. Generate one package per capability-set/cohort combination (not one universal package) to keep future re-onboarding cycles targeted.
5. Pilot on 1-2 non-production-critical Tier-0-equivalent devices first if available, confirming both the intended restriction behavior and that legitimate operational workflows (backup agents, monitoring tools that rely on Live Response for remote diagnostics, etc.) still function as expected.
6. Roll out to the full cohort, then run the Validation Steps section against a sample for confirmation.
7. Document the capability-set decision per asset class for future audit/change-management reference — since there's no portal-level historical log of *why* a given package was configured a certain way beyond the package name itself.

</details>

---
## Evidence Pack

```kusto
// Selective Response Actions — Evidence Pack
// Run in security.microsoft.com > Advanced hunting

// 1. Current restriction state for a specific device
DeviceInfo
| where DeviceId == "<deviceId>"
| project Timestamp, DeviceName, RestrictedDeviceSecurityOperations
| order by Timestamp desc
| take 1

// 2. Tenant-wide inventory of Restricted-mode devices (best-effort via DeviceInfo)
DeviceInfo
| where isnotempty(RestrictedDeviceSecurityOperations)
| summarize arg_max(Timestamp, RestrictedDeviceSecurityOperations) by DeviceId, DeviceName
| order by DeviceName asc
```

```powershell
# Local device-side supporting evidence (does not read the restriction state itself —
# there is no local registry/WMI surface documented for that; use Advanced Hunting or the
# portal for authoritative restriction state)
Get-Service Sense, WinDefend | Select-Object Name, Status, StartType
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name "SenseVersion" -EA SilentlyContinue
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Enable tenant feature switch | Portal: Settings > Endpoints > Advanced features > "Allow restricted security operations during onboarding" |
| Generate a Restricted onboarding package | Portal: System > Settings > Endpoints > Onboarding > Windows > Onboard > select **Restricted** |
| Check a device's current mode | Portal: Device inventory > device > **Security operations** column |
| Full per-category restriction detail | Portal: Device page > **View security operations information** |
| Query restriction state (KQL) | `DeviceInfo \| project RestrictedDeviceSecurityOperations` |
| Confirm Sense build | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name SenseVersion` |
| Offboard a device | Portal: Device page > **Offboard**, or Graph `POST /security/machines/{id}/offboard` |
| Change a device's capability set | Offboard → generate new package → re-onboard (no in-place edit) |
| Attempt an action to confirm restriction (diagnostic only) | Public API response-action call against the device — capture the explicit rejection error |

---
## 🎓 Learning Pointers

- Restricted mode is an **onboarding-time, immutable** decision. The single most common operational mistake is expecting a portal toggle to change it later — plan the capability set deliberately before generating a package for a Tier-0 cohort. [Restrict response actions on high-value assets](https://learn.microsoft.com/en-us/defender-endpoint/restrict-response-actions-high-value-assets)
- Live Response **script execution is unconditionally blocked** in Restricted mode — checking every capability box does not restore it. Microsoft states plainly that "Restricted mode with all response actions allowed is not equivalent to full functionality."
- The **prerequisite Sense build (10.8798+) and OS-specific KB** are silent gates — an onboarding attempt against a down-level device does not fail with an obvious "unsupported" error in this feature's own flow. Verify the current KB table on the live Learn page before rollout, since KB numbers roll forward over time.
- Restriction is enforced **at both the sensor and the public API layer** — any SOAR/automation targeting a mixed device population should pre-check `RestrictedDeviceSecurityOperations` via Advanced Hunting rather than assuming uniform Full-mode behavior across the fleet.
- Restricted mode has **zero effect on detection, alerting, or sensor telemetry** — this is a response-action-surface control only. Don't reach for this runbook when investigating a genuine detection gap; that's a sensor-health issue (see `MDE-Onboarding-A.md`).
- This is a distinct control surface from **Predictive Shielding** (`PredictiveShielding-A.md`), which autonomously *decides when Defender itself takes a hardening action* rather than *what a human/API caller is permitted to trigger*. The two can coexist on the same Tier-0 device and address different risk models — don't conflate them when scoping a Tier-0 protection strategy.
