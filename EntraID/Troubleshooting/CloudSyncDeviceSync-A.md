# Microsoft Entra Cloud Sync Device Sync (Preview) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- **Device sync**, a **public preview** capability (available since the end of July 2026) that closes what had been Cloud Sync's single most-cited feature gap against Connect Sync: synchronizing on-premises Active Directory **computer objects** to Microsoft Entra ID via a new `AD2AADDeviceSync` job type in an existing **AD to Microsoft Entra ID** Cloud Sync configuration
- The service connection point (SCP) prerequisite, the provisioning-agent version floor, the attribute mapping table, on-demand device provisioning, Microsoft Graph management of the sync job, and deleted-device recovery
- How this preview capability changes the Cloud Sync vs. Connect Sync feature-comparison picture used in `CloudSyncMigration-A.md`/`-B.md` — this file is the authoritative deep-dive on the capability itself; the migration runbooks reference it rather than duplicate it

**Does not cover:**
- **Device *writeback*** (Entra ID → AD) — this remains a Connect Sync-only capability. Device sync is one-directional (AD → Entra ID) only.
- **Cloud Kerberos Trust** — the separate, **generally available** mechanism for completing Microsoft Entra hybrid join without any device-sync dependency at all. Still the recommended path for a production-critical hybrid-join rollout today; see the Learning Pointers for why preview status matters here.
- **General Cloud Sync agent health, quarantine, or gMSA auth** — see `CloudSync-A.md`/`-B.md` for day-2 operation of an already-configured Cloud Sync deployment.
- **The broader Connect Sync → Cloud Sync migration decision** — see `CloudSyncMigration-A.md`/`-B.md` for the full readiness framework this capability now feeds into.
- **User provisioning to AD** — still unsupported by either sync tool; unrelated to this feature.

**Assumes:**
- An existing, functioning **AD to Microsoft Entra ID** Cloud Sync configuration (user/group provisioning already working)
- Microsoft Entra provisioning agent version **1.1.1107 or later** (device sync's hard version floor — the job type doesn't exist below this)
- Temporary access to an **Enterprise Admins** account in each AD forest containing domain-joined computers (SCP configuration only — not needed day-to-day)
- A **Hybrid Identity Administrator** account (non-guest) for enabling device sync in the Microsoft Entra admin center
- Comfort with this being **preview** software — subject to the Azure Preview Supplemental Terms, no GA SLA, and a feature set that can still change before general availability

---
## How It Works

<details><summary>Full architecture — the device sync model</summary>

### What actually moves, and in which direction

Device sync uses a dedicated synchronization job template, `AD2AADDeviceSync`, layered onto an existing AD-to-Entra Cloud Sync configuration. It reads AD **computer objects** and creates/updates corresponding **device objects** in Microsoft Entra ID. After a computer object syncs this way, the device can complete **Microsoft Entra hybrid join** — the same end state Connect Sync's device sync has always produced, just via a different provisioning agent-based pipeline instead of the on-prem Connect Sync sync engine.

The relationship is strictly one-directional. There is no AD2AADDeviceSync equivalent that writes Entra device state back into AD — that remains Connect Sync's Device Writeback feature, which Cloud Sync does not and will not replicate (Microsoft's stated direction for hybrid-join device state going forward is Cloud Kerberos Trust, not device writeback).

### The service connection point — a one-time, per-forest prerequisite

Devices discover which Microsoft Entra tenant to register against via a **service connection point (SCP)** object in AD, created under `CN=Device Registration Configuration,CN=Services` in the Configuration naming context. This is the *same* SCP mechanism classic Hybrid Azure AD Join has always used — device sync doesn't introduce a new discovery mechanism, it reuses the existing one.

Configuring it requires exactly one Enterprise Admins-authenticated PowerShell run per AD forest (Microsoft ships a documented `ConfigureSCP.ps1` script for this) — set `azureADName` (the verified domain devices authenticate against) and `azureADId` (the tenant GUID) as `keywords` on the SCP object. Critically, if an SCP already exists in the forest (common in environments with existing Hybrid Azure AD Join via Connect Sync), **the script clears the existing `keywords` values and replaces them** — always read the existing SCP values first and record them before running the script, so a mistake is recoverable.

Because this step needs Enterprise Admins (a Tier-0 credential), Microsoft's own guidance is to use a just-in-time privileged access process rather than a standing account — this is a one-time configuration action, not a recurring operational one.

### Enabling the job — Basics, not a separate configuration object

