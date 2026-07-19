# Microsoft 365 Apps Deployment & Update Channels — Reference Runbook (Mode A: Deep Dive)
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

Covers the **Microsoft 365 Apps for enterprise/business desktop client stack**: Click-to-Run installation architecture, the Office Deployment Tool (ODT), update channel selection and servicing, and client-level activation/licensing (Shared Computer Activation and standard user-based activation). Assumes Windows devices running the modern Click-to-Run installation of Word/Excel/PowerPoint/Outlook/etc. (Microsoft 365 Apps for enterprise or Business), not volume-licensed MSI Office.

**Does not cover:**
- Outlook-specific profile, Autodiscover, OST, or COM add-in issues — see `M365/Exchange/Outlook-Client-A.md`. That topic assumes the Click-to-Run install itself is healthy and focuses purely on Outlook's own connectivity/profile layer.
- Entra ID license *assignment* (who has which SKU) — see `M365/Licensing/License-Assignment-A.md` and `Group-Based-Licensing-A.md`. This topic assumes a valid license assignment exists and focuses on the client's ability to activate against it.
- **New Outlook for Windows** and other WebView2-based "New" Microsoft 365 app experiences — architecturally unrelated (no Click-to-Run servicing, no local `.ost`, no update-channel concept in the same sense); briefly disambiguated below but not covered in depth.
- Volume-licensed MSI installations (Office LTSC, Office 2019/2021 Professional Plus) — these use `PerpetualVL2021`/equivalent update channels and WSUS/SCCM-style servicing, not Click-to-Run's CDN-based model.
- Mobile (iOS/Android) Office app deployment and update — entirely separate app-store-based servicing model.

---
## How It Works

<details><summary>Full architecture</summary>

### Click-to-Run: what it actually is

Click-to-Run is Microsoft's streaming/virtualization-based installation technology for Microsoft 365 Apps — **not** a traditional MSI install. Key architectural facts that drive most troubleshooting:

- Office is installed into a versioned folder structure and served through an App-V-derived virtualization layer, allowing multiple builds to be staged and multiple update mechanisms (background download, delta patching) that a traditional MSI install can't do.
- The **OfficeC2RClient.exe** process and the **ClickToRun** Windows service manage installation, updates, and repair — not Windows Installer.
- Update channel, version, and build are tracked in the registry under `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration`.
- Updates are delivered via the **Office Content Delivery Network (CDN)** by default — a globally distributed set of endpoints Microsoft controls, distinct from Windows Update entirely.

### The three primary update channels

| Channel | Feature update cadence | Security/non-security cadence | Support duration (per version) | Rollback window |
|---|---|---|---|---|
| **Current Channel** | As soon as ready, no fixed schedule (~monthly) | ~2-3 releases/month, one on 2nd Tuesday | Until next version ships (~1 month) | N/A |
| **Monthly Enterprise Channel (MEC)** | Monthly, 2nd Tuesday | Monthly, 2nd Tuesday | 3 months | 3 months |
| **Semi-Annual Enterprise Channel (SAC)** | Historically Jan/July only — **changing July 2026** (see below) | Monthly, 2nd Tuesday | Historically 8 months — **changing to an effective 3-month window (1 month support + 2 months rollback) starting July 2026** | 2 months (post-2026 change) |

**Current Channel (Preview)** and **Beta Channel** (Microsoft 365 Insider) exist as earlier-access variants of Current Channel for pilot/IT-staff testing — Beta Channel is explicitly unsupported and should never be deployed broadly.

### The July 2026 SAC/MEC unification (load-bearing, currently in effect)

Beginning with the **July 2026 (Version 2606) release**, Microsoft is unifying Semi-Annual Enterprise Channel's cadence with Monthly Enterprise Channel: SAC now receives feature **and** security updates on a monthly basis rather than twice a year. This is not a policy migration an admin must action — existing channel assignments continue to be respected, and devices simply start receiving updates on the new cadence automatically. The practical consequences:

- SAC's support-per-version window drops from 8 months to an effective ~3 months (1 month direct support + a 2-month rollback window), a dramatically faster cadence than what SAC was originally chosen for.
- Compliance/reporting/dashboard tooling that specifically filters or labels devices as "Semi-Annual Enterprise Channel" may need updating, since the channel's actual update behavior after this point functionally resembles MEC even though the channel *name* a device reports doesn't change.
- Clients who selected SAC specifically to minimize testing/change frequency need to be proactively told this cadence has shifted — this is exactly the kind of platform change that surfaces as a support ticket ("why did Word's ribbon change, we're on Semi-Annual!") months after the fact if not flagged ahead of time.

