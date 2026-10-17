# Office LTSC / Volume Activation (KMS, MAK, ADBA) — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** volume-licensed, Click-to-Run Office LTSC Professional Plus/Standard 2024 and 2021, Office Professional Plus/Standard 2019, and volume Visio/Project of the same generations; KMS, Active Directory-Based Activation (ADBA) and MAK; the Office side of a KMS host; Windows 8.1+/Server 2012 R2+ clients.
- **Out of scope:** subscription Microsoft 365 Apps (vNext licence files, SCA, device-based) → `Activation-A.md`; Windows OS activation → `Windows/Troubleshooting/VolumeActivation-A.md`; Office 2010 and its separate OSPPSVC service; Office for Mac volume serializer.
- **Assumptions:** admin rights on the client; KMS host owner is reachable for host-side changes; Volume Licensing portal (VLSC / M365 admin center *Billing → Your products → Volume licensing*) access for keys.
- **Dates:** Office LTSC 2024 mainstream support ends 9 Oct 2029 (Microsoft Lifecycle). Office 2019 and 2016 reached end of support 14 Oct 2025 — activation still works, but treat these as migration tickets.

---
## How It Works
<details><summary>Full architecture</summary>

### One licensing engine, two products
Since Office 2013, Office on Windows 8+ does not run its own licensing service. It registers its licences with the **Windows Software Protection Platform** (`sppsvc`) under application ID `0ff1ce15-a989-479d-af46-f275c6370663` (Windows itself is `55c92734-d682-4d71-983e-d6ec3f16059f`). Consequences:

- `Get-CimInstance SoftwareLicensingProduct` and `slmgr /dlv all` list Office rows next to Windows rows.
- `OSPP.VBS` (in `Program Files\Microsoft Office\Office16` for 2016–2024) is just a VBScript front-end that calls the same WMI provider. Every OSPP action has a CIM method equivalent.
- SPP events for Office (12288 request, 12289 response, 8198 activation failure) land in the **Application** log under `Microsoft-Windows-Security-SPP`, interleaved with Windows events — filter by the product name in the message.

### Product identity vs key
A Click-to-Run install carries **product licence files** (e.g. `ProPlus2024VL_KMS_Client_AE`, `ProPlus2024VL_MAK_AE`) laid down by the product ID in the ODT XML. `ProPlus2024Volume` lays down volume licence files; `ProPlus2024Retail` lays down retail ones. A key can only bind to a licence file of its channel, so a GVLK has nothing to attach to on a Retail install — `0xC004F050` / "product key not valid".

Volume LTSC installs service from the `PerpetualVL2024` / `PerpetualVL2021` / `PerpetualVL2019` channels — security updates only, no feature updates.

### KMS
```
 Client (GVLK)                         KMS host (Office CSVLK + VLP)
 ─────────────                         ─────────────────────────────
 1. Find host: manual setting ─┐
    else DNS SRV _vlmcs._tcp ──┴──►  2. RPC over TCP 1688: activation request
                                         (client machine ID, product SKU, timestamp)
                                    3. Host checks: has Office licence files for this
                                       generation? Office count >= 5?
 5. LicenseStatus=1, valid 180 d ◄── 4. Response (count, renewal interval)
 6. Renew every 7 d; retry every 2 h on failure; grace when 180 d lapse
```
- **Thresholds:** Office needs **5** distinct clients counted; Windows clients need 25, Windows Server 5. Counters are independent per application (Office vs Windows) and the host caches up to 50 client IDs. Counted IDs expire after 30 days without renewal.
- **Host prerequisites per generation** (Microsoft Learn): Office LTSC 2024 → Windows Server 2019+ or Windows 10+ volume editions; Office LTSC 2021 → Server 2016+; Office 2019 → Server 2012+. Each generation needs its **own Volume License Pack** (Office LTSC 2024 VLP: Download Center 106246) and **its own** Office KMS host key. A host built for 2021 does not activate 2024 (`0xC004F042`).
- Office and Windows host roles happily coexist on one server; each CSVLK is a separate host licence row.

### ADBA
Run Volume Activation Tools on any machine with RSAT/role, choose *Active Directory-Based Activation*, enter the Office CSVLK (with the matching VLP installed on that machine). This creates an `msSPP-ActivationObject` under `CN=Activation Objects,CN=Microsoft SPP,CN=Services,CN=Configuration,<forest DN>`. Domain-joined clients with a GVLK read it via LDAP at boot/renewal — **no count threshold, no DNS SRV, no port 1688**. Office 2013+ on Windows 8+ supports ADBA. ADBA-activated clients re-check every 7 days and lose activation 180 days after they last saw the domain. KMS remains the fallback for clients that can't use ADBA.

