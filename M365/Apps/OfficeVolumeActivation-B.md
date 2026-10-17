# Office LTSC / Volume Activation (KMS, MAK, ADBA) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers volume-licensed Office LTSC 2024, Office LTSC 2021, Office 2019 and volume Visio/Project. Subscription Microsoft 365 Apps activation is `Activation-B.md`; Windows OS activation is `Windows/Troubleshooting/VolumeActivation-B.md`.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run elevated on the affected client. Everything below uses CIM (no VBScript), so it still works after the VBScript Feature on Demand is disabled.

```powershell
# 1. What Office is installed? (Volume LTSC ProductReleaseIds end in "Volume", e.g. ProPlus2024Volume)
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue) |
    Select-Object ProductReleaseIds, UpdateChannel, VersionToReport

# 2. Office licences held by Windows SPP (Office 2013+ application ID)
$officeApp = '0ff1ce15-a989-479d-af46-f275c6370663'
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$officeApp' AND PartialProductKey IS NOT NULL" |
    Select-Object Name, Description, LicenseStatus, PartialProductKey,
                  @{n='GraceDays';e={[math]::Round($_.GracePeriodRemaining/1440,1)}},
                  KeyManagementServiceMachine, DiscoveredKeyManagementServiceMachineName

# 3. Can the client find and reach a KMS host?
Resolve-DnsName -Type SRV "_vlmcs._tcp.$((Get-CimInstance Win32_ComputerSystem).Domain)" -ErrorAction SilentlyContinue
Test-NetConnection <kmsHost> -Port 1688 | Select-Object ComputerName, TcpTestSucceeded

# 4. Recent activation errors (SPP logs Office and Windows to the same source)
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Security-SPP'; Id=12288,12289,8198} -MaxEvents 10 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, @{n='Msg';e={$_.Message.Substring(0,[math]::Min(200,$_.Message.Length))}}
```

| Result | Meaning | Go to |
|---|---|---|
| `ProductReleaseIds` contains `O365ProPlusRetail` / `O365BusinessRetail` | Subscription install, not volume | `Activation-B.md` |
| ProductReleaseIds ends in `Retail` (e.g. `ProPlus2024Retail`) but you expect KMS | Wrong product installed — GVLKs/MAKs never activate a Retail product | Fix 5 |
| Step 2 returns nothing | No Office licence/key installed in SPP (or Office 2010 / OSPPSVC era) | Fix 1 |
| `Description` contains `VOLUME_KMSCLIENT`, `LicenseStatus` 2/5, grace counting down | KMS client never reached/activated against a host | Steps 3 → Fix 2/3 |
| `LicenseStatus` 1 (Licensed) | Activated. If the user still sees a banner, it is another product (Visio/Project) or a second licence row | Step 4 of the flow |
| `Description` contains `VOLUME_MAK` and status ≠ 1 | MAK not activated online or MAK count exhausted | Fix 4 |
| SRV lookup empty and no `KeyManagementServiceMachine` set | Auto-discovery has nothing to find | Fix 2 |
| Port 1688 test fails | Firewall/routing to KMS host | Fix 2 (network) |
| Event 12288 present but no 12289 | Client sent a request and got no reply | Fix 2 |
| Event 12289 with `0xC004F038` | Host reachable but **Office** count < 5 | Fix 3 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Client side
└─ Office install is a VOLUME product (ProductReleaseIds *Volume, channel PerpetualVL20xx)
   └─ Matching key installed in Windows SPP (sppsvc)
      ├─ GVLK (KMS client) ──► KMS host found (manual host OR _vlmcs._tcp SRV)
      │                        └─ TCP 1688 reachable
      │                           └─ KMS HOST side:
      │                              ├─ Host OS supported (2024: Server 2019+/Win10+ VL; 2021: Server 2016+; 2019: Server 2012+)
      │                              ├─ Office Volume License Pack for THAT version installed
      │                              ├─ Office KMS host key (CSVLK) for that version installed + activated with Microsoft
      │                              └─ Office client count >= 5 (separate counter from Windows)
      ├─ GVLK (ADBA) ──► domain-joined, Win 8.1+/Server 2012 R2+, AD Activation Object for the Office CSVLK exists
      └─ MAK ──► one-time online (or phone) activation with Microsoft; MAK count not exhausted
         └─ LicenseStatus = 1 (Licensed); KMS clients renew every 7 days, licence valid 180 days
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm it is a volume install.**
   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration').ProductReleaseIds -split ','
   ```
   Expected: `ProPlus2024Volume`, `Standard2024Volume`, `ProPlus2021Volume`, `ProPlus2019Volume`, `VisioPro2024Volume`, `ProjectPro2024Volume`… Anything ending `Retail` cannot use a GVLK/MAK.

2. **List every Office licence row with a key.**
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
       Format-List Name, Description, LicenseStatus, LicenseStatusReason, PartialProductKey, GracePeriodRemaining
   ```
   Expected: one row per installed product, `LicenseStatus : 1`. `LicenseStatus` values: 0 Unlicensed, 1 Licensed, 2 OOB grace, 3 OOT grace, 4 Non-genuine grace, 5 Notification, 6 Extended grace. Multiple rows for the same product (e.g. a Retail trial key plus a GVLK) cause confusing banners — remove the stray one (Fix 1).

