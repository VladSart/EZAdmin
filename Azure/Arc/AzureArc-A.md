# Azure Arc-Enabled Servers — Reference Runbook (Mode A: Deep Dive)
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

| Item | Detail |
|------|--------|
| Product | Azure Arc-enabled servers (Connected Machine agent) — physical servers, on-prem VMs, VMs on other clouds |
| Applies to | Windows and Linux Connected Machine agent, agent versions with `azcmagent` CLI (current model) |
| Out of scope | Azure Arc-enabled Kubernetes, Arc-enabled data services (SQL/PostgreSQL), Arc-enabled VMware/SCVMM/AWS/GCP (private cloud/private hub scenarios — different onboarding model) |
| Prerequisite for | Sentinel data connectors (`Security/Sentinel/DataConnectors-A.md`), Microsoft Defender for Cloud CSPM/server plans, Update Manager, Azure Policy guest configuration on non-Azure machines |
| Identity model | Each Arc-enabled server gets its own Microsoft Entra managed identity, issued at onboarding, used for all subsequent Azure communication |

---
## How It Works

<details><summary>Full architecture</summary>

Azure Arc-enabled servers projects a non-Azure machine (physical, on-prem VM, or a VM running on another cloud) into Azure Resource Manager as a `Microsoft.HybridCompute/machines` resource, so it can be governed, monitored, and extended with the same control plane used for native Azure VMs — without Azure ever having inbound network access to it.

**The core mechanism — outbound-only, agent-initiated:**

```
Non-Azure server
    │
    ├── Connected Machine agent (azcmagent) — the onboarding/lifecycle CLI
    │
    ├── HIMDS (Hybrid Instance Metadata Service) — local service that issues a
    │      machine-scoped managed identity token, analogous to IMDS on a real Azure VM
    │
    ├── Guest Configuration / Extension agent — installs and manages VM extensions
    │      (AMA, MDE.Windows/Linux, Update Manager, Custom Script, Dependency agent)
    │
    └── All communication is OUTBOUND HTTPS 443 to Azure — no listener, no inbound
        firewall rule ever required on the server itself.
```

**Onboarding flow (interactive or at-scale):**

1. `azcmagent connect` is run locally (interactively with device-code/Entra login, or unattended with a service principal for at-scale deployment).
2. The agent authenticates to Microsoft Entra ID (`login.microsoftonline.com`), then calls Azure Resource Manager (`management.azure.com`) to create the `Microsoft.HybridCompute/machines` resource.
3. Azure issues a machine-scoped **Microsoft Entra managed identity** tied to that resource. HIMDS stores the private key locally and never transmits it — only signed tokens leave the machine, mirroring how Azure VM Managed Identity/IMDS works.
4. The agent begins sending a **heartbeat every 5 minutes**. Azure marks the resource `Disconnected` if no heartbeat arrives within **15 minutes**.
5. Extension management (`*.guestconfiguration.azure.com`) becomes available — this is the channel used to layer on AMA, Defender for Endpoint, Update Manager, and Azure Policy guest configuration, all delivered as VM extensions exactly like on a native Azure VM.

**The three-tier server-state model:**

- **Connected** — heartbeat received within the last 15 minutes. Fully governable.
- **Disconnected** — no heartbeat for 15+ minutes. The Azure-side resource object still exists (not deleted), extensions/policies remain assigned but can't execute, and the last-known configuration is what Azure Policy/Defender for Cloud will report against.
- **Expired** — after **45-90 days** continuously disconnected, the machine's Microsoft Entra managed identity registration itself expires. This is not self-healing: the agent can never silently reconnect past this point. Recovery requires `azcmagent disconnect --force-local-only` (wipes local state only, since Azure-side cleanup already effectively happened) followed by a fresh `azcmagent connect`, which **creates a brand-new resource ID** — any monitoring, tagging, or policy assignment keyed to the old resource ID must be redone.

**Identity separation (two different "identities" in play):**