### Channel resolution precedence

When multiple mechanisms specify an update channel, Windows/Click-to-Run resolves in this order (highest wins):

1. **Group Policy** (`Computer Configuration > Administrative Templates > Microsoft 365 Apps/Office 2016 (Machine) > Updates > Update Channel`) — if configured, this **always** wins regardless of any other setting.
2. **Office Deployment Tool** `Channel` attribute in the `Add` or `Updates` element of the configuration XML used at install time (or a later ODT-driven channel change).
3. **Microsoft 365 admin center** org-wide setting (**Settings > Org settings > Services > Microsoft 365 installation options**) — applies only to users who self-install via Office.com, not to ODT/Intune-deployed installs.
4. **Per-product default** — Current Channel for Microsoft 365 Apps for enterprise/business (and for the subscription versions of Project/Visio).

This precedence is the single most common root cause of "I changed the channel and nothing happened" tickets — a GPO set months ago (possibly by a different admin, possibly since forgotten) silently overrides every later attempt via ODT or the admin center.

### Update channel configuration methods, compared

| Method | Scope | Overridden by |
|---|---|---|
| Group Policy (ADMX/ADML) | Per-device, domain/Intune-GPO-scoped | Nothing — this is the top of the precedence chain |
| Office Deployment Tool `Channel` attribute | Set at install time, or via a later ODT run with `/configure` | Group Policy |
| Microsoft 365 admin center org setting | Self-service installs via Office.com only | Group Policy, ODT |
| Intune Configuration Profile (Office/Microsoft 365 Apps policy templates) | Effectively wraps the same GPO ADMX settings via CSP/OMA-URI | Nothing (functions as GPO-equivalent) |

### Activation and Shared Computer Activation (SCA)

Activation is architecturally independent of update channel — a device can be perfectly up to date on its channel and still fail to activate, or vice versa. Standard user-based activation ties a licensing token to the signed-in identity's Entra-assigned Microsoft 365 Apps license; **Shared Computer Activation** is a special install-time mode (`SharedComputerLicensing="1"` in the ODT config) for RDS/Citrix/kiosk/shared-device scenarios where many different users sign into the same machine:

- Requires a license SKU that explicitly supports SCA (not universal across all Microsoft 365 Apps SKUs).
- Microsoft enforces a rolling limit on how many *shared* computers a single user identity can be activated against concurrently — exceeding it produces activation failures that look identical to a licensing problem but are actually a quota problem requiring de-activation of stale sessions, not re-licensing.
- SCA must be set at deployment time; it is not a runtime toggle an admin can flip on an already-deployed, non-SCA install without redeploying via ODT.

### New Outlook / WebView2 app disambiguation

Newer "New" Microsoft 365 app experiences (New Outlook for Windows being the most prominent) are **not** Click-to-Run applications — they are WebView2-hosted, browser-engine-based apps with no local `.ost`, no COM add-in support, and their own separate cache/reset model (`%localappdata%\Microsoft\Olk` + `OneAuth`). Applying a Click-to-Run repair, ODT reconfiguration, or update-channel fix to one of these apps does nothing, because none of that architecture applies. See `Outlook-Client-A.md` for New Outlook's own troubleshooting model.

</details>

---
## Dependency Stack

```
[User-visible symptom: missing feature / won't update / won't activate]
         |
         ├── Update-channel failure domain ───────────────┐   Activation failure domain ──────────────┐
         │                                                  │                                             │
         ▼                                                  ▼                                             ▼
[Channel resolution: GPO > ODT > admin center > default]   [Signed-in identity resolved (Entra)]
         |                                                  |
         ▼                                                  ▼
["Office Automatic Updates 2.0" scheduled task enabled]    [Entra license assignment includes Microsoft 365 Apps SKU]
         |                                                  |
         ▼                                                  ▼
[Office CDN reachable (officecdn.microsoft.com)]           [Licensing token issued + cached locally
         |                                                   (OneAuth / Office identity cache)]
         ▼                                                  |
[Click-to-Run servicing engine downloads + applies update]  ▼
         |                                                 [If Shared Computer Activation: SKU supports SCA
         ▼                                                  AND per-user shared-activation quota not exceeded]
[App relaunch reports new Version/Build in File > Account]  |
                                                              ▼
                                                             [App reports Licensed Product]
```

