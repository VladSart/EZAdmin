# Windows Health Attestation Migration to Microsoft Azure Attestation — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index (with jump links)
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

This runbook covers Microsoft's announced migration of **Windows Health Attestation** compliance evaluation from the legacy **Device Health Attestation (DHA)** service to **Microsoft Azure Attestation (MAA)** — a Plan for Change posted to the Microsoft 365 Message Center as two companion notices, **MC1473156** ("Plan for Change: Intune migration for Windows Health Attestation to Microsoft Azure Attestation for Windows 11 devices," Intune service, Sept 16, 2026) and **MC1473600** ("Intune: Windows Health Attestation Migration to Microsoft Azure Attestation," Windows service, Sept 17, 2026). Both describe the identical change; Microsoft simply posted it against two service categories. Migration is targeted for the **end of Q1 calendar year 2027**, is entirely **service-side and automatic**, and has **no admin-facing opt-in/opt-out control**.

**Naming collision warning:** this repo already uses the acronym **MAA** for an unrelated feature — **Multi Admin Approval** (`Troubleshooting/MultiAdminApproval-A/B.md`, `Scripts/Get-MAAAccessPolicyAudit.ps1`). This document deliberately spells out "Azure Attestation" throughout rather than abbreviating it, to avoid confusion with that existing MAA content.

Scope of this document:
- Windows 11 devices only, with a compliance policy that evaluates at least one **Device Health** setting (BitLocker, Secure Boot, Code Integrity).
- The network-endpoint and firewall/proxy readiness work an MSP can and should do **today**, ahead of the actual cutover.
- The documented, permanent post-migration exclusions (Windows 10, GCC High/DoD).

Out of scope:
- Any other Windows compliance policy setting (password, OS version/build, encryption-at-rest without Device Health scope, Endpoint Protection status, custom compliance scripts) — entirely unaffected by this migration; see `CustomCompliance-A/B.md` for that separate mechanism.
- General DHA/TPM/BitLocker troubleshooting unrelated to network reachability — see standard Windows/BitLocker troubleshooting content for device-local attestation failures that aren't network-path issues.
- Multi Admin Approval (a distinct, unrelated Intune feature sharing the "MAA" initialism) — see `MultiAdminApproval-A/B.md`.

---

## How It Works

<details><summary>Full architecture</summary>

Today, when a Windows compliance policy evaluates a **Device Health** setting (BitLocker, Secure Boot, Code Integrity), the device's TPM-backed attestation report is validated through the legacy **Device Health Attestation (DHA)** service at `has.spserv.microsoft.com`. This is a single, global endpoint regardless of tenant location.

Microsoft is replacing this evaluation path — for Windows 11 devices in non-GCC-High/DoD tenants only — with **Microsoft Azure Attestation (MAA)**, Azure's general-purpose remote attestation service, instantiated as Intune-dedicated regional endpoints (hostname pattern `intunemaapeN.<azure-region-code>.attest.azure.net`). The driving motivation, per Microsoft's own framing in the source Message Center posts, is "better compliance checks directly tied to TPM-based attestation and faster responses using the Azure service instead of the legacy DHA endpoints" — i.e. moving off a single global legacy endpoint onto Azure's own regional attestation infrastructure.

```
┌──────────────────────────────────────────────────────────────────┐
│  Compliance policy evaluates a Device Health setting                │
│  (BitLocker / Secure Boot / Code Integrity) on a managed device      │
└───────────────────────────────┬──────────────────────────────────────┘
                                  │
                     ┌────────────┴─────────────┐
                     ▼                           ▼
        ┌─────────────────────────┐   ┌──────────────────────────────┐
        │  Windows 11 device        │   │  Windows 10 device, OR         │
        │  in a non-GCCH/DoD tenant │   │  device in a GCC High/DoD tenant │
        └─────────────┬─────────────┘   └───────────────┬───────────────┘
                       │                                   │
                       ▼                                   ▼
        ┌─────────────────────────────┐     ┌───────────────────────────────┐
        │  Microsoft Azure Attestation  │     │  Legacy Device Health           │
        │  (MAA) — regional endpoint     │     │  Attestation (DHA)              │
        │  set based on Intune tenant    │     │  has.spserv.microsoft.com       │
        │  location (NA/EU/APAC)         │     │  (single global endpoint,       │
        │  intunemaapeN.<region>         │     │  unchanged by this migration)   │
        │  .attest.azure.net             │     └───────────────────────────────┘
        └─────────────┬─────────────────┘
                       │  requires outbound HTTPS/443, no SSL inspection
                       ▼
        ┌─────────────────────────────────┐
        │  Attestation result returned to    │
        │  Intune → compliance state updates  │
        │  for BitLocker/Secure Boot/Code     │
        │  Integrity settings specifically     │
        └─────────────────────────────────────┘
```

