# Teams Calling / PSTN — Hotfix Runbook (Mode B: Ops)
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
# Connect to Teams PowerShell
Connect-MicrosoftTeams

# 1. Get user's calling configuration in one shot
Get-CsOnlineUser -Identity <UPN> | Select-Object DisplayName, LineUri, EnterpriseVoiceEnabled, HostedVoiceMail, TeamsUpgradeMode, OnlineVoiceRoutingPolicy, DialPlan, CallingPolicy | Format-List

# 2. Check Teams Phone license
Get-MgUserLicenseDetail -UserId <UPN> | Where-Object {$_.SkuPartNumber -match "MCOEV|TEAMS_PHONE|PHONESYSTEM"} | Select-Object SkuPartNumber, SkuId

# 3. Check calling policy
Get-CsOnlineUser -Identity <UPN> | Select-Object OnlineVoiceRoutingPolicy, DialPlan, TeamsCallingPolicy | Format-List

# 4. Check PSTN usage routes (direct routing)
Get-CsVoiceRoute | Select-Object Name, NumberPattern, PstnGatewayList | Format-Table -AutoSize

# 5. Check SBC connectivity (direct routing only)
Get-CsOnlinePstnGateway | Select-Object Fqdn, Enabled, SipSignalingPort, FailoverTimeSeconds, ForwardCallHistory | Format-Table -AutoSize
```

**Interpretation Table:**

| Symptom | Likely Cause | Go To |
|---------|-------------|-------|
| `EnterpriseVoiceEnabled: False` | License or EV not enabled | Fix 1 |
| `LineUri` is empty | Phone number not assigned | Fix 2 |
| `OnlineVoiceRoutingPolicy` is empty | No voice routing policy | Fix 3 |
| SBC `Enabled: False` or unreachable | Direct routing SBC down | Fix 4 |
| Call connects but audio choppy | Network/QoS issue | Fix 5 |
| Number assigned but calls go to voicemail | Simultaneous ring or call forward active | Fix 6 |
| `TeamsUpgradeMode` not `TeamsOnly` | Hybrid Skype/Teams mode | Fix 1 |

---
## Dependency Cascade

<details><summary>What must be true for PSTN calling to work</summary>

```
Teams Phone (MCOEV) license assigned
    └── EnterpriseVoiceEnabled = True
        └── TeamsUpgradeMode = TeamsOnly
            └── Phone number assigned (LineUri = tel:+1XXXXXXXXXX)
                └── DialPlan (E.164 normalization rules)
                    └── OnlineVoiceRoutingPolicy assigned
                        └── PstnUsage linked to VoiceRoute
                            └── VoiceRoute NumberPattern matches dialled number
                                └── PstnGateway (SBC) reachable on TLS/5061
                                    └── CARRIER / PSTN
                                        └── CALL COMPLETES
```

**For Calling Plan (Microsoft-hosted):**
- Replace SBC/Gateway with: Microsoft Calling Plan license + Calling Plan minutes
- `OnlineVoiceRoutingPolicy` not required — routing is automatic

**For Operator Connect:**
- Replace SBC with: Operator Connect carrier assignment in Teams Admin Centre
- LineUri and EnterpriseVoiceEnabled still required
</details>

---
## Diagnosis & Validation Flow

**Step 1 — Get full user calling status**
```powershell
$user = Get-CsOnlineUser -Identity <UPN>
$user | Select-Object DisplayName, LineUri, EnterpriseVoiceEnabled, TeamsUpgradeMode, OnlineVoiceRoutingPolicy, DialPlan | Format-List
```
Expected: `EnterpriseVoiceEnabled: True`, `LineUri: tel:+<E.164>`, `TeamsUpgradeMode: TeamsOnly`.

**Step 2 — Verify Teams Phone license**
```powershell
# Check for Teams Phone System (MCOEV) or Teams Phone Standard
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber | Where-Object {$_.SkuPartNumber -match "MCOEV|MCOEV_VIRTUALUSER|TEAMS_PHONE"}
```
Expected: At least one MCOEV or TEAMS_PHONE SKU present.

**Step 3 — Validate voice routing (Direct Routing)**
```powershell
# Get the voice routing policy assigned to user
$vrp = $user.OnlineVoiceRoutingPolicy
if ($vrp) {
    Get-CsOnlineVoiceRoutingPolicy -Identity $vrp | Select-Object Identity, OnlinePstnUsages
    # Get usages and their routes:
    $policy = Get-CsOnlineVoiceRoutingPolicy -Identity $vrp
    foreach ($usage in $policy.OnlinePstnUsages) {
        Write-Host "Usage: $usage"
        Get-CsVoiceRoute | Where-Object {$_.OnlinePstnUsages -contains $usage} | Select-Object Name, NumberPattern, PstnGatewayList
    }
}
```

**Step 4 — Test SBC reachability (Direct Routing)**
```powershell
# From the SBC/gateway server or a machine on the same network:
$sbcFqdn = "<sbc.yourdomain.com>"
Test-NetConnection -ComputerName $sbcFqdn -Port 5061
# Also test from Microsoft's perspective — check SBC health in Teams Admin Centre:
# Teams Admin Centre → Voice → Direct Routing → SBC health
```

**Step 5 — Test dial tone via Teams Admin Centre**
- Teams Admin Centre → Users → select user → Voice tab → Test call (if available)
- Or ask user to dial a known number and capture exact error message

---
## Common Fix Paths

<details><summary>Fix 1 — Enable Enterprise Voice / set TeamsOnly mode</summary>

**Use when:** `EnterpriseVoiceEnabled: False` or `TeamsUpgradeMode` is not `TeamsOnly`.

```powershell
# Enable Enterprise Voice (requires Teams Phone license first):
Set-CsPhoneNumberAssignment -Identity <UPN> -EnterpriseVoiceEnabled $true

