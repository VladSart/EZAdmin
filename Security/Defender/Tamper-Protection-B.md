# Tamper Protection — Hotfix Runbook (Mode B: Ops)
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

Run on the affected device (elevated PowerShell):

```powershell
# 1 — Current Tamper Protection state
Get-MpComputerStatus | Select-Object IsTamperProtected, TamperProtectionSource

# 2 — MDE onboarding state (Tamper Protection managed via MDE = cannot be disabled locally)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -EA SilentlyContinue |
    Select-Object OnboardingState, OrgId

# 3 — Registry protection check (Tamper writes here)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender" -EA SilentlyContinue |
    Select-Object DisableAntiSpyware, DisableRealtimeMonitoring

# 4 — Intune policy managed
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender" -EA SilentlyContinue |
    Select-Object *Tamper*, *RealTime*, *AntiSpyware*

# 5 — Recent Tamper Protection events
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 30 -EA SilentlyContinue |
    Where-Object Id -in 5013, 5001, 5004, 5010, 5012 |
    Select-Object TimeCreated, Id, Message | Select-Object -First 10
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| `IsTamperProtected = True`, `TamperProtectionSource = ATP` | MDE-managed — cannot disable locally | Fix 1 |
| `IsTamperProtected = True`, `TamperProtectionSource = MDM` | Intune-managed — change via Intune policy | Fix 2 |
| `IsTamperProtected = False` but setting won't save | GPO conflict blocking Defender config | Fix 3 |
| Tamper blocks a third-party AV or security tool | Expected — tool must be added as MDE exclusion or licensed | Fix 4 |
| `DisableAntiSpyware = 1` in registry but Defender still active | Tamper Protection is reverting it | Fix 5 |

---

## Dependency Cascade

<details><summary>What controls Tamper Protection</summary>

```
[Tamper Protection Toggle]
    ├── MDE (if onboarded + MDE P1/P2 licensed)
    │       └── Managed via: security.microsoft.com > Settings > Endpoints > Advanced Features
    │               └── TamperProtectionSource = "ATP" — no local override possible
    │
    ├── Intune MDM (if enrolled, no MDE or MDE defers to Intune)
    │       └── Managed via: Intune > Endpoint Security > Antivirus > Windows Security Experience
    │               └── TamperProtectionSource = "MDM"
    │
    └── Local (if no MDM/MDE management)
            └── Windows Security app > Virus & Threat Protection > Manage Settings
                    └── TamperProtectionSource = "Locally managed"
```

**Tamper Protection protects:**
- Windows Defender AV real-time protection settings
- Cloud-delivered protection settings
- Behaviour monitoring
- SENSE/MDE sensor service state
- Security intelligence updates
- Registry keys under `HKLM:\SOFTWARE\Microsoft\Windows Defender`

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the management source**
```powershell
$status = Get-MpComputerStatus
Write-Host "Tamper Protected : $($status.IsTamperProtected)"
Write-Host "Source           : $($status.TamperProtectionSource)"
# Possible sources: ATP, MDM, Locally managed
```
This determines which fix path to use.

**Step 2 — Confirm what is being blocked**

Common symptoms Tamper Protection causes:
- `Set-MpPreference` commands fail silently or throw "Access is denied"
- Third-party tools that modify Defender config (e.g., backup agents, some RMM tools) fail
- GPO trying to set `DisableAntiSpyware` or `DisableRealtimeMonitoring` has no effect
- Services SENSE, WinDefend, SecurityHealthService cannot be stopped

```powershell
# Test — try setting a preference (will fail under Tamper Protection):
try {
    Set-MpPreference -DisableRealtimeMonitoring $true
    Write-Host "Change accepted (Tamper OFF or test param)"
} catch {
    Write-Host "BLOCKED: $_"
}
```

**Step 3 — Check for script/RMM tool failure correlation**

If an RMM script or third-party tool is failing on multiple devices:
```powershell
# Check if tool is trying to write to protected registry paths
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 50 -EA SilentlyContinue |
    Where-Object Id -eq 5013 |
    Select-Object TimeCreated, Message
