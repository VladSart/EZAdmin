# Azure Arc-Enabled Servers — Hotfix Runbook (Mode B: Ops)
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

Run these on the affected server (elevated). `azcmagent` ships with the Connected Machine agent — no module install needed.

```powershell
# 1. Current connection status, agent version, last heartbeat
azcmagent show

# 2. Run the full built-in connectivity/health check (network, DNS, proxy, cert store)
azcmagent check

# 3. Is the HIMDS (Hybrid Instance Metadata Service) service running?
Get-Service himds | Select-Object Name, Status, StartType

# 4. Tail the verbose agent log for recent errors
Get-Content "$env:ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log" -Tail 100

# 5. Confirm the machine object still exists in Azure and check its portal status
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" |
    Select-Object Name, Status, LastStatusChange, AgentVersion
```

**Interpretation:**

| Finding | Action |
|---|---|
| `azcmagent show` → `Agent Status: Disconnected` | Fix 1 — heartbeat/connectivity break |
| `azcmagent check` reports blocked endpoint | Fix 2 — firewall/proxy/DNS blocking a required URL |
| `himds` service stopped or crash-looping | Fix 3 — restart/repair the agent services |
| Log shows `AZCM0041`/`AZCM0012` (invalid credentials/token) | Fix 4 — re-onboard with valid credentials |
| Azure-side `Status` shows `Expired` or object missing | Fix 5 — machine identity expired after 45-90 days offline, re-onboard |
| Agent connected but a specific extension (AMA, MDE, Update Manager) not working | Fix 6 — per-extension health check |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Server (physical, VM outside Azure, or on another cloud)
    │
    ▼
Connected Machine agent installed + HIMDS service running
    │
    ▼
Outbound HTTPS 443 to required endpoints
    │  ├── login.microsoftonline.com / *.login.microsoft.com / pas.windows.net  (Entra ID auth)
    │  ├── management.azure.com                                                 (ARM — connect/disconnect only)
    │  ├── *.his.arc.azure.com                                                  (metadata + hybrid identity — always)
    │  ├── *.guestconfiguration.azure.com                                       (extension mgmt — always)
    │  └── guestnotificationservice.azure.com / *.servicebus.windows.net        (notifications)
    │
    ▼
Microsoft Entra managed identity for the machine (issued at onboarding, auto-renews while heartbeats continue)
    │
    ▼
Heartbeat every 5 min → Azure marks "Disconnected" after 15 min silence
    │
    ▼
Azure RBAC: caller/service principal has "Azure Connected Machine Onboarding" (or Contributor) role at onboarding time
    │
    ▼
Resource providers registered on the subscription (Microsoft.HybridCompute, Microsoft.GuestConfiguration, Microsoft.HybridConnectivity)
    │
    ▼
Extensions (AMA, MDE.Windows/Linux, Update Manager, Defender for Cloud) layered on top of a healthy connection
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm agent status and last heartbeat**
```powershell
azcmagent show
```
Expected: `Agent Status: Connected`. If `Disconnected`, the agent process itself is running but hasn't reached Azure in 15+ minutes — move to Step 2. If the command errors entirely, the agent service itself is down — go to Fix 3.

**Step 2 — Run the built-in connectivity check**
```powershell
azcmagent check
```
This actively tests every required endpoint (Entra ID, ARM, `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`, notification service) and reports pass/fail per URL, plus proxy and TLS configuration. This is the single most useful command in this runbook — run it before anything else if unsure.
Bad: any endpoint shows `Failed` — that's your root cause, go to Fix 2.

**Step 3 — Check the HIMDS service**
```powershell
Get-Service himds
# Windows service name is 'himds'; on Linux, check: systemctl status himds
```
Expected: `Running`. If stopped/crash-looping, the agent cannot authenticate to Azure at all (HIMDS issues the local managed-identity token) — go to Fix 3.

**Step 4 — Check the verbose log for a specific AZCM error code**
```powershell
Get-Content "$env:ProgramData\AzureConnectedMachineAgent\Log\azcmagent.log" -Tail 200 | Select-String "AZCM\d{4}"
```
Match the code against the table in `AzureArc-A.md` → Symptom → Cause Map. Common ones: `AZCM0026` (network/DNS), `AZCM0041` (bad credentials), `AZCM0067` (already connected — needs `reconnect` not `connect`), `AZCM0081` (managed identity cert download failed).

