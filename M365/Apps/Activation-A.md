# Microsoft 365 Apps Activation & Licensing — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** Click-to-Run Microsoft 365 Apps for enterprise / business (and Visio/Project subscription) on Windows 10/11 and Windows Server RDS/AVD hosts; the three subscription licensing modes — **user-based**, **Shared Computer Activation (SCA)**, **device-based**; identity (WAM) dependencies; reset and re-activation.
- **Out of scope:** Volume-licensed Office LTSC 2021/2024 and Office 2019 (KMS/MAK/ADBA — now covered in `OfficeVolumeActivation-A.md`, added run 287), Office for Mac (licence file in `~/Library/Group Containers/UBF8T346G9.Office/` — see `macOS/`), Entra licence assignment mechanics (`M365/Licensing/`), channel/servicing (`Deployment-UpdateChannels-A.md`).
- **Assumes:** the engineer can run PowerShell as the affected user and elevated, and has Graph `User.Read.All` for the server-side check.

---
## How It Works
<details><summary>Full architecture</summary>

### 1. The "vNext" licensing model
Since roughly Version 1909/2019, subscription Office no longer uses the Software Protection Platform (SPP/OSPP) product-key store. Instead the client requests a **licence document** from the Office Licensing Service (`ols.officeapps.live.com`) after the user authenticates to Entra ID. The licence is written per user to:

```
%LOCALAPPDATA%\Microsoft\Office\Licenses\<n>\<licenseId>   (user-based vNext licences)
%LOCALAPPDATA%\Microsoft\Office\16.0\Licensing\             (SCA licensing tokens; legacy location)
```

Consequences engineers trip over:
- `cscript OSPP.VBS /dstatus` returns nothing useful for subscription installs — **this is not a failure**. Microsoft ships `vNextDiag.ps1` (in the `Office16` program folder on current builds) to dump vNext licence state instead. (OSPP.VBS is also VBScript and caught up in the VBScript deprecation — see `Windows/Troubleshooting/VBScriptDeprecation-A.md`.)
- Licences are bound to **user profile + device**. Copying a profile to a new machine, or restoring an image with another user's `Licenses` folder, produces odd "belongs to someone else" states; reset fixes it.
- The licence carries an expiry and is renewed in the background while the user's subscription is valid. If renewal cannot reach the service for long enough, Office drops to **Reduced Functionality Mode** (view/print only).

### 2. Identity: WAM is the front door
Office signs in through the **Web Account Manager** (WAM) and the Entra broker plug-in (`Microsoft.AAD.BrokerPlugin`). On an Entra-joined or hybrid-joined device, the **Primary Refresh Token (PRT)** lets Office acquire tokens silently — that's the "it just activates" experience. Failure points:
- PRT missing/expired (`dsregcmd /status` → `AzureAdPrt : NO`) → interactive prompts or loops.
- Extra accounts under *Access work or school* from other tenants → Office picks or offers the wrong one.
- Cached Office identities in `HKCU\Software\Microsoft\Office\16.0\Common\Identity\Identities` pointing at an old tenant/UPN after a migration or UPN change.
- Proxy/TLS inspection on `login.microsoftonline.com` → WAM `0xCAA*` errors in `Microsoft-Windows-AAD/Operational`.

Legacy registry tweaks (`DisableADALatopWAMOverride`, `EnableADAL=0`, `DisableAADWAM`) are **unsupported workarounds** from the ADAL era; remove them rather than add them.

### 3. The three licensing modes

| Mode | Who consumes the licence | Activation limit | Typical host | Enabled by |
|---|---|---|---|---|
| User-based (default) | Signed-in user | 5 PCs/Macs + 5 tablets + 5 phones per user | Personal laptop/desktop | Default |
| Shared Computer Activation | Signed-in user (still needs a licence) | Not counted against the 5 | RDS, AVD pooled, Citrix, shared kiosk/lab | ODT `SharedComputerLicensing="1"`, C2R registry `SharedComputerLicensing`="1", GPO *Use shared computer activation*, or SaRA |
| Device-based | The device (Entra group membership) | N/A — no user licence or sign-in required for activation | Education labs, shared enterprise devices | Device licence assigned to an Entra group containing Entra/hybrid-joined devices |