```
Event 5013 = "Tamper Protection blocked a change to Windows Defender". The message includes which process attempted the change.

**Step 4 — Confirm Intune policy intent**

If `TamperProtectionSource = MDM`, check Intune:
- Intune portal > Endpoint Security > Antivirus > your AV policy > Properties
- Setting: "Tamper Protection" — is it Enabled/Disabled/Not configured?

---

## Common Fix Paths

<details>
<summary>Fix 1 — Disable Tamper Protection (MDE-managed, TamperProtectionSource = ATP)</summary>

**This must be done in the MDE portal — no local override is possible.**

1. Go to: **security.microsoft.com**
2. Settings > Endpoints > Advanced Features
3. Toggle **"Tamper Protection"** OFF
4. Save

> ⚠️ This disables Tamper Protection for the **entire tenant** — not per-device. Only do this for a maintenance window, then re-enable.

**For per-device temporary disable (if MDE P2):**
1. security.microsoft.com > Assets > Devices > select device
2. … (three dots) > Manage tags — add a tag for exclusion scope
3. Security policies can be scoped by device tag to exclude specific devices

**Re-enable immediately after maintenance:**
```
Settings > Endpoints > Advanced Features > Tamper Protection = ON
```

**Alternative: Use MDE's "exclusion window" for RMM/backup tools** rather than disabling Tamper Protection globally — see Fix 4.
</details>

<details>
<summary>Fix 2 — Adjust Tamper Protection via Intune (TamperProtectionSource = MDM)</summary>

1. Intune portal > Endpoint Security > Antivirus
2. Edit the policy that targets this device/group
3. Windows Security Experience > **Tamper Protection** → set to **Disabled** (or "Not configured" to defer to local)
4. Save and push — allow 15 min for device sync

**Force sync on device:**
```powershell
Get-ScheduledTask | Where-Object TaskName -like "*Schedule*Sync*" | Start-ScheduledTask
```

**Verify after sync:**
```powershell
Get-MpComputerStatus | Select-Object IsTamperProtected, TamperProtectionSource
```

**Rollback:** Re-enable in Intune policy once maintenance is complete.

> ⚠️ Disabling Tamper Protection removes protection against malicious actors stopping Defender. Always re-enable after the change window.
</details>

<details>
<summary>Fix 3 — GPO trying to disable Defender settings (Tamper Protection blocking it)</summary>

This is expected behaviour — Tamper Protection is designed to block GPO changes to Defender.

**To allow GPO to manage Defender settings**, Tamper Protection must be OFF (Fix 1 or Fix 2) OR you must use the correct channel:

- **Right way:** Configure Defender settings via Intune or MDE — not GPO
- **If GPO is required:** Tamper Protection must be disabled tenant-wide (only appropriate for on-prem-only scenarios without MDE)

```powershell
# Confirm GPO is being blocked:
gpresult /h C:\Temp\gpresult.html /f
# Open the HTML report, look for "Windows Defender" policy results
# "Failed" or "Access Denied" = Tamper Protection blocking

# Also check:
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -EA SilentlyContinue
# If keys exist here but Get-MpPreference shows different values = Tamper Protection winning
```

**Long-term fix:** Migrate Defender configuration from GPO to Intune. GPO and Intune should not both manage Defender settings simultaneously.
</details>

<details>
<summary>Fix 4 — Third-party tool (RMM, backup, AV) blocked by Tamper Protection</summary>

Tools that interact with Defender internals (e.g., Veeam, Datto, ConnectWise Automate, SentinelOne co-existence) can be blocked.

**Option A: MDE Exclusion (preferred if MDE-managed)**

In MDE portal: Settings > Endpoints > Indicators > Add indicator, or configure via Intune:
```
Intune > Endpoint Security > Antivirus > Exclusions
Add path exclusion for the tool's executable
```

**Option B: Verify tool compatibility**

Check if the vendor has documented Tamper Protection compatibility:
- Most enterprise RMM vendors have specific documentation for running alongside MDE
- Veeam: requires specific service account permissions, not Tamper Protection disable
- ConnectWise: uses signed drivers that MDE recognises — should not require TP disable

**Identify what the tool is trying to do:**
```powershell
# Which process triggered Tamper Protection event?
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 20 -EA SilentlyContinue |
    Where-Object Id -eq 5013 |
    Select-Object TimeCreated, @{N="Details";E={$_.Message}}
