# Quick Machine Recovery (QMR) — Hotfix Runbook (Mode B: Ops)
> Fix, enable, or evidence-collect on a QMR ticket in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first (elevated) — results tell you which fix path to follow:

```powershell
# 1. Is Windows RE even enabled? (hard prerequisite — QMR cannot function without it)
reagentc.exe /info

# 2. What is the device's CURRENT effective QMR/recovery configuration?
reagentc.exe /getrecoverysettings
# Look for: <CloudRemediation state="0|1" /> and <AutoRemediation state="0|1" totalwaittime="..." waitinterval="..."/>
# NOTE: if a Wi-Fi profile is configured for WinRE, its SSID and PASSWORD print in plaintext —
# redact before pasting this output into a ticket or screen-sharing it

# 3. Is this device managed (Enterprise/Education/domain-or-MDM-managed Pro), or unmanaged (Home/standalone Pro)?
#    Defaults are OPPOSITE depending on this — see Dependency Cascade below
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"
(Get-CimInstance Win32_OperatingSystem).Caption

# 4. OS build check — Microsoft's two own pages disagree on the minimum build (see Learning Pointers)
[System.Environment]::OSVersion.Version
Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name DisplayVersion, CurrentBuild, UBR

# 5. Confirm the device is actually receiving current Intune/MDM policy (if QMR is meant to be managed)
Get-ScheduledTask -TaskName "PushLaunch" -ErrorAction SilentlyContinue
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName
```

**Interpretation table:**

| Finding | Action |
|---|---|
| `reagentc /info` shows WinRE **disabled** | QMR cannot run at all — this is priority #1, not a QMR-specific issue → Fix 2 |
| Device is unmanaged (Home, or standalone Pro) and `CloudRemediation state="1"` | Expected default — QMR is ON by default here, working as designed |
| Device is Enterprise/Education/domain-or-MDM-managed Pro and `CloudRemediation state="0"` | **Expected default, not a bug** — QMR ships OFF by default on managed editions until an admin explicitly turns it on → Fix 1 if org wants it enabled |
| Managed device shows `CloudRemediation state="1"` but nobody remembers enabling it | Either an admin explicitly enabled it via Intune/CSP, or the device was unmanaged when the setting was set and it "stuck" through enrollment (see Dependency Cascade) — confirm intent, don't assume malfunction |
| `AutoRemediation` enabled but `waitinterval` (retry) is greater than `totalwaittime` (time to reboot) | Misconfigured timer relationship — Microsoft requires retry interval ≤ time to reboot; fix the policy → Fix 4 |
| User reports the device "kept rebooting into recovery over and over" | Likely the timer misconfiguration above, or auto-remediation with no available fix looping through retries as designed until `totalwaittime` elapses → Fix 4 |
| Recovery attempted but device never connected to the network in WinRE | Enterprise Wi-Fi is almost always 802.1X/certificate-based — **not supported** by WinRE's network stack (wired or WPA/WPA2-password only) → Fix 3 |
| Need to confirm whether a QMR remediation actually fired during a past incident | Settings > Windows Update > Update history > **Quality updates** section → Fix 5 |
| Device enrolled in Windows Insider Program, Experimental channel, testing before a fleet rollout | Test mode is available → Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Windows Recovery Environment (WinRE) enabled on the device
   reagentc /info → "Windows RE status: Enabled"
   (if Disabled, NOTHING below this line matters — fix this first)
        │
Windows 11, version 24H2 or 25H2, minimum build
   Support doc states 24H2 build 26100.4700+
   The Recovery CSP reference states 26100.8737+ (24H2) / 26200.8737+ (25H2)
   -- these two Microsoft pages do not agree; treat 26100.8737+ as the safer
      floor since it is the CSP-level (management) reference
        │
