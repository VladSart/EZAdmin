# Windows 10 Extended Security Updates (ESU) — Hotfix Runbook (Mode B: Ops)
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

Run these first — they tell you which path to take. This is the **commercial (MAK-based)** ESU path for managed/domain-joined or Entra-joined devices, not the consumer in-Settings wizard.

```powershell
# 1. Confirm this is even a 22H2 device (only 22H2 is ESU-eligible)
Get-ComputerInfo | Select-Object WindowsVersion, OsBuildNumber, CsDomain

# 2. Check prerequisite KBs are present and in the right order
Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue |
    Select-Object HotFixID, InstalledOn | Sort-Object InstalledOn

# 3. Check current licensing status (read-only)
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv

# 4. Quick reachability check to the two most common activation-blocking endpoints
Test-NetConnection -ComputerName activation.sls.microsoft.com -Port 443 -WarningAction SilentlyContinue |
    Select-Object ComputerName, TcpTestSucceeded
Test-NetConnection -ComputerName licensing.mp.microsoft.com -Port 443 -WarningAction SilentlyContinue |
    Select-Object ComputerName, TcpTestSucceeded

# 5. If this is a Windows 365-connected physical endpoint expecting FREE ESU, check the flag
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU" `
    -Name EnableESUSubscriptionCheck -ErrorAction SilentlyContinue
```

| Result | Next Step |
|--------|-----------|
| Not on Windows 10, version 22H2 | → [Fix 1 — Device Not on 22H2](#fix-1--device-not-on-22h2) |
| `KB5072653` missing or installed before `KB5066791` | → [Fix 2 — Prerequisite KB Order](#fix-2--prerequisite-kb-order) |
| `/ipk` fails with `0xC004F050` | → [Fix 3 — Invalid Product Key](#fix-3--invalid-product-key) |
| `/ato` fails with `0xC004F074` | → [Fix 4 — Activation Server Unreachable](#fix-4--activation-server-unreachable) |
| `/ato` fails with `0xC004C020` | → [Fix 5 — MAK Activation Limit Exceeded](#fix-5--mak-activation-limit-exceeded) |
| No internet path at all on this device | → [Fix 6 — Isolated/Air-Gapped Device](#fix-6--isolatedair-gapped-device) |
| User describes a consumer "Enroll now"/Microsoft Account wizard | → [Fix 7 — Wrong Program: Consumer vs. Commercial](#fix-7--wrong-program-consumer-vs-commercial) |
| Windows 365-connected endpoint, flag missing/0 | → [Fix 8 — Free ESU Flag Not Deployed](#fix-8--free-esu-flag-not-deployed) |
| Licensed but still not getting updates | → [Fix 9 — Licensed But No Updates Arriving](#fix-9--licensed-but-no-updates-arriving) |

---
## Dependency Cascade

<details><summary>What must be true for commercial ESU activation to succeed</summary>

```
Windows 10, version 22H2 (only eligible version)
        │
        ▼
KB5066791 installed, THEN KB5072653 installed (order matters)
        │
        ▼
Outbound HTTPS reachability to Microsoft activation/licensing endpoints
        │
        ▼
Entra ID account with Product Key Reader / VL Administrator role
  (to retrieve the MAK from the M365 admin center)
        │
        ▼
MAK installed:      slmgr.vbs /ipk <ESU MAK>
        │
        ▼
Activated against the correct year's Activation ID: slmgr.vbs /ato <Activation ID>
        │
        ▼
slmgr.vbs /dlv shows License Status: Licensed
        │
        ▼
Device receives ESU updates via its EXISTING update channel — no separate config
```
</details>

---
## Diagnosis & Validation Flow

**1. Confirm build eligibility**
```powershell
Get-ComputerInfo | Select-Object WindowsVersion, OsBuildNumber
```
Expected: `22H2`. Bad: anything else — not ESU-eligible, needs a feature update first.

**2. Confirm prerequisite KBs, in order**
```powershell
Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue | Sort-Object InstalledOn
```
Expected: `KB5066791` date ≤ `KB5072653` date. Bad: reversed order or `KB5072653` missing.

**3. Check current license state**
```cmd
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv
```
Expected: an ESU program name with `License Status: Licensed`. Bad: no ESU entry, or status other than `Licensed`.

**4. Test the activation endpoints**
```powershell
"go.microsoft.com","activation.sls.microsoft.com","validation.sls.microsoft.com",
"activation-v2.sls.microsoft.com","validation-v2.sls.microsoft.com",
"licensing.mp.microsoft.com","displaycatalog.mp.microsoft.com","purchase.mp.microsoft.com" |
    ForEach-Object { Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue |
    Select-Object ComputerName, TcpTestSucceeded }
```
Expected: `True` for all. Bad: any `False` — allowlist that endpoint.

**5. If free-ESU (W365-connected endpoint) is expected, check the flag**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU" -ErrorAction SilentlyContinue
```
Expected: `EnableESUSubscriptionCheck = 1`. Bad: missing or `0` — Intune policy hasn't landed.