These two chains only intersect at the symptom layer ("Office seems broken") — they share no actual dependency, which is why misdiagnosing one as the other wastes the most troubleshooting time in this topic.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Changed update channel via ODT/admin center, device still on old channel | Group Policy overriding the channel setting | `HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate` |
| Device never receives updates at all | "Office Automatic Updates 2.0" scheduled task missing/disabled | `Get-ScheduledTask -TaskName "Office Automatic Updates 2.0"` |
| Repair dialog does nothing when clicked | Known Click-to-Run repair-launch bug | Use Settings > Apps > Modify > Quick Repair instead of the in-app dialog |
| "Unlicensed Product"/sign-in loop on a shared/kiosk device | Shared Computer Activation quota exceeded, or SKU doesn't support SCA | `OSPP.VBS /dstatus`; confirm SKU; count concurrent shared activations |
| Correct Entra license assigned, client still shows Unlicensed | Stale local licensing token/cache | Clear `OneAuth`/`OfficeFileCache`, re-sign in |
| Feature present on one device, missing on an identically-licensed device | Different update channels (feature rollout differs per channel by design) | Compare `UpdateChannel` GUID on both devices |
| Device on Semi-Annual Enterprise Channel now updating monthly / support window feels shorter | Expected — July 2026 SAC/MEC cadence unification, not a misconfiguration | Confirm device is post-Version 2606; this is a platform-wide change |
| Can't change update channel for just one app (Word) on a multi-app install | Not supported — update channel is device-wide across all installed Microsoft 365 Apps products (Word/Excel/Project/Visio, etc.) | Confirm intended scope of change before troubleshooting further |
| OneDrive or Teams update behaving differently than Office update channel would predict | OneDrive and Teams have their own independent update cadences, unrelated to Microsoft 365 Apps update channels | Check OneDrive/Teams-specific update documentation, not this topic |
| Install fails with a licensing-token error during Shared Computer Activation | `SharedComputerLicensing` not actually set at install/ODT-config time despite intent | Re-check the ODT configuration XML used for the original deployment |
| Volume-licensed Office (2019/2021/LTSC) doesn't seem to follow any of these channel rules | Correct — those use `PerpetualVL2021`/equivalent, a wholly separate update model (WSUS/SCCM-servicable, not CDN/Click-to-Run) | Confirm SKU/licensing model before applying this topic's fixes |

---
## Validation Steps

**Step 1 — Confirm Click-to-Run installation**
```powershell
Test-Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
```
Expected: `True`. If `False`, this topic doesn't apply — identify MSI/LTSC or New Outlook instead.

**Step 2 — Confirm current channel, version, build**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" |
    Select-Object VersionToReport, UpdateChannel, ClientCulture, Platform
```
Cross-reference the `UpdateChannel` GUID against known channel identifiers (Command Cheat Sheet).

**Step 3 — Confirm channel resolution source**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue
```
Presence of a value here means GPO is authoritative — any other configuration is cosmetic until this policy is changed or removed.

**Step 4 — Confirm update task health**
```powershell
Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" | Select-Object State
Get-ScheduledTaskInfo -TaskName "Office Automatic Updates 2.0" | Select-Object LastRunTime, LastTaskResult
```
Expected: `State = Ready`, recent `LastRunTime`, `LastTaskResult = 0`.

**Step 5 — Confirm CDN connectivity**
```powershell
Test-NetConnection -ComputerName officecdn.microsoft.com -Port 443
```

**Step 6 — Confirm activation state**
```powershell
& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus
```
Expected: `LICENSE STATUS: ---LICENSED---`. `OOB_GRACE`/`OOT_GRACE`/`NOTIFICATIONS` all indicate a licensing-token problem distinct from update-channel health.

**Step 7 — Confirm Entra-side license assignment (rule out the assignment layer before touching the client)**
```powershell
# Connect-MgGraph -Scopes "User.Read.All"
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber
```

---
## Troubleshooting Steps (by phase)

### Phase 1: Establish failure domain

1. Determine whether the reported symptom is update/feature-related or activation/licensing-related — they require entirely different fix paths despite similar user-facing language ("Office is broken").
2. Confirm installation type (Click-to-Run vs. MSI vs. New Outlook) before applying any fix in this topic.

### Phase 2: Update channel resolution

1. Check GPO first — it silently overrides everything else and is the most common root cause of "channel change didn't take."
2. If no GPO, check the ODT configuration file used at install/last reconfiguration.
3. If neither, check the Microsoft 365 admin center org-wide installation option (applies only to self-service Office.com installs).
4. Confirm the device's actual resolved channel via the registry, not assumptions from any single configuration source.

### Phase 3: Update mechanics

