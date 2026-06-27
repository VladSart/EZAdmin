# Microsoft Defender for Cloud Apps (MDA) — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to establish context:

```powershell
# 1. Check MDA licensing (requires Graph)
Connect-MgGraph -Scopes "Directory.Read.All"
$skus = Get-MgSubscribedSku
$skus | Where-Object { $_.SkuPartNumber -match "CAS|CLOUD_APP_SECURITY|EMS|E5" } |
    Select-Object SkuPartNumber,
        @{N="Enabled";E={$_.PrepaidUnits.Enabled}},
        @{N="Consumed";E={$_.ConsumedUnits}} |
    Format-Table

# 2. Check Defender for Endpoint integration status (on device)
Get-MpComputerStatus | Select-Object AMServiceEnabled, RealTimeProtectionEnabled, MpVersion

# 3. Check Conditional Access app control proxy connectivity
# (From affected user's machine — confirms proxy is reachable)
Invoke-WebRequest -Uri "https://contoso.mcas.ms" -UseDefaultCredentials -MaximumRedirection 0 -ErrorAction SilentlyContinue |
    Select-Object StatusCode, Headers

# 4. Pull recent MDA-related CA sign-in failures
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "status/errorCode eq 53003 or appDisplayName eq 'Microsoft Cloud App Security'" -Top 20 |
    Select-Object CreatedDateTime, UserPrincipalName, AppDisplayName,
        @{N="Error";E={$_.Status.ErrorCode}}, @{N="Reason";E={$_.Status.FailureReason}} |
    Format-Table -AutoSize
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| No CAS/E5 SKU found | No MDA license | Check licensing — assign CAS_E plan or verify E5 includes MDA |
| `StatusCode 302` on mcas.ms redirect | CA App Control proxy active | Proxy is working; issue is policy or session |
| `StatusCode 404/Connection refused` | Proxy not routing | Check CA policy "Use Conditional Access App Control" is set |
| Error 53003 in sign-in logs | Blocked by CA App Control (MDA session policy) | Review MDA session/access policies in the MDA portal |
| `AMServiceEnabled = False` | Defender not running | Can't forward signals to MDA — fix MDE first |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender for Cloud Apps (MDA) Portal
         │
         ├── Licensing: MDA standalone / EMS E5 / M365 E5
         │
         ├── Data ingestion sources
         │   ├── Microsoft Defender for Endpoint (MDE) — automatic signal forwarding
         │   │       └── MDE onboarded, Policy "Microsoft Defender for Cloud Apps" enabled
         │   ├── Conditional Access App Control (CAAC) — proxy mode
         │   │       ├── CA policy → Session control → "Use Conditional Access App Control"
         │   │       ├── App configured in MDA as conditional access app
         │   │       └── User's browser session routes through *.mcas.ms proxy
         │   └── Log collectors / API connectors (third-party apps)
         │
         ├── Cloud Discovery (Shadow IT)
         │   ├── MDE traffic forwarding (most common in modern deployments)
         │   └── Firewall/proxy log upload (classic / non-MDE environments)
         │
         ├── App Connectors (API-connected apps: M365, GitHub, AWS, Salesforce, etc.)
         │   └── OAuth app permissions granted by admin
         │
         └── Policies acting on ingested data
             ├── Session policies (block download, watermark, etc.)
             ├── Access policies (block/allow session initiation)
             ├── Activity policies (alert on anomalies)
             └── File policies (DLP on cloud file activity)
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm the user is experiencing the right symptom**

```
User blocked by MDA → Error 53003 in sign-in logs?       → Fix Path 1
User sees MDA warning/block in browser?                   → Fix Path 2
Shadow IT report not showing devices/traffic?             → Fix Path 3
App connector showing "Connection error"?                 → Fix Path 4
MDA alerts not firing for known activity?                 → Fix Path 5
```

**2. Get the specific MDA alert or policy name from the user's error page**

MDA blocks and session policy interventions show a customisable message. Note the policy name displayed — it maps directly to a policy in the MDA portal (security.microsoft.com → Cloud Apps → Policies).

**3. Check the MDA portal alert queue**

Navigate to: `https://security.microsoft.com` → Cloud Apps → Alerts

Filter by last 24h and the affected user's UPN. Note whether alerts are triggered (meaning signals are arriving) or empty (signals not reaching MDA).

**4. Verify MDE-to-MDA integration (for Shadow IT / Cloud Discovery)**

```powershell
# On a managed device — confirm MDE is forwarding to MDA
# Check relevant registry key
$key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection"
Get-ItemProperty -Path $key -Name "ForwardCloudAppTraffic" -ErrorAction SilentlyContinue

# Expected: ForwardCloudAppTraffic = 1
# If absent or 0: MDE is NOT forwarding traffic to MDA
```

