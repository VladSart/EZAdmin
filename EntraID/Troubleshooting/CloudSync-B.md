# Entra Cloud Sync — Hotfix Runbook (Mode B: Ops)
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

Run these on the server(s) with the Microsoft Entra provisioning agent installed:

```powershell
# 1. Are the two required services running?
Get-Service "AADConnectProvisioningAgent","AADConnectProvisioningAgentUpdater" |
    Select-Object DisplayName, Status, StartType

# 2. Install AADCloudSyncTools if not already present, then check agent + job health from the cloud side
Install-Module -Name AADCloudSyncTools -Scope AllUsers -Force
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools     # prompts for Hybrid Identity Administrator sign-in
Get-AADCloudSyncToolsAgent    # shows every registered agent + health status
Get-AADCloudSyncToolsJob      # shows every sync job + quarantine status

# 3. Check the trace logs on the agent server for recent errors
Get-ChildItem "C:\ProgramData\Microsoft\Azure AD Connect Provisioning Agent\Trace" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5

# 4. Quick outbound connectivity check to the two domains the agent lives on
Test-NetConnection -ComputerName "login.windows.net" -Port 443
Test-NetConnection -ComputerName "<yourtenant>.servicebus.windows.net" -Port 443

# 5. Force an immediate resync of a specific job (replace with your job ID from step 2)
Invoke-AADCloudSyncToolsJob -JobId "<jobId>" -Restart
```

| What you see | What it means |
|---|---|
| `AADConnectProvisioningAgent` service Stopped | Agent isn't running locally — nothing will sync until it's started (Fix 1) |
| Agent shows in portal but status is grey/not "Active" | Agent isn't reaching Azure Service Bus — usually a firewall/proxy block (Fix 2) |
| Job status = **Quarantined** | Consistent failures against the target (bad credential, or AD/Entra ID rejecting most calls) — see Fix 3 |
| `HybridIdentityServiceNoActiveAgents` in job error | No agent is listening on the Service Bus endpoint for this domain (Fix 2) |
| `AzureActiveDirectoryInvalidCredential` / `AzureActiveDirectoryExpiredCredentials` | The `ADToAADSyncServiceAccount` service principal is missing or its token expired (Fix 4) |
| `AzureDirectoryServiceAuthorizationFailed` | The **Microsoft Entra AD Synchronization Service** service principal is missing from the tenant (Fix 5) |
| Object exists in AD but never appears in Entra ID | Scoping filter is excluding it, or it's still in the default-excluded set (Fix 6) |
| Export blocked with an "accidental deletion" error while bulk-deleting/moving objects out of scope | Accidental Deletion Prevention threshold tripped (Fix 7) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Domain-joined agent server (Server 2016/2019/2022 — NOT Server 2025 unless KB5070773+ applied)
  └── Microsoft Entra Provisioning Agent service running, using the gMSA (domain\provAgentgMSA$)
        └── TLS 1.2 enabled + outbound 443 (and fallback 8080 status heartbeat) reachable
              └── Persistent connection to Azure Service Bus (*.servicebus.windows.net)
                    └── Agent registered + shows "Active" in Entra admin center (Entra Connect > Cloud sync)
                          └── Cloud-side provisioning service dispatches SCIM requests every 2 minutes
                                └── Agent queries AD (LDAP) using gMSA permissions, applies scoping + attribute mapping
                                      └── Response sent back over Service Bus to the provisioning service
                                            └── Provisioning service commits the change to Microsoft Entra ID
                                                  └── Watermark advances (next delta cycle picks up from here)
