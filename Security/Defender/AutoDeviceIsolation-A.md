# Automatic Device Isolation (Attack Disruption, Preview) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from a live fetch of Microsoft's own [Take response actions on a device](https://learn.microsoft.com/en-us/defender-endpoint/respond-machine-alerts) page (`ms.date` 2026-07-23, `updated_at` 2026-08-25), specifically the "Isolate device - automatic attack disruption (Preview)" section, plus the parent "Isolate devices from the network" section it extends. The page itself carries Microsoft's standard prerelease-product disclaimer. Cross-referenced against community reporting (Bleeping Computer, 4sysops, IT-Connect) confirming the feature shipped in Microsoft's May 2026 Defender for Endpoint update — treat exact undo-window timing and rollout scope as subject to change and verify per tenant.

---
## Skim Index (with jump links)
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

This runbook covers the **automatic** trigger path of MDE's "Isolate device" response action — i.e. Defender XDR itself deciding to isolate a device as part of [automatic attack disruption](https://learn.microsoft.com/en-us/defender-xdr/automatic-attack-disruption), currently in Preview. It does **not** cover manually-initiated isolation (same mechanism, human-triggered, long GA — see the base "Isolate devices from the network" section of the same Learn page), nor does it cover the sibling automatic containment actions that operate on different entity types:

| Action | Entity | Mechanism | Where documented |
|---|---|---|---|
| **Isolate device** (this topic) | Onboarded end-user workstation | Full network disconnect, MDE cloud channel retained | This file |
| Contain critical assets | Domain controllers, DNS/DHCP servers | Port/direction-level blocking, keeps asset running | Base Learn page, "Contain critical assets" |
| Contain devices | Unmanaged/undiscovered devices | All onboarded devices block traffic to/from it | Base Learn page, "Contain devices from the network" |
| Contain IP addresses | IPs of undiscovered devices | Onboarded devices block the IP | Base Learn page, "Contain IP addresses" |
| Contain user | Compromised identity | Endpoint-layer auth/session blocking, not IdP disable | Base Learn page, "Contain a user" |
| GPO/SafeBoot Hardening, Contain User (predictive) | Predicted future targets | Proactive, pre-compromise | `PredictiveShielding-A.md` |

Requires Defender for Endpoint Plan 2 (or Defender for Business); assumes at least Semi automation level configured on the relevant device group (see `AIR-A.md` for the automation-level model this shares).

---
## How It Works

<details><summary>Full architecture</summary>

Automatic attack disruption is Defender XDR's cross-signal correlation engine — it ingests evidence from endpoint, identity, email, and cloud-app sensors and, when it reaches high confidence that a specific device is compromised, applies containment actions without waiting for human approval (subject to the device group's automation level). Isolate device is one of several actions in its toolkit.

When the isolate action fires on an eligible device:

1. The device is disconnected from the network at the OS/firewall level (the same mechanism as manual isolation — `iptables`/`ip6tables` rules on Linux, Windows Filtering Platform on Windows, PF on macOS).
2. Connectivity to the Microsoft Defender for Endpoint cloud service is deliberately preserved, so the sensor keeps reporting and security operators can continue to monitor, run scans, and issue further response actions remotely.
3. Isolation is **scoped** — it targets the specific device(s) involved in the incident, not a blast-radius sweep of the whole environment.
4. Isolation is **time-limited** — it is automatically undone after a defined window unless a security operator releases it earlier or extends containment through other means. This is a deliberate design choice: an automated system that can silently contain production assets indefinitely is a larger operational risk than one that self-expires and requires an active decision to re-contain.

Two independent exclusion layers sit above this mechanism, and conflating them is the single most common configuration mistake:

- **Selective isolation exclusions** operate *within* an isolation event — they define which processes and network destinations remain reachable on an otherwise-isolated device (e.g. a monitoring agent, a specific management console). Available on Windows 11, Windows 10 1703+, Windows Server 2012 R2+, Azure Stack HCI 23H2+, and macOS. Defining a selective isolation exclusion rule for a device is what causes automatic attack disruption to use **Selective isolation by default instead of Full isolation** the next time it acts on that device — this is documented, deliberate behavior.
- **Automatic attack disruption exclusions** operate *above* the isolation decision entirely — they mark a device or entity as exempt from automatic containment actions altogether. Configured via device tag + "Policy applications and exclusions (Preview)", scoped per-action (you can exclude just Isolate device while leaving other containment actions active for that same tag).

When an excluded device would otherwise have been isolated, the action is logged with a **Skipped** status in the Action center and the device continues operating normally — this is the correct signal to confirm an exclusion is actually working, rather than the absence of any log entry.

</details>

