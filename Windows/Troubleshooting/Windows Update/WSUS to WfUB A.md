# WSUS to Windows Update for Business — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Windows 10 22H2 and Windows 11 (23H2/24H2/25H2) clients scanning against on-prem WSUS
- Migration path from WSUS-managed update scanning to Windows Update for Business (WUfB) via Intune update rings and the Update Settings Catalog
- Feature update pinning behaviour (`TargetReleaseVersion` / `TargetReleaseVersionInfo`) and how it interacts with both WSUS and WUfB
- Devices that are Entra-joined, hybrid-joined, or domain-joined with co-management/Intune enrollment
- "Dual scan" behaviour where a device configured for WSUS still reaches out to Microsoft Update for some categories

**Out of scope:**
- Configuration Manager (ConfigMgr) Software Update Point (SUP) design — this covers client-side WSUS pointer only, not SUP server administration
- WSUS server health (SUSDB maintenance, IIS tuning, content store cleanup) — see `WSUS-Server-A.md` for the dedicated server-side runbook
- Autopatch (Windows Autopatch has its own ring/deployment model layered on top of WUfB — related but distinct)
- Driver update policy specifics (covered under a separate Feature Updates / Driver Management runbook)

**Assumptions:**
- You have Intune admin access (Global Admin, Intune Administrator, or Policy and Profile Manager role) to inspect/modify update ring policy
- You have local admin on the affected client for registry/service diagnostics
- The organization's end goal is to decommission or reduce reliance on WSUS in favour of cloud-managed WUfB

---
## How It Works

<details><summary>Full architecture — scan sources, policy precedence, and the migration model</summary>

### Two Competing Scan Sources

Windows Update client-side scanning has exactly one "active" scan source at a time, controlled by policy:

```
Windows Update Agent (wuauserv)
        │
        ├── Source A: WSUS (on-prem)
        │     Registry: UseWUServer=1, WUServer=<url>, WUStatusServer=<url>
        │     Scans against: internal WSUS SUSDB catalog (subset of MS catalog,
        │                     admin-approved updates only)
        │     Reporting: status reported back to WSUS server
        │
        └── Source B: Windows Update for Business (cloud)
              Registry: UseWUServer=0 (or absent), no WUServer
              Scans against: Microsoft Update service directly
              Reporting: status reported to Windows Update for Business
                          deployment service / Intune device compliance
```

These are mutually exclusive per the classic model. A device is either "pointed at WSUS" or "using WUfB" — it does not blend catalogs. The one nuance is **dual scan**: even with `UseWUServer=1`, certain update categories (notably some driver and Microsoft Store updates) may still reach out to Windows Update directly unless explicitly disabled via `DisableDualScan`.

### Policy Precedence: Who Wins When Multiple Sources Configure This

```
Priority (highest wins, last-writer among same tier is unpredictable — avoid conflicts):

1. MDM (Intune) — Update rings / Windows Update Settings Catalog
   └── Delivered via OMA-URI: ./Vendor/MSFT/Policy/Config/Update/*
2. Domain Group Policy (GPO)
   └── Computer Configuration > Administrative Templates > Windows Components
       > Windows Update
3. Local Group Policy (gpedit.msc) — same registry keys as domain GPO
4. Local registry edit (manual reg add)
   └── Will be REVERTED on next policy refresh if MDM or GPO also configures
       the same value
```

If a device is **co-managed** (ConfigMgr + Intune) or receives **both domain GPO and Intune policy** (hybrid-joined device processing both), whichever wrote the registry value most recently at policy refresh generally "wins" until the next refresh cycle overwrites it again — this produces the classic symptom of "I changed it and it changed back." The fix is always to find and correct the *authoritative* policy source, not the registry value.

### The Registry Keys That Actually Matter

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
  ├── WUServer              (REG_SZ)   — WSUS server URL, e.g. http://wsus01:8530
  ├── WUStatusServer        (REG_SZ)   — WSUS reporting URL (usually same as WUServer)
  ├── TargetReleaseVersion  (REG_DWORD)— 1 = feature update version is pinned
  ├── TargetReleaseVersionInfo (REG_SZ)— e.g. "23H2" — the pinned target
  └── DisableDualScan       (REG_DWORD)— 1 = force WSUS-only, block MU fallback

HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
  ├── UseWUServer           (REG_DWORD)— 1 = WSUS active, 0/absent = WUfB/MU active
  ├── NoAutoUpdate          (REG_DWORD)— 1 = disables automatic updates entirely
  └── AUOptions             (REG_DWORD)— legacy notification/install behaviour setting