**5. Verify CA App Control session routing**

From an affected user's browser, navigate to the target app (e.g. SharePoint). The URL should redirect through `*.mcas.ms`. If it does not, the CA policy "Use Conditional Access App Control" is not applying to this user/session.

---

## Common Fix Paths

<details><summary>Fix 1 — User blocked by error 53003 (CA App Control policy)</summary>

**Cause:** An MDA Access or Session policy is blocking the user's session.

**Steps:**

1. Go to `https://security.microsoft.com` → Cloud Apps → Policies → Policy management.
2. Filter by "Session" or "Access" policies.
3. Find the policy named in the user's block message.
4. Click the policy → review "Actions": is it "Block" or "Monitor"?
5. Review the filters: does this user match the scope (user group, IP, device tag)?
6. **Quick fix (test):** Set the policy action to "Monitor" temporarily → have the user retry → confirm access works → then refine filters and restore to Block.

```powershell
# MDA policies cannot be managed via PowerShell — use the portal.
# To identify which policy fired: check sign-in log for the specific CA policy name.
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>' and status/errorCode eq 53003" -Top 5 |
    Select-Object CreatedDateTime, AppDisplayName,
        @{N="CAPolicy";E={$_.AppliedConditionalAccessPolicies.DisplayName -join ", "}} |
    Format-Table -AutoSize
```

**Rollback:** Set the policy back to its original action (Block / Block with override).

</details>

<details><summary>Fix 2 — MDA session control not applying (no mcas.ms proxy in URL)</summary>

**Cause:** The Conditional Access policy session control is not applying to this user/app combination.

**Checklist:**

1. In Entra CA, open the policy that should apply → confirm the user is included (check group membership).
2. Under **Session** → verify "Use Conditional Access App Control" is selected (not "Monitor only").
3. In the MDA portal → Settings → Cloud Apps → Connected apps → Conditional Access App Control apps → confirm the target app appears here.
4. If the app is not in the MDA app list, it must be onboarded: MDA portal → Settings → Cloud Apps → Conditional Access App Control → Add an app.
5. If it's a custom/non-featured app, use the "Custom" onboarding flow and set the redirect URI.

**Validate after fix:**

```powershell
# Sign-in logs should show the CA policy "Applied" and session control type
Connect-MgGraph -Scopes "AuditLog.Read.All"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
    ForEach-Object {
        [PSCustomObject]@{
            Time       = $_.CreatedDateTime
            App        = $_.AppDisplayName
            CAPolicies = ($_.AppliedConditionalAccessPolicies | Where-Object { $_.Result -eq "success" }).DisplayName -join ", "
            SessionCtrl = $_.AuthenticationProcessingDetails | Where-Object { $_.Key -eq "Is CAE Token" } | Select-Object -ExpandProperty Value
        }
    } | Format-Table -AutoSize
```

</details>

<details><summary>Fix 3 — Shadow IT / Cloud Discovery not showing traffic</summary>

**Cause A (MDE integration disabled):**

```powershell
# Check MDE cloud app security integration (Intune policy or GPO sets this)
# Registry path on endpoint:
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection"
$val = Get-ItemProperty -Path $regPath -Name "ForwardCloudAppTraffic" -ErrorAction SilentlyContinue
if ($val.ForwardCloudAppTraffic -ne 1) {
    Write-Warning "MDE is not forwarding traffic to MDA. Set ForwardCloudAppTraffic = 1 via Intune or GPO."
}
```

**Fix via Intune:**
- Intune → Endpoint Security → Microsoft Defender for Endpoint → Enable "Microsoft Defender for Cloud Apps" → set to "Enabled".
- This deploys the registry key automatically to onboarded devices.
- Allow 2–4 hours for data to appear in MDA Cloud Discovery.

**Cause B (Log collector not uploading):**
- MDA portal → Cloud Discovery → Log collectors → check status and last upload time.
- If stalled: restart the log collector Docker container, verify it can reach `*.portal.cloudappsecurity.com:443`.

</details>

<details><summary>Fix 4 — App connector showing connection error</summary>

**Cause:** OAuth token expired, permission scope changed, or admin consent revoked.

```powershell
# Check if the connected app's service principal permissions are intact
Connect-MgGraph -Scopes "Application.Read.All"
$sp = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Cloud App Security'" -All
$sp | Select-Object DisplayName, Id, AppId | Format-List
```

**Fix:**

