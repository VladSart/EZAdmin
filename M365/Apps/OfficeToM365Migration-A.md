# Migrating MSI / LTSC / Retail Office to Microsoft 365 Apps — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

- **Sources:** Office 2010/2013/2016 **MSI**; Office 2013 **Click-to-Run** (15.0); Office 2016/2019/2021/2024 **retail/OEM C2R**; Office 2019, LTSC 2021, LTSC 2024 **volume C2R**; standalone Visio/Project of any of these.
- **Target:** Microsoft 365 Apps for enterprise (`O365ProPlusRetail`) or for business (`O365BusinessRetail`) on Windows 10/11 or Windows Server RDS/AVD, delivered by ODT, Intune (Microsoft 365 Apps app type or Win32), or Configuration Manager.
- **Out of scope:** activation/sign-in after a clean install (`Activation-A.md`), KMS/MAK for Office you keep (`OfficeVolumeActivation-A.md`), channel management (`Deployment-UpdateChannels-A.md`), Mac (`macOS/Troubleshooting/M365AppsMac-A.md`), Outlook profile/mailbox migration.
- ODT and C2R commands need local admin. Licence checks need Graph `User.Read.All` (or the M365 admin center).

---
## How It Works

<details><summary>Full architecture</summary>

### Two install technologies, one version number
Every Office from 2016 to Microsoft 365 Apps is **version 16.0**. Office 2016 shipped as MSI (volume) and C2R (retail/subscription); everything since 2019 is C2R only. Windows can host one 16.0 **technology** at a time and C2R hosts one **install** (one `ClickToRun` service, one `Configuration` key, one channel, one bitness) containing one or more products.

Microsoft's two rules:
1. No two products with the **same version but different technologies** → MSI Office/Visio/Project 2016 blocks any 16.0 C2R.
2. No two products of **different versions** that are both C2R and overlap apps → Office 2013 C2R + M365 Apps is blocked.

A consequence not written as a rule but enforced by the channel model: a perpetual **volume** suite (`ProPlus2024Volume`) lives on `PerpetualVL2024`, while M365 Apps lives on Current/Monthly Enterprise/Semi-Annual. Both suites in one C2R install can only follow one channel, so mixing them produces a suite on the wrong channel and two overlapping licences. Treat "remove the old suite, then add the new one" as mandatory.

### What the C2R install records
`HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration`:

| Value | Meaning |
|---|---|
| `ProductReleaseIds` | Comma list of product IDs in the install (`O365ProPlusRetail,VisioPro2024Volume`) |
| `Platform` | `x86` or `x64` |
| `VersionToReport` | Build, e.g. `16.0.18xxx.xxxxx` |
| `CDNBaseUrl` | Channel GUID URL the install was deployed from |
| `UpdateChannel` | Channel URL set by admin center/policy (if any) — wins over `CDNBaseUrl` |
| `<ProductId>.MediaType` / `.ExcludedApps` | Per-product details |

Policy in `HKLM\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate` (`updatebranch`, `updatepath`) overrides both. An `updatepath` pointing to an LTSC network source will pull a freshly-migrated device back to LTSC bits.

### The ODT verbs that matter
| Element | What it does | Covers |
|---|---|---|
| `<Add>` | Installs products into the C2R install; sets channel, bitness | 16.0 C2R |
| `MigrateArch="TRUE"` (on Add) | Switches the whole install x86↔x64 in the same run, keeping products/languages | Existing 16.0 C2R |
| `<RemoveMSI/>` | Detects and removes MSI Office, Visio, Project 2007–2016 before installing | MSI only |
| `<IgnoreProduct ID="…"/>` (in RemoveMSI) | Keep an MSI product (only sensible for 2010/2013 versions) | MSI only |
| `<Remove>` / `<Remove All="TRUE"/>` | Uninstalls named C2R products/languages, or all C2R products | 16.0 C2R |
| `Language ID="MatchPreviousMSI"` | Installs the languages the removed MSI had | With RemoveMSI |
| `Language ID="MatchInstalled"` | Matches languages already in the C2R install | C2R in place |
| `Language ID="MatchOS" Fallback="en-us"` | OS display language | Fresh installs |
| `<Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>` | Closes Office apps instead of failing | All |

`RemoveMSI` needs a current ODT build and installs M365 Apps 1803+. It removes MSI suites **and** their MSI language packs/proofing tools; it doesn't remove SharePoint Designer 2010/InfoPath MSI in all cases — check leftovers with an uninstall-key query.