### MAK
Each MAK has a fixed activation count. The client contacts Microsoft's activation service once (online, or by phone using installation ID / confirmation ID). Reimaging consumes another activation unless reclaimed. VAMT can manage MAK and proxy-activate isolated networks.

### Coexistence with Microsoft 365 Apps
Mixing subscription Microsoft 365 Apps with volume LTSC Office suites on one device is unsupported. Specific volume Visio/Project products can coexist with Microsoft 365 Apps if installed via ODT on a compatible channel — check Microsoft's *Supported scenarios for installing different versions of Office, Visio, and Project* before planning it.
</details>

---
## Dependency Stack
```
[7] User sees "Product Activated" in File > Account
[6] LicenseStatus = 1 for every installed Office product row
[5] Activation channel succeeds
      ├─ KMS: host reachable on 1688, host Office count >= 5, host has VLP + CSVLK for this generation
      ├─ ADBA: domain-joined, DC reachable (LDAP), activation object for this generation exists
      └─ MAK: internet/phone path to Microsoft, MAK count available
[4] Host discovery (KMS only): manual KeyManagementServiceMachine OR _vlmcs._tcp SRV in client's DNS suffix
[3] Correct key installed in SPP (GVLK for KMS/ADBA, MAK otherwise); no conflicting stray keys
[2] Volume product licence files present (ProductReleaseIds = *Volume)
[1] sppsvc service healthy; system clock within tolerance; Windows activation store not corrupt
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| "Unlicensed Product", Office row `LicenseStatus 2/5` on fresh image | Count < 5 or no host found | Event 12289 code; SRV lookup |
| `0xC004F074` | No KMS host responded (DNS, firewall, host down) | `Resolve-DnsName -Type SRV`, `Test-NetConnection -Port 1688` |
| `0x8007232B` | SRV record missing in client's primary DNS suffix | `Resolve-DnsName _vlmcs._tcp.<domain> -Type SRV` |
| `0xC004F038` | Office count below 5 | Host `KeyManagementServiceCurrentCount` on Office row |
| `0xC004F042` | Host lacks VLP/CSVLK for this generation (e.g. 2021 host, 2024 client) | Host Office rows' `Name` |
| `0xC004F050` / key rejected | Retail product installed, or wrong-generation GVLK | `ProductReleaseIds` |
| `0xC004C008` / `0xC004C020` | MAK count exhausted | Volume Licensing portal |
| Worked for months, now grace on many devices | KMS host decommissioned/renamed; manual host still set on clients | `KeyManagementServiceMachine` |
| Only Visio/Project unlicensed | Separate product needs its own GVLK/MAK and host support | Licence rows per product |
| Banner persists but suite row is Licensed | Second stale row (e.g. old Retail/trial key) | `PartialProductKey IS NOT NULL` rows |
| Activation fine, `OSPP.VBS` errors "script host disabled" | VBScript FOD removed/disabled | Use CIM methods instead |
| ADBA domain but clients still query KMS | Activation object missing for this generation, or client off-domain | AD `CN=Activation Objects` |

---
## Validation Steps
1. **Install type** — `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration').ProductReleaseIds`
   Good: `ProPlus2024Volume`. Bad: `*Retail`, `O365*`.
2. **Licence rows** — `Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" | Select Name, Description, LicenseStatus`
   Good: one row per product, `VOLUME_KMSCLIENT` or `VOLUME_MAK`, status 1. Bad: no rows, status ≠ 1, duplicate rows.
3. **Renewal health (KMS)** — `Select-Object VLActivationInterval, VLRenewalInterval, GracePeriodRemaining`
   Good: renewal 10080 min, grace ~259200 min (180 d) just after renewal. Bad: grace steadily decreasing with no renewal.
4. **Discovery** — `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>`
   Good: one or more hosts, port 1688. Bad: NXDOMAIN, or entries for retired servers.
5. **Host** (on host) — Office row with `Description` `*VOLUME_KMS channel*`, `LicenseStatus 1`, `KeyManagementServiceCurrentCount` ≥ 5.
6. **ADBA** — `Get-ADObject -SearchBase "CN=Activation Objects,CN=Microsoft SPP,CN=Services,$((Get-ADRootDSE).configurationNamingContext)" -Filter * -Properties displayName | Select displayName`
   Good: an object whose name references the Office generation's KMS key. Bad: only Windows objects.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Is this the right runbook?** Confirm Volume product (Validation 1). Subscription → `Activation-A.md`.

