# Token Protection — Reference Runbook (Mode A: Deep Dive)
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

- **Scope:** Conditional Access Token Protection ("Require token protection for sign-in sessions") — the cryptographic device-binding mechanism, its architecture, supported platforms/apps/resources as of this writing, the documented unsupported-combination list, and how to design, pilot, and troubleshoot it.
- **Not covered:** Standard grant controls (Require MFA, Require compliant device, Require Hybrid Joined device) — those are evaluated separately; see `CA-Design-A.md`. Not a replacement for `EntraID/Troubleshooting/CAE-A.md` (Continuous Access Evaluation) — CAE and Token Protection are different, complementary mechanisms addressing different parts of the token-theft problem (see below).
- **Applies to:** Any Entra ID tenant with **Entra ID P1** licensing (required for this feature). Enforcement is currently possible only for **Windows** (Generally Available) and **Apple platforms** (Preview: macOS 14.0+ with Enterprise SSO plug-in or Platform SSO; iOS/iPadOS 16.0+ with Enterprise SSO plug-in — MDM-managed devices only).
- **Client requirement:** Token Protection only covers **native/rich client applications** that integrate with the platform authentication broker (Windows Account Manager — WAM — on Windows). **Browser-based access is never covered**, regardless of platform.

---

## How It Works

<details><summary>Full architecture</summary>

### The problem Token Protection solves

The dominant credential-theft pattern in 2024-2026 is not password theft — it's **session/token theft**. Adversary-in-the-middle (AiTM) phishing proxies, infostealer malware, and browser-session exfiltration all target the same thing: a valid OAuth access/refresh token or Primary Refresh Token (PRT), harvested *after* the legitimate user has already completed sign-in (including MFA). Once an attacker has that token, they can typically replay it from their own infrastructure and be treated as the legitimate, already-authenticated user — MFA has already happened, so it doesn't fire again.

Standard Conditional Access grant controls (Require MFA, Require compliant device, Require Hybrid Joined device) evaluate device/user state **at the moment the token is issued**. They do nothing to stop a token that was already issued to a legitimate, compliant device from being **replayed from a completely different machine** later — the token itself carries no device binding by default.

### The Token Protection mechanism

Token Protection closes this specific gap by binding the sign-in session token to the device that requested it, using a Proof-of-Possession (PoP) model:

```
Device registers with Microsoft Entra ID (Entra join / Hybrid join / Entra register)
        │
        ▼
A cryptographic key pair is generated and the private key is stored in the
device's protected key store (TPM-backed on Windows)
        │
        ▼
When a Primary Refresh Token (PRT) or sign-in session token is issued to this
device, it is bound to that key pair
        │
        ▼
Supported client apps request access using this bound token flow — each token
request includes proof that the caller holds the matching private key
        │
        ▼
Microsoft Entra ID / the resource provider validates the proof-of-possession
before honoring the request
        │
        ├─ Proof matches the device the token was issued to  → request succeeds (Bound)
        └─ Proof missing / from a different device / unsupported flow → request
           fails (Unbound), with a signInSessionStatusCode explaining why
```

If an attacker exfiltrates the raw token value (via AiTM proxy, malware, or a stolen browser session) and tries to replay it from their own machine, they do not possess the bound private key — the resource provider rejects the replayed token. This is a materially different defense than "require a compliant device," because it protects the **token in transit and in use**, not just the device state at the moment of issuance.

### Why Token Protection, Compliant Device, and CAE are three different things

This is the single most common point of confusion when designing or explaining Conditional Access to a non-security audience:

| Control | What it checks | When it checks | What it stops |
|---|---|---|---|
| Require compliant / Hybrid Joined device | Device posture (Intune compliance, join type) | At sign-in / token issuance | Non-compliant devices from getting a token in the first place |
| Continuous Access Evaluation (CAE) | Identity/account-level signals (disable, password change, risk) + optional strict location | Reactively, within minutes of a signal | A token continuing to work after the underlying account/context has changed |
| **Token Protection** | Cryptographic proof the caller holds the device-bound key for **this specific token** | On every protected request, continuously | A stolen/replayed token being used from a **different device** than it was issued to |

