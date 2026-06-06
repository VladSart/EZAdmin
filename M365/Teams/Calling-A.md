# Teams Calling — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Teams PSTN calling (Calling Plans, Operator Connect, Direct Routing)
- Teams Phone System (voice-enabled users, call queues, auto attendants)
- Dial pad missing, call quality degradation, one-way audio, dropped calls
- Emergency calling (E911) configuration
- Call routing policies and dial plans
- Teams media transport (STUN/TURN/SRTP)

**Out of scope:**
- Skype for Business Online (deprecated July 2021)
- On-premises PBX integration (covered by Direct Routing if via SBC)
- Physical desk phone hardware repair

**Assumptions:**
- Users licensed with Teams Phone (formerly Phone System add-on) or M365 E5
- Admin has Teams Administrator or Global Administrator role
- Network connectivity to Microsoft 365 confirmed functional

---

## How It Works

<details><summary>Full architecture — Teams calling signal and media path</summary>

### Calling Architecture Overview

Teams calling has two separate traffic paths: **signaling** (call setup, control) and **media** (audio/video/screen share). Problems in either path produce different symptoms.

```
User Device
    │
    ├── Signaling (HTTPS / WSS port 443)
    │       │
    │       ▼
    │   Teams Transport Relay
    │   (signal.azure.com, *.teams.microsoft.com)
    │       │
    │       ▼
    │   Teams Call Controller (Azure)
    │   └── Phone System (voice policy enforcement)
    │           └── PSTN Gateway
    │               ├── Calling Plan (Microsoft PSTN)
    │               ├── Operator Connect (carrier SBC in MS network)
    │               └── Direct Routing (customer SBC on-prem/cloud)
    │
    └── Media (SRTP/DTLS over UDP 3478-3481 or TCP 443)
            │
            ▼ (direct path — ideal)
        Remote peer OR PSTN media gateway
            │
            ▼ (relay path — fallback)
        Microsoft TURN relay
        (*.relay.teams.microsoft.com, UDP 3478)
```

### Signaling Flow (Outbound Call)
1. Teams client sends SIP-over-WebSocket INVITE to Teams transport relay
2. Teams Call Controller processes the INVITE — checks Phone System license, dial plan, call routing policy
3. PSTN routing evaluates dial string against voice routing policies
4. Call routed to: MS Calling Plan gateway | Operator Connect SBC | Customer Direct Routing SBC
5. PSTN completes the call; 200 OK traverses back to Teams client
6. Media negotiated (ICE/STUN) — direct path attempted first, TURN relay fallback

### Media Transport (ICE/STUN/TURN)
Teams uses **Interactive Connectivity Establishment (ICE)** to find the best media path:
1. **Host candidate:** device IP — direct LAN path (best, lowest latency)
2. **SRFLX candidate:** NAT-translated IP via STUN (`stun.l.google.com` is NOT used — Teams uses `*.relay.teams.microsoft.com`)
3. **Relay candidate:** TURN relay at Microsoft edge (fallback when firewall blocks UDP)

**One-way audio** almost always means ICE negotiation completed via relay on one side and direct on the other — asymmetric media path.

### Phone System License Chain

```
Microsoft 365 License (E1/E3/E5)
    └── Teams (included)
        └── Teams Phone (add-on for E1/E3, included in E5)
            └── PSTN Connectivity (one of):
                ├── Microsoft Calling Plan (PSTN-as-a-service)
                ├── Operator Connect (carrier-managed SBC)
                └── Direct Routing (BYO-SBC)
                    └── SBC paired via: Set-CsOnlinePSTNGateway
```

### Direct Routing Call Flow
```
Teams Client
    │ SIP (TLS 5061)
    ▼
Teams SIP proxy (sip.pstnhub.microsoft.com)
    │ SIP (TLS 5061 or 5067)
    ▼
Customer SBC (on-prem or cloud)
    │ ISDN/SIP trunk
    ▼
PSTN / Telco
```
SBC must present a **public TLS certificate** matching the FQDN registered in `Set-CsOnlinePSTNGateway`. Expired or mismatched cert = all Direct Routing calls fail.

