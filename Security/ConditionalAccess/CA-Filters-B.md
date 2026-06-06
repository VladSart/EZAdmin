# Conditional Access — Policy Filters Hotfix Runbook (Mode B: Ops)
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

Run these to identify whether a CA filter is the cause of unexpected include/exclude behaviour.

| Check | Where | If X → Do Y |
|-------|-------|-------------|
| **1. Is it definitely a CA policy blocking/bypassing?** | Entra Sign-in logs → Conditional Access tab on the sign-in event | Shows each policy and its result (Success/Failure/Not Applied/Report-Only) → identify the specific policy with unexpected behaviour |
| **2. Does the policy use a filter for devices or users?** | Entra → Protection → CA → open the policy → Conditions | Filter for devices: `device.xxx -eq "yyy"` syntax; Filter for users (preview): similar syntax → go to Fix 1 |
| **3. Does the device have the expected attribute value?** | Entra → Devices → find the device → Properties | Compare `extensionAttribute`, `trustType`, `isCompliant`, `managementType`, `operatingSystem` against the filter rule |
| **4. Is the filter Include or Exclude mode?** | Policy → Conditions → Filter for devices → Mode | Include = only devices matching filter are in scope; Exclude = matching devices are excluded. Reversed mode = inverted behaviour |
| **5. When was the device attribute last updated?** | Entra → Device → Properties → Modified date | Entra device sync can lag up to 15 min after Intune compliance change → fix: wait or force sync (Fix 4) |

**Interpretation table**

| Symptom | Most Likely Cause |
|---------|------------------|
| Policy applies to all devices even though filter should exclude compliant ones | Filter mode set to "Include" instead of "Exclude" (or syntax error in rule) |
| Policy never applies to any device | Filter has typo or wrong attribute value; device doesn't populate that attribute |
| Policy works for some users but not others | Mixed device states: some devices meet filter, some don't — expected behaviour |
| Policy stopped working after Intune compliance change | Entra device attribute not yet synced from Intune — wait up to 15 min |
| extensionAttribute filter never matches | extensionAttribute must be set manually on the Entra device object via Graph/PowerShell |
| Filter using `device.managementType` doesn't match as expected | Only "MDM" and "EAS" are valid values; Intune-enrolled = "MDM" |

---

## Dependency Cascade

<details><summary>What must be true for a CA device filter to evaluate correctly</summary>

```
User signs in
  └─ CA engine evaluates all enabled policies
       └─ Policy has "Filter for devices" condition
            └─ Device context available in sign-in token
                 ├─ Device must be registered in Entra ID (not just compliant)
                 │    └─ Hybrid join: device synced from on-prem AD via Entra Connect
                 │    └─ Entra join / Intune enroll: device registered in Entra devices
                 └─ Device attributes must be populated
                      ├─ isCompliant ← populated by Intune, syncs to Entra (~15 min lag)
                      ├─ trustType ← set at join/register time (AzureAD / ServerAD / Workplace)
                      ├─ managementType ← MDM or EAS
                      ├─ operatingSystem ← set at registration
                      ├─ model / manufacturer ← set at registration
                      └─ extensionAttribute1-15 ← NOT auto-populated, set manually via Graph
  └─ Filter rule evaluates (RSQL-like syntax)
       └─ Mode: Include → policy scopes to matching devices only
       └─ Mode: Exclude → policy excludes matching devices
```

**Key gotcha:** A device must be registered in Entra ID for device-based CA filters to work. Unregistered personal devices will fail the filter check even if the filter is "Exclude compliant devices" — the device has no attributes, so the filter cannot evaluate, and the policy falls through to its grant/block controls.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Find the sign-in with unexpected CA behaviour**
```
Entra ID → Monitoring → Sign-in logs
Filter: User = <affected UPN>, Date = <incident time>
Open sign-in → Conditional Access tab → find the policy → note the result and reason
```
Expected: Policy result is "Success" (grant applied) or "Not Applied" (user/device out of scope)  
Unexpected: Policy is "Failure" when it shouldn't be, or "Not Applied" when it should apply

---

**Step 2 — Check the filter rule syntax**
```
Entra → Protection → Conditional Access → <policy name>
→ Conditions → Filter for devices → Rule syntax box
```
Valid filter examples:
```
device.isCompliant -eq True
device.trustType -eq "ServerAD"
device.extensionAttribute1 -eq "ManagedDevice"
device.operatingSystem -in ["Windows", "iOS"]
```
Common syntax mistakes:
- `True`/`False` must be unquoted boolean (not `"True"`)
- String values must use double quotes: `-eq "value"` not `-eq 'value'`
- Operator is `-eq`, `-ne`, `-in`, `-notIn` (not `==` or `!=`)

---

**Step 3 — Check the actual device attributes in Entra**
```powershell
# Connect with Graph
Connect-MgGraph -Scopes "Device.Read.All" -NoWelcome

# Find the device
$device = Get-MgDevice -Filter "displayName eq '<deviceName>'" -Top 1

# Check the attributes CA filters use
$device | Select-Object DisplayName, OperatingSystem, TrustType, IsManaged, IsCompliant,
    @{N='ManagementType'; E={$_.ManagementType}},
    @{N='ExtAttr1'; E={$_.ExtensionAttributes.extensionAttribute1}}
```
Compare the actual values against what the filter rule expects.

