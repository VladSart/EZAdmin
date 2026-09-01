# Windows 10 Extended Security Updates (ESU) — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- The **commercial/organizational Windows 10 ESU program** for physical, domain-joined or Entra-joined Windows 10 devices — Multiple Activation Key (MAK)-based licensing purchased through Volume Licensing, activated via `slmgr.vbs`
- The **free ESU entitlement** for physical Windows 10 endpoints used to access a Windows 365 Cloud PC or Azure Virtual Desktop session host — a separate, licensing-driven (not MAK) mechanism
- Prerequisite update/build state, activation troubleshooting, and how ESU-covered updates then flow through Windows Update, Windows Update for Business (WUfB), Intune, WSUS, or Configuration Manager
- Windows 10, version 22H2 only — no other Windows 10 version is ESU-eligible

**Out of scope:**
- **Consumer ESU** (individuals/Windows 10 Home, enrolled via the in-OS "Enroll now" wizard using a Microsoft Account, free via Windows Backup sync or 1,000 Microsoft Rewards points, or a one-time $30 purchase) — a genuinely different program with its own enrollment wizard and support path. See [Windows 10 Consumer Extended Security Updates (ESU) program](https://www.microsoft.com/windows/extended-security-updates). A commercial/domain-joined device will generally **not** show the consumer wizard at all — see Fix/Symptom entries below for the confusion this causes on tickets.
- **Windows 10 ESU for Windows 10 VMs already running in Azure/W365/AVD/Azure Local/Azure VMware Solution/Nutanix Cloud Clusters on Azure** as the *host* — those are entitled to ESU at no additional cost by virtue of running in that service; this runbook's "free ESU" section instead covers the **physical endpoint device** that connects *to* a Cloud PC/AVD session, a commonly confused adjacent scenario. For the VM-host-side entitlement itself, see [Understanding ESU for Windows 365](https://learn.microsoft.com/en-us/windows-365/enterprise/understanding-extended-security-updates) / [Understanding ESU for Azure Virtual Desktop](https://learn.microsoft.com/en-us/azure/virtual-desktop/understanding-extended-security-updates).
- **Windows Server ESU** — a separate program with its own SKUs, activation IDs, and (for Server) an Azure Arc-based free-with-Arc path; not covered here.
- **Windows 10 LTSB/LTSC** — has its own independent servicing lifecycle and is explicitly **not** covered by the Windows 10 ESU program at all.
- Feature-update / in-place-upgrade mechanics to move devices off Windows 10 entirely (Autopatch, Feature Updates policy) — see `Intune/Troubleshooting/Autopatch-A.md` and `Intune/Troubleshooting/FeatureUpdates-A.md` for the "get off Windows 10" path, which is Microsoft's stated preferred outcome; ESU is explicitly a bridge, not a destination.

**Assumptions:**
- Windows 10 reached end of support on **October 14, 2025**. From that date, Microsoft no longer provides technical support, feature updates, or quality/security updates for non-ESU Windows 10 devices.
- You have (or are helping a client obtain) a Volume Licensing agreement that includes ESU, and Microsoft Entra ID accounts with the **Product Key Reader** or **VL Administrator** role to retrieve keys from the Microsoft 365 admin center.
- Devices needing ESU are already on Windows 10, version 22H2 — this runbook does not cover getting a device onto 22H2 from an earlier feature update (that's ordinary Feature Update servicing, see `Intune/Troubleshooting/FeatureUpdates-A.md`).

---
## How It Works

<details><summary>Full architecture — program structure, pricing, and the two enrollment paths</summary>

### What ESU actually is

The Windows 10 ESU program is **not** a feature-update or support extension — it is a paid subscription that unlocks delivery of **Critical and Important-severity security updates only** for up to three additional years past end of support, delivered through the device's existing update channel. Per Microsoft's own FAQ, ESU explicitly does **not** include: new features, customer-requested non-security fixes, design change requests, or general technical support (only support for the ESU license/activation/installation itself, and only for organizations with an active Microsoft Unified support plan).

### The three-year, cumulative, per-device pricing model

For commercial/organizational customers purchasing through Volume Licensing:
- **Year One: $61 USD per device.**
- The price **doubles every consecutive year** — Year Two and Year Three cost more, for a maximum coverage window of three years.
- **ESU is cumulative, not à la carte.** You cannot buy only Year Two or Year Three in isolation — if you enroll late, you must pay for Year One retroactively as well as the year you're actually enrolling into.
- **Minimum purchase is one license** — there's no fleet-size floor, which matters for small/MSP-managed clients with only a handful of legacy devices.
- **Year One began in November 2025** — this anchors the Year 1/2/3 Activation ID mapping used during activation (below); it is not tied to an individual device's own enrollment date.

### Free-of-charge ESU paths (no MAK purchase required)

ESU is included at **no additional cost** for Windows 10 running as a VM/session host in: Windows 365, Azure Virtual Desktop, Azure Virtual Machines, Azure Dedicated Host, Azure VMware Solution (including Citrix and Omnissa Horizon on AVS), Nutanix Cloud Clusters on Azure, Azure Local (formerly Azure Stack HCI), and Azure Stack Hub/Edge.

Separately — and this is the scenario most likely to generate a confused ticket — a **physical Windows 10 endpoint device** used to connect to a Windows 365 Cloud PC is entitled to free ESU coverage for up to three years, provided it has an active Windows 365 subscription license. This entitlement is **not automatic**: the device must have the `EnableESUSubscriptionCheck` flag set (REG_DWORD = 1) so it can verify Windows 365 entitlement and receive updates without a MAK. This is deployed via an Intune custom policy (OMA-URI) or direct registry configuration — see Playbook 4 below. This is architecturally distinct from the commercial MAK path entirely; a device using this free entitlement never runs `slmgr.vbs /ipk` at all.

### The commercial MAK activation model

For everything else (standard commercial/educational physical endpoints not covered by one of the free paths above), ESU is licensed and activated like classic Volume Licensing MAK software:

```
1. Organization purchases ESU under a Volume Licensing agreement (any qty, min 1)
2. Admin retrieves the Multiple Activation Key (MAK) from the Microsoft 365 admin center
   Billing > Your Products > Volume licensing tab > Contracts > View contracts >
     [License ID] > ... (More actions) > View product keys
3. MAK is installed on each target device: slmgr.vbs /ipk <ESU MAK>
4. Device is activated against Microsoft's activation servers using a specific
   Activation ID that identifies WHICH ESU year is being activated:
     Win10 ESU Year1: f520e45e-7413-4a34-a497-d2765967d094
     Win10 ESU Year2: 1043add5-23b1-4afb-9a0f-64343c8f3f8d
     Win10 ESU Year3: 83d49986-add3-41d7-ba33-87c7bfb5c0fb
   slmgr.vbs /ato <Activation ID>
5. slmgr.vbs /dlv confirms License Status = Licensed for that ESU program name
6. Device now receives ESU-covered security updates through its NORMAL update
   channel — Windows Update, WUfB, Intune, WSUS, or Configuration Manager.
   There is no separate "ESU update ring" or special classification to configure.
```

Important nuance: **the MAK you install does not itself encode which year you're activating** — the Activation ID does. A device that already activated Year 1 and is now being rolled into Year 2 coverage re-runs the `/ato` step against the Year 2 Activation ID (a fresh MAK for that year's purchase is typically issued — confirm against your Volume Licensing contract's actual product key list, since MAK issuance details can vary by how the renewal was purchased).

### Why this matters for an MSP: eligibility tracking is now entirely your responsibility

Prior to Windows 10's end of support, Microsoft's own admin tooling could enumerate which users/devices were ESU-entitled. **After October 15, 2025, that centralized user-to-device ESU mapping and reporting is no longer available through Microsoft's own admin tooling.** There is no single console view showing "these N devices in this tenant are ESU-licensed and receiving updates." Organizations (and MSPs managing them) must maintain their own records of which devices are ESU-enrolled, automate eligibility checks, and track policy assignment and patch delivery themselves — this is precisely the gap `Get-ESUActivationStatus.ps1` (below) is built to close at the device level, one endpoint at a time, since no tenant-wide native report exists.

</details>

---
## Dependency Stack

```
Windows 10, version 22H2 (mandatory — no other Windows 10 version is ESU-eligible)
        │
        ▼
Prerequisite updates installed, IN ORDER
  1. KB5066791 (or a later cumulative update)
  2. KB5072653 — ESU Licensing Preparation Package
     (must be installed AFTER KB5066791, not before or simultaneously)
        │
        ▼
Outbound network reachability to Microsoft activation/licensing endpoints
  go.microsoft.com · login.live.com · crl.microsoft.com
  activation.sls.microsoft.com · validation.sls.microsoft.com
  activation-v2.sls.microsoft.com · validation-v2.sls.microsoft.com
  displaycatalog.mp.microsoft.com · licensing.mp.microsoft.com · purchase.mp.microsoft.com
  displaycatalog.md.mp.microsoft.com · licensing.md.mp.microsoft.com · purchase.md.mp.microsoft.com
        │
        ▼
Volume Licensing entitlement + admin role
  ESU purchased under a Volume Licensing agreement (min 1 device, cumulative by year)
  Entra ID account holds Product Key Reader or VL Administrator role
  (required to read the MAK from the M365 admin center Volume Licensing contracts view)
        │
        ▼
MAK installed on the device        →  slmgr.vbs /ipk <ESU MAK>
        │
        ▼
Device activated against the correct year's Activation ID  → slmgr.vbs /ato <Activation ID>
        │
        ▼
slmgr.vbs /dlv confirms License Status = Licensed for the matching ESU program name
        │
        ▼
Device is now eligible — ESU-covered security updates flow through the device's
EXISTING update channel (Windows Update / WUfB / Intune / WSUS / ConfigMgr) with
no separate ring, classification, or product category to configure
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `slmgr.vbs /ipk` fails, invalid key error (0xC004F050) | Wrong/mistyped MAK, or a MAK issued for the wrong ESU year | Re-copy MAK exactly from M365 admin center; confirm which year's contract it belongs to |
| `slmgr.vbs /ato` fails, cannot contact activation server (0xC004F074) | Outbound firewall/proxy blocking one or more of the required activation endpoints | Test each endpoint in the Dependency Stack; check proxy/SSL-inspection exceptions |
| `slmgr.vbs /ato` fails, MAK activation limit exceeded (0xC004C020) | Tenant's MAK activation count has been used up (common after mass reimaging without accounting for re-activations) | `slmgr.vbs /dlv` to see remaining count; request an increase via VL portal (Playbook 3) |
| MAK installs cleanly but `/dlv` never shows the ESU program as Licensed | `/ato` step was skipped, run against the wrong Activation ID, or run before the device could reach the network | Re-run `/ato` with the correct Year 1/2/3 Activation ID; confirm network reachability first |
| ESU key won't install at all, or installs but device shows no eligible ESU offer | Device is not on Windows 10, version 22H2 | `Get-ComputerInfo` / `winver` — must be 22H2 exactly, no other Windows 10 version qualifies |
| `KB5072653` install silently fails or has no effect | Installed before `KB5066791` instead of after — order is a hard requirement per Microsoft's documented sequence | Confirm install order via `Get-HotFix`/`wmic qfe list` timestamps; reinstall in correct order if needed |
| End user reports no "Enroll now" prompt in Settings | Expected on commercial/domain-joined or Entra-joined devices — the consumer in-OS wizard is a **different program** that generally doesn't surface on managed commercial devices at all | Confirm device is domain/Entra-joined and managed; use the MAK path, not the consumer wizard, for commercial devices |
| Reimaged/replaced device loses ESU activation | MAK activations are consumed per activation event, not per physical device permanently — a reimage is a new activation | Re-run `/ipk` + `/ato` post-reimage; request a MAK activation-limit increase if the tenant is running close to its cap |
| Air-gapped/no-internet device can't activate | Device cannot reach Microsoft's activation servers at all | Use phone/Confirmation ID activation (single device) or VAMT Proxy Activation (bulk) — Playbooks 1 & 2 |
| Windows 365-connected physical endpoint expected free ESU but isn't getting updates | `EnableESUSubscriptionCheck` registry flag not deployed, or device doesn't have an active Windows 365 subscription entitlement backing it | Check registry flag via Intune custom policy assignment status; confirm the W365 license assignment (Playbook 4) |
| Ticket describes "ESU enrollment failed — Something went wrong" with a Microsoft Account sign-in step | This is the **consumer** enrollment wizard's error, not the commercial MAK path — wrong runbook/program entirely for a managed device | Confirm whether the device is genuinely unmanaged/consumer before treating this as a commercial ESU ticket |
| Devices activated for ESU still don't receive any updates after 30 days | Underlying WUfB/Intune/WSUS update deployment is broken independent of ESU licensing — ESU only unlocks *eligibility*, it doesn't fix a broken update pipeline | Validate the normal update delivery path per `Intune/Troubleshooting/FeatureUpdates-A.md` / `Windows/Troubleshooting/Windows Update/` runbooks; ESU licensing is not the cause of a stalled patching pipeline |

---
## Validation Steps

**Step 1 — Confirm the device is Windows 10, version 22H2**
```powershell
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber
```
Expected: `WindowsVersion` = `22H2`. Bad: any other version — the device is not ESU-eligible until upgraded to 22H2.

**Step 2 — Confirm prerequisite updates are installed, in the correct order**
```powershell
Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue |
    Select-Object HotFixID, InstalledOn | Sort-Object InstalledOn
```
Expected: both present, with `KB5066791`'s `InstalledOn` date earlier than or equal to `KB5072653`'s. Bad: `KB5072653` missing, or installed before `KB5066791` — reinstall in order.

**Step 3 — Confirm the account retrieving the MAK has the right role**
In the [Microsoft 365 admin center](https://admin.microsoft.com): **Billing → Your Products → Volume licensing tab → Contracts → View contracts** → locate the ESU License ID → **More actions → View product keys**. If this is inaccessible, the signed-in Entra ID account is missing the **Product Key Reader** or **VL Administrator** role — see [Understand volume licensing roles](https://learn.microsoft.com/en-us/microsoft-365/commerce/licenses/manage-user-roles-vl#understand-volume-licensing-roles).

**Step 4 — Test reachability to activation endpoints**
```powershell
$esuEndpoints = @(
    "go.microsoft.com","login.live.com","crl.microsoft.com",
    "activation.sls.microsoft.com","validation.sls.microsoft.com",
    "activation-v2.sls.microsoft.com","validation-v2.sls.microsoft.com",
    "displaycatalog.mp.microsoft.com","licensing.mp.microsoft.com","purchase.mp.microsoft.com",
    "displaycatalog.md.mp.microsoft.com","licensing.md.mp.microsoft.com","purchase.md.mp.microsoft.com"
)
$esuEndpoints | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $_; Reachable = $r.TcpTestSucceeded }
}
```
Expected: `Reachable = True` for every endpoint. Bad: any `False` — a firewall/proxy/SSL-inspection rule is blocking activation; allowlist that endpoint.

**Step 5 — Install the MAK**
```cmd
cscript //nologo C:\Windows\System32\slmgr.vbs /ipk <ESU MAK>
```
Expected: dialog/output confirms "the product key installed successfully." Bad: `0xC004F050` (invalid key — re-copy exactly from the admin center) or `0xC004F015` (uninstall a conflicting key first).

**Step 6 — Activate against the correct year's Activation ID**
```cmd
cscript //nologo C:\Windows\System32\slmgr.vbs /ato f520e45e-7413-4a34-a497-d2765967d094
```
(Use `1043add5-23b1-4afb-9a0f-64343c8f3f8d` for Year 2, `83d49986-add3-41d7-ba33-87c7bfb5c0fb` for Year 3.)
Expected: "product activated successfully." Bad: `0xC004F074` (can't reach activation server — recheck Step 4) or `0xC004C020` (MAK activation limit exceeded — Playbook 3).

**Step 7 — Confirm licensed status**
```cmd
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv
```
Expected: an entry with a **Name** matching the ESU program (e.g., "Windows 10 Enterprise ESU Year 1") and **License Status: Licensed**. Bad: License Status other than `Licensed` (e.g., `Notification`, `Unlicensed`) — activation did not complete; repeat Step 6.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Eligibility and Build Verification
1. Confirm the device is genuinely Windows 10, version 22H2 (Validation Step 1) — this is the single hardest prerequisite to retrofit; a device on an earlier feature update needs a full feature-update cycle first, not a quick fix.
2. Rule out Windows 10 LTSB/LTSC — those SKUs are not covered by this ESU program at all regardless of build number.
3. Determine which enrollment path actually applies: commercial MAK (most managed endpoints), free Windows 365-connected-endpoint path, or free cloud/VM-host path — misidentifying the path is the most common reason a ticket goes nowhere.

### Phase 2 — Prerequisite Update State
1. Verify `KB5066791` (or later CU) and `KB5072653` are both present and in the correct install order (Validation Step 2).
2. If missing, deploy via the device's normal update channel (WUfB/Intune/WSUS) before attempting any activation step — activation will not succeed without them.
3. If `KB5072653` shows installed but activation still behaves as if the prep package never ran, uninstall and reinstall it after confirming `KB5066791` is genuinely present first (order-sensitivity has caused silent no-ops in the field).

### Phase 3 — MAK Retrieval and Role Access
1. Confirm the engineer/admin has Product Key Reader or VL Administrator in Entra ID (Validation Step 3).
2. Retrieve the MAK from the correct License ID/contract — a tenant with multiple VL contracts can have more than one ESU-related License ID; installing the wrong one wastes an activation attempt against the wrong contract's activation count.
3. Note the ESU program **year** the MAK maps to before proceeding — this determines which Activation ID you use in Phase 5.

### Phase 4 — Network Path Verification
1. Run the endpoint reachability sweep (Validation Step 4) before touching `slmgr` at all — most escalations that "look like" a licensing bug are actually a blocked endpoint.
2. Pay particular attention to SSL-inspecting proxies/firewalls — several of these endpoints (the `.sls.microsoft.com` and `.mp.microsoft.com` family) are activation-specific and not always covered by a generic "allow Microsoft 365" firewall rule built for other purposes.
3. If the device has zero internet path by design (isolated/air-gapped), do not keep retrying `/ato` — move directly to Playbook 1 (phone activation) or Playbook 2 (VAMT proxy activation for bulk).

### Phase 5 — Install, Activate, Verify
1. Install the MAK (Validation Step 5).
2. Activate against the correct year's Activation ID (Validation Step 6) — using the wrong year's ID against a Year-1-only MAK will fail; confirm the MAK's own contract year first.
3. Confirm License Status = Licensed (Validation Step 7).
4. Do **not** configure any special update ring, classification, or WSUS product category for "ESU updates" — per Microsoft's own FAQ, ESU-covered updates flow through the device's existing Windows Update/WUfB/Intune/WSUS/ConfigMgr channel automatically once licensed. If updates still aren't arriving after licensing succeeds, the problem is the underlying update pipeline, not ESU (see `Windows/Troubleshooting/Windows Update/` and `Intune/Troubleshooting/FeatureUpdates-A.md`).

### Phase 6 — Fleet-Level Tracking (MSP-specific)
1. Because Microsoft no longer provides centralized ESU enrollment reporting after October 15, 2025, build and maintain your own device-level inventory — run `Get-ESUActivationStatus.ps1` (below) across the fleet on a recurring schedule (Intune Remediation, scheduled task, or RMM script) and centralize the CSV output.
2. Track MAK activation count consumption against the Volume Licensing contract's total, especially for clients doing frequent reimaging — request an activation-limit increase proactively rather than reactively (Playbook 3).
3. Track each device's *year* of coverage explicitly — a device licensed only for Year 1 does not automatically roll into Year 2; re-purchase and re-activation are required annually.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Phone/Confirmation ID activation for a single isolated device</summary>

**Scenario:** A device has no path to the internet (or cannot reach Microsoft's activation servers specifically) and needs ESU activated as a one-off.

```cmd
:: Step 1 — Install the MAK (same as connected devices)
cscript //nologo C:\Windows\System32\slmgr.vbs /ipk <ESU MAK>