Device management-state default fork (this is the #1 source of confusion)
   UNMANAGED (Home edition, OR Pro not domain-joined/not MDM-enrolled):
        CloudRemediation defaults ON, one-time-scan AutoRemediation
   MANAGED (Enterprise, Education, OR Pro that IS domain-joined/MDM-enrolled):
        CloudRemediation defaults OFF — admin must explicitly enable
   If cloud remediation is never explicitly configured, the EFFECTIVE default
   automatically FLIPS if the device transitions between these two states
   (e.g., unmanaged → freshly Intune-enrolled). If an admin EVER explicitly
   sets the value, that explicit value sticks permanently regardless of any
   later management-state transition.
        │
Recovery CSP reachable via Intune (MDM channel) if a managed-fleet policy exists
   ./Vendor/MSFT/Recovery/QuickMachineRecovery/EnableQuickMachineRecovery = true
        │
   ┌────┴─────────────────────────┐
   │                               │
Auto remediation (optional)    Network reachability in WinRE
EnableAutoRemediation = true   Wired Ethernet -- always supported
   SetRetryInterval (0-4320m)  WPA/WPA2 password-based Wi-Fi -- supported
   SetTimeToReboot (1-4320m)   802.1X / Enterprise Wi-Fi (RADIUS/cert) --
   Retry interval MUST be <=     NOT SUPPORTED, no workaround except a
   time to reboot, or behavior    dedicated WinRE-only WPA2-PSK fallback
   is undocumented/unreliable     network pushed via NetworkSettings/Wifi
        │                               │
        └───────────────┬───────────────┘
                         ▼
        Windows Update reachability from WinRE
        (remediation content is delivered as a quality update)
                         ▼
        Remediation applied → device reboots → verify in
        Settings > Windows Update > Update history > Quality updates
```

**Key concepts:**
- **The default is backwards from what most admins assume.** On a properly managed (Intune/domain-joined) fleet, QMR is OFF out of the box — it does not silently protect anything until an admin turns it on. This is the opposite of the unmanaged/consumer default.
- **Explicit configuration is sticky across management-state transitions.** A device that had QMR explicitly turned on while unmanaged does not silently revert to the managed default of OFF just because it later gets Intune-enrolled — and vice versa.
- **WinRE's network stack does not support 802.1X.** Most enterprise Wi-Fi is 802.1X. Without wired connectivity or a dedicated fallback WPA2-PSK network provisioned specifically for WinRE, a wireless-only enterprise device functionally cannot reach cloud remediation even with every policy correctly enabled.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm WinRE is enabled (hard prerequisite):**
```powershell
reagentc.exe /info
```
- `Windows RE status: Disabled` → stop here, this is the actual root cause, not QMR

**Step 2 — Read the device's current effective recovery settings:**
```powershell
reagentc.exe /getrecoverysettings
```
- Confirms `CloudRemediation`, `AutoRemediation` (with its timers), and whether a `WifiCredential` fallback profile is configured

**Step 3 — Determine which default applies:**
```powershell
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"
```
- Any of these `YES` → managed → default is OFF unless explicitly configured
- All `NO` on a Home/Pro edition → unmanaged → default is ON with one-time scan

**Step 4 — If a fleet policy should be applying, confirm MDM policy delivery:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 20 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message
```
- Look for recent CSP push activity; if the device hasn't synced recently, force one from Company Portal or `Get-ScheduledTask -TaskName "PushLaunch" | Start-ScheduledTask`

**Step 5 — If the complaint is "it never recovers," confirm the network path exists in WinRE:**
- Ask: is this device on wired Ethernet, or Wi-Fi? If Wi-Fi, is it WPA/WPA2-password or 802.1X/Enterprise? Only the former two work in WinRE.

---

## Common Fix Paths

<details><summary>Fix 1 — Enable QMR fleet-wide (most common MSP request for managed devices)</summary>

**Cause:** Managed devices (Enterprise/Education/domain-or-MDM-managed Pro) ship with cloud remediation OFF by default. If the org wants QMR's automated recovery, it must be explicitly turned on.

**Via Intune (Settings Catalog, preferred):**
```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Remote Remediation (per current community documentation of this
Settings Catalog category; Microsoft's own Recovery CSP reference page does
not itself name the Settings Catalog category label — verify the category
name in your tenant's Settings Catalog search before assuming it matches)
  → Enable Quick Machine Recovery = Enabled
  → Enable Auto Remediation = Enabled (optional, recommended for unattended recovery)
  → Set Retry Interval = <minutes, e.g. 120>
  → Set Time To Reboot = <minutes, e.g. 2400 — MUST be >= Retry Interval>
Assign to the target device group, then force a policy sync.
```

**Via direct CSP / OMA-URI (fallback if Settings Catalog UI lags a tenant):**
```
./Vendor/MSFT/Recovery/QuickMachineRecovery/EnableQuickMachineRecovery         (bool) = true
./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/EnableAutoRemediation (bool) = true
./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/SetRetryInterval      (int)  = 120
./Vendor/MSFT/Recovery/QuickMachineRecovery/AutoRemediationSettings/SetTimeToReboot       (int)  = 2400
```

**Verify (on-device, post-sync):**
```powershell
reagentc.exe /getrecoverysettings
```

**Rollback:** Set `EnableQuickMachineRecovery` back to `false` (or remove the policy/assignment) and re-sync. Note this is now an *explicit* configuration — it will not silently revert to the managed default even after removal until you confirm the setting actually cleared.

</details>

<details><summary>Fix 2 — QMR unavailable / WinRE shows Disabled</summary>

**Cause:** WinRE itself is disabled (common after certain disk-partitioning changes, some third-party imaging tools, or manual `reagentc /disable` runs) or the device is below the minimum OS build.

```powershell
reagentc.exe /info
[System.Environment]::OSVersion.Version
```

**Remediation:**
```powershell
# Re-enable WinRE (requires the recovery partition/image to still exist and be reachable)
reagentc.exe /enable
```
- If `/enable` fails because the recovery image is missing, this becomes a WinRE-repair task (rebuilding the recovery partition/image), which is out of scope for this runbook — treat as a separate WinRE-health ticket first.
- If the build is below the minimum, this device is not yet eligible; a feature update is required before QMR configuration has any effect.

**Rollback:** N/A — re-enabling WinRE is not a destructive action.

</details>

<details><summary>Fix 3 — QMR enabled but the device never actually reaches Windows Update in WinRE</summary>

**Cause:** The device's normal network is 802.1X/Enterprise Wi-Fi, which WinRE's network stack does not support. No policy setting fixes this — it's an inherent WinRE limitation.

**Remediation options (pick based on the estate):**
1. **Wired-only acceptance:** if the device has a wired NIC, QMR will use it automatically in WinRE with no extra configuration — often the simplest real answer for desktops/docked laptops.
2. **Dedicated WinRE fallback Wi-Fi network:** provision a WPA/WPA2-password-based SSID (ideally an isolated, purpose-built network, not the production 802.1X SSID) specifically for recovery scenarios, and push its profile via:
   ```
   ./Vendor/MSFT/Recovery/NetworkSettings/Wifi/{SSID}/WlanXML   (string — standard Windows WLAN profile XML)
   ```
3. **Accept the limitation:** for a wireless-only 802.1X estate with no fallback network appetite, QMR will still fall back to local Startup Repair (no cloud remediation) — document this as a known, accepted gap rather than continuing to troubleshoot a connectivity problem that has no fix within QMR's current network model.

**Rollback:** Remove the `WlanXML` node/profile if the fallback network is decommissioned.

</details>

<details><summary>Fix 4 — Device loops in WinRE / auto-remediation timers misbehaving</summary>

**Cause:** `SetRetryInterval` is configured greater than `SetTimeToReboot` — a relationship Microsoft's own CSP reference explicitly requires (retry interval must be ≤ time to reboot). Behavior outside this relationship is not well-defined and should be treated as a misconfiguration, not a product bug.

```powershell
reagentc.exe /getrecoverysettings
# Compare <AutoRemediation totalwaittime="X" waitinterval="Y"/> — Y must be <= X
```

**Remediation:** Correct the Intune/CSP policy so `SetRetryInterval` (waitinterval) is less than or equal to `SetTimeToReboot` (totalwaittime), then re-sync and re-verify.

**Rollback:** N/A — this is a corrective configuration fix.

</details>

<details><summary>Fix 5 — Confirm whether a remediation actually fired (post-incident review)</summary>

**Cause:** After a fleet-wide boot-failure incident, you need to confirm which devices' QMR successfully applied a fix vs. which required manual intervention.

**Check per-device:**
```
Settings > Windows Update > Update history > Quality updates
```
A QMR-applied fix appears here like any other quality update. There is currently no documented tenant-wide Graph/Intune report that aggregates "which devices had a QMR remediation applied" — this is a per-device check only.

**Rollback:** N/A — read-only verification.

</details>

<details><summary>Fix 6 — Validating QMR behavior before a fleet rollout (test mode)</summary>

**Cause:** You want to see the QMR auto-remediation experience without waiting for a real boot failure, before turning this on broadly.

**Constraint:** Test mode is documented as available **only** on devices enrolled in the Windows Insider Program's **Experimental channel** — this is not something you can trigger on a standard production Windows 11 24H2/25H2 device. Most MSPs will not want production hardware on the Insider Experimental channel; treat this as a lab-only validation path, not a pilot-fleet option.

```cmd
:: On an Insider Experimental-channel test device only:
reagentc.exe /SetRecoveryTestmode
reagentc.exe /BootToRe
:: Restart the device — it will simulate the auto-remediation flow and return to Windows
```
If the device boots into ordinary WinRE instead of test mode after restart:
```cmd
:: In WinRE: select Continue to boot Windows normally, then:
reagentc.exe /Disable
reagentc.exe /Enable
:: Retry from reagentc.exe /SetRecoveryTestmode
```

**Rollback:** N/A — test mode is a temporary simulation state, not a persistent configuration change.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Quick Machine Recovery Issue
=====================================
Device Name:              [hostname]
OS Build:                 [DisplayVersion / CurrentBuild.UBR]
WinRE Status:              [reagentc /info output — Enabled/Disabled]
Management State:          [Unmanaged | Domain-joined | Entra-joined/MDM-managed]
CloudRemediation state:    [0|1, from reagentc /getrecoverysettings]
AutoRemediation state:     [0|1, totalwaittime=___, waitinterval=___]
WinRE Network Path:        [Wired | WPA/WPA2 Wi-Fi | 802.1X Enterprise Wi-Fi (unsupported)]
Fallback WinRE Wi-Fi profile configured: [Yes/No]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed WinRE is Enabled (reagentc /info)
[ ] Read current recovery settings (reagentc /getrecoverysettings)
[ ] Confirmed managed vs. unmanaged default applies as expected
[ ] Confirmed MDM/Intune policy sync is current
[ ] Confirmed retry-interval <= time-to-reboot relationship if auto-remediation is on
[ ] Confirmed WinRE network path (wired/WPA2-PSK vs. unsupported 802.1X)
[ ] Checked Windows Update history for an applied quality-update remediation
```

---

## 🎓 Learning Pointers

- **QMR needs zero special hardware — this is the opposite of Windows Recall.** No NPU, no Copilot+ PC certification, nothing. It runs on any Windows 11 24H2/25H2 device with WinRE enabled. Don't reflexively check hardware eligibility the way you would for Recall; the actual gate here is management state and policy, not silicon. [Quick machine recovery overview](https://support.microsoft.com/en-us/windows/experience/backup-recovery/quick-machine-recovery-in-windows)

- **The managed-vs-unmanaged default is backwards from what most engineers assume, and it's the single highest-value fact in this topic.** A properly Intune-managed or domain-joined fleet does NOT get QMR's cloud remediation for free — it ships OFF until an admin turns it on. Don't tell a client "QMR already has you covered" without checking the actual policy state first.

- **Once a value is explicitly set, it survives a management-state change.** A device that had cloud remediation manually turned on while it was an unmanaged demo unit, then later got Autopilot-enrolled into the production tenant, will NOT silently revert to the managed-default OFF state. Always read `reagentc /getrecoverysettings` rather than assuming the default that "should" apply based on join state alone.

- **WinRE cannot do 802.1X.** This is an under-advertised limitation that quietly defeats QMR for most wireless-only enterprise estates (which are overwhelmingly 802.1X/RADIUS-based). Wired connectivity or a dedicated WPA2-PSK fallback network are the only two paths that actually work — there is no certificate-based or Enterprise-Wi-Fi option in WinRE as of this writing.

- **Microsoft's own two published sources disagree on the minimum OS build** (the end-user Support article says 24H2 build 26100.4700+; the Recovery CSP reference says 26100.8737+ for 24H2 / 26200.8737+ for 25H2). Treat the CSP reference's higher, more recent figure as the safer floor for planning purposes, and flag this discrepancy explicitly if a client's compliance reporting depends on an exact build number. [Recovery CSP reference](https://learn.microsoft.com/en-us/windows/client-management/mdm/recovery-csp#quickmachinerecovery)

- **Test mode cannot be validated on a normal production device.** It requires Windows Insider Program Experimental-channel enrollment — plan any pilot/validation strategy around a genuinely disposable lab device, not a production pilot group, if you need to see the auto-remediation UX firsthand before a wider rollout.
