# Automated Investigation & Response (AIR) — Hotfix Runbook (Mode B: Ops)
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

AIR tickets fall into a handful of shapes: a legitimate file got quarantined (false positive), a remediation action is stuck "Pending" and nobody knows who's supposed to approve it, AIR seems to have done nothing at all after an alert, or someone wants to change how aggressively AIR remediates. Start in the Microsoft Defender portal (security.microsoft.com) — there is no PowerShell cmdlet surface for AIR state itself, this is a portal/Graph-API-driven feature.

| Check | Where | Interpretation |
|---|---|---|
| Action Center → **Pending** tab | `https://security.microsoft.com/action-center` | Any item here needs a human decision — it will sit there until approved, rejected, or it silently times out after **7 days** (treated as rejected) |
| Action Center → **History** tab | Same page | Shows everything AIR already did automatically — this is where you Undo a false positive |
| Device group automation level | **Settings → Endpoints → Device groups** | This is set **per device group**, not tenant-wide — the #1 source of "why did this device behave differently than that one" confusion |
| Device's Plan/licensing | **Settings → Endpoints → Licenses**, or per-device page | AIR only exists in **Defender for Endpoint Plan 2** or **Defender for Business** — Plan 1 has no AIR at all, regardless of any device group configuration |
| Incident → Evidence and Response tab | Specific incident page | Approve/reject remediation actions in incident context, same underlying queue as Action Center |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device onboarded to Microsoft Defender for Endpoint, licensed Plan 2 (or Defender for Business)
  └── (Plan 1 has NO automated investigation/remediation capability at all — stop here if Plan 1)
  └── Real-time protection / EDR sensor active and reporting
        └── An alert is generated that is eligible to trigger an automated investigation
              └── Device is a member of a Device Group (falls to "Ungrouped devices" default
                  group if not explicitly assigned — groups are matched top-down by RANK,
                  first match wins)
                    └── That device group's Automation Level governs the outcome:
                          ├── Full — remediate automatically (recommended, default for tenants
                          │     created on/after Aug 16, 2020)
                          ├── Semi (3 variants: any / core-folders / non-temp-folders) —
                          │     some or all actions require human approval
                          └── No automated response — AIR never runs at all for this device
                                (built-in real-time AV blocking is UNAFFECTED by this setting —
                                 it governs post-alert investigation/remediation only)
                                      └── Verdict reached per artifact: Malicious / Suspicious /
                                          No threats found
                                            └── Action taken automatically OR queued Pending
                                                in the Action Center, per the automation level
                                                  └── Pending actions expire after 7 DAYS with
                                                      NO approval → treated as REJECTED, silently
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the device even has AIR available.** Check the device's Defender plan. Defender for Endpoint Plan 1 customers sometimes escalate "AIR isn't investigating anything" tickets when the real answer is: it never will, on this license.
   - Portal: **Assets → Devices → \<device\> → Overview** shows the onboarding/plan context; or check the tenant's overall Defender license under **Settings → Endpoints → Licenses**.

2. **Identify which device group the affected device is actually in**, and that group's automation level. Device groups are evaluated top-down by rank — a device can only match ONE group (the highest-ranked group whose criteria it satisfies), so two devices that look similar (same OU, same naming pattern) can land in different groups with different automation levels if the group criteria/rank ordering isn't what you assumed.
   - Portal: **Settings → Endpoints → Device groups** — review rank order and criteria, then check which group the specific device falls into via **Assets → Devices → \<device\>**.

3. **Check the Action Center for the specific investigation.** Search by device name or alert.
   - Pending tab = awaiting a decision. History tab = already resolved (automatically or by prior approval).

4. **If a file was wrongly quarantined**, confirm the verdict was *Malicious* or *Suspicious* and trace which automation level path applied (Full = automatic; Semi-core-folders/non-temp = depends on file location).

---
## Common Fix Paths

<details><summary>Fix 1 — Legitimate file/app quarantined (false positive)</summary>

1. Go to **Action Center → History**, locate the Quarantine file action for the affected file/device.
2. Select the item(s) — for the same file across multiple devices, use **Apply to X more instances of this file** to batch-undo.
3. Select **Undo**.
4. Add an indicator/exclusion so it doesn't recur: **Settings → Endpoints → Indicators** (allow the specific file hash) or an ASR/AV exclusion if this is a known LOB app pattern (see `ASR-Rules-B.md` for exclusion syntax).