:: Step 2 — Confirm the key installed
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv

:: Step 3 — Get the Installation ID (IID) for the correct year's Activation ID
cscript //nologo C:\Windows\System32\slmgr.vbs /dti f520e45e-7413-4a34-a497-d2765967d094

:: Step 4 — On a DIFFERENT computer with internet access, go to the Microsoft
:: Product Activation portal (https://aka.ms/aoh), enter the Installation ID,
:: and follow the prompts to obtain a Confirmation ID (CID).

:: Step 5 — Back on the isolated device, activate using the Confirmation ID
:: (no spaces in the CID)
cscript //nologo C:\Windows\System32\slmgr.vbs /atp <Confirmation ID> f520e45e-7413-4a34-a497-d2765967d094

:: Step 6 — Verify
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv
```

**Rollback:** Not applicable — activation is additive and doesn't alter existing OS licensing. If the CID was mistyped, simply re-run Step 5 with the correct value.
</details>

<details><summary>Playbook 2 — Bulk offline activation via VAMT Proxy Activation</summary>

**Scenario:** A large batch of air-gapped or restricted-network devices all need ESU activated without individually walking Playbook 1 on each one.

```
1. Install/update the Volume Activation Management Tool (VAMT) from the latest
   Windows Assessment and Deployment Kit (ADK):
   https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install

2. Apply the VAMT update containing refreshed PkeyConfig files for Windows 10
   ESU MAK keys — required before VAMT will correctly recognize ESU product keys:
   https://www.microsoft.com/download/details.aspx?id=106364

3. In VAMT, use the Proxy Activation workflow: a VAMT host WITH internet access
   collects installation IDs from the offline target devices (via a network
   share, removable media, or the VAMT client-side collection tool), submits
   them to Microsoft's activation service on the targets' behalf, then returns
   the resulting confirmation data to apply activation on each target.

4. Full mechanics: https://learn.microsoft.com/en-us/windows/deployment/volume-activation/proxy-activation-vamt
```

**Rollback:** Not applicable — VAMT proxy activation only applies licensing state; it makes no other device changes.
</details>

<details><summary>Playbook 3 — Requesting a MAK activation-limit increase</summary>

**Scenario:** `slmgr.vbs /ato` returns `0xC004C020` (activation limit exceeded) — common after mass reimaging, hardware refreshes, or simply underestimating how many activation events a MAK will need across its device lifecycle (each reimage typically consumes another activation).

```
1. Confirm current usage: cscript //nologo slmgr.vbs /dlv
   (shows remaining activation count for the installed key, where reported)

2. In the Microsoft 365 admin center, follow the documented process to request
   additional MAK activations against the existing ESU License ID:
   https://learn.microsoft.com/en-us/microsoft-365/commerce/licenses/product-keys-for-vl#request-an-increase-to-mak-activation-limits

3. While the request is processing, prioritize activation on devices closest to
   losing update coverage rather than activating in arbitrary order — an
   exhausted MAK blocks ALL further activations on that key until the increase
   is granted.
```

**Rollback:** Not applicable — this is a licensing-limit increase request, not a configuration change with a revert path.
</details>

<details><summary>Playbook 4 — Enabling free ESU for Windows 365-connected physical endpoints (Intune)</summary>

**Scenario:** A physical Windows 10 device is used to connect to a Windows 365 Cloud PC and should be eligible for free ESU coverage, but isn't receiving ESU updates because the subscription-check flag was never deployed.

```
1. Confirm the user/device has an active Windows 365 license assignment —
   this entitlement only applies with a genuine, active Windows 365 subscription
   backing the physical endpoint.

2. In the Intune admin center, create a Custom (OMA-URI) device configuration
   profile targeting the affected physical Windows 10 endpoints:
     OMA-URI: a custom-policy path targeting the registry value under
       HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU
       Value name : EnableESUSubscriptionCheck
       Data type  : REG_DWORD
       Value      : 1
   (Confirm the exact current OMA-URI/CSP path against
    https://learn.microsoft.com/en-us/windows/whats-new/enable-extended-security-updates-virtual
    before deploying at scale — Microsoft has iterated this delivery mechanism and the
    authoritative page is the source of truth, not this cached copy.)

3. Assign the profile to the physical endpoint devices (not the Cloud PCs themselves).

4. Validate deployment: on the endpoint,
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU" -Name EnableESUSubscriptionCheck
   should return Value = 1 once the policy has applied.
```

**Rollback:** Remove/unassign the Intune configuration profile; the registry value can be manually cleared with `Remove-ItemProperty` if immediate reversal is needed on a specific device.
</details>

---
## Evidence Pack

Run this on the affected Windows 10 device (requires admin). Captures everything needed for L3/licensing escalation — **read-only, makes no activation changes**:

```powershell
<#
.SYNOPSIS  Windows 10 ESU Evidence Collector
.NOTES     Run from an elevated PowerShell session. Does not install or activate any key.
#>

$reportPath = "C:\Temp\ESU_Evidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
Write-Host "Collecting ESU evidence to $reportPath..." -ForegroundColor Cyan

# 1. Build/version
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, CsDomain |
    Format-List | Out-File "$reportPath\01_Build.txt"

# 2. Prerequisite KBs
Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue |
    Select-Object HotFixID, InstalledOn | Out-File "$reportPath\02_PrereqKBs.txt"

# 3. Current licensing state (read-only query)
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv | Out-File "$reportPath\03_LicenseStatus.txt"

# 4. Endpoint reachability
$esuEndpoints = @(
    "go.microsoft.com","login.live.com","crl.microsoft.com",
    "activation.sls.microsoft.com","validation.sls.microsoft.com",
    "activation-v2.sls.microsoft.com","validation-v2.sls.microsoft.com",
    "displaycatalog.mp.microsoft.com","licensing.mp.microsoft.com","purchase.mp.microsoft.com",
    "displaycatalog.md.mp.microsoft.com","licensing.md.mp.microsoft.com","purchase.md.mp.microsoft.com"
)
$esuEndpoints | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $_; Reachable = $r.TcpTestSucceeded }
} | Format-Table -AutoSize | Out-File "$reportPath\04_EndpointReachability.txt"