3. **Identify which KMS host the client is using.**
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
       Select-Object Name, KeyManagementServiceMachine, KeyManagementServicePort, DiscoveredKeyManagementServiceMachineName, DiscoveredKeyManagementServiceMachinePort
   ```
   Manual `KeyManagementServiceMachine` overrides DNS. A stale manual host (decommissioned server) is a very common cause.

4. **Check the KMS host itself (run on the host).**
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
       Where-Object { $_.Description -like '*VOLUME_KMS channel*' } |
       Select-Object Name, Description, LicenseStatus, KeyManagementServiceCurrentCount
   Get-WinEvent -LogName 'Key Management Service' -MaxEvents 20 | Where-Object Id -eq 12290 | Select-Object -First 5 TimeCreated, Message
   ```
   Expected: an Office host row (e.g. `Office 24, VOLUME_KMS channel`) with `LicenseStatus 1` and `KeyManagementServiceCurrentCount` ≥ 5. No Office row = Volume License Pack or host key missing → escalate to KMS owner (Fix 3).

5. **Translate the error code.** `0xC004F074` no KMS could be contacted · `0x8007232B` DNS name does not exist (no SRV) · `0xC004F038` count too low · `0xC004F042` this KMS host cannot activate this product (VLP/CSVLK missing or older generation) · `0xC004C008` / `0xC004C020` MAK limit reached · `0xC004F050` invalid key for this product.

---
## Common Fix Paths

<details><summary>Fix 1 — Install the correct GVLK (and remove stray keys)</summary>

Published GVLKs (Microsoft Learn: *GVLKs for KMS and Active Directory-based activation of Office*). Verify Visio/Project keys against that page before use.

| Product | GVLK |
|---|---|
| Office LTSC Professional Plus 2024 | `XJ2XN-FW8RK-P4HMP-DKDBV-GCVGB` |
| Office LTSC Professional Plus 2021 | `FXYTK-NJJ8C-GB6DW-3DYQT-6F7TH` |
| Office Professional Plus 2019 | `NMMKJ-6RK4F-KMJVX-8D9MJ-6MWKP` |

```powershell
$officeApp = '0ff1ce15-a989-479d-af46-f275c6370663'
$svc = Get-CimInstance SoftwareLicensingService
# Install the GVLK (SPP routes it to the matching Office product)
Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = '<GVLK>' }
Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus | Out-Null

# Remove a stray key by its last 5 characters (e.g. an old Retail/MAK on the same product)
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$officeApp' AND PartialProductKey='<last5>'" |
    Invoke-CimMethod -MethodName UninstallProductKey
```
OSPP equivalent (needs VBScript FOD): `cscript "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /inpkey:<GVLK>` and `/unpkey:<last5>`.

Rollback: re-install the previous key with `InstallProductKey`. Removing the only key leaves Office unlicensed until a key is reinstalled.
</details>

<details><summary>Fix 2 — Point the client at a reachable KMS host and activate</summary>

```powershell
$officeApp = '0ff1ce15-a989-479d-af46-f275c6370663'
$prods = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$officeApp' AND PartialProductKey IS NOT NULL" |
         Where-Object Description -like '*VOLUME_KMSCLIENT*'

# Option A: per-product manual host (Office only — does not touch Windows activation)
foreach ($p in $prods) {
    Invoke-CimMethod -InputObject $p -MethodName SetKeyManagementServiceMachine -Arguments @{ MachineName = '<kmsHost.fqdn>' } | Out-Null
    Invoke-CimMethod -InputObject $p -MethodName SetKeyManagementServicePort    -Arguments @{ PortNumber = [uint32]1688 } | Out-Null
}
# Option B: clear a stale manual host so DNS auto-discovery is used again
# foreach ($p in $prods) { Invoke-CimMethod -InputObject $p -MethodName ClearKeyManagementServiceMachine | Out-Null }

# Activate now
foreach ($p in $prods) { Invoke-CimMethod -InputObject $p -MethodName Activate }
```
OSPP equivalent: `OSPP.VBS /sethst:<kmsHost> /setprt:1688 /act` (`/remhst` to clear).

If `Test-NetConnection -Port 1688` fails, fix firewall/VPN first — KMS is plain TCP 1688 client→host. If the SRV record is missing, ask DNS owners to restore `_vlmcs._tcp` (the KMS host registers it automatically unless `DisableDnsPublishing` is set).
</details>