```
The process name in event 5013 tells you exactly which tool is being blocked.

**Option C: Temporary maintenance window**
Disable Tamper Protection (Fix 1 or Fix 2), perform the operation, re-enable immediately.
</details>

<details>
<summary>Fix 5 — Registry shows DisableAntiSpyware=1 but Defender still running</summary>

This is expected and correct — Tamper Protection detects and reverts this registry write. The setting has no effect.

```powershell
# Confirm Tamper Protection is reverting it:
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender" | Select-Object DisableAntiSpyware
# Will show 1 (set by something), but Defender ignores it due to Tamper Protection

# Actual Defender state:
Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled, AntivirusEnabled
```

If something is trying to set `DisableAntiSpyware = 1`:
- Check GPO (`HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\DisableAntiSpyware`)
- Check startup scripts or RMM automation
- If intentional (e.g., migrating to third-party AV): Tamper Protection must be disabled first, then the registry key will take effect

> **Note:** `DisableAntiSpyware` is a legacy key. Modern Windows uses `PassiveModeEnabled` for co-existence with third-party AV. If switching to passive mode, use the correct key:
```powershell
# Correct way to set passive mode (still requires TP off):
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender" -Name "PassiveModeEnabled" -Value 1
```
</details>

---

## Escalation Evidence

```
=== TAMPER PROTECTION ESCALATION ===
Date/Time      : 
Engineer       : 
Ticket         : 

Device Name    : 
OS Version     : 
MDE Onboarded  : (Yes/No — OnboardingState reg value)

IsTamperProtected   : (Get-MpComputerStatus value)
TamperProtectionSource : (ATP / MDM / Locally managed)

What is being blocked:
- Tool/script name : 
- Action attempted : (e.g., Set-MpPreference, sc.exe stop sense)
- Error received   : 

Event 5013 details : (paste message content if present)

Intune policy name : 
Tamper setting     : (Enabled / Disabled / Not configured — from Intune)

Steps Attempted:
1. 
2. 
3. 

Expected behaviour : [describe intended configuration change]
Actual behaviour   : [describe what is blocked or failing]
```

---

## 🎓 Learning Pointers

- **Tamper Protection source determines who can change it** — ATP source = only MDE portal, MDM source = only Intune, local = Windows Security UI. Trying to change it through the wrong channel always fails silently or with Access Denied.
- **Disabling TP tenant-wide is a last resort** — the right fix is almost always to use the correct management channel (Intune or MDE portal) rather than disabling protection to allow a misconfigured tool to work.
- **Event ID 5013** is your friend — it names the process that triggered the Tamper Protection event, saving you from guessing which of your tools is misbehaving. [MS Docs: TP events](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/troubleshoot-microsoft-defender-antivirus)
- **GPO cannot win against Tamper Protection** when MDE or Intune is managing the device. This is a deliberate design decision — Tamper Protection exists specifically to block registry/GPO manipulation by attackers. Migrate Defender config to Intune.
- **RMM tools don't need TP disabled** if they're designed correctly — they should use supported APIs or signed drivers. If your RMM requires disabling Tamper Protection, ask the vendor for their MDE co-existence documentation.
- **Always re-enable** — if you disable Tamper Protection for a maintenance window, build the re-enable step into the ticket's close criteria. It is frequently left off after break-fix work. [MS Docs: Tamper Protection](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection)
