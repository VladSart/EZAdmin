# Migrating MSI / LTSC / Retail Office to Microsoft 365 Apps — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage

**Scope:** moving a Windows device from **Office 2016/2013 MSI**, **Office LTSC 2024/2021 or Office 2019 volume (Click-to-Run)**, or **retail/OEM Office 2016–2024** to **Microsoft 365 Apps** (`O365ProPlusRetail` / `O365BusinessRetail`) — the install fails with a conflict, both suites end up installed, Visio/Project breaks, or the new install still shows the old product name. Activation problems *after* a clean M365 Apps install go to `Activation-B.md`; KMS/MAK problems on Office you are keeping go to `OfficeVolumeActivation-B.md`; channel/update issues go to `Deployment-UpdateChannels-B.md`.

Run on the affected device (elevated for the MSI/licence parts):

```powershell
# 1. What Click-to-Run Office is installed (products, bitness, version, channel)?
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue |
  Select-Object ProductReleaseIds, Platform, VersionToReport, CDNBaseUrl, UpdateChannel

# 2. Any MSI (Windows Installer) Office / Visio / Project left behind?
'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
  Where-Object { $_.PSObject.Properties.Name -contains 'WindowsInstaller' -and $_.WindowsInstaller -eq 1 -and $_.DisplayName -match '^Microsoft (Office|Visio|Project)' } |
  Select-Object DisplayName, DisplayVersion

# 3. Old Office 2013 Click-to-Run (15.0) — not removed by RemoveMSI
Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\15.0\ClickToRun'

# 4. Office licences still sitting in Windows SPP (volume keys left after removal)
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
  Select-Object Name, PartialProductKey, LicenseStatus
```

| Finding | Interpretation | Do this |
|---|---|---|
| `ProductReleaseIds` contains `ProPlus2024Volume` / `ProPlus2021Volume` / `ProPlus2019Volume` / `Standard20xxVolume` | Perpetual **volume C2R** on a `PerpetualVL20xx` channel. M365 Apps can't sit alongside it (same 16.0 C2R, overlapping apps, different channel) | **Fix 1** (remove first) → **Fix 2** |
| `ProductReleaseIds` contains `O365ProPlusRetail` **and** a `…Volume`/`…Retail` suite | Half-migrated: both suites in one C2R install. Licence and update channel are undefined | **Fix 1** removing only the old suite |
| Step 2 lists MSI Office/Visio/Project 2016/2013/2010 | MSI install blocks C2R 16.0 (same version, different technology) | **Fix 2** with `<RemoveMSI/>` (or Intune "Remove other versions") |
| Step 3 returns `True` | Office 2013 C2R present — `RemoveMSI` ignores it | **Fix 3** |
| `HomeBusiness2024Retail`, `HomeStudent2021Retail`, `ProPlusRetail` etc. (OEM / retail) | Pre-installed retail Office on new hardware | **Fix 1** then **Fix 2** |
| `VisioPro20xxVolume` / `ProjectPro20xxVolume` to keep | Allowed with M365 Apps **only** if same bitness, same channel as M365 Apps, and M365 Apps ≥ 2408 (2024) / 2108 (2021) / 1808 (2019) | **Fix 4** |
| M365 Apps installed but step 4 still shows `Office LTSC …` / `Office 19 …` rows with a key | Old volume licences left in SPP → wrong product name in File > Account, activation confusion | **Fix 5** |
| `Platform` = `x86` and target is x64 | Bitness change needed | **Fix 2** with `MigrateArch="TRUE"` |

> Decode `CDNBaseUrl` GUIDs: `492350f6…` Current, `55336b82…` Monthly Enterprise, `7ffbc6bf…` Semi-Annual Enterprise, `7983bac0…` PerpetualVL2024, `5030841d…` PerpetualVL2021, `f2e724c1…` PerpetualVL2019.

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
User opens Word → "Microsoft 365 Apps for enterprise" + subscription licence
 └── Single Click-to-Run install containing O365ProPlusRetail (or O365BusinessRetail)
      ├── No MSI Office/Visio/Project 2016 (same 16.0, different technology)  → RemoveMSI / Intune "Remove other versions"
      ├── No other 16.0 C2R Office suite (LTSC/2019/retail)                   → ODT <Remove> pass first
      ├── No Office 2013 C2R (15.0)                                           → SaRA / uninstall tool
      ├── Optional volume Visio/Project: same bitness + same channel + M365 Apps build ≥ 2408/2108/1808
      ├── Bitness consistent across every Office product (MigrateArch to switch)
      └── Channel: Current / MonthlyEnterprise / SemiAnnual (not PerpetualVL20xx), no GPO pinning updatepath to LTSC source
 └── Licence
      ├── User has an M365 Apps-capable licence (E3/E5/Apps for enterprise → O365ProPlusRetail;
      │     Business Standard/Premium/Apps for business → O365BusinessRetail)
      ├── No stale volume (KMS/MAK) Office keys in SPP from the removed product
      └── Identity: WAM/PRT sign-in works (→ Activation-B.md)
 └── Install path: ODT setup.exe /configure (or Intune M365 Apps app / ConfigMgr), source reachable (CDN or share), ~4 GB free, no other C2R operation running