1. Confirm the "Office Automatic Updates 2.0" scheduled task is enabled and has run recently.
2. Confirm CDN reachability — proxy/firewall changes are a common silent blocker.
3. If updates are stalled mid-download, a Quick Repair often unsticks the Click-to-Run servicing state without a full reinstall.

### Phase 4: Repair escalation

1. Quick Repair first — local-file-based, fast, resolves the majority of corruption issues.
2. Online Repair second — full re-download and re-validation, slower, resolves deeper corruption Quick Repair can't reach.
3. Full uninstall/reinstall only as a last resort — rarely necessary given Online Repair's depth.

### Phase 5: Activation and licensing

1. Confirm Entra-side license assignment is actually correct before assuming a client-side bug.
2. Confirm local licensing token/cache state via `OSPP.VBS /dstatus`.
3. For Shared Computer Activation specifically, confirm SKU eligibility and per-user shared-activation quota before assuming a broader licensing failure.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide update channel standardization via GPO</summary>

**When:** Multiple devices report inconsistent update channels across a fleet that should be standardized (e.g., moving general staff to Monthly Enterprise Channel while keeping a small IT pilot group on Current Channel Preview).

1. Download the Office ADMX/ADML templates and add to the Central Store.
2. Create/edit a GPO targeting the intended OU or security-group-filtered scope.
3. Set **Computer Configuration > Administrative Templates > Microsoft 365 Apps/Office 2016 (Machine) > Updates > Update Channel** to the intended channel.
4. Enable **Automatically update Office** to keep the servicing task active.
5. Force policy refresh and confirm via the registry validation steps above on a pilot device before broad rollout.

**Rollback:** set the GPO setting to Not Configured; devices fall back to the next-highest precedence source (ODT config or admin center default), which may itself need explicit setting to avoid an unintended fallback to Current Channel.

</details>

<details><summary>Playbook 2 — ODT-driven channel change and redeployment</summary>

**When:** No GPO in play; need to change the channel via the Office Deployment Tool directly (e.g., moving a device onto Monthly Enterprise Channel for the first time).

1. Download the latest `setup.exe` (ODT) from the Microsoft Download Center.
2. Build a configuration XML specifying the target `Channel` attribute in the `Updates` element.
3. Run `setup.exe /configure configuration.xml` on the target device.
4. Confirm via `ClickToRun\Configuration` registry key that the channel updated and a subsequent update cycle picks up the new channel's release cadence.

**Rollback:** re-run ODT with a configuration XML specifying the prior channel — note this can mean a downgrade in version, which Click-to-Run handles, but any features only available in the newer channel disappear.

</details>

<details><summary>Playbook 3 — Recovering a Shared Computer Activation deployment</summary>

**When:** A kiosk/RDS/Citrix fleet is failing activation and SCA needs to be confirmed or newly enabled.

1. Confirm the assigned license SKU explicitly supports Shared Computer Activation.
2. Build/update the ODT configuration XML with `SharedComputerLicensing="1"` under the relevant `Property` element.
3. Redeploy via ODT (`setup.exe /configure`) — this is an install-time setting, not adjustable via GPO or registry alone.
4. On affected devices already failing activation, clear the local licensing cache (`OneAuth`, `OfficeFileCache`) before the next user sign-in to force a clean token request.
5. If quota-related, review and close out stale/abandoned shared-activation sessions tied to specific users before re-attempting.

**Rollback:** redeploy via ODT with `SharedComputerLicensing` removed/set to `0` to return to standard per-user activation — appropriate only if the shared-device use case is being retired.

</details>

<details><summary>Playbook 4 — Fleet-wide health sweep ahead of the July 2026 SAC/MEC unification</summary>

Run `Get-M365AppsHealth.ps1` (see Scripts/) across representative devices to inventory current channel, version/build, GPO-vs-ODT channel authority, and activation state — specifically flagging any device still reporting Semi-Annual Enterprise Channel so affected business units can be proactively told about the new monthly cadence and shortened support window before it causes a surprise mid-cycle UI change.

**Rollback:** N/A — read-only inventory pass.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Microsoft 365 Apps deployment/update/activation evidence for escalation
.NOTES     Run on the affected device as the signed-in user (activation checks require user context).
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = "$env:USERPROFILE\Desktop\M365AppsEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
    "Device    : $env:COMPUTERNAME"
    "User      : $env:USERNAME"
}

Add-Section "Click-to-Run configuration" {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue |
        Select-Object VersionToReport, UpdateChannel, ClientCulture, Platform | Format-List | Out-String
}

Add-Section "GPO-enforced update policy (if any)" {
    Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate" -ErrorAction SilentlyContinue |
        Format-List | Out-String
}