**Step 5 — Confirm the Azure-side resource still exists and its status**
```powershell
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" |
    Select-Object Name, Status, LastStatusChange, AgentVersion, OSType
```
Expected: `Status: Connected`, `LastStatusChange` within the last 5-15 minutes. If the resource is missing entirely, someone deleted it in the portal/CLI while the local agent still thinks it's connected — go to Fix 5.

**Step 6 — Check RBAC/resource provider registration (onboarding-time failures only)**
```powershell
Get-AzResourceProvider -ProviderNamespace Microsoft.HybridCompute | Select-Object ProviderNamespace, RegistrationState
Get-AzRoleAssignment -SignInName "<upn-or-spn>" | Where-Object { $_.RoleDefinitionName -like "*Connected Machine*" }
```
Only relevant during first-time onboarding failures, not for an already-connected machine that dropped.

---
## Common Fix Paths

<details><summary>Fix 1 — Agent shows "Disconnected" (heartbeat lost, agent process otherwise healthy)</summary>

```powershell
# Confirm current state
azcmagent show

# Restart the agent service stack (Windows)
Restart-Service himds -Force
Restart-Service GCArcService -Force -ErrorAction SilentlyContinue
Restart-Service ExtensionService -Force -ErrorAction SilentlyContinue

# Linux equivalent
# sudo systemctl restart himds gcad extd

# Re-check after 2-3 minutes for the next heartbeat
Start-Sleep -Seconds 180
azcmagent show
```

If it reconnects, this was a transient service hiccup — no further action. If it stays disconnected, go to Fix 2 (network) or Fix 3 (service-level repair).

</details>

<details><summary>Fix 2 — A required endpoint is blocked (firewall/proxy/DNS)</summary>

```powershell
azcmagent check
# Read the per-endpoint results — note which specific URL(s) failed

# Manually confirm DNS + TCP 443 for the flagged endpoint
Resolve-DnsName "management.azure.com"
Test-NetConnection -ComputerName "management.azure.com" -Port 443

# If behind a proxy, confirm the agent's proxy config
azcmagent config list
azcmagent config set proxy.url "http://<proxy>:<port>"

# Confirm the required service tags are allow-listed on the firewall/NSG:
#   AzureActiveDirectory, AzureTrafficManager, AzureResourceManager,
#   AzureArcInfrastructure, Storage, AzureFrontDoor.Frontend
# If filtering AzureArcInfrastructure by IP, you must allow the FULL service
# tag range (not just the local region's sub-range) — global components live outside it.
```

**Rollback:** Proxy config changes are non-destructive — `azcmagent config clear proxy.url` reverts.

</details>

<details><summary>Fix 3 — HIMDS/agent service crash-looping or stopped</summary>

```powershell
Get-Service himds, GCArcService, ExtensionService

# Check Windows Event Log for the agent's own crash/error entries
Get-WinEvent -LogName "Application" -MaxEvents 50 |
    Where-Object { $_.ProviderName -like "*AzureConnectedMachineAgent*" -or $_.ProviderName -like "*himds*" }

# Try a clean service restart first
Restart-Service himds -Force

# If it won't stay running, repair by re-running the installer over the existing install
# (does not remove the existing Azure resource or require re-registration if resource still exists)
$installer = "$env:TEMP\AzureConnectedMachineAgent.msi"
Invoke-WebRequest -Uri "https://aka.ms/AzureConnectedMachineAgent" -OutFile $installer
Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn" -Wait
Restart-Service himds -Force
```

**Rollback:** Reinstalling over an existing agent is non-destructive to the Azure-side resource. If problems persist after reinstall, fully disconnect and re-onboard (Fix 5).

</details>

<details><summary>Fix 4 — Invalid/expired credentials (AZCM0041, AZCM0012)</summary>

```powershell
# For interactive/device-code onboarding — token expired, just retry the connect
azcmagent connect --resource-group "<rg>" --tenant-id "<tenantId>" `
    --location "<region>" --subscription-id "<subId>"

# For service-principal-based (at-scale) onboarding — verify the SPN itself first
# In Entra: check the app registration hasn't had its secret expire or been disabled

# If already connected and just re-authenticating:
azcmagent connect --service-principal-id "<spnAppId>" --service-principal-secret "<spnSecret>" `
    --resource-group "<rg>" --tenant-id "<tenantId>" --location "<region>" --subscription-id "<subId>" `
    --verbose
```

If you get `AZCM0067` ("machine is already connected"), don't force a fresh connect — use `azcmagent disconnect` first, or better, `azcmagent connect` will fail cleanly telling you to do that.

**Rollback:** None required — credential retry is non-destructive.

</details>

<details><summary>Fix 5 — Azure-side resource deleted/expired, local agent orphaned</summary>

```powershell
# Confirm the resource is genuinely gone
Get-AzConnectedMachine -ResourceGroupName "<rg>" -Name "<machineName>" -ErrorAction SilentlyContinue