Microsoft's own guidance is explicit: use Token Protection **as part of a broader defense-in-depth strategy**, alongside device compliance and CAE — none of the three substitutes for the others.

### Platform and app support boundaries (as of this writing)

| Platform | Status |
|---|---|
| Windows | Generally Available |
| iOS / iPadOS | Preview |
| macOS | Preview |

Supported **resources**: Exchange Online, SharePoint Online, Microsoft Teams — and, on Windows specifically, additionally Azure Virtual Desktop and Windows 365.

Supported **client applications** (Windows) include: Outlook, Teams, OneDrive, Word/Excel/PowerPoint, OneNote, To Do, Loop, Power BI Desktop, PowerQuery for Excel (Current Channel only), Visual Studio Code, Visual Studio (via the Windows authentication broker sign-in option), Windows App, Microsoft 365 Copilot, Microsoft Edge (profile sign-in only), Exchange PowerShell module, and Microsoft Graph PowerShell (with `-EnableLoginByWAM`). **Browser-based application access is explicitly and permanently out of scope** — this is a protocol limitation, not a rollout-phase gap.

### Documented unsupported combinations (hard limitations, not bugs)

These do not work today and have no client-side fix:

- Office **perpetual** (non-subscription) client installations
- PowerShell modules that access **SharePoint** (as opposed to the Exchange PowerShell module, which is supported)
- **PowerQuery** for Excel on any update channel other than Current Channel
- **VS Code extensions** that reach Exchange or SharePoint directly (VS Code itself is supported; specific extensions calling these resources are not)
- **Surface Hub** devices and **Windows-based Microsoft Teams Rooms (MTR)** systems

And these **device registration/deployment methods** cannot satisfy Token Protection at all, regardless of app:

- Microsoft Entra-joined **Azure Virtual Desktop session hosts**
- Windows devices deployed via **bulk enrollment**
- **Windows 365 Cloud PCs** that are Microsoft Entra joined
- **Power Automate hosted machine groups** that are Microsoft Entra joined
- Windows Autopilot devices deployed using **self-deploying mode**
- Azure Windows VMs enabled for Entra ID sign-in via the **VM extension**

External (B2B) users who meet Token Protection requirements in their **home** tenant are supported — but if they don't, they see a generic, unhelpful error with no indication of root cause, which makes cross-tenant troubleshooting notably harder.

</details>

---

## Dependency Stack

```
┌────────────────────────────────────────────────────────────────┐
│  Layer 5 — Conditional Access policy                            │
│  Session > "Require token protection for sign-in sessions"      │
│  scoped to: Windows platform, "Mobile apps and desktop clients" │
│  (NOT Browser), specific resources (not the Office 365 app group)│
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Layer 4 — Target resource                                       │
│  Exchange Online / SharePoint Online / Teams                     │
│  (Windows only, additionally: Azure Virtual Desktop, Windows 365) │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Layer 3 — Client application                                    │
│  Must be on the supported native-app list AND broker through WAM │
│  (Windows) — browser sessions, PowerShell-to-SharePoint, non-    │
│  Current-Channel PowerQuery, Office perpetual, VS Code extensions │
│  reaching Exchange/SharePoint are all excluded here               │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Layer 2 — Device-bound token issuance                          │
│  Device-bound PRT issued; session key held in TPM (Windows) or   │
│  platform-equivalent secure store (Apple, Preview)                │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  Layer 1 — Device registration (foundation)                      │
│  Entra joined / Entra Hybrid joined / Entra registered, on a     │
│  supported OS (Windows 10+/Server 2019+ Hybrid; macOS 14+/iOS    │
│  16+ Preview) via a SUPPORTED registration method — excludes      │
│  AVD Entra-joined hosts, bulk enrollment, Entra-joined Cloud PCs, │
│  Entra-joined Power Automate hosted machine groups, Autopilot    │
│  self-deploying mode, and Azure VM sign-in extension devices      │
└────────────────────────────────────────────────────────────────┘
```