- The **machine's own managed identity** (via HIMDS) — used for the agent's ongoing communication with Azure Arc services after onboarding.
- The **onboarding identity** (interactive user, or a service principal for at-scale) — used only at connect/disconnect time to create/delete the ARM resource, and must hold the **Azure Connected Machine Onboarding** role (or broader) at the target resource group scope.

**Private Link option:**
For organizations wanting to avoid public-internet exposure entirely, Azure Arc Private Link Scope routes `*.his.arc.azure.com` and `*.guestconfiguration.azure.com` traffic through a Private Endpoint in the customer's VNet. `login.microsoftonline.com` and `management.azure.com` remain public endpoints even with Private Link configured (documented as "Public" in the private-link-capable column) — a common point of confusion when customers expect a fully private path.

</details>

---
## Dependency Stack

```
Physical server / on-prem VM / VM on another cloud (Windows or Linux)
    │
    └── Connected Machine agent installed (azcmagent + HIMDS + Extension service)
            │
            └── Outbound HTTPS 443 reachability (agent-initiated only, no inbound ever required)
                    │
                    ├── login.microsoftonline.com / *.login.microsoft.com / pas.windows.net  — Entra ID auth (always)
                    ├── management.azure.com                                                  — ARM, connect/disconnect only
                    ├── *.his.arc.azure.com                                                   — metadata + hybrid identity (always, Private Link-capable)
                    ├── *.guestconfiguration.azure.com                                         — extension mgmt (always, Private Link-capable)
                    └── guestnotificationservice.azure.com / *.servicebus.windows.net          — notifications (always)
                            │
                            └── HIMDS issues machine-scoped Microsoft Entra managed identity (local, private key never leaves the box)
                                    │
                                    └── Heartbeat every 5 min → Connected / Disconnected (15 min) / Expired (45-90 days)
                                            │
                                            └── Azure RBAC on the onboarding identity: "Azure Connected Machine Onboarding" role
                                                    │
                                                    └── Resource providers registered: Microsoft.HybridCompute, Microsoft.GuestConfiguration, Microsoft.HybridConnectivity
                                                            │
                                                            └── Extensions layered on top: AMA, MDE.Windows/Linux, Update Manager,
                                                                Dependency Agent, Custom Script, Azure Policy guest configuration
                                                                    │
                                                                    └── Downstream consumers: Microsoft Sentinel data connectors,
                                                                        Defender for Cloud CSPM/server plans, Azure Policy compliance
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| `azcmagent show` reports `Disconnected` | No heartbeat received in 15+ min — network/service issue, agent process itself may be fine | `azcmagent check`; `Get-Service himds` |
| Onboarding fails with `AZCM0026` | Network config error — endpoint unreachable, or Private Link Scope needed but not specified | `azcmagent check`; confirm `--private-link-scope` if applicable |
| Onboarding fails with `AZCM0041` | Invalid credentials (bad SPN secret, wrong tenant, wrong client ID) | Verify SPN app ID/secret/tenant against Entra app registration |
| Onboarding fails with `AZCM0042` | Resource creation failed — insufficient RBAC or quota | Confirm "Azure Connected Machine Onboarding" role at target scope |
| Onboarding fails with `AZCM0044` | A resource with the same name already exists | Use a different `--resource-name`, or delete the stale Azure-side resource first |
| Onboarding fails with `AZCM0067` | Machine already connected locally | Run `azcmagent disconnect` first, or use `reconnect` |
| Onboarding fails with `AZCM0081` | Managed identity certificate download failed after resource creation | Delete the partially-created Azure resource and retry connect |
| Machine has been offline 45+ days and won't reconnect | Entra managed identity registration expired — not recoverable in place | `azcmagent disconnect --force-local-only` then fresh `connect` (new resource ID) |
| `Failed to acquire authorization token`, dial tcp unreachable | Firewall blocking `login.windows.net`/`login.microsoftonline.com` | `azcmagent check`; confirm service tag `AzureActiveDirectory` allow-listed |
| `Get ARM Resource Response ... 403` | Caller/SPN lacks RBAC at the target scope | Confirm role assignment, not just resource provider registration |
| `subscription isn't registered to use namespace 'Microsoft.HybridCompute'` | Resource provider not registered on the subscription | `Register-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute` |
| Agent connected, but an extension (AMA/MDE) never installs | Extension management channel (`*.guestconfiguration.azure.com`) blocked, or extension-specific prerequisite missing | `Get-AzConnectedMachineExtension`; check extension logs under `GuestConfig\extension_logs` |
| Machine shows Connected in Azure but data isn't flowing to Sentinel/Defender for Cloud | The Arc connection is healthy but the *data-plane* extension (AMA + DCR association) is a separate, later layer | Cross-reference `Security/Sentinel/DataConnectors-A.md` — Arc connectivity is a precondition, not the whole pipeline |
| Filtering `AzureArcInfrastructure` by IP/region works in one region, fails in another | Regional service tag sub-ranges exclude global service components | Use the full, unscoped `AzureArcInfrastructure` service tag range |
| TLS handshake failures only on older/legacy OS or agent < 1.56 | Cipher suite/TLS version mismatch — agent requires TLS 1.2/1.3 with specific cipher suites as of v1.56+ | Confirm OS TLS registry settings; upgrade agent |

