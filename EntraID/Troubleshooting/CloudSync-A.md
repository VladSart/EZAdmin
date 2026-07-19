# Entra Cloud Sync — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Entra Cloud Sync — the lightweight, agent-based provisioning model (Entra ID > Entra Connect > Cloud sync)
- Provisioning agent install/health, gMSA-based service account, multi-agent high availability
- User/group/contact sync from AD to Entra ID, disconnected multi-forest scenarios
- Group provisioning from Entra ID back to AD DS (the reverse direction, GPAD)
- Password writeback and password hash sync under Cloud Sync
- Object scoping, quarantine handling, and the AADCloudSyncTools PowerShell module

**Out of scope:**
- Entra Connect Sync (the legacy on-prem sync-engine model — see `Connect-Sync-A.md`/`Connect-Sync-B.md`)
- HR-driven provisioning from Workday/SuccessFactors (separate provisioning app, different agent)
- Entra Connect Health monitoring/alerting configuration
- AD FS federation (see `ActiveDirectory/Troubleshooting/ADFS/`)

**Assumptions:**
- You have console/RDP access to at least one provisioning agent server
- You have Domain Admin or Enterprise Admin rights for initial gMSA creation, and Hybrid Identity Administrator in Entra ID
- The agent server(s) run Windows Server 2016, 2019, or 2022 (see the Server 2025 caveat below)
- The AADCloudSyncTools PowerShell module can be installed on at least one management workstation

---
## How It Works

<details><summary>Full architecture — provisioning agent and cloud orchestration internals</summary>

### Two-Component Model

Cloud Sync splits responsibility differently than Entra Connect Sync. Instead of one on-prem sync engine doing import → sync → export against a local database, the work is split across a thin on-prem relay and a cloud orchestrator:

```
On-Prem Active Directory
        │
        │  LDAP query (using gMSA: domain\provAgentgMSA$)
        ▼
Microsoft Entra Provisioning Agent (on-prem, per-domain)
  [Lightweight relay — same underlying tech as Application Proxy / PTA connectors]
        │
        │  Persistent outbound connection, listens for SCIM requests
        ▼
Azure Service Bus (*.servicebus.windows.net)
        │
        ▼
Microsoft Entra Provisioning Service (cloud, fully managed by Microsoft)
  [Stores ALL configuration: scoping rules, attribute mappings, schedule]
  [Scheduler tick: every 2 minutes]
        │
        │  Commits processed changes
        ▼
Microsoft Entra ID (target directory)
```

**Key architectural facts:**

1. **No local database.** Unlike Entra Connect Sync's SQL/LocalDB-backed Connector Space and Metaverse, Cloud Sync keeps no persistent identity store on-prem. The agent is stateless — it relays SCIM requests and returns AD query results. All watermarks, scoping configuration, and job state live in the cloud provisioning service.

2. **SCIM as the wire protocol.** The cloud provisioning service issues System for Cross-domain Identity Management (SCIM) requests over the Service Bus channel. The agent translates these into LDAP queries against AD, then serializes results back into SCIM responses. This is the same SCIM plumbing used for third-party app provisioning — Cloud Sync is really "provisioning from AD" using the general-purpose Entra provisioning engine.

3. **The agent reuses Application Proxy/PTA connector technology.** This is why the required firewall rules (`*.msappproxy.net`, `*.servicebus.windows.net`) look identical to Application Proxy and Pass-through Authentication — under the hood, it's the same outbound-only, no-inbound-firewall-rule connector model.

4. **Multi-agent, active-active, no primary/standby distinction.** Entra Connect Sync has an explicit staging-mode concept (one active server, others passive). Cloud Sync has no such concept — multiple agents for the same domain are all active simultaneously, and the cloud service load-balances and fails over between them transparently. Microsoft's own recommendation is **3 active agents** per domain for HA.

5. **Disconnected forest support is native, not bolted on.** Because each agent is just a relay tied to whatever domain it's joined to, and all orchestration lives centrally in the cloud, multiple forests that have no trust relationship or network path to each other can each run their own agent(s) and synchronize into the *same* Entra tenant — something Entra Connect Sync cannot do without complex multi-Connect-server topologies.

### Group Managed Service Account (gMSA)