A failure at any layer produces an **Unbound** result with a specific `signInSessionStatusCode` — the fastest diagnostic path is always to read that code first (Validation Step 1) rather than guessing which layer broke.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All users on Entra-joined AVD session hosts or Entra-joined Windows 365 Cloud PCs suddenly blocked from Exchange/Teams after a policy change | Unsupported device registration type — Token Protection cannot bind on these by design | Sign-in log Basic Info: `Token Protection - Sign In Session` = Unbound, statusCode **1003**; confirm device `systemLabels`/`trustType` |
| Autopilot self-deploying-mode kiosk/shared devices blocked | Self-deploying mode enrollment is an explicitly unsupported registration method | Check device's `enrollmentProfileName` in Entra/Intune |
| A PowerShell automation script pulling SharePoint data starts failing tenant-wide after enforcement | PowerShell modules accessing SharePoint are a hard unsupported combination (Exchange PowerShell module IS supported — SharePoint is not) | Confirm client app in sign-in log; migrate to a supported access path or scope an exclusion |
| Teams Web (browser) users blocked entirely while Teams desktop users are unaffected | CA policy's Client apps condition includes Browser, or wasn't configured — MSAL.js browser apps cannot honor Token Protection | Review policy Conditions > Client apps; should be "Mobile apps and desktop clients" only |
| User sees a "register or enroll your device" branded error page | Device isn't Entra registered/joined/Hybrid joined at all | `dsregcmd /status` on the device |
| User sees an "app not supported" branded error, different from the registration error | App itself isn't on the supported list, even though the device is fine | Sign-in log AppDisplayName; cross-reference supported-app list |
| PowerQuery in Excel fails for some users, not others | Affected users are on a non-Current-Channel Office update channel | File > Account > update channel, on the affected machine |
| Report-only mode shows policy "not applied" for users expected to be in scope | Policy scoping issue (platform/resource/client-app condition), not a compatibility gap | Conditional Access > Policies > [policy] > report-only insights, or the "What If" tool |
| B2B/guest users from a partner tenant get a vague, unhelpful error with no clear cause | Guest doesn't meet Token Protection requirements in their **home** tenant — Entra does not surface a specific reason cross-tenant | Confirm with the partner tenant admin whether the guest's home-tenant device satisfies Token Protection prerequisites |
| Android, Linux, or other non-Windows/non-Apple platform users are never challenged by this policy at all | Expected — Token Protection is enforceable only on Windows (GA) and Apple (Preview); other platforms cannot be required to use it | Confirm a complementary "Block unknown platforms" / "Require compliant device for all platforms" policy exists to close this gap |
| Sign-in log shows an `enforcedSessionControls` value of `Binding` in older data but current data shows `SignInTokenProtection` | Expected — the string value changed in **June 2023**; the underlying control is the same | Update any KQL/automation to check both string values for full historical coverage |

---

## Validation Steps

**1. Read the `Token Protection - Sign In Session` field and its statusCode**
```
Sign-in logs > [event] > Basic info tab
```
Good: field present, value = Bound.
Bad: value = Unbound — note the statusCode (1002/1003/1005/1006/1008) before doing anything else; it tells you which layer of the dependency stack failed.

---

**2. Confirm which Conditional Access (or Report-only) policy evaluated this sign-in**
```
Sign-in logs > [event] > Conditional Access / Report-only tab > click the policy name
→ Session Controls section: Satisfied / Not satisfied
```
Good: exactly one policy requiring token protection is scoped to this request, and its result is clear.
Bad: multiple overlapping policies, or none at all despite the symptom — re-check policy Conditions scoping (platform, resource, client app).

---

**3. Confirm the device's registration/enrollment type**
```
On-device:  dsregcmd /status
Portal:     Entra admin center > Identity > Devices > All devices > [device]
            → Join type, trust type, and (for Intune-managed) enrollment profile
```
Good: device is Entra joined/Hybrid joined/Entra registered via a standard flow, not one of the six excluded registration methods.
Bad: device matches an excluded method (AVD session host, Cloud PC, bulk-enrolled, Autopilot self-deploy, Power Automate hosted machine group, Azure VM extension) — this maps directly to statusCode 1003 and has no fix except a device filter exclusion.