**Phase 2 — Client key state.** Validation 2. No key → install GVLK. Wrong key/channel → fix key or reinstall product (Playbook C). Duplicate rows → uninstall the stray key.

**Phase 3 — Discovery.** Manual host set? Is it current? Else SRV present in the suffix the client actually uses (`Get-DnsClientGlobalSetting` suffix search list)? Multi-forest/workgroup clients often need a manual host.

**Phase 4 — Transport.** `Test-NetConnection <host> -Port 1688`. VPN split-tunnel and branch firewalls are typical blockers. Events 12288 with no 12289 point here.

**Phase 5 — Host capability.** Error code from 12289: `0xC004F038` (count) vs `0xC004F042` (generation). Inspect host rows and Key Management Service log (12290 per request).

**Phase 6 — Alternative channel.** If KMS can't be fixed quickly: ADBA (domain) or MAK (isolated/small).

---
## Remediation Playbooks

<details><summary>Playbook A — Bring a KMS host up to Office LTSC 2024</summary>

1. Confirm host OS: Server 2019+ (or Windows 10+ volume edition).
2. Download and install the **Office LTSC 2024 Volume License Pack** (Download Center 106246). The installer launches Volume Activation Tools.
3. Choose *Key Management Service (KMS)*, enter the Office LTSC 2024 KMS host key from the Volume Licensing portal, activate online (or phone).
4. Verify:
   ```powershell
   Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL" |
       Where-Object { $_.Description -like '*VOLUME_KMS channel*' } |
       Select-Object Name, LicenseStatus, KeyManagementServiceCurrentCount
   ```
5. Ensure inbound TCP 1688 is allowed (`Get-NetFirewallRule -DisplayGroup 'Key Management Service' | Select DisplayName, Enabled`).
Rollback: uninstalling the host key (`UninstallProductKey` on that row) stops Office 2024 activation from this host; clients keep working until their 180-day validity lapses.
</details>

<details><summary>Playbook B — Move a domain to ADBA for Office</summary>

1. On a domain-joined server with the VLP installed and Enterprise Admin rights: Server Manager → Tools → Volume Activation Tools → *Active Directory-Based Activation*.
2. Enter the Office CSVLK, activate online, name the object (e.g. `Office LTSC 2024 ADBA`).
3. On a client: `Invoke-CimMethod` `Activate` on the Office row (or reboot). Confirm `LicenseStatus 1`.
4. Keep KMS for non-domain/legacy clients or decommission once counts drop.
Rollback: delete the activation object in ADSI Edit (`CN=Activation Objects`). Clients continue for up to 180 days, then fall back to KMS discovery.
</details>

<details><summary>Playbook C — Convert Retail installs to Volume at scale</summary>

Use ODT with `<Remove All="TRUE"/>` (destructive — removes all C2R Office) and a `Product ID="ProPlus2024Volume"` with `PIDKEY` = GVLK and `Channel="PerpetualVL2024"`. Deploy as an Intune Win32 app or SCCM package; detection rule: `ProductReleaseIds` contains `ProPlus2024Volume`. Pilot first; user settings (registry `HKCU\Software\Microsoft\Office\16.0`) survive because the major version stays 16.0.
Rollback: redeploy the previous ODT XML.
</details>

<details><summary>Playbook D — Clean out stale manual KMS hosts fleet-wide</summary>

Intune Remediation / RMM script:
```powershell
$officeApp = '0ff1ce15-a989-479d-af46-f275c6370663'
$stale = @('<oldKms1.fqdn>','<oldKms2.fqdn>')
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$officeApp' AND PartialProductKey IS NOT NULL" |
    Where-Object { $stale -contains $_.KeyManagementServiceMachine } |
    ForEach-Object {
        Invoke-CimMethod -InputObject $_ -MethodName ClearKeyManagementServiceMachine | Out-Null
        Invoke-CimMethod -InputObject $_ -MethodName Activate | Out-Null
    }
```
Rollback: `SetKeyManagementServiceMachine` with the previous name.
</details>

<details><summary>Playbook E — MAK proxy activation for isolated networks (VAMT)</summary>