**SCA mechanics.** When SCA is on, Office does not perform a normal per-user activation. On first launch per user it obtains a **licensing token** valid for about 30 days and renews it automatically while the user keeps using Office online. On non-persistent VDI the token must roam — keep `%LOCALAPPDATA%\Microsoft\Office\16.0\Licensing` inside the FSLogix profile container, or redirect with the GPO *Specify the location to save the licensing token* (`SCLCacheOverride` + `SCLCacheOverrideDirectory`). Without roaming, every logon does a fresh token request — which works, but adds latency and fails hard if the licensing service is unreachable.

**SCA can be enabled after installation.** Registry, GPO and SaRA all work on an existing install; a reboot is required, and **any user who activated before SCA was enabled must have their activation reset**. (The GPO route is documented as unsupported for Microsoft 365 Apps for business — use the C2R registry value or ODT on Business Premium RDS hosts.)

**SKU reality check.** Licences include either the enterprise Apps plan (`OFFICESUBSCRIPTION`, product `O365ProPlusRetail`) or the business plan (`O365_BUSINESS`, product `O365BusinessRetail`). The installed product ID (`ProductReleaseIds`) and the licence plan should match; mismatches often "work" but break policy-dependent features and surprise people after a licence migration.

### 4. Activation sequence (user-based)

```
User launches Word
  │
  ├─ Read HKCU Identity cache ──► existing identity? ──yes──► WAM GetTokenSilently ─┐
  │                                     │no                                         │
  │                                     └──► WAM interactive sign-in ───────────────┤
  │                                                                                 ▼
  │                                                          Entra issues token (PRT-backed if joined)
  │                                                                                 │
  ├─ POST to ols.officeapps.live.com with token ◄──────────────────────────────────┘
  │       │
  │       ├─ user has Apps plan + < 5 PCs ──► licence → %LOCALAPPDATA%\...\Licenses → "Subscription Product"
  │       ├─ no Apps plan / plan disabled ──► "Unlicensed Product" / "Product Deactivated"
  │       └─ device limit reached ──────────► prompt to sign out of another device
  │
  └─ Background: renew licence before expiry; failure for extended period → Reduced Functionality Mode
```
</details>

---
## Dependency Stack
```
[7] Office app shows "Subscription Product" (File > Account)
[6] Valid licence document / SCA token in the user's profile
[5] Office Licensing Service reachable (ols.officeapps.live.com:443, no TLS break)
[4] Entra access token for the licensed identity (WAM + BrokerPlugin)
[3] Device identity: PRT (Entra/hybrid joined) or account added via Access work or school
[2] Licensing mode configured correctly for the host type (user / SCA / device)
[1] Entra: user (or device group) assigned a SKU with the Apps service plan ENABLED
[0] Click-to-Run install healthy, product ID matches SKU family
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| Red "Unlicensed Product" bar, user is licensed | Wrong/stale identity cached; WAM failure | Identity key, *Access work or school*, `dsregcmd` PRT |
| "Product Deactivated" | Licence removed or Apps plan disabled inside SKU; user removed from licensing group | Graph `Get-MgUserLicenseDetail` service plan status |
| "Subscription expired" after renewal | Cached licence from expired subscription | Reset activation (Playbook 2) |
| "We can't activate — too many devices" on RDS | SCA not enabled; users burn 5-PC slots per session host | C2R `SharedComputerLicensing` |
| Every logon on AVD pooled host prompts/slow first launch | SCA token not roaming in FSLogix/non-persistent profile | Token folder location vs profile container, `SCLCacheOverrideDirectory` |
| "This product can't be used for shared computer activation" (0x80004005 family) | SKU without SCA rights, or pre-existing per-user activation | SKU plan; reset after enabling SCA |
| Sign-in window flashes and closes / blank | BrokerPlugin unregistered/corrupt; WebView/AAD broker blocked | `Get-AppxPackage Microsoft.AAD.BrokerPlugin`, AAD Operational log |
| `0xCAA70004`, `0xCAA82EE2`, `0xCAA20003` | Network/proxy/TLS to Entra endpoints | `netsh winhttp show proxy`, Test-NetConnection 443 |
| Office belongs to previous employee on reassigned laptop | Licence/identity in old profile; shared profile reused | Licences folder in that profile; reset |
| Works for one user, not another, same device | Per-user licence/identity — device is fine | Compare `%LOCALAPPDATA%` licence folders |
| Reduced Functionality Mode on travelling laptops | Licence renewal blocked for an extended period (captive portal, blocked endpoints) | Last write time of licence files |
| Business features missing after E3 migration | Installed `O365BusinessRetail` but licensed for enterprise | `ProductReleaseIds` vs Graph SKU |

---
## Validation Steps
1. **Licence assigned and Apps plan enabled**
   ```powershell
   (Get-MgUserLicenseDetail -UserId '<UPN>').ServicePlans |
     Where-Object ServicePlanName -match '^(OFFICESUBSCRIPTION|O365_BUSINESS|OFFICE_BUSINESS)$' |
     Select-Object ServicePlanName, ProvisioningStatus
   ```
   Good: `Success`. Bad: `Disabled`, `PendingProvisioning` for > 1 h, or no row.
2. **Install product and mode**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' | Select-Object ProductReleaseIds, SharedComputerLicensing, VersionToReport
   ```
   Good: product family matches the licence; SCA = 1 on multi-session hosts only. Bad: SCA missing on RDS/AVD; `O365BusinessRetail` with enterprise licence.