---

**4. Confirm the client app against the supported list**
```
Sign-in log > AppDisplayName / Client app columns
```
Good: app is on the documented supported native-app list and was accessed via its desktop/mobile client.
Bad: browser session, Office perpetual install, SharePoint-targeting PowerShell module, non-Current-Channel PowerQuery, or a VS Code extension hitting Exchange/SharePoint directly.

---

**5. Confirm policy Conditions match design intent**
```
Entra admin center > Protection > Conditional Access > [policy] >
Conditions > Client apps, Device platforms, Target resources
```
Good: Client apps = "Mobile apps and desktop clients" only (Browser excluded); Target resources are individually selected (Exchange Online, SharePoint Online, Teams Services, and if relevant AVD/Windows 365/Windows Cloud Login) — NOT the broad "Office 365" app group.
Bad: Browser included in Client apps, or the Office 365 app group selected as the resource — both are documented, specific gotchas that cause unintended blocking or unintended gaps.

---

**6. For B2B/guest scenarios, confirm home-tenant compliance**
```
Coordinate with the partner tenant admin — no visibility into a guest's home-tenant
device state exists from the resource tenant's sign-in logs beyond a generic failure.
```
Good: partner tenant confirms the guest's device satisfies Token Protection prerequisites.
Bad: partner tenant cannot confirm, or the guest's home tenant doesn't have equivalent device registration — expect this to remain a persistent friction point for that specific guest population, not a one-time fix.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Establish scope and pull the statusCode
1. Determine if this is a single user, a device class (all AVD hosts, all Cloud PCs), or broad
2. Pull the sign-in log entry and read `Token Protection - Sign In Session` + statusCode (Validation Step 1)
3. If the field is entirely absent, stop — this isn't a Token Protection issue; investigate the actual reported symptom separately

### Phase 2 — Map the statusCode to a dependency-stack layer
1. 1002/1003 → Layer 1 (device registration) — go to Validation Step 3
2. 1005/1008 → Layer 3 (client app / broker integration) — go to Validation Step 4
3. 1006 → Layer 1 (OS version)

### Phase 3 — Confirm whether this is a known, documented limitation vs. a real misconfiguration
1. Cross-reference the device registration type, client app, and resource against the documented unsupported-combination lists above
2. If it matches a documented limitation exactly: this is expected behavior — the fix is a device filter exclusion (a permanent workaround) plus a compensating control, not a "bug"
3. If it does NOT match any documented limitation: re-check policy Conditions scoping (Validation Step 5) — this is more likely a policy authoring error

### Phase 4 — Pilot-safety check before any policy change
1. Confirm whether the affected policy is still in Report-only mode or fully enforced
2. If enforced and this is a widescale unexpected block, consider moving the policy back to Report-only temporarily while the fix is prepared, rather than leaving users blocked during remediation — coordinate this decision with whoever owns Conditional Access design for the tenant
3. Any device filter exclusion or scope change should be tested in Report-only/What-If before re-enforcing

### Phase 5 — Close residual bypass gaps
1. Confirm complementary policies exist for platforms Token Protection cannot cover (Block unknown platforms, Require compliant device for all known platforms)
2. Document any device filter exclusions added, and why — these are permanent, not temporary, and should be visible to whoever audits CA policy design later

---

## Remediation Playbooks

<details><summary>Playbook 1 — Staged rollout via Report-only, then pilot, then enforce</summary>

**Scenario:** Deploying Token Protection to a tenant for the first time, or expanding it beyond an initial pilot group.