Device sync is not a new Cloud Sync configuration — it's a toggle (**Enable device sync**) on the **Basics** properties of an *existing* AD-to-Entra Cloud Sync configuration. It is disabled by default even after the provisioning agent meets the version floor; nothing changes for a tenant until an admin explicitly flips it. Once enabled, the `AD2AADDeviceSync` job runs on its own schedule as part of that same Cloud Sync configuration, alongside (not replacing) the existing user/group/contact sync jobs.

### Attribute mapping — a fixed, non-customizable set

Unlike the user/group attribute flows in a Cloud Sync configuration (which use an expression-builder editor), device sync ships a fixed mapping table with no customization surface documented as of this writing:

| Microsoft Entra attribute | AD attribute | Mapping type |
|---|---|---|
| `AccountEnabled` | `userAccountControl` | Expression |
| `DeviceId` | `objectGUID` | Direct |
| `DeviceOSType` | `operatingSystem` | Expression |
| `DeviceTrustType` | None — always `ServerAd` | Expression |
| `DisplayName` | `displayName`, `dNSHostName` | Expression |
| `OnPremiseSecurityIdentifier` | `objectSid` | Direct |
| `RegisteredOwnerReference` | `mS-DS-CreatorSID` | **Once** — applied only the first time the computer object is found |
| `SourceAnchor` | `objectGUID` | Direct |
| `UserCertificate` | `userCertificate` | Direct |

The `DeviceTrustType` value is hardcoded to `ServerAd` for every device sync-provisioned object — this is the same trust type Connect Sync's Hybrid Azure AD Join has always produced, which is precisely why post-sync hybrid join behaves identically to the Connect Sync path from the device's own perspective.

The `Once`-type mapping on `RegisteredOwnerReference` is a genuine gotcha: if the AD computer object's `mS-DS-CreatorSID` changes later (rare, but possible after certain AD object operations), that change will **not** re-flow to Entra ID — the Entra attribute was already set on first sync and stays put.

### Provisioning paths — scheduled cycle, on-demand, and Graph

Three ways a computer object actually gets synced:

1. **The job's normal sync cycle** — same cadence behavior as any other Cloud Sync job once device sync is enabled.
2. **Provision on demand** (portal) — Cloud Sync configuration → **Provision on demand** → **Device** tab → supply the AD computer's distinguished name → **Provision**. Useful for validating a single device without waiting for or forcing a full cycle.
3. **Microsoft Graph** — create a `synchronizationJob` with `templateId: AD2AADDeviceSync` on the AD-to-Entra service principal, `Start` it, then (optionally) call `synchronizationJob: provisionOnDemand` with `objectTypeName: computer` and the device sync rule ID (read from `synchronizationSchema`) for single-device on-demand provisioning via automation.

### Deleted-device recovery — three independent deletion triggers, one recovery model

A device can leave Microsoft Entra ID through three separate paths that don't all originate from Cloud Sync itself:
- The AD computer object is deleted → Cloud Sync deletes the corresponding Entra device on next cycle (expected, intentional).
- `dsregcmd /leave` runs on the device → Azure Device Registration Service deletes it independently of Cloud Sync.
- An admin manually deletes the device from **Entra ID > Devices** in the portal.

The important architectural detail: **if anything other than Cloud Sync deletes the device, Cloud Sync will not automatically re-create it on the next sync cycle** unless the AD computer object itself changes (a property write, even a no-op-looking one, triggers re-evaluation). Recovery is therefore one of: restore from **Deleted devices** in the portal, force a change on the AD computer object and wait for the next cycle, or use Provision on Demand for an immediate recovery.

</details>

---
## Dependency Stack

```
Layer 5 — Preview status (governs risk posture, not a technical gate)
          — Azure Preview Supplemental Terms apply; no GA SLA; feature set can
                still change before General Availability
Layer 4 — Prerequisites
          ├─ Existing AD-to-Entra Cloud Sync configuration (user/group sync
          │       already functioning)
          ├─ Provisioning agent version 1.1.1107+ (hard floor — job type does
          │       not exist below this version)
          └─ Hybrid Identity Administrator account (non-guest) for enabling
                the feature in the admin center
Layer 3 — Per-forest one-time setup
          ├─ Service connection point (SCP) configured/verified in EVERY AD
          │       forest containing domain-joined computers
          └─ Enterprise Admins access used just-in-time, not as a standing
                credential, to run ConfigureSCP.ps1
Layer 2 — Enablement
          └─ "Enable device sync" toggle on the AD-to-Entra Cloud Sync
                configuration's Basics properties (off by default, even once
                prerequisites are met)
Layer 1 — Sync execution
          ├─ AD2AADDeviceSync job runs on the configuration's normal cycle
          ├─ Fixed, non-customizable attribute mapping table (see How It
          │       Works) — no expression-builder equivalent for devices
          └─ On-demand provisioning (portal or Graph) available for
                single-device validation without a full cycle
Layer 0 — Resulting state
          ├─ Entra device object created with DeviceTrustType = ServerAd
          ├─ Device eligible to complete Microsoft Entra hybrid join
          └─ NO reverse path — device writeback to AD remains Connect
                Sync-only; this is one-directional
```