# Force-clean the local agent state (resource no longer exists in Azure)
azcmagent disconnect --force-local-only

# Re-onboard fresh
azcmagent connect --resource-group "<rg>" --tenant-id "<tenantId>" `
    --location "<region>" --subscription-id "<subId>"
```

**Context:** if a machine has been disconnected for 45-90 days, its Microsoft Entra managed-identity registration expires outright and the agent can never reconnect on its own — this Fix path (disconnect --force-local-only, then reconnect) is the only way out, and it creates a **new** resource ID. Any alerting/automation keyed to the old resource ID must be updated.

**Rollback:** N/A — this is itself the recovery action for an already-broken state.

</details>

<details><summary>Fix 6 — Agent connected, but a specific extension isn't working (AMA / MDE / Update Manager)</summary>

```powershell
# List installed extensions and their provisioning state
Get-AzConnectedMachineExtension -ResourceGroupName "<rg>" -MachineName "<machineName>" |
    Select-Object Name, ProvisioningState

# Check extension-specific logs on the machine (Windows path shown; extension name varies)
Get-ChildItem "$env:ProgramData\GuestConfig\extension_logs" -Recurse -Filter "*.log" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5

# Force a reinstall of a stuck extension
Remove-AzConnectedMachineExtension -ResourceGroupName "<rg>" -MachineName "<machineName>" -Name "AzureMonitorWindowsAgent"
New-AzConnectedMachineExtension -ResourceGroupName "<rg>" -MachineName "<machineName>" -Name "AzureMonitorWindowsAgent" `
    -Publisher "Microsoft.Azure.Monitor" -ExtensionType "AzureMonitorWindowsAgent" -Location "<region>"
```

**Rollback:** Removing and re-adding an extension is safe; it does not affect the core agent connection or other extensions.

</details>

---
## Escalation Evidence

```
=== Azure Arc-Enabled Server Escalation Pack ===
Date/Time:                _______________
Machine name:              _______________
Resource group / Sub:      _______________
OS:                        _______________
Agent version:             _______________

azcmagent show output:     Connected / Disconnected / Error
azcmagent check result:    PASS / FAIL (endpoint: _______________)
himds service status:      Running / Stopped / Crash-looping
Last heartbeat/status change: _______________
AZCM error code (if any):  _______________

Azure-side resource exists (Get-AzConnectedMachine): YES / NO
Time disconnected (if known): _______________ (>45 days? YES / NO)

Actions taken so far:
1.
2.
3.

Escalation contact: Microsoft Support via Azure Portal > Azure Arc > Machine > New Support Request
Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/troubleshoot-agent-onboard
```

---
## 🎓 Learning Pointers

- **`azcmagent check` is the single best first command.** It actively probes every required endpoint (Entra ID, ARM, `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`, notification service) rather than making you guess which one is blocked — run it before manual DNS/port testing. See [Connected Machine agent network requirements](https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements).
- **Disconnected ≠ broken agent.** "Disconnected" specifically means the agent process is fine but hasn't sent a heartbeat Azure received in 15+ minutes — it's a connectivity/service symptom, not proof the agent itself crashed. Check `himds` status separately.
- **45-90 days offline is a hard cliff, not a warning.** Unlike most Azure resource states, an expired Entra managed identity for an Arc machine cannot self-heal — it requires `azcmagent disconnect --force-local-only` + fresh `connect`, which creates a new resource ID. Alert on disconnection well before that window, not after.
- **AZCM error codes map directly to remediation — don't guess from the free-text message alone.** The `AZCM####` code in the log/console output is more reliable to search/match than the surrounding English text, which can vary by agent version. See the [full error code table](https://learn.microsoft.com/en-us/azure/azure-arc/servers/troubleshoot-agent-onboard).
- **Service tag filtering has a trap:** filtering `AzureArcInfrastructure` by individual regional sub-ranges (e.g. `AzureArcInfrastructure.EastUS`) misses global components of the service — the full, unscoped service tag range must be allowed. This is a common "works in the lab, fails behind the real firewall" gap.
- **This is a prerequisite layer for Sentinel/Defender for Cloud onboarding of non-Azure servers** — see `Security/Sentinel/DataConnectors-A.md` and cross-reference here whenever a hybrid/multi-cloud data connector or CSPM scan isn't picking up an expected server.