### Licensing hand-over
- Perpetual Office (volume or retail) writes licences/keys into **Windows SPP** (app ID `0ff1ce15-a989-479d-af46-f275c6370663`) or, for retail, Office's own token store.
- Microsoft 365 Apps uses **vNext per-user licence files** under `%localappdata%\Microsoft\Office\Licenses` acquired with the user's Entra identity (or device-based / Shared Computer Activation tokens). It doesn't need a SPP key.
- Removing a C2R product with ODT normally removes its SPP licences; failed/forced removals often leave **volume keys behind**. Leftovers don't block M365 Apps outright but cause the wrong product name in File > Account, KMS activation attempts in the event log, and confusing `OSPP.VBS` output. Clean them (Playbook D).
- Product ID must match the licence: `O365ProPlusRetail` ↔ E3/E5/Apps for enterprise; `O365BusinessRetail` ↔ Business Standard/Premium/Apps for business. Business users on a ProPlus install see "Unlicensed Product".

### Visio and Project
- Volume Visio/Project 2019/2021/2024 can coexist with M365 Apps if **same bitness**, **same channel as M365 Apps** (not PerpetualVL), and M365 Apps is at least **1808 / 2108 / 2408** respectively. Volume versions on the M365 channel still don't get feature updates.
- MSI Visio/Project 2016 can't coexist with any 16.0 C2R — replace with C2R volume (ODT with the 2016 volume product IDs `VisioProXVolume`/`ProjectProXVolume`) or subscription (`VisioProRetail`/`ProjectProRetail`).
- `<Remove All="TRUE"/>` removes Visio/Project too — remove the suite by ID if they should stay.

### Bitness
Microsoft recommends 64-bit. The risks: 32-bit COM/VSTO add-ins, ActiveX controls, VBA `Declare` statements without `PtrSafe`, and compiled Access `.mde/.accde` built in 32-bit. MSI → C2R is a natural point to switch (the MSI is removed anyway); C2R → C2R uses `MigrateArch`.
</details>

---
## Dependency Stack

```
[6] User experience: File > Account shows Microsoft 365 Apps, activated, correct channel, add-ins load
[5] Licence: correct SKU for product ID, vNext licence acquired (WAM/PRT), no stale SPP volume keys
[4] Single C2R install: only O365*Retail suite (+ intended Visio/Project), one bitness, M365 channel
[3] Removal phase complete: MSI 2007-2016 (RemoveMSI), C2R 16.0 suites (ODT Remove), C2R 15.0 (uninstall tool)
[2] Policy: no updatepath/updatebranch pinning to LTSC; Intune/ConfigMgr not re-installing the old suite
[1] Install engine: ODT current, source reachable (CDN or share), disk space, no concurrent C2R operation, admin rights
[0] OS: supported Windows build, .NET/VC runtimes current, pending reboot cleared
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Setup stops: conflict with an existing product | MSI 16.0 or C2R 15.0 present | Uninstall-key query; `Office\15.0\ClickToRun` |
| Both "Office LTSC" and "Microsoft 365" in Settings > Apps | One-pass install over volume C2R | `ProductReleaseIds` |
| File > Account says "Office LTSC Professional Plus 2024" after migration | Old suite still in `ProductReleaseIds` or stale SPP key | Triage 1 + 4 |
| Device reverts to LTSC build after a week | GPO/Intune `updatepath` to LTSC share; old deployment re-applied | officeupdate policy key; app assignments |
| Visio stops working after migration | Visio volume on PerpetualVL channel or other bitness; `Remove All` removed it | `ProductReleaseIds`, `Platform` |
| "Unlicensed Product" for Business Premium users | `O365ProPlusRetail` installed for a business SKU | `Get-MgUserLicenseDetail` |
| Outlook add-in / Access app broken | 32→64-bit change | Add-in load behaviour; COM add-in bitness |
| Languages missing after MSI removal | No `MatchPreviousMSI` | ODT config |
| Intune "Remove other versions" didn't remove LTSC | That option is `RemoveMSI` only | Fix with ODT Remove first |
| Install fails on RDS host | SCA not set / per-user licences | `SharedComputerLicensing` property |

---
## Validation Steps

1. **Inventory** — `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'` → good: only `O365ProPlusRetail` (+ intended Visio/Project). Bad: any `…Volume`/`…Retail` suite.
2. **No MSI leftovers** — uninstall-key query (B runbook triage 2) → good: empty.
3. **Channel** — `CDNBaseUrl`/`UpdateChannel` decode to target channel; policy key doesn't point at LTSC.
4. **Bitness** — `Platform` = intended value on every product.
5. **SPP clean** — Office app-ID rows with `PartialProductKey` → good: none, or only intended Visio/Project.
6. **Licence** — File > Account: "Subscription Product — Microsoft 365 Apps for enterprise" and user's UPN. `vNextDiag.ps1` from Microsoft (see `Activation-A.md`) shows a licence for the user.
7. **Update path works** — `& "$env:CommonProgramFiles\microsoft shared\ClickToRun\OfficeC2RClient.exe" /update user` → updates to the channel's latest build.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Pre-flight inventory.** Run `Get-OfficeMigrationReadiness.ps1` across a pilot group. Classify devices: MSI-only, LTSC volume, retail/OEM, Office 2013 C2R, mixed. Each class needs a different removal path.

