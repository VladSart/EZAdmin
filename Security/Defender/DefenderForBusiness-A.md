# Microsoft Defender for Business — Reference Runbook (Mode A: Deep Dive)
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
- Defender for Business (DfB) as a licensing/policy tier for orgs up to 300 users
- Standalone DfB SKU and DfB-as-bundled-in-Microsoft 365 Business Premium
- The simplified configuration model (default policies, wizard onboarding)
- Feature boundary between DfB and Defender for Endpoint (MDE) P1/P2
- Migration path from DfB to full MDE P1/P2/E5 licensing

**Does not cover:**
- SENSE sensor mechanics, onboarding transport methods, event log troubleshooting — identical to full MDE, see `MDE-Onboarding-A.md`
- ASR rule tuning, Tamper Protection, WDAC — see their respective runbooks in this folder; DfB uses the same engines
- Defender for Cloud (Azure resource CSPM) — unrelated product despite the name similarity, see `DefenderForCloud-A.md`

**Assumptions:**
- Reader already understands full MDE onboarding architecture (`MDE-Onboarding-A.md`)
- Admin has Microsoft 365 Defender portal access (security.microsoft.com) with Security Administrator or Global Administrator role
- Tenant is licensed with either the standalone "Microsoft Defender for Business" SKU or Microsoft 365 Business Premium

---
## How It Works

<details><summary>Full architecture — DfB as a licensing tier over the shared MDE stack</summary>

**The core insight: there is no separate "Defender for Business agent."**

Defender for Business is not a fork of Defender for Endpoint. It is the exact same product — same SENSE Windows service, same `security.microsoft.com` portal, same underlying detection/prevention engines (Defender AV, ASR, Network Protection, Firewall, EDR telemetry pipeline) — gated by license SKU into a simplified operating mode aimed at organizations without a dedicated security team.

**What licensing changes, concretely:**

1. **Portal presentation.** The DfB tenant sees a streamlined left-nav in security.microsoft.com — a simplified setup wizard runs on first login, and several P2-only surfaces (custom Advanced Hunting query editor, custom detection rules, Live Response console) are hidden or reduced.

2. **Default policies, auto-created.** Unlike full MDE where an admin builds every Endpoint Security policy from scratch in Intune, DfB automatically provisions two policies at first device onboarding:
   - **Default policy — Next generation protection** (Defender AV settings: cloud-delivered protection, PUA protection, scan settings)
   - **Default policy — Firewall protection** (inbound/outbound rule baseline)

   Both are scoped to "All devices" using Microsoft's recommended security baseline. This is the single biggest structural difference from full MDE, where no policy exists until an admin creates one.

3. **Seat-capped licensing (300 users, 5 devices/user).** This is enforced at the Microsoft 365 admin/licensing layer, not the sensor — `Get-MgSubscribedSku` shows consumed vs. total, and the cloud service silently stops accepting new onboarding once the cap is hit. There is no local registry flag or SENSE behavior difference for a device that's over-cap; the failure surfaces as "device never appears in portal" even though the sensor itself is healthy.

4. **Feature-gated console, not feature-gated sensor.** EDR telemetry still streams from every onboarded device — the *sensor* collects the same signal regardless of license. What's restricted is which analyst *tools* can query that telemetry: full custom KQL Advanced Hunting, custom detection rule authoring, and Live Response interactive sessions are P2/E5-gated UI features layered on top of identical raw telemetry.

**Onboarding path (identical to full MDE):**
```
DfB tenant → Intune auto-onboarding (enrolled devices) | GPO | local script | mobile app | Azure Arc (servers)
    └── SENSE service provisioned, writes registry status blob
            └── Device authenticates to Defender cloud
                    └── Cloud checks license availability (seat cap) before accepting telemetry stream long-term
                            └── Default policies (Next-gen protection + Firewall) auto-apply on first successful onboarding
```

</details>

---
## Dependency Stack