```
1. Create the Conditional Access policy scoped to:
   - Users: a small pilot group first (privileged/specialized roles are good early
     candidates, per Microsoft's guidance) — exclude break-glass accounts
   - Target resources: select Office 365 Exchange Online, Office 365 SharePoint
     Online, Microsoft Teams Services individually (add Azure Virtual Desktop,
     Windows 365, Windows Cloud Login only if Windows App is deployed) — do NOT
     select the broad "Office 365" application group
   - Device platforms: Windows (add Apple platforms only if piloting Preview support)
   - Client apps: configure this condition explicitly — select "Mobile apps and
     desktop clients" only; leave Browser unchecked
   - Session > "Require token protection for sign-in sessions"

2. Set Enable policy to Report-only. Do NOT enforce immediately.

3. Let it run long enough to observe normal application usage patterns for the
   pilot group (both interactive and non-interactive sign-ins) — a single day is
   rarely enough to catch every app/workflow combination.

4. Review Policy impact / report-only insights and the sign-in logs for the pilot
   group, looking specifically for Unbound results and their statusCodes.

5. Add any needed device filter exclusions (Playbook 2) for legitimately
   unsupported device classes discovered during the pilot.

6. Expand the pilot group gradually, repeating steps 3-5, before finally moving
   Enable policy from Report-only to On for the full target population.
```

**Rollback:** Move the policy back to Report-only (or Off) at any stage if the pilot surfaces unacceptable breakage — this is non-destructive and expected to happen iteratively.

</details>

<details><summary>Playbook 2 — Exclude permanently-unsupported device registration types</summary>

**Scenario:** A defined population of devices (AVD session hosts, Cloud PCs, bulk-enrolled devices, Autopilot self-deploy kiosks, Power Automate hosted machine groups, Azure VM sign-in extension hosts) will never be able to satisfy Token Protection, and should stop being blocked by a policy they cannot pass.

```
1. Confirm the device category precisely (Validation Step 3) — don't guess.

2. Entra admin center > Protection > Conditional Access > [policy] >
   Conditions > Filter for devices > add an exclude rule:

   - Entra-joined Cloud PCs (Windows 365):
       systemLabels -eq "CloudPC" and trustType -eq "AzureAD"
   - Entra-joined Azure Virtual Desktop session hosts:
       systemLabels -eq "AzureVirtualDesktop" and trustType -eq "AzureAD"
   - Entra-joined Power Automate hosted machine groups:
       systemLabels -eq "MicrosoftPowerAutomate" and trustType -eq "AzureAD"
   - Autopilot self-deploying mode devices (match your tenant's actual profile name):
       enrollmentProfileName -eq "Autopilot self-deployment profile"
   - Entra-joined Azure VMs using the VM sign-in extension:
       profileType -eq "SecureVM" and trustType -eq "AzureAD"

3. Validate in Report-only/What-If that affected devices now show "Not applicable"
   rather than "Failure" for this policy.

4. Document the exclusion and the compensating control (see Playbook 4) that
   covers these devices instead — an exclusion here is a permanent architectural
   decision, not a temporary patch.
```

**Rollback:** Remove the specific filter rule if the device category was misidentified or Microsoft later adds support for it (check current documentation periodically — platform support boundaries do change over time).

</details>

<details><summary>Playbook 3 — Fix the two most common policy-authoring gotchas</summary>

**Scenario:** Unexpected blocking (or unexpected non-enforcement) traced back to how the policy itself was configured, not a device/app compatibility gap.

```
1. Client apps condition gotcha:
   Entra admin center > Protection > Conditional Access > [policy] > Conditions > Client apps
   → Set Configure = Yes
   → Under Modern authentication clients, select ONLY "Mobile apps and desktop clients"
   → Leave Browser unchecked — leaving it checked, or leaving the whole condition
     unconfigured, silently blocks MSAL.js browser apps like Teams Web

2. Resource/app-group targeting gotcha:
   Entra admin center > Protection > Conditional Access > [policy] > Target resources
   → Confirm individual resources are selected: Office 365 Exchange Online, Office
     365 SharePoint Online, Microsoft Teams Services (+ AVD/Windows 365/Windows
     Cloud Login if relevant)
   → Confirm the broad "Office 365" application group is NOT selected — this is an
     explicit, documented exception to the usual CA app-group-selection guidance
     and can cause unintended failures if used here

3. Re-test both fixes together via Report-only/What-If before re-enforcing.
```