**Phase 2 — Licence alignment.** Before deployment, map users to `O365ProPlusRetail` vs `O365BusinessRetail`. Mixed tenants usually need two deployments (two Intune apps / two XMLs) targeted by group.

**Phase 3 — Policy hygiene.** Remove or retarget LTSC-era GPO/Intune settings (`updatepath`, `updatebranch`, update deadlines tied to LTSC). Disable the old ConfigMgr/Intune Office application's assignment, or it will reinstall on the next evaluation.

**Phase 4 — Removal.** MSI → `RemoveMSI` inside the install XML. C2R 16.0 → separate `Remove` run (Win32 app / remediation / task sequence step). C2R 15.0 → uninstall tool. Reboot between removal and install if the log asks.

**Phase 5 — Install + licence.** Install with the right product/channel/bitness. Sign the user in (or deploy device-based licensing / SCA). Clean SPP leftovers.

**Phase 6 — Post-checks.** Validation steps 1–7; add-in health (Outlook *Slow and disabled add-ins*), Access line-of-business apps, Visio/Project activation.

ODT logs: path from `<Logging>` or `%temp%` of the running account (`C:\Windows\Temp` under SYSTEM / Intune). Search for `Error`, `RemoveMSI`, and the product IDs.

---
## Remediation Playbooks

<details><summary>Playbook A — LTSC 2024 volume → Microsoft 365 Apps, keep Visio LTSC 2024 volume</summary>

`remove.xml` (suite only):
```xml
<Configuration>
  <Remove><Product ID="ProPlus2024Volume"><Language ID="en-us" /></Product></Remove>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
```
`install.xml` (moves Visio to the M365 channel in the same install):
```xml
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail"><Language ID="MatchInstalled" /></Product>
    <Product ID="VisioPro2024Volume" PIDKEY="<VisioKey>"><Language ID="MatchInstalled" /></Product>
  </Add>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
```
Run `setup.exe /configure remove.xml`, then `setup.exe /configure install.xml`. Clean old ProPlus 2024 SPP keys (Playbook D). Rollback: remove `O365ProPlusRetail`, re-add `ProPlus2024Volume` with `Channel="PerpetualVL2024"` (Visio follows).
</details>

<details><summary>Playbook B — Office 2016 MSI (32-bit) + Visio 2016 MSI → Microsoft 365 Apps 64-bit + Visio Plan 2</summary>

```xml
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="MatchPreviousMSI" />
      <Language ID="MatchOS" Fallback="en-us" />
    </Product>
    <Product ID="VisioProRetail">
      <Language ID="MatchPreviousMSI" />
      <Language ID="MatchOS" Fallback="en-us" />
    </Product>
  </Add>
  <RemoveMSI />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\Temp\ODTLogs" />
</Configuration>
```
Pre-check 32-bit add-ins / Access MDEs. Target only users holding Visio Plan 2 with the Visio product (separate XML otherwise). Rollback: MSI reinstall from original media (keep the MSP/config.xml from the old deployment).
</details>

<details><summary>Playbook C — OEM retail Office (Home & Business 2024) on new laptops</summary>

1. Remove: `<Remove All="TRUE"/>` is fine here (nothing to keep).
2. Install M365 Apps per standard XML.
3. The user's personal Microsoft account licence for the OEM copy is untouched in their account; nothing to deactivate tenant-side.
4. Autopilot: put the removal Win32 app in the ESP blocking apps ahead of the M365 Apps app to avoid conflicts during provisioning.
</details>

<details><summary>Playbook D — Clean stale Office volume keys from SPP</summary>

```powershell
$app = '0ff1ce15-a989-479d-af46-f275c6370663'
$rows = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$app' AND PartialProductKey IS NOT NULL"
$rows | Format-Table Name, PartialProductKey, LicenseStatus, Description
# Remove only rows for the suite you removed (adjust the pattern; keep Visio/Project you still use)
$rows | Where-Object { $_.Name -match 'ProPlus20(19|21|24)|Standard20(19|21|24)' } |
  ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName UninstallProductKey }
```
Equivalent legacy command: `cscript "C:\Program Files\Microsoft Office\Office16\OSPP.VBS" /unpkey:<last5>` (OSPP.VBS depends on VBScript, which is being phased out of Windows — prefer CIM). Rollback: reinstall the key via `SoftwareLicensingService.InstallProductKey`.
</details>

