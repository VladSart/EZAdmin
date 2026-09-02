# Predictive Shielding — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Predictive shielding** in Microsoft Defender XDR — a **Preview** capability (as of this writing) that proactively hardens devices and contains at-risk accounts *before* an attacker reaches them, based on graph-based prediction of likely attack progression from an already-active incident.

Assumes: a Microsoft Defender XDR tenant with Defender for Endpoint Plan 2 or Defender for Business licensing, automatic attack disruption already enabled (predictive shielding is architecturally an extension of that same autonomous-protection stack, not a separately-purchased add-on). Does **not** cover: standard (reactive, post-compromise) automatic attack disruption in general — see a future dedicated topic or Microsoft's own [Automatic attack disruption](https://learn.microsoft.com/en-us/defender-xdr/automatic-attack-disruption) documentation for that adjacent-but-distinct capability; Defender for Cloud Apps or Defender for Identity's own independent detection/response actions (predictive shielding consumes MDI signal as an enrichment source but is fundamentally an MDE-license-gated, MDE-action-executing feature).

**Source-confidence note:** both official Microsoft Learn source pages for this feature are marked "Preview" and explicitly warn that "some information in this article relates to a prereleased product which may be substantially modified before it's commercially released." Everything in this runbook — the two currently-documented hardening actions (GPO Hardening, SafeBoot Hardening), the KQL schema, the lack of a PowerShell/Graph configuration surface — should be treated as accurate as of the source pages' last-updated dates (2026-06-23 for the overview page, 2026-06-19 for the management page) and reverified against the live pages before being treated as permanent architecture, not as a guarantee that Microsoft won't add, rename, or GA-stabilize this differently.

---
## How It Works

<details><summary>Full architecture</summary>

Predictive shielding sits on top of Defender's existing **automatic attack disruption** stack and reuses its confidence-scoring and AI decision model, but shifts the trigger point earlier in the attack lifecycle:

- **Automatic attack disruption** (the pre-existing, broader capability): reacts to **confirmed** malicious activity on a specific asset — e.g., isolates a device once ransomware execution is detected on it.
- **Predictive shielding** (this topic): reacts to an **active incident anywhere in the environment**, then uses graph-based reasoning to identify *other* assets that are *likely future targets* on the attacker's probable path — and hardens those assets **before** the attacker reaches them, not after.

The distinction matters operationally: an admin investigating a predictive-shielding-hardened device will often find **no malicious activity on that specific device at all** — because the whole point of the feature is to act before compromise occurs there. This is the single most common source of "why did Defender do this, nothing's wrong here" tickets, and the correct response is not to treat the hardened device as a false positive, but to check the *originating* incident elsewhere in the environment that predicted this device as a likely next hop.

**The two-pillar model:**

1. **Prediction** — Defender continuously analyzes:
   - Threat intelligence (aligning observed activity with known attacker tools/tactics/TTPs)
   - Historical incident patterns (statistical extrapolation of "what usually happens next" after a given attacker behavior is observed)
   - Organizational exposure data (the structural map of the environment: which identities/assets are connected, what permissions exist, what vulnerabilities/misconfigurations are present, and how risk can propagate along those edges)

2. **Enforcement** — once a likely next-target asset is identified, Defender applies a **targeted, minimal** restriction to that specific asset (not a blanket, environment-wide lockdown) to cut off that specific predicted attack path, while security analysts continue investigating the root incident.

**Graph-based prediction logic — the three-stage pipeline:**

```
Stage 1: Defender overlays confirmed post-breach activity onto the
         organization's exposure graph
             │
             ▼
Stage 2: Defender computes the "blast radius" — every asset that the
         observed activity could plausibly reach next, based on the
         graph's connectivity (identities, permissions, network paths)
             │
             ▼
Stage 3: Reasoning models rank the most probable next steps within
         that blast radius, factoring in past attacker behavior
         patterns, asset criticality, and known vulnerabilities —
         then Defender applies enforcement to the highest-confidence
         predicted targets
```

