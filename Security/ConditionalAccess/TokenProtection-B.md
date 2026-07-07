# Token Protection — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [What this is](#what-this-is)
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## What this is

**Token Protection** is a Conditional Access **session control** ("Require token protection for sign-in sessions") that cryptographically binds a user's sign-in session token (their Primary Refresh Token-derived session) to the specific device it was issued on. If an attacker steals that token — via AiTM phishing, malware, or an exfiltrated browser session — it cannot be replayed from a different machine, because the attacker doesn't have the matching device-bound key.

It is **not** the same thing as requiring a compliant or Hybrid Joined device (those checks happen at sign-in time and don't stop a stolen token being reused elsewhere), and it is **not** the same thing as Continuous Access Evaluation (see `EntraID/Troubleshooting/CAE-B.md` — CAE revokes tokens reactively within minutes of a signal; Token Protection prevents a stolen token being usable on another device from the moment it's stolen). Microsoft recommends running both together.

The common ticket pattern: a user, or an entire class of devices, is suddenly **blocked from Outlook/Teams/SharePoint** shortly after a Token Protection Conditional Access policy is enabled or expanded — usually because the device, app, or platform in question falls into one of a well-documented set of unsupported combinations, not because of an actual attack.

**As of this writing:** Token Protection is Generally Available on Windows; iOS/iPadOS and macOS support is in **Preview**. It only protects **native/rich client apps** — browser-based access is never covered.

---

## Triage

Run these first:

```
1. Confirm scope: is this one user, one device, or a whole class of devices (e.g. all AVD hosts, all Cloud PCs)?
   → Ask the user/requester directly — this immediately narrows which fix path applies.

2. Entra admin center > Identity > Monitoring & health > Sign-in logs
   → Find the failed sign-in for the affected user around the reported time
   → Open it > "Basic info" tab > find "Token Protection - Sign In Session"
   → Note the value: Bound / Unbound, and if Unbound, note the statusCode shown alongside it

3. Same sign-in event > "Conditional Access" (or "Report-only") tab
   → Click the policy name requiring token protection
   → Under "Session Controls" confirm whether the requirement was Satisfied or Not satisfied

4. Identify the device's registration/enrollment type
   On the device itself:      dsregcmd /status
   Look for:                  AzureAdJoined / AzureAdRegistered / DomainJoined, and
                               check whether it's an AVD session host, Cloud PC, or
                               Autopilot self-deploying-mode device (ask the requester
                               or check Intune/Entra device properties — SystemLabels)

5. Identify the client app being used
   Sign-in log > "AppDisplayName" / "Client app" columns
   → Confirm whether it's on the supported native-app list (Outlook, Teams, OneDrive,
     Word/Excel/PowerPoint, Edge profile sign-in, etc.) or a browser / unsupported combo
```

| Sign-in log shows | statusCode | Then |
|---|---|---|
| Unbound | **1002** | Device has no Entra ID device state at all — not registered/joined → **Fix 3** |
| Unbound | **1003** | Device state exists but doesn't satisfy the policy — almost always an **unsupported registration type** (AVD Entra-joined host, Entra-joined Cloud PC, bulk-enrolled device, Autopilot self-deploy, Power Automate hosted machine group) → **Fix 1** |
| Unbound | **1005** | Unspecified — treat as inconclusive, re-check device/app/platform manually → **Fix 1** then **Fix 2** |
| Unbound | **1006** | OS version unsupported (pre-Windows 10, or Apple OS below the Preview minimum) → **Fix 4** |
| Unbound | **1008** | Client isn't integrated with the platform broker (WAM) — outdated client, or an app that never brokers through WAM → **Fix 2** |
| Bound | — | Token protection is working correctly for this request — the reported issue is something else entirely; stop here and investigate the actual symptom separately |
| No "Token Protection" field present at all | — | This sign-in wasn't evaluated against a token-protection policy — check policy scoping (app/platform/user) before assuming a compatibility issue |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Device registered with Microsoft Entra ID using a SUPPORTED method
   (Entra joined, Entra Hybrid joined, or Entra registered — Windows 10+/
    Server 2019+ Hybrid joined; Apple: MDM-managed + Enterprise SSO plugin
    or Platform SSO, Preview)
        │
        ▼
   EXCLUDED if registered via an unsupported method:
     - Entra-joined Azure Virtual Desktop session hosts
     - Windows devices deployed via bulk enrollment
     - Entra-joined Windows 365 Cloud PCs
     - Entra-joined Power Automate hosted machine groups
     - Windows Autopilot self-deploying mode devices
     - Azure VMs using the VM extension for Entra ID sign-in
        │
        ▼