### Call Quality Determinants
Microsoft uses **MOS (Mean Opinion Score)** 1.0–5.0 and **network impairment** thresholds:

| Metric | Good | Acceptable | Poor |
|--------|------|-----------|------|
| Packet loss | < 1% | < 5% | > 5% |
| Latency (RTT) | < 100 ms | < 200 ms | > 200 ms |
| Jitter | < 30 ms | < 50 ms | > 50 ms |

</details>

---

## Dependency Stack

```
User License
    └── Teams Phone (Phone System) — REQUIRED for dial pad
        └── PSTN Add-on (one of below):
            ├── Calling Plan (licenses + phone number from Microsoft)
            ├── Operator Connect (carrier manages SBC in MS Azure peering)
            └── Direct Routing (requires SBC, SIP trunk, FQDN, TLS cert)

Teams Client
    └── Network path:
        ├── UDP 3478-3481 (Teams media — must be open)
        ├── TCP 443 (fallback + signaling)
        └── STUN/TURN to *.relay.teams.microsoft.com

Phone System features (require Phone System license):
    ├── Call Queues (requires Resource Account + license)
    ├── Auto Attendants (requires Resource Account + license)
    ├── Voicemail (Cloud Voicemail — requires Exchange Online mailbox)
    └── Emergency Calling (E911 — requires ELIN or dynamic location)

Azure AD
    └── User account (source of Teams identity + license assignment)
        └── Teams admin center reads user from AAD
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Dial pad missing | Phone System license not assigned or not active | `Get-CsOnlineUser -Identity <UPN>` — check `EnterpriseVoiceEnabled` and `TeamsUpgradeEffectiveMode` |
| "You don't have access to calling" | Phone System license unassigned; no PSTN connectivity method | License assignment in M365 admin center |
| One-way audio | NAT/firewall blocking UDP; asymmetric ICE path | Network trace; CQD data; UDP 3478 blocked |
| Dropped calls every ~30 minutes | SIP session timer expired; firewall killing idle UDP | SBC SIP timer config; firewall UDP timeout |
| Can hear outbound but PSTN can't hear us | Media asymmetry — caller behind restrictive NAT | STUN/TURN network test; UDP outbound blocked |
| Call quality degraded (choppy audio) | High jitter or packet loss on LAN or WAN | CQD → Poor Call report; run Network Assessment Tool |
| Can't call specific number | Dial plan not normalizing correctly; PSTN usage policy missing route | Test with `Test-CsOnlineDialPlan`; check call routing |
| Direct Routing calls fail | SBC TLS cert expired; SBC not responding on 5061 | `Get-CsOnlinePSTNGateway -Identity <FQDN>` → check `RunspaceId`, `SBCConnectivity` |
| Voicemail not working | Exchange Online mailbox missing; cloud voicemail not configured | `Get-CsOnlineUser` → check `HostedVoicemailPolicy` |
| Auto attendant not transferring | Resource account missing license; routing misconfigured | Check resource account license; AA call flow |
| E911 calls not routing | ELIN not set; location policy not assigned | `Get-CsEmergencyCallingPolicy`; `Get-CsOnlineLisLocation` |

---

## Validation Steps

**1. Verify user is voice-enabled**
```powershell
Connect-MicrosoftTeams
$user = Get-CsOnlineUser -Identity <UPN>
$user | Select-Object DisplayName, EnterpriseVoiceEnabled, TeamsUpgradeEffectiveMode,
    HostedVoicemailPolicy, TelephoneNumber, LineUri, OnlineVoiceRoutingPolicy,
    DialPlan, EmergencyCallingPolicy
```
*Good:* `EnterpriseVoiceEnabled: True`, `TeamsUpgradeEffectiveMode: TeamsOnly`, `LineUri` populated  
*Bad:* `EnterpriseVoiceEnabled: False` = Phone System not active for user

**2. Check Phone System license**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
$licenses = Get-MgUserLicenseDetail -UserId <UPN>
# Look for MCOEV (Phone System) or MCOEV_VIRTUALUSER (resource account)
$licenses | Where-Object { $_.SkuPartNumber -match "MCOEV" }
```