This is why predictive shielding actions cluster around an active incident rather than appearing in isolation: every predictive action traces back to a specific triggering incident and a specific triggering alert, which is always visible in the Activities tab.

**Why GPO Hardening and SafeBoot Hardening specifically (as the two documented Defender-for-Endpoint-based actions, alongside Contain User):**

Both are classic *lateral-movement and defense-evasion enablers*, not endpoints in themselves — an attacker rarely wants to modify a GPO or force a Safe Mode boot as the end goal; they do it to escalate privilege, disable security tooling, or persist. By hardening these two specific mechanisms on predicted-next-target devices, Defender closes off two of the most common paths an attacker uses to expand from an initial foothold, without needing to fully isolate the device (which would disrupt business use) or wait for confirmed compromise on that specific device (which might arrive too late).

- **GPO Hardening (Preview):** temporarily stops **new** Group Policy Object pushes from applying to the flagged device. It is a forward-looking block, not a rollback — any GPO already applied before the hardening activated remains in effect. This specifically targets the attacker technique of pushing a malicious GPO (e.g., one that disables Defender, adds a scheduled task, or deploys a payload via startup script) as a lateral-movement or persistence mechanism.
- **SafeBoot Hardening (Preview):** prevents the device from booting into Safe Mode. Safe Mode is a well-documented attacker/red-team technique for bypassing endpoint security agents, since most EDR/AV agents (Defender included, in most configurations) do not load in Safe Mode without Networking — giving an attacker a window to disable defenses, tamper with configuration, or exfiltrate data with reduced detection risk.

**The "Performed by" column quirk:** for both predictive shielding actions and standard automatic attack disruption actions, the Activities tab's Performed by column shows the generic value **"Attack Disruption"** — it does not name "Predictive Shielding" as a distinct performer. The only reliable disambiguators are (a) the action **Type** column (GPO Hardening / SafeBoot Hardening / Contain User = predictive; Isolate Device / Disable User etc. = standard reactive attack disruption) and (b) the **Predictive shielding** label shown specifically in the alert details pane. This is a genuine, currently-documented UI limitation, not a misconfiguration to troubleshoot.

</details>

---
## Dependency Stack