<details><summary>Fix 3 — Host count below 5 / host can't activate this Office version (0xC004F038, 0xC004F042)</summary>

Office has its own KMS counter (threshold **5** clients) separate from Windows. A new LTSC 2024 rollout to three pilot PCs will sit in grace until two more request activation.

- Short term: activate more clients (they retry every 2 hours), or use MAK on the pilot devices (Fix 4).
- `0xC004F042`: the host has no Office 2024 licence files. On the KMS host (Server 2019+/Windows 10+ VL for 2024):
  1. Install the **Office LTSC 2024 Volume License Pack** (Microsoft Download Center ID 106246).
  2. Run the pack's setup to enter and activate the Office 2024 KMS host key (CSVLK) from the Volume Licensing portal.
  3. Confirm the host row with step 4 of the flow.
- Better long term: ADBA — the same CSVLK can create an AD activation object (Volume Activation Tools → Active Directory-Based Activation). Domain-joined clients then activate on boot, with no count threshold.

No client-side rollback needed; changes are host-side and additive.
</details>

<details><summary>Fix 4 — MAK activation (no KMS, small sites, off-domain devices)</summary>

```powershell
$svc = Get-CimInstance SoftwareLicensingService
Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = '<MAK>' }
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
    Where-Object Description -like '*VOLUME_MAK*' | Invoke-CimMethod -MethodName Activate
```
`0xC004C008`/`0xC004C020` = MAK count exhausted → request an increase in the Volume Licensing portal, or reclaim keys. Offline device: `OSPP.VBS /dinstid` to get the installation ID, phone-activate, then `OSPP.VBS /actcid:<confirmationId>`.

Rollback: reinstall the GVLK (Fix 1) to return the device to KMS.
</details>

<details><summary>Fix 5 — Retail product installed where volume was intended</summary>

A GVLK or MAK cannot activate `ProPlus2024Retail`. Reinstall the volume product with ODT:

```xml
<Configuration>
  <Remove All="TRUE" />
  <Add OfficeClientEdition="64" Channel="PerpetualVL2024">
    <Product ID="ProPlus2024Volume" PIDKEY="XJ2XN-FW8RK-P4HMP-DKDBV-GCVGB">
      <Language ID="MatchOS" />
    </Product>
  </Add>
  <Property Name="AUTOACTIVATE" Value="1" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
```
```powershell
& "<path>\setup.exe" /configure "<path>\ltsc2024-volume.xml"
```
Destructive: `<Remove All="TRUE"/>` uninstalls every Click-to-Run Office product on the device, including Microsoft 365 Apps. Remove that line if M365 Apps must stay (only supported volume Visio/Project combinations can coexist with M365 Apps).
</details>

---
## Escalation Evidence

```
Ticket: ____________   Device: ____________   User: ____________
Office product (ProductReleaseIds): ____________   Channel: ____________
Licence rows (Name / Description / LicenseStatus / last5):
  ____________________________________________________________
KMS host configured (manual): ________   Discovered: ________
_vlmcs._tcp SRV result: ________   TCP 1688 to host: Pass / Fail
Latest SPP event 12288/12289 + error code: ________
KMS host Office row present (Y/N): __  Host count: __  VLP version: ________
Activation channel: KMS / ADBA / MAK      MAK remaining (if MAK): ____
Fixes attempted: ____________________________________________
Evidence script output attached: Get-OfficeVolumeActivationHealth.ps1 CSV  Y/N
```

---
## 🎓 Learning Pointers
- Office 2013 and later on Windows 8.1+ store their licences in the **Windows** SPP service under application ID `0ff1ce15-…`; that is why `slmgr /dlv all` and CIM show Office rows, and why OSPP.VBS is only a front-end. See [Volume activation of Office](https://learn.microsoft.com/office/volume-license-activation/plan-volume-activation-of-office).
- Office and Windows each have their own KMS count. A healthy Windows count tells you nothing about Office — check the Office host row specifically. [Configure a KMS host for Office](https://learn.microsoft.com/office/volume-license-activation/configure-a-kms-host-computer-for-office).
- Each Office generation needs its own Volume License Pack and host key; Office 2024 also needs a newer host OS (Server 2019+) than 2021 (Server 2016+).
- ADBA removes the count threshold and DNS dependency for domain-joined clients — usually the better design for MSP tenants with mixed Office generations. See `Windows/Troubleshooting/VolumeActivation-A.md` § ADBA.
- `OSPP.VBS` is VBScript; plan for the VBScript FOD being disabled (see `Windows/Troubleshooting/VBScriptDeprecation-B.md`). The CIM calls in this runbook do the same work without it.
- Deep dive: `OfficeVolumeActivation-A.md`. Evidence: `Scripts/Get-OfficeVolumeActivationHealth.ps1`.