1. MDA portal → Settings → Cloud Apps → Connected apps → App connectors.
2. Click the affected connector → "Test connection".
3. If it fails, click **Edit** → re-enter credentials or re-authorise OAuth.
4. For M365 connectors: the connecting account must be a Global Admin at the time of authorisation.
5. After reconnect, allow 15–30 minutes for activity data to re-populate.

**Rollback:** Disconnecting an app connector does not delete historical MDA data; you can reconnect at any time.

</details>

<details><summary>Fix 5 — MDA alerts not firing for known activity</summary>

**Cause:** Policy scope wrong, alert suppression active, or data not reaching MDA.

1. **Confirm data is arriving:** MDA portal → Cloud Discovery → Overview — do you see any traffic in the last 24h? If zero: fix data ingestion first (Fix 3).
2. **Check policy scope:** MDA portal → Policies → click the relevant policy → verify "Apply to" includes the right apps, users, and activity types.
3. **Check alert suppression:** On the policy page, look for "Do not alert if same activity is repeated within X minutes" — if set too high, repeat actions won't re-alert.
4. **Trigger a test event manually** and wait 10–15 minutes. Check the Alerts page and the Activity log (Cloud Apps → Activity log) to see if the event appears.
5. **Review policy severity:** Policies with "Low" severity may be filtered out in the default alerts view — change filter to "All severities".

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Microsoft Defender for Cloud Apps (MDA)
=========================================================
Date/Time of issue:          ___________________________
Affected user UPN:           ___________________________
Affected application:        ___________________________
Symptom observed:            ___________________________
  [ ] User blocked (error 53003)
  [ ] Session control not applying (no .mcas.ms in URL)
  [ ] Shadow IT data missing
  [ ] App connector failing
  [ ] Alerts not firing

Tenant ID:                   ___________________________
MDA portal URL:              https://security.microsoft.com → Cloud Apps
Licensing SKU confirmed:     [ ] Yes  [ ] No — SKU: ___________

MDA Policy name (from block page or sign-in log):  ___________________________
CA policy name applied:      ___________________________

Sign-in log correlation ID:  ___________________________
MDA Alert ID (if any):       ___________________________

MDE integration status:
  ForwardCloudAppTraffic registry value:  ___  (expected: 1)
  MDE onboarding status of device:        [ ] Onboarded  [ ] Not onboarded

Attached evidence:
  [ ] Sign-in log export (CSV)
  [ ] MDA policy screenshot
  [ ] Browser URL screenshot showing (or not showing) .mcas.ms

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Defender for Cloud Apps
```

---

## 🎓 Learning Pointers

- **MDA has two proxy modes:** "Conditional Access App Control" (CAAC) for browser sessions, and native integration for apps that natively support the MDA SDK. Most troubleshooting involves CAAC. The *.mcas.ms domain in the URL is your confirmation that the session is being proxied. [MS Docs: Conditional Access App Control](https://learn.microsoft.com/en-us/defender-cloud-apps/proxy-intro-aad)

- **Error 53003 is an MDA signal, not an Entra signal:** It originates when MDA's access/session policy issues a block instruction back through the CA framework. To find the specific MDA policy, check the block page text or the CA sign-in log's "Applied CA Policies" section — the MDA policy name is embedded there. [MS Docs: Troubleshoot access and session controls](https://learn.microsoft.com/en-us/defender-cloud-apps/troubleshooting-proxy)

- **MDE integration is the modern alternative to log collectors:** If devices are onboarded to MDE, enabling the MDA integration toggle in Intune/MDE is far simpler than deploying Docker-based log collectors. Traffic from all onboarded endpoints flows into MDA Cloud Discovery automatically. [MS Docs: Microsoft Defender for Endpoint integration](https://learn.microsoft.com/en-us/defender-cloud-apps/mde-integration)

- **App connector permissions are tenant-scoped:** When you connect an app like Salesforce or GitHub to MDA, the OAuth token is tied to the admin account that performed the connection. If that admin leaves and their account is deactivated, the connector breaks. Best practice: connect app connectors using a dedicated service account. [MS Docs: Connect apps to MDA](https://learn.microsoft.com/en-us/defender-cloud-apps/enable-instant-visibility-protection-and-governance-actions-for-your-apps)

- **Shadow IT scoring uses the Cloud App Catalog:** MDA scores discovered apps 0–10 based on security attributes (data retention, encryption, compliance). You can customise scores and tag apps as Sanctioned/Unsanctioned. Sanctioned apps are excluded from Shadow IT risk reports — useful for reducing noise once your approved SaaS list is defined. [MS Docs: Working with the Cloud App Catalog](https://learn.microsoft.com/en-us/defender-cloud-apps/risk-score)
