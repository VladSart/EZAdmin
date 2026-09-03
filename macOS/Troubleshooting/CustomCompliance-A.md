# macOS Custom Compliance Settings — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Intune **Custom Compliance Settings** for macOS — the JSON-rules + Bash-discovery-script model that extends the built-in compliance framework, first shipped for Windows and later Linux, and now documented as a third supported platform: macOS
- The macOS-specific discovery script contract (Bash, shebang, exit code AND JSON output — a dual contract distinct from the Windows model)
- macOS-specific script upload options (run as logged-on user vs. system, signature enforcement, notification suppression)
- Terminology clarification against this repo's own pre-existing `Compliance-Policies-A.md` ("Custom Attributes") coverage
- Monitoring and troubleshooting on macOS specifically, including a documented gap in Microsoft's own troubleshooting guidance

**Assumes:**
- Intune P1 or above (custom compliance requires Intune Plan 1+, same licensing floor as Windows/Linux)
- Mac enrolled in Intune MDM (ADE or user-driven enrollment — either is fine)
- The on-device Intune agent (`Microsoft Intune Agent.app`, installed at `/Library/Intune/`) is present and healthy — see `Shell-Script-Failures-A.md` if it is not
- Admin roles: Intune Administrator or Policy and Profile Manager; default Scope Tag assignment (the script-upload workflow does not support custom scope tags)

**Out of scope:**
- Windows and Linux custom compliance mechanics — see `Intune/Troubleshooting/CustomCompliance-A.md`/`-B.md` for the Windows-focused version of this same underlying feature (IME-based, PowerShell discovery scripts). **That file previously stated macOS was unsupported — this is now stale.** As of the current Microsoft Learn documentation (`ms.date` 2026-05-20 / `updated_at` 2026-07-15 on the platform-requirements and discovery-script pages respectively), macOS is a fully documented, supported platform alongside Windows and Linux.
- macOS built-in (non-custom) compliance settings — OS version, FileVault, password policy, SIP, Gatekeeper — see `Compliance-Policies-A.md`/`-B.md`
- The older, simpler macOS "Custom Attributes" shell-script mechanism referenced in `Compliance-Policies-A.md` — see the terminology note below
- iOS/iPadOS custom compliance (not currently documented as a supported platform for this feature)

---

## How It Works

<details><summary>Full architecture</summary>

### The two-artifact model (shared across Windows/Linux/macOS)

Every custom compliance policy is built from exactly two artifacts, both authored by the admin and uploaded separately:

1. **Discovery script** — platform-specific code that runs on the device, reads real settings, and emits a JSON object of discovered values. For macOS, this is a **Bash shell script**.
2. **JSON rules file** — defines which of the discovered JSON keys matter, what value is considered compliant for each, the comparison operator, and the message shown to the end user if the check fails. The JSON file is attached when you configure the compliance policy itself, not when you upload the script.

```
┌───────────────────────────────────────────────────────────────────┐
│                     Intune Service (Cloud)                        │
│                                                                     │
│  Compliance Policy (macOS)                                         │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │  Built-in Settings         Custom Settings                 │   │
│  │  (FileVault, SIP, ...)     (linked Discovery Script + JSON)│   │
│  └────────────────────────────────────────────────────────────┘   │
│              │                          │                         │
│              ▼                          ▼                         │
│         Compliance Engine evaluates on next check-in              │
└─────────────────────────────┬───────────────────────────────────────┘
                              │  Policy + script + JSON downloaded
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│                       Device (macOS)                               │
│                                                                     │
│  Microsoft Intune Agent.app                                        │
│  /Library/Intune/Microsoft Intune Agent.app                        │
│                                                                     │
│  1. Downloads discovery script (Bash, valid shebang required)      │
│  2. Runs script — respects "Run using logged on credentials"       │
│     (Yes = user context; default = elevated/system context)        │
│  3. TWO separate outcomes are captured:                            │
│       a. Exit code   → 0 = script ran successfully                 │
│                         non-zero = script itself FAILED to run     │
│       b. STDOUT       → must be a single valid JSON object         │
│  4. Reports both back to Intune                                    │
└─────────────────────────────┬───────────────────────────────────────┘
                              │  Exit code + JSON reported back
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│                     Intune Service (Cloud)                        │
│                                                                     │
│  If exit code != 0            → device compliance = ERROR          │
│      (script execution failure, JSON rules never evaluated)        │
│  If exit code == 0 but JSON invalid/missing keys → ERROR            │
│  If exit code == 0 and JSON valid → JSON evaluated against rules   │
│      → COMPLIANT or NONCOMPLIANT per key                           │
│                                                                     │
│  → Compliance state published to Entra ID device object            │
│  → Conditional Access evaluates (if required)                      │
└───────────────────────────────────────────────────────────────────┘
```