**3. Verify PSTN connectivity method**
```powershell
# Calling Plan — check phone number assignment
Get-CsPhoneNumberAssignment -AssignedPstnTargetId <UPN>

# Direct Routing — check SBC status
Get-CsOnlinePSTNGateway | Select-Object Identity, Enabled, SipSignalingPort, 
    MaxConcurrentSessions, FailoverTimeSeconds, ForwardCallHistory
```

**4. Validate voice routing policy and PSTN usages**
```powershell
$policy = Get-CsOnlineVoiceRoutingPolicy -Identity (Get-CsOnlineUser <UPN>).OnlineVoiceRoutingPolicy
$policy.OnlinePstnUsages | ForEach-Object {
    $usage = Get-CsOnlinePstnUsage -Identity Global
    $routes = $usage.Usage | Where-Object { $_ -eq $_ }
}
# Simpler — test a number directly:
$dialResult = (Get-CsOnlineUser <UPN>).OnlineVoiceRoutingPolicy | 
    ForEach-Object { Get-CsOnlineVoiceRoutingPolicy -Identity $_ }
```

**5. Test dial plan normalization**
```powershell
# Test how a number gets normalized:
$dialPlan = (Get-CsOnlineUser <UPN>).DialPlan
Test-CsOnlineDialPlan -DialedNumber "+441234567890" -Dialplan $dialPlan
```

**6. Check Direct Routing SBC health**
```powershell
Get-CsOnlinePSTNGateway -Identity <SBC-FQDN> | Select-Object Identity, Enabled,
    SipSignalingPort, MediaBypass, MaxConcurrentSessions, FailoverResponseCodes
# Check SBC connectivity from Teams admin center:
# Teams Admin → Voice → Direct Routing → select SBC → view status
```

**7. Check Call Quality Dashboard (CQD) — PowerShell**
```powershell
# CQD data via PowerShell (requires CQD access):
Connect-MicrosoftTeams
# Pull recent call records via Graph:
Connect-MgGraph -Scopes "CallRecords.Read.All"
Get-MgCommunicationCallRecord -Top 20 | Select-Object Id, StartDateTime, EndDateTime,
    JoinWebUrl, @{N='Duration';E={$_.EndDateTime - $_.StartDateTime}}
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Dial Pad Missing

**1a. Confirm TeamsUpgradeEffectiveMode**
```powershell
(Get-CsOnlineUser -Identity <UPN>).TeamsUpgradeEffectiveMode
# Must be: TeamsOnly
```
If not `TeamsOnly`: the user is in Islands or SfB mode — the dial pad may be suppressed.

**1b. Confirm EnterpriseVoiceEnabled**
```powershell
(Get-CsOnlineUser -Identity <UPN>).EnterpriseVoiceEnabled
# Must be: True
```
If `False`:
```powershell
Set-CsPhoneNumberAssignment -Identity <UPN> -EnterpriseVoiceEnabled $true
```

**1c. Confirm LineUri / phone number**
```powershell
(Get-CsOnlineUser -Identity <UPN>).LineUri
# Must be populated, e.g. tel:+441234567890
```
If empty — assign number:
```powershell
# Calling Plan:
Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber "+441234567890" -PhoneNumberType CallingPlan
# Direct Routing:
Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber "+441234567890" -PhoneNumberType DirectRouting
```

### Phase 2: Call Quality Issues (One-Way Audio / Choppy)

**2a. Run Teams Network Assessment Tool on client**
```
# Download: https://www.microsoft.com/en-us/download/details.aspx?id=103017
NetworkAssessmentTool.exe /connectivitycheck
NetworkAssessmentTool.exe /qualitycheck
# Check results for: packet loss > 1%, jitter > 30ms, RTT > 100ms
```

**2b. Verify UDP 3478–3481 is open outbound**
```powershell
# On client machine:
1..4 | ForEach-Object {
    $port = 3477 + $_
    $result = Test-NetConnection -ComputerName "worldaz.relay.teams.microsoft.com" -Port $port
    [PSCustomObject]@{ Port = $port; TcpTestSucceeded = $result.TcpTestSucceeded }
}
```
*Note: UDP cannot be tested with Test-NetConnection. Use Teams Network Assessment Tool for UDP.*

**2c. Check CQD for the affected user**
```
Teams Admin Center → Analytics & Reports → Call Quality Dashboard
→ Filter by: User Principal Name = <UPN>
→ Sort by: Poor Call %
→ Look for: high Packet Loss Avg, Jitter Avg, Roundtrip Avg
```

**2d. Force media over TCP (temporary workaround)**
If UDP is confirmed blocked and can't be opened quickly:
```powershell
# This degrades quality but allows calls to function:
Set-CsOnlineUser -Identity <UPN> -AllowedDataPath TCP
# Revert when UDP is available:
Set-CsOnlineUser -Identity <UPN> -AllowedDataPath UDP
```

### Phase 3: Direct Routing Failures

**3a. Verify SBC is responding on port 5061**
```powershell
Test-NetConnection -ComputerName <SBC-FQDN> -Port 5061
```

**3b. Check SBC TLS certificate**
```powershell
# Test cert from SBC FQDN:
$tcpClient = New-Object System.Net.Sockets.TcpClient(<SBC-FQDN>, 5061)
$sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream())
$sslStream.AuthenticateAsClient(<SBC-FQDN>)
$cert = $sslStream.RemoteCertificate
[PSCustomObject]@{
    Subject    = $cert.Subject
    Issuer     = $cert.Issuer
    NotAfter   = $cert.GetExpirationDateString()
    Thumbprint = $cert.GetCertHashString()
}
$sslStream.Close(); $tcpClient.Close()
```
*Certificate must: be from public CA, match SBC FQDN exactly, not be expired*

**3c. Test SIP connectivity from Teams side**
```powershell
Get-CsOnlinePSTNGateway -Identity <SBC-FQDN> | Select-Object *
# Check HealthStatus (if available) in Teams Admin Center → Voice → Direct Routing
```

**3d. Review SBC-side SIP logs**
Look for: `401 Unauthorized` (auth issue), `503 Service Unavailable` (SBC overloaded), `408 Request Timeout` (network path), `480 Temporarily Unavailable`

### Phase 4: Call Routing Issues

**4a. Trace a failed call**
```powershell
# Get recent call records for user:
Connect-MgGraph -Scopes "CallRecords.Read.All"
$calls = Get-MgCommunicationCallRecord -Top 10
$calls | Select-Object Id, StartDateTime, @{N='Type';E={$_.Type}}, 
    @{N='Participants';E={$_.Participants.User.DisplayName -join ", "}}
