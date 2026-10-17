# Microsoft 365 Apps Activation & Licensing — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers "Unlicensed Product", "Product Deactivated", "Subscription expired" banners, sign-in loops, wrong-account activation, Shared Computer Activation (SCA) and device-based licensing on Click-to-Run installs.

**Scope:** Microsoft 365 Apps for enterprise/business (Click-to-Run, vNext licensing). Not volume-licensed Office LTSC/2019/2021 KMS/MAK — for OS activation see `Windows/Troubleshooting/VolumeActivation-B.md`. Update channel / repair issues → `Deployment-UpdateChannels-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run **as the affected user** (not elevated as a different admin account — licensing and identity are per-user).

```powershell
# 1. What is installed and in which licensing mode?
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' |
  Select-Object ProductReleaseIds, Platform, VersionToReport, SharedComputerLicensing

# 2. SCA forced by policy?
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing' -ErrorAction SilentlyContinue

# 3. Which vNext licences does this user hold on this device?
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\Licenses" -Recurse -File -ErrorAction SilentlyContinue |
  Select-Object FullName, LastWriteTime
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing" -File -ErrorAction SilentlyContinue |
  Select-Object Name, LastWriteTime     # SCA tokens live here

# 4. Is the device/user identity healthy for WAM sign-in?
dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|AzureAdPrt |WorkplaceJoined|TenantName'