<details><summary>Playbook E — Intune at scale</summary>

1. **Win32 app "Remove Office LTSC/retail C2R"**: ODT `setup.exe` + `remove.xml`; detection rule = registry `ProductReleaseIds` does **not** contain `Volume`/the retail suite IDs (use a PowerShell detection script); run as System.
2. **Microsoft 365 Apps app** (built-in type or Win32 with your XML) with a **dependency** on app 1 (auto-install), *Remove other versions* = Yes for MSI.
3. Unassign the old LTSC app and remove LTSC update settings (Settings catalog > Microsoft Office 2016 (Machine) > Updates).
4. Pilot ring first; report with `Get-OfficeMigrationReadiness.ps1` output collected by a remediation script.
</details>

---
## Evidence Pack

```powershell
$out = "C:\Temp\OfficeMigration-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory $out -Force | Out-Null
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue | Out-File "$out\c2r-config.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -ErrorAction SilentlyContinue | Out-File "$out\update-policy.txt"
'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
  Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -match 'Office|Visio|Project|Microsoft 365' } |
  Select-Object DisplayName, DisplayVersion, Publisher, UninstallString | Export-Csv "$out\uninstall-entries.csv" -NoTypeInformation
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
  Select-Object Name, PartialProductKey, LicenseStatus, Description | Export-Csv "$out\spp-office.csv" -NoTypeInformation
Get-ChildItem C:\Temp\ODTLogs, $env:TEMP, C:\Windows\Temp -Filter '*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-3) -and $_.Name -match '^[A-Z0-9-]+-\d{8}-\d{4}' } |
  Copy-Item -Destination $out -ErrorAction SilentlyContinue
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```
Or run `Scripts/Get-OfficeMigrationReadiness.ps1 -GenerateXml` for a classified report plus suggested remove/install XML.

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| C2R products/bitness/channel | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'` |
| MSI Office leftovers | Uninstall-key query filtered on `WindowsInstaller -eq 1` |
| Office 2013 C2R present | `Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun'` |
| Remove C2R products | `setup.exe /configure remove.xml` |
| Install M365 Apps | `setup.exe /configure install.xml` |
| Download source to share | `setup.exe /download install.xml` (with `SourcePath` set) |
| Force update | `OfficeC2RClient.exe /update user` |
| Office SPP keys | `Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-…' AND PartialProductKey IS NOT NULL"` |
| Remove a key | `Invoke-CimMethod -InputObject $row -MethodName UninstallProductKey` |
| User licences | `Get-MgUserLicenseDetail -UserId <UPN>` |
| Update policy | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'` |
| Readiness report | `.\Get-OfficeMigrationReadiness.ps1 -GenerateXml` |
| Add-in bitness inventory (per user) | `.\Get-OfficeAddinInventory.ps1 -TargetBitness x64` |

---
## 🎓 Learning Pointers
- The two coexistence rules plus the Visio/Project caveats (same bitness, same channel, minimum M365 Apps build) decide every migration path. — [Supported scenarios for installing different versions](https://learn.microsoft.com/microsoft-365-apps/deploy/install-different-office-visio-and-project-versions-on-the-same-computer)
- `RemoveMSI` is for MSI only; LTSC and retail Click-to-Run need `Remove`. — [Remove existing MSI versions of Office](https://learn.microsoft.com/microsoft-365-apps/deploy/upgrade-from-msi-version), [ODT configuration options](https://learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options)
- Bitness changes are cheap to deploy and expensive to support; inventory add-ins first. — [Choose between 64-bit and 32-bit](https://learn.microsoft.com/microsoft-365-apps/deploy/choose-bitness), [Change bitness](https://learn.microsoft.com/microsoft-365-apps/deploy/change-bitness)
- Match product ID to licence family; business plans use `O365BusinessRetail`. — [Product IDs supported by ODT](https://learn.microsoft.com/troubleshoot/microsoft-365-apps/office-suite-issues/product-ids-supported-office-deployment-click-to-run)
- Intune's Microsoft 365 Apps app type "Remove other versions" option maps to `RemoveMSI`. — [Add Microsoft 365 Apps to Windows devices with Intune](https://learn.microsoft.com/mem/intune/apps/apps-add-office365)
- Related: `Activation-A.md`, `OfficeVolumeActivation-A.md`, `Deployment-UpdateChannels-A.md`.