---
## Dependency Stack

```
Layer 4: Exclusion configuration
         Selective isolation exclusions (per-device process/destination allow-list)
         Automatic attack disruption exclusions (per-tag, per-action exemption)
Layer 3: Automatic attack disruption decision engine
         Cross-signal correlation (endpoint + identity + email + cloud apps)
         → incident confidence scoring → device-group automation level check
Layer 2: Response action execution
         Isolate device (Full or Selective) — issued as a machine action
         against the target device's Machine ID
Layer 1: Sensor/connectivity layer
         MDE sensor (Sense service) must be healthy and the device must be
         reachable to receive and acknowledge the isolate command
Layer 0: Onboarding
         Device onboarded to MDE as an end-user workstation (NOT a server,
         domain controller, or unmanaged/undiscovered device — those route
         through Contain critical assets / Contain devices / Contain IP instead)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device "loses internet" with no ticket-side explanation | Automatic isolation fired | `machines/{id}` → `isolationState` + `machineactions` requestor field |
| Device isolated but investigation tools (e.g. live response) fail to reach it | Isolation legitimately blocks most traffic; investigation method/endpoint not on the allow path | Confirm method is supported for the device/scenario; check required service endpoints per `Configure device connectivity` |
| Device partially reachable while marked isolated | A Selective isolation exclusion rule exists for this device | Check exclusion configuration in the portal; this switches Full → Selective by default |
| Isolation "disappeared" with no admin action logged | Time-limited auto-release window expired | Review Action center release event, don't assume tampering |
| Device never gets isolated despite an active incident naming it | An Automatic attack disruption exclusion (per-tag) is suppressing the Isolate device action | Check device tags against configured Policy applications and exclusions; look for **Skipped** status in Action center |
| Isolate action stuck `Pending` | Device offline or unable to reach MDE cloud service | Confirm last-seen timestamp, retry once device is confirmed online |
| BAS/security-validation exercise unexpectedly isolated test devices | No temporary exclusion was configured before running the exercise | Exclude Isolate device action for in-scope devices before future exercises |

---
## Validation Steps

1. **Confirm the device is genuinely eligible for this action.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId" | Select-Object computerDnsName, osPlatform, machineTags
   ```
   Good: an end-user workstation OS platform, onboarded. Bad: a server SKU — if so, this topic doesn't apply; check `Contain critical assets`/`Contain devices` instead.

2. **Confirm current isolation state and the action history.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$deviceId'&`$orderby=creationDateTimeUtc desc&`$top=10" |
       Select-Object -ExpandProperty value | Select-Object type, status, requestor, creationDateTimeUtc
   ```
   Good: a clear, ordered action history. Bad: repeated Isolate/Unisolate cycles in a short window — indicates a recurring trigger that needs root-cause investigation, not just repeated releases.

3. **Confirm the triggering incident and its confidence.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/incidents?`$filter=status eq 'active'&`$top=50" |
       Select-Object -ExpandProperty value | Where-Object { $_.systemTags -contains 'AttackDisruption' }
   ```
   Good: a multi-signal incident with several correlated alerts. Bad: a single low-severity alert driving an isolation — worth reviewing automation-level configuration for that device group.

4. **Confirm exclusion configuration if applicable.**
   Portal-only check (no documented Graph read surface for Policy applications and exclusions as of this writing): Defender portal → Settings → Endpoints → Attack Disruption → Policy applications and exclusions. Cross-reference the device's tags from step 1 against configured exclusion rules.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm scope.** Is the affected device actually an onboarded end-user workstation? If it's a server, DC, or unmanaged device, this entire topic doesn't apply — redirect to the appropriate sibling containment action.

**Phase 2 — Confirm trigger legitimacy.** Pull the triggering incident and its correlated alerts before touching containment state. Releasing a device before understanding why it was isolated risks re-exposing an active compromise.

**Phase 3 — Decide: release, extend, or escalate.** If remediation is confirmed complete, release. If investigation is ongoing, leave isolated and communicate expected duration to the business owner. If the device is critical enough that isolation itself is causing unacceptable impact, evaluate a Selective isolation exclusion (keep isolation but allow specific critical traffic) before reaching for a full Automatic attack disruption exclusion (which removes containment protection entirely).

**Phase 4 — Fix the recurrence, not just the symptom.** Repeated auto-isolation of the same device is a signal worth investigating on its own merits — either the device has a persistent compromise vector, or a benign process/behavior is repeatedly tripping high-confidence correlation and may warrant a scoped Selective isolation exclusion rather than repeated manual releases.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standard release after confirmed remediation</summary>