```
</details>

---
## Diagnosis & Validation Flow

1. **Classify what's installed** — triage commands 1–3. Write down: suite product ID(s), Visio/Project IDs, MSI leftovers, bitness, current channel.
2. **Check the target licence before touching the device.**
   ```powershell
   # Graph PowerShell, any admin workstation
   Connect-MgGraph -Scopes User.Read.All
   Get-MgUserLicenseDetail -UserId '<UPN>' | Select-Object SkuPartNumber
   ```
   Expected: `SPE_E3`/`SPE_E5`/`ENTERPRISEPACK`/`OFFICESUBSCRIPTION` → install `O365ProPlusRetail`; `O365_BUSINESS_PREMIUM`/`SPB`/`O365_BUSINESS` → `O365BusinessRetail`. Wrong product ID for the licence = "Unlicensed Product" after migration.
3. **Check for a policy that will drag it back to LTSC.**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -ErrorAction SilentlyContinue |
     Select-Object updatebranch, updatepath, enableautomaticupdates
   ```
   `updatepath` pointing to an LTSC share or `updatebranch` set to an LTSC value overrides ODT. Remove/repoint the GPO/Intune setting first.
4. **Check readiness:** free space on C: ≥ 4 GB (`Get-PSDrive C`), no running C2R install (`Get-Process OfficeClickToRun, OfficeC2RClient -ErrorAction SilentlyContinue` — a busy `OfficeC2RClient` means an operation is in progress), pending reboot.
5. **After migration validate:** `ProductReleaseIds` contains only the M365 product (+ any intended Visio/Project), `CDNBaseUrl` decodes to the target channel, File > Account shows *Microsoft 365 Apps for enterprise / business*, triage step 4 shows no LTSC/2019 keys.

---
## Common Fix Paths

<details><summary>Fix 1 — Remove the existing Click-to-Run suite (LTSC / 2019 / retail) first</summary>

Download the Office Deployment Tool (`setup.exe`) from Microsoft, then create `remove.xml`. Remove only the suite if Visio/Project should stay:

```xml
<Configuration>
  <Remove>
    <Product ID="ProPlus2024Volume">
      <Language ID="en-us" />
    </Product>
  </Remove>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\Temp\ODTLogs" />
</Configuration>
```
- Use the exact ID from `ProductReleaseIds`; list every installed language (or use `<Remove All="TRUE" />` to remove **every** C2R product including Visio/Project).
- Run: `.\setup.exe /configure .\remove.xml` (elevated). Check `ProductReleaseIds` afterwards.
- Rollback: reinstall the old product from its own ODT config (keep a copy of it before removing).
- Why not one pass? Installing M365 Apps over a perpetual-volume C2R install puts both suites into one install on one channel — unsupported and the cause of most "both suites present" tickets. Remove, then install.
</details>

<details><summary>Fix 2 — Install Microsoft 365 Apps (removes MSI Office in the same pass)</summary>

`install.xml`:
```xml
<Configuration>
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise" MigrateArch="TRUE">
    <Product ID="O365ProPlusRetail">
      <Language ID="MatchPreviousMSI" />
      <Language ID="MatchOS" Fallback="en-us" />
      <ExcludeApp ID="Groove" />
    </Product>
  </Add>
  <RemoveMSI />
  <Property Name="SharedComputerLicensing" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\Temp\ODTLogs" />
</Configuration>
```
- `O365BusinessRetail` for Business plans; set `Channel` to your standard (see `Deployment-UpdateChannels-A.md`); `SharedComputerLicensing=1` for RDS/AVD.
- `<RemoveMSI/>` removes MSI Office, Visio, Project 2007–2016. To keep an MSI product, add `<IgnoreProduct ID="VisPro" />` inside it — but MSI Visio/Project 2016 **can't** coexist with C2R 16.0, so ignoring is only valid for 2010/2013 MSI.
- Run: `.\setup.exe /configure .\install.xml`. Reboot if prompted.
- Intune: the **Microsoft 365 Apps (Windows 10 and later)** app type has *Remove other versions* = Yes, which does the `RemoveMSI` part only — LTSC/retail C2R still needs Fix 1 (Win32 app or remediation) first.
</details>