# 5. Can the client reach licensing endpoints?
'ols.officeapps.live.com','login.microsoftonline.com','officeclient.microsoft.com' |
  ForEach-Object { [pscustomobject]@{ Host = $_; Tcp443 = (Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded } }
```

| Result | Meaning | Go to |
|---|---|---|
| `SharedComputerLicensing` = 1 (C2R or policy) on a **single-user** laptop | SCA on a personal device — 30-day token model, no 5-device count | Fix 4 (disable) or accept |
| `SharedComputerLicensing` absent/0 on an **RDS/AVD/Citrix** host | Users burn their 5-PC activations on the host; "too many devices" | Fix 4 (enable) |
| `Licenses` folder empty, banner says Unlicensed | Never activated or cleared — sign-in/identity problem | Fix 1 → Fix 2 |
| Licence files exist but banner still says Unlicensed / Subscription expired | Stale cached licence after SKU change, renewal or tenant move | Fix 3 (reset) |
| `AzureAdPrt : NO` on an Entra/hybrid-joined device | WAM can't silently get a token → sign-in loop | Fix 2 |
| `WorkplaceJoined : YES` with a *different tenant* | Wrong account cached by WAM | Fix 2 |
| Any endpoint `False` | Proxy/TLS-inspection/firewall blocking licensing | Fix 5 |
| ProductReleaseIds shows `O365BusinessRetail` but user holds E3/E5 (or vice-versa) | Installed SKU ≠ licence (works but may show wrong features; Business SKU blocked on SCA GPO path) | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User-based activation (default)
└─ Entra user has a licence containing Microsoft 365 Apps service plan (OFFICESUBSCRIPTION / O365_BUSINESS) ENABLED
   └─ User signs in to Office with THAT identity (WAM / Microsoft.AAD.BrokerPlugin)
      └─ Device: PRT healthy (Entra/hybrid joined) OR user account added under "Access work or school"
         └─ Network: login.microsoftonline.com + ols.officeapps.live.com reachable on 443 (no TLS break)
            └─ Licensing service issues licence → %LOCALAPPDATA%\Microsoft\Office\Licenses\
               └─ User has < 5 activated PCs/Macs (else prompt to sign out of one)
                  └─ Office apps show "Subscription Product" in File > Account

Shared Computer Activation (RDS/AVD/Citrix/shared kiosks)
└─ SharedComputerLicensing=1 (ODT, C2R registry or GPO) — reboot applied
   └─ No pre-existing per-user activation left on the device (else reset)
      └─ Each user still has their own licence (no anonymous use)
         └─ Token written per user to %LOCALAPPDATA%\Microsoft\Office\16.0\Licensing (or SCLCacheOverrideDirectory)
            └─ Token renewed online before ~30-day expiry → else Reduced Functionality

Device-based licensing (Education/enterprise "Microsoft 365 Apps for enterprise (device)")
└─ Device is Entra joined / hybrid joined and in an Entra group assigned the device licence
   └─ Supported Windows + M365 Apps version → no user licence or sign-in needed
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the licence server-side** (Graph, admin):
   ```powershell
   Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome
   Get-MgUserLicenseDetail -UserId '<UPN>' | ForEach-Object {
     $_.ServicePlans | Where-Object ServicePlanName -match 'OFFICESUBSCRIPTION|O365_BUSINESS|OFFICE_BUSINESS' |
       Select-Object @{n='Sku';e={$_.ServicePlanName}}, ProvisioningStatus }
   ```
   Expected: a plan with `ProvisioningStatus = Success`. `Disabled` → someone unticked "Microsoft 365 Apps" inside the SKU. No row → no Apps entitlement (Exchange-only/F-SKUs, E1 web-only).

2. **Check what account Office is actually signed in as:** File → Account → "Belongs to:" — or:
   ```powershell
   Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -ErrorAction SilentlyContinue |
     ForEach-Object { Get-ItemProperty $_.PSPath | Select-Object EmailAddress, ProviderId, SignInName }
   ```
   Expected: one identity matching the licensed UPN. Multiple / personal MSA / old tenant → Fix 2/3.

3. **Read the vNext licence state with Microsoft's own script** (ships with the install):
   ```powershell
   $vnd = Get-ChildItem "${env:ProgramFiles}\Microsoft Office\Office16\vNextDiag.ps1",
                        "${env:ProgramFiles(x86)}\Microsoft Office\Office16\vNextDiag.ps1" -ErrorAction SilentlyContinue |
          Select-Object -First 1
   if ($vnd) { & $vnd.FullName } else { 'vNextDiag.ps1 not present on this build' }
   ```
   Good: a licence entry with the expected product and a valid/active state. Expired or a licence for a SKU the user no longer owns → Fix 3.
   > `OSPP.VBS /dstatus` does **not** report vNext subscription licences — an empty OSPP result is normal on M365 Apps and is not a fault.

4. **SCA only — confirm the token**:
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name, LastWriteTime
   ```
   Token older than ~30 days, or none → token renewal/sign-in failing (Fix 2/5). If FSLogix/roaming profile is in use, confirm the path is inside the profile container (or `SCLCacheOverrideDirectory` points to a roaming share).

5. **Event evidence:** Event Viewer → Applications and Services Logs → *Microsoft Office Alerts*, and `Microsoft-Windows-AAD/Operational` for WAM token errors (e.g. `0xCAA*` codes = network/proxy/TLS to Entra).

---
## Common Fix Paths

<details><summary>Fix 1 — Licence missing or Apps plan disabled (server side)</summary>

```powershell
Connect-MgGraph -Scopes 'User.ReadWrite.All','Organization.Read.All' -NoWelcome
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{n='Enabled';e={$_.PrepaidUnits.Enabled}}
# Assign or re-enable via the group/portal that owns the licence — if group-based licensing, fix it on the GROUP
```
Then on the client: close all Office apps, reopen, File → Account → **Update License** (or sign out/in). Allow up to ~1 hour after assignment for propagation. If licensing is group-based, see `M365/Licensing/Group-Based-Licensing-A.md` before editing the user directly.
</details>

<details><summary>Fix 2 — Wrong account / sign-in loop (WAM)</summary>

1. Settings → Accounts → **Access work or school** — remove stale accounts from other tenants (do **not** remove the account that joined the device).
2. Re-register the Entra broker plug-in (as the user, safe):
   ```powershell
   if (-not (Get-AppxPackage Microsoft.AAD.BrokerPlugin)) {
     Add-AppxPackage -Register "$env:windir\SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\Appxmanifest.xml" -DisableDevelopmentMode -ForceApplicationShutdown
   }
   ```
3. Hybrid/Entra-joined with `AzureAdPrt : NO` → fix the PRT first (`EntraID/Troubleshooting/PRT-Issues-B.md`); Office cannot sign in silently without it.
4. Sign out of Office (File → Account → Sign out), close all apps, reopen and sign in with the licensed UPN.
</details>

<details><summary>Fix 3 — Reset activation state (stale licence, tenant move, SKU change, "Subscription expired" after renewal)</summary>

Preferred: Get Help → *Microsoft 365 activation troubleshooter*, or Support and Recovery Assistant **Enterprise** `ResetOfficeActivation` scenario for remote/bulk. Manual equivalent (as the user, Office closed) — **back up first**:
```powershell
Get-Process WINWORD,EXCEL,POWERPNT,OUTLOOK,ONENOTE,MSACCESS,MSPUB,VISIO,WINPROJ,lync,ms-teams -ErrorAction SilentlyContinue | Stop-Process -Force
$bk = "$env:TEMP\OfficeActivationBackup_$(Get-Date -f yyyyMMddHHmmss)"; New-Item $bk -ItemType Directory | Out-Null
reg export 'HKCU\Software\Microsoft\Office\16.0\Common\Identity' "$bk\Identity.reg" /y | Out-Null
foreach ($p in "$env:LOCALAPPDATA\Microsoft\Office\Licenses","$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing") {
  if (Test-Path $p) { Copy-Item $p "$bk\$(Split-Path $p -Leaf)" -Recurse; Remove-Item "$p\*" -Recurse -Force }
}
Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -Recurse -Force -ErrorAction SilentlyContinue
# Office cached credentials in Credential Manager
cmdkey /list | Select-String 'MicrosoftOffice1[56]_Data' | ForEach-Object {
  $t = ($_ -replace '.*Target:\s*','').Trim(); cmdkey /delete:$t | Out-Null }
"Backup: $bk — reopen Word and sign in"
```
**Rollback:** `reg import "$bk\Identity.reg"` and copy the folders back. The reset does not uninstall Office or touch documents; the user just signs in again.
</details>

<details><summary>Fix 4 — Turn Shared Computer Activation on/off on an existing install (no reinstall)</summary>

SCA can be changed post-install — reboot required, then reset any per-user activations made before the change (Fix 3 per user, or FSLogix profile reset).
```powershell
# Enable (elevated) — C2R config value (REG_SZ)
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name SharedComputerLicensing -Value '1' -Type String
# Or GPO: Computer Config > Admin Templates > Microsoft Office 2016 (Machine) > Licensing Settings > "Use shared computer activation"
# Optional roaming token location for non-persistent VDI:
# GPO "Specify the location to save the licensing token" (SCLCacheOverride / SCLCacheOverrideDirectory)
Restart-Computer -Confirm
```
Disable: set the value to `'0'` and remove the GPO. **Note:** the GPO path is documented as not applicable to Microsoft 365 Apps for business — use the registry/ODT method for Business Premium RDS hosts.
</details>

<details><summary>Fix 5 — Network / proxy / TLS inspection</summary>

```powershell
netsh winhttp show proxy
'ols.officeapps.live.com','login.microsoftonline.com','officeclient.microsoft.com','officecdn.microsoft.com' |
  ForEach-Object { [pscustomobject]@{Host=$_; Tcp443=(Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded} }
```
Bypass TLS inspection and authenticated proxy for the *Microsoft 365 Common and Office Online* endpoint set (`*.officeapps.live.com`, `login.microsoftonline.com`, `*.office.com`). WAM acquires tokens in the user's context; an authenticated proxy that prompts breaks silent token acquisition.
</details>

<details><summary>Fix 6 — "Too many devices" (5-PC limit) or installed SKU mismatch</summary>

- User: https://myaccount.microsoft.com → *Office apps / Devices* → sign out of old PCs. Admin cannot raise the limit; RDS hosts must use SCA (Fix 4).
- SKU mismatch (e.g. `O365BusinessRetail` installed, user moved to E3): Office keeps working while the licence entitles the installed product, but switch product for features/policy support:
  ```powershell
  # Elevated — check the installed IDs first
  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration').ProductReleaseIds
  ```
  Change via ODT `configuration.xml` (`<Product ID="O365ProPlusRetail">` + `<Remove><Product ID="O365BusinessRetail"/></Remove>`) — see `Deployment-UpdateChannels-A.md`.
</details>

---
## Escalation Evidence
```
Ticket: M365 Apps activation — <ticket #>
User UPN: <UPN>                 Tenant: <tenantName>.onmicrosoft.com
Device: <hostname>  Join state (dsregcmd): AzureAdJoined=<>  DomainJoined=<>  AzureAdPrt=<>
Banner / error text + code: <e.g. "Unlicensed Product", 0xCAA70004>
ProductReleaseIds: <>   VersionToReport: <>   Channel: <>
SharedComputerLicensing (C2R / Policy): <> / <>   Host type: <laptop | RDS | AVD pooled | kiosk>
Graph licence: SKU <>  Apps service plan status <Success/Disabled/none>
Licenses folder files: <count, newest timestamp>   SCA token newest: <timestamp>
vNextDiag.ps1 output: <attached>
Endpoints 443 (ols/login/officeclient): <T/F/T>   Proxy: <>
Already tried: [ ] Update License [ ] sign out/in [ ] reset (Fix 3) [ ] BrokerPlugin re-register [ ] reboot
Get-M365AppsActivationDiagnostics.ps1 CSV: <attached>
```

---
## 🎓 Learning Pointers
- **vNext is per-user, per-device files — not a product key.** That's why `OSPP.VBS` shows nothing and why clearing `%LOCALAPPDATA%\Microsoft\Office\Licenses` forces a fresh licence. [Reset Microsoft 365 Apps activation state](https://learn.microsoft.com/office/troubleshoot/activation/reset-office-365-proplus-activation-state)
- **SCA is a switch, not a reinstall.** Registry, GPO or SaRA can enable it on an existing install; earlier per-user activations must be reset afterwards. [Overview of shared computer activation](https://learn.microsoft.com/microsoft-365-apps/licensing-activation/overview-shared-computer-activation)
- **"Unlicensed Product" is usually identity, not licensing** — a stale work/school account or broken WAM beats a missing licence in frequency. [Unlicensed Product errors](https://learn.microsoft.com/office/troubleshoot/activation/unlicensed-product-error)
- **Pick the licensing mode deliberately:** user-based (5 PCs), SCA (RDS/VDI, unlimited hosts, licence per user), device-based (no user licence, Entra-registered device). [Licensing and activation overview](https://learn.microsoft.com/microsoft-365-apps/licensing-activation/overview-licensing-activation-microsoft-365-apps)
- Deeper reasoning, SCA token lifecycle on FSLogix/non-persistent VDI and fleet audit: `Activation-A.md` and `Scripts/Get-M365AppsActivationDiagnostics.ps1`.