---
## Validation Steps

**1 — Confirm agent installation and version**
```powershell
azcmagent version
Get-Service himds, GCArcService, ExtensionService | Select-Object Name, Status
```
Bad: any of the three core services not `Running`.

**2 — Confirm connection state and heartbeat recency**
```powershell
azcmagent show
```
Bad: `Agent Status: Disconnected` or `Error`, or `Last Heartbeat` older than ~10 minutes.

**3 — Run the built-in end-to-end connectivity probe**
```powershell
azcmagent check
```
Bad: any endpoint reports `Failed`. This single command replaces manual per-endpoint DNS/port testing in most cases.

**4 — Confirm the Azure-side resource state matches the local agent's view**
```powershell
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" |
    Select-Object Name, Status, LastStatusChange, AgentVersion, OSType, DetectedProperties
```
Bad: Azure shows `Disconnected` while `azcmagent show` locally reports `Connected` (or vice versa) — indicates a heartbeat delivery problem worth isolating with packet capture/proxy logs rather than assuming either side is simply wrong.

**5 — Confirm resource provider registration (onboarding-time only)**
```powershell
Get-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute, Microsoft.GuestConfiguration, Microsoft.HybridConnectivity |
    Select-Object ProviderNamespace, RegistrationState
```
Bad: any shows `NotRegistered` or `Registering` for more than a few minutes.

**6 — Confirm RBAC on the onboarding identity**
```powershell
Get-AzRoleAssignment -SignInName "<upn-or-spn-appid>" -Scope "/subscriptions/<subId>/resourceGroups/<rg>" |
    Where-Object { $_.RoleDefinitionName -like "*Connected Machine*" -or $_.RoleDefinitionName -eq "Contributor" }
```
Bad: no matching role — onboarding will fail with `AZCM0042`.

**7 — Confirm extension health once connected**
```powershell
Get-AzConnectedMachineExtension -ResourceGroupName "<rg>" -MachineName "<machineName>" |
    Select-Object Name, ProvisioningState, TypeHandlerVersion
```
Bad: `ProvisioningState` stuck in `Creating`/`Updating` for more than 15-20 minutes, or `Failed`.

---
## Troubleshooting Steps (by phase)

### Phase 1 — Onboarding Fails Outright
1. Capture the exact `AZCM####` code from console output or `azcmagent.log` — this is more reliable than the free-text message.
2. Distinguish credential failures (`AZCM0041`, `AZCM0012`) from network failures (`AZCM0026`) from RBAC/resource failures (`AZCM0042`, `AZCM0044`) — each has a completely different fix path.
3. For at-scale (service principal) onboarding specifically, verify the SPN's client ID/secret/tenant against the actual Entra app registration before assuming a network cause — this is the single most common at-scale onboarding failure.
4. Confirm required resource providers are registered on the target subscription before retrying.