Cloud Sync authenticates to AD using a gMSA — `domain\provAgentgMSA$` by default — created during agent installation (requires Domain/Enterprise Admin the first time). A gMSA:
- Has its password rotated automatically by AD (no service account password expiry failure mode)
- Can be used simultaneously across multiple agent servers (a prerequisite for multi-agent HA)
- Requires the forest's AD schema to be at Windows Server 2012 level or later, and at least one 2012+ DC

Default gMSA permissions (auto-applied only on **clean install** — upgrades from non-gMSA versions require manually running `Set-AADCloudSyncPermissions`):

| Access | Applies to |
|---|---|
| Read all properties | Descendant Device, InetOrgPerson, Computer, foreignSecurityPrincipal, User, Contact objects |
| Full control | Descendant Group objects |
| Create/delete User objects | This object and all descendant objects |

### Provisioning Cycle and Quarantine

The cloud provisioning service runs each job on a scheduler (2-minute tick for delta). Every call the job makes against the target system (Entra ID, or AD DS for reverse group provisioning) is tracked. If most/all calls **consistently fail** — bad credential, permission revoked, target down — the job accumulates "escrows" until it crosses a threshold and is placed into **quarantine**. Quarantine has three independently resettable components:
- **Escrows** — the failure counter that accrues toward the quarantine threshold
- **Quarantine flag** — the actual blocked state
- **Watermarks** — the delta-sync bookmark tracking what's already been processed

This granularity (exposed via the Graph `synchronizationJob.restart` API) lets you clear just the quarantine flag without forcing a full resync by also clearing watermarks.

### Group Provisioning to Active Directory (reverse direction)

Cloud Sync also supports the inverse flow: provisioning **cloud-created security groups from Entra ID into AD DS** (GPAD), for governing on-prem applications that still read group membership from AD. This uses the same agent and provisioning-service model, but:
- Runs on a fixed 20-minute schedule (not the 2-minute delta tick used for AD→Entra)
- Requires the agent to reach domain controllers directly on **TCP/389 (LDAP)** and **TCP/3268 (Global Catalog)** — the GC lookup filters out invalid membership references
- Only supports groups containing on-premises-synced users or other cloud-created security groups (not arbitrary cloud-only users)
- Requires the on-prem user's `objectGUID` to be mapped to the cloud user's `onPremisesObjectIdentifier` attribute (set by either sync client)
- Global tenants only — not supported for B2C tenants

</details>

---
## Dependency Stack

```
Domain-joined agent server (Server 2016/2019/2022 — 2025 unsupported pre-KB5070773)
  └── .NET Framework 4.7.1+, TLS 1.2 enabled, PowerShell execution policy Undefined/RemoteSigned
        └── Windows Credential Manager service (VaultSvc) — must NOT be disabled (blocks agent install)
              └── gMSA (domain\provAgentgMSA$) created + permissioned in AD
                    └── Microsoft Entra Provisioning Agent service (running as the gMSA)
                          └── Microsoft Entra Connect Agent Updater service (auto-patches the agent)
                                └── Outbound 443 (+ fallback 8080 status heartbeat, + 80 for CRL) reachable
                                      └── Persistent connection to Azure Service Bus established
                                            └── Agent registered + "Active" in Entra admin center
                                                  └── Provisioning service dispatches SCIM requests (2-min tick)
                                                        └── Agent's gMSA queries AD (LDAP) within scoping rules
                                                              └── Attribute mapping + scoping filter applied
                                                                    └── Response committed to Microsoft Entra ID
                                                                          └── Watermark advances → next delta cycle
```

**Reverse flow (Group Provisioning to AD DS) has its own extra dependency branch:**

