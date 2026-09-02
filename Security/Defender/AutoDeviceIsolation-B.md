# Automatic Device Isolation (Attack Disruption, Preview) — Hotfix Runbook (Mode B: Ops)
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

A user reports a device "lost internet" or a ticket says a workstation is unreachable with no ticket-side explanation. Before chasing a network fault, rule this in or out first — it takes under a minute.

```powershell
# 1. Confirm Graph connection and check the device's current isolation state
Connect-MgGraph -Scopes "Machine.Read.All"
$deviceId = "<AAD-Device-ID-or-MDE-MachineId>"
$m = Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId"
$m | Select-Object computerDnsName, isolationState, healthStatus, lastSeen

# 2. List recent isolate/release actions for this device
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$deviceId'&`$orderby=creationDateTimeUtc desc&`$top=5" |
    Select-Object -ExpandProperty value | Select-Object type, status, requestor, creationDateTimeUtc

# 3. Check for an open incident that triggered automatic attack disruption on this device
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/incidents?`$filter=status eq 'active'&`$top=25" |
    Select-Object -ExpandProperty value | Where-Object { $_.systemTags -contains 'AttackDisruption' } |
    Select-Object id, displayName, severity, createdDateTime

# 4. Confirm the device tag used for auto-isolation exclusions (portal-only setting — this only shows tag membership)
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId" | Select-Object -ExpandProperty machineTags
```