### Phase 2 — Previously-Connected Machine Goes Disconnected
1. Run `azcmagent check` first — it isolates network/endpoint failures from service failures in one pass.
2. If all endpoints pass but the agent still won't heartbeat, check the three core services (`himds`, `GCArcService`, `ExtensionService`) individually — a stopped/crashed service can look identical to a network problem from the portal's perspective.
3. Check how long the machine has been disconnected. Under 45 days: standard reconnect troubleshooting applies. Approaching or past 45-90 days: the managed identity may already be expired — don't burn time on network troubleshooting, jump straight to the force-disconnect/reconnect playbook.
4. If using a proxy, confirm the agent's own proxy configuration (`azcmagent config list`) matches the environment's actual proxy — proxy config drift after a network change is a common silent-disconnect cause.

### Phase 3 — Agent Connected, But Extensions/Data Aren't Working
1. Confirm the Arc connection itself is healthy first (Phase 1/2 checks) — don't troubleshoot an extension on top of a shaky base connection.
2. Check `*.guestconfiguration.azure.com` reachability specifically — this is a separate endpoint from the core identity/heartbeat path and can be blocked independently.
3. Pull the specific extension's provisioning state and logs — AMA, MDE, and Update Manager each have their own extension-level log paths and failure modes layered on top of a working Arc connection.
4. For Sentinel/Defender for Cloud specifically, remember Arc connectivity is a **prerequisite layer**, not the data pipeline itself — cross-reference `Security/Sentinel/DataConnectors-A.md` once the Arc connection itself is confirmed healthy.

### Phase 4 — Multi-Region / Multi-Tenant (MSP Fleet) Considerations
1. Service tag filtering (`AzureArcInfrastructure`) must use the full, unscoped range — per-region sub-ranges miss global components and cause "works in one client's network, fails in another's" tickets.
2. At-scale onboarding scripts using a single SPN across many client tenants should confirm the SPN's role assignment exists in **each** target tenant/subscription — a role that exists in one client's environment doesn't carry over to another.
3. Track disconnection duration per machine across a fleet — a scripted sweep for machines approaching the 45-90 day expiry cliff prevents surprise "why can't I reconnect this" tickets weeks later.

---
## Remediation Playbooks

<details><summary>Playbook 1 — At-scale onboarding via service principal, hardened for MSP multi-tenant use</summary>

```powershell
# 1. Verify (don't assume) the SPN's role assignment exists in THIS target tenant/subscription
$spnAppId = "<spnAppId>"
Connect-AzAccount -Tenant "<targetTenantId>" -Subscription "<targetSubId>"
Get-AzRoleAssignment | Where-Object { $_.ApplicationId -eq $spnAppId }
# Expected: "Azure Connected Machine Onboarding" (or broader) at the target resource group scope.
# If missing, grant it before attempting onboarding — don't discover this via a failed AZCM0042.

# 2. Register required resource providers (idempotent — safe to always run)
Register-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute
Register-AzResourceProvider -ProviderNamespace Microsoft.GuestConfiguration
Register-AzResourceProvider -ProviderNamespace Microsoft.HybridConnectivity

# 3. Run the onboarding with verbose logging so failures are captured on first attempt
azcmagent connect `
    --service-principal-id $spnAppId `
    --service-principal-secret "<spnSecret>" `
    --resource-group "<rg>" `
    --tenant-id "<targetTenantId>" `
    --location "<region>" `
    --subscription-id "<targetSubId>" `
    --tags "Environment=Prod,ManagedBy=MSP" `
    --verbose

# 4. Immediately validate
azcmagent show
azcmagent check
```

**Rollback:** If onboarding partially succeeds then fails (Azure resource created but agent-side connect errors), delete the partial resource before retrying rather than layering a second attempt on top: `azcmagent disconnect --force-local-only` then remove the orphaned `Microsoft.HybridCompute/machines` object in Azure if it exists.

