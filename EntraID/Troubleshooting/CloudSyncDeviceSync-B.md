# Microsoft Entra Cloud Sync Device Sync (Preview) — Hotfix Runbook (Mode B: Ops)
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

```powershell
# 1. Provisioning agent version -- device sync needs 1.1.1107+, full stop
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent" -ErrorAction SilentlyContinue).Version

# 2. Local forest's SCP keywords (read-only -- no Enterprise Admins needed to READ)
$configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
([ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN").keywords

# 3. Devices with the ServerAd trust type already in Entra ID (either Connect Sync or
#    Cloud Sync device sync produces this trust type -- this alone doesn't tell you which)
Get-MgDevice -Filter "trustType eq 'ServerAd'" -All -ConsistencyLevel eventual -CountVariable c
$c

# 4. Is a specific test computer's AD object healthy/unchanged recently?
Get-ADComputer -Identity "<computer-name>" -Properties whenChanged, mS-DS-CreatorSID

# 5. Confirm device sync is enabled on the Cloud Sync configuration (portal check --
#    Entra ID > Entra Connect > Cloud sync > <config> > Properties > Basics)
```

| Triage result | Interpretation | Do this |
|---|---|---|
| Agent version below 1.1.1107 | Device sync job type isn't available at all | Fix 1 |
| SCP keywords empty or missing | Devices in this forest can't discover the tenant | Fix 2 |
| SCP keywords present but wrong tenant GUID/domain | SCP points at the wrong tenant (legacy or misconfigured) | Fix 2 |
| Basics shows "Device sync: Disabled" | Feature never enabled on this configuration | Fix 3 |
| Enabled, SCP correct, agent current -- but a specific computer still doesn't sync | Scope issue (computer outside the Cloud Sync configuration's OU/connector scope) | Fix 4 |
| A device disappeared and hasn't come back | Deletion originated outside Cloud Sync (manual delete or `dsregcmd /leave`) | Fix 5 |
| `RegisteredOwnerReference` looks wrong for a reassigned device | `Once`-type mapping -- expected behavior, not a bug | Fix 6 |
| Team wants this to fully replace Hybrid Azure AD Join today | Preview status risk conversation needed | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
AD computer object appears as a device in Microsoft Entra ID via Cloud Sync
        |
        v
Provisioning agent >= 1.1.1107 installed and healthy
        |
        v
SCP configured in THAT computer's AD forest, correct azureADName + azureADId
        |
        v
"Enable device sync" toggle set on the AD-to-Entra Cloud Sync configuration's
Basics properties (off by default -- not implied by agent/SCP readiness alone)
        |
        v
Computer object is inside the Cloud Sync configuration's directory/OU scope
        |
        v
AD2AADDeviceSync job cycle runs (or Provision on Demand is used) --
fixed, non-customizable attribute mapping applied
        |
        v