```
Microsoft 365 tenant
  └── License: Defender for Business (standalone) OR Microsoft 365 Business Premium (bundled)
        └── Seat available (ConsumedUnits < 300-user program cap)
              └── User assigned license (covers up to 5 devices for that user)
                    └── Device onboarding — SAME mechanism as full MDE:
                    │     Intune auto-onboarding | GPO | local script | Arc (servers)
                    │           └── SENSE service running, registry blob populated
                    │                 └── First successful cloud heartbeat
                    │                       └── Default policies auto-created & applied
                    │                             ("Next gen protection" + "Firewall protection",
                    │                              scoped to All devices)
                    │                                   ├── Admin may layer/override with
                    │                                   │   custom Configuration management policy
                    │                                   └── Real-time protection depends on
                    │                                       AV running mode (Active vs Passive
                    │                                       under 3rd-party AV) + EDR Block Mode
                    └── Portal feature surface gated by SAME license check:
                          Advanced Hunting (scoped), Live Response (absent), AIR (present,
                          simplified orchestration), custom detections (absent)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| New device never appears in portal, sensor healthy locally | Seat/device cap reached at license layer | `Get-MgSubscribedSku` ConsumedUnits vs Total |
| Device has settings admin didn't configure | Auto-created Default policy applied at onboarding | Configuration management → Device configuration |
| Custom policy changes don't seem to take effect | Default policy still scoped to "All devices," overlapping custom policy | Compare scope of both policies |
| "Where is Advanced Hunting / custom detections?" | DfB's Advanced Hunting is a scoped-down view — full KQL editor and detection rule authoring are P2/E5 only | License tier (`Get-MgSubscribedSku`) |
| No real-time block despite alerts firing | Defender AV in Passive mode (3rd-party AV primary) and EDR in Block Mode not enabled | `Get-MpComputerStatus` AMRunningMode |
| CA policy not evaluating device risk | Device is GPO-managed only, not Entra-joined + Intune-enrolled | `dsregcmd /status` |
| Client asks "can we just buy more DfB seats" past 300 users | Program cap is hard — DfB is not purchasable beyond 300 seats | Portal licensing page / partner center |
| Portal shows different nav after a license change | License tier re-evaluated by cloud service, portal surface updates automatically (hours, not immediate) | Re-check `Get-MgSubscribedSku`, wait, hard-refresh portal |

---
## Validation Steps

**Step 1 — Confirm the SKU and consumption**
```powershell
Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match "DEFENDER_BUSINESS|SPB|SPE_E3|SPE_E5" } |
    Select-Object SkuPartNumber, ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}
```
Expected for a DfB tenant: `DEFENDER_BUSINESS` (standalone) or `SPB` (Business Premium bundle) present, `ConsumedUnits <= Total <= 300`.
Bad: neither SKU present but tickets reference DfB features — likely a scoping/terminology mismatch, confirm with the client which product they mean.

**Step 2 — Confirm sensor health (shared with full MDE)**
```powershell
Get-Service Sense | Select-Object Status, StartType
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OnboardingState, OrgId, SenseIsRunning
```
Identical expected/bad values to `MDE-Onboarding-A.md` Validation Step 2 — no DfB-specific variant exists at this layer.

**Step 3 — Enumerate applied policies**
Portal: **Endpoints → Configuration management → Device configuration**. List every policy targeting the affected device's group, note precedence order. DfB's Default policies do not use Intune's explicit "conflict winner by policy order" resolution — they resolve by scope specificity, same as documented in `Intune/Troubleshooting/Policy-Conflict-A.md`.

**Step 4 — Confirm AV running mode and EDR Block Mode state**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled
```
Cross-reference portal: **Settings → Endpoints → Advanced features → EDR in block mode**. `Passive` mode with Block Mode **Off** means no real-time blocking from Defender even though EDR telemetry keeps flowing — expected only if the client understands and accepts this tradeoff.

**Step 5 — Confirm Entra join + Intune enrollment for CA-dependent scenarios**
```powershell
dsregcmd /status | Select-String -Pattern "(AzureAdJoined|EnterpriseJoined|DomainJoined|MDMUrl)"
```
Required for device-risk-based Conditional Access; not required for baseline AV/EDR protection.

---
## Troubleshooting Steps (by phase)

### Phase 1: Licensing & Seat Availability
1. `Get-MgSubscribedSku` — confirm SKU present and seats available
2. Portal: **Billing → Your products** — cross-check against Graph output for drift (recent purchases can lag Graph replication by a few minutes)
3. If seats exhausted: free an unused license or purchase more, up to the 300-seat program ceiling

### Phase 2: Sensor & Onboarding
1. Same phase-by-phase flow as `MDE-Onboarding-A.md` Troubleshooting Steps — no DfB divergence
2. Only DfB-specific addition: after resolving a sensor issue, re-check whether Default policies applied correctly post-onboarding (they only fire once, at first successful onboarding — a device that was previously onboarded and re-onboarded after an offboard/onboard cycle may not re-trigger default policy assignment; assign manually if missing)

