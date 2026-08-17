# Defender for Business — Hotfix Runbook (Mode B: Ops)
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

Defender for Business (DfB) runs on the **same SENSE sensor and same security.microsoft.com portal** as full Defender for Endpoint (MDE) — it is a licensing/policy tier, not a separate agent. If a ticket doesn't fit the patterns below, check `MDE-Onboarding-B.md` first; the sensor-level triage there applies unchanged.

Run on the affected device (elevated PowerShell):

```powershell
# 1 — Confirm this tenant is actually on DfB (not full MDE P1/P2/E5)
# Portal: security.microsoft.com > Settings > Endpoints > Licenses
# No reliable local registry flag distinguishes DfB from MDE — the sensor is identical.

# 2 — Onboarding + sensor state (same as full MDE)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue |
    Select-Object OnboardingState, OrgId, SenseIsRunning
Get-Service "Sense" | Select-Object Name, Status, StartType

# 3 — AV mode: passive (3rd-party AV present) vs active vs EDR block mode
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, IsTamperProtected

# 4 — Which policy is actually applying — default (auto-created) or custom?
Get-MpPreference | Select-Object -Property * | Format-List `
    AttackSurfaceReductionRules_Ids, EnableNetworkProtection, PUAProtection

# 5 — Assigned license count vs. seat cap (300) — run against tenant, needs Graph
Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
Get-MgSubscribedSku | Where-Object SkuPartNumber -like "*DEFENDER_BUSINESS*" |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `OnboardingState = 0` or Sense stopped | Same root causes as full MDE | `MDE-Onboarding-B.md` |
| `AMRunningMode = Passive`, no blocking despite alerts | 3rd-party AV is primary — DfB EDR telemetry works but no real-time block unless EDR in Block Mode is on | Fix 1 |
| Device shows two conflicting policies in portal (Default + custom) | Auto-created default policy wasn't disabled before assigning a custom one | Fix 2 |
| Advanced Hunting / custom detection rules missing from portal nav | Not a bug — DfB's Advanced Hunting is scoped down, no custom KQL query builder for detections the way P2 has | Fix 3 |
| `ConsumedUnits` at or over `Total`, new devices won't onboard | Seat cap (300 licenses) reached | Fix 4 |
| Client outgrew SMB size, wants Live Response / full Advanced Hunting / Sentinel correlation | Feature gap, not a fault — needs plan upgrade | Fix 5 |
| Conditional Access device-risk signal not evaluating | Device isn't Entra-joined + Intune-managed — GPO-only devices can't feed CA risk signals | Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true for Defender for Business to protect a device</summary>

```
[Tenant: Defender for Business standalone SKU OR Microsoft 365 Business Premium]
    └── [Seat available: ConsumedUnits < 300-seat cap]
            └── [License assigned to user (up to 5 devices/user)]
                    └── [Device onboarded — same SENSE mechanism as full MDE:
                         Intune auto-onboarding | GPO | local script | Arc for servers]
                            └── [SENSE service: Running, Automatic]
                                    └── [Default policies applied at onboarding:
                                         Next-gen protection + Firewall protection]
                                            ├── [Admin may override with custom policy —
                                            │    must disable/deprioritize default first]
                                            └── [Real-time block requires Defender AV
                                                 as PRIMARY (Active mode), or EDR in
                                                 Block Mode if 3rd-party AV is primary]
```