Rollback note: Undo restores the file/registry key/scheduled task/etc. from quarantine — it does not retroactively "unblock" future detections of the same hash unless you also add the allow indicator in step 4.

</details>

<details><summary>Fix 2 — Remediation action stuck in "Pending" and nobody's approving it</summary>

1. Confirm who has the RBAC role to approve (Security Operator or equivalent Defender role with remediation permissions).
2. Route to that person/team, or approve directly if you hold the role: **Action Center → Pending → select item → Approve** (or **Reject** if it's a false positive — pair with Fix 1's Undo if something already fired automatically before rejection could apply).
3. **If this keeps happening repeatedly for the same device group**, the group's automation level may be set stricter than the org actually wants to operate (e.g., "Semi — require approval for any remediation" on a group where full automation would be appropriate). Revisit the automation level, don't just keep manually approving forever.
4. Remember the **7-day expiry**: if nobody approves in time, the action is auto-rejected — the "threat" is left as detected-but-unremediated. Check whether anything timed out recently if you're seeing artifacts that "should have been cleaned up."

</details>

<details><summary>Fix 3 — AIR seemingly did nothing after an alert fired</summary>

1. Check the device group's automation level first — **"No automated response"** means AIR literally never investigates, by design (this is explicitly not-recommended by Microsoft, but it is a valid, sometimes intentionally chosen setting for tightly change-controlled environments).
2. If the group isn't set to "No automated response," confirm the alert type is actually one that triggers automated investigation — not every alert category does; some are informational-only.
3. Confirm the device is in ANY device group at all — a device with zero group membership falls into "Ungrouped devices," which has its own automation level default (verify it wasn't set to No automated response as a leftover default).
4. If none of the above explains it, this may be a genuine platform gap or delay — check **Action Center** directly by device/time rather than assuming from the incident view alone, and escalate to Microsoft support with the incident/alert ID if still unexplained.

</details>

<details><summary>Fix 4 — Change the automation level for a device group</summary>

**Settings → Endpoints → Device groups → \<group\> → Automation level** dropdown → select the desired level → **Save**.

Guidance: Microsoft recommends **Full** for most orgs — their own telemetry shows 40% more high-confidence malware removed vs. lower automation levels, and every action (including under Full) remains visible and undoable in Action Center History. Reserve Semi-automation for specific device groups with genuine change-control requirements (e.g., regulated production servers where every remediation needs a human sign-off), not as a default-everywhere posture — it creates an approval queue that, per Fix 2, tends to get neglected.

Rollback: change the dropdown back to the prior value; takes effect on the next automated investigation, does not retroactively re-evaluate already-completed or already-pending actions.

</details>

---
## Escalation Evidence

```
=== AIR Escalation Packet ===
Tenant/Device Plan:              <Plan 1 / Plan 2 / Defender for Business>
Device name:                     <device>
Device group:                    <group name, rank position>
Automation level (that group):   <Full / Semi-any / Semi-core / Semi-non-temp / No automated response>
Incident/Alert ID:                <ID>
Action Center item ID/type:      <Quarantine file / Kill process / etc.>
Status (Pending/History):        <status, timestamp, approver if applicable>
Verdict:                         <Malicious / Suspicious / No threats found>
Expected vs actual behavior:     <what should have happened per automation level table vs what happened>
Requested action:                <undo / approve / automation-level change / platform escalation>
```

---
## 🎓 Learning Pointers

- Automation level is a **per device group** setting, not a tenant-wide switch — always confirm which group a device is actually in before assuming a policy applies. See [Automation levels in AIR — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/automation-levels) (updated 2026-01-15).
- Pending approvals expire after **7 days** and are then silently treated as rejected — build this into any change-control process that relies on Semi-automation, or the queue becomes a source of un-remediated threats by neglect rather than decision. See [Review remediation actions following automated investigations — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/manage-auto-investigation) (updated 2026-07-15).
- AIR is a **Defender for Endpoint Plan 2 / Defender for Business** capability only — Plan 1 customers can still create device groups, but there is no AIR to configure on them. Confirm licensing before troubleshooting "AIR isn't working."
- "No automated response" does not disable Defender's real-time antivirus/EDR blocking — it only disables the *post-alert investigation and remediation* workflow. Don't conflate the two when explaining this setting to a client who wants "AIR off" for change-control reasons but still expects real-time protection.
- Undo is available for both automatic and manually-triggered remediation actions from Action Center History — always prefer Undo + an allow indicator over disabling AIR broadly when chasing a single false positive.
