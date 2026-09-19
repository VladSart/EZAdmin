# Windows Health Attestation Migration to Microsoft Azure Attestation — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

**Scope check first:** this runbook covers Microsoft's **Plan for Change** (Message Center MC1473156 / MC1473600, posted Sept 16–17, 2026) migrating **Windows Health Attestation** compliance evaluation from the legacy **Device Health Attestation (DHA)** service to **Microsoft Azure Attestation (MAA)**. It is an Intune **service-side** change — nothing to configure to opt in — targeted for the **end of Q1 calendar year 2027**. It only affects **Windows 11** devices with a compliance policy using a **Device Health** setting (BitLocker, Secure Boot, Code Integrity). Windows 10 devices and **GCC High/DoD** tenants keep using the legacy DHA endpoint (`has.spserv.microsoft.com`) and are unaffected by this migration. Do not confuse the "MAA" abbreviation with this repo's **Multi Admin Approval** feature (`Troubleshooting/MultiAdminApproval-A/B.md`) — same three letters, unrelated Intune feature. This runbook always spells out "Azure Attestation" to avoid that collision.

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All,DeviceManagementManagedDevices.Read.All" -NoWelcome

# 1. Confirm the device is Windows 11 (Windows 10 is never in scope for this migration)
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
    Select-Object DeviceName, OperatingSystem, OSVersion, ComplianceState

# 2. Confirm the failing compliance policy actually uses a Device Health setting
#    (BitLocker / Secure Boot / Code Integrity — Settings Catalog "Device Health" category,
#     or the equivalent legacy compliance policy checkboxes). Portal is authoritative:
#     Intune admin center > Devices > Compliance policies > <policy> > Properties > Device Health

# 3. Confirm tenant location (determines which regional Azure Attestation endpoint set applies)
Write-Host "Intune admin center > Tenant administration > Tenant status > Tenant details > Tenant location" -ForegroundColor Cyan
```

**Interpretation:**

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Windows 11 device with a BitLocker/Secure Boot/Code Integrity compliance setting suddenly shows non-compliant with no policy change | Firewall/proxy is blocking outbound access to the tenant's regional Azure Attestation endpoints — the single expected failure mode of this migration | Fix 1 |
| Device is Windows 10 and is failing Device Health compliance | Out of scope for this migration entirely — Windows 10 stays on legacy DHA (`has.spserv.microsoft.com`); troubleshoot as a standard DHA/TPM issue, not this migration | Fix 2 |
| Tenant is GCC High or DoD | Out of scope — explicitly excluded from this migration per the source Message Center posts; do not apply this runbook | Fix 2 |
| Compliance policy doesn't use BitLocker/Secure Boot/Code Integrity at all | Out of scope — this migration only affects Device Health–based compliance evaluation, not general compliance policy failures | Not this runbook |
| Ticket references today's date but the migration "isn't live yet" | Expected — this is a **Plan for Change**, targeted end of Q1 CY2027; if today is before that window, root-cause elsewhere first (this migration cannot be the cause yet) | Confirm rollout status |
| SSL-inspecting proxy or TLS-terminating firewall is in the path | Documented incompatibility — DHA endpoints explicitly don't support SSL inspection; treat Azure Attestation endpoints the same way pending live confirmation | Fix 1 |

---

## Dependency Cascade

<details><summary>What must be true for Device Health compliance to evaluate successfully after migration</summary>

```
[Windows 11 device] + [Compliance policy with a Device Health setting]
(BitLocker / Secure Boot / Code Integrity)
    │
    ├── Tenant is NOT GCC High / DoD
    │     └── GCCH/DoD always uses legacy DHA endpoint (has.spserv.microsoft.com) — never migrates
    │
    ├── Device OS is Windows 11 (not Windows 10)
    │     └── Windows 10 always uses legacy DHA endpoint — never migrates
    │
    ├── Migration has actually reached this tenant (service-side, automatic, targeted end of Q1 CY2027)
    │     └── No admin toggle exists to opt in/out or control timing
    │
    ├── Intune tenant location identified
    │     └── Tenant administration > Tenant status > Tenant details > Tenant location
    │           └── Determines WHICH regional Azure Attestation (attest.azure.net) endpoint set applies
    │
    ├── Outbound HTTPS/443 reachable to the tenant's regional Azure Attestation endpoint set
    │     └── `*.attest.azure.net` (region-specific hostnames — see Mode A Command Cheat Sheet)
    │           └── Blocked by firewall/proxy → device cannot complete attestation → falls out of
    │                 compliance for BitLocker/Secure Boot/Code Integrity specifically
    │
    ├── No SSL/TLS traffic inspection on the attestation endpoint
    │     └── Documented as unsupported for the legacy DHA endpoints; treat Azure Attestation
    │           endpoints under the same constraint pending live re-verification
    │
    └── Device Health attestation report returned to Intune
          └── Compliance state for BitLocker/Secure Boot/Code Integrity settings updates accordingly
                (non-Device-Health compliance settings are entirely unaffected by this migration)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the device and tenant are actually in scope**