**Portal/RBAC note:** DfB uses the same Unified RBAC / Security Administrator roles as full MDE — no separate DfB-specific role. See `MDE-Onboarding-A.md` for the shared onboarding architecture.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm license tier before troubleshooting further**
Portal: **security.microsoft.com → Settings → Endpoints → Licenses**, or:
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "DEFENDER_BUSINESS|SPB" } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
```
`DEFENDER_BUSINESS` = standalone. `SPB` (Microsoft 365 Business Premium) includes DfB bundled. If neither is present, this isn't a DfB tenant — stop and re-scope to `MDE-Onboarding-B.md`.

**Step 2 — Sensor health (identical to full MDE)**
```powershell
Get-Service Sense | Select-Object Status, StartType
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
```
See `MDE-Onboarding-B.md` Diagnosis steps if this fails — the sensor layer has no DfB-specific variant.

**Step 3 — Identify which policy actually applies**
Portal: **Endpoints → Configuration management → Device configuration**. Look for **Default policies** (auto-named "Default policy — DfB Next generation protection" / "Default policy — DfB Firewall") alongside any custom policy. Both target "All devices" by default, which is the #1 source of confusing behaviour — policy precedence follows normal Intune/MDE conflict rules (more specific scope wins; check `Intune/Troubleshooting/Policy-Conflict-A.md`).

**Step 4 — Check AV running mode vs. expected protection**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled
```
`Passive` is expected and correct when a 3rd-party AV is the registered primary. To get real-time blocking back under a 3rd-party AV, EDR in Block Mode must be explicitly enabled (portal-only toggle, Endpoints → Advanced features).

**Step 5 — Confirm seat/device count against the 300-user cap**
```powershell
Get-MgSubscribedSku | Where-Object SkuPartNumber -like "*DEFENDER_BUSINESS*" |
    Select-Object @{N="Used";E={$_.ConsumedUnits}}, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```
Each license covers up to 5 devices for that user — a stuck onboarding on a 6th device for the same user is a device-cap issue, not a licensing outage.

---

## Common Fix Paths

<details>
<summary>Fix 1 — No real-time blocking with 3rd-party AV present</summary>

```powershell
# Confirm passive mode is the cause, not a broken sensor
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled
```
If `AMRunningMode = Passive` and a 3rd-party AV is intentionally primary:
1. Portal → **Settings → Endpoints → Advanced features → EDR in block mode → On**
2. Wait up to 30 minutes for policy propagation
3. Re-check: `Get-MpComputerStatus | Select AMRunningMode` — mode stays Passive, but block actions now fire from EDR telemetry even though Defender AV isn't the on-access scanner

**Rollback:** turn EDR in block mode off if it causes duplicate-block noise with the 3rd-party product's own EDR (rare, but happens with overlapping vendor EDR stacks).
</details>

<details>
<summary>Fix 2 — Default policy conflicting with a custom policy</summary>

DfB auto-creates two **Default policies** at first onboarding: *Next generation protection* and *Firewall protection*, scoped to "All devices."

1. Portal → **Endpoints → Configuration management → Device configuration**
2. Open the Default policy → note its settings
3. If you want a custom policy to win: either (a) narrow the Default policy's scope to exclude the target device group, or (b) edit the Default policy directly rather than layering a second policy on the same "All devices" scope — DfB's simplified model does not use Intune-style explicit conflict-winner ranking the way full Intune policies do
4. Re-check applied config on device:
```powershell
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, PUAProtection, CloudBlockLevel
```

**Rollback:** Default policies can be edited but not deleted — restore original recommended values from `learn.microsoft.com/defender-business/mdb-view-edit-create-policies` if a change causes regressions.
</details>

<details>
<summary>Fix 3 — Advanced Hunting / custom detection rules missing</summary>

This is expected DfB behaviour, not a fault. DfB includes Automated Investigation & Response and a scoped-down device-timeline view, but full custom-KQL Advanced Hunting and custom detection rule authoring are Defender for Endpoint P2 / Microsoft 365 E5 features.

**No fix within DfB.** Document as a licensing-tier limitation. If the client needs custom hunting queries, this is a licensing conversation (see Fix 5), not a configuration one.
</details>

<details>
<summary>Fix 4 — Seat cap reached, new devices won't onboard</summary>

```powershell
Get-MgSubscribedSku | Where-Object SkuPartNumber -like "*DEFENDER_BUSINESS*" |
    Select-Object ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```
If `ConsumedUnits -ge Total`:
1. Free a seat by removing DfB license from an unassigned/offboarded user, **or**
2. Purchase additional seats (up to the 300-user program cap — beyond that, DfB itself is not purchasable and the tenant must move to Defender for Endpoint P1/P2)
3. Re-run onboarding once a seat is freed/added — no sensor-side change needed, licensing is checked at the cloud service, not locally

**Rollback:** none needed — this is additive.
</details>

<details>
<summary>Fix 5 — Client outgrew DfB, needs full MDE feature set</summary>