---
## Common Fix Paths

<details><summary>Fix 1 — Device Not on 22H2</summary>

**When:** `Get-ComputerInfo` shows anything other than `22H2`.

```powershell
Get-ComputerInfo | Select-Object WindowsVersion, OsBuildNumber
```

There is no ESU shortcut here — the device must be moved to 22H2 through a normal feature-update cycle before any activation step can succeed. Deploy via Intune Feature Updates policy or Windows Update; see `Intune/Troubleshooting/FeatureUpdates-A.md` for stuck/failed feature-update triage.

**Rollback:** N/A — this is a required upgrade, not an optional change.
</details>

<details><summary>Fix 2 — Prerequisite KB Order</summary>

**When:** `KB5072653` is missing, or its install date is earlier than `KB5066791`'s.

```powershell
# Confirm current state
Get-HotFix -Id KB5066791, KB5072653 -ErrorAction SilentlyContinue | Sort-Object InstalledOn

# If KB5072653 is missing or was installed out of order, reinstall it AFTER
# confirming KB5066791 (or a later CU) is present. Deploy both via your normal
# update channel (WUfB/Intune/WSUS) rather than manual .msu install where possible,
# to keep the fleet consistent.
```

**Rollback:** Not destructive — reinstalling an update package in the correct order has no negative side effect.
</details>

<details><summary>Fix 3 — Invalid Product Key</summary>

**When:** `slmgr.vbs /ipk <ESU MAK>` fails with `0xC004F050`.

```cmd
:: Re-copy the MAK exactly from the M365 admin center — no extra spaces/characters
:: Billing > Your Products > Volume licensing > Contracts > View contracts >
::   [License ID] > More actions > View product keys
cscript //nologo C:\Windows\System32\slmgr.vbs /ipk <ESU MAK>
```

Also confirm the MAK actually belongs to the ESU program (not an unrelated VL product key pasted by mistake), and that it maps to the year you're intending to activate.

**Rollback:** N/A — a failed `/ipk` makes no change to install.
</details>

<details><summary>Fix 4 — Activation Server Unreachable</summary>

**When:** `slmgr.vbs /ato <Activation ID>` fails with `0xC004F074`.

```powershell
# Test every required endpoint — a generic "allow Microsoft 365" firewall rule
# often does NOT cover these activation-specific hosts
$esuEndpoints = "go.microsoft.com","login.live.com","crl.microsoft.com",
    "activation.sls.microsoft.com","validation.sls.microsoft.com",
    "activation-v2.sls.microsoft.com","validation-v2.sls.microsoft.com",
    "displaycatalog.mp.microsoft.com","licensing.mp.microsoft.com","purchase.mp.microsoft.com",
    "displaycatalog.md.mp.microsoft.com","licensing.md.mp.microsoft.com","purchase.md.mp.microsoft.com"
$esuEndpoints | ForEach-Object {
    Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue |
        Select-Object ComputerName, TcpTestSucceeded
}
```

Allowlist any endpoint showing `False` on the perimeter firewall/proxy, and check SSL-inspection exceptions specifically — inspection breaking the activation TLS handshake is a common false-negative cause even when the port itself is technically open.

**Rollback:** N/A — firewall allowlisting is additive.
</details>

<details><summary>Fix 5 — MAK Activation Limit Exceeded</summary>

**When:** `slmgr.vbs /ato` fails with `0xC004C020`.

```cmd
:: Confirm current state
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv
```

The tenant's MAK has run out of activations — common after mass reimaging (each reimage typically consumes another activation against the same key). Request an increase via [Request an increase to MAK activation limits](https://learn.microsoft.com/en-us/microsoft-365/commerce/licenses/product-keys-for-vl#request-an-increase-to-mak-activation-limits). While waiting, prioritize activation on devices closest to losing coverage.

**Rollback:** N/A — this is a licensing-limit request, not a config change.
</details>

<details><summary>Fix 6 — Isolated/Air-Gapped Device</summary>

**When:** Device has no path to Microsoft's activation servers by design (isolated network, no internet).

```cmd
:: Step 1 — Install the MAK
cscript //nologo C:\Windows\System32\slmgr.vbs /ipk <ESU MAK>

:: Step 2 — Get the Installation ID for the correct year
cscript //nologo C:\Windows\System32\slmgr.vbs /dti f520e45e-7413-4a34-a497-d2765967d094

:: Step 3 — On a DIFFERENT internet-connected machine, go to
:: https://aka.ms/aoh, submit the Installation ID, get a Confirmation ID

:: Step 4 — Activate using the Confirmation ID (no spaces)
cscript //nologo C:\Windows\System32\slmgr.vbs /atp <Confirmation ID> f520e45e-7413-4a34-a497-d2765967d094
```

For bulk isolated fleets, use VAMT Proxy Activation instead of doing this per-device — see `ESU-A.md` Playbook 2.

**Rollback:** N/A — additive activation, no config to revert.
</details>

<details><summary>Fix 7 — Wrong Program: Consumer vs. Commercial</summary>