# Set Teams-only mode:
Grant-CsTeamsUpgradePolicy -Identity <UPN> -PolicyName "UpgradeToTeams"

# Verify:
Get-CsOnlineUser -Identity <UPN> | Select-Object EnterpriseVoiceEnabled, TeamsUpgradeMode
```

**Note:** Allow 5-15 minutes for policy to propagate. User may need to restart Teams client.

**Rollback:** `Set-CsPhoneNumberAssignment -Identity <UPN> -EnterpriseVoiceEnabled $false`
</details>

<details><summary>Fix 2 — Assign a phone number</summary>

**Use when:** `LineUri` is empty or wrong.

```powershell
# Check available numbers in the tenant:
Get-CsPhoneNumberAssignment -CapabilitiesContain VoiceApplications -ErrorAction SilentlyContinue
Get-CsPhoneNumberAssignment -CapabilitiesContain UserAssignment | Where-Object {$_.AssignedPstnTargetId -eq $null} | Select-Object TelephoneNumber, NumberType | Format-Table

# Assign a number (Calling Plan or Operator Connect number):
Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber "+<E.164Number>" -PhoneNumberType <CallingPlan|OperatorConnect|DirectRouting>

# For Direct Routing (number hosted on SBC):
Set-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber "+<E.164Number>" -PhoneNumberType DirectRouting

# Verify:
Get-CsOnlineUser -Identity <UPN> | Select-Object LineUri
```

**Rollback:**
```powershell
Remove-CsPhoneNumberAssignment -Identity <UPN> -PhoneNumber "+<E.164Number>" -PhoneNumberType DirectRouting
```
</details>

<details><summary>Fix 3 — Assign voice routing policy</summary>

**Use when:** `OnlineVoiceRoutingPolicy` is empty, or assigned policy has no working routes.

```powershell
# List available voice routing policies:
Get-CsOnlineVoiceRoutingPolicy | Select-Object Identity, OnlinePstnUsages | Format-Table -AutoSize

# Assign to user:
Grant-CsOnlineVoiceRoutingPolicy -Identity <UPN> -PolicyName "<PolicyName>"

# Verify route coverage — test that the user's number pattern will match a route:
$testNumber = "+<E.164DestinationNumber>"
$vrp = Get-CsOnlineUser -Identity <UPN> | Select-Object -ExpandProperty OnlineVoiceRoutingPolicy
$policy = Get-CsOnlineVoiceRoutingPolicy -Identity $vrp
foreach ($usage in $policy.OnlinePstnUsages) {
    $routes = Get-CsVoiceRoute | Where-Object {$_.OnlinePstnUsages -contains $usage -and $testNumber -match $_.NumberPattern}
    if ($routes) { Write-Host "Match found: $($routes.Name) via $($routes.PstnGatewayList)" }
}
```

**Rollback:** `Grant-CsOnlineVoiceRoutingPolicy -Identity <UPN> -PolicyName $null` (removes policy).
</details>

<details><summary>Fix 4 — Restore SBC connectivity (Direct Routing)</summary>

**Use when:** SBC shows as inactive in Teams Admin Centre, or all DR calls failing.

```powershell
# Check SBC status:
Get-CsOnlinePstnGateway | Select-Object Fqdn, Enabled, SipSignalingPort, FailoverTimeSeconds, MediaBypass | Format-Table -AutoSize

# Re-enable an SBC if accidentally disabled:
Set-CsOnlinePstnGateway -Identity <sbc.fqdn> -Enabled $true

# Check SIP signaling port reachability (typically 5061 TLS):
Test-NetConnection -ComputerName <sbc.fqdn> -Port 5061
```

**SBC-side checks (performed on the SBC itself):**
- Verify TLS certificate is valid and not expired
- Confirm SIP trunk to PSTN carrier is registered
- Check SBC logs for `403 Forbidden` or `503 Service Unavailable` from Microsoft SIP proxy

**Microsoft SIP proxy IPs:** Maintain connectivity to `sip.pstnhub.microsoft.com` (52.114.x.x range) on port 5061.

**Rollback:** `Set-CsOnlinePstnGateway -Identity <sbc.fqdn> -Enabled $false` if SBC needs maintenance.
</details>

<details><summary>Fix 5 — Improve call quality / fix choppy audio</summary>

**Use when:** Calls connect but audio is poor, dropping, or delayed.

```powershell
# Pull Call Quality Dashboard data via Graph (requires Reports.Read.All):
# Best done via Teams Admin Centre → Analytics & reports → Call Quality Dashboard