1. Confirm the triggering incident's remediation steps are complete (malware removed, credentials rotated, etc.).
2. Release from isolation via the device page, device inventory, or the `unisolate` API action.
3. Monitor the device for re-isolation over the following 24-48 hours — a quick re-trigger means remediation was incomplete.
4. Document the incident resolution and close out the Action center entry.

No rollback needed — release is itself the terminal, safe state for this action.

</details>

<details><summary>Playbook 2 — Recurring false-positive isolation on a specific business-critical device</summary>

1. Confirm across at least 2-3 occurrences that the trigger is genuinely benign (e.g. a legitimate but unusual admin tool tripping correlation) rather than a real, intermittent compromise — do not skip this verification step.
2. Prefer a **Selective isolation exclusion** (keeps isolation as containment but allow-lists the specific process/destination causing false-positive impact) over a full **Automatic attack disruption exclusion** wherever the false-positive traffic is specific and identifiable.
3. Only use a full Automatic attack disruption exclusion (via device tag + Policy applications and exclusions) if the device must never be isolated for business reasons, and pair this with a compensating manual monitoring control — an excluded device is a device with reduced automated protection.
4. Set a calendar reminder to review the exclusion quarterly; stale exclusions on devices that no longer need them are a common audit finding.

Rollback: remove the tag from Policy applications and exclusions, or delete the selective isolation exclusion rule, to restore full default protection.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects automatic-attack-disruption device isolation evidence for a single device
    for escalation or incident documentation.
#>
param([Parameter(Mandatory)][string]$DeviceId)

$machine = Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId"
$actions = (Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$DeviceId'&`$orderby=creationDateTimeUtc desc&`$top=25").value
$incidents = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/incidents?`$filter=status eq 'active'&`$top=50").value |
    Where-Object { $_.systemTags -contains 'AttackDisruption' }

[PSCustomObject]@{
    DeviceName        = $machine.computerDnsName
    IsolationState    = $machine.isolationState
    HealthStatus      = $machine.healthStatus
    LastSeen          = $machine.lastSeen
    MachineTags       = ($machine.machineTags -join ", ")
    RecentActions     = $actions | Select-Object type, status, requestor, creationDateTimeUtc
    RelatedIncidents  = $incidents | Select-Object id, displayName, severity, createdDateTime
} | ConvertTo-Json -Depth 5
```

---
## Command Cheat Sheet

```powershell
# Current isolation state
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId" | Select isolationState

# Recent isolate/release action history
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$deviceId'&`$orderby=creationDateTimeUtc desc&`$top=10"

# Manually release a device
Invoke-MgGraphRequest -Method POST -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId/unisolate" -Body (@{Comment="release reason"} | ConvertTo-Json) -ContentType "application/json"

# Manually isolate a device (for comparison / manual escalation, not this topic's automatic path)
Invoke-MgGraphRequest -Method POST -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId/isolate" -Body (@{Comment="reason"; IsolationType="Full"} | ConvertTo-Json) -ContentType "application/json"

# Active incidents tagged AttackDisruption
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/incidents?`$filter=status eq 'active'" | Select-Object -ExpandProperty value | Where-Object { $_.systemTags -contains 'AttackDisruption' }

# Device tags (for cross-referencing exclusion rules — the exclusion rule itself is portal-only)
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId" | Select-Object -ExpandProperty machineTags
```

---
## 🎓 Learning Pointers

- This is architecturally the same "Isolate device" action that's been GA for years — what's new and Preview is the **automatic trigger path** via attack disruption, plus its dedicated exclusion controls. See [Take response actions on a device](https://learn.microsoft.com/en-us/defender-endpoint/respond-machine-alerts#isolate-device---automatic-attack-disruption-preview).
- Selective isolation exclusions and Automatic attack disruption exclusions solve different problems at different layers — confusing the two is the most common misconfiguration for this topic. See [Isolation exclusions](https://learn.microsoft.com/en-us/defender-endpoint/network-isolation-exclusions) and [Automatic attack disruption exclusions](https://learn.microsoft.com/en-us/defender-xdr/automatic-attack-disruption-exclusions).
- Scope is hard-limited to onboarded end-user workstations — don't expect this mechanism on servers, domain controllers, or unmanaged devices; those use the sibling Contain actions on the same base Learn page.
- No PowerShell module wraps `api.securitycenter.microsoft.com` directly — all scripting in this repo against MDE machine/action data goes through `Invoke-MgGraphRequest` against that REST host, consistent with `Get-MDEDeviceStatus.ps1`'s existing pattern.
- For the proactive, pre-compromise sibling capability (hardening *predicted* future targets rather than isolating a confirmed one), see `PredictiveShielding-A.md`/`-B.md`.