**This is a service-side cutover, not a policy change.** There is no new Settings Catalog setting, no new compliance policy configuration, and no admin toggle to control timing or opt out. The only administrator-actionable work is **network readiness**: confirming the environment permits outbound access to the correct regional Azure Attestation endpoints before Microsoft's own rollout reaches the tenant. Everything else — which service evaluates the attestation, when the cutover happens for a given tenant — is entirely outside admin control.

**Two permanent, architecture-level exclusions exist,** not temporary transition carve-outs:
1. **Windows 10 devices** continue using the legacy DHA endpoint indefinitely, regardless of this migration's rollout status elsewhere in the tenant.
2. **GCC High and DoD tenants** continue using DHA indefinitely as well — this migration is explicitly scoped to commercial/GCC-standard cloud tenants only.

Both exclusions matter operationally: a mixed Windows 10/11 fleet, or a tenant that spans a commercial and a GCC High environment, will have some devices migrate to Azure Attestation and others permanently remain on DHA — both endpoint sets must stay reachable simultaneously in that scenario, not just the new one.

</details>

---

## Dependency Stack

```
[Intune tenant, non-GCCH/DoD]
    │
    ├── [Compliance policy with a Device Health setting configured]
    │     ├── Require BitLocker
    │     ├── Require Secure Boot to be enabled on the device
    │     └── Require code integrity
    │           (any other compliance setting is entirely outside this migration's scope)
    │
    ├── [Device OS = Windows 11]
    │     └── Windows 10 devices bypass this entire dependency chain — permanent DHA path
    │
    ├── [Migration has reached this tenant] (service-side, automatic, no admin control,
    │      targeted end of Q1 CY2027 — no published per-tenant schedule as of this writing)
    │
    ├── [Intune tenant location identified] (Tenant administration > Tenant status >
    │      Tenant details > Tenant location, e.g. "North America 0501")
    │           └── Determines which regional Azure Attestation endpoint set is authoritative
    │
    ├── [Outbound network path to the regional Azure Attestation endpoint set]
    │     ├── TCP/443 reachable
    │     ├── No SSL/TLS traffic inspection on the path (treated as required by analogy to
    │     │     the documented DHA-endpoint restriction — not yet independently re-confirmed
    │     │     by Microsoft for the Azure Attestation endpoints specifically)
    │     └── DNS resolution for `*.attest.azure.net` hostnames not blocked
    │
    └── [Attestation report returned and processed by Intune]
          └── Compliance state for the specific Device Health setting(s) updates
                (does not affect evaluation of any other compliance policy setting)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Windows 11 device suddenly non-compliant on BitLocker/Secure Boot/Code Integrity, no recent policy change | Firewall/proxy blocking the tenant's regional Azure Attestation endpoints post-migration | Reachability test to region-matched `*.attest.azure.net` endpoint |
| Same symptom, but tenant is GCC High/DoD | Migration doesn't apply — investigate as a standard DHA (`has.spserv.microsoft.com`) reachability or TPM issue instead | Confirm tenant cloud type first |
| Same symptom, but device is Windows 10 | Migration doesn't apply — Windows 10 always uses legacy DHA | Confirm device OS |
| Compliance failure on a setting other than BitLocker/Secure Boot/Code Integrity | Out of scope entirely — this migration only touches Device Health settings | Identify which compliance setting is actually failing |
| SSL-inspecting proxy/firewall present in the network path | Documented-by-analogy incompatibility (confirmed for DHA, presumed for Azure Attestation pending Microsoft confirmation) | Bypass/allowlist the attestation endpoints on the inspecting device |
| Ticket references this migration well before the announced rollout window | Migration is a Plan for Change targeted for end of Q1 CY2027 with no confirmed per-tenant date yet — likely a different root cause | Re-check Message Center for tenant-specific rollout confirmation |
| Uncertain which regional endpoint set applies | Region is derived from Intune tenant location, not device geography or company HQ | Tenant administration > Tenant status > Tenant details > Tenant location |

---

## Validation Steps

1. **In-scope confirmation.** Verify device is Windows 11 and tenant is not GCC High/DoD. Good: both conditions met. Bad: either fails — this migration is not the cause, redirect troubleshooting.
2. **Policy setting confirmation.** Open the failing compliance policy and confirm a Device Health setting (BitLocker/Secure Boot/Code Integrity) is actually configured and is the setting in a non-compliant state. Good: confirmed. Bad: a different setting is failing — unrelated to this migration.
3. **Tenant location lookup.** Intune admin center → Tenant administration → Tenant status → Tenant details → Tenant location. Good: a location value is present (e.g. "Europe 0301"). Record it — it determines the correct endpoint set.
4. **Regional endpoint reachability.** Test outbound TCP/443 to the endpoint(s) matching the tenant's region (see Command Cheat Sheet for the full table). Good: `TcpTestSucceeded : True` for at least one endpoint in the correct region. Bad: failures across the region's endpoint set — firewall/proxy work required.
5. **SSL inspection check.** Confirm no TLS-terminating proxy sits on the path to the attestation endpoint. Good: direct TLS to Microsoft, no re-signing certificate observed. Bad: inspection present — add to bypass list.
6. **DHA fallback check for excluded populations.** For Windows 10 devices or GCC High/DoD tenants, separately confirm reachability to `has.spserv.microsoft.com` instead — these populations never use the new endpoints.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Scope determination.** Establish device OS (Windows 11 vs. 10) and tenant cloud type (commercial/GCC vs. GCC High/DoD) before doing anything else — these two facts alone determine whether this migration can possibly be the root cause.

**Phase 2 — Policy-setting isolation.** Confirm the specific compliance setting failing is a Device Health setting (BitLocker/Secure Boot/Code Integrity), not a different, unrelated compliance requirement bundled in the same policy.

**Phase 3 — Tenant location and endpoint mapping.** Retrieve the tenant location from the portal and map it to the correct regional Azure Attestation endpoint set — do not infer the region from the tenant's country, billing address, or device geography; the portal value is authoritative.

**Phase 4 — Network path validation.** Test reachability and rule out SSL/TLS inspection on the mapped endpoint set. This is the only class of fix available to an admin for this migration — there is no policy-side remediation.

**Phase 5 — Timing sanity check.** If troubleshooting occurs well before the announced end-of-Q1-CY2027 target and no tenant-specific rollout notice exists in Message Center, treat this migration as an unlikely root cause and continue investigating other causes in parallel.

**Phase 6 — Exclusion-population handling.** For any Windows 10 device or GCC High/DoD tenant in the same fleet, apply DHA-path troubleshooting (`has.spserv.microsoft.com` reachability, TPM health) instead — do not attempt Azure Attestation endpoint fixes for these devices, they will never use them.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Pre-migration network readiness sweep (recommended before the tenant is actually migrated)</summary>

1. Identify the tenant's Intune tenant location (Tenant administration → Tenant status → Tenant details).
2. Map that location to the correct regional Azure Attestation endpoint set (Command Cheat Sheet table).
3. Add firewall/proxy allow rules for outbound TCP/443 to those `*.attest.azure.net` hostnames, mirroring the existing allow rules already in place for `*.manage.microsoft.com`/`*.dm.microsoft.com`.
4. Add the same hostnames to any SSL/TLS inspection bypass/allowlist already maintained for the legacy DHA endpoint and core Intune endpoints.
5. Confirm the legacy DHA endpoint (`has.spserv.microsoft.com`) remains allowed and uninspected for any Windows 10 devices or GCC High/DoD tenants that will never migrate.
6. Document the readiness work performed and date, so a future compliance-drift ticket around the actual cutover date can be triaged quickly against "was network readiness already done."

</details>

<details><summary>Playbook 2 — Responding to a live compliance-drift incident after migration reaches the tenant</summary>

1. Confirm scope (Phase 1 above) — Windows 11, non-GCCH/DoD.
2. Pull the tenant location and map to the regional endpoint set.
3. Run the reachability test from an affected device's network segment, not just from an admin workstation that may have a different network path.
4. If unreachable, escalate to network/firewall team with the specific hostname list and the SSL-inspection-bypass requirement — this is not an Intune-side configuration fix.
5. Re-check compliance state after the device's next scheduled check-in; do not expect immediate re-evaluation.
6. If multiple, geographically distinct sites show the same failure, confirm whether a central/shared proxy or SASE/SSE solution is inspecting or blocking traffic tenant-wide rather than troubleshooting site-by-site.

</details>

<details><summary>Playbook 3 — Auditing fleet readiness ahead of the announced rollout window</summary>

1. Use `Scripts/Get-AzureAttestationEndpointReadiness.ps1` to identify which managed devices have Device-Health-scoped compliance policies assigned and are running Windows 11 (the actual in-scope population).
2. Cross-reference against known network segments/sites to identify which sites still need the firewall/proxy work from Playbook 1.
3. Track GCC High/DoD and Windows 10 populations separately — confirm they are excluded from any planned endpoint-allowlisting change to avoid unnecessarily granting new firewall access where DHA already works.
4. Re-run periodically as Microsoft's rollout approaches the end-of-Q1-CY2027 target, since no granular per-tenant schedule has been published as of this writing.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects fleet-level Device-Health-compliance scoping and endpoint-reachability
    evidence ahead of, or during, the Windows Health Attestation → Azure Attestation
    migration (MC1473156 / MC1473600).
.DESCRIPTION
    Identifies which managed Windows 11 devices are actually in scope for this migration
    (i.e. targeted by a compliance policy using a Device Health setting), reports the
    tenant's configured location where available via Graph, and tests outbound reachability
    to the known regional Azure Attestation endpoint set from wherever the script is run.
    Compliance-policy READ requires DeviceManagementConfiguration.Read.All; device inventory
    requires DeviceManagementManagedDevices.Read.All.
.NOTES
    Read-only. Requires Microsoft.Graph.DeviceManagement module.
    Reachability results reflect the network path of the machine running the script, NOT
    necessarily every managed device's own network path — run it from representative
    network segments/sites, not just one admin workstation.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = ".\HealthAttestationMigrationEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All,DeviceManagementManagedDevices.Read.All" -NoWelcome
Write-Status "Connected." "OK"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Status "Querying managed Windows devices..."
$devices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All

foreach ($d in $devices) {
    $isWin11 = $d.OSVersion -match "^10\.0\.2[2-9]\d{3}" # heuristic: Windows 11 build ranges start at 10.0.22000
    $results.Add([PSCustomObject]@{
        DeviceName        = $d.DeviceName
        OSVersion         = $d.OSVersion
        LikelyWindows11   = $isWin11
        ComplianceState   = $d.ComplianceState
        LastSyncDateTime  = $d.LastSyncDateTime
        Note              = "Device-Health-setting scoping requires cross-referencing assigned compliance policy content — see portal checklist below"
    })
}

Write-Status "Collected $($results.Count) Windows device record(s)." "OK"

Write-Status ""
Write-Status "=== PORTAL-ONLY EVIDENCE — collect manually before escalating ===" "WARN"
$portalChecklist = @(
    "Intune admin center > Devices > Compliance policies > <policy> > confirm BitLocker/Secure Boot/Code Integrity settings configured"
    "Intune admin center > Tenant administration > Tenant status > Tenant details > Tenant location"
    "Confirm tenant cloud type (commercial/GCC vs. GCC High/DoD) via tenant licensing/admin center banner"
)
foreach ($item in $portalChecklist) {
    Write-Host "  [ ] $item" -ForegroundColor Yellow
    $results.Add([PSCustomObject]@{ DeviceName = "N/A"; Note = "PORTAL_CHECK: $item" })
}

Write-Status ""
Write-Status "=== Regional Azure Attestation endpoint reachability (run per site/segment) ===" "WARN"
# Endpoint list per Microsoft Learn "Network endpoints for Microsoft Intune" — Migrating device
# health attestation compliance policies to Microsoft Azure attestation. Region mapping for
# neu/weu/jpe entries inferred from standard Azure region-code suffixes; the live page's regional
# tabs render client-side and only fully surfaced the North America entries on direct fetch during
# authoring — re-verify the Europe/Asia Pacific grouping against the live page or tenant behavior
# before treating this mapping as authoritative for firewall automation.
$endpointsByRegion = @{
    "North America" = @(
        "intunemaape1.eus.attest.azure.net",
        "intunemaape2.eus2.attest.azure.net",
        "intunemaape3.cus.attest.azure.net",
        "intunemaape4.wus.attest.azure.net",
        "intunemaape5.scus.attest.azure.net",
        "intunemaape6.ncus.attest.azure.net"
    )
    "Europe (inferred grouping — verify)" = @(
        "intunemaape7.neu.attest.azure.net",
        "intunemaape8.neu.attest.azure.net",
        "intunemaape9.neu.attest.azure.net",
        "intunemaape10.weu.attest.azure.net",
        "intunemaape11.weu.attest.azure.net",
        "intunemaape12.weu.attest.azure.net"
    )
    "Asia Pacific (inferred grouping — verify)" = @(
        "intunemaape13.jpe.attest.azure.net",
        "intunemaape17.jpe.attest.azure.net",
        "intunemaape18.jpe.attest.azure.net",
        "intunemaape19.jpe.attest.azure.net"
    )
}

foreach ($region in $endpointsByRegion.Keys) {
    foreach ($endpoint in $endpointsByRegion[$region]) {
        try {
            $test = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
            $status = if ($test.TcpTestSucceeded) { "OK" } else { "ERROR" }
            Write-Status "$region : $endpoint -> $($test.TcpTestSucceeded)" $status
            $results.Add([PSCustomObject]@{ DeviceName = "N/A (network test)"; Note = "REACHABILITY: $region $endpoint = $($test.TcpTestSucceeded)" })
        } catch {
            Write-Status "$region : $endpoint -> test failed to run ($($_.Exception.Message))" "ERROR"
            $results.Add([PSCustomObject]@{ DeviceName = "N/A (network test)"; Note = "REACHABILITY: $region $endpoint = TEST_FAILED" })
        }
    }
}

# Legacy DHA endpoint — must remain reachable for Windows 10 devices and GCC High/DoD tenants
try {
    $dhaTest = Test-NetConnection -ComputerName "has.spserv.microsoft.com" -Port 443 -WarningAction SilentlyContinue
    Write-Status "Legacy DHA endpoint has.spserv.microsoft.com -> $($dhaTest.TcpTestSucceeded)" $(if ($dhaTest.TcpTestSucceeded) { "OK" } else { "WARN" })
    $results.Add([PSCustomObject]@{ DeviceName = "N/A (network test)"; Note = "REACHABILITY: Legacy DHA has.spserv.microsoft.com = $($dhaTest.TcpTestSucceeded)" })
} catch {
    Write-Status "Legacy DHA endpoint test failed to run" "WARN"
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to $OutputPath." "OK"
```