```

**4b. Verify PSTN usage chain**
```powershell
# Voice Routing Policy → PSTN Usage → Voice Routes → PSTN Gateway
$vrp = Get-CsOnlineVoiceRoutingPolicy -Identity (Get-CsOnlineUser <UPN>).OnlineVoiceRoutingPolicy
$vrp.OnlinePstnUsages

$vrp.OnlinePstnUsages | ForEach-Object {
    $usage = $_
    Get-CsOnlineVoiceRoute | Where-Object { $_.OnlinePstnUsages -contains $usage } |
        Select-Object Name, NumberPattern, OnlinePstnGatewayList
}
```

**4c. Check dial plan normalization rules**
```powershell
$dp = Get-CsOnlineDialPlan -Identity (Get-CsOnlineUser <UPN>).DialPlan
$dp.NormalizationRules | Select-Object Name, Pattern, Translation, IsInternalExtension
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable user for Teams calling (Calling Plan)</summary>

**Prerequisites:** Phone System license assigned; phone number available in M365 admin center

```powershell
Connect-MicrosoftTeams

# Step 1: Enable Enterprise Voice
Set-CsPhoneNumberAssignment -Identity "<UPN>" -EnterpriseVoiceEnabled $true

# Step 2: Assign phone number (Calling Plan)
Set-CsPhoneNumberAssignment -Identity "<UPN>" -PhoneNumber "+<E164Number>" -PhoneNumberType CallingPlan

# Step 3: Assign voice routing policy (if using Direct Routing alongside)
Grant-CsOnlineVoiceRoutingPolicy -Identity "<UPN>" -PolicyName "<PolicyName>"

# Step 4: Assign dial plan (if tenant-level isn't sufficient)
Grant-CsTenantDialPlan -Identity "<UPN>" -PolicyName "<DialPlanName>"

# Step 5: Verify
Get-CsOnlineUser -Identity "<UPN>" | Select-Object EnterpriseVoiceEnabled, LineUri, 
    OnlineVoiceRoutingPolicy, DialPlan, TeamsUpgradeEffectiveMode
```