3. **Device identity**
   ```powershell
   dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|AzureAdPrt |TenantName'
   ```
   Good: joined + `AzureAdPrt : YES` with the correct tenant. Bad: PRT NO → fix device identity first.
4. **Cached Office identity**
   ```powershell
   Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -EA SilentlyContinue | Get-ItemProperty | Select-Object EmailAddress, ProviderId
   ```
   Good: one entry, licensed UPN. Bad: old UPN/tenant, personal MSA as primary.
5. **Licence/token present and fresh**
   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\Licenses","$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing" -Recurse -File -EA SilentlyContinue |
     Sort-Object LastWriteTime -Descending | Select-Object -First 5 FullName, LastWriteTime
   ```
   Good: recent files. Bad: none, or very old while the user works offline.
6. **Endpoints** — `Test-NetConnection ols.officeapps.live.com -Port 443` and `login.microsoftonline.com` → `TcpTestSucceeded : True`, no TLS-inspection certificate in the chain.
7. **vNextDiag.ps1** — run from the `Office16` program folder; good = licence for the expected product in an active state.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Entitlement (server).** Confirm SKU, plan status, group-licensing errors (`Get-MgUser -Property LicenseAssignmentStates`). Don't touch the client until this is green.

**Phase 2 — Mode fit.** Is the host multi-user? Then SCA must be on before any user activates. Is it a lab with device licences? Then the device must be in the assigned group and Entra-registered. Wrong mode explains most "works on laptop, not on the server" cases.

**Phase 3 — Identity.** PRT, *Access work or school* accounts, cached Office identities, BrokerPlugin package. Read `Microsoft-Windows-AAD/Operational` for the exact WAM error.

**Phase 4 — Network.** Proxy (WinHTTP *and* user WinINET), TLS inspection, conditional access blocking the Office client app (sign-in logs: app *Microsoft Office*, look for CA failures — also see `EntraID/` CA runbooks).

**Phase 5 — Local state.** Stale licences, mismatched product IDs, old SCA tokens. Reset and re-sign-in.

**Phase 6 — Install.** Only if everything above is clean: Online Repair (`Deployment-UpdateChannels-B.md` Fix 3).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Converting an RDS/AVD host to SCA after users already activated</summary>

1. Drain the host (`Set-RDSessionHost -NewConnectionAllowed No` or AVD drain mode).
2. Enable SCA (elevated):
   ```powershell
   Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name SharedComputerLicensing -Value '1' -Type String
   ```
   or GPO *Use shared computer activation* (not for Microsoft 365 Apps for business).
3. If profiles roam (FSLogix), decide token location: inside the container (default `%LOCALAPPDATA%` is included unless excluded) or GPO *Specify the location to save the licensing token* to a per-user share.
4. Reboot.
5. Reset per-user activation for every existing profile (Playbook 2 at logon via a one-time logon script, or FSLogix profile reset for test users first).
6. Validate with a test user: token appears in `16.0\Licensing`; no new device entry appears in the user's *My Account* device list.

**Rollback:** set the value to `'0'`, remove GPO, reboot; users will re-activate per user (consuming device slots).
</details>

<details><summary>Playbook 2 — Full per-user activation reset (scriptable)</summary>

Use the Get Help activation troubleshooter interactively, SaRA Enterprise (`SaRAcmd.exe -S ResetOfficeActivation -AcceptEula -CloseOffice`) at scale where still available, or this manual equivalent run **as the user**:
```powershell
$apps = 'WINWORD','EXCEL','POWERPNT','OUTLOOK','ONENOTE','MSACCESS','MSPUB','VISIO','WINPROJ','lync'
Get-Process $apps -ErrorAction SilentlyContinue | Stop-Process -Force
$bk = Join-Path $env:TEMP ("OfficeActivationBackup_{0:yyyyMMddHHmmss}" -f (Get-Date))
New-Item $bk -ItemType Directory -Force | Out-Null
reg export 'HKCU\Software\Microsoft\Office\16.0\Common\Identity' (Join-Path $bk 'Identity.reg') /y | Out-Null
foreach ($p in "$env:LOCALAPPDATA\Microsoft\Office\Licenses","$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing") {
  if (Test-Path $p) { Copy-Item $p (Join-Path $bk (Split-Path $p -Leaf)) -Recurse -Force; Get-ChildItem $p | Remove-Item -Recurse -Force }
}
Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -Recurse -Force -ErrorAction SilentlyContinue
cmdkey /list | Select-String 'MicrosoftOffice1[56]_Data' | ForEach-Object {
  $target = ($_.Line -replace '^\s*Target:\s*','').Trim(); cmdkey /delete:$target | Out-Null }