```

Key failure points:
- Agent service stopped locally, or never started due to a GPO blocking the NT service logon right
- Agent not on Server 2025 support list (or missing the Oct 2025 KB) — causes sync problems, not an install failure
- Firewall/proxy blocking outbound 443/`*.servicebus.windows.net`/`*.msappproxy.net` — agent silently stops appearing "Active"
- gMSA credential broken (password rotation failed, or account deleted) — job goes into quarantine
- `ADToAADSyncServiceAccount` (cloud-side sync service account) or the **Microsoft Entra AD Synchronization Service** service principal deleted/expired
- Scoping rule (OU or attribute filter) excluding the object, or it matches a default exclusion (`IsCriticalSystemObject = TRUE`, replication-victim objects)
- Accidental Deletion Prevention threshold hit during a large scope change or forest decommission

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the agent is installed, running, and registered**
```powershell
Get-Service "AADConnectProvisioningAgent","AADConnectProvisioningAgentUpdater"
```
Expected: both `Running` / `Automatic`.
Bad: Stopped → try `Start-Service AADConnectProvisioningAgent`. If it fails with *"failed to start... insufficient privileges"*, this is almost always a GPO blocking permissions on the `NT SERVICE\AADConnectProvisioningAgent` logon account (Fix 1).

**Step 2 — Confirm the portal sees the agent as healthy**
Entra admin center → **Entra ID > Entra Connect > Cloud sync** → confirm the agent shows a green **Active** status.
Bad: grey/inactive → the agent isn't reaching the Service Bus endpoint (Fix 2).

**Step 3 — Check job quarantine state**
```powershell
Get-AADCloudSyncToolsJob | Select-Object Id, Status, Schema
```
Expected: `Status: Active`/`Healthy`.
Bad: `Quarantined` → check the error code first with `Get-AADCloudSyncToolsLogs` or the portal's job status pane before clearing it — clearing without knowing the cause just re-quarantines a few minutes later (Fix 3).

**Step 4 — Verify outbound network path**
```powershell
Test-NetConnection -ComputerName "login.windows.net" -Port 443
Test-NetConnection -ComputerName "<tenant>.servicebus.windows.net" -Port 443
```
Expected: `TcpTestSucceeded: True` on both.
Bad: `False` → firewall/proxy is blocking the agent; see Fix 2 for the full URL/port list.

**Step 5 — Pull the provisioning logs for a specific object**
Entra admin center → **Entra Connect > Cloud sync** → select the job → **Logs** → search by the AD object's `ObjectGuid`.
Look for a `Skipped` status with only a Source ID and no target — that means a scoping rule filtered it out (Fix 6), not a sync failure.

**Step 6 — Gather full diagnostics before escalating**
```powershell
Export-AADCloudSyncToolsLogs -TracingDurationMins 5
```
This captures verbose agent traces plus current state into a zip in your Documents folder — attach it to any support case.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent service won't start ("insufficient privileges")</summary>

**Cause:** A Group Policy applied to the agent server is stripping the logon-as-a-service right from the local NT service account the installer created (`NT SERVICE\AADConnectProvisioningAgent`).

```powershell
# Confirm the service and its logon account
Get-CimInstance Win32_Service -Filter "Name='AADConnectProvisioningAgent'" |
    Select-Object Name, StartName, State

# Temporary workaround: run the service under a domain admin to confirm this is the cause
# Services.msc → Microsoft Entra Provisioning Agent → Log On tab → This account → <domain admin> → OK → restart service
Restart-Service AADConnectProvisioningAgent
```

If it starts under a domain admin account, the real fix is to find and exclude this server from the GPO that assigns "Log on as a service" rights, then revert to the NT service account (or the gMSA, if configured that way) — don't leave it running as a standing domain admin.

**Rollback note:** Reverting the logon account back to the original service account is safe; just restart the service afterward.

</details>

<details><summary>Fix 2 — Agent shows inactive / not reaching the cloud service</summary>

**Cause:** Outbound firewall/proxy blocking one of the required endpoints, or the agent process crashed without restarting.

Required outbound access:

| Port | Purpose |
|---|---|
| 443 | All communication with the provisioning service and Service Bus |
| 80 | CRL/certificate revocation checks |
| 8080 (optional) | Status heartbeat every 10 min, used only if 443 is unavailable |

Required URL suffixes: `*.msappproxy.net`, `*.servicebus.windows.net`, `*.microsoftonline.com`, `*.microsoftonline-p.com`, `*.msauth.net`, `*.msftauth.net`, `login.windows.net`, `enterpriseregistration.windows.net`, `management.azure.com`, `ctldl.windowsupdate.com`.

```powershell
foreach ($ep in @("login.windows.net","management.azure.com","ctldl.windowsupdate.com")) {
    Test-NetConnection -ComputerName $ep -Port 443 | Select-Object ComputerName, TcpTestSucceeded
}