A gap at Layer 3 (SCP not configured, or configured for the wrong tenant/domain) means devices in that forest never discover where to register — this is the most common "why isn't anything happening" root cause and has nothing to do with the Cloud Sync job itself.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device sync toggle doesn't appear, or the job type isn't offered | Provisioning agent below version 1.1.1107 | Confirm installed agent version against the release history; upgrade before anything else |
| Toggle is available and enabled, but no devices appear in Entra ID | SCP missing, misconfigured, or pointing at the wrong tenant/domain in that forest | Re-run the SCP verification step (LDAP read below); confirm `azureADName`/`azureADId` match the intended tenant |
| Some computers sync, others in the same OU don't | Cloud Sync job's scope doesn't include those computers, or they're outside the AD-to-Entra configuration's connector scope | Confirm the configuration's directory/OU scope includes the missing computers |
| A device was deleted (accidentally or by policy) and never comes back | Deletion originated outside Cloud Sync (manual portal delete, `dsregcmd /leave`) and no AD-side change has occurred since to re-trigger sync | Restore from Deleted devices, force an AD attribute change, or use Provision on Demand |
| `RegisteredOwnerReference` is wrong/stale for a device that changed hands | The `Once` mapping type means this attribute only ever flows on first sync | No supported remediation via re-sync; correct manually in Entra ID if needed, understanding it won't be overwritten again automatically |
| Team assumed this replaces Hybrid Azure AD Join entirely and deprioritized Cloud Kerberos Trust planning | Device sync is preview, one-directional, and functionally narrower than the full Connect Sync device story (no writeback) | Reframe: device sync closes the *inbound* AD→Entra gap for hybrid join, but Cloud Kerberos Trust remains the GA-supported modernization path for organizations not ready to depend on preview functionality |
| SCP script run but a *different* forest's computers still don't discover the tenant | SCP is per-forest — a script run in one forest does not configure any other forest containing domain-joined computers | Confirm the script was run (or the existing SCP verified) in every forest with in-scope computers, not just the first one |

---
## Validation Steps

1. **Provisioning agent version meets the floor.**
   ```powershell
   (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent" -ErrorAction SilentlyContinue).Version
   ```
   Expected: 1.1.1107 or later. Bad: older version, or the key doesn't exist (agent not installed at all).

2. **SCP exists and points at the correct tenant, in every relevant forest.**
   ```powershell
   $configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
   $scp = [ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN"
   $scp.keywords
   ```
   Expected: `azureADName:<verified-domain>` and `azureADId:<tenant-guid>` matching the intended tenant. Bad: values from a different/legacy tenant, missing keywords entirely, or the SCP object not existing.

3. **Device sync is actually enabled on the configuration.**
   Portal: Cloud Sync configuration → **Properties** → **Basics** → confirm **Device sync: Enabled** (not Disabled). Bad: still showing Disabled despite believing it was turned on — the edit may not have been applied/saved.

4. **On-demand provisioning succeeds for a known test computer.**
   Portal: **Provision on demand** → **Device** tab → supply a test computer's DN → **Provision**. Expected: success with the device visible in Entra ID shortly after. Bad: an error surfaced immediately — usually an SCP or scope problem, not a transient sync delay.

5. **Resulting device object has the expected trust type.**
   ```powershell
   Get-MgDevice -Filter "displayName eq '<device-name>'" | Select-Object DisplayName, TrustType, DeviceId
   ```
   Expected: `TrustType` = `ServerAd`. Bad: device not found at all, or a different trust type (suggests it was created through a different path, e.g., an existing Hybrid Azure AD Join via Connect Sync, not this feature).

6. **Deleted-device recovery path is understood and tested at least once in a non-production forest/OU.**
   Expected: team can distinguish "AD computer deleted → expected Cloud Sync-driven removal" from "device removed by something else → needs manual recovery." Bad: assuming every missing device will simply reappear on the next cycle.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the provisioning agent version floor before anything else.**