# 5. Free-ESU (Windows 365 endpoint) registry check
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU" `
    -ErrorAction SilentlyContinue | Out-File "$reportPath\05_W365FreeESUFlag.txt"

Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "Evidence collected: $reportPath.zip" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check Windows 10 version/build | `Get-ComputerInfo \| Select-Object WindowsVersion, OsBuildNumber` |
| Check prerequisite KBs | `Get-HotFix -Id KB5066791, KB5072653` |
| Install the ESU MAK | `cscript //nologo slmgr.vbs /ipk <ESU MAK>` |
| Activate (Year 1) | `cscript //nologo slmgr.vbs /ato f520e45e-7413-4a34-a497-d2765967d094` |
| Activate (Year 2) | `cscript //nologo slmgr.vbs /ato 1043add5-23b1-4afb-9a0f-64343c8f3f8d` |
| Activate (Year 3) | `cscript //nologo slmgr.vbs /ato 83d49986-add3-41d7-ba33-87c7bfb5c0fb` |
| View full license detail | `cscript //nologo slmgr.vbs /dlv` |
| Get Installation ID (offline activation) | `cscript //nologo slmgr.vbs /dti <Activation ID>` |
| Activate via phone/Confirmation ID | `cscript //nologo slmgr.vbs /atp <Confirmation ID> <Activation ID>` |
| Test one activation endpoint | `Test-NetConnection -ComputerName activation.sls.microsoft.com -Port 443` |
| Check free-ESU W365 endpoint flag | `Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU` |
| VL role needed to view MAK | Product Key Reader or VL Administrator (Entra ID role) |
| Where to find the MAK | admin.microsoft.com → Billing → Your Products → Volume licensing → Contracts → View product keys |
| Request more MAK activations | [Request an increase to MAK activation limits](https://learn.microsoft.com/en-us/microsoft-365/commerce/licenses/product-keys-for-vl#request-an-increase-to-mak-activation-limits) |

---
## 🎓 Learning Pointers

- **ESU is a bridge, not a destination, and Microsoft says so explicitly.** The FAQ's own recommendation is to upgrade eligible PCs to Windows 11 via Autopatch/Intune, or move to Windows 365 for a Cloud PC, rather than to plan around ESU long-term. Treat ESU conversations with clients as a migration-timeline conversation, not a standalone product to sell indefinitely. [Extended Security Updates (ESU) program for Windows 10](https://learn.microsoft.com/en-us/windows/whats-new/extended-security-updates)
- **The pricing model punishes procrastination on purpose.** Year One is $61/device, doubling each year, and is cumulative — enrolling in Year Two means paying for Year One too. For a client sitting on dozens of legacy Windows 10 devices, the true cost of waiting compounds fast; model the 3-year total cost against a Windows 11 hardware refresh early. [Enable Windows 10 Extended Security Updates (ESU)](https://learn.microsoft.com/en-us/windows/whats-new/enable-extended-security-updates)
- **Order matters for the prerequisite KBs, and it's not obvious from the error messages.** `KB5072653` (the ESU Licensing Preparation Package) must be installed strictly after `KB5066791` — install them out of order and activation can silently misbehave with no explicit "wrong order" error. Always verify install *timestamps*, not just presence.
- **There is no more centralized ESU enrollment reporting from Microsoft after October 15, 2025.** This is a structural gap, not a temporary rough edge — build your own tracking (the accompanying `Get-ESUActivationStatus.ps1` script) into standard fleet hygiene rather than expecting a built-in Intune/admin-center report to appear.
- **Don't conflate the consumer wizard with the commercial MAK path when triaging a ticket.** A user describing an in-Settings "Enroll now" flow with a Microsoft Account sign-in is almost certainly on the *consumer* program, which is a different product with a different support path — verify domain/Entra join and management state before treating it as a commercial ESU MAK issue. [Windows 10 Consumer Extended Security Updates (ESU) program](https://www.microsoft.com/windows/extended-security-updates)
- **The Windows 365-connected-endpoint free path is easy to under-deliver.** It requires an explicit `EnableESUSubscriptionCheck` registry flag pushed via Intune — an org can have valid Windows 365 licenses and still see zero ESU coverage on physical endpoints simply because that one custom policy was never deployed. [Enable ESU for clients accessing cloud and virtual machines](https://learn.microsoft.com/en-us/windows/whats-new/enable-extended-security-updates-virtual)