**What it cannot do:** definitively confirm which devices are in scope without a per-device compliance-policy-content join (compliance policy setting content requires enumerating each assigned policy's Settings Catalog payload, which the script does not attempt automatically — use the portal checklist); confirm actual per-tenant migration rollout status (no documented Graph field as of this writing); or guarantee the reachability test reflects every managed device's own network path — SSL inspection in particular can succeed a raw TCP test while still breaking real attestation traffic, so a clean `Test-NetConnection` result is necessary but not sufficient.

---

## Command Cheat Sheet

| Purpose | Command / Location |
|---------|---------------------|
| Find tenant location | Intune admin center → Tenant administration → Tenant status → Tenant details → Tenant location |
| Check a device's OS/compliance snapshot | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'"` |
| Test reachability to a regional endpoint | `Test-NetConnection -ComputerName "<endpoint>" -Port 443` |
| North America endpoints | `intunemaape1.eus` / `2.eus2` / `3.cus` / `4.wus` / `5.scus` / `6.ncus` `.attest.azure.net` |
| Europe endpoints (verify grouping) | `intunemaape7-9.neu` / `10-12.weu` `.attest.azure.net` |
| Asia Pacific endpoints (verify grouping) | `intunemaape13,17-19.jpe.attest.azure.net` |
| Legacy DHA endpoint (Win10 + GCCH/DoD, unchanged) | `has.spserv.microsoft.com` |
| View/edit a Device-Health-scoped compliance policy | Intune admin center → Devices → Compliance policies → `<policy>` → Properties |
| Source Message Center posts | MC1473156 (Intune service, Plan for Change), MC1473600 (Windows service) |
| Related, unrelated-feature disambiguation | `MultiAdminApproval-A/B.md` (different feature also abbreviated "MAA") |

---

## 🎓 Learning Pointers

- **This is one migration announced as two Message Center posts against two different service categories.** MC1473156 (Intune service, explicitly tagged "Plan for Change") and MC1473600 (Windows service, posted one day later, same content) describe the identical change. Don't double-count this as two separate roadmap items when triaging Message Center backlog. MS Docs: [Network endpoints for Microsoft Intune — Migrating device health attestation compliance policies to Microsoft Azure attestation](https://learn.microsoft.com/en-us/intune/fundamentals/endpoints#migrating-device-health-attestation-compliance-policies-to-microsoft-azure-attestation)

- **The only admin lever here is network readiness — there's no policy, no toggle, no opt-out.** Unlike most Intune "Plan for Change" items that eventually surface an admin-facing setting, this one is purely infrastructure: allow outbound HTTPS/443 to the correct regional endpoints, exempt them from SSL inspection, and wait. Treat firewall/proxy work as the deliverable, not a policy change in the Intune admin center.

- **Scope is a two-axis exclusion (OS version AND cloud type), not one.** Both Windows 10 devices and GCC High/DoD tenants are permanently excluded — independently of each other. A commercial-cloud tenant with a mixed Windows 10/11 fleet will have both endpoint sets in active use simultaneously and indefinitely; don't plan network changes assuming a clean full cutover.

- **The live Microsoft Learn page's regional tabs (North America/Europe/Asia Pacific) render client-side and only the North America tab's endpoint bullets came through on a direct fetch during authoring.** The Europe and Asia Pacific groupings in this runbook were reconstructed from the page's separate, complete consolidated FQDN list using standard Azure region-code suffix conventions (`neu`/`weu` = Europe, `jpe` = Japan East/Asia Pacific) — a reasonable inference, not a directly confirmed regional tab mapping. Re-verify against the live tabbed table before treating the Europe/Asia Pacific grouping as authoritative for firewall automation, consistent with this repo's standing "verify search/render snippets against the primary source" discipline.

- **SSL/TLS inspection incompatibility is explicitly documented for the legacy DHA endpoint and for `*.manage.microsoft.com`/`*.dm.microsoft.com`, but Microsoft's source text doesn't independently restate it for the new Azure Attestation endpoints in the same breath.** This runbook treats the new endpoints as carrying the same restriction by reasonable analogy — flag this explicitly as an assumption, not a confirmed fact, when advising a customer's network team, and re-check Microsoft's guidance as the rollout date approaches.

- **No per-tenant rollout schedule exists yet.** The end-of-Q1-CY2027 target is tenant-wide guidance, not a specific date for any given tenant. Don't treat a compliance-drift ticket today as automatically caused by this migration without first confirming Message Center shows tenant-specific rollout language — this is still, as of this writing, a Plan for Change rather than a live cutover for most tenants.