Device-bound Primary Refresh Token (PRT) issued, session key held in
device's protected key store (TPM-backed on Windows)
        │
        ▼
Client application is on the SUPPORTED native-app list AND integrates
with the platform broker (WAM on Windows)
   (Outlook, Teams, OneDrive, Word/Excel/PowerPoint, OneNote, To Do, Loop,
    Power BI Desktop, VS Code, Windows App, Edge — profile sign-in only, etc.)
        │
        ▼
   EXCLUDED even on a supported device:
     - Any browser-based access (MSAL.js web apps, e.g. Teams Web)
     - Office "perpetual" (non-subscription) clients
     - PowerShell modules accessing SharePoint
     - PowerQuery for Excel — unless on Current Channel
     - VS Code extensions that reach Exchange/SharePoint directly
     - Surface Hub / Windows-based Microsoft Teams Rooms systems
        │
        ▼
Target resource is one Token Protection actually covers:
   Exchange Online, SharePoint Online, Microsoft Teams
   (Windows only, additionally: Azure Virtual Desktop, Windows 365)
        │
        ▼
Conditional Access policy: Session > "Require token protection for
sign-in sessions", scoped to Windows platform + "Mobile apps and
desktop clients" (NOT Browser) + the specific resources above
        │
        ▼
Sign-in log: "Token Protection - Sign In Session" = Bound → allowed
                                                  = Unbound → blocked (see statusCode)
```

**Key fact:** Token Protection is currently enforceable only on Windows (GA) and Apple platforms (Preview). Android, Linux, and any other platform simply **cannot** be required to use it — if your policy doesn't also block unknown/unsupported platforms or require device compliance broadly, those platforms are an unintended bypass path around this control, not a compatibility bug.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm this is actually a Token Protection block**
```
Sign-in logs > affected event > Basic info > "Token Protection - Sign In Session"
```
Expected: field is present and shows Bound/Unbound + a statusCode if Unbound.
Bad/inconclusive: field is absent entirely — this sign-in wasn't evaluated against a token protection policy; look elsewhere (standard CA grant control, licensing, MFA).

**Step 2 — Read the statusCode and match it to the Triage table above**
```
Same log entry, statusCode field next to "Unbound"
```
This single value tells you which of the 5 fix paths applies — don't skip ahead without it.

**Step 3 — Confirm the device's registration/enrollment type**
```
On-device:  dsregcmd /status
Portal:     Entra admin center > Identity > Devices > All devices > [device] >
            check Join type, and (if applicable) Intune enrollment method
```
Good: registration type is Entra joined / Hybrid joined / Entra registered via a standard flow.
Bad: device is an AVD session host, Cloud PC, bulk-enrolled, or Autopilot self-deploy-mode device — matches statusCode 1003, go to **Fix 1**.

**Step 4 — Confirm the client app is genuinely supported**
```
Sign-in log > AppDisplayName / Client app columns
```
Good: app is on the documented supported list and was used as its native/desktop client.
Bad: app is a browser session, an Office perpetual install, a PowerShell module hitting SharePoint, or a VS Code extension calling Exchange/SharePoint — go to **Fix 2**.

**Step 5 — Confirm policy scope matches intent**
```
Entra admin center > Protection > Conditional Access > [policy] > Conditions > Client apps
```
Good: "Mobile apps and desktop clients" is selected; Browser is NOT selected.
Bad: Browser is included, or Client apps condition wasn't configured at all — this silently blocks MSAL.js web apps like Teams Web. Fix the policy condition directly (this is a policy authoring error, not a device/app compatibility gap).

---

## Common Fix Paths

<details><summary>Fix 1 — Unsupported device registration type (statusCode 1003)</summary>

**When to use:** The device is genuinely on the documented unsupported list — most commonly an Entra-joined AVD session host, an Entra-joined Windows 365 Cloud PC, a bulk-enrolled device, an Entra-joined Power Automate hosted machine group, or an Autopilot self-deploying-mode device. Token Protection **cannot** bind on these today — this is a hard platform limitation, not a misconfiguration to "fix" on the device.

```
1. Confirm the device category via Entra admin center > Identity > Devices > [device]
   (SystemLabels / trust type) or Intune enrollment profile name.