**Rollback:**
```powershell
Remove-CsPhoneNumberAssignment -Identity "<UPN>" -PhoneNumber "+<E164Number>" -PhoneNumberType CallingPlan
Set-CsPhoneNumberAssignment -Identity "<UPN>" -EnterpriseVoiceEnabled $false
```

</details>

<details><summary>Playbook 2 — Enable user for Direct Routing</summary>

**Prerequisites:** SBC configured and registered; voice routing policy and PSTN usages exist

```powershell
Connect-MicrosoftTeams

# Step 1: Enable Enterprise Voice
Set-CsPhoneNumberAssignment -Identity "<UPN>" -EnterpriseVoiceEnabled $true

# Step 2: Assign phone number (Direct Routing)
Set-CsPhoneNumberAssignment -Identity "<UPN>" -PhoneNumber "+<E164Number>" -PhoneNumberType DirectRouting

# Step 3: Assign voice routing policy
Grant-CsOnlineVoiceRoutingPolicy -Identity "<UPN>" -PolicyName "<PolicyName>"

# Step 4: Assign online voice routing (dial plan if needed)
Grant-CsTenantDialPlan -Identity "<UPN>" -PolicyName "<DialPlanName>"

# Step 5: Test the route
$dp = (Get-CsOnlineUser "<UPN>").DialPlan
Test-CsOnlineDialPlan -DialedNumber "+441234567890" -Dialplan $dp

# Step 6: Verify SBC
Get-CsOnlinePSTNGateway -Identity "<SBC-FQDN>" | Select-Object Identity, Enabled, 
    SipSignalingPort, MediaBypass
```

</details>

<details><summary>Playbook 3 — Register / update SBC for Direct Routing</summary>

```powershell
Connect-MicrosoftTeams

# Register new SBC:
New-CsOnlinePSTNGateway -Identity "<SBC-FQDN>" `
    -Enabled $true `
    -SipSignalingPort 5061 `
    -MaxConcurrentSessions 100 `
    -MediaBypass $false `
    -ForwardCallHistory $true `
    -ForwardPai $true

# Update existing SBC (e.g., after cert renewal):
Set-CsOnlinePSTNGateway -Identity "<SBC-FQDN>" -Enabled $true

# Create PSTN usage and route if not existing:
Set-CsOnlinePstnUsage -Identity Global -Usage @{Add="<UsageName>"}

New-CsOnlineVoiceRoute -Identity "<RouteName>" `
    -NumberPattern "^\+44" `
    -OnlinePstnGatewayList "<SBC-FQDN>" `
    -OnlinePstnUsages "<UsageName>" `
    -Priority 1

# Create and assign voice routing policy:
New-CsOnlineVoiceRoutingPolicy -Identity "<PolicyName>" -OnlinePstnUsages "<UsageName>"
```

**Rollback:**
```powershell
Remove-CsOnlinePSTNGateway -Identity "<SBC-FQDN>"
```

</details>

<details><summary>Playbook 4 — Call queue / auto attendant resource account setup</summary>

```powershell
Connect-MicrosoftTeams

# Step 1: Create resource account
New-CsOnlineApplicationInstance -UserPrincipalName "<ra-name>@<tenant>.onmicrosoft.com" `
    -DisplayName "<DisplayName>" `
    -ApplicationId "11cd3e2e-fccb-42ad-ad00-878b93575e07"  # Call Queue
    # Auto Attendant: ce933385-9390-45d1-9512-c8d228074e07

# Step 2: Sync (wait 30 seconds after creation)
Start-Sleep -Seconds 30
Sync-CsOnlineApplicationInstance -ObjectId (Get-CsOnlineUser "<ra-UPN>").ObjectId

# Step 3: Assign Virtual User license in M365 admin center (Teams Phone Resource Account)
# Then assign phone number:
Set-CsPhoneNumberAssignment -Identity "<ra-UPN>" -PhoneNumber "+<E164Number>" `
    -PhoneNumberType DirectRouting  # or CallingPlan