```
Agent reachable to DCs on TCP/389 (LDAP) + TCP/3268 (Global Catalog)
  └── Provisioning agent build >= 1.1.1373.0
        └── msDS-ExternalDirectoryObjectId schema attribute present (Server 2016+ schema)
              └── (if also running Entra Connect Sync for user membership) build >= 2.2.8.0
                    └── onPremisesObjectIdentifier (cloud) mapped to objectGUID (AD) per user
                          └── Group provisioning job runs on its own 20-minute schedule
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Agent shows inactive/grey in portal | Firewall/proxy blocking 443 to `*.servicebus.windows.net`/`*.msappproxy.net`, or the local service is stopped | `Get-Service AADConnectProvisioningAgent`; `Test-NetConnection` to Service Bus endpoint |
| "Service failed to start — insufficient privileges" | GPO stripping "log on as a service" right from the NT service account | Check applied GPOs on the agent server; temporarily test under a domain admin |
| Job status = Quarantined | Consistent failures against target — bad gMSA permissions, deleted service principal, or AD DS unreachable (reverse flow) | `Get-AADCloudSyncToolsJob`; check the specific error code before clearing |
| `HybridIdentityServiceNoActiveAgents` | No agent listening on the Service Bus endpoint for this domain — agent down or firewalled | Confirm agent service running + Service Bus reachability |
| `HybridIdentityServiceNoAgentsAssigned` | Agent(s) removed/unregistered entirely — portal shows zero agents for the domain | Re-install and re-register the agent |
| `AzureActiveDirectoryInvalidCredential` / `...ExpiredCredentials` | Cloud-side `ADToAADSyncServiceAccount` deleted or its token expired | `Repair-AADCloudSyncToolsAccount` |
| `AzureDirectoryServiceAuthorizationFailed` | Tenant missing the **Microsoft Entra AD Synchronization Service** service principal | `Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra AD Synchronization Service'"` |
| `HybridSynchronizationActiveDirectoryUnexpectedDuplicateEntriesFound` | Two AD groups share the same `msDS-ExternalDirectoryObjectId` value (usually from a botched GPAD setup or object restore) | Query AD for duplicate `Group_*` values in that attribute |
| Object never appears in Entra ID, no error shown | Default scope exclusion (`IsCriticalSystemObject`) or a configured OU/attribute scoping filter | Provisioning logs, filter by AD `ObjectGuid`, look for `Skipped` |
| Membership silently stops updating after an AD reorg | OU or group renamed while already in scope — delta sync doesn't detect the rename and doesn't quarantine either | Compare current AD OU/group names against the job's scoping configuration |
| Export blocked citing accidental deletion prevention | Bulk deletion/move out of scope tripped the threshold — can be triggered by either Connect or Cloud Sync's own instance of this feature if both export to the same tenant | `Disable-AADCloudSyncToolsDirSyncAccidentalDeletionPrevention` (after confirming deletions are expected) |
| Sync agent registration times out / certificate errors | Agent can't reach the hybrid identity service — usually an outbound proxy that isn't configured in the agent's own config file | Edit `AADConnectProvisioningAgent.exe.config`, add `<defaultProxy>` block |
| Agent install fails with a PowerShell/security error | Local execution policy is `Unrestricted` (Cloud Sync requires `Undefined` or `RemoteSigned`) | `Get-ExecutionPolicy -List` |
| Password writeback silently fails for some users | Inheritance disabled on the user object, or gMSA permission propagation (up to ~1 hr) hasn't completed | Check AD inheritance flag; re-test after permission propagation window |
| GPAD job slow / erroring on large tenants | Wrong scoping mode for tenant size — "All security groups" without an attribute filter is unsupported outright | Compare tenant user/group/membership counts against the documented scale limits |
| Recently upgraded agent server to Windows Server 2025 | Known Cloud Sync compatibility issue on Server 2025 without the Oct 2025 cumulative update | Confirm KB5070773 (or later) is installed, then reboot |

---
## Validation Steps

**Step 1 — Confirm both agent services are installed and running**
```powershell
Get-Service "AADConnectProvisioningAgent","AADConnectProvisioningAgentUpdater" |
    Select-Object DisplayName, Status, StartType
```
Expected: both `Running`/`Automatic`.

**Step 2 — Confirm the agent's OS is supported**
```powershell
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "Caption: $($os.Caption)  Build: $($os.BuildNumber)"
# If this is Server 2025 (Build 26100+), confirm KB5070773 or later is installed:
Get-HotFix -Id "KB5070773" -ErrorAction SilentlyContinue
```
Bad: Server 2025 without that KB — known sync-breaking issue.

**Step 3 — Confirm TLS 1.2 and .NET prerequisites**
```powershell
$tlsPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
)
foreach ($p in $tlsPaths) {
    if (Test-Path $p) { (Get-ItemProperty $p).Enabled } else { "NOT CONFIGURED: $p" }
}
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue |
    Select-Object Release, Version
```
Expected: TLS 1.2 `Enabled = 1` on both paths; .NET release >= 461308 (4.7.1).