### Phase 3: Policy Resolution
1. List all policies scoped to the device/group from the portal
2. Identify overlapping scope between Default and custom policies
3. Narrow Default policy scope or edit it directly — DfB's simplified model favors editing the single Default policy over stacking multiple competing policies
4. Validate applied config locally:
```powershell
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, PUAProtection, CloudBlockLevel, `
    EnableNetworkProtection, DisableRealtimeMonitoring
```

### Phase 4: Feature-Boundary Questions
1. Confirm license tier before troubleshooting a "missing feature" ticket — most "Advanced Hunting is broken" tickets are licensing-tier expectations mismatches, not defects
2. If the org has genuinely outgrown DfB (>300 users, or needs Live Response/custom detections/Sentinel correlation), route to Remediation Playbook 2 (migration), not further DfB troubleshooting

---
## Remediation Playbooks

<details><summary>Playbook 1 — Reconcile Default policy conflicts cleanly</summary>

```powershell
# Step 1: Enumerate current local effective policy
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions, `
    PUAProtection, CloudBlockLevel, EnableNetworkProtection

# Step 2: In portal, open both Default policies and any custom policy
# Endpoints > Configuration management > Device configuration
# Note exact scope (device group) of each

# Step 3: Decide resolution strategy:
#   (a) Edit the Default policy directly to match desired baseline (simplest, recommended for DfB)
#   (b) Narrow Default policy scope to exclude the group targeted by the custom policy
# Avoid creating a third overlapping "All devices" policy — this compounds the conflict

# Step 4: After portal change, force a policy sync on the device (or wait for next check-in cycle)
# Step 5: Re-validate
Get-MpPreference | Select-Object AttackSurfaceReductionRules_Ids, PUAProtection, CloudBlockLevel
```

**Rollback:** Default policies cannot be deleted, only edited — revert values to Microsoft's documented recommended baseline if a change causes regressions. See `learn.microsoft.com/defender-business/mdb-view-edit-create-policies`.
</details>

<details><summary>Playbook 2 — Migrate a growing client from DfB to Defender for Endpoint P2 / E5</summary>

```powershell
# Step 1: Confirm current DfB consumption and target SKU availability
Get-MgSubscribedSku | Where-Object SkuPartNumber -match "DEFENDER_BUSINESS|MDATP|SPE_E5"

# Step 2: Purchase/assign new licenses (P1, P2, or E5 add-on) to affected users
# Do NOT remove DfB licenses yet — overlap is safe and prevents a protection gap
Set-MgUserLicense -UserId "<user@domain.com>" -AddLicenses @{SkuId="<newSkuId>"} -RemoveLicenses @()

# Step 3: Wait for cloud-side license re-evaluation (observed: minutes to a few hours)
# Confirm new portal surfaces appear: Advanced Hunting full editor, Live Response console

# Step 4: Once confirmed stable for all target users, remove DfB licenses
Set-MgUserLicense -UserId "<user@domain.com>" -AddLicenses @() -RemoveLicenses @("<dfbSkuId>")

# Step 5: Review and rebuild Endpoint Security policy in Intune to replace DfB's
# simplified Default policies with granular custom policies now that P2 unlocks
# finer-grained ASR/EDR controls
```

**Rollback:** Re-assign DfB licenses; sensor and telemetry are unaffected by either direction of this migration — no re-onboarding required.
</details>

<details><summary>Playbook 3 — Diagnose a "device won't onboard" ticket that turns out to be a seat cap</summary>

```powershell
# Step 1: Confirm sensor-side onboarding actually failed vs. just not visible in portal
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
    Select-Object OnboardingState, SenseIsRunning
# If OnboardingState = 1 and SenseIsRunning = 1, the sensor believes it succeeded —
# a "not appearing in portal" symptom with a healthy local sensor points to licensing, not sensor failure

# Step 2: Check seat consumption
Get-MgSubscribedSku | Where-Object SkuPartNumber -like "*DEFENDER_BUSINESS*" |
    Select-Object ConsumedUnits, @{N="Total";E={$_.PrepaidUnits.Enabled}}

# Step 3: If at cap, free a seat (remove from an offboarded/inactive user) or purchase more
Get-MgUser -Filter "accountEnabled eq false" -Property Id,DisplayName,AssignedLicenses |
    Where-Object { $_.AssignedLicenses.SkuId -contains "<dfbSkuId>" }

# Step 4: Re-check portal after freeing/adding a seat — no device-side action needed
```

**Rollback:** not applicable — additive fix.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Defender for Business diagnostic evidence for escalation
.NOTES     Run device-side portion as Administrator; run Graph portion with Organization.Read.All
#>