</details>

<details><summary>Playbook 2 — Recover a machine past the 45-90 day disconnect/expiry window</summary>

```powershell
# 1. Confirm this is genuinely an expiry case, not a fixable network/service issue
azcmagent show
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" |
    Select-Object Status, LastStatusChange
# If LastStatusChange is 45+ days in the past and reconnect attempts fail with identity/auth errors
# (not network errors), this is the expiry case.

# 2. Wipe local agent state only — the managed identity registration is unrecoverable, no point
#    trying to preserve it
azcmagent disconnect --force-local-only

# 3. Clean up the stale Azure-side resource (optional but recommended — prevents name collision)
Remove-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" -ErrorAction SilentlyContinue

# 4. Fresh onboarding — this creates a NEW resource ID
azcmagent connect --resource-group "<rg>" --tenant-id "<tenantId>" `
    --location "<region>" --subscription-id "<subId>" --resource-name "<machineName>"

# 5. IMPORTANT: update any monitoring, alerting, Azure Policy exemptions, or automation that
#    referenced the OLD resource ID — it no longer exists and won't silently redirect.
```

**Rollback:** N/A — this playbook is itself the recovery path for an unrecoverable state. There is no safe way to "undo" an expired managed identity in place.

</details>

<details><summary>Playbook 3 — Fleet-wide disconnect sweep before it becomes an expiry problem</summary>

```powershell
# Run across all subscriptions an MSP manages, find anything disconnected and how long
$subs = Get-AzSubscription
$atRisk = foreach ($sub in $subs) {
    Set-AzContext -Subscription $sub.Id | Out-Null
    Get-AzConnectedMachine | Where-Object { $_.Status -ne "Connected" } |
        Select-Object Name, ResourceGroupName, Status, LastStatusChange,
            @{N='SubscriptionId';E={$sub.Id}},
            @{N='DaysDisconnected';E={(New-TimeSpan -Start $_.LastStatusChange -End (Get-Date)).Days}}
}

$atRisk | Where-Object { $_.DaysDisconnected -ge 30 } | Sort-Object DaysDisconnected -Descending |
    Format-Table Name, ResourceGroupName, SubscriptionId, Status, DaysDisconnected -AutoSize

# Anything approaching 45 days needs active remediation (Fix 1-3 in AzureArc-B.md) THIS WEEK,
# not after it crosses the expiry line into Playbook 2 territory.
```

**Rollback:** N/A — read-only reporting query.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Azure Arc-Enabled Server Evidence Collector — gathers diagnostic data for escalation
.NOTES     Run locally on the affected server (elevated) for local state, and optionally against
           Azure for resource-side state if Az.ConnectedMachine module + context are available.
#>

param(
    [string]$ResourceGroupName,
    [string]$MachineName
)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Azure Arc Evidence Pack - $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n")

try {
    $show = & azcmagent show
    $report.Add("azcmagent show:`n$($show -join "`n")")
} catch { $report.Add("ERROR running azcmagent show: $_") }

try {
    $check = & azcmagent check
    $report.Add("`nazcmagent check:`n$($check -join "`n")")
} catch { $report.Add("ERROR running azcmagent check: $_") }

foreach ($svc in @('himds','GCArcService','ExtensionService')) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        $report.Add("`nService $svc : $($s.Status)")
    } catch { $report.Add("`nService $svc : NOT FOUND") }
}