---

**Step 4 — Check filter mode (Include vs. Exclude)**
```
Policy → Conditions → Filter for devices
Note: "Configure" = Yes, Mode = Include OR Exclude
```
- **Include mode**: policy applies ONLY to devices matching the filter. Devices NOT matching are excluded from the policy entirely.
- **Exclude mode**: devices matching the filter are excluded from the policy. Devices NOT matching are still in scope.

A common mistake: setting filter mode to "Include" thinking it means "include these devices as exceptions" — it actually restricts the policy to only those devices.

---

**Step 5 — Simulate the policy evaluation**
```
Entra → Protection → CA → What If
User: <UPN>
Device: <device name or ID>
App: <target app>
→ Check which policies apply and why
```
The "What If" tool evaluates filter rules against the device's actual Entra attributes and shows whether the device matches.

---

## Common Fix Paths

<details><summary>Fix 1 — Correct filter rule syntax error</summary>

**Problem:** Filter rule has a syntax error causing policy to evaluate incorrectly.

**Check current rule:**
```
Policy → Conditions → Filter for devices → Edit → copy the rule text
```

**Valid syntax reference:**
```
# Single condition
device.isCompliant -eq True

# Multiple conditions (AND)
device.trustType -eq "AzureAD" -and device.isCompliant -eq True

# Multiple conditions (OR)  
device.trustType -in ["AzureAD", "ServerAD"]

# Not equal
device.extensionAttribute1 -ne "Kiosk"

# Combine
(device.trustType -eq "AzureAD" -or device.trustType -eq "ServerAD") -and device.isCompliant -eq True
```

**Fix:** Correct the rule → Save → test with What If tool.

**Rollback:** Revert to previous rule text (copy it before changing).

</details>

---

<details><summary>Fix 2 — Switch filter mode between Include and Exclude</summary>

**Problem:** Policy is scoping to wrong set of devices because Include/Exclude mode is backwards.

**Common scenario:** Engineer creates a policy to block legacy auth, wants to exclude compliant devices, but sets mode to "Include" — now the policy only applies to compliant devices (inverted intent).

**Fix:**
```
Policy → Conditions → Filter for devices → Edit
Toggle "Mode" from Include → Exclude (or vice versa)
Save → test with What If
```

**What each mode does:**
- **Exclude**: devices matching the filter are removed from the policy's scope. Everyone else is still evaluated.
- **Include**: only devices matching the filter are in the policy's scope. Everyone else is untouched by this policy.

Use **Exclude** for "apply to all EXCEPT these devices."  
Use **Include** for "apply ONLY to these devices."

</details>

---

<details><summary>Fix 3 — Set an extensionAttribute on a device for filter targeting</summary>

**Problem:** Filter rule uses `device.extensionAttribute1 -eq "ManagedDevice"` but the attribute is blank — no devices match.

**Why:** `extensionAttribute1–15` on Entra device objects are NOT auto-populated. They must be set manually via Graph.

**Set the attribute via Graph PowerShell:**
```powershell
Connect-MgGraph -Scopes "Device.ReadWrite.All" -NoWelcome

# Find the device
$device = Get-MgDevice -Filter "displayName eq '<deviceName>'" -Top 1

# Set extensionAttribute1
$body = @{
    extensionAttributes = @{
        extensionAttribute1 = "ManagedDevice"
    }
}
Update-MgDevice -DeviceId $device.Id -BodyParameter $body
Write-Host "Updated extensionAttribute1 on $($device.DisplayName)"
```

**Set in bulk (from a CSV with DeviceName and AttributeValue columns):**
```powershell
Import-Csv .\devices.csv | ForEach-Object {
    $device = Get-MgDevice -Filter "displayName eq '$($_.DeviceName)'" -Top 1
    if ($device) {
        Update-MgDevice -DeviceId $device.Id -BodyParameter @{
            extensionAttributes = @{ extensionAttribute1 = $_.AttributeValue }
        }
        Write-Host "Set $($_.DeviceName) → $($_.AttributeValue)"
    } else {
        Write-Warning "Device not found: $($_.DeviceName)"
    }
}
```

**Note:** The attribute takes effect in CA policy evaluation within a few minutes of being set.

</details>

---

<details><summary>Fix 4 — Force device attribute sync after Intune compliance change</summary>

**Problem:** Intune marked the device compliant/non-compliant but the CA filter still sees the old value.

**Why:** Entra device attributes (`isCompliant`, `managementType`) are synced from Intune on a background schedule (~15 minutes). CA evaluates the Entra-side values.

**Fix A — Wait:**
Wait 15–20 minutes after the Intune compliance state change, then retry sign-in.

**Fix B — Force Intune sync on the device:**
```
Intune Admin Center → Devices → find device → Sync
OR have the user open Company Portal → tap/click Sync
```
Then wait a few minutes for the sync to propagate to Entra.