```

`UseWUServer` is the master switch. Both `AU\UseWUServer` and the parent key's `WUServer`/`WUStatusServer` must be considered together — inconsistent state (e.g. `UseWUServer=1` but no `WUServer`) causes scan failures (0x8024402C and similar).

### Migration Model: WSUS → WUfB via Intune

The supported migration path is **not** a single toggle — it is a sequenced policy change:

```
Step 1: Build the target state in Intune BEFORE touching WSUS pointer
  └── Create/verify Update Ring or Update Settings Catalog profile:
        - Feature update deferral / target version (if pinning desired)
        - Quality update deferral
        - Servicing channel (General Availability)
        - Deadlines and grace periods (Update Compliance Deadlines)
  └── Assign to a PILOT group first — never all devices at once

Step 2: Remove the WSUS-pointing policy for the pilot group
  └── If GPO: unlink/remove "Specify intranet Microsoft update service location"
      for that OU/security-filtered group
  └── If Intune: ensure no competing profile sets UseWUServer=1

Step 3: Allow policy convergence (can take up to 8, 24, or the configured
        MDM refresh interval — force with Company Portal Sync or
        Invoke-CimMethod TriggerSync)

Step 4: Validate — UseWUServer should read 0/absent, WUServer should be
        empty, and a manual scan should show it querying against
        Microsoft Update / WUfB deployment service (not WSUS)

Step 5: Widen the ring — Broad, then full production, monitoring compliance
        and feature update rollout percentage in Intune each phase
```

### Feature Update Pinning Interaction

`TargetReleaseVersion` + `TargetReleaseVersionInfo` is a **separate control plane** from the WSUS/WUfB scan source toggle. Switching WSUS→WUfB does **not** automatically move a device to a newer feature version if a pin is set. This is the #1 cause of "I switched to WUfB but it's still stuck on 22H2" tickets — the pin, not the scan source, is holding the version.

</details>

---
## Dependency Stack

```
Policy Authority (top of stack — must be correct first)
  ├── Intune Update Ring / Settings Catalog profile (MDM channel)
  └── Domain or Local GPO (Windows Update ADMX templates)
        │
        ▼
Registry State (client)
  ├── UseWUServer (AU key) — WSUS on/off switch
  ├── WUServer / WUStatusServer — WSUS endpoint (must be absent for WUfB)
  ├── TargetReleaseVersion / TargetReleaseVersionInfo — feature pin
  └── DisableDualScan — forces WSUS-only if set
        │
        ▼
Windows Update Client Services
  ├── wuauserv (Windows Update)
  ├── usosvc (Update Orchestrator Service)
  ├── bits (Background Intelligent Transfer Service)
  └── cryptsvc (Cryptographic Services — signature validation)
        │
        ▼
Scan Source Reachability
  ├── If WSUS still configured: WSUS server URL must be reachable (TCP, usually 8530/8531)
  └── If WUfB: Windows Update / Delivery Optimization endpoints reachable
      (*.update.microsoft.com, *.windowsupdate.com, delivery.mp.microsoft.com)
        │
        ▼
Reporting Channel
  ├── WSUS: status reported to WSUS server, visible in WSUS console
  └── WUfB: status reported to Windows Update for Business deployment
      service, visible in Intune (Reports > Windows Updates) and
      Update Compliance (if configured)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Registry value reverts within minutes of manual change | MDM or GPO still configuring the opposing value | `gpresult /h report.html` + review assigned Intune Update Ring profile |
| `UseWUServer=1` but scan fails with 0x8024402C | WSUS URL unreachable or misconfigured | Test `WUServer` URL reachability |
| Device switched to WUfB but stays on old feature version | `TargetReleaseVersion`/`TargetReleaseVersionInfo` still pinned | `reg query` both values; check Intune Feature Update policy |
| Some updates apply, others silently skip (dual scan) | `DisableDualScan` not set while WSUS active, causing inconsistent behaviour | Check `DisableDualScan`; decide intended behaviour explicitly |
| Device shows "up to date" in WSUS console but out of date per Intune Update Compliance | Client is dual-reporting or mid-migration (stale WSUS record) | Confirm actual current `UseWUServer` value on device |
| Manual `usoclient StartScan` does nothing observable | `usosvc` (Update Orchestrator) stopped, or command deprecated on this build | `Get-Service usosvc`; use Settings UI "Check for updates" as fallback |
| Feature update deploys to pilot ring but never reaches broad ring | Deployment safeguard hold or staged rollout percentage not yet reached | Check Intune feature update deployment profile rollout status |
| Device is hybrid-joined and gets conflicting settings from GPO and Intune | Co-management workload split not configured to hand Windows Update policy to Intune | Check ConfigMgr co-management workload settings; check for competing GPO link |
| WSUS URL removed but device still tries to reach old WSUS server | Cached policy not yet refreshed, or stale scheduled task | Force MDM sync; verify with fresh registry query after 15+ min |
| Update stack itself broken (corrupt store) regardless of source | SoftwareDistribution or catbase corruption | Standard WU reset (stop services, rename folders, restart) — see Playbook 3 |

