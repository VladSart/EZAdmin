# Microsoft 365 Companion Apps Retirement (Calendar, People, Files) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:** the three Microsoft 365 companion apps (**Calendar**, **People**, **Files**) delivered as one MSIX/AppX package, `Microsoft.M365Companions`, on Windows 11; their retirement under **MC1474111** (18 Sept 2026); closing every install vector; removing existing installs from managed and unmanaged devices; and proving the fleet is clean before **16 December 2026**.

**Out of scope:** Microsoft 365 Apps Click-to-Run servicing itself (`Deployment-UpdateChannels-A.md`), the *Microsoft 365 Copilot app* (formerly "Microsoft 365 (Office)" hub app — a different package, not retiring), and the new Outlook / new Teams WebView2 apps.

**Assumptions:**
- Engineer has Intune Administrator (or Application Manager) and Office Apps Admin for the M365 Apps admin center.
- Devices are Windows 11 with Microsoft 365 Apps Click-to-Run (the only population that received the auto-install).
- PowerShell 5.1 elevated or SYSTEM context on endpoints; Microsoft Graph PowerShell SDK for tenant-side checks.

**Key dates**

| Date | Event |
|------|-------|
| Late 2025 | Microsoft begins auto-installing companion apps on eligible Windows 11 + M365 Apps devices unless admins opted out in the M365 Apps admin center |
| 18 Sept 2026 | MC1474111 published. Auto-install via M365 Apps updates stops. **No further updates or security fixes.** Existing installs keep working |
| 16 Dec 2026 | Apps stop functioning and are unsupported. Anything still installed is dead, unpatched code |

---

## How It Works

<details><summary>Full architecture</summary>

### What the companion apps were

Lightweight, taskbar-pinned WinUI apps that surfaced three Microsoft Graph–backed views: upcoming meetings (Calendar), org people search/profile cards (People), and recent/shared files (Files). They held **no authoritative data** — everything was read from Exchange Online, Entra ID/Microsoft Search and SharePoint/OneDrive at runtime. Microsoft's Learn article states removing them deletes nothing; local package data is cache/settings only.

### Packaging

```
Microsoft.M365Companions_<version>_x64__8wekyb3d8bbwe      (one package, three app entries)
 ├── Calendar companion  ─┐
 ├── People companion    ─┼─ separate Start/taskbar entries, same package
 └── Files companion     ─┘
Per-user state:   %LOCALAPPDATA%\Packages\Microsoft.M365Companions_8wekyb3d8bbwe\
Provisioned copy: present if staged for all users (new profiles inherit it)
```

Because all three share a package, **uninstalling one uninstalls all three** — Microsoft's user guidance relies on this.

### Install vectors (why they come back)

```
                    ┌───────────────────────────────────────────────┐
                    │ 1. Microsoft 365 Apps updates (auto-install)   │  Win11 + C2R only
                    │    gated by admin toggle in config.office.com  │  STOPPED 18 Sept 2026
                    └───────────────────────────────────────────────┘
                    ┌───────────────────────────────────────────────┐
                    │ 2. Intune Win32 app "Microsoft 365 companion   │  Required → reinstalls
                    │    apps" (from Microsoft's deployment guide)   │  Available → Company Portal
                    └───────────────────────────────────────────────┘
                    ┌───────────────────────────────────────────────┐
                    │ 3. Other ESD / RMM / golden image / task seq.  │  your responsibility
                    └───────────────────────────────────────────────┘
                    ┌───────────────────────────────────────────────┐
                    │ 4. User self-install                           │  no supported source now
                    └───────────────────────────────────────────────┘
```

Microsoft only closed vector 1. The admin-center toggle is **not** cleared by Microsoft. Learn recommends clearing it anyway so the configuration doesn't mislead anyone later.

Vector 2 is the most common cause of "we removed it and it came back." An Intune **Required** assignment is re-evaluated every app check-in (~8 h, or on sync), sees the app missing, and reinstalls it.

### Why removal can look like it failed

- AppX removal of a package **in use** is deferred. Microsoft explicitly says apps may stay visible until the user closes them or signs out, and some devices need a restart.
- `Get-AppxPackage` without `-AllUsers` only shows the calling user. Run as SYSTEM or elevated with `-AllUsers`, or you'll see "clean" while other profiles still have it.
- Removing registrations doesn't remove the **provisioned** package. New profiles created later get it back from the provisioned copy.

### What Microsoft's toggle does *not* have

As of September 2026 there is no documented Graph or PowerShell surface for the "Enable automatic installation of Microsoft 365 companion apps" Modern App setting. Check and change it in the portal and record the change in the ticket.
</details>

---

## Dependency Stack

```
Layer 5  Proof of zero ........ Intune install status / Remediation "without issues" = all devices
Layer 4  Device clean-up ...... Remove-AppxPackage -AllUsers  +  Remove-AppxProvisionedPackage  +  data folder
Layer 3  Session release ...... user sign-out / restart for in-use packages
Layer 2  Vector closure ....... Intune Required/Available deleted · other ESD removed · image rebuilt
Layer 1  Tenant setting ....... M365 Apps admin center auto-install toggle cleared
Layer 0  Microsoft service .... auto-install stopped (18 Sept 2026) · backend off (16 Dec 2026)
```