### The dual-contract gotcha (single highest-value fact in this file)

A macOS discovery script must satisfy **two independent success criteria**, and conflating them is the single most common authoring mistake for admins moving from the Windows model:

| Contract | What it means | What happens if it fails |
|---|---|---|
| **Exit code** | `exit 0` = the script itself ran to completion without a scripting/runtime error. `exit <non-zero>` = the *script* failed — this is NOT the same as "the setting is non-compliant." | Device reports **Error**, not NonCompliant. The JSON rules are never evaluated. |
| **STDOUT JSON** | Must be a single, valid, UTF-8 JSON object containing the keys your JSON rules file references. This is where you report the *actual discovered value*, compliant or not. | Malformed/missing JSON → **Error** state (same bucket as an exit-code failure — Intune does not distinguish the two failure modes in the portal's compliance state itself, only in per-setting detail). |

**The mistake to avoid:** writing `exit 1` when a monitored setting is found to be *non-compliant* (e.g., FileVault is off). That is backwards — a script that successfully determines FileVault is off should `exit 0` (the script worked correctly) and report `{"FileVaultEnabled": false}` in its JSON. Let the **JSON rules engine**, not the script's own exit code, decide compliant vs. non-compliant. Reserve non-zero exit codes strictly for genuine script failures (missing dependency, permission denied, unexpected OS state the script can't handle).

### macOS-specific script requirements

- Must be Bash, with a valid shebang line (`#!/bin/bash`)
- Must be UTF-8 encoded **without a byte-order mark (BOM)** — a BOM silently introduced by some macOS text editors (BBEdit, TextEdit in certain modes) is a real, hard-to-spot failure cause
- Script size ≤ 1 MB; output size ≤ 1 MB
- Run time ≤ **10 minutes** (same ceiling as Windows; Linux's ceiling is 5 minutes — don't assume parity across platforms when porting a script)
- Each compliance policy supports exactly **one** discovery script, but that one script can discover and report **multiple** settings/keys in its JSON output

### macOS-specific upload-time behavior options

When adding the discovery script (**Endpoint security → Device compliance → Scripts → Add → macOS**), three macOS-only toggles configure execution behavior:

| Option | Effect when set to Yes |
|---|---|
| **Run this script using the logged on credentials** | Script runs in the context of the currently logged-on user rather than the elevated agent context. Needed for checks that depend on user-space state (user preferences, per-user login items) that aren't visible to a system-context process. |
| **Enforce script signature check** | Requires the script to carry a valid code signature before the agent will execute it. |
| **Hide script notifications on devices** | Suppresses the on-device notification banner that would otherwise appear when the script runs. |

> Intune does **not** validate script syntax or logic on upload for any platform, including macOS — a script with a typo uploads successfully and only fails at execution time on-device.

### Terminology note: "Custom Attributes" vs. "Custom Compliance Settings"

This repo's own `Compliance-Policies-A.md` documents an older, simpler macOS mechanism it calls **Custom Attributes** — a shell script that returns a single string/integer/date value, consumed by a compliance policy rule, gated behind the same on-device agent (`Microsoft Intune Agent.app`). The feature documented in *this* file — **Custom Compliance Settings**, with its JSON rules file, multi-key discovery scripts, comparison operators, and per-setting remediation messaging — is Microsoft's current, actively documented terminology and the richer of the two models. Treat "Custom Attributes" as the legacy/informal name for the same underlying territory; when scoping new work, build against the JSON + discovery script model described here, and use this file (not the older section) as the source of truth for current behavior.

</details>

---

## Dependency Stack