| Result | Interpretation |
|---|---|
| `isolationState = Isolated`, a `requestor` of `System` or `Automatic disruption` on a recent `Isolate` action | This IS automatic device isolation, not a network fault. Go to [Common Fix Paths](#common-fix-paths). |
| `isolationState = Isolated`, `requestor` is a named admin | This was a **manual** isolation — different runbook, ask the requestor before releasing. |
| `isolationState = NotIsolated`, no recent `Isolate` action | Not this feature. Troubleshoot as a normal connectivity/network issue instead. |
| An active incident tagged `AttackDisruption` includes this device | Confirms the trigger; do not release the device until the incident is understood — see [Escalation Evidence](#escalation-evidence). |
| `machineTags` includes an isolation-exclusion tag but the device was isolated anyway | The **Policy applications and exclusions** rule for that tag was likely misconfigured or not yet propagated (up to a few minutes) — verify in the portal under Attack Disruption exclusions. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device onboarded to Microsoft Defender for Endpoint, sensor healthy
    └── Automatic attack disruption enabled (device-group automation level: Full or
            Semi — see AIR-A.md for the automation-level model this shares)
            └── Defender XDR correlates cross-signal evidence (endpoint + identity +
                    email + cloud apps) into a high-confidence incident
                    └── Device classified as compromised AND is an end-user
                            WORKSTATION onboarded/managed by MDE
                            (servers, domain controllers, unmanaged/undiscovered
                            devices are NOT eligible for THIS action — see
                            Contain device / Contain critical assets / Contain IP
                            in respond-machine-alerts instead)
                            └── No matching Automatic attack disruption exclusion
                                    for this device/entity
                                    └── Isolate device action fires
                                            ├── Full isolation (default) OR
                                            │   Selective isolation (if a Selective
                                            │   isolation exclusion rule exists for
                                            │   this device — defining one silently
                                            │   changes the isolation TYPE)
                                            └── Device disconnected from network,
                                                    retains MDE cloud connectivity
                                                    └── Time-limited: auto-released
                                                            after a defined window,
                                                            or manually released
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm it's automatic, not manual isolation.**
   Run Triage step 1-2 above. `requestor` on the `Isolate` machine action distinguishes a named admin (manual) from the system (automatic attack disruption).
   Expected: automatic isolations show a system/automation requestor, never a named UPN.

2. **Find the triggering incident.**
   In the Defender portal, open **Incidents**, filter to the device, and open the **Activities** tab (or **Action center**) to see the exact action, timestamp, and the alert chain that triggered it. This is the fastest way to know *why* — do not skip this before releasing a device.
   Expected: a clear incident with correlated alerts (not a single isolated low-severity detection).

3. **Check whether the device is genuinely isolated or stuck pending.**
   ```powershell
   Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$deviceId' and type eq 'Isolate'&`$orderby=creationDateTimeUtc desc&`$top=1" |
       Select-Object -ExpandProperty value | Select-Object status, errorHint
   ```
   `status = Pending` for more than ~15 minutes on an active device usually means the device is offline or can't reach the MDE cloud service to receive the command. `status = Failed` — confirm the device is online and re-issue from the device action panel.

4. **If the device shows isolated but you can't pull investigation data from it,** confirm your investigation method (e.g. live response) is supported for that device/scenario, and that required MDE service endpoints are reachable from an isolated state (isolation blocks most traffic but keeps the MDE cloud channel open by design).

5. **If isolation was lifted unexpectedly with no admin action logged,** check whether a time-limited automatic undo window applies in your tenant, and review the Action center's release event before assuming tampering or a bug.

---
## Common Fix Paths

<details><summary>Fix 1 — Business-critical device was auto-isolated and needs to come back online now</summary>

Verify containment/remediation is actually safe first — releasing prematurely can re-expose the compromise.

```powershell
# Release from isolation (device inventory / device page equivalent)
$body = @{ Comment = "Verified remediated - releasing per <ticket/incident ref>" } | ConvertTo-Json
Invoke-MgGraphRequest -Method POST -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId/unisolate" -Body $body -ContentType "application/json"
```
Rollback: none needed — this is the release action itself. If the device re-isolates immediately after release, the triggering incident is still active; investigate before releasing again.

</details>

<details><summary>Fix 2 — Device is stuck "isolated" and unresponsive, forcible release script needed</summary>

The standard release action requires the device to check in. For an unresponsive device, use Microsoft's downloadable per-device forced-release script instead of waiting.

1. In the Defender portal, open the device page → action menu → **Download script to force-release a device from isolation**.
2. Requires local admin execution on the device itself; script is valid for that device only and **expires in 3 days**.
3. Minimum builds: Windows 10 21H2/22H2 with KB5023773/KB5023778, Windows 11 21H2 with KB5023774, Windows 11 22H2 with KB5023778. Older builds cannot use this path — escalate for manual remediation instead.

Rollback: not applicable — this only removes containment, it does not undo any other remediation action taken.

</details>

<details><summary>Fix 3 — A business-critical device keeps getting auto-isolated and it's causing outages faster than you can respond</summary>

Do not disable automatic attack disruption tenant-wide as a first response — that removes protection from every device, not just this one.

1. Confirm the device is genuinely a false-positive/over-broad target, not a real compromise, before excluding it.
2. Create or apply a device tag to the device.
3. In the Defender portal, configure **Policy applications and exclusions (Preview)** for that tag and exclude the **Isolate device** action specifically (this is narrower than excluding the device from all attack-disruption actions).
4. Confirm the exclusion by checking that a subsequent would-be isolation shows **Skipped** status in the Action center rather than silently not appearing at all.

Rollback: remove the tag or the policy exclusion once the underlying cause is fixed — do not leave a business-critical device permanently exempted from containment without a compensating control.

</details>

<details><summary>Fix 4 — Running a breach-and-attack simulation and don't want it to trigger real isolation</summary>

Temporarily exclude the **Isolate device** action (via the same Policy applications and exclusions path as Fix 3) for the devices in scope of the simulation before running it, then remove the exclusion immediately after. Forgetting to remove it leaves those devices unprotected against a genuine future incident.

</details>

<details><summary>Fix 5 — Selective isolation exclusions vs. Automatic attack disruption exclusions confusion</summary>

These are two different controls that are easy to conflate:

- **Selective isolation exclusions** — define *what stays reachable* on an isolated device (e.g. a management tool or line-of-business app). The device is still isolated; only specific processes/destinations are excepted.
- **Automatic attack disruption exclusions** — define *which devices/entities are never touched* by automatic attack disruption actions at all, including isolation.

If a device that should have been fully isolated instead shows partial network access, check for a **selective isolation exclusion rule** first — defining one on a device silently switches the isolation type from Full to Selective by default, which is expected behavior, not a bug.

</details>

---
## Escalation Evidence

```
=== Automatic Device Isolation — Escalation Template ===
Device name / MDE Machine ID: <fill in>
Isolation state at time of report:      <Isolated / NotIsolated / Pending>
Requestor on the Isolate action:        <System/AttackDisruption vs named admin>
Triggering incident ID:                 <fill in>
Incident severity / status:             <fill in>
Correlated alert count:                 <fill in>
Time isolated (UTC):                    <fill in>
Business impact / criticality of device:<fill in>
Selective or Full isolation applied:    <fill in>
Exclusion rule present on this device?: <yes/no — tag name if yes>
Action taken so far:                    <released / left isolated / forcibly released>
Requested next step:                    <release approval / root-cause investigation / exclusion review>
```

---
## 🎓 Learning Pointers

- Automatic device isolation is a **Preview** capability layered on top of the long-GA manual "Isolate device" action — the underlying isolation mechanism (network block + retained MDE cloud channel) is identical either way; only the *trigger* differs. See [Take response actions on a device](https://learn.microsoft.com/en-us/defender-endpoint/respond-machine-alerts#isolate-device---automatic-attack-disruption-preview).
- It only fires on **onboarded end-user workstations**. Domain controllers, DNS/DHCP servers, and other critical assets use the separate **Contain critical assets** mechanism (port/direction-level blocking, not full isolation) — don't expect this runbook's fixes to apply there.
- Defining a **Selective isolation exclusion** rule for a device changes the *type* of isolation applied (Full → Selective) the next time automatic attack disruption acts on it — this is documented, deliberate behavior, not a partial failure.
- The forcible-release script is a genuinely separate mechanism from the normal Release button, gated by specific KBs — don't assume every device in your fleet can use it.
- Related but architecturally distinct: `PredictiveShielding-B.md`/`-A.md` (proactive hardening of *predicted* future targets, not reactive isolation of a confirmed-compromised device) and `AIR-B.md`/`-A.md` (per-alert automated investigation, a different automation engine entirely).