There is no in-place "upgrade toggle." Migration path:
1. Confirm target: Defender for Endpoint P1 (AV/ASR/manual response, no full EDR) or P2 (full EDR, Advanced Hunting, Live Response, AIR) or Microsoft 365 E5
2. Purchase and assign new licenses; **do not remove DfB licenses until the new SKU is confirmed active** — this avoids a protection gap
3. No re-onboarding required — same SENSE sensor, the cloud service picks up the new license tier and unlocks P2 UI (Advanced Hunting, Live Response) automatically, typically within a few hours
4. Review Default policies — once on P2, consider migrating from DfB's simplified default-policy model to full custom Intune-delivered Endpoint Security policies for finer control
5. Reference: `learn.microsoft.com/defender-endpoint/switch-to-mde-overview`

**Rollback:** not applicable — this is a one-way licensing upgrade path.
</details>

<details>
<summary>Fix 6 — Conditional Access device-risk signal not evaluating</summary>

DfB's EDR risk signal only feeds Conditional Access for devices that are **Entra ID joined or hybrid joined AND Intune-managed**. GPO-only onboarded devices have a working sensor but do not participate in CA device-risk policies.

```powershell
dsregcmd /status | Select-String -Pattern "(AzureAdJoined|EnterpriseJoined|DomainJoined|MDMUrl)"
```
If `AzureAdJoined: NO` and `MDMUrl` empty: device needs Entra join + Intune enrollment before CA risk-based policies apply. See `EntraID/Troubleshooting/HybridJoin-B.md` and `Security/ConditionalAccess/CA-Design-A.md`.

**Rollback:** not applicable.
</details>

---

## Escalation Evidence

```
=== DEFENDER FOR BUSINESS ESCALATION ===
Date/Time      :
Engineer       :
Ticket         :

Tenant SKU     : (DEFENDER_BUSINESS standalone / SPB bundled — confirm via Get-MgSubscribedSku)
Seats Used/Cap : (ConsumedUnits / PrepaidUnits.Enabled)

Device Name    :
OnboardingState: (registry value)
SenseStatus    : (Running / Stopped / Disabled)
AMRunningMode  : (Active / Passive)
EDR Block Mode : (On / Off — portal: Advanced features)

Policy Conflict: (Default policy present? Custom policy present? Scope overlap?)
CA Device State: (Entra joined? Intune enrolled? — dsregcmd /status)

Steps Attempted:
1.
2.
3.

Expected behaviour :
Actual behaviour   :
```

---

## 🎓 Learning Pointers

- **DfB is a policy/licensing tier on top of MDE, not a separate agent.** Every sensor-level fix in `MDE-Onboarding-B.md` applies unchanged — don't duplicate triage, just confirm the license tier first. [Defender for Business overview](https://learn.microsoft.com/en-us/defender-business/mdb-overview)
- **Default policies are silent and easy to forget.** They're auto-created the moment the first device onboards, target "All devices," and don't show up unless an admin goes looking in Configuration management — the #1 source of "why is this device configured differently than I set it" tickets. [View, edit, create policies](https://learn.microsoft.com/en-us/defender-business/mdb-view-edit-create-policies)
- **300 seats is a hard program cap, not just a soft licensing limit** — once a tenant needs more, DfB itself stops being purchasable and the path is Defender for Endpoint P1/P2 or Microsoft 365 E3/E5, not "buy more DfB." [Get Defender for Business](https://learn.microsoft.com/en-us/defender-business/get-defender-business)
- **Advanced Hunting gaps are licensing, not bugs.** Don't spend time troubleshooting a missing custom-KQL query builder in a DfB tenant — it's scoped out by design at this tier.
- **CA risk-based policies need Entra join + Intune enrollment**, independent of whether the EDR sensor itself is healthy — a fully-protected, fully-onboarded GPO-managed device still won't participate in device-risk Conditional Access.
- **Migrating tiers is additive, not a cutover** — assign new licenses before removing old ones to avoid a protection gap; the sensor doesn't need to be touched. [Switch to Microsoft Defender for Endpoint](https://learn.microsoft.com/en-us/defender-endpoint/switch-to-mde-overview)