```
Intune Compliance Policy (macOS, with Custom Compliance settings attached)
        │
JSON rules file (attached to the policy — defines keys, operators, compliant values, user messages)
        │
Discovery Script (uploaded separately as its own object — Bash, macOS platform)
        │
Microsoft Intune Agent.app — /Library/Intune/Microsoft Intune Agent.app
        │
Device enrolled in Intune (MDM enrolled, ADE or user-driven — either works)
        │
Device check-in (device must reach Intune service endpoints)
        │
Entra ID Device Object (compliance state stored here)
        │
Conditional Access (reads compliance state from Entra ID)
        │
Resource Access (Teams, SharePoint, etc. — blocked if non-compliant + CA enforcing)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device shows `Error` compliance state | Non-zero exit code from script, OR malformed/missing JSON on STDOUT | Reports → Device compliance → Noncompliant devices and settings, filtered to this device |
| Device always `NonCompliant` regardless of actual state | JSON key name mismatch between script output and JSON rules file | Compare discovery script's emitted keys against the rules file's key names, character-for-character |
| Device stuck `Not evaluated` / `Unknown` | Intune Agent not installed/healthy, or policy not yet assigned to device's group | `Get-DiskUsage`/agent health checks; confirm group membership |
| Script works when run manually in Terminal, fails via Intune | Script assumes user context but ran as system (or vice versa) — check the "Run using logged on credentials" toggle | Re-test with the same context the toggle configures |
| Non-compliant setting never flips to compliant after on-device fix | Script or policy re-evaluation interval hasn't elapsed yet | Trigger a manual check via Company Portal → Devices → device → **Check Status** |
| `Error` immediately after uploading a new/edited script | BOM accidentally introduced by the text editor used to save the script | Re-save as plain UTF-8 without BOM (`iconv`/`file` on the script to confirm) |
| Script exceeds 10-minute ceiling | Slow network calls or unbounded loops in the discovery script | Add explicit timeouts; profile the script's runtime locally first |
| Discovery script can't read a system-level path | Script assumes elevated context but the toggle is set to run as the logged-on user | Flip "Run using logged on credentials" or redesign the check to avoid the elevation requirement |

---

## Validation Steps

**1. Confirm the Intune Agent is present and recently checked in**

```bash
# On the Mac
ls -la "/Library/Intune/Microsoft Intune Agent.app"
log show --predicate 'subsystem == "com.microsoft.intune"' --last 1h
```

Expected: app bundle present; recent log activity showing check-in traffic.

---

**2. Manually run the discovery script exactly as authored, and inspect both outputs**

```bash
# On the Mac (or a representative test Mac) — run as the context the toggle expects
chmod +x ./discovery-script.sh
./discovery-script.sh
echo "Exit code: $?"
```

Expected: exit code `0`; STDOUT is a single valid JSON object.

---

**3. Validate the JSON is actually parseable**

```bash
./discovery-script.sh | python3 -m json.tool
```

Expected: pretty-printed JSON with no parse error. Any parse error here reproduces the exact `Error` state Intune will report.

---

**4. Confirm no BOM is present in the script file**

```bash
file discovery-script.sh
# Look for "UTF-8 Unicode (with BOM) text" — this is a failure
head -c 3 discovery-script.sh | xxd
# EF BB BF present = BOM — strip it
```

---

**5. Cross-reference the compliance policy's JSON rule key names against script output (Graph)**

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
$policyId = "<CompliancePolicyId>"
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$policyId?`$expand=scheduledActionsForRule" |
    ConvertTo-Json -Depth 6
```

Manually diff the rule's `settingName` values against the discovery script's JSON keys.

---

**6. Check device compliance state and last-reported detail**

```powershell
$deviceId = "<ManagedDeviceId>"
Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId |
    Select DeviceName, ComplianceState, OperatingSystem, LastSyncDateTime

Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $deviceId |
    Select DisplayName, State, SettingCount
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Script Never Runs

1. Confirm `Microsoft Intune Agent.app` is installed and running — if missing, resolve via `Shell-Script-Failures-B.md` first (the same agent drives both features)
2. Confirm the device is in the assigned group for the compliance policy
3. Force a check-in: Company Portal app → **Devices** → select device → **Check Status**
4. Confirm the discovery script itself uploaded without error (Intune does not validate content, but confirm the object exists and is linked to the policy)