Work bottom-up: Layer 2 before Layer 4, or Layer 4 is undone within hours.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| App reappears hours after removal | Intune **Required** assignment still exists | Graph: `mobileApps?$filter=contains(displayName,'companion')&$expand=assignments` |
| App reappears only for **new** users on a device | Provisioned package not removed | `Get-AppxProvisionedPackage -Online` |
| Users can reinstall from Company Portal | **Available** assignment still exists | Same Graph query — `intent = available` |
| New devices from imaging have it | Package baked into golden image / task sequence | Image `DISM /Get-ProvisionedAppxPackages` |
| `Remove-AppxPackage` → 0x80073CFA | Package in use by a signed-in session | `Get-Process` for companion processes; sign-out/restart |
| `Remove-AppxPackage` → 0x80070005 | Not elevated / not SYSTEM | Rerun elevated |
| Script reports clean, user still sees app | Script ran without `-AllUsers` or in user context | Re-run as SYSTEM |
| Intune Uninstall assignment shows "Failed" on offline device | Device hasn't checked in | Last check-in date; wait/sync |
| App opens but shows errors / blank panes | Backend degradation during retirement window | Expected; remove it — Microsoft says uninstall is the fix |
| After 16 Dec 2026 app tile does nothing | Retired | Remove |
| Windows 10 device has the app | Deployed manually or by ESD (auto-install was Win11-only) | Check ESD/Intune history |

---

## Validation Steps

1. **Package state (device)**
   ```powershell
   Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions' | Select-Object PackageFullName, Version
   ```
   Good: no output. Bad: one or more rows.

2. **Provisioned state (device)**
   ```powershell
   Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.M365Companions'
   ```
   Good: no output. Bad: a row — new profiles will receive it.

3. **Per-user footprint**
   ```powershell
   Get-ChildItem "$env:SystemDrive\Users\*\AppData\Local\Packages\Microsoft.M365Companions_8wekyb3d8bbwe" -Directory -ErrorAction SilentlyContinue
   ```
   Good: none. Bad: folders after the package is gone (cosmetic).

4. **Intune vector (tenant)**
   ```powershell
   Connect-MgGraph -Scopes 'DeviceManagementApps.Read.All'
   (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=contains(displayName,'companion')&`$expand=assignments").value |
       Select-Object displayName, id, @{n='Intents';e={($_.assignments.intent) -join ','}}
   ```
   Good: no app, or only `uninstall` intents. Bad: `required` / `available`.

5. **Admin-center toggle** — portal: unchecked. Record who cleared it and when.

6. **Fleet proof** — Remediation report: "Without issues" count equals targeted device count, and no "Failed".

---

## Troubleshooting Steps (by phase)

**Phase 1 — Inventory.** Deploy `Scripts/Remove-M365CompanionApps.ps1` in detect-only mode as a Remediation detection script (or via RMM). Export the report. Split the results into: (a) auto-install population (Win11 + C2R, no Intune entry), (b) Intune-deployed, (c) unexpected (Win10, servers, AVD images).

**Phase 2 — Close vectors.** Clear the admin toggle. Delete Intune Required/Available assignments. Remove the package from ConfigMgr apps, RMM policies, and golden images (`DISM /Image:<mount> /Remove-ProvisionedAppxPackage /PackageName:<name>`). For AVD/W365 custom images, rebuild or patch the image, or pooled hosts will return with it.

**Phase 3 — Remove.** Intune Uninstall assignment if an app entry exists; otherwise Remediation with `-Remediate`. Communicate to users first (Learn provides an email template).

**Phase 4 — Stragglers.** Offline devices, in-use deferrals (need restart), unmanaged/BYOD (user instructions only).

**Phase 5 — Close-out.** Keep the Remediation running daily until 16 Dec 2026, then retire it. Remove companion references from internal KBs, onboarding guides and training material, as MC1474111 asks.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Tenant-wide vector closure</summary>

```powershell
Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All'
$apps = (Invoke-MgGraphRequest GET "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=contains(displayName,'companion')&`$expand=assignments").value
foreach ($a in $apps) {
    foreach ($asg in $a.assignments | Where-Object { $_.intent -in 'required','available','availableWithoutEnrollment' }) {
        Write-Host "Deleting $($asg.intent) assignment $($asg.id) on $($a.displayName)"
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($a.id)/assignments/$($asg.id)"
    }
}
```
**Rollback:** export `$apps | ConvertTo-Json -Depth 10` before running so the assignments can be recreated if a group was hit by mistake. Then clear the admin-center toggle in the portal.
</details>

<details><summary>Playbook 2 — Intune Uninstall assignment (app entry exists)</summary>

Portal: app → Properties → Assignments → Edit → **Uninstall** → All devices (or pilot group first). Graph:

```powershell
$appId = '<companionAppId>'
$body = @{
    mobileAppAssignments = @(@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = 'uninstall'
        target        = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }
    })
} | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/assign" -Body $body -ContentType 'application/json'
```
> `/assign` **replaces** the full assignment set. Run this only after Playbook 1 so you're not silently discarding assignments you meant to keep.
</details>

<details><summary>Playbook 3 — Remediation-based removal (no Intune app entry)</summary>

1. Devices → Scripts and remediations → Create.
2. Detection: `Remove-M365CompanionApps.ps1` (default report mode → exit 1 when found).
3. Remediation: wrapper `& "$PSScriptRoot\Remove-M365CompanionApps.ps1" -Remediate`, or a copy with `[switch]$Remediate = $true` set as the default.
4. Run as System, 64-bit. Daily. Assign to all Windows devices.
5. Watch "Issues fixed" vs "Recurred". **Recurred** means an install vector is still open, so go back to Phase 2.
</details>

<details><summary>Playbook 4 — Golden image / AVD</summary>

```powershell
# Mounted offline image
DISM /Image:C:\Mount /Get-ProvisionedAppxPackages | Select-String M365Companions
DISM /Image:C:\Mount /Remove-ProvisionedAppxPackage /PackageName:<PackageNameFromAbove>
```
For live session hosts, run Playbook 3 and also update the image, or the next reimage brings it back.
</details>

---

## Evidence Pack

```powershell
# Collect-CompanionEvidence.ps1 — run elevated on an affected device
$out = "$env:TEMP\CompanionEvidence_${env:COMPUTERNAME}_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Export-Csv "$out\os.csv" -NoType
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue |
    Select-Object VersionToReport, UpdateChannel, Platform | Export-Csv "$out\c2r.csv" -NoType