Write-Output "Reset complete. Backup at $bk"
```
**Rollback:** `reg import <bk>\Identity.reg`, copy folders back. Non-destructive to documents and the install.
</details>

<details><summary>Playbook 3 — Tenant-to-tenant migration / UPN change</summary>

1. After mailbox/identity cutover, remove the old tenant account from *Access work or school* (unless it owns the device join — then re-join to the new tenant first).
2. Run Playbook 2 for each user.
3. If OneDrive/Teams also cache the old identity, sign them out too — Office will otherwise silently reuse the old token via WAM.
4. Confirm File → Account shows the new UPN and *Subscription Product*.
</details>

<details><summary>Playbook 4 — Switching installed product (Business ↔ Enterprise)</summary>

ODT `configuration.xml`, run elevated with `setup.exe /configure`:
```xml
<Configuration>
  <Add Version="MatchInstalled">
    <Product ID="O365ProPlusRetail"><Language ID="MatchInstalled"/></Product>
  </Add>
  <Remove><Product ID="O365BusinessRetail"/></Remove>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>
  <Display Level="None" AcceptEULA="TRUE"/>
</Configuration>
```
Then Playbook 2 so the new product picks up a matching licence. **Rollback:** inverse XML.
</details>

<details><summary>Playbook 5 — Licensing endpoint blocked by proxy/TLS inspection</summary>

1. Identify path: `netsh winhttp show proxy`; user proxy in *Settings > Network > Proxy*; PAC.
2. Exempt the Microsoft 365 *Optimize/Allow* endpoint categories (at minimum `*.officeapps.live.com`, `login.microsoftonline.com`, `*.office.com`, `*.office.net`) from TLS inspection and authentication.
3. Re-test 443 and retry *Update License*. Check `Microsoft-Windows-AAD/Operational` is clear of `0xCAA*` errors.
</details>

---
## Evidence Pack
Run as the affected user (elevation not required; some HKLM reads work without it).
```powershell
$out = Join-Path $env:TEMP ("M365AppsActivation_{0}_{1:yyyyMMddHHmm}" -f $env:COMPUTERNAME,(Get-Date))
New-Item $out -ItemType Directory -Force | Out-Null
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' | Out-File "$out\c2r-config.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing' -EA SilentlyContinue | Out-File "$out\policy-licensing.txt"
dsregcmd /status > "$out\dsregcmd.txt"
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\Licenses","$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing" -Recurse -File -EA SilentlyContinue |
  Select-Object FullName, Length, LastWriteTime | Export-Csv "$out\licence-files.csv" -NoTypeInformation
Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -EA SilentlyContinue | Get-ItemProperty |
  Select-Object EmailAddress, ProviderId, SignInName | Export-Csv "$out\office-identities.csv" -NoTypeInformation