```
[Microsoft Defender XDR tenant]
    │
    ├── License gate: Defender for Endpoint Plan 2 OR Defender for Business
    │       (predictive shielding uses Defender-for-Endpoint-based actions
    │        exclusively — Plan 1-only tenants cannot use this feature)
    │
    ├── Automatic attack disruption enabled
    │       (predictive shielding is documented as an EXPANSION of this
    │        existing autonomous-protection capability, sharing its
    │        confidence-scoring/AI decision model — not a separately
    │        toggled feature as of this writing)
    │
    ├── MDE sensor onboarded + healthy on candidate devices
    │       └── Sense service running, cloud connectivity intact
    │              (a disconnected/unhealthy sensor cannot receive or
    │               report hardening state — appears "stuck" if it
    │               drops mid-incident)
    │
    ├── [OPTIONAL, but materially improves accuracy]
    │      Defender for Identity sensor deployed
    │           └── Enriches the exposure graph with usernames, AD
    │                details, and group memberships — without it,
    │                predictions rely on MDE-only signal and will be
    │                fewer/less precise, not broken
    │
    └── TRIGGER: an active Defender incident, anywhere in the tenant,
           with sufficient confidence for the graph-based prediction
           model to identify likely next-target assets
               │
               ▼
        [Enforcement — automatic, no admin approval step]
               ├── Contain User        (account-level restriction)
               ├── GPO Hardening       (blocks NEW GPO pushes only)
               └── SafeBoot Hardening  (blocks boot-to-Safe-Mode)
               │
               ▼
        [Visible via: Incidents list "Predictive Shielding" tag,
         incident graph/attack story, disruption summary card,
         Activities tab (Response category), Advanced Hunting
         DisruptionAndResponseEvents table]
               │
               ▼
        [Reversal — MANUAL ONLY, portal-driven]
               └── Undo from Activities tab, or Action center
                      (no PowerShell/Graph cmdlet for undo, confirmed
                       absent from both source pages as of this writing)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| New GPOs silently not applying to a specific device, no admin change made | GPO Hardening action active on that device | Activities tab, Response category, Type = GPO Hardening |
| Device cannot boot into Safe Mode; F8/msconfig Safe Mode option ignored or blocked | SafeBoot Hardening action active | Activities tab, Type = SafeBoot Hardening |
| A user account is suddenly restricted/signed out with no help-desk ticket or admin action logged | Contain User action (predictive, not reactive) | Alert details pane — check for the "Predictive shielding" label and threat type |
| Hardening state shown in portal doesn't match observed device behavior | Sensor lost connectivity mid-incident, stale reported state | `Get-Service Sense` on device; check last-seen timestamp in device inventory |
| Cannot find "Predictive Shielding" anywhere in the tenant | Missing Defender for Endpoint Plan 2/DfB license, OR automatic attack disruption itself disabled, OR feature genuinely hasn't triggered yet (no active qualifying incident) | Settings > Endpoints > Advanced features (attack disruption toggle); license inventory; Incidents list filtered by tag |
| Ticket says "Defender broke our Safe Mode / GPOs and IT didn't do it" but no incident is visible to the requester | Requester lacks Security Reader/Operator role to see Incidents — action is real but invisible to them, not a phantom | Confirm with a security-role-holding admin before concluding it's unrelated to Defender |
| Undo action available in Action center but the underlying restriction still appears active on the device | Sensor policy re-sync delay, or the undo targeted the wrong specific action among several applied to the same device | Re-check Activities tab per-action Policy status column; allow a sync interval before re-escalating |

---
## Validation Steps

1. **Confirm license and feature prerequisites.**
   ```powershell
   Connect-MgGraph -Scopes "Organization.Read.All"
   Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "DEFENDER|ATP|MDATP|EMSPREMIUM|SPE_E5|DFB" } |
       Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
   ```
   Expected: a SKU covering Defender for Endpoint Plan 2 (bundled in E5/EMS E5/standalone) or Defender for Business.
   Bad output: no matching SKU — predictive shielding is not usable regardless of any other setting.

2. **Confirm automatic attack disruption is enabled tenant-wide.**
   Portal: `security.microsoft.com` > Settings > Endpoints > Advanced features > confirm Automated Investigation and related attack disruption settings are ON.
   Bad output: disabled — predictive shielding cannot fire even with a qualifying incident.

3. **Confirm sensor health on the specific device.**
   ```powershell
   Get-Service Sense, WinDefend | Select-Object Name, Status, StartType
   ```
   Expected: both `Running`.
   Bad output: `Stopped` or missing — hardening state reported by the portal may be stale/unreliable for this device.

4. **Confirm the triggering incident and disambiguate action type.**
   Portal: Incidents & alerts > Incidents > filter tag = Predictive Shielding > open incident > Activities tab > Response category.
   Expected: a row showing Type = GPO Hardening / SafeBoot Hardening / Contain User, with a Policy status of Applied or Removed.
   Bad output: no rows — the device's symptom is not attributable to predictive shielding; investigate through normal GPO/Safe Mode channels instead.

5. **Cross-validate with Advanced Hunting for a portal-independent proof point.**
   ```kusto
   DisruptionAndResponseEvents
   | where PolicyName in ("GpoPrevention","SafebootPrevention")
   | where Timestamp > ago(7d)
   | order by Timestamp desc
   ```
   Expected: rows with `ReportType == "PolicyUpdated"` (state changes) and/or `ReportType == "Prevented"` (an actual block event occurred — the strongest evidence the control did something, not just that it's configured).

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm attribution.** Before doing anything to the device or GPO, confirm the symptom is actually predictive shielding and not an unrelated GPO replication issue, WMI filter problem, or genuine Safe Mode boot failure (BCD corruption, disk issue). Use Validation Step 4 first — if no Predictive Shielding incident/tag exists, exit this runbook and troubleshoot the underlying platform issue conventionally.

**Phase 2 — Assess the originating incident, not just the local symptom.** Once attribution is confirmed, open the full incident graph and attack story. Determine: is this incident still active, resolved-clean, or a confirmed false positive? This assessment — not the local device symptom — determines whether undoing the hardening is safe.

**Phase 3 — Coordinate before reversal.** Predictive shielding actions are, by design, applied without admin approval (that's the point — speed). Reversal should not follow the same unilateral pattern. Involve whoever owns incident response for an active/unresolved incident before undoing a hardening action, even if the specific device seems unaffected — a predicted-target device without confirmed compromise is still, by definition, a device Defender's graph model flagged as at risk.

**Phase 4 — Reverse via the documented mechanism only.** Undo exclusively through the Activities tab or Action center. Do not attempt device-local workarounds (registry edits to Safe Boot/BCD settings, forcing `gpupdate`, disabling the Sense service to "free" the device) — these either fail because the Defender sensor re-enforces the hardening, or generate new tamper-related detections that complicate the incident timeline.

**Phase 5 — Validate reversal and close the loop.** Confirm Policy status shows Removed in the Activities tab, re-run the relevant device-side check (`gpresult /h`, or a controlled Safe Mode boot test), and document the undo justification directly on the incident for audit purposes.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Full incident-to-resolution workflow for a predictive-shielding-hardened device</summary>

1. Confirm attribution via Activities tab + Advanced Hunting (Validation Steps 4-5).
2. Pull the full attack story from the incident graph — identify the originating alert, the compromised asset that triggered the prediction, and every other asset hardened as part of the same incident (a single incident often hardens multiple devices/accounts simultaneously — treat this as one coordinated response, not N separate tickets).
3. Engage security/incident-response ownership; do not act unilaterally on an active incident.
4. Once the incident is confirmed resolved (root cause remediated, no ongoing lateral-movement risk):
   - Undo each hardening action individually via Activities tab or bulk-undo via Action center.
   - Validate device-by-device (GPO application resumes; Safe Mode boot succeeds in a controlled test if genuinely needed).
5. Document the full incident-to-resolution timeline on the incident record, including which predictive actions were applied, when, and when/why each was reversed.
6. If the same device or account is repeatedly flagged across multiple unrelated incidents, treat that pattern itself as a signal — investigate why that asset keeps appearing as a predicted high-value target (over-privileged account, poorly segmented network position, outdated/vulnerable software) rather than only clearing each incident in isolation.

</details>

<details><summary>Playbook 2 — Emergency reversal for a business-critical device mid-incident</summary>

Use only when a hardened device is genuinely blocking a business-critical operation and the delay of full incident resolution is not acceptable — this is an exception path, not the default.

1. Escalate to the most senior available security/IR decision-maker; this decision should not be made by a help-desk-tier responder alone.
2. Document the specific business justification and the risk being accepted (the device was flagged as a likely attack-path target; reversing hardening before the incident is resolved reopens that path).
3. Undo the specific action only (not a bulk undo across the whole incident) — minimize the scope of risk re-exposure.
4. Apply compensating controls if available (e.g., temporary network isolation to a restricted VLAN, enhanced monitoring on that specific device) while the underlying incident investigation continues.
5. Revisit and potentially re-apply hardening once the emergency business need has passed, if the incident is still open.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects predictive shielding evidence for a specific device/incident for escalation.
.DESCRIPTION
    Read-only. Combines Microsoft Graph incident/subscription checks with guidance for the
    Advanced Hunting queries that must be run interactively in the Defender portal (no
    confirmed Graph/PowerShell surface exists for DisruptionAndResponseEvents as of this
    writing outside the portal's Advanced Hunting UI / Graph Security API runHuntingQuery).
#>
Connect-MgGraph -Scopes "SecurityEvents.Read.All","Organization.Read.All"

# 1 — License confirmation
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "DEFENDER|ATP|MDATP|EMSPREMIUM|SPE_E5|DFB" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# 2 — Recent security incidents (filter results for the Predictive Shielding tag manually,
#     since tag-level filtering is a portal UI feature, not a documented Graph query parameter)
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/incidents?`$top=25&`$orderby=createdDateTime desc"

# 3 — Advanced Hunting via Graph Security API (requires ThreatHunting.Read.All)
$huntingQuery = @{
    Query = 'DisruptionAndResponseEvents | where PolicyName in ("GpoPrevention","SafebootPrevention") | where Timestamp > ago(7d) | order by Timestamp desc'
} | ConvertTo-Json
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/security/runHuntingQuery" -Body $huntingQuery -ContentType "application/json"

Write-Host "Manual step required: cross-check the incident IDs above against security.microsoft.com > Incidents, filtered by the 'Predictive Shielding' tag, to confirm which incidents specifically triggered predictive actions (tag-based filtering is portal-only)." -ForegroundColor Yellow
```