Add-Section "Office Automatic Updates 2.0 task state" {
    Get-ScheduledTask -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue | Select-Object State | Out-String
    Get-ScheduledTaskInfo -TaskName "Office Automatic Updates 2.0" -ErrorAction SilentlyContinue | Select-Object LastRunTime, LastTaskResult | Out-String
}

Add-Section "CDN connectivity" {
    Test-NetConnection -ComputerName officecdn.microsoft.com -Port 443 | Select-Object ComputerName, TcpTestSucceeded | Out-String
}

Add-Section "Activation status" {
    & "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus 2>&1 | Out-String
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm Click-to-Run install | `Test-Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"` |
| Current channel/version | `Get-ItemProperty "HKLM:\...\ClickToRun\Configuration" \| Select VersionToReport, UpdateChannel` |
| Check GPO-enforced channel | `Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate"` |
| Check update task state | `Get-ScheduledTask -TaskName "Office Automatic Updates 2.0"` |
| Force an update check | `& "$env:ProgramFiles\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe" /update user` |
| Change channel via ODT | `setup.exe /configure configuration.xml` (with `Channel` attribute set) |
| Test CDN reachability | `Test-NetConnection -ComputerName officecdn.microsoft.com -Port 443` |
| Check activation status | `& "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus` |
| Clear licensing/identity cache | `Remove-Item "$env:LOCALAPPDATA\Microsoft\OneAuth" -Recurse -Force` |
| Check Entra license assignment | `Get-MgUserLicenseDetail -UserId <UPN> \| Select SkuPartNumber` |
| Quick Repair (UI) | Settings > Apps > Installed apps > Microsoft 365 Apps > Modify > Quick Repair |
| Online Repair (UI) | Settings > Apps > Installed apps > Microsoft 365 Apps > Modify > Online Repair |
| Known channel identifiers | Current, Current (Preview), Monthly Enterprise, Semi-Annual Enterprise, Beta (Insider) |

---
## 🎓 Learning Pointers

- **Click-to-Run is a streaming/virtualization install technology, not an MSI** — this is why it has its own repair model (Quick/Online Repair), its own update task, and its own registry configuration path entirely separate from Windows Installer or Windows Update. Troubleshooting instincts built around MSI-based software (uninstall/reinstall, `msiexec /fix`) don't map cleanly onto this architecture. [Overview of the Office Deployment Tool](https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool)

- **Group Policy sits above every other channel-configuration mechanism, permanently, until explicitly changed.** A GPO set once — possibly years ago, possibly by a departed admin — will silently override every subsequent attempt to change the channel via ODT or the admin center, with zero error message indicating why the change "didn't take." Always check the registry directly rather than trusting any single configuration UI's stated value. [Change the Microsoft 365 Apps update channel](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/change-update-channels)

- **The July 2026 SAC/MEC cadence unification is a live, currently-in-effect platform change** (Version 2606, second Tuesday of July 2026) that fundamentally alters what "Semi-Annual Enterprise Channel" means in practice — monthly updates instead of twice-yearly, and a support window compressed from 8 months to an effective ~3 months. Clients who chose SAC specifically to minimize update frequency need this proactively explained; discovering it via a surprised support ticket months later is a preventable client-relationship cost. [Upcoming channel unification: SAC to MEC](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/unified-update-channels)

- **Update channel is a device-wide setting, not a per-app setting.** If Word, Excel, Project, and Visio are all installed on the same device, they share one channel — there's no way to pin one product to Current Channel while another stays on Monthly Enterprise on the same machine. Any ticket asking for per-app channel control needs to be redirected toward a separate-device or separate-VM conversation instead. [Overview of update channels](https://learn.microsoft.com/en-us/microsoft-365-apps/updates/overview-update-channels)

- **Shared Computer Activation is baked in at deployment time, not adjustable afterward without redeployment.** `SharedComputerLicensing="1"` lives in the ODT configuration file used for the original install; there's no supported registry or GPO toggle to retrofit it onto an existing non-SCA install. Plan RDS/Citrix/kiosk deployments with this in mind from day one. [Troubleshoot shared computer activation](https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/troubleshoot-shared-computer-activation)

- **New Outlook and other WebView2-based "New" app experiences share none of this architecture** — no Click-to-Run servicing, no ODT channel concept, no `OSPP.VBS`-style activation check in the same form. A ticket that turns out to be about New Outlook needs an immediate pivot to `Outlook-Client-A.md`'s New-Outlook-specific section rather than continuing down this topic's fix paths. [Outlook-Client-A.md — client-type identification](../Exchange/Outlook-Client-A.md)