# Step 4: Create call queue referencing resource account
New-CsCallQueue -Name "<QueueName>" `
    -UseDefaultMusicOnHold $true `
    -RoutingMethod Attendant `
    -AllowOptOut $true `
    -AgentAlertTime 30

# Step 5: Associate resource account to call queue
New-CsOnlineApplicationInstanceAssociation -Identities "<ra-UPN>" `
    -ConfigurationId (Get-CsCallQueue -NameFilter "<QueueName>").Identity `
    -ConfigurationType CallQueue
```

</details>

---

## Evidence Pack

```powershell
<#
  EZAdmin — Teams Calling Evidence Collector
  Collects full calling configuration for escalation to Microsoft Support
  Run as: Teams Administrator or Global Administrator
#>

param(
    [Parameter(Mandatory)]
    [string]$UserUPN
)

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$report    = @{}

Connect-MicrosoftTeams
Connect-MgGraph -Scopes "User.Read.All","CallRecords.Read.All"

# 1. User calling config
$csUser = Get-CsOnlineUser -Identity $UserUPN
$report.UserCallingConfig = $csUser | Select-Object DisplayName, UserPrincipalName,
    EnterpriseVoiceEnabled, TeamsUpgradeEffectiveMode, LineUri,
    OnlineVoiceRoutingPolicy, DialPlan, HostedVoicemailPolicy,
    EmergencyCallingPolicy, EmergencyCallRoutingPolicy,
    TelephoneNumber, OnPremLineUri

# 2. License check
$report.Licenses = Get-MgUserLicenseDetail -UserId $UserUPN |
    Select-Object SkuPartNumber, SkuId,
    @{N='ServicePlans';E={$_.ServicePlans | Select-Object ServicePlanName, ProvisioningStatus}}

# 3. Voice routing policy detail
if ($csUser.OnlineVoiceRoutingPolicy) {
    $vrp = Get-CsOnlineVoiceRoutingPolicy -Identity $csUser.OnlineVoiceRoutingPolicy
    $report.VoiceRoutingPolicy = $vrp
    $report.VoiceRoutes = $vrp.OnlinePstnUsages | ForEach-Object {
        $usage = $_
        Get-CsOnlineVoiceRoute | Where-Object { $_.OnlinePstnUsages -contains $usage }
    }
}

# 4. Dial plan
if ($csUser.DialPlan) {
    $report.DialPlan = Get-CsOnlineDialPlan -Identity $csUser.DialPlan |
        Select-Object Identity, NormalizationRules
}

# 5. Phone number assignment
$report.PhoneNumberAssignment = Get-CsPhoneNumberAssignment -AssignedPstnTargetId $UserUPN

# 6. SBC status (Direct Routing)
$report.SBCs = Get-CsOnlinePSTNGateway | Select-Object Identity, Enabled,
    SipSignalingPort, MaxConcurrentSessions, FailoverTimeSeconds,
    MediaBypass, ForwardCallHistory, GatewaySiteId

# 7. Emergency calling
$report.EmergencyCallingPolicy = Get-CsEmergencyCallingPolicy -Identity ($csUser.EmergencyCallingPolicy ?? "Global")
$report.EmergencyCallRoutingPolicy = Get-CsEmergencyCallRoutingPolicy

# 8. Recent call records (last 10)
$report.RecentCalls = Get-MgCommunicationCallRecord -Top 10 |
    Select-Object Id, StartDateTime, EndDateTime, Type, Version