---
## Command Cheat Sheet

| Purpose | Command / Location |
|---------|---------------------|
| Confirm MDE sensor health | `Get-Service Sense, WinDefend` |
| Confirm hardening applied locally (registry signal) | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Hardening"` |
| Force GPO reapplication after undo | `gpupdate /force` |
| Confirm applied GPOs | `gpresult /h C:\Temp\gpresult.html` |
| License check | `Get-MgSubscribedSku \| Where SkuPartNumber -match "DEFENDER\|ATP\|DFB"` |
| Filter incidents by predictive shielding | Portal: Incidents & alerts > Incidents > tag = Predictive Shielding |
| View disruption summary | Incident details > disruption summary card |
| View specific actions applied | Incident details > Activities tab > Response category |
| Advanced Hunting — active hardening policies | `DisruptionAndResponseEvents \| where PolicyName in ("GpoPrevention","SafebootPrevention") \| where IsPolicyOn` |
| Advanced Hunting — actual block events | `DisruptionAndResponseEvents \| where ReportType == "Prevented"` |
| Undo an action | Activities tab (select action > Undo) or Action center > Undo completed actions |
| Graph Security API — run hunting query | `POST /security/runHuntingQuery` (requires `ThreatHunting.Read.All`) |
| Graph Security API — list incidents | `GET /security/incidents` |