**Step 4 — Confirm the gMSA and its AD permissions**
```powershell
Get-ADServiceAccount -Filter "Name -like 'provAgentgMSA*'" -Properties PrincipalsAllowedToRetrieveManagedPassword
```
Expected: returns the gMSA object, with the agent server(s) listed as allowed to retrieve the password.

**Step 5 — Confirm agent registration and health in the portal**
Entra admin center → **Entra ID > Entra Connect > Cloud sync** → verify every expected agent shows **Active** (green).
Bad: missing agent, or grey/inactive status.

**Step 6 — Confirm job health via AADCloudSyncTools**
```powershell
Install-Module AADCloudSyncTools -Scope AllUsers -Force
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools
Get-AADCloudSyncToolsAgent
Get-AADCloudSyncToolsJob
```
Expected: agents listed as healthy; jobs `Status: Active`, not `Quarantined`.

**Step 7 — Validate outbound network path**
```powershell
$endpoints = @(
    @{ Name = "login.windows.net"; Port = 443 },
    @{ Name = "management.azure.com"; Port = 443 },
    @{ Name = "ctldl.windowsupdate.com"; Port = 80 }
)
foreach ($e in $endpoints) {
    $r = Test-NetConnection -ComputerName $e.Name -Port $e.Port -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $e.Name; Port = $e.Port; Reachable = $r.TcpTestSucceeded }
} | Format-Table -AutoSize
```
Expected: all `True`.

**Step 8 — For GPAD (reverse) deployments, confirm LDAP/GC reachability**
```powershell
$dc = (Get-ADDomainController -Discover).HostName
Test-NetConnection -ComputerName $dc -Port 389
Test-NetConnection -ComputerName $dc -Port 3268
```
Expected: both `True`.

**Step 9 — Trigger a manual restart/resync of a specific job and confirm progress**
```powershell
$job = Get-AADCloudSyncToolsJob | Select-Object -First 1
Invoke-AADCloudSyncToolsJob -JobId $job.Id -Restart
Start-Sleep -Seconds 150
Get-AADCloudSyncToolsJob -JobId $job.Id
```
Expected: status returns to `Active` with an updated last-run timestamp.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Agent Install / Service Layer