1. Install VAMT (Windows ADK) on a connected machine. 2. Discover the isolated machines, export the CIL. 3. Move CIL to the connected VAMT, acquire confirmation IDs. 4. Import back and apply. Office products appear in VAMT alongside Windows.
</details>

---
## Evidence Pack
Use `Scripts/Get-OfficeVolumeActivationHealth.ps1` (client and host mode, CSV output). Minimal inline version:

```powershell
$out = "$env:TEMP\OfficeVLEvidence_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
$officeApp = '0ff1ce15-a989-479d-af46-f275c6370663'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue |
    Select-Object ProductReleaseIds, UpdateChannel, VersionToReport, Platform | Export-Csv "$out\c2r.csv" -NoTypeInformation
Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$officeApp' AND PartialProductKey IS NOT NULL" |
    Select-Object Name, Description, LicenseStatus, LicenseStatusReason, PartialProductKey, GracePeriodRemaining,
                  KeyManagementServiceMachine, KeyManagementServicePort, DiscoveredKeyManagementServiceMachineName,
                  VLActivationInterval, VLRenewalInterval | Export-Csv "$out\licences.csv" -NoTypeInformation
$domain = (Get-CimInstance Win32_ComputerSystem).Domain
Resolve-DnsName -Type SRV "_vlmcs._tcp.$domain" -ErrorAction SilentlyContinue | Export-Csv "$out\srv.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Microsoft-Windows-Security-SPP'; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in 8198,12288,12289 } | Select-Object TimeCreated, Id, Message | Export-Csv "$out\spp-events.csv" -NoTypeInformation
Compress-Archive "$out\*" "$out.zip" -Force
"Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| Office licence rows | `Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='0ff1ce15-a989-479d-af46-f275c6370663' AND PartialProductKey IS NOT NULL"` |
| Install key | `Invoke-CimMethod -InputObject (Get-CimInstance SoftwareLicensingService) -MethodName InstallProductKey -Arguments @{ProductKey='<key>'}` |
| Activate a row | `$row \| Invoke-CimMethod -MethodName Activate` |
| Set Office-only KMS host | `$row \| Invoke-CimMethod -MethodName SetKeyManagementServiceMachine -Arguments @{MachineName='<host>'}` |
| Clear manual host | `$row \| Invoke-CimMethod -MethodName ClearKeyManagementServiceMachine` |
| Uninstall key | `$row \| Invoke-CimMethod -MethodName UninstallProductKey` |
| SRV lookup | `Resolve-DnsName -Type SRV _vlmcs._tcp.<domain>` |
| Port test | `Test-NetConnection <host> -Port 1688` |
| OSPP status (VBScript) | `cscript "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS" /dstatus` |
| OSPP KMS history | `... OSPP.VBS /dhistorykms` |
| OSPP error text | `... OSPP.VBS /ddescr:0xC004F074` |
| OSPP phone activation | `... OSPP.VBS /dinstid` then `/actcid:<id>` |
| Host count | host row `KeyManagementServiceCurrentCount` |
| Host request log | `Get-WinEvent -LogName 'Key Management Service' -MaxEvents 50` |
| ADBA objects | `Get-ADObject -SearchBase "CN=Activation Objects,CN=Microsoft SPP,CN=Services,<configNC>" -Filter *` |

---
## 🎓 Learning Pointers
- [Plan volume activation of Office](https://learn.microsoft.com/office/volume-license-activation/plan-volume-activation-of-office) — the KMS/ADBA/MAK decision, and why Office has its own count.
- [Configure a KMS host computer for Office](https://learn.microsoft.com/office/volume-license-activation/configure-a-kms-host-computer-for-office) — per-generation host OS minimums and the one-VLP-per-version rule behind `0xC004F042`.
- [GVLKs for KMS and Active Directory-based activation of Office](https://learn.microsoft.com/office/volume-license-activation/gvlks) — authoritative key list, including Visio/Project.
- [Tools to manage volume activation of Office](https://learn.microsoft.com/office/volume-license-activation/tools-to-manage-volume-activation-of-office) — the full OSPP.VBS option list; map each to its CIM method before VBScript is disabled.
- [Office LTSC 2024 lifecycle](https://learn.microsoft.com/lifecycle/products/office-ltsc-2024) — support dates to quote when customers ask about staying perpetual.
- Related: `Windows/Troubleshooting/VolumeActivation-A.md` (same SPP/KMS plumbing for Windows), `Activation-A.md` (subscription Office), `Windows/Troubleshooting/VBScriptDeprecation-A.md`.