---
## 🎓 Learning Pointers

- Predictive shielding's core conceptual shift — acting on *predicted* future targets rather than *confirmed* compromised assets — is the same underlying idea behind Microsoft's broader push into exposure-graph-driven security (see also `Security/ExposureManagement/` in this repo for the standalone Security Exposure Management product, which builds and exposes a similar attack-path graph for manual analyst use rather than automated action).
- Read [Automatic attack disruption](https://learn.microsoft.com/en-us/defender-xdr/automatic-attack-disruption) in full before this topic if the confidence-scoring/AI-decision-model concepts are new — predictive shielding explicitly inherits that model rather than defining its own.
- The [DisruptionAndResponseEvents table schema reference](https://learn.microsoft.com/en-us/defender-xdr/advanced-hunting-disruptionandresponseevents-table) is worth bookmarking directly — it's the single most reliable, portal-independent evidence source for this entire topic.
- Because this is a **Preview** capability, treat the specific action list (currently: Contain User, GPO Hardening, SafeBoot Hardening) as a snapshot, not a ceiling — re-check [Predictive shielding in Microsoft Defender](https://learn.microsoft.com/en-us/defender-xdr/shield-predict-threats) periodically for new action types as the feature matures toward GA.
- Deploying Microsoft Defender for Identity alongside MDE is explicitly called out by Microsoft as materially improving prediction accuracy (adds AD/username/group-membership enrichment) — a genuine, actionable upsell/architecture conversation for MSP clients running MDE-only, not just a nice-to-have.
- Microsoft's own published case study — [How predictive shielding stopped GPO-based ransomware before it started](https://www.microsoft.com/en-us/security/blog/2026/03/23/case-study-predictive-shielding-defender-stopped-gpo-based-ransomware-before-started/) — is useful client-facing material for explaining *why* a device was hardened when nothing was locally wrong with it (700 devices proactively hardened against malicious GPO propagation in that real-world incident).