2. Add a device filter EXCLUSION to the Token Protection Conditional Access policy so these
   devices aren't held to a requirement they can never satisfy:

   Entra admin center > Protection > Conditional Access > [policy] > Conditions > Filter for devices

   - Entra-joined Cloud PCs (Windows 365):
       systemLabels -eq "CloudPC" and trustType -eq "AzureAD"
   - Entra-joined Azure Virtual Desktop session hosts:
       systemLabels -eq "AzureVirtualDesktop" and trustType -eq "AzureAD"
   - Entra-joined Power Automate hosted machine groups:
       systemLabels -eq "MicrosoftPowerAutomate" and trustType -eq "AzureAD"
   - Autopilot self-deploying mode devices (adjust profile name to your tenant's):
       enrollmentProfileName -eq "Autopilot self-deployment profile"
   - Entra-joined Azure VMs using the VM sign-in extension:
       profileType -eq "SecureVM" and trustType -eq "AzureAD"

3. Validate: re-test sign-in from an affected device, confirm the policy now shows
   "Not applicable" (excluded) rather than "Failure" for that device in sign-in logs.
```

**Rollback:** Remove the device filter exclusion if added in error. Excluding these devices means they are NOT protected by this control — that gap should be covered by a compensating control (device compliance, network restrictions) since it's a known, permanent limitation rather than a temporary workaround.

</details>

<details><summary>Fix 2 — Unsupported or incompatible client app (statusCode 1005/1008, or Browser-condition gap)</summary>

**When to use:** The client is a browser session, an Office perpetual (non-subscription) install, a PowerShell module reaching SharePoint, a VS Code extension calling Exchange/SharePoint directly, or PowerQuery on a non-Current-Channel Office build.

```
1. Confirm exactly which app/client from the sign-in log's AppDisplayName field.

2. If it's a genuinely unsupported combination (PowerShell-to-SharePoint, VS Code
   extension, non-Current-Channel PowerQuery, Office perpetual):
   - There is no client-side fix — the resource access must go through a supported
     path instead (e.g. use Microsoft Graph PowerShell with -EnableLoginByWAM instead
     of a legacy SharePoint-specific module), or the identity/workflow needs a
     Conditional Access exclusion if it cannot be changed.

3. If it's a browser session that should have been allowed (e.g. Teams Web for a
   user who isn't required to use the desktop app):
   - This is a POLICY SCOPING issue — go to Fix 3, not a client fix.

4. If statusCode is 1008 (client not integrated with the platform broker/WAM):
   - Update the client to a current version.
   - For Microsoft Graph PowerShell specifically, ensure WAM login is enabled:
     Set-MgGraphOption -EnableLoginByWAM $true
```

**Rollback:** N/A — these are hard compatibility limitations, not configuration changes to undo.

</details>

<details><summary>Fix 3 — Device not registered/enrolled at all (statusCode 1002)</summary>

**When to use:** `dsregcmd /status` shows the device is not Entra joined, Hybrid joined, or Entra registered.

```
1. Determine why the device isn't registered:
   - Personal/BYOD device never went through Entra registration →
     have the user complete registration: Settings > Accounts > Access work or school
     > Connect, or see the Microsoft support guide for registering a personal device.
   - Corporate device that should be Entra/Hybrid joined but isn't →
     cross-reference EntraID/Troubleshooting/HybridJoin-B.md for join failures.

2. After registration completes, confirm dsregcmd /status shows AzureAdJoined
   or AzureAdRegistered = YES, then re-test sign-in.
```

**Rollback:** N/A.

</details>

<details><summary>Fix 4 — Unsupported OS version (statusCode 1006)</summary>

**When to use:** Device OS predates the supported minimum (below Windows 10, or below the Apple Preview minimums: macOS 14.0 / iOS-iPadOS 16.0).

```
1. Confirm current OS version on the device.
2. Windows: OS must be upgraded to a supported version — no policy-side workaround exists.
3. Apple (Preview): confirm macOS 14.0+/iOS 16.0+ AND that the Microsoft Enterprise
   SSO plug-in (or Platform SSO for macOS) is configured — the OS version alone
   isn't sufficient without the SSO plugin.
4. If upgrade isn't immediately possible, add a temporary device filter exclusion
   (see Fix 1 pattern) and track the OS upgrade as the real remediation.