try {
    $log = Get-Content "$env:ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log" -Tail 100
    $errors = $log | Select-String "AZCM\d{4}" | Select-Object -Last 20
    if ($errors) { $report.Add("`nRecent AZCM error codes in log:`n$($errors -join "`n")") }
} catch { $report.Add("`nCould not read local agent log: $_") }

if ($ResourceGroupName -and $MachineName) {
    try {
        $azm = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $MachineName
        $report.Add("`nAzure-side resource: Status=$($azm.Status), LastStatusChange=$($azm.LastStatusChange), AgentVersion=$($azm.AgentVersion)")
    } catch { $report.Add("`nERROR reading Azure-side resource: $_") }
}

$outPath = "$env:TEMP\AzureArc-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
$report | Out-File $outPath -Encoding UTF8
Write-Host "Evidence saved to: $outPath" -ForegroundColor Green
$outPath
```

---
## Command Cheat Sheet

| Task | Command |
|------|---------|
| Show connection status/heartbeat | `azcmagent show` |
| Full connectivity/endpoint check | `azcmagent check` |
| List/set agent config (proxy etc.) | `azcmagent config list` / `azcmagent config set <key> <value>` |
| Onboard interactively | `azcmagent connect --resource-group <rg> --tenant-id <t> --location <region> --subscription-id <s>` |
| Onboard at-scale (SPN) | `azcmagent connect --service-principal-id <id> --service-principal-secret <secret> ...` |
| Disconnect cleanly | `azcmagent disconnect` |
| Disconnect when Azure resource already gone | `azcmagent disconnect --force-local-only` |
| Reconnect an already-connected machine | `azcmagent connect` (fails w/ AZCM0067 — use disconnect first, or `reconnect` semantics) |
| Check Azure-side resource state | `Get-AzConnectedMachine -ResourceGroupName <rg> -Name <name>` |
| Delete Azure-side resource | `Remove-AzConnectedMachine -ResourceGroupName <rg> -Name <name>` |
| Check resource provider registration | `Get-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute` |
| List extensions on a machine | `Get-AzConnectedMachineExtension -ResourceGroupName <rg> -MachineName <name>` |
| Remove/reinstall a stuck extension | `Remove-AzConnectedMachineExtension` / `New-AzConnectedMachineExtension` |
| Core services (Windows) | `himds`, `GCArcService`, `ExtensionService` |
| Verbose log path (Windows) | `%ProgramData%\AzureConnectedMachineAgent\Log\azcmagent.log` |
| Verbose log path (Linux) | `/var/opt/azcmagent/log/azcmagent.log` |

---
## 🎓 Learning Pointers

- **The 45-90 day expiry cliff is the domain's single biggest "surprise ticket" generator.** Unlike almost every other Azure resource state, this one is not recoverable in place — it requires a destructive local wipe and a brand-new resource ID. Build fleet-wide disconnect-duration monitoring (Playbook 3) rather than waiting for individual reconnect failures. See [Connected Machine agent overview](https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview).
- **`azcmagent check` replaces most manual network troubleshooting.** It's purpose-built to test every required endpoint in one pass — reach for it before `Test-NetConnection`/`Resolve-DnsName` on individual URLs. See [network requirements](https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements).
- **Two identities are in play and it's easy to confuse them.** The onboarding identity (your user or an SPN) only matters at connect/disconnect time and needs RBAC at the target scope; the machine's own managed identity (via HIMDS) is what the agent uses for everything afterward and never leaves the box. A failure at one layer looks completely different from a failure at the other.
- **Arc connectivity is a prerequisite layer, not the whole story for Sentinel/Defender for Cloud.** A healthy `Connected` status only means the control-plane channel works — data actually flowing into Sentinel or a CSPM scan completing depends on the extension layer (AMA + DCR association) on top of that. See [[project_ezadmin]] and cross-reference `Security/Sentinel/DataConnectors-A.md`.
- **Service tag filtering by region sub-range is a classic MSP multi-client gap.** `AzureArcInfrastructure.<Region>` excludes global service components — only the full, unscoped tag is safe to filter on. This is the kind of thing that works fine in a lab/single-region test and then quietly breaks at a client with a stricter regional firewall policy.
- **AZCM error codes are more stable than the surrounding free-text message across agent versions.** When documenting a fix or searching community threads, lead with the code (`AZCM0026`, `AZCM0041`, etc.) — it's the more durable search key. See the [full error/exit code reference](https://learn.microsoft.com/en-us/azure/azure-arc/servers/troubleshoot-agent-onboard).