Below 1.1.1107, the `AD2AADDeviceSync` job type simply isn't available — there's nothing to troubleshoot in the sync logic until the agent is upgraded.

**Phase 2 — Verify the SCP in every forest that has in-scope domain-joined computers.**
This is a per-forest object, not a per-tenant or per-Cloud-Sync-configuration setting. A multi-forest environment needs this checked (or configured) once per forest — assuming one forest's success means every forest is ready is the most common miss.

**Phase 3 — Confirm the toggle is enabled and the job has actually run at least one cycle.**
Enabling the toggle doesn't force an immediate sync — allow at least one normal cycle, or use Provision on Demand to force validation without waiting.

**Phase 4 — Validate scope: which computers are, and aren't, covered.**
The device sync job rides the same directory/OU scope as the rest of that Cloud Sync configuration — a computer outside that scope won't sync regardless of SCP or agent version correctness.

**Phase 5 — For missing/deleted devices, identify the deletion trigger before assuming a bug.**
Three different things can remove a device from Entra ID (see Symptom → Cause Map) — only one of them (AD computer object deletion) is something Cloud Sync will "just handle" on the next cycle by design.

**Phase 6 — Treat this as preview functionality in every recommendation.**
Set expectations accordingly with the customer: no GA SLA, subject to change, and Cloud Kerberos Trust remains the safer default recommendation for a production-critical hybrid-join dependency until this feature reaches general availability.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Enable device sync for a pilot forest/OU</summary>

1. Confirm the provisioning agent is at version 1.1.1107+ (Validation Step 1); upgrade first if not.
2. Confirm or configure the SCP in the target forest using Microsoft's `ConfigureSCP.ps1` (Enterprise Admins, just-in-time access) — record any pre-existing `keywords` values first in case of rollback.
3. In the Microsoft Entra admin center, open the existing AD-to-Entra Cloud Sync configuration → **Properties** → **Basics** → edit → **Enable device sync** → **Apply**.
4. Use **Provision on demand** → **Device** tab to sync a single known-good test computer rather than waiting for/forcing a full-scope cycle.
5. Validate the resulting device object (Validation Steps 4-5).
6. Only after a successful, validated single-device test, allow the configuration's normal cycle to pick up the rest of the in-scope computers.

**Rollback:** disable the **Device sync** toggle on the configuration's Basics properties. This stops new device sync activity; it does not retroactively remove already-synced device objects (delete those manually from **Entra ID > Devices** if a full rollback is required). If the SCP was newly created (not pre-existing), it can be left in place or removed — leaving it in place is harmless since it only affects device discovery, not Cloud Sync's device sync toggle state.
</details>

<details><summary>Playbook 2 — Multi-forest rollout</summary>

1. Repeat Playbook 1's SCP step independently in **every** AD forest containing domain-joined computers in scope — do not assume one forest's SCP configuration covers any other forest.
2. Track SCP status per forest (configured/verified vs. not yet done) separately from the single tenant-wide Cloud Sync "Enable device sync" toggle, since these operate at different scopes.
3. Stagger validation by forest: confirm Playbook 1's single-device test succeeds in each forest before considering that forest done.

**Rollback:** per-forest — reverting one forest's SCP `keywords` to its pre-existing values (recorded in Playbook 1 step 2) does not affect any other forest or the tenant-wide toggle.
</details>

<details><summary>Playbook 3 — Recover a device that isn't re-appearing after deletion</summary>

1. Determine the deletion trigger: check **Entra ID > Devices > Deleted devices** for the device's last-known state and deletion timestamp; correlate against AD computer object state (still present? recently modified?) and any known `dsregcmd /leave` activity on the endpoint.
2. If the AD computer object still exists and is unchanged, the device sync job has no reason to re-provision it on its own — use **Provision on Demand** for an immediate, explicit re-sync.
3. Alternatively, restore directly from **Deleted devices** in the portal if the AD-side object and Entra history are both intact and consistent.
4. If neither path resolves it, make an inconsequential attribute change on the AD computer object (this forces re-evaluation on the next cycle) as a fallback.

**Rollback:** none — this is a recovery action, not a destructive change.
</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Entra Cloud Sync device sync (preview) readiness and status
             evidence for planning or ticket escalation.
.DESCRIPTION Read-only. Checks provisioning agent version against the 1.1.1107
             floor, reads the local forest's SCP keywords (run once per forest),
             and cross-references Entra device objects with TrustType = ServerAd
             via Microsoft Graph. Does not enable or change any configuration.