Windows 11, non-GCCH/DoD tenant. If either condition fails, this migration is not the cause — troubleshoot as a standard compliance/DHA issue instead.

**Step 2 — Confirm the compliance policy uses a Device Health setting**
Intune admin center → Devices → Compliance policies → open the assigned policy → confirm BitLocker, Secure Boot, or Code Integrity is configured. If the policy only uses unrelated settings (password, encryption-at-rest, OS version, etc.), this migration cannot be the cause.
Expected: policy includes at least one Device Health setting.
Bad: no Device Health setting present — look elsewhere.

**Step 3 — Identify tenant location**
Intune admin center → Tenant administration → Tenant status → Tenant details → **Tenant location** (e.g. "North America 0501"). This determines the specific regional Azure Attestation endpoint set the device must reach.
Expected: a location value like "North America ####", "Europe ####", or "Asia Pacific ####".

**Step 4 — Test outbound reachability to the regional Azure Attestation endpoints**
From the device (or a device on the same network path), confirm outbound TCP/443 to the region's `*.attest.azure.net` hostnames (full list in Mode A). A simple reachability check:
```powershell
Test-NetConnection -ComputerName "intunemaape1.eus.attest.azure.net" -Port 443
```
Substitute the hostname matching the tenant's region (Mode A has the full table). Expected: `TcpTestSucceeded : True`.

**Step 5 — Rule out SSL/TLS inspection**
Confirm no SSL-inspecting proxy or firewall is terminating/re-signing TLS on the path to the attestation endpoint. Microsoft explicitly documents this as unsupported for the legacy DHA endpoints; Azure Attestation endpoints should be treated the same until Microsoft explicitly states otherwise.

**Step 6 — Confirm timing against the migration rollout window**
This is a Plan for Change targeted for the **end of Q1 CY2027**, with no published per-tenant rollout schedule as of this writing. If the symptom appears well before that window on a still-DHA tenant, this runbook doesn't apply yet — re-check Message Center for a tenant-specific rollout notice before assuming migration has occurred.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Firewall/proxy is blocking the regional Azure Attestation endpoints</summary>

**Symptoms:** Windows 11 device with a BitLocker/Secure Boot/Code Integrity compliance setting falls out of compliance with no recent policy change; no local BitLocker/Secure Boot/Code Integrity problem exists on the device itself.

**Step 1 — Identify tenant location**
Intune admin center → Tenant administration → Tenant status → Tenant details → Tenant location.

**Step 2 — Allow outbound HTTPS/443 to the matching regional endpoint set**
Add firewall/proxy allow rules for the `*.attest.azure.net` hostnames matching the tenant's region (see Mode A's full endpoint table — do not guess the region from the tenant's country alone; use the portal value).

**Step 3 — Disable SSL/TLS inspection on those endpoints specifically**
If a corporate SSL-inspecting proxy is in the path, add the Azure Attestation endpoints to its inspection-bypass/allow list, matching the same treatment already required for the legacy DHA endpoint and for `*.manage.microsoft.com`/`*.dm.microsoft.com`.

**Step 4 — Re-test and allow for normal Intune check-in latency**
```powershell
Test-NetConnection -ComputerName "<regional-attest-endpoint>" -Port 443
```
Compliance re-evaluation follows the device's normal Intune check-in cycle — don't expect instant results.

**Rollback:** N/A — this is a network-access fix, not a configuration change to the device or policy.

</details>

<details>
<summary>Fix 2 — Device is out of scope (Windows 10, or GCC High/DoD tenant)</summary>