**Rollback:** Revert to prior Conditions configuration if the change introduces new unexpected blocking — test incrementally rather than changing both conditions at once in a live-enforced policy.

</details>

<details><summary>Playbook 4 — Close the non-Windows/non-Apple bypass gap</summary>

**Scenario:** Security review identifies that Android, Linux, or other unsupported platforms are not held to any token-binding requirement, because Token Protection cannot be enforced there.

```
1. Confirm this is expected (platform support is Windows GA / Apple Preview only —
   not a configuration gap in the Token Protection policy itself).

2. Add or confirm complementary Conditional Access policies exist:
   - Block access from unknown/unsupported platforms
   - Require device compliance for all known platforms

3. Scope these carefully — the goal is closing the platform bypass gap, not
   blocking legitimate access from platforms genuinely needed by the business.

4. Coordinate with the Conditional Access policy owner before enforcing broadly;
   pilot in Report-only mode first, same as any other CA policy change.
```

**Rollback:** Narrow or remove the compensating policies if they block legitimate access unexpectedly; re-scope rather than disabling outright, since the underlying platform gap remains real either way.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS    Collects Token Protection policy configuration and recent sign-in failure evidence.
.DESCRIPTION Pulls every Conditional Access policy with the token-protection session control
             configured, plus a Log Analytics KQL query (for manual execution) identifying
             devices whose sign-ins failed the policy due to an unsupported device state
             (statusCode 1003). Read-only — makes no policy changes.
.NOTES       Requires: Microsoft.Graph.Identity.SignIns module.
             Auth: Connect-MgGraph -Scopes "Policy.Read.All"
             The KQL portion requires a Log Analytics workspace ingesting Entra sign-in logs
             and must be run separately in Log Analytics / Sentinel — Graph does not expose
             sign-in log detail at this granularity via cmdlet.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Connect-MgGraph -Scopes "Policy.Read.All" -NoWelcome

$Policies = Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.SessionControls.SecureSignInSession.IsEnabled -eq $true }

Write-Host "[OK] Found $($Policies.Count) polic$(if ($Policies.Count -eq 1) { 'y' } else { 'ies' }) requiring Token Protection." -ForegroundColor Cyan

$outputDir = "$env:TEMP\TokenProtection-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$Policies | Select-Object DisplayName, Id, State,
    @{N='IncludeUsers';E={($_.Conditions.Users.IncludeUsers -join ", ")}},
    @{N='IncludeApps';E={($_.Conditions.Applications.IncludeApplications -join ", ")}},
    @{N='Platforms';E={($_.Conditions.Platforms.IncludePlatforms -join ", ")}},
    @{N='ClientAppTypes';E={($_.Conditions.ClientAppTypes -join ", ")}},
    @{N='DeviceFilterRule';E={$_.Conditions.Devices.DeviceFilter.Rule}} |
    Export-Csv "$outputDir\TokenProtection-Policies.csv" -NoTypeInformation

Write-Host "[OK] Policy configuration exported to: $outputDir\TokenProtection-Policies.csv"