---

### Phase 2 — Device Reports `Error`

1. Re-run the script manually on a representative Mac in the exact context configured ("Run using logged on credentials")
2. Check the exit code first — a non-zero exit means the JSON was never evaluated; fix the script's execution path before touching the JSON rules
3. If exit code is `0`, validate the JSON with `python3 -m json.tool` or `jq`
4. Check for a BOM (`file discovery-script.sh`)
5. Confirm output size and script size are each under 1 MB

---

### Phase 3 — Device is `NonCompliant` But the Setting Looks Fine On-Device

1. Extract the exact JSON keys the script emits
2. Compare against the JSON rules file's key names — case and exact spelling matter
3. Confirm the operator and compliant value in the JSON rules file actually match your intent (`IsEqual` vs. `IsNotEqual` is a common inversion mistake)
4. Rebuild the rules file from scratch if a mismatch can't be found by inspection — a single invisible character copy-pasted from a rich-text editor is a known cause

---

### Phase 4 — Compliance State Not Propagating to Conditional Access

1. Compliance state syncs to Entra ID with a short delay after the device reports in
2. Conditional Access evaluates at token issuance, not continuously — an existing session isn't immediately revoked
3. Force re-evaluation: user signs out/in, or revoke sessions:
   ```powershell
   Revoke-MgUserSignInSession -UserId "<UserUPN>"
   ```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Correctly Structured macOS Discovery Script (Template)</summary>

```bash
#!/bin/bash
#
# Custom Compliance Discovery Script — macOS template
# Contract:
#   - exit 0  = script ran successfully (regardless of whether settings are compliant)
#   - exit 1+ = script itself failed to execute correctly
#   - STDOUT  = single valid JSON object with discovered values ONLY

# Example: report FileVault status and a custom app version
FDE_STATUS=$(fdesetup status | grep -q "FileVault is On" && echo "true" || echo "false")

APP_PLIST="/Applications/ContosoAgent.app/Contents/Info.plist"
if [[ -f "$APP_PLIST" ]]; then
    APP_VERSION=$(plutil -p "$APP_PLIST" | grep "CFBundleShortVersionString" | awk -F'"' '{ print $4 }')
else
    APP_VERSION="not_installed"
fi

# Emit JSON — this is the ONLY thing that should go to STDOUT
printf '{"FileVaultEnabled": %s, "ContosoAgentVersion": "%s"}\n' "$FDE_STATUS" "$APP_VERSION"

# The script ran successfully — exit 0 regardless of the discovered values above
exit 0
```

**Common mistake to avoid:** do not `exit 1` when `FDE_STATUS` is `false`. The script succeeded at discovering the state; let the JSON rules file mark that as non-compliant.

</details>

<details><summary>Playbook 2 — JSON Rules File (Template)</summary>

```json
{
  "Rules": [
    {
      "SettingName": "FileVaultEnabled",
      "Operator": "IsEquals",
      "DataType": "Boolean",
      "Operand": true,
      "MoreInfoUrl": "https://contoso.com/filevault-help",
      "RemediationStrings": [
        {
          "Language": "en_US",
          "Title": "Disk encryption is required",
          "Description": "Enable FileVault from System Settings > Privacy & Security > FileVault."
        }
      ]
    },
    {
      "SettingName": "ContosoAgentVersion",
      "Operator": "IsEquals",
      "DataType": "String",
      "Operand": "4.2.0",
      "MoreInfoUrl": "https://contoso.com/agent-update",
      "RemediationStrings": [
        {
          "Language": "en_US",
          "Title": "Agent update required",
          "Description": "Open Company Portal and check for available app updates."
        }
      ]
    }
  ]
}
```

Attach this JSON when configuring the compliance policy's Custom Compliance settings page — not when uploading the discovery script itself, which is a separate object.

</details>

<details><summary>Playbook 3 — Upload Discovery Script via Graph</summary>

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"

$scriptContent = Get-Content -Path "./discovery-script.sh" -Raw -Encoding UTF8
# Confirm no BOM before encoding
$scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptContent))

