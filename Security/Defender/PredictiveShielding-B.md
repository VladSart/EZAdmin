# Predictive Shielding — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Predictive shielding (Preview, as of this writing) is an *autonomous* Defender for Endpoint capability. Nobody in the tenant configured a policy that suddenly stopped GPOs applying or blocked Safe Mode — Defender did it, on its own, in response to a detected attack elsewhere in the environment. The #1 triage mistake is treating this as a misconfiguration ticket instead of a security-response ticket.

Run these first, in this order:

```powershell
# 1 — Is there an active Defender incident tagged "Predictive Shielding"?
# Portal: security.microsoft.com > Incidents & alerts > Incidents
# Filter by the "Predictive Shielding" tag — do this BEFORE touching any device or GPO

# 2 — On the affected device: confirm MDE onboarding + sensor health
# (predictive shielding requires an active, healthy Defender for Endpoint sensor)
Get-Service Sense, WinDefend | Select-Object Name, Status
& "$env:ProgramFiles\Windows Defender Advanced Threat Protection\MpCmdRun.exe" -SenseCncProxyTest 2>$null

# 3 — Is the device currently under a hardening policy? (0x0=off, 0x1=on)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Hardening" -EA SilentlyContinue

# 4 — Confirm which hardening action is active (GPO vs Safeboot) via Advanced Hunting
#     (run in security.microsoft.com > Advanced hunting, or via Get-PredictiveShieldingAudit.ps1 -Mode Hunting)
# DisruptionAndResponseEvents | where PolicyName in ("GpoPrevention","SafebootPrevention") | where DeviceId == "<deviceId>" | where ReportType == "PolicyUpdated" and IsPolicyOn == "1"

# 5 — Confirm the triggering incident, not just the symptom device
# Incident details > Activities tab > filter Response category > find GPO Hardening / SafeBoot Hardening row > "Triggering alert" column
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| GPOs stopped applying to one/several devices, no admin change made | GPO Hardening action active — device flagged high-risk by predictive shielding | Fix 1 |
| Device won't boot to Safe Mode / F8-Safe Mode option greyed out or blocked | Safeboot Hardening action active | Fix 2 |
| User account suddenly restricted/logged out with no ticket raised | Contain User action — a predictive shielding action, not GPO/Safeboot specific | Fix 3 |
| "Predictive Shielding" tag not visible anywhere in the portal | Feature not enabled, or tenant lacks a Defender for Endpoint license (Plan 2/DfB) | Fix 4 |
| Hardening applied but you need it removed NOW (business-critical device) | Manual undo path | Fix 5 |
| Can't tell if an action came from predictive shielding or a human admin | "Performed by" column always shows "Attack Disruption" for both — disambiguate via action type | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for predictive shielding to trigger</summary>

```
[Microsoft Defender XDR tenant, Defender for Endpoint Plan 2 or Defender for Business license]
    └── [Automatic attack disruption enabled (predictive shielding extends this same stack)]
            └── [MDE sensor healthy + onboarded on the target device]
                    └── [An ACTIVE incident detected elsewhere in the environment]
                            └── [Defender's exposure graph + threat intel + AI predicts this device/user
                                 is a likely NEXT target on the attack path]
                                    └── [Action applied AUTOMATICALLY, no admin approval step]
                                            ├── Contain User  — restricts an at-risk account
                                            ├── GPO Hardening (Preview) — blocks NEW GPO policy
                                            │      application to the device (existing applied
                                            │      policy is NOT rolled back, only new pushes are held)
                                            └── SafeBoot Hardening (Preview) — blocks the device
                                                   from booting into Safe Mode (a common attacker
                                                   persistence/AV-bypass tactic)