1. Confirm domain-join and OS version (`Get-CimInstance Win32_ComputerSystem`, `Win32_OperatingSystem`)
2. Confirm VaultSvc (Credential Manager) is not disabled — a disabled VaultSvc silently blocks agent installation: `Get-Service VaultSvc`
3. Confirm PowerShell execution policy is `Undefined` or `RemoteSigned` on both machine and user scope (`Unrestricted` breaks the installer's registration scripts): `Get-ExecutionPolicy -List`
4. Confirm the gMSA exists and this server is authorized to retrieve its password
5. If the service won't start, check for a GPO stripping the "Log on as a service" right from `NT SERVICE\AADConnectProvisioningAgent`

### Phase 2 — Registration / Network Layer

1. Confirm outbound 443/80 (and optional 8080) reachability to the full required URL list
2. If a corporate proxy is in the path, confirm it's configured in the agent's own `.exe.config` file — the system-wide proxy setting alone is not always sufficient
3. Confirm the proxy supports HTTP 1.1 and chunked encoding
4. Check trace logs for registration failures: `C:\ProgramData\Microsoft\Azure AD Connect Provisioning Agent\Trace`
5. If registration times out repeatedly, capture full diagnostics: `Export-AADCloudSyncToolsLogs`

### Phase 3 — Job Configuration / Scoping

1. Confirm the job's scoping mode (OU-based or attribute-based) matches intent
2. Remember the 4 MB configuration size ceiling (~50 OUs/security groups including metadata) — large environments may need multiple jobs with disjoint scopes
3. Confirm nested OUs are being used correctly — a single OU with 130 nested children counts as one scoping entry; 60 separate top-level OUs in one job does not fit the same budget
4. For group-based scoping approaching 50,000 members, know that delta sync does not support scope filtering above this size — split membership or restructure

### Phase 4 — Quarantine / Provisioning Failures

1. Never blind-clear a quarantine — pull the specific error code first (portal job status pane, or `Get-AADCloudSyncToolsLogs`)
2. Map the error code to the reference table (see Command Cheat Sheet / Symptom map) and resolve the underlying cause
3. Clear quarantine via portal (simplest) or Graph `synchronizationJob.restart` (granular — lets you preserve watermarks)
4. For `AzureDirectoryServiceAuthorizationFailed`, remember the up-to-24-hour propagation delay after recreating the missing service principal — don't re-escalate prematurely

### Phase 5 — Post-Fix Verification

1. Confirm job status returns to `Active`/healthy via `Get-AADCloudSyncToolsJob`
2. Spot-check the specific previously-failing object in the provisioning logs by AD `ObjectGuid`
3. For scoping changes, confirm the expected object count actually landed in Entra ID (`Get-MgUser`/`Get-MgGroup` filtered by a known attribute)
4. For GPAD, confirm the group actually appears in AD with correct membership within one 20-minute cycle

---
## Remediation Playbooks

<details><summary>Playbook 1 — Recover an agent stuck in "insufficient privileges" service-start failure</summary>

**Scenario:** `Microsoft Entra Provisioning Agent` fails to start with an insufficient-privileges error after install or a server reboot. This is caused by a Group Policy that removes "Log on as a service" rights from the NT service account the installer provisioned.

**Step 1 — Confirm the service account and error**
```powershell
Get-CimInstance Win32_Service -Filter "Name='AADConnectProvisioningAgent'" |
    Select-Object Name, StartName, State
Get-WinEvent -LogName System -MaxEvents 50 |
    Where-Object { $_.Id -eq 7000 -or $_.Id -eq 7041 } | Select-Object TimeCreated, Message
```

**Step 2 — Confirm the GPO is the cause (temporary diagnostic only)**
```powershell
# Services.msc → Microsoft Entra Provisioning Agent → Log On tab → This account → <domain admin> → OK
Restart-Service AADConnectProvisioningAgent
```
If it now starts, the GPO is confirmed as the cause.

**Step 3 — Fix at the policy level, not the account level**
Identify the GPO applying "Log on as a service" restrictions to this OU/server and either exclude the agent server via a security-filtered GPO scope, or add the gMSA/NT service account explicitly to the allowed list within that policy.

**Step 4 — Revert the temporary domain-admin logon and confirm clean start**
```powershell
# Reset Log On account back to the gMSA or original NT service account in Services.msc
Restart-Service AADConnectProvisioningAgent
Get-Service AADConnectProvisioningAgent | Select-Object Status
```

**Rollback:** Reverting the service logon account is non-destructive; just restart the service.

</details>

<details><summary>Playbook 2 — Diagnose and clear a quarantined job without losing sync state</summary>

**Scenario:** A job has entered quarantine. Rather than a blind clear, this playbook isolates the true cause first.

**Step 1 — Pull the specific error code**
```powershell
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools
$job = Get-AADCloudSyncToolsJob | Where-Object { $_.Status -eq "Quarantined" }
$job | Select-Object Id, Status
```
Cross-reference the error against the reference table in the Command Cheat Sheet, or the portal's status pane detail.

**Step 2 — Resolve by error family**
- Credential-related (`AzureActiveDirectory*Credential*`) → `Repair-AADCloudSyncToolsAccount`
- Missing service principal (`AzureDirectoryServiceAuthorizationFailed`) → recreate via `Update-MgOrganization -OnPremisesSyncEnabled:$true`, then wait up to 24h
- No active agent (`HybridIdentityServiceNoActiveAgents`/`...NoAgentsAssigned`) → confirm agent service running and reachable; re-register if the portal shows zero agents
- Duplicate directory objects (`HybridSynchronizationActiveDirectoryUnexpectedDuplicateEntriesFound`) → find and remove duplicate `msDS-ExternalDirectoryObjectId` values (see script below)

**Step 3 — Find duplicate group entries (if applicable)**
```powershell
$attributeName = "msDS-ExternalDirectoryObjectId"
$prefix = "Group_"
$allGroups = Get-ADGroup -LDAPFilter "($attributeName=$prefix*)" -Properties $attributeName
$duplicateGroups = $allGroups | Group-Object -Property $attributeName | Where-Object { $_.Count -gt 1 }
foreach ($group in $duplicateGroups) {
    Write-Host "Value: $($group.Name) (Count: $($group.Count))"
    $group.Group | Select-Object Name, DistinguishedName, $attributeName | Format-Table -AutoSize
}
```
Remove the true duplicate (not the authoritative object) after confirming with the business owner.

**Step 4 — Clear quarantine with granular control**
```powershell
# Portal: right-click job status → Clear quarantine (clears everything)
# OR Graph — preserve watermarks, clear only the quarantine flag:
# POST /servicePrincipals/{id}/synchronization/jobs/{jobId}/restart
# body: { "criteria": { "resetScope": "Quarantine" } }
```

**Step 5 — Confirm recovery**
```powershell
Start-Sleep -Seconds 150
Get-AADCloudSyncToolsJob -JobId $job.Id | Select-Object Id, Status
```

**Rollback:** Not applicable — this playbook only diagnoses and clears a blocked state; no destructive changes unless duplicate-object removal in Step 3 is performed (back up the DN/attribute values first).

</details>

<details><summary>Playbook 3 — Migrate scoping safely to avoid an Accidental Deletion Prevention block</summary>

**Scenario:** You're narrowing scope (removing OUs, or fully cutting over from Entra Connect Sync to Cloud Sync) and need to avoid tripping the accidental-deletion safety threshold mid-migration.

**Step 1 — Estimate the object count that will fall out of scope**
```powershell
(Get-ADObject -SearchBase "<OU-DN>" -SearchScope Subtree -Filter * | Measure-Object).Count
```

**Step 2 — If the count is large, stage the scope reduction incrementally**
Reduce scope in smaller batches (e.g., by sub-OU) rather than one large cutover, checking provisioning logs between batches for unexpected quarantine.

**Step 3 — If a block still occurs, confirm it's expected before disabling protection**
```powershell
# Review what's pending deletion in the provisioning logs first
# Entra admin center → Entra Connect > Cloud sync > [job] > Logs → filter by deletion events
```

**Step 4 — Temporarily disable Accidental Deletion Prevention**
```powershell
Import-Module AADCloudSyncTools
Connect-AADCloudSyncTools
Disable-AADCloudSyncToolsDirSyncAccidentalDeletionPrevention -TenantId "<tenantId>"
```

**Step 5 — Let the next cycle export the deletions, then re-enable protection**
```powershell
Start-Sleep -Seconds 150
Get-AADCloudSyncToolsJob | Select-Object Id, Status
# Re-enable protection via the corresponding Enable- cmdlet once the migration event is complete
```

**Rollback:** If deletions turn out to be unintended, restore affected objects from the Entra ID Recycle Bin (30-day retention) before the window closes.

</details>

<details><summary>Playbook 4 — Right-size Group Provisioning to AD DS (GPAD) scoping mode for tenant scale</summary>

**Scenario:** GPAD delta cycles are slow or erroring, and the tenant is at or near the documented scale ceilings.

**Step 1 — Establish current tenant scale**
```powershell
Connect-MgGraph -Scopes "User.Read.All","Group.Read.All"
$userCount = (Get-MgUser -All -Property Id | Measure-Object).Count
$groupCount = (Get-MgGroup -All -Property Id | Measure-Object).Count
Write-Host "Users: $userCount  Groups: $groupCount"
```

**Step 2 — Pick the correct scoping mode**

| Tenant scale | Required mode | Ceiling |
|---|---|---|
| > 200K users, > 40K groups, or > 1M memberships | **Selected security groups** (only supported mode at this scale) | Up to 10K groups, 250K total members in scope |
| Under all three thresholds above | **All security groups + attribute scoping filter** | Up to 20K groups, 500K total members in scope |

"All security groups" **without** an attribute filter is unsupported at any scale.

**Step 3 — If more than 999 groups need "Selected security groups" scope**, use the Graph API directly (the portal UI caps selection/display at 999):
```http
POST https://graph.microsoft.com/v1.0/servicePrincipals/{servicePrincipalID}/appRoleAssignedTo
Content-Type: application/json

{
  "principalId": "<group-object-id>",
  "resourceId": "<job-service-principal-id>",
  "appRoleId": "1a0abf4d-b9fa-4512-a3a2-51ee82c6fd9f"
}
```
(`appRoleId` above is for the Public cloud — see the cheat sheet for US Gov/other clouds.)

**Step 4 — Split oversized single groups**
Any single group over 50,000 members is unsupported outright — split membership across multiple groups (e.g., by region/business unit) rather than trying to force one large group through.

**Step 5 — Re-verify cycle health**
```powershell
Get-AADCloudSyncToolsJob | Where-Object { $_.Schema -like "*ADDS*" } | Select-Object Id, Status
```

**Rollback:** Scoping mode changes are configuration-only; reverting is safe but triggers a re-evaluation cycle.

</details>

---
## Evidence Pack

Run this on a provisioning agent server to collect everything needed for an L3/Microsoft support escalation:

```powershell
<#
.SYNOPSIS  Entra Cloud Sync Evidence Collector
.NOTES     Run from a provisioning agent server as local administrator.
           Requires the AADCloudSyncTools module (installed automatically if missing).
#>

$reportPath = "C:\Temp\CloudSyncEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
Write-Host "Collecting Cloud Sync evidence to $reportPath..." -ForegroundColor Cyan

# 1. Local service state
"=== Agent Services ===" | Out-File "$reportPath\01_Services.txt"
Get-Service "AADConnectProvisioningAgent","AADConnectProvisioningAgentUpdater" -ErrorAction SilentlyContinue |
    Select-Object DisplayName, Status, StartType | Format-List | Out-File "$reportPath\01_Services.txt" -Append

# 2. OS / prerequisite check
"=== OS and Prerequisites ===" | Out-File "$reportPath\02_Prereqs.txt"
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, BuildNumber |
    Format-List | Out-File "$reportPath\02_Prereqs.txt" -Append
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue |
    Select-Object Release, Version | Format-List | Out-File "$reportPath\02_Prereqs.txt" -Append
Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-File "$reportPath\02_Prereqs.txt" -Append

# 3. gMSA state
"=== gMSA ===" | Out-File "$reportPath\03_gMSA.txt"
Get-ADServiceAccount -Filter "Name -like 'provAgentgMSA*'" -Properties PrincipalsAllowedToRetrieveManagedPassword -ErrorAction SilentlyContinue |
    Format-List | Out-File "$reportPath\03_gMSA.txt" -Append

# 4. Cloud-side agent + job status (requires sign-in)
"=== Agents and Jobs (cloud) ===" | Out-File "$reportPath\04_CloudState.txt"
if (-not (Get-Module -ListAvailable AADCloudSyncTools)) {
    Install-Module AADCloudSyncTools -Scope AllUsers -Force -ErrorAction SilentlyContinue
}
Import-Module AADCloudSyncTools -ErrorAction SilentlyContinue
try {
    Connect-AADCloudSyncTools -ErrorAction Stop
    Get-AADCloudSyncToolsAgent | Format-List | Out-File "$reportPath\04_CloudState.txt" -Append
    Get-AADCloudSyncToolsJob | Format-List | Out-File "$reportPath\04_CloudState.txt" -Append
} catch {
    "Could not connect — sign in manually and re-run Get-AADCloudSyncToolsAgent / Get-AADCloudSyncToolsJob" |
        Out-File "$reportPath\04_CloudState.txt" -Append
}

# 5. Network connectivity
"=== Network Connectivity ===" | Out-File "$reportPath\05_Network.txt"
$eps = @(
    @{n="login.windows.net";p=443}, @{n="management.azure.com";p=443},
    @{n="ctldl.windowsupdate.com";p=80}, @{n="enterpriseregistration.windows.net";p=443}
)
foreach ($e in $eps) {
    $r = Test-NetConnection -ComputerName $e.n -Port $e.p -WarningAction SilentlyContinue
    "$($e.n):$($e.p) — $($r.TcpTestSucceeded)" | Out-File "$reportPath\05_Network.txt" -Append
}

# 6. Agent trace logs (copy, don't move)
"=== Trace Log Directory Listing ===" | Out-File "$reportPath\06_TraceLogs.txt"
$tracePath = "C:\ProgramData\Microsoft\Azure AD Connect Provisioning Agent\Trace"
if (Test-Path $tracePath) {
    Get-ChildItem $tracePath | Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
        Format-Table Name, LastWriteTime, Length -AutoSize | Out-File "$reportPath\06_TraceLogs.txt" -Append
}

# 7. Full AADCloudSyncTools log export (verbose capture)
try {
    Export-AADCloudSyncToolsLogs -TracingDurationMins 3 -OutputPath $reportPath -ErrorAction Stop
} catch {
    "Export-AADCloudSyncToolsLogs failed — run manually if agent-side traces are needed" |
        Out-File "$reportPath\07_ExportLogsNote.txt"
}

# Compress
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "`nEvidence collected: $reportPath.zip" -ForegroundColor Green
Write-Host "Upload this file to your support ticket." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check agent services | `Get-Service AADConnectProvisioningAgent,AADConnectProvisioningAgentUpdater` |
| Install AADCloudSyncTools | `Install-Module AADCloudSyncTools -Scope AllUsers -Force` |
| Connect to Cloud Sync tools | `Connect-AADCloudSyncTools` |
| List agents (cloud view) | `Get-AADCloudSyncToolsAgent` |
| List jobs + status | `Get-AADCloudSyncToolsJob` |
| Restart/resync a job | `Invoke-AADCloudSyncToolsJob -JobId "<id>" -Restart` |
| Repair sync service account | `Repair-AADCloudSyncToolsAccount` |
| Disable accidental-deletion block | `Disable-AADCloudSyncToolsDirSyncAccidentalDeletionPrevention -TenantId "<id>"` |
| Set gMSA permissions manually | `Set-AADCloudSyncPermissions -PermissionType UserGroupCreateDelete -TargetDomain "<fqdn>" -EACredential $cred` |
| Export full agent diagnostics | `Export-AADCloudSyncToolsLogs -TracingDurationMins 5` |
| Check missing sync service principal | `Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Entra AD Synchronization Service'"` |
| Force service principal recreation | `Update-MgOrganization -OrganizationId <id> -OnPremisesSyncEnabled:$true` |
| Check gMSA object + delegation | `Get-ADServiceAccount -Filter "Name -like 'provAgentgMSA*'" -Properties PrincipalsAllowedToRetrieveManagedPassword` |
| Check TLS 1.2 registry state | `Get-ItemProperty "HKLM:\...\SCHANNEL\Protocols\TLS 1.2\Client"` |
| Check execution policy | `Get-ExecutionPolicy -List` |
| Find duplicate GPAD group anchors | See Playbook 2, Step 3 (`msDS-ExternalDirectoryObjectId` dedup script) |
| Restart a job via Graph (granular) | `POST /servicePrincipals/{id}/synchronization/jobs/{jobId}/restart` |
| Graph API for >999 group GPAD scope | `POST /servicePrincipals/{id}/appRoleAssignedTo` |

---
## 🎓 Learning Pointers

- **Cloud Sync has no Metaverse and no local database — it's stateless by design.** Every troubleshooting instinct carried over from Entra Connect Sync (checking the Connector Space, inspecting the Metaverse Designer) doesn't apply here. State lives entirely in the cloud provisioning service; the on-prem agent is purely a relay. Reach for the provisioning logs in the portal, not a local sync engine GUI. [What is Microsoft Entra Cloud sync?](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/what-is-cloud-sync)

- **Windows Server 2025 is explicitly unsupported for the provisioning agent unless KB5070773 (Oct 20, 2025) or later is installed.** This is a recent, easy-to-miss gotcha for any environment refreshing agent servers onto the newest Windows Server release — check this before assuming a fresh Server 2025 install should "just work." [Cloud Sync prerequisites](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-prerequisites)

- **Renamed OUs and groups are a silent blind spot.** Delta sync does not detect an in-scope OU or group being renamed in AD — and critically, this does **not** put the job into quarantine or raise any error. The job stays "healthy" while quietly failing to track membership changes for the renamed container. This is one of the few failure modes in this whole repo's coverage that produces zero error signal by design.

- **Group Provisioning to AD DS has hard scale ceilings that are easy to trip in a large tenant.** "All security groups" scoping without an attribute filter isn't a bad practice to avoid — it's unsupported outright above any scale. Get the tenant's user/group/membership counts before choosing a scoping mode, not after cycles start failing. [Scale limits reference](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-prerequisites#scale-limits-for-provisioning-groups-to-active-directory)

- **The gMSA is what makes multi-agent HA possible — don't fight it by going back to a standard service account.** A gMSA's automatic password rotation and multi-server usability is the specific mechanism that lets 3 agents run active-active with transparent failover. If an environment reverts to a manually-managed service account (common after a botched upgrade), HA silently degrades to "whichever agent has valid credentials right now."

- **Quarantine's three-part reset (escrows/quarantine/watermarks) is worth understanding before you next hit it under pressure.** The portal's "Clear quarantine" button resets everything, including watermarks — which can trigger a much longer resync than necessary if only the quarantine flag actually needed clearing. The Graph restart API's `resetScope` parameter lets you be surgical. [Troubleshooting: provisioning quarantine](https://learn.microsoft.com/en-us/entra/identity/hybrid/cloud-sync/how-to-troubleshoot)