**Symptoms:** Ticket assumes this migration explains a Device Health compliance failure, but the device is Windows 10 or the tenant is GCC High/DoD.

**Step 1 — Confirm out-of-scope status**
Windows 10 devices and GCC High/DoD tenants continue using the legacy Device Health Attestation (DHA) endpoint `has.spserv.microsoft.com` indefinitely — this migration does not touch them.

**Step 2 — Redirect troubleshooting**
Treat the failure as a standard DHA/TPM/BitLocker compliance issue: check TPM health, BitLocker protector status, and Secure Boot state locally, and confirm `has.spserv.microsoft.com` reachability (unchanged requirement, unrelated to this migration).

**Rollback:** N/A — clarification only, no change made.

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — Health Attestation Azure Migration Issue
=====================================================================
Tenant:                        [tenant name / domain]
Tenant location (portal value): [e.g. North America 0501]
Device name:                    [device name]
Device OS:                      [Windows 11 build / Windows 10 — out of scope if 10]
GCC High / DoD tenant:           [Yes/No — out of scope if Yes]
Compliance policy name:          [policy name]
Device Health settings enabled:  [BitLocker / Secure Boot / Code Integrity — which ones]
Compliance state:                [Compliant / Non-compliant / Error]
First observed:                  [date/time]

Reachability test to regional Azure Attestation endpoint:
  Endpoint tested:                [hostname]
  Test-NetConnection result:      [Succeeded / Failed]
SSL/TLS inspection in path:       [Yes/No/Unknown]

Actions taken so far:
  □ Confirmed device is Windows 11 and tenant is not GCC High/DoD
  □ Confirmed compliance policy uses a Device Health setting
  □ Identified tenant location
  □ Tested outbound reachability to regional Azure Attestation endpoint(s)
  □ Checked for SSL/TLS inspection on the path
  □ [Other]

Next recommended action: [your assessment]
```

---

## 🎓 Learning Pointers

- **This is a Plan for Change, not a live cutover — but the network readiness work is actionable today.** Microsoft posted two near-identical Message Center notices (MC1473156, tagged Plan for Change under the Intune service; MC1473600, posted a day later under the Windows service) describing the same migration — treat them as a single change, not two separate ones, when triaging Message Center noise. MS Docs: [Network endpoints for Microsoft Intune — Migrating device health attestation compliance policies to Microsoft Azure attestation](https://learn.microsoft.com/en-us/intune/fundamentals/endpoints#migrating-device-health-attestation-compliance-policies-to-microsoft-azure-attestation)

- **Scope is narrower than "Windows compliance" — it's specifically Device Health settings.** Only BitLocker, Secure Boot, and Code Integrity compliance evaluation moves to Azure Attestation. Every other compliance policy setting (password, OS version, encryption-at-rest, custom compliance scripts, etc.) is completely unaffected — don't over-apply this runbook to unrelated compliance failures.

- **Two durable exclusions exist and won't change even after the migration completes:** Windows 10 devices and GCC High/DoD tenants keep the legacy DHA endpoint (`has.spserv.microsoft.com`) permanently for this purpose. This is a real, stated architecture decision, not a temporary transition detail.

- **The regional endpoint tabs on Microsoft's own Learn page render client-side and didn't fully surface all three regions on a live fetch during authoring** — only the North America tab's endpoint list rendered directly; the Europe/Asia Pacific endpoint mapping used here was derived from the page's separate consolidated FQDN list, cross-referenced by standard Azure region-code suffixes (`neu`/`weu` = Europe, `jpe` = Japan East/Asia Pacific). Re-verify the live tabbed table (or the tenant's own Tenant location value) before hard-coding endpoints into firewall automation — see Mode A for the full caveat and endpoint table.

- **SSL/TLS inspection incompatibility is documented for the legacy DHA endpoint, not yet explicitly re-stated for Azure Attestation in the same sentence.** Treat Azure Attestation endpoints under the same no-inspection constraint as a safe working assumption (consistent with `*.manage.microsoft.com`/`*.dm.microsoft.com` and the DHA endpoint), but flag this as an assumption worth re-confirming against Microsoft's guidance as the migration approaches its rollout window, not a hard-confirmed fact for the new endpoints specifically.