# 9. Export
$outputPath = "C:\Temp\TeamsCallingEvidence-$UserUPN-$timestamp.json"
$report | ConvertTo-Json -Depth 6 | Out-File $outputPath -Encoding utf8
Write-Host "[OK] Evidence saved to $outputPath" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Get user calling status | `Get-CsOnlineUser -Identity <UPN> \| Select EnterpriseVoiceEnabled, LineUri, TeamsUpgradeEffectiveMode` |
| Enable Enterprise Voice | `Set-CsPhoneNumberAssignment -Identity <UPN> -EnterpriseVoiceEnabled $true` |
| Assign Calling Plan number | `Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber +<E164> -PhoneNumberType CallingPlan` |
| Assign Direct Routing number | `Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber +<E164> -PhoneNumberType DirectRouting` |
| Assign voice routing policy | `Grant-CsOnlineVoiceRoutingPolicy -Identity <UPN> -PolicyName <Name>` |
| Assign dial plan | `Grant-CsTenantDialPlan -Identity <UPN> -PolicyName <Name>` |
| Test dial plan | `Test-CsOnlineDialPlan -DialedNumber <number> -Dialplan <name>` |
| List SBCs | `Get-CsOnlinePSTNGateway \| Select Identity, Enabled, SipSignalingPort` |
| Register SBC | `New-CsOnlinePSTNGateway -Identity <FQDN> -Enabled $true -SipSignalingPort 5061` |
| Check voice routes | `Get-CsOnlineVoiceRoute \| Select Name, NumberPattern, OnlinePstnGatewayList` |
| List available phone numbers | `Get-CsPhoneNumberAssignment -CapabilitiesContain VoiceApplicationAssignment` |
| List all voice routing policies | `Get-CsOnlineVoiceRoutingPolicy \| Select Name, OnlinePstnUsages` |
| Get PSTN usages | `Get-CsOnlinePstnUsage -Identity Global \| Select Usage` |
| List call queues | `Get-CsCallQueue \| Select Name, Identity` |
| List auto attendants | `Get-CsAutoAttendant \| Select Name, Identity` |

---

## 🎓 Learning Pointers

- **Phone System vs. Calling Plan:** Phone System (MCOEV license) enables the PBX features (voicemail, call queues, dial pad). A calling plan or Direct Routing is needed *separately* to connect to the PSTN. Engineers often enable Phone System but forget to configure PSTN connectivity — resulting in an active dial pad that can't dial out. [Teams Phone overview](https://learn.microsoft.com/en-us/microsoftteams/what-is-phone-system-in-office-365)

- **E.164 format is mandatory:** All phone number assignments in Teams require E.164 format (`+` followed by country code, no spaces or dashes). The most common onboarding error is assigning a local format number — Teams rejects it silently in some clients. Always verify with `Get-CsPhoneNumberAssignment`. [Number format requirements](https://learn.microsoft.com/en-us/microsoftteams/getting-phone-numbers-for-your-users)

- **Direct Routing cert expiry kills all calls:** The SBC TLS certificate presented to Teams SIP proxy must be valid, publicly trusted, and exactly match the FQDN registered in `New-CsOnlinePSTNGateway`. Set a certificate expiry reminder 30 days before the cert expires. Monitor via `Get-CsOnlinePSTNGateway` health status. [Direct Routing SBC cert requirements](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan#public-trusted-certificate-for-the-sbc)

- **CQD is the authoritative source for call quality:** The Call Quality Dashboard in Teams Admin Center (and `cqd.teams.microsoft.com`) provides per-call MOS scores, packet loss, jitter, and roundtrip time. Always pull CQD data before escalating a call quality complaint — it tells you whether the problem is inside or outside the Microsoft network. [CQD documentation](https://learn.microsoft.com/en-us/microsoftteams/cqd-teams-utilization-report)

- **Media Bypass reduces latency for Direct Routing:** Media Bypass allows the Teams client to send media directly to the SBC, bypassing the Teams media relay. This significantly reduces audio latency for on-premises users. Requires SBC support and correct network configuration. Enable with `Set-CsOnlinePSTNGateway -Identity <FQDN> -MediaBypass $true`. [Media Bypass overview](https://learn.microsoft.com/en-us/microsoftteams/direct-routing-media-bypass)

- **TeamsOnly mode is required for calling:** If a user's `TeamsUpgradeEffectiveMode` is anything other than `TeamsOnly` (e.g., `Islands`, `SfBWithTeamsCollab`), the Teams dial pad may not appear. In coexistence scenarios, the tenant policy must be `TeamsOnly` or the user must be individually upgraded. [Upgrade modes](https://learn.microsoft.com/en-us/microsoftteams/migration-interop-guidance-for-teams-with-skype)