<details><summary>Fix 3 — Office 2013 Click-to-Run (15.0) is present</summary>

`RemoveMSI` doesn't touch it, and ODT 16.0 `Remove` doesn't target 15.0 products. Uninstall it from **Settings > Apps** (or Control Panel) first, or use Microsoft's *Uninstall Office* support tool (Get Help / SaRA enterprise scenario) for broken installs, reboot, then run Fix 2.
</details>

<details><summary>Fix 4 — Keep volume Visio / Project LTSC alongside Microsoft 365 Apps</summary>

Supported if: same bitness, M365 Apps build ≥ 2408 (Visio/Project 2024), ≥ 2108 (2021) or ≥ 1808 (2019), and the volume product uses **the M365 Apps channel**, not `PerpetualVL20xx`. Install them together:
```xml
<Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
  <Product ID="O365ProPlusRetail"><Language ID="en-us" /></Product>
  <Product ID="VisioPro2024Volume" PIDKEY="<VisioGVLKorMAK>"><Language ID="en-us" /></Product>
</Add>
```
- If users have Visio Plan 2 / Project Plan 3/5 subscriptions instead, use `VisioProRetail` / `ProjectProRetail` and drop the key.
- After the move, check activation of the volume Visio with `OfficeVolumeActivation-B.md` (the KMS host must still host the Visio 2024 key).
</details>

<details><summary>Fix 5 — Old volume licences still in SPP after migration</summary>

```powershell
# Show, then remove ONLY the old perpetual Office keys (not the M365 subscription — that isn't a SPP key)
$old = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
  Where-Object { $_.Name -match 'Office ?(19|21|24)|LTSC|2019|2021|2024|Office16(ProPlus|Standard)VL' -and $_.Name -notmatch 'Visio|Project' }
$old | Format-Table Name, PartialProductKey, LicenseStatus
$old | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName UninstallProductKey }
```
- Leave Visio/Project keys you deliberately kept (Fix 4). Close Office, reopen, check File > Account.
- Rollback: re-install the key with `Invoke-CimMethod -InputObject (Get-CimInstance SoftwareLicensingService) -MethodName InstallProductKey -Arguments @{ProductKey='<key>'}`.
</details>

---
## Escalation Evidence

```
Device / UPN:                          ______________ / ______________
Before: ProductReleaseIds / Platform:  ______________ / x86|x64     Channel (CDNBaseUrl): ______________
MSI Office/Visio/Project present:      Y/N  (_______________)       Office 2013 C2R present: Y/N
Target product ID + channel:           O365ProPlusRetail|O365BusinessRetail  /  ______________
User licence SKU(s):                   ______________
Visio/Project strategy:                keep volume (ID ______) / subscription / remove
Policy overrides (updatepath/branch):  ______________
ODT configs used:                      remove.xml / install.xml attached  Y/N
Result / error text:                   ______________________________________
Attached: C:\Temp\ODTLogs\*.log, %temp%\<machine>-*.log, Get-OfficeMigrationReadiness CSV
```

---
## 🎓 Learning Pointers
- Two compatibility rules explain almost every failure: no two 16.0 products with different install technologies (MSI vs C2R), and no two C2R products of different versions with overlapping apps. — [Supported scenarios for installing different versions of Office, Visio and Project](https://learn.microsoft.com/microsoft-365-apps/deploy/install-different-office-visio-and-project-versions-on-the-same-computer)
- `RemoveMSI` covers MSI 2007–2016 only; Click-to-Run LTSC/2019/retail needs the ODT `Remove` element. — [Remove existing MSI versions of Office when upgrading](https://learn.microsoft.com/microsoft-365-apps/deploy/upgrade-from-msi-version)
- Volume Visio/Project can stay, but only on the M365 Apps channel and bitness, with a minimum M365 Apps build. — same Learn article (caveats 1–3)
- `MigrateArch="TRUE"` switches 32→64-bit during the same run; 32-bit COM add-ins and compiled Access (`.mde`/`.accde`) files break on 64-bit — inventory them first. — [Change a Microsoft 365 Apps installation from 32-bit to 64-bit](https://learn.microsoft.com/microsoft-365-apps/deploy/change-bitness)
- ODT XML reference for every element used above. — [Configuration options for the Office Deployment Tool](https://learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options)
- Deep dive: `OfficeToM365Migration-A.md`; inventory + XML generator: `Scripts/Get-OfficeMigrationReadiness.ps1`.