**Fix C — Force refresh device token:**
On the device:
```powershell
# Force a new Primary Refresh Token (PRT) which refreshes device claims
dsregcmd /refreshprt

# Then sign out and back in to the app, or clear the token cache:
# Office apps: File → Account → Sign Out → Sign In
```

**Verify compliance state in Entra:**
```powershell
(Get-MgDevice -Filter "displayName eq '<deviceName>'" -Top 1).IsCompliant
```

</details>

---

<details><summary>Fix 5 — Handle unregistered devices with device filters</summary>

**Problem:** Filter rule expects `device.isCompliant -eq True` but some sign-ins bypass it because the device isn't registered in Entra ID (personal/unmanaged device).

**Why:** Unregistered devices have no device object in Entra — the filter cannot evaluate, so the device is treated as if it doesn't match an Include filter (excluded from scope) or matches an Exclude filter (excluded from scope). The net result is the policy doesn't apply as expected.

**Fix — Add a separate policy that blocks or grants on no-device-context:**
```
Create new CA policy:
  Users: All users (or same target as the filter policy)
  Apps: same target apps
  Conditions:
    Filter for devices: NOT CONFIGURED
    OR: Filter set to include device.trustType -in ["AzureAD","ServerAD"] (Exclude mode = invert)
  Grant: Block access (or Require compliant device)
```

**Check what device context is present in sign-in logs:**
```
Sign-in log → Device info tab
Device ID: "(blank)" → no registered device context in this sign-in
Device ID: <GUID> → registered device, filter can evaluate
```

If Device ID is blank and your filter is "Exclude compliant devices," the device is NOT excluded — the policy applies in full. Add a requirement for device compliance or registration at the grant level.

</details>

---

## Escalation Evidence

```
CONDITIONAL ACCESS FILTER ISSUE — ESCALATION TICKET
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Tenant ID:           ___________________________________
Policy Name:         ___________________________________
Policy ID:           ___________________________________
Affected User (UPN): ___________________________________
Device Name:         ___________________________________
Device ID (Entra):   ___________________________________
Sign-in time:        ___________________________________
Sign-in ID (GUID):   ___________________________________ (from sign-in log)

Filter rule (exact text):
___________________________________________________________________

Filter mode:  [ ] Include  [ ] Exclude

Expected behaviour:  ___________________________________
Actual behaviour:    ___________________________________

Sign-in log CA result for this policy: ___________________________________
Sign-in log CA failure reason: ___________________________________

Device attributes (from Get-MgDevice output):
  isCompliant:        ___
  trustType:          ___
  isManaged:          ___
  managementType:     ___
  operatingSystem:    ___
  extensionAttribute1: ___

What If tool result:  ___________________________________

Steps taken:
[ ] Verified filter rule syntax
[ ] Checked filter mode (Include/Exclude)
[ ] Verified device attributes in Entra
[ ] Ran What If simulation
[ ] Forced Intune sync and waited 15 min
[ ] Tested after dsregcmd /refreshprt

Attach:
- Sign-in log event JSON (copy from "..." → Download JSON in sign-in log)
- Screenshot of policy filter rule
- Get-MgDevice output for the affected device
```

---

## 🎓 Learning Pointers

- **"Include" mode does not mean "include as exceptions."** Include mode restricts the policy to only matching devices. It's the opposite of most people's intuition. For bypass/exclusion, use **Exclude** mode. [CA filter for devices docs](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-condition-filters-for-devices)

- **extensionAttributes on devices are not auto-populated — ever.** Unlike user extensionAttributes (which can be synced from on-prem AD), device extensionAttributes must be set via Graph. Build an Intune Remediation or Logic App to maintain them if you use them in filters. [Device management docs](https://learn.microsoft.com/en-us/graph/api/device-update)

- **The What If tool is your best friend for filter debugging.** It simulates policy evaluation against an actual device and user combination using their real Entra attributes — far faster than reading policy logic manually. Always use it before telling a user to sign out and back in. [What If tool docs](https://learn.microsoft.com/en-us/entra/identity/conditional-access/what-if-tool)

- **Device attributes in CA are evaluated at token issuance time, not real-time.** When Intune marks a device non-compliant, the `isCompliant` flag in Entra updates on background sync. The user's existing access token remains valid until expiry (default 1 hour). Continuous Access Evaluation (CAE) can shorten this for critical revocations. [CAE docs](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-continuous-access-evaluation)

- **A blank Device ID in sign-in logs means device filters cannot evaluate.** Check the "Device info" tab of the sign-in event. If the device hasn't registered in Entra, no filter expression will match — the device is effectively outside the filter's scope. Design policies with this edge case in mind.

- **Filter rules support complex boolean logic with parentheses.** Use `(A -or B) -and C` grouping for precise targeting. Test every rule variant in What If before enabling a policy in Report-Only mode first, then Enabled. [Filter rule syntax reference](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-condition-filters-for-devices#filter-for-devices-rules)