Entra device object created, DeviceTrustType = ServerAd -->
eligible for Microsoft Entra hybrid join
```

Preview feature -- no GA SLA. This is layered ON TOP of an already-working AD-to-Entra
Cloud Sync configuration; if user/group sync itself is broken, fix that first (see
`CloudSync-B.md`) before troubleshooting device sync specifically.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the provisioning agent meets the 1.1.1107 floor.** Nothing else matters until this is true.
2. **Confirm the SCP exists and is correct in the specific forest the affected computer lives in.** SCP is per-forest -- a multi-forest environment can have it right in one forest and wrong/missing in another.
3. **Confirm the toggle is actually enabled** on the Cloud Sync configuration's Basics properties -- this is a manual, off-by-default step that's easy to assume was done.
4. **Confirm the specific computer is in scope** (the same directory/OU scope as the rest of that Cloud Sync configuration).
5. **Force a single-device test via Provision on Demand** rather than waiting for/assuming the next scheduled cycle.
6. **If a device disappeared, identify which of the three deletion triggers caused it** before assuming Cloud Sync will auto-recover it.

---
## Common Fix Paths

<details><summary>Fix 1 -- Provisioning agent below version 1.1.1107</summary>

```powershell
# Confirm current version, then download and install the latest agent from the
# Microsoft Entra admin center (Entra Connect > Cloud sync > Agents)
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent" -ErrorAction SilentlyContinue).Version
```
There's no in-place config workaround for this -- the `AD2AADDeviceSync` job template simply isn't offered below the version floor. Upgrade the agent, then re-check the Basics properties for the Device sync toggle.

**Rollback:** none needed -- agent upgrades are forward-only and don't remove existing user/group sync functionality.
</details>

<details><summary>Fix 2 -- SCP missing, empty, or pointing at the wrong tenant</summary>

Requires temporary Enterprise Admins access in the affected forest (use just-in-time access, not a standing account).

```powershell
# Read existing values FIRST and record them before making any change
$configCN = ([ADSI]"LDAP://RootDSE").configurationNamingContext
([ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configCN").keywords

# Then run Microsoft's ConfigureSCP.ps1 (Enterprise Admins) with the correct values:
# .\ConfigureSCP.ps1 -Domain <verified-domain> -TenantId <tenant-guid>
```
The script **clears and replaces** existing `keywords` -- this is destructive to whatever was there before, which is why recording the pre-existing values first matters.

**Rollback:** re-run `ConfigureSCP.ps1` with the originally-recorded `Domain`/`TenantId` values to restore the prior state.
</details>

<details><summary>Fix 3 -- Device sync toggle is Disabled</summary>

Portal only: Cloud Sync configuration -> **Properties** -> **Basics** -> edit icon -> **Enable device sync** -> **Apply**. Confirm it actually saved by reopening Properties afterward -- a common miss is closing the edit panel without clicking Apply.

**Rollback:** repeat the same steps to toggle back to Disabled. Existing already-synced device objects are not automatically removed by disabling the toggle.
</details>

<details><summary>Fix 4 -- Specific computer(s) outside the Cloud Sync configuration's scope</summary>

Check the AD-to-Entra Cloud Sync configuration's directory/OU scope in the portal and confirm the affected computer's OU is included. This is the same scoping mechanism that already governs user/group sync for that configuration -- device sync doesn't have a separate scope setting.

**Rollback:** n/a -- this is a scope correction, not a destructive change.
</details>

<details><summary>Fix 5 -- Device disappeared and isn't coming back</summary>

```powershell
# Confirm the AD computer object still exists and check when it last changed
Get-ADComputer -Identity "<computer-name>" -Properties whenChanged
```
If the AD object is unchanged, Cloud Sync has no trigger to re-provision it automatically. Either:
- Restore from **Entra ID > Devices > Deleted devices** in the portal, or
- Use **Provision on Demand** (Cloud Sync configuration -> Device tab) for an immediate re-sync, or
- Make a trivial attribute change on the AD computer object to force re-evaluation on the next cycle.

**Rollback:** none -- this is a recovery action.
</details>

<details><summary>Fix 6 -- RegisteredOwnerReference looks stale after a device reassignment</summary>

This is expected: the `RegisteredOwnerReference` attribute uses a `Once`-type mapping and is only ever set on the first sync of that computer object. It will not update automatically after `mS-DS-CreatorSID` changes later in AD.

**Rollback:** n/a -- not a bug. Correct the value manually in Entra ID if the discrepancy matters operationally; it won't be overwritten again by future syncs either way.
</details>

<details><summary>Fix 7 -- Team wants to fully replace Hybrid Azure AD Join / Cloud Kerberos Trust planning with this</summary>

Don't. This is a **preview** feature: no GA SLA, subject to change, one-directional only (no device writeback equivalent). For a production-critical hybrid-join dependency, Cloud Kerberos Trust (generally available) remains the recommended path. Position device sync as a pilot-now / plan-for-GA capability, not a wholesale replacement for an existing device-join strategy today.

**Rollback:** n/a -- this is a recommendation/expectation-setting conversation, not a technical change.
</details>

---
## Escalation Evidence

```
Tenant/customer name: ____________________
Affected forest(s): ____________________
Provisioning agent version: ____________________
SCP keywords present (Y/N) and values (domain / tenant GUID): ____________________
Device sync toggle state (Enabled/Disabled) on the Cloud Sync configuration: ____________________
Affected computer name(s) and current AD OU: ____________________
Provision on Demand attempted (Y/N) and result: ____________________
Existing ServerAd-trust device count (Get-MgDevice filter): ____________________
Deletion trigger identified, if applicable (AD delete / dsregcmd leave / manual portal delete): ____________________
Specific blocker: ____________________
```

---
## 🎓 Learning Pointers

- **Check the provisioning agent version before anything else.** Below 1.1.1107, there is no device sync job to troubleshoot -- this single check saves the most time on a fresh ticket. [Configure device sync with Microsoft Entra Cloud Sync (preview)](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/device-sync)
- **SCP is per-forest, and the config script overwrites existing keywords.** Always read the current SCP values before running `ConfigureSCP.ps1` in any forest -- this is the single most common irreversible-feeling mistake in this workflow (though it's recoverable if you recorded the prior values).
- **The Device sync toggle is a genuine off-by-default setting, not implied by prerequisites.** A tenant can have a current agent and a correct SCP and still have nothing sync, simply because Basics -> Device sync was never explicitly enabled.
- **Don't treat a missing device as a Cloud Sync bug without checking the deletion trigger first.** Three different mechanisms (AD delete, `dsregcmd /leave`, manual portal delete) can remove a device, and only one of them is something Cloud Sync auto-recovers from on its own.
- **This is preview, not GA -- say so explicitly in any customer-facing recommendation.** Cloud Kerberos Trust remains the safer default for a production-critical Hybrid Azure AD Join dependency until this reaches general availability.
