# Entra Global Secure Access (GSA) — Hotfix Runbook (Mode B: Ops)
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

Run these first. Interpret results to choose a fix path.

```powershell
# 1. Check Global Secure Access client service state (on the affected device)
Get-Service "Global Secure Access Client" | Select-Object Name, Status, StartType

# 2. Check which traffic forwarding profiles are enabled for the tenant (Graph)
Get-MgBetaNetworkAccessForwardingProfile | Select-Object Name, TrafficForwardingType, State

# 3. Check the user's Conditional Access policies requiring GSA / compliant network
Get-MgIdentityConditionalAccessPolicy |
    Where-Object { $_.Conditions.ClientAppTypes -contains "all" } |
    Select-Object DisplayName, State

# 4. Check device enrollment / registration status for the GSA client (must be Entra-registered at minimum)
dsregcmd /status | Select-String "AzureAdJoined|WorkplaceJoined|AzureAdPrt"

# 5. Check remote network / connector health (Private Access only)
Get-MgBetaNetworkAccessConnectorGroup | Select-Object Name, Region
Get-MgBetaNetworkAccessConnector -All | Select-Object MachineName, Status, Version
```

| Result | Action |
|--------|--------|
| GSA client service `Stopped` | → [Fix 1 — Restart / Reinstall GSA Client](#fix-1--restart--reinstall-gsa-client) |
| Forwarding profile `State = disabled` | → [Fix 2 — Enable Traffic Forwarding Profile](#fix-2--enable-traffic-forwarding-profile) |
| Connector `Status = inactive` (Private Access) | → [Fix 3 — Restore Private Access Connector](#fix-3--restore-private-access-connector) |
| Device not Entra registered/joined | → [Fix 4 — Fix Device Identity Prerequisite](#fix-4--fix-device-identity-prerequisite) |
| CA policy requiring GSA blocking sign-in unexpectedly | → [Fix 5 — Adjust Conditional Access Network Compliance](#fix-5--adjust-conditional-access-network-compliance) |
| All checks pass, traffic still not tunneling | → Escalate — capture client logs via `GlobalSecureAccessClient` log collector and open a support case |

---
## Dependency Cascade

<details><summary>What must be true for GSA to tunnel traffic correctly</summary>

```
Entra ID (Identity)
  └── Tenant licensed for Microsoft Entra Internet Access / Private Access
        └── Traffic Forwarding Profiles enabled
              ├── Microsoft 365 traffic profile (Internet Access)
              ├── Internet Access traffic profile
              └── Private Access traffic profile
                    └── Enterprise Application(s) published via Private Access
                          └── Private Network Connector (on-prem or IaaS)
                                ├── Connector service running
                                ├── Outbound 443 to Entra network access service
                                └── Line-of-sight to target internal resource
        └── Device
              ├── Entra ID registered / joined / hybrid joined (minimum: registered)
              ├── Global Secure Access Client installed and running
              ├── Client signed in with the correct user (single sign-in binds tunnel to identity)
              └── Local network allows outbound to GSA edge (no conflicting VPN/proxy forcing traffic elsewhere)
        └── Conditional Access (optional but common)
              └── Policy requiring "compliant network" / GSA-tagged traffic
                    └── Enforced only for scoped apps/users — misscoping here blocks unrelated traffic
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm the GSA client is installed and running**
```powershell
Get-Service "Global Secure Access Client" -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType
```
Expected: `Status = Running`, `StartType = Automatic`. If service missing entirely, the client was never installed — deploy via Intune Win32 app or manual installer.

**Step 2 — Confirm sign-in state inside the client**
```powershell
# Client exposes status via its tray icon UI; for scripted checks, verify token acquisition indirectly:
dsregcmd /status | Select-String "AzureAdPrt"
```
Expected: `AzureAdPrt : YES`. GSA relies on the same token infrastructure — no PRT means no authenticated tunnel, regardless of client service state.

**Step 3 — Confirm traffic forwarding profiles are enabled tenant-wide**
```powershell
Get-MgBetaNetworkAccessForwardingProfile | Select-Object Name, TrafficForwardingType, State
```
Expected: The profile(s) relevant to the reported issue (`microsoft365`, `internet`, `private`) show `State = enabled`. A disabled profile means the client will not tunnel that traffic category at all, even if perfectly healthy.

**Step 4 — For Private Access issues, confirm connector health**
```powershell
Get-MgBetaNetworkAccessConnector -All | Select-Object MachineName, Status, Version, LastHeartbeat
```
Expected: `Status = active`, recent `LastHeartbeat` (within last few minutes). A connector that's `inactive` breaks every Private Access app routed through it — check this before troubleshooting individual app access.

**Step 5 — Confirm the specific Enterprise Application is published and assigned**
```powershell
Get-MgBetaNetworkAccessApplication -All |
    Select-Object DisplayName, DestinationHost, ConnectorGroupId
```
Expected: The target app is listed with the correct destination host/port and a valid connector group reference. Missing entries mean the app was never published for Private Access — this is an admin configuration gap, not a connectivity fault.

---
## Common Fix Paths

<details><summary>Fix 1 — Restart / Reinstall GSA Client</summary>

**When:** Client service stopped, crashed, or traffic isn't tunneling despite everything upstream looking healthy.

```powershell
# Restart the client service
Restart-Service "Global Secure Access Client" -Force

# If restart doesn't resolve — check client logs
Get-WinEvent -LogName "Microsoft-Global Secure Access Client/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object LevelDisplayName -in "Error","Warning"

# Full reinstall (if service repeatedly crashes)
# Uninstall via Programs and Features or:
Get-Package "Global Secure Access Client" -ErrorAction SilentlyContinue | Uninstall-Package -Force
# Then redeploy via Intune Win32 app assignment or the standalone MSI from admin center
```

**Rollback:** Reinstalling is non-destructive to user data; the client re-authenticates on next sign-in. No user profile impact.

</details>

<details><summary>Fix 2 — Enable Traffic Forwarding Profile</summary>

**When:** Specific traffic category (M365, Internet, or Private) isn't being tunneled tenant-wide.

```powershell
# Identify the profile that needs enabling
$profile = Get-MgBetaNetworkAccessForwardingProfile | Where-Object Name -eq "Microsoft 365 access profile"

# Enable it
Update-MgBetaNetworkAccessForwardingProfile -ForwardingProfileId $profile.Id -BodyParameter @{
    state = "enabled"
}
```

**Rollback:** Disabling the profile again reverts to direct (non-tunneled) routing for that traffic category — no persistent state change on client devices.

</details>

<details><summary>Fix 3 — Restore Private Access Connector</summary>

**When:** Connector shows `inactive` or stale `LastHeartbeat`, breaking Private Access to on-prem apps.

```powershell
# On the connector VM/server — check the service directly
Get-Service "Microsoft Entra private network connector" | Select-Object Name, Status

# Restart the connector service
Restart-Service "Microsoft Entra private network connector" -Force

# Confirm outbound connectivity from the connector host
Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
Test-NetConnection -ComputerName "graph.microsoft.com" -Port 443

# If still inactive after restart, redeploy the connector agent from the admin center
# (Global Secure Access > Connectors > Download connector)
```

**Rollback:** Restarting the connector service briefly interrupts all Private Access traffic through that connector — schedule during low-usage window if possible. Non-destructive.

</details>

<details><summary>Fix 4 — Fix Device Identity Prerequisite</summary>

**When:** Device is not Entra registered/joined; GSA client cannot establish an authenticated tunnel.

```powershell
# Check current state
dsregcmd /status

# For an unregistered device, trigger registration (Entra ID join / hybrid join per org policy)
# Cloud-native devices: re-run OOBE or Settings > Accounts > Access work or school > Connect
# Hybrid: confirm the device is domain-joined first, then Entra Connect sync brings the device object across

# Force a Workplace Join / device registration retry
dsregcmd /leave
dsregcmd /join
```

**Rollback:** `dsregcmd /leave` temporarily removes device registration — re-run `dsregcmd /join` (or sign out/in for automatic re-registration) to restore. Coordinate with the user since this briefly affects SSO.

</details>

<details><summary>Fix 5 — Adjust Conditional Access Network Compliance</summary>

**When:** A CA policy requiring GSA-tunneled/compliant network traffic is blocking users who legitimately shouldn't be in scope yet (e.g., pilot group scoping error).

```powershell
# Identify the policy
$policy = Get-MgIdentityConditionalAccessPolicy | Where-Object DisplayName -like "*Compliant Network*"

# Review current scope
$policy | Select-Object DisplayName, State, Conditions

# Narrow scope to intended pilot group only (example: update assignment)
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter @{
    conditions = @{
        users = @{
            includeGroups = @("<pilot-group-object-id>")
        }
    }
}
```

**Rollback:** Revert `includeGroups`/`includeUsers` to the prior assignment stored in your change record before editing. Always snapshot the existing CA policy JSON before modifying.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== GLOBAL SECURE ACCESS ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s): _______________
Tenant ID: _______________
Device Name: _______________
Device Join Type: [ ] Entra ID Joined  [ ] Entra Hybrid Joined  [ ] Registered Only

SYMPTOM:
[ ] Traffic not tunneling (Internet Access)
[ ] Traffic not tunneling (M365 Access)
[ ] Private Access app unreachable
[ ] Client won't install / crashes
[ ] Conditional Access blocking unexpectedly
[ ] Other: _______________

TRIAGE RESULTS:
GSA Client Service Status: _______________
PRT Status (dsregcmd): _______________
Forwarding Profile State(s): _______________
Connector Status (if Private Access): _______________
Affected Enterprise App (if Private Access): _______________

ACTIONS TAKEN:
_______________

CORRELATION ID: _______________
CLIENT VERSION: _______________
CONNECTOR VERSION (if applicable): _______________
```

---
## 🎓 Learning Pointers

- **GSA is two products under one brand**: Microsoft Entra Internet Access (SWG-style protection for internet/M365 traffic) and Microsoft Entra Private Access (ZTNA-style replacement for VPN/on-prem access) share the same client and forwarding-profile framework but solve different problems — always confirm which profile the reported issue actually touches before troubleshooting. Reference: [What is Global Secure Access](https://learn.microsoft.com/en-us/entra/global-secure-access/overview-what-is-global-secure-access)
- **Traffic forwarding profiles are the master switch**: A perfectly healthy client and connector will still pass traffic untunneled if the relevant forwarding profile is disabled at the tenant level — this is the single most common first check that gets skipped. Reference: [Traffic forwarding profiles](https://learn.microsoft.com/en-us/entra/global-secure-access/concept-traffic-forwarding)
- **PRT dependency is easy to miss**: Because GSA piggybacks on the same identity plumbing as everything else in Entra ID, a broken PRT (see `EntraID/Troubleshooting/PRT-Issues-B.md`) silently breaks GSA tunneling too — always cross-check PRT status before assuming a GSA-specific fault.
- **Private Access connectors are the on-prem single point of failure**: Unlike Internet Access (fully cloud-side), Private Access depends on customer-deployed connector software with the same operational characteristics as an Entra App Proxy connector (see `EntraID/Troubleshooting/AppProxy-B.md`) — treat connector health checks with the same priority. Reference: [Private network connector](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-connectors)
- **Conditional Access "compliant network" is a new grant, not a replacement for named locations**: The GSA-aware CA condition evaluates whether traffic is verified as tunneled through GSA, which is a materially different signal than IP-based named locations — mixing the two in policy design without testing in report-only mode first is a common cause of unexpected lockouts. Reference: [Conditional Access network compliance](https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-target-resources-conditional-access)