$reportPath = "C:\Temp\DfB-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# Device sensor state (same as MDE evidence pack)
Get-Service Sense -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType |
    ConvertTo-Json | Out-File "$reportPath\01-SenseService.json"

$mdePath = "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
if (Test-Path $mdePath) {
    Get-ItemProperty $mdePath | ConvertTo-Json | Out-File "$reportPath\02-OnboardingRegistry.json"
}

Get-MpComputerStatus -ErrorAction SilentlyContinue |
    Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, IsTamperProtected |
    ConvertTo-Json | Out-File "$reportPath\03-DefenderStatus.json"

Get-MpPreference -ErrorAction SilentlyContinue |
    Select-Object AttackSurfaceReductionRules_Ids, PUAProtection, CloudBlockLevel, EnableNetworkProtection |
    ConvertTo-Json | Out-File "$reportPath\04-EffectivePolicy.json"

dsregcmd /status | Out-File "$reportPath\05-DsregcmdStatus.txt"

# Tenant licensing (run separately, requires Graph auth)
# Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
# Get-MgSubscribedSku | Where-Object SkuPartNumber -match "DEFENDER_BUSINESS|SPB" |
#     ConvertTo-Json | Out-File "$reportPath\06-LicenseState.json"

$zipPath = "C:\Temp\DfB-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').zip"
Compress-Archive -Path $reportPath -DestinationPath $zipPath -Force
Write-Host "Evidence collected: $zipPath" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Purpose | Command |
|---------|---------|
| Confirm DfB/SPB license present | `Get-MgSubscribedSku \| Where SkuPartNumber -match "DEFENDER_BUSINESS\|SPB"` |
| Check seat consumption | `Get-MgSubscribedSku \| Select ConsumedUnits, PrepaidUnits` |
| Check sensor state | `Get-Service Sense \| Select Status, StartType` |
| Check onboarding registry | `Get-ItemProperty "HKLM:\...\Windows Advanced Threat Protection\Status"` |
| Check AV running mode | `Get-MpComputerStatus \| Select AMRunningMode, AntivirusEnabled` |
| Check effective ASR/AV policy | `Get-MpPreference \| Select AttackSurfaceReductionRules_Ids, PUAProtection` |
| Check Entra join / Intune enrollment | `dsregcmd /status` |
| Assign new SKU (migration) | `Set-MgUserLicense -UserId <upn> -AddLicenses @{SkuId=<id>} -RemoveLicenses @()` |
| Remove old SKU (migration, after validation) | `Set-MgUserLicense -UserId <upn> -RemoveLicenses @(<dfbSkuId>)` |
| Find unassigned/offboarded license holders | `Get-MgUser -Filter "accountEnabled eq false" -Property AssignedLicenses` |

---
## 🎓 Learning Pointers

- **DfB and MDE are one product with a license gate, not two products.** Every architectural fact about SENSE, onboarding transports, and telemetry in `MDE-Onboarding-A.md` applies to DfB unchanged — the only genuinely new surface area is the Default policy auto-provisioning and the feature-scoped portal UI. [Defender for Business overview](https://learn.microsoft.com/en-us/defender-business/mdb-overview)
- **The 300-seat cap is enforced in the cloud, invisible locally.** A device that fails to appear in the portal despite a perfectly healthy `SenseIsRunning = 1` sensor is very often a licensing-cap problem, not a sensor problem — check `Get-MgSubscribedSku` before spending time on device-level diagnostics.
- **Default policies are the most common source of "unexpected config" tickets** in DfB tenants because they're silent and automatic — unlike full Intune-managed MDE where nothing applies until an admin builds a policy. [View, edit, and create policies](https://learn.microsoft.com/en-us/defender-business/mdb-view-edit-create-policies)
- **Feature gaps (Advanced Hunting scope, no Live Response, no custom detections) are licensing decisions, not defects** — confirm SKU before troubleshooting a "missing feature."
- **Migration to full MDE is additive and reversible until DfB licenses are removed** — assign the new SKU first, validate, then remove DfB to avoid a protection gap. [Switch to Microsoft Defender for Endpoint](https://learn.microsoft.com/en-us/defender-endpoint/switch-to-mde-overview)
- **CA device-risk integration has its own prerequisite chain** (Entra join + Intune enrollment) independent of EDR health — a fully protected GPO-only device still won't participate in risk-based Conditional Access. See `Security/ConditionalAccess/CA-Design-A.md`.