Get-AppxPackage -AllUsers -Name 'Microsoft.M365Companions' | Select-Object Name, Version, PackageFullName, InstallLocation |
    Export-Csv "$out\appx.csv" -NoType
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.M365Companions' |
    Select-Object DisplayName, Version, PackageName | Export-Csv "$out\provisioned.csv" -NoType
Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 300 -ErrorAction SilentlyContinue |
    Where-Object Message -match 'M365Companions' | Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$out\appx-events.csv" -NoType
Get-ChildItem 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs' -Filter 'AppWorkload*.log' -ErrorAction SilentlyContinue |
    Copy-Item -Destination $out
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Is it installed (any user)? | `Get-AppxPackage -AllUsers -Name Microsoft.M365Companions` |
| Is it provisioned? | `Get-AppxProvisionedPackage -Online \| ? DisplayName -eq Microsoft.M365Companions` |
| Remove for all users | `Get-AppxPackage -AllUsers -Name Microsoft.M365Companions \| Remove-AppxPackage -AllUsers` |
| Remove provisioned | `Get-AppxProvisionedPackage -Online \| ? DisplayName -eq Microsoft.M365Companions \| Remove-AppxProvisionedPackage -Online` |
| Leftover data folders | `gci "$env:SystemDrive\Users\*\AppData\Local\Packages\Microsoft.M365Companions_8wekyb3d8bbwe"` |
| AppX deployment errors | `Get-WinEvent -LogName Microsoft-Windows-AppXDeploymentServer/Operational -MaxEvents 100` |
| Intune companion app + assignments | `Invoke-MgGraphRequest GET ".../beta/deviceAppManagement/mobileApps?$filter=contains(displayName,'companion')&$expand=assignments"` |
| Offline image check | `DISM /Image:C:\Mount /Get-ProvisionedAppxPackages` |
| Fleet detect/remove | `.\Scripts\Remove-M365CompanionApps.ps1` / `-Remediate` |
| C2R version/channel | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` |

---

## 🎓 Learning Pointers

- **Microsoft closed one vector out of four.** Auto-install stopped, but the admin toggle, Intune assignments, images and the installed packages are all yours to clean. [Microsoft 365 companion apps retirement](https://learn.microsoft.com/en-us/microsoft-365-apps/companions/companion-app-retirement)
- **Registered vs provisioned AppX** is the classic reason removals "don't stick" for new profiles. The same pattern applies to any inbox or Microsoft-pushed Store app. [Remove-AppxProvisionedPackage](https://learn.microsoft.com/en-us/powershell/module/dism/remove-appxprovisionedpackage)
- **`/assign` replaces, it doesn't append.** Posting an assignment set to Intune's `mobileApps/{id}/assign` wipes existing ones, so export them first. [mobileApp: assign (Graph)](https://learn.microsoft.com/en-us/graph/api/intune-apps-mobileapp-assign)
- **"Recurred" in Remediations is a signal.** It means something reinstalled the app between runs, so there's still an open vector. [Remediations](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations)
- MC text and timeline: [MC1474111 — mc.merill.net](https://mc.merill.net/message/MC1474111); community scripts: [LazyAdmin](https://lazyadmin.nl/office-365/microsoft-365-companion-apps-are-being-retired-how-to-remove/).