Get-AppxPackage Microsoft.AAD.BrokerPlugin | Select-Object Name, Version, Status | Out-File "$out\brokerplugin.txt"
netsh winhttp show proxy > "$out\winhttp-proxy.txt"
'ols.officeapps.live.com','login.microsoftonline.com','officeclient.microsoft.com' | ForEach-Object {
  [pscustomobject]@{Host=$_; Tcp443=(Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded} } |
  Export-Csv "$out\endpoints.csv" -NoTypeInformation
Get-WinEvent -LogName 'Microsoft-Windows-AAD/Operational' -MaxEvents 200 -EA SilentlyContinue |
  Where-Object LevelDisplayName -in 'Error','Warning' | Select-Object TimeCreated, Id, Message | Export-Csv "$out\aad-operational.csv" -NoTypeInformation
$vnd = Get-ChildItem "${env:ProgramFiles}\Microsoft Office\Office16\vNextDiag.ps1" -EA SilentlyContinue
if ($vnd) { & $vnd.FullName *> "$out\vnextdiag.txt" }
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Installed product / SCA | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` |
| SCA policy | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing` |
| Enable SCA | `Set-ItemProperty ...\ClickToRun\Configuration -Name SharedComputerLicensing -Value '1' -Type String` + reboot |
| vNext licence files | `Get-ChildItem $env:LOCALAPPDATA\Microsoft\Office\Licenses -Recurse` |
| SCA tokens | `Get-ChildItem $env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing` |
| vNext diag | `& "$env:ProgramFiles\Microsoft Office\Office16\vNextDiag.ps1"` |
| Office identities | `Get-ChildItem HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities` |
| PRT / join state | `dsregcmd /status` |
| Re-register broker | `Add-AppxPackage -Register "$env:windir\SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\Appxmanifest.xml" -DisableDevelopmentMode -ForceApplicationShutdown` |
| User licence plans | `(Get-MgUserLicenseDetail -UserId <UPN>).ServicePlans` |
| Tenant SKUs | `Get-MgSubscribedSku` |
| Office cached creds | `cmdkey /list \| Select-String MicrosoftOffice` |
| Proxy | `netsh winhttp show proxy` |
| Endpoint test | `Test-NetConnection ols.officeapps.live.com -Port 443` |
| Fleet/device audit | `.\Scripts\Get-M365AppsActivationDiagnostics.ps1` |

---
## 🎓 Learning Pointers
- [Overview of licensing and activation in Microsoft 365 Apps](https://learn.microsoft.com/microsoft-365-apps/licensing-activation/overview-licensing-activation-microsoft-365-apps) — the authoritative comparison of user-based, SCA and device-based modes; read it before designing any shared-device estate.
- [Overview of shared computer activation](https://learn.microsoft.com/microsoft-365-apps/licensing-activation/overview-shared-computer-activation) — the three post-install enablement methods, token behaviour, and the "reset earlier activations" caveat that explains most broken RDS conversions.
- [Reset Microsoft 365 Apps activation state](https://learn.microsoft.com/office/troubleshoot/activation/reset-office-365-proplus-activation-state) — Microsoft's list of what to clear and the SaRA Enterprise option for remote/bulk resets.
- [Unlicensed Product and activation errors](https://learn.microsoft.com/office/troubleshoot/activation/unlicensed-product-error) — identity-first fixes (work/school account mismatch, Identity key) that resolve the majority of tickets.
- [Microsoft 365 URLs and IP address ranges](https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges) — the endpoint set to exempt from TLS inspection.
- Related in this repo: `EntraID/Troubleshooting/PRT-Issues-A.md` / `HybridJoin-A.md` (Phase 3), `M365/Licensing/Group-Based-Licensing-A.md` (Phase 1), `Deployment-UpdateChannels-A.md` (install/product IDs).