.NOTES       Run on a domain-joined host with the ActiveDirectory module and an
             active Graph connection (Connect-MgGraph -Scopes "Device.Read.All").
             The SCP check requires only read access to the Configuration
             naming context -- no Enterprise Admins membership needed to READ it.
#>

$agentKey = "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent"
$agentVersion = (Get-ItemProperty -Path $agentKey -ErrorAction SilentlyContinue).Version
$agentMeetsFloor = $false
if ($agentVersion) {
    try { $agentMeetsFloor = ([version]$agentVersion) -ge ([version]"1.1.1107") } catch {}
}

$configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
$scpPath  = "LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN"
$scpKeywords = $null
if ([System.DirectoryServices.DirectoryEntry]::Exists($scpPath)) {
    $scpKeywords = ([ADSI]$scpPath).keywords
}

$serverAdDeviceCount = (Get-MgDevice -Filter "trustType eq 'ServerAd'" -All -ErrorAction SilentlyContinue).Count

[PSCustomObject]@{
    Forest                  = (Get-ADDomain -ErrorAction SilentlyContinue).Forest
    ProvisioningAgentVersion = $agentVersion
    MeetsDeviceSyncFloor    = $agentMeetsFloor
    SCPExists               = [bool]$scpKeywords
    SCPKeywords             = ($scpKeywords -join "; ")
    ServerAdTrustDeviceCount = $serverAdDeviceCount
    CollectedAt             = Get-Date
} | Export-Csv -Path ".\CloudSyncDeviceSyncReadiness_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd).csv" -NoTypeInformation
```

---
## Command Cheat Sheet

```powershell
# Installed provisioning agent version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent" -ErrorAction SilentlyContinue).Version

# Read (not modify) the local forest's SCP keywords
$configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
([ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN").keywords

# Devices provisioned with the ServerAd trust type (Connect Sync OR Cloud Sync device sync -- both produce this)
Get-MgDevice -Filter "trustType eq 'ServerAd'" -All

# Look up a specific synced device
Get-MgDevice -Filter "displayName eq '<device-name>'" | Select-Object DisplayName, TrustType, DeviceId, ApproximateLastSignInDateTime

# Graph: create + start an AD2AADDeviceSync job (requires the AD-to-Entra service principal ID)
# POST /servicePrincipals/{id}/synchronization/jobs   { "templateId": "AD2AADDeviceSync" }
# POST /servicePrincipals/{id}/synchronization/jobs/{jobId}/start

# Graph: on-demand device provisioning (requires the device sync rule ID from synchronizationSchema)
# POST /servicePrincipals/{id}/synchronization/jobs/{jobId}/provisionOnDemand
#   { "objectId": "<computer DN>", "objectTypeName": "computer", "ruleId": "<rule-id>" }

# Official reference
# https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/device-sync
```

---
## 🎓 Learning Pointers

- **This closes what `CloudSyncMigration-A.md`/`-B.md` used to call a hard, unconditional gap -- but only as a preview.** As of end of July 2026, Cloud Sync can synchronize AD computer objects for Hybrid Azure AD Join purposes. Update any prior "device sync = automatic near-term blocker" framing to "device sync now has a preview-status path -- evaluate risk tolerance for preview functionality before treating it as production-ready for a given customer." [Configure device sync with Microsoft Entra Cloud Sync (preview)](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/device-sync)
- **One-directional only -- don't let "device sync" imply device writeback.** The name describes AD -> Entra ID synchronization of computer objects, not the reverse. Device Writeback (Entra -> AD) remains Connect Sync-only and has no Cloud Sync roadmap item at all; Microsoft's stated direction for that use case is Cloud Kerberos Trust instead.
- **The SCP is per-forest, and the configuration script is destructive to existing keywords if one already exists.** Always read-before-write here -- a multi-forest customer with an existing Hybrid Azure AD Join SCP from Connect Sync needs each forest's existing keywords recorded before running `ConfigureSCP.ps1`, in case of a mistake or an unintended tenant target.
- **`RegisteredOwnerReference`'s `Once` mapping type is an easy-to-miss gotcha.** Unlike every other mapped attribute, this one is intentionally not kept in sync after first write -- a later ownership change on the AD side will not propagate. Don't debug this as a sync failure; it's documented, expected behavior.
- **Preview status is a genuine input to the recommendation, not a formality.** For a customer with a production-critical Hybrid Azure AD Join dependency today, Cloud Kerberos Trust (GA) remains the safer default. Device sync is best positioned as "worth piloting now, worth planning around for GA," not as an immediate wholesale replacement for an existing device-join strategy.