Write-Host "`n[INFO] Run the following in Log Analytics (workspace ingesting AADNonInteractiveUserSignInLogs) to find devices failing due to unsupported registration type (statusCode 1003):" -ForegroundColor Yellow
Write-Host @'
AADNonInteractiveUserSignInLogs
| where TimeGenerated > ago(7d)
| where TokenProtectionStatusDetails != ""
| extend parsedBindingDetails = parse_json(TokenProtectionStatusDetails)
| extend bindingStatus = tostring(parsedBindingDetails["signInSessionStatus"])
| extend bindingStatusCode = tostring(parsedBindingDetails["signInSessionStatusCode"])
| where bindingStatusCode == "1003"
| summarize FailureCount = count() by UserPrincipalName, AppDisplayName
| sort by FailureCount desc
'@
```

---

## Command Cheat Sheet

| Purpose | Command / Location |
|---|---|
| Check device registration state on-device | `dsregcmd /status` |
| Check Token Protection binding result for a sign-in | Sign-in logs > [event] > Basic info > "Token Protection - Sign In Session" |
| Check which CA policy evaluated the request | Sign-in logs > [event] > Conditional Access / Report-only tab |
| List CA policies requiring token protection | `Get-MgIdentityConditionalAccessPolicy -All \| Where-Object { $_.SessionControls.SecureSignInSession.IsEnabled }` |
| Enable WAM login for Graph PowerShell | `Set-MgGraphOption -EnableLoginByWAM $true` |
| Exclude Entra-joined Cloud PCs via device filter | `systemLabels -eq "CloudPC" and trustType -eq "AzureAD"` |
| Exclude Entra-joined AVD session hosts via device filter | `systemLabels -eq "AzureVirtualDesktop" and trustType -eq "AzureAD"` |
| Exclude Entra-joined Power Automate hosted machine groups | `systemLabels -eq "MicrosoftPowerAutomate" and trustType -eq "AzureAD"` |
| Exclude Autopilot self-deploying mode devices | `enrollmentProfileName -eq "<your self-deploy profile name>"` |
| Exclude Entra-joined Azure VMs (sign-in extension) | `profileType -eq "SecureVM" and trustType -eq "AzureAD"` |
| Test policy scope for a user/app/context | Entra admin center > Protection > Conditional Access > Policies > What If |
| Review Report-only impact before enforcing | Entra admin center > Protection > Conditional Access > [policy] > Policy impact |
| KQL: devices failing due to unsupported registration (1003) | See Evidence Pack query above |

---

## 🎓 Learning Pointers

- **Token Protection is a token-theft mitigation, not a general-purpose access control — frame it that way when explaining the investment to stakeholders.** It specifically defends against AiTM phishing and stolen-token replay, a threat class that MFA alone does not stop once a token has already been issued. It complements, rather than replaces, standard grant controls and CAE. [MS Docs: Protecting tokens in Microsoft Entra](https://learn.microsoft.com/en-us/entra/identity/devices/protecting-tokens-microsoft-entra-id)

- **The unsupported-device-registration-type list is long, specific, and permanent as currently documented — treat statusCode 1003 as "check the list first," not "investigate a bug."** AVD session hosts, Cloud PCs, bulk-enrolled devices, Autopilot self-deploy kiosks, Power Automate hosted machine groups, and Azure VM sign-in-extension hosts are all excluded by design. [MS Docs: Token Protection deployment guide — Windows](https://learn.microsoft.com/en-us/entra/identity/conditional-access/deployment-guide-token-protection-windows)

- **Browser-based access is never covered, on any platform — this is a protocol-level boundary, not a Preview limitation that will later be lifted for browsers.** Any design that assumes "eventually this will cover Teams Web too" needs to be corrected early, since the architecture fundamentally depends on native/broker-integrated app behavior that a browser session cannot provide.

- **Platform support is asymmetric and evolving — Windows is GA, Apple is Preview, and nothing else is supported at all.** Any tenant with a meaningful non-Windows/non-Apple population needs an explicit compensating strategy (device compliance + platform blocking) rather than assuming Token Protection alone closes the token-theft gap tenant-wide. Re-check current platform status periodically, since Preview features frequently expand scope over time. [MS Docs: Token Protection in Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-token-protection)

- **The Graph property is `sessionControls.secureSignInSession.isEnabled`, not an intuitively-named "tokenProtection" field — worth knowing before writing any Graph-based audit or automation**, since searching the schema for the wrong name is a common early stumbling block. [MS Graph: conditionalAccessSessionControls resource type](https://learn.microsoft.com/en-us/graph/api/resources/conditionalaccesssessioncontrols?view=graph-rest-1.0)

- **`enforcedSessionControls`/`sessionControlsNotSatisfied` values changed from `Binding` to `SignInTokenProtection` in June 2023 — any query, dashboard, or automation should check both strings** to correctly cover historical sign-in log data alongside current data.