---
## Validation Steps

**Step 1 — Confirm current scan source (the ground truth, not intent)**
```powershell
$auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

[PSCustomObject]@{
    UseWUServer      = (Get-ItemProperty $auKey -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
    WUServer         = (Get-ItemProperty $wuKey -Name WUServer -ErrorAction SilentlyContinue).WUServer
    WUStatusServer   = (Get-ItemProperty $wuKey -Name WUStatusServer -ErrorAction SilentlyContinue).WUStatusServer
    DisableDualScan  = (Get-ItemProperty $wuKey -Name DisableDualScan -ErrorAction SilentlyContinue).DisableDualScan
}
```
Expected for WUfB-only: `UseWUServer` = 0 or absent, `WUServer`/`WUStatusServer` absent.
Expected for WSUS-active: `UseWUServer` = 1, `WUServer` populated with reachable URL.

**Step 2 — Confirm feature update pin state**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -Name TargetReleaseVersion, TargetReleaseVersionInfo -ErrorAction SilentlyContinue |
    Select-Object TargetReleaseVersion, TargetReleaseVersionInfo
```
If both are present and `TargetReleaseVersion = 1`, the device cannot move past `TargetReleaseVersionInfo` regardless of scan source.

**Step 3 — Identify policy origin (don't fight the wrong layer)**
```powershell
gpresult /h "$env:TEMP\gpreport.html"
Invoke-Item "$env:TEMP\gpreport.html"
# Look under Computer Configuration > Policies > Administrative Templates > Windows Components > Windows Update
```
If the report shows a Windows Update GPO applied, that GPO is the authoritative source — editing Intune alone will not resolve conflicts.

**Step 4 — Confirm MDM/Intune enrollment and last policy sync**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|MdmUrl|TenantId"
```
Confirms the device is actually receiving MDM policy at all (a device with no `MdmUrl` will never receive an Intune Update Ring, no matter how it's configured in the portal).

**Step 5 — Validate update client services are healthy**
```powershell
Get-Service wuauserv, usosvc, bits, cryptsvc |
    Select-Object Name, Status, StartType
```
Expected: all `Running`, `Automatic` (bits may show `Manual`/Trigger-Start — that's normal, it starts on demand).

**Step 6 — Test WSUS reachability (only relevant if still WSUS-active)**
```powershell
$wsusUrl = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue).WUServer
if ($wsusUrl) {
    try {
        $resp = Invoke-WebRequest -Uri "$wsusUrl/selfupdate/wuident.cab" -UseBasicParsing -TimeoutSec 10
        "Reachable: HTTP $($resp.StatusCode)"
    } catch {
        "NOT reachable: $($_.Exception.Message)"
    }
}
```

**Step 7 — Force a scan and observe scan source in logs**
```powershell
Get-WindowsUpdateLog -LogPath "$env:TEMP\WindowsUpdate.log" -ErrorAction SilentlyContinue
Select-String -Path "$env:TEMP\WindowsUpdate.log" -Pattern "WSUS|Windows Update for Business|Server URL" |
    Select-Object -Last 20
```
Expected: log entries referencing the scan source that matches your intended state (WSUS URL, or WUfB/Microsoft Update).

**Step 8 — Confirm compliance/reporting is reaching Intune (if WUfB target state)**
In Intune portal: Devices > Monitor > Windows Updates report, or Reports > Windows Updates > Windows Feature/Quality Update Reports. Cross-check the device appears with a recent scan timestamp.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Policy Source Conflict

Value keeps reverting after manual or Intune-side change:
1. Run `gpresult /h` and confirm whether a domain GPO configures any Windows Update ADMX setting
2. If a GPO exists: it must be unlinked, filtered out for the target OU/group, or updated — Intune policy alone cannot override an actively-applied domain GPO on a hybrid-joined device
3. If no GPO: confirm only one Intune profile (Update Ring or Settings Catalog) targets this device — overlapping profiles with conflicting values produce unpredictable results (Intune will show a conflict in Device > Configuration if detected)
4. For co-managed devices: verify ConfigMgr's co-management workload slider has "Windows Update Policies" set to **Intune**, not **ConfigMgr** — otherwise ConfigMgr/WSUS retains authority regardless of Intune profile

### Phase 2 — Scan Source Not Actually Changing

Registry shows intended values but scans still hit WSUS (or vice versa):
1. Confirm policy has actually refreshed on-device: `gpupdate /force` (GPO) and force MDM sync (Settings > Accounts > Access work or school > Info > Sync, or `Invoke-CimMethod` — see cheat sheet)
2. Restart the update stack cleanly after policy refresh:
   ```powershell
   Stop-Service wuauserv, bits -Force
   Start-Service bits, wuauserv
   ```
3. Trigger a fresh scan and check `WindowsUpdate.log` for which server it contacted (Step 7 above)
4. If dual scan behaviour is suspected (some updates via WSUS, others direct to MU) and this is unwanted: set `DisableDualScan = 1` explicitly rather than leaving it ambiguous

### Phase 3 — Feature Version Not Moving After Migration

WUfB active, WSUS fully removed, but device won't move to target feature version:
1. Check `TargetReleaseVersion`/`TargetReleaseVersionInfo` — this is set independently in Intune's Feature Update deployment profile or Update Ring "Feature update deferral period" / "Target Feature Update Version" field
2. Check for a Microsoft safeguard hold: known compatibility issues can block a specific device/driver combination from receiving a feature update even with correct policy — check `Get-WindowsUpdateLog` for safeguard hold references, or Windows Release Health dashboard
3. Check the Intune Feature Update deployment's rollout percentage/staged rollout — a device may simply not have been reached yet in a phased rollout schedule
4. Confirm the device meets hardware/prerequisite requirements for the target version (TPM 2.0, Secure Boot, minimum build for direct upgrade path)

### Phase 4 — Reachability / Network Failures

Correct policy, correct services, but scans fail:
1. If still WSUS-active: confirm `WUServer` URL responds (Step 6); check corporate firewall/proxy hasn't blocked the WSUS port since a network change
2. If WUfB-active: confirm outbound HTTPS reachability to `*.update.microsoft.com`, `*.windowsupdate.com`, `delivery.mp.microsoft.com`, `*.delivery.mp.microsoft.com` — proxy/firewall changes are the most common post-migration breakage
3. Check Delivery Optimization isn't misconfigured to only use a Connected Cache/WSUS-adjacent peer source that no longer exists:
   ```powershell
   Get-DeliveryOptimizationStatus
   ```

### Phase 5 — Update Stack Corruption (source-agnostic)

If policy, services, and reachability all check out but scans still fail (0x80070003, 0x8024402C persisting):
1. This is a generic Windows Update Agent corruption issue, independent of WSUS vs WUfB — proceed to Playbook 3 (Reset Update Components)

---
## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a pilot group from WSUS to WUfB via Intune (staged, reversible)</summary>

**Scenario:** Ready to move a pilot ring of devices off WSUS onto Intune-managed WUfB, with a clean rollback path if issues surface.

**Step 1 — Confirm target Intune Update Ring exists and is assigned to pilot group**
In Intune portal: Devices > Windows > Update rings for Windows 10 and later > confirm a ring exists with intended feature/quality deferral settings, assigned to the pilot Entra security group. Do not proceed until this is in place and shows "Succeeded" for at least one test device.

**Step 2 — Remove/adjust the competing WSUS policy for pilot devices only**
If GPO-based:
```powershell
# On a domain controller / RSAT machine — identify the GPO
Get-GPO -All | Where-Object { $_.DisplayName -like "*Windows Update*" }
# Security-filter the GPO to exclude the pilot group, or move pilot OU out of scope
```
If Intune-based (competing Settings Catalog profile setting UseWUServer): remove or scope that profile away from the pilot group.

**Step 3 — Force policy convergence on a test device**
```powershell
gpupdate /force
Start-Process "ms-settings:workplace"   # trigger MDM sync via UI
# or
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient `
    -MethodName TriggerSync -Arguments @{ commandID = 1 } -ErrorAction SilentlyContinue
```

**Step 4 — Validate on the test device**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name UseWUServer
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue
```
Expected: `UseWUServer` = 0/absent, `WUServer` absent or empty.

**Step 5 — Force a scan and confirm reporting appears in Intune**
```powershell
usoclient StartScan
```
Check Intune > Reports > Windows Updates within 1-24 hours for the device's compliance record.

**Step 6 — Widen to Broad ring, then General ring**, repeating Steps 2-5 for each subsequent ring after a monitoring period (recommend minimum 3-5 business days per ring for quality issues to surface).

**Rollback:** Re-link/re-scope the original WSUS GPO or Intune profile to the affected group; restart `wuauserv`/`bits`. WSUS reporting will re-populate on next scan.

</details>

<details><summary>Playbook 2 — Clear a feature update pin blocking version upgrade</summary>

**Scenario:** Device is confirmed WUfB-active (Playbook 1 complete) but remains on an old feature version because of a `TargetReleaseVersion` pin left over from a prior policy or manual configuration.

**Step 1 — Confirm the pin exists and its value**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -Name TargetReleaseVersion, TargetReleaseVersionInfo -ErrorAction SilentlyContinue
```

**Step 2 — Find and correct the authoritative source in Intune**
In Intune: Devices > Windows > Update rings (or Configuration profiles > Settings Catalog if using the newer profile type) assigned to this device. Look for "Target Feature Update Version" or an equivalent field. Update it to the desired target version, or clear it to allow the latest supported feature update.

**Step 3 — If no Intune policy sets this (stale local/GPO artifact), clear locally as a stopgap**
```powershell
# Only if you've confirmed no MDM/GPO policy is intentionally setting this
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo /f
```

**Step 4 — Force sync and re-scan**
```powershell
Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient `
    -MethodName TriggerSync -Arguments @{ commandID = 1 } -ErrorAction SilentlyContinue
usoclient StartScan
```

**Step 5 — Verify the pin is gone and the target version is now offered**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -Name TargetReleaseVersion, TargetReleaseVersionInfo -ErrorAction SilentlyContinue
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
```

**Rollback:** Re-add the original pin values via `reg add` if the pin was intentional and removed in error:
```powershell
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo /t REG_SZ /d "<PreviousVersion>" /f
```

</details>

<details><summary>Playbook 3 — Reset Windows Update components (source-agnostic corruption fix)</summary>

**Scenario:** Policy, scan source, and reachability all check out, but the device consistently fails to scan/install with generic errors (0x80070003, 0x8024402C, 0x80244022) regardless of whether it's WSUS or WUfB managed.

**Step 1 — Stop the update stack**
```powershell
Stop-Service wuauserv, bits, cryptsvc, msiserver -Force -ErrorAction SilentlyContinue
```

**Step 2 — Rename the SoftwareDistribution and catroot2 folders**
```powershell
Rename-Item "$env:windir\SoftwareDistribution" "SoftwareDistribution.old" -ErrorAction SilentlyContinue
Rename-Item "$env:windir\System32\catroot2" "catroot2.old" -ErrorAction SilentlyContinue
```

**Step 3 — Restart services**
```powershell
Start-Service cryptsvc, bits, msiserver, wuauserv
```

**Step 4 — Re-force a scan**
```powershell
usoclient StartScan
```

**Rollback:** If the reset does not resolve the issue and you need to restore prior state for comparison, stop services again and rename `.old` folders back (only useful for diagnostic comparison — do not leave both folder sets in place long-term; delete the `.old` folders once resolution is confirmed).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  WSUS/WUfB Migration Evidence Collector
.NOTES     Run elevated on the affected client
#>

$reportPath = "C:\Temp\WU_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

# 1. Identity and MDM enrollment
dsregcmd /status | Out-File "$reportPath\01_Identity.txt"

# 2. Scan source registry state
[PSCustomObject]@{
    UseWUServer          = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
    WUServer             = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name WUServer -ErrorAction SilentlyContinue).WUServer
    WUStatusServer       = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name WUStatusServer -ErrorAction SilentlyContinue).WUStatusServer
    DisableDualScan      = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name DisableDualScan -ErrorAction SilentlyContinue).DisableDualScan
    TargetReleaseVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name TargetReleaseVersion -ErrorAction SilentlyContinue).TargetReleaseVersion
    TargetVersionInfo    = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name TargetReleaseVersionInfo -ErrorAction SilentlyContinue).TargetReleaseVersionInfo
} | Format-List | Out-File "$reportPath\02_RegistryState.txt"

# 3. GPO report
gpresult /h "$reportPath\03_GPReport.html"

# 4. Services
Get-Service wuauserv, usosvc, bits, cryptsvc |
    Select-Object Name, Status, StartType | Format-Table |
    Out-File "$reportPath\04_Services.txt"

# 5. OS version
[PSCustomObject]@{
    DisplayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
    CurrentBuild   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    UBR            = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
} | Format-List | Out-File "$reportPath\05_OSVersion.txt"

# 6. Windows Update log (last 24h)
Get-WindowsUpdateLog -LogPath "$reportPath\06_WindowsUpdate.log" -ErrorAction SilentlyContinue

# 7. Delivery Optimization status
Get-DeliveryOptimizationStatus | Out-File "$reportPath\07_DeliveryOptimization.txt"

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check WSUS active flag | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Name UseWUServer` |
| Check WSUS URL | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name WUServer` |
| Check feature update pin | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Name TargetReleaseVersion,TargetReleaseVersionInfo` |
| GPO report | `gpresult /h report.html` |
| MDM enrollment check | `dsregcmd /status` |
| Force MDM sync | `Invoke-CimMethod -Namespace root\cimv2\mdm\dmmap -ClassName MDM_DMClient -MethodName TriggerSync -Arguments @{ commandID = 1 }` |
| Force GPO refresh | `gpupdate /force` |
| Check update services | `Get-Service wuauserv,usosvc,bits,cryptsvc` |
| Force update scan | `usoclient StartScan` |
| Get Windows Update log | `Get-WindowsUpdateLog -LogPath C:\Temp\WU.log` |
| Check Delivery Optimization | `Get-DeliveryOptimizationStatus` |
| Reset update stack (destructive) | Stop services → rename `SoftwareDistribution`/`catroot2` → start services |
| Check OS version | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'` |

---
## 🎓 Learning Pointers

- **`UseWUServer` is a boolean switch, but the actual behaviour depends on three keys agreeing.** `AU\UseWUServer=1` alone with no `WUServer` value produces scan failures, not a fallback to Microsoft Update. Always check all three related values (`UseWUServer`, `WUServer`, `WUStatusServer`) together rather than assuming one implies the others. [MS Docs: Configure WSUS client policy settings](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings)

- **Feature update pinning and scan source are independent control planes.** Migrating from WSUS to WUfB changes *where* the device scans, not *what version* it's allowed to move to. `TargetReleaseVersion`/`TargetReleaseVersionInfo` must be managed separately in the Intune Update Ring or Feature Update deployment profile. This is the single most common cause of "migration didn't work" tickets. [MS Docs: Manage Windows 10/11 feature updates](https://learn.microsoft.com/en-us/mem/intune/protect/windows-10-feature-updates)

- **Policy precedence is not a simple hierarchy — it's whoever writes last on a co-managed or hybrid-joined device.** Don't assume Intune "wins" over GPO by design; on a hybrid-joined, co-managed device both can write to the same registry keys. The durable fix is to remove the competing policy at its source (unlink the GPO, or hand the workload to Intune via co-management settings), not to keep re-applying the value you want. [MS Docs: Co-management workloads](https://learn.microsoft.com/en-us/mem/configmgr/comanage/workloads)

- **Dual scan is a feature, not a bug, but it's silent.** A WSUS-managed device can still reach out to Microsoft Update for specific categories (drivers, Store apps) unless `DisableDualScan` is explicitly set. If your organization wants strict WSUS-only behaviour, this must be configured deliberately — otherwise expect unexplained "it installed an update we didn't approve in WSUS" tickets. [MS Docs: Dual scan behavior](https://learn.microsoft.com/en-us/windows/deployment/update/waas-wu-settings#configuring-automatic-updates)

- **Migrate in rings, and expect an 8-24 hour (or longer) convergence window.** Both GPO refresh and MDM policy sync are not instantaneous. When validating a migration, always force sync explicitly (`gpupdate /force` + MDM TriggerSync) rather than waiting passively, and re-check registry state after the forced sync rather than assuming the portal's "Succeeded" status means the client has actually applied it.

- **Safeguard holds can block a feature update independent of every setting covered here.** If policy, pin state, and scan source are all correct but the device still won't move to a target feature version, check for a Microsoft-imposed compatibility safeguard hold before spending more time on client-side config. [MS Docs: Safeguard holds](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds)