# Restart the agent service after fixing firewall/proxy rules
Restart-Service AADConnectProvisioningAgent
```

If a proxy is required, configure it in the agent's own config file (not just the system-wide proxy):
```
C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\AADConnectProvisioningAgent.exe.config
```
Add before the closing `</configuration>` tag:
```xml
<system.net>
    <defaultProxy enabled="true" useDefaultCredentials="true">
        <proxy usesystemdefault="true" proxyaddress="http://[proxy-server]:[proxy-port]" bypassonlocal="true" />
    </defaultProxy>
</system.net>
```

**Rollback note:** Config file edit only affects the agent process — revert the added block and restart the service to undo.

</details>

<details><summary>Fix 3 — Job in quarantine</summary>

**Cause:** Cloud sync auto-quarantines a job once most/all calls against the target consistently fail (bad credential, target system down, permission revoked).

```powershell
# See the specific error code/message behind the quarantine first
Get-AADCloudSyncToolsJob | Select-Object Id, Status
# Then check the job's status pane in the portal, or:
Get-AADCloudSyncToolsLogs -JobId "<jobId>"
```

Once the underlying cause (credential, permission, connectivity) is fixed, clear the quarantine one of two ways:

```powershell
# Option A — portal: right-click the job status → Clear quarantine
# Option B — Graph, giving you granular control over what resets
POST /servicePrincipals/{id}/synchronization/jobs/{jobId}/restart
# body can selectively clear: Escrows, Quarantine, Watermarks
```

⚠️ Clearing quarantine without fixing the root cause just re-quarantines the job after the escrow counter fills again — always confirm the error code first.

**Rollback note:** Clearing quarantine/restarting is non-destructive; worst case is a longer resync if you also clear watermarks.

</details>

<details><summary>Fix 4 — Sync service account credential invalid or expired</summary>

**Cause:** The cloud-side `ADToAADSyncServiceAccount` was deleted or its token expired.

```powershell
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools
Repair-AADCloudSyncToolsAccount
```

Confirms and repairs the service account automatically. Re-check job status a few minutes after running it.

**Rollback note:** Repair-only operation, no destructive side effects.

</details>

<details><summary>Fix 5 — AzureDirectoryServiceAuthorizationFailed (missing service principal)</summary>

**Cause:** The tenant is missing the **Microsoft Entra AD Synchronization Service** service principal entirely.

```powershell
# Confirm it's actually missing
Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra AD Synchronization Service'"
```

If nothing returns, trigger Microsoft Entra ID to recreate it:
```powershell
# Graph PATCH — re-enabling a setting that's already on forces service principal recreation
Update-MgOrganization -OrganizationId <tenantId> -OnPremisesSyncEnabled:$true
```

Re-run the `Get-MgServicePrincipal` query — it should now return a result. Allow up to 24 hours for authorization errors to fully clear; if they persist past that, escalate to Microsoft support.

**Rollback note:** This only re-provisions a missing system service principal — no risk to existing sync configuration.

</details>

<details><summary>Fix 6 — Object not appearing in Entra ID (scoping exclusion)</summary>

**Cause:** Default scope exclusions, or an OU/attribute scoping filter configured on the job, is filtering the object out — this shows as a `Skipped` status (Source ID only, no target) in the provisioning logs, not an error.

Objects excluded by default:
- Users/groups/contacts with `IsCriticalSystemObject = TRUE` (most AD built-ins)
- Replication-victim objects

```powershell
# Confirm the object isn't a critical system object
Get-ADUser -Identity "<sam-account-name>" -Properties IsCriticalSystemObject |
    Select-Object Name, IsCriticalSystemObject, DistinguishedName