# Quick check — test network for Teams:
# Have user run: https://networktest.teams.microsoft.com
# Or use connectivity test tool:
# Teams client: Settings → Devices → Make a test call

# Check for QoS markings (on managed networks):
Get-NetQosPolicy | Where-Object {$_.Name -like "*Teams*"} | Format-Table -AutoSize

# Apply QoS policy if missing (run on client machine via GPO or Intune):
New-NetQosPolicy -Name "Teams Audio" -AppPathNameMatchCondition "Teams.exe" -IPProtocolMatchCondition UDP -IPSrcPortStartMatchCondition 50000 -IPSrcPortEndMatchCondition 50019 -DSCPAction 46 -NetworkProfile All
New-NetQosPolicy -Name "Teams Video" -AppPathNameMatchCondition "Teams.exe" -IPProtocolMatchCondition UDP -IPSrcPortStartMatchCondition 50020 -IPSrcPortEndMatchCondition 50039 -DSCPAction 34 -NetworkProfile All
```

**Common causes of poor call quality:**
- VPN hairpinning Teams media traffic (Teams media should bypass VPN — split tunneling required)
- Wireless roaming mid-call
- ISP jitter >30ms or packet loss >1%
- Missing QoS on managed LAN

**Rollback:** `Remove-NetQosPolicy -Name "Teams Audio" -Confirm:$false`
</details>

<details><summary>Fix 6 — Fix calls going straight to voicemail or forwarded unexpectedly</summary>

**Use when:** Calls ring briefly or not at all, then hit voicemail or another number.

```powershell
# Check user's call forwarding settings:
Get-CsUserCallingSettings -Identity <UPN> | Format-List

# Reset forwarding if set incorrectly:
Set-CsUserCallingSettings -Identity <UPN> -IsForwardingEnabled $false
Set-CsUserCallingSettings -Identity <UPN> -IsUnansweredEnabled $false

# Check simultaneous ring:
Get-CsUserCallingSettings -Identity <UPN> | Select-Object IsForwardingEnabled, ForwardingTarget, IsUnansweredEnabled, UnansweredTarget, UnansweredDelay
```

Expected: `IsForwardingEnabled: False`, `IsUnansweredEnabled: False` (unless voicemail is intended).

**Rollback:** Re-enable forwarding/unanswered settings to original values.
</details>

---
## Escalation Evidence

```
TEAMS CALLING ESCALATION
=========================
User UPN:                <UPN>
Calling type:            [ ] Calling Plan  [ ] Operator Connect  [ ] Direct Routing

EnterpriseVoiceEnabled:  <True/False>
TeamsUpgradeMode:        <value>
LineUri:                 <tel:+... or empty>
OnlineVoiceRoutingPolicy: <value or empty>
DialPlan:                <value or empty>
Teams Phone license:     [ ] Present (SKU: <name>)  [ ] Missing

Symptom:
  [ ] No dial tone  [ ] Can't receive calls  [ ] Can't make outbound
  [ ] Poor quality  [ ] Specific number pattern fails
  [ ] Calls forwarding unexpectedly

Error message in Teams:  <exact text>

SBC status (Direct Routing only):
  FQDN: <sbc.fqdn>  Enabled: <True/False>  Last health check: <time>

Call Quality Dashboard data (if available):
  Packet loss: <x>%  Jitter: <x>ms  Round-trip: <x>ms

Steps already tried:
  [ ] Checked license  [ ] Checked LineUri  [ ] Checked VRP  [ ] SBC reachability test
```

---
## 🎓 Learning Pointers

- **Teams Phone ≠ Calling Plan** — Teams Phone (MCOEV) is the PBX engine; a Calling Plan is the carrier. Without a Calling Plan, Operator Connect, or Direct Routing, there's no PSTN — just internal Teams-to-Teams calls.
- **LineUri must be E.164 format** — `+12125551234` not `12125551234`. The leading `+` is required. Calls will silently fail or route incorrectly without it.
- **Direct Routing SBC certificate must be from a trusted CA** — self-signed certs are rejected by Microsoft SIP proxy. Microsoft publishes the list of trusted CAs: https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan#public-trusted-certificate-for-the-sbc
- **Split tunneling is mandatory for good call quality over VPN** — all Teams media (UDP 50000-50059) should bypass the VPN tunnel. Routing media over VPN causes >100ms jitter in most environments.
- **Call Quality Dashboard is retrospective** — data is available after calls end, typically within 30 minutes. For live troubleshooting, use the Teams Network Planner or the client's diagnostics logs.
- MS Docs — Plan Direct Routing: https://learn.microsoft.com/en-us/microsoftteams/direct-routing-plan
- MS Docs — Manage Teams calling policies: https://learn.microsoft.com/en-us/microsoftteams/teams-calling-policy