$body = @{
    displayName        = "macOS Custom Compliance - FileVault + Agent Version"
    detectionScriptContent = $scriptB64
    runAsAccount        = "system"   # or "user" to mirror "Run using logged on credentials"
    enforceSignatureCheck = $false
} | ConvertTo-Json

# NOTE: verify the exact beta resource/property names against the current Graph reference
# before running against production — Intune's script-object schemas have shifted across
# platforms and this call should be validated in a test tenant first.
Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceComplianceScripts" `
    -Body $body -ContentType "application/json"
```

> After upload, link the script and JSON to a compliance policy via the Intune portal — this remains the supported path for wiring the two artifacts together.

</details>

---

## Evidence Pack

```powershell
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All"

$policyId   = "<CompliancePolicyId>"
$deviceId   = "<ManagedDeviceId>"
$outputPath = ".\macOSCustomCompliance-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

Get-MgDeviceManagementManagedDevice -ManagedDeviceId $deviceId |
    ConvertTo-Json -Depth 4 | Out-File "$outputPath\01-Device.json"

Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId $deviceId |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\02-DeviceComplianceState.json"

Write-Host ""
Write-Host "TODO: Also collect from the Mac itself:" -ForegroundColor Yellow
Write-Host "  Manual run of the discovery script + its exit code + raw STDOUT"
Write-Host "  'file discovery-script.sh' output (confirm no BOM)"
Write-Host "  'log show --predicate ''subsystem == \"com.microsoft.intune\"'' --last 4h'"
Write-Host ""
Write-Host "Evidence in: $outputPath"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm Intune Agent present | `ls -la "/Library/Intune/Microsoft Intune Agent.app"` |
| Run discovery script + capture exit code | `./script.sh; echo $?` |
| Validate JSON output | `./script.sh \| python3 -m json.tool` |
| Check for BOM | `file script.sh` / `head -c 3 script.sh \| xxd` |
| FileVault status (example check) | `fdesetup status` |
| Force compliance re-check (on device) | Company Portal app → Devices → device → **Check Status** |
| Get device compliance state (Graph) | `Get-MgDeviceManagementManagedDevice -ManagedDeviceId <id> \| Select ComplianceState` |
| Get per-policy state on device | `Get-MgDeviceManagementManagedDeviceCompliancePolicyState -ManagedDeviceId <id>` |
| Revoke sign-in sessions | `Revoke-MgUserSignInSession -UserId <UPN>` |

---

## 🎓 Learning Pointers

- **The exit code and the JSON output are two separate contracts** — this is the single biggest mental model shift for anyone who has only ever written Windows custom compliance scripts. On Windows, an unhandled exception breaking STDOUT is the main failure mode; on macOS, you must also get the Bash exit code right, independently of what the JSON says. [MS Docs: Custom compliance discovery scripts](https://learn.microsoft.com/en-us/intune/device-security/compliance/create-custom-script)

- **Microsoft's own troubleshooting documentation for this feature is explicitly titled for "Windows and Linux devices"** — the numbered error codes (65007–65010) are documented in that Windows/Linux-scoped section, with no explicit macOS confirmation in the same source. Don't assume 1:1 parity; verify which error surfaces you actually see in your own tenant's compliance reports for macOS before building alerting logic around a specific code. [MS Docs: Use custom compliance settings](https://learn.microsoft.com/en-us/intune/device-security/compliance/custom-settings)

- **"Custom Attributes" and "Custom Compliance Settings" are easy to conflate** — this repo's own `Compliance-Policies-A.md` documents the older, simpler single-value Custom Attributes mechanism. When a colleague says "custom compliance" for a Mac, confirm which of the two they mean before troubleshooting — the JSON rules engine, multi-key discovery, and remediation messaging described in this file only exist in the newer Custom Compliance Settings model.

- **BOM corruption is a silent, editor-dependent failure** — several common macOS text editors can save a UTF-8 file with a byte-order mark without any visible indication. Since the requirement (`UTF-8 without BOM`) is easy to violate accidentally, make `file script.sh` a standard step before every script upload, not just a troubleshooting step after a failure.

- **Test the discovery script in the same execution context the toggle configures, not just interactively as yourself** — "Run using logged on credentials" changes what the script can see (user-space preferences vs. system-level state). A script that works perfectly in your own Terminal session can behave completely differently once deployed if you didn't match the context.