```

**Key fact:** predictive shielding is a licensing + feature-flag combination, not a policy you author. There is no "create a predictive shielding policy" experience — it fires automatically based on an active incident's blast-radius prediction. The only admin-facing controls are: (a) whether automatic attack disruption is enabled at all, and (b) undoing an individual action after the fact.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm an incident actually exists and is tagged.**
   Portal: Incidents & alerts > Incidents > filter tag = **Predictive Shielding**.
   Expected: at least one incident, with a disruption summary card showing the number of policies invoked and devices hardened.
   If empty: this device's symptom is NOT predictive shielding — go back to standard GPO/Safe Mode troubleshooting outside this runbook.

2. **Open the incident graph and read the attack story.**
   Confirm the affected device/user appears in the graph as a *predicted* target, not a *confirmed compromised* asset — this tells you whether you're dealing with a proactive hardening (this topic) or a reactive attack-disruption containment (a different, more urgent incident-response track).

3. **Check the Activities tab, Response category, for the specific action.**
   ```
   Type column shows: Contain User | GPO Hardening | SafeBoot Hardening
   Policy status column shows: currently applied / removed
   ```
   Expected good output: a clear row naming the exact action and the device/user it targets.

4. **Validate via Advanced Hunting** (works even if the portal UI is slow to reflect state):
   ```kusto
   DisruptionAndResponseEvents
   | where PolicyName in ("GpoPrevention","SafebootPrevention")
   | where DeviceId == "<deviceId>"
   | where Timestamp > ago(7d)
   | order by Timestamp desc
   ```
   `ReportType == "PolicyUpdated" and IsPolicyOn == "1"` = hardening currently active.
   `ReportType == "Prevented"` = a specific block event occurred (e.g., a GPO push was actually held, or a Safe Mode boot attempt was actually stopped) — this is your proof-of-effectiveness evidence for the ticket.

5. **Confirm sensor/connectivity health if the device seems "stuck" rather than actively hardened.**
   A device that lost Sense connectivity mid-incident can show a stale hardening state in the portal that no longer matches reality — reboot the sensor (`Restart-Service Sense`) and re-check before assuming the hardening itself is broken.

---
## Common Fix Paths

<details><summary>Fix 1 — GPO Hardening is blocking new Group Policy application</summary>

**What's happening:** the device was flagged as a likely next target in an active attack; Defender is temporarily holding new GPO policy pushes to it. This is not a rollback of already-applied GPOs — it only prevents *new* ones from landing, cutting off an attacker's ability to push a malicious GPO (e.g., disabling AV, adding a scheduled task) as a lateral-movement step.

1. Confirm the triggering incident is real and still active or recently resolved (do not undo hardening tied to an unresolved active incident without security-team sign-off).
2. If the incident is resolved and the device is confirmed clean:
   - Incident details > Activities tab > select the **GPO Hardening** row > **Undo**.
   - Or: Action center > find the action > **Undo**.
3. Confirm GPO application resumes:
   ```powershell
   gpupdate /force
   gpresult /h C:\Temp\gpresult.html
   ```
4. If the incident is still active or unconfirmed: escalate to security/incident response before undoing — this is a live containment measure, not a stuck-state bug.

**Rollback note:** undoing the action does not "roll back" anything that was already blocked — it simply stops blocking *future* GPO pushes from that point forward.

</details>

<details><summary>Fix 2 — SafeBoot Hardening is preventing Safe Mode boot</summary>

**What's happening:** the device was hardened against booting into Safe Mode, because attackers commonly abuse Safe Mode to bypass endpoint AV/EDR agents (most security agents don't load in Safe Mode with Networking, giving an attacker a window to disable defenses or exfiltrate data undetected).

1. Confirm via the incident Activities tab that **SafeBoot Hardening** is the active action on this device.
2. If a legitimate business need for Safe Mode exists (e.g., driver troubleshooting) and the incident is resolved/confirmed clean:
   - Undo the action from the Activities tab or Action center, same path as Fix 1.
3. If Safe Mode access is needed urgently and the incident is still active:
   - Do NOT undo unilaterally — escalate to security/IR first. Bypassing this control mid-incident on a predicted-target device is exactly the scenario the feature exists to prevent.
4. Validate the device can boot to Safe Mode again only after the action shows "removed" in Policy status.

**Rollback note:** the block is device-local and enforced by the Defender sensor itself, not a Group Policy setting — do not attempt to "fix" this via `msconfig` or `bcdedit`; it will not remove a Defender-enforced hardening state.

</details>

<details><summary>Fix 3 — Contain User action restricted an account unexpectedly</summary>

1. This is the same underlying mechanism as standard automatic attack disruption's device/account containment, applied predictively (before confirmed compromise, based on blast-radius prediction).
2. Check the incident's alert details for the **Predictive shielding** label and threat type (e.g., "ransomware") to understand why this specific user was selected.
3. Coordinate with the account owner and security team before restoring access — a predictively-contained account may still be a genuine target even if not yet compromised.
4. Undo path is identical: Activities tab or Action center > Undo, once cleared.

</details>

<details><summary>Fix 4 — "Predictive Shielding" tag/features don't appear anywhere</summary>

1. Confirm licensing: predictive shielding requires a Defender for Endpoint license (Plan 2 or Defender for Business) on the relevant devices — Plan 1-only tenants will not see this feature.
2. Confirm automatic attack disruption itself is enabled (predictive shielding is an extension of that same capability, not a separately-toggled feature as of this writing) — Settings > Endpoints > Advanced features > Automated Investigation, and the attack disruption settings page.
3. Remember this is a **Preview** feature at time of writing — confirm current availability/region rollout against the live Microsoft Learn page rather than assuming it's enabled tenant-wide by default.
4. If licensing and enablement both check out but no incidents have triggered it yet: this is expected — the feature only activates during an actual detected attack. Absence of tags does not mean the feature is broken.

</details>

<details><summary>Fix 5 — Need a hardening action removed immediately (business-critical device)</summary>

1. Incident details > Activities tab > select the action > **Undo**, or Action center > **Undo completed actions**.
2. There is no PowerShell/Graph cmdlet to undo this action as of this writing — portal-only.
3. If the portal is inaccessible or the incident response team is unavailable, this is a genuine escalation — do not attempt device-local workarounds (registry edits, `gpupdate` force, `bcdedit` Safe Mode flags); the Defender sensor re-enforces the hardening state and a local workaround will either fail silently or generate a new detection.
4. Document the undo reason on the incident (business-justification note) — this is the audit trail if security later needs to explain why a predictive containment was reversed.

</details>

<details><summary>Fix 6 — Disambiguating a predictive shielding action from a human admin's action</summary>

The **Performed by** column in the Activities tab shows **"Attack Disruption"** for both standard automatic attack disruption actions AND predictive shielding actions — it does not distinguish them by actor name.

1. Disambiguate by **action type**, not performer:
   - `Isolate Device`, `Disable User` (post-compromise, confirmed) → standard automatic attack disruption
   - `Contain User`, `GPO Hardening`, `SafeBoot Hardening` (pre-compromise, predicted) → predictive shielding
2. Cross-reference the alert details pane's **Predictive shielding** label — if present, it's this feature; if absent, treat it as standard attack disruption and use different runbook context (post-compromise IR, not proactive hardening).

</details>

---
## Escalation Evidence

```
PREDICTIVE SHIELDING — ESCALATION TEMPLATE
============================================
Tenant:                    <tenant name/ID>
Device(s) affected:        <device name(s) / DeviceId>
User(s) affected:          <UPN(s), if Contain User action>
Incident ID:               <Defender incident ID>
Predictive Shielding tag:  <confirmed present / absent>
Action(s) applied:         <GPO Hardening | SafeBoot Hardening | Contain User>
Policy status:             <applied / removed, per Activities tab>
Triggering alert:          <alert name + link>
Incident status:           <active / resolved / false positive — confirm with security team>
Advanced Hunting evidence: <paste DisruptionAndResponseEvents query output>
Business impact:           <what the device/user can't currently do>
Requested action:          <undo now / awaiting security sign-off / informational only>
```

---
## 🎓 Learning Pointers

- Predictive shielding is explicitly described by Microsoft as an *extension* of automatic attack disruption, not a replacement — understand [Automatic attack disruption](https://learn.microsoft.com/en-us/defender-xdr/automatic-attack-disruption) first if the "Contain User"/isolation concepts are unfamiliar, since the confidence-scoring and AI-decision model is shared between both features.
- This is a **Preview** feature as of this writing (GPO Hardening and SafeBoot Hardening actions specifically) — confirm current GA status, region availability, and any new response-action types against the live [Predictive shielding in Microsoft Defender](https://learn.microsoft.com/en-us/defender-xdr/shield-predict-threats) page before treating anything here as permanent behavior.
- The **Performed by** column showing "Attack Disruption" for both feature families (not a per-feature actor name) is the single most common cause of ticket misrouting — always disambiguate by action type and the Predictive shielding alert label, not by the performer field.
- Deploying the **Defender for Identity** sensor materially improves predictive shielding's accuracy (adds username/AD/group-membership enrichment to the graph) — if a tenant is only running MDE without MDI, expect fewer and less-precise predictive actions, not a bug.
- GPO Hardening only blocks *new* GPO pushes — it is not a rollback mechanism. If a malicious GPO was already applied before the incident triggered, that requires separate manual GPO remediation, not an "undo" of this action.
- See [Manage predictive shielding in Microsoft Defender](https://learn.microsoft.com/en-us/defender-xdr/shield-predict-threats-manage) for the full Advanced Hunting query set and the Action-center-based bulk undo workflow.