```

If it's a real scoping-filter exclusion, review/adjust the job's OU or attribute scoping filter in **Entra Connect > Cloud sync > [job] > Configure scoping filters**, then trigger a delta run.

⚠️ Known limitation: renaming an OU or group that's already in scope does **not** trigger delta sync to notice the change — the job stays healthy and shows no error, but membership silently stops updating. If a scope change doesn't seem to take effect, re-save the scoping filter to force re-evaluation.

**Rollback note:** Scoping filter changes only affect what syncs going forward — no data is deleted by narrowing scope, existing synced objects remain in Entra ID until explicitly removed from scope.

</details>

<details><summary>Fix 7 — Blocked by Accidental Deletion Prevention during a bulk scope change</summary>

**Cause:** You're moving/deleting many objects out of scope at once (forest decommission, OU restructure, or migrating fully off Entra Connect onto Cloud Sync) and tripped the accidental-deletion threshold.

```powershell
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools
Disable-AADCloudSyncToolsDirSyncAccidentalDeletionPrevention -TenantId "<tenantId>"
```

Run this **only after confirming** the pending deletions are expected. The next provisioning cycle exports the blocked deletions.

**Rollback note:** Re-enable protection after the bulk operation completes if this was a one-time event — check the corresponding `Enable-*` cmdlet in the AADCloudSyncTools module reference.

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Entra Cloud Sync

Agent server name(s): ______________________
Agent version: _____________________________
Tenant ID: __________________________________
AD domain(s) in scope: ______________________

Agent service status (local): (Running / Stopped)
Agent status (portal, Entra Connect > Cloud sync): (Active / Inactive)
Job status: (Active / Quarantined — error code: _______)

Outbound connectivity:
  - login.windows.net :443: ___
  - <tenant>.servicebus.windows.net :443: ___

Recent error code(s) from job/provisioning logs: ___________
Affected object (AD ObjectGuid): ____________________
Scoping filter in effect (OU / attribute / none): ___________

Steps already attempted:
[ ] Confirmed agent service running locally
[ ] Confirmed agent shows Active in portal
[ ] Checked/cleared quarantine
[ ] Ran Repair-AADCloudSyncToolsAccount
[ ] Verified outbound network path (443/80/8080, required URLs)
[ ] Checked provisioning logs by ObjectGuid
[ ] Exported full diagnostics via Export-AADCloudSyncToolsLogs

Diagnostics zip attached: (Y/N) ______________
```

---
## 🎓 Learning Pointers

- **The agent is a bridge, not a sync engine.** All orchestration, scheduling, and configuration lives in the cloud provisioning service — the on-prem agent just relays SCIM requests over a persistent Service Bus connection. This is why cloud sync has no local SQL database and no "Synchronization Service Manager" GUI the way Entra Connect Sync does. [What is Microsoft Entra Cloud sync?](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/what-is-cloud-sync)
- **Windows Server 2025 is not yet a supported host for the provisioning agent** unless the October 20, 2025 KB5070773 update (or later) is installed — without it, Server 2025 hosts can hit silent sync problems that look like any other agent issue. Check this first if the agent server was recently upgraded. [Cloud sync prerequisites](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-prerequisites)
- **Renamed OUs/groups don't trigger re-evaluation — and don't quarantine either.** This is one of the few failure modes that produces zero error signal. If membership "just stops updating" after an AD reorg, suspect a rename inside an already-in-scope OU or group before anything else. [Known limitations](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-prerequisites#known-limitations)
- **Quarantine has three independently-resettable parts:** escrows, quarantine state, and watermarks. Clearing all three via the portal button is usually right, but the Graph restart API lets you reset just the quarantine flag while preserving watermarks — useful when you don't want to force a full resync. [Troubleshooting: resolve a quarantine](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-troubleshoot)
- **Deploy 3 agents for HA, not 1.** Unlike Entra Connect Sync's single-server design, Cloud Sync actively supports multiple agents per domain with automatic failover — Microsoft's own recommendation is 3 active agents. A single-agent Cloud Sync deployment still has the exact single-point-of-failure problem Cloud Sync was built to remove.
- **Group provisioning to AD DS (the reverse direction) has its own scale ceiling.** "All security groups" scoping without an attribute filter is unsupported outright; past 200K users/40K groups/1M memberships in a tenant, "Selected security groups" mode (capped at 10K groups) is the only supported path. Picking the wrong scoping mode at the wrong tenant size is a common cause of slow or failing delta cycles. [Prerequisites — scale limits](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-prerequisites#scale-limits-for-provisioning-groups-to-active-directory)