```

**Rollback:** Remove any temporary exclusion once the OS is upgraded.

</details>

<details><summary>Fix 5 — Non-Windows/non-Apple platform bypassing the control entirely</summary>

**When to use:** During a security review or incident, you realize Android/Linux/other platforms are not required to satisfy Token Protection at all (because it isn't enforceable there yet), creating a gap relative to the intended "all access to this resource must be token-bound" goal.

```
1. This is expected — Token Protection is Windows (GA) / Apple (Preview) only.
2. Close the gap with COMPLEMENTARY policies, not by trying to force Token
   Protection onto unsupported platforms:
   - Require device compliance for all known platforms
   - Block access from unknown/unsupported platforms
3. Coordinate with whoever owns Conditional Access design for this tenant before
   adding broad block policies — confirm no legitimate access path is cut off.
```

**Rollback:** Remove the added compensating policies if they cause unintended blocking; re-scope rather than disabling outright.

</details>

---

## Escalation Evidence

```
TICKET: Token Protection Sign-In Block
========================================================
Date/Time:                          _______________
Raised by:                          _______________
Affected user(s):                    _______________
Single user, device class, or many?: [ ] Single  [ ] Device class (describe: ___)  [ ] Many

Sign-in log — Token Protection - Sign In Session value:  [ ] Bound  [ ] Unbound
If Unbound, statusCode:              _______________
Client app / AppDisplayName shown:    _______________
Target resource (Exchange/SharePoint/Teams/AVD/W365): _______________
CA policy name requiring token protection: _______________

Device registration type (dsregcmd /status or Entra device properties):
  [ ] Entra joined   [ ] Hybrid joined   [ ] Entra registered   [ ] Not registered
  [ ] AVD session host (Entra-joined)    [ ] Windows 365 Cloud PC (Entra-joined)
  [ ] Bulk-enrolled    [ ] Autopilot self-deploy    [ ] Power Automate hosted machine group
  [ ] Other/unclear: ___________________

Steps taken:
[ ] Checked sign-in log Basic Info for Token Protection - Sign In Session + statusCode
[ ] Confirmed device registration/enrollment type
[ ] Confirmed client app against supported-app list
[ ] Reviewed CA policy's Client apps and Resources scoping
[ ] Checked for existing device filter exclusions on the policy

Result:
_______________________________________________
========================================================
```

---

## 🎓 Learning Pointers

- **Most Token Protection tickets are the platform working exactly as documented, not a bug.** statusCode 1003 (unsupported registration type) accounts for the large majority of "why is this suddenly blocked" reports — AVD session hosts, Cloud PCs, and bulk-enrolled devices are explicitly and permanently excluded from being able to bind. Check the statusCode before assuming misconfiguration. [MS Docs: Token Protection deployment guide — Windows](https://learn.microsoft.com/en-us/entra/identity/conditional-access/deployment-guide-token-protection-windows)

- **The "don't select the Office 365 app group" rule is a deliberate exception to normal Conditional Access authoring guidance** — Token Protection policies must target Exchange Online, SharePoint Online, and Teams Services individually (plus AVD/Windows 365/Windows Cloud Login if relevant), not the broader Office 365 app group, or the policy can produce unintended failures. [MS Docs: Token Protection in Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-token-protection)

- **The Client apps condition is the single easiest way to break Teams Web (or any MSAL.js browser app) by accident.** Scope Token Protection policies to "Mobile apps and desktop clients" only — leaving Browser selected, or leaving the condition unconfigured, silently blocks browser-based sign-in for the targeted resources.

- **`enforcedSessionControls` and `sessionControlsNotSatisfied` changed their string value from `Binding` to `SignInTokenProtection` in June 2023** — any KQL query or automation written before then (or copied from an older blog post) needs both values checked to cover historical and current data.

- **Token Protection, Compliant/Hybrid Joined device grant controls, and Continuous Access Evaluation are three different, complementary defenses — not interchangeable.** Compliant device checks device posture at sign-in time; CAE revokes based on signals within minutes; Token Protection prevents a stolen token from being replayed elsewhere the instant it's stolen. Explaining which gap each one closes is the fastest way to correctly scope a security design conversation. [MS Docs: Protecting tokens in Microsoft Entra](https://learn.microsoft.com/en-us/entra/identity/devices/protecting-tokens-microsoft-entra-id)

- **Always pilot in Report-only mode first, on a small group, and read both interactive and non-interactive sign-in logs before enforcing broadly** — Microsoft's own deployment guidance calls this out because app/device compatibility gaps are common enough that a blind full-tenant rollout will generate a wave of tickets in the first hour.