**When:** A user or ticket describes an in-Settings "Enroll now" wizard with a Microsoft Account sign-in step, on a device you'd expect to be on the commercial MAK path.

```powershell
# Confirm join/management state first
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|EnterpriseJoined"
```

If the device is genuinely domain-joined/Entra-joined and Intune/GPO-managed, the consumer wizard is the wrong program entirely — redirect to the commercial MAK path (Triage above). If the device is a personally-owned/unmanaged Windows 10 Home machine, this genuinely IS the consumer program and this runbook does not apply — see [Windows 10 Consumer Extended Security Updates (ESU) program](https://www.microsoft.com/windows/extended-security-updates).

**Rollback:** N/A — diagnostic clarification only.
</details>

<details><summary>Fix 8 — Free ESU Flag Not Deployed</summary>

**When:** A physical endpoint connecting to a Windows 365 Cloud PC should have free ESU but the registry flag is missing or `0`.

```powershell
# Check current state
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform\ESU" -ErrorAction SilentlyContinue

# Confirm the user/device actually has an active Windows 365 license first —
# the free entitlement requires a genuine active W365 subscription behind it.
```

If the W365 license is confirmed active but the flag is missing, deploy (or re-check assignment/sync status of) the Intune custom OMA-URI policy setting `EnableESUSubscriptionCheck` = `1` under that registry path — see `ESU-A.md` Playbook 4 for the full deployment steps, and confirm the current OMA-URI path against [Enable ESU for clients accessing cloud and virtual machines](https://learn.microsoft.com/en-us/windows/whats-new/enable-extended-security-updates-virtual) since Microsoft has iterated this mechanism.

**Rollback:** Unassign the Intune profile, or `Remove-ItemProperty` the registry value if immediate reversal is needed.
</details>

<details><summary>Fix 9 — Licensed But No Updates Arriving</summary>

**When:** `slmgr.vbs /dlv` confirms `License Status: Licensed` but the device still hasn't received any post-EOL security updates after a reasonable window.

```cmd
:: Re-confirm licensing is genuinely in place
cscript //nologo C:\Windows\System32\slmgr.vbs /dlv
```

ESU licensing only unlocks *eligibility* — it does not create a special update ring or classification. Per Microsoft's own documentation, ESU updates flow through the device's normal Windows Update/WUfB/Intune/WSUS/ConfigMgr channel automatically once licensed. If licensing is confirmed but updates aren't arriving, treat this as a standard update-pipeline problem, not an ESU problem — escalate to `Windows/Troubleshooting/Windows Update/` or `Intune/Troubleshooting/FeatureUpdates-A.md` triage instead.

**Rollback:** N/A — diagnostic redirection only.
</details>

---
## Escalation Evidence

```
=== Windows 10 ESU Escalation Package ===
Date/Time            :
Device Name          :
Domain/Entra Join    :
Windows Version/Build:
Enrollment Path      : [ ] Commercial MAK  [ ] Free (W365-connected endpoint)  [ ] Consumer (wrong runbook)

--- Prerequisite KBs ---
KB5066791 installed  :
KB5072653 installed  :
Install order correct (5066791 before 5072653):

--- Licensing State (slmgr /dlv) ---
ESU Program Name     :
License Status       :
Activation ID used   :
Error code (if any)  :

--- Network Reachability ---
activation.sls.microsoft.com : 
licensing.mp.microsoft.com   : 
Other endpoint failures      :

--- Volume Licensing ---
License ID / Contract:
MAK activation count remaining (if known):

--- Free-ESU Flag (if applicable) ---
EnableESUSubscriptionCheck value:
W365 license active on user/device:

--- Actions Taken ---
1.
2.
3.
```

---
## 🎓 Learning Pointers

- **This is a licensing problem before it's a technical problem.** Most ESU tickets resolve to "wrong program" (consumer vs. commercial), "wrong prerequisite order," or "blocked activation endpoint" — not a genuine defect. Triage in that order before assuming something is broken.
- **`0xC004F074` almost always means a blocked endpoint, not a Microsoft-side outage.** The activation endpoint list is longer and more specific than a typical "allow Microsoft 365" firewall rule covers — check the full list, especially the `.sls.microsoft.com` and `.mp.microsoft.com` families. [Enable Windows 10 Extended Security Updates (ESU)](https://learn.microsoft.com/en-us/windows/whats-new/enable-extended-security-updates)
- **Reimaging consumes MAK activations.** A client doing frequent reimages on ESU-covered fleet devices will exhaust the activation count faster than expected — proactively request an increase rather than waiting for `0xC004C020` to surface mid-incident.
- **Once licensed, there's nothing else to configure.** No special WSUS product category, no separate Intune update ring — ESU updates ride the existing update channel. If updates aren't arriving post-licensing, the update pipeline itself is the problem, not ESU.
- **Microsoft stopped centrally tracking ESU enrollment after October 15, 2025.** Don't expect an admin-center report to confirm fleet-wide coverage — that's why `Windows/Scripts/Get-ESUActivationStatus.ps1` exists; run it and centralize the output yourselves.
