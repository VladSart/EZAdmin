# Selective Response Actions — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** Selective Response Actions is an **onboarding-time** decision, not a runtime toggle. A device onboarded in **Restricted** mode cannot have that setting changed later — the only way to change a device's response-action capability is to offboard it and re-onboard it with a new package. The #1 triage mistake is spending time hunting for a portal switch to "just allow Live Response on this one device" — that switch does not exist post-onboarding.

Run these first, in this order:

```powershell
# 1 — Is the tenant feature switch even on? (Defender portal, not PowerShell-readable)
# security.microsoft.com > Settings > Endpoints > Advanced features >
#   "Allow restricted security operations during onboarding"

# 2 — Check this device's current Security operations status
# Portal: Asset rules > Device inventory > find device > "Security operations" column
#   Full      = all response actions available
#   Restricted = high-impact actions were disallowed at onboarding

# 3 — On the device itself, confirm Sense build meets the restricted-mode floor (10.8798+)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection" -Name "SenseVersion" -EA SilentlyContinue

# 4 — Confirm exactly which capability is blocked via Advanced Hunting
#     (portal: security.microsoft.com > Advanced hunting)
# DeviceInfo
# | where DeviceId == "<deviceId>"
# | project DeviceName, RestrictedDeviceSecurityOperations
# | take 1

# 5 — Try the action via the public API to get the authoritative error, not a guess
# A restricted action attempted via API returns an explicit "operation isn't allowed on the device" error —
# use this to confirm restriction is the actual cause before opening a bigger investigation
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| "Isolate device" / "Run AV scan" / other response action greyed out or fails for one specific device only | Device onboarded in Restricted mode with that capability category unselected | Fix 1 |
| Live Response session won't run **scripts** even though Live Response itself is enabled | Restricted mode always blocks Live Response *script execution* by design — not a bug, not fixable without re-onboarding | Fix 2 |
| Need to change which actions are allowed on an already-onboarded device | Not possible in place — requires offboard + re-onboard with a new package | Fix 3 |
| "Restricted" onboarding option missing entirely from the Defender deployment tool (DDT) | Tenant feature switch is off | Fix 4 |
| Alerts/detections seem to have stopped on a Restricted-mode device | Misdiagnosis — restricted mode does NOT affect detection, alerting, or sensor coverage; investigate as a normal sensor-health issue instead | Fix 5 |
| Device is a Tier-0 asset (DC, ADFS) and needs this protection but isn't onboarded yet | Standard first-time onboarding using a Restricted package | Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for Restricted mode to work</summary>

```
[Microsoft Defender for Endpoint tenant]
    └── [Advanced features > "Allow restricted security operations during
         onboarding" switch = ON]
            └── [Defender deployment tool (DDT) package generated with
                 "Restricted" selected + specific capabilities checked/unchecked]
                    ├── Basic response    (AV scan, collect file, collect investigation package)
                    ├── Advanced response (isolate device, restrict app execution,
                    │                      request remediation)
                    ├── Live response     (session allowed — but scripts inside the
                    │                      session are STILL always blocked in Restricted mode)
                    └── Device protection (automated investigation and response / AIR)
                            └── [Device onboarded using that specific package]
                                    └── [Security operations status = "Restricted",
                                         permanently, until offboard + re-onboard]
```

**Key fact:** Restricted mode with every single capability checkbox enabled is still **not** the same as Full mode — Live Response script execution is unconditionally disabled in Restricted mode regardless of which boxes are ticked. There is no configuration that reproduces Full mode's script-execution capability from a Restricted package.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm the tenant switch is on.**
   Settings > Endpoints > Advanced features > "Allow restricted security operations during onboarding" = enabled.
   If off: no device in this tenant can be onboarded Restricted, and the DDT won't offer the option — this is Fix 4, not a per-device issue.

2. **Confirm the device's actual status, not an assumption.**
   Device inventory > device > **Security operations** column/tag. Full vs Restricted. A device tagged "Restricted security operations" on the Device page confirms this runbook applies; a Full-mode device with a failing action needs a different runbook (standard response-action troubleshooting).

3. **Read the exact restriction, don't guess.**
   Device page > **View security operations information** > Device Security Operations pane lists every capability and its enabled/disabled state individually.

4. **Cross-check via Advanced Hunting for a definitive, queryable answer:**
   ```kusto
   DeviceInfo
   | where DeviceId == "<deviceId>"
   | project Timestamp, DeviceName, RestrictedDeviceSecurityOperations
   | order by Timestamp desc
   | take 1
   ```
   A value of e.g. `LiveResponse` means only Live Response is disallowed; other categories remain available. An empty/null value on a device tagged Restricted means check the Device page directly — the property reflects the *category names* that are limited, not a full/restricted boolean.

5. **If attempted via the public API, capture the actual error response** — it explicitly states the operation isn't allowed on the device, which is stronger escalation evidence than a portal screenshot alone.

---
## Common Fix Paths

<details><summary>Fix 1 — A specific response action is blocked on a Restricted-mode device</summary>

1. Confirm via the Device Security Operations pane (Diagnosis step 3) exactly which category the failing action falls under (Basic response / Advanced response / Live response / Device protection).
2. This is **expected, by-design behavior** for a device onboarded Restricted with that category unchecked — not a bug.
3. If the business need for that action is genuine and ongoing (not a one-off), this requires offboard + re-onboard with a new package that includes the needed capability — see Fix 3. There is no per-incident override.
4. If the need is a genuine emergency on a Tier-0 asset, escalate to whoever owns the onboarding-package decision for that asset class before offboarding a production domain controller or ADFS server unilaterally.

</details>

<details><summary>Fix 2 — Live Response won't execute scripts</summary>

1. Confirm Live Response itself is enabled in the device's onboarding package (Device Security Operations pane) — if it shows enabled but scripts still won't run, this is not a misconfiguration.
2. **Restricted mode unconditionally blocks Live Response script execution**, even when the Live Response category checkbox is selected. This is explicit, documented, by-design behavior — Microsoft states restricted mode "does not support Live Response script execution... even if Live Response is enabled."
3. Interactive Live Response commands (non-script) may still work depending on the exact capability set — verify against the current Device Security Operations pane rather than assuming full interactive parity with Full mode.
4. If script execution is a hard requirement for this device, the only path is re-onboarding via Full mode (Fix 3) — weigh that against the operational-stability reason the device was Restricted in the first place before doing so.

</details>

<details><summary>Fix 3 — Need to change an already-onboarded device's allowed actions</summary>

**There is no in-place edit.** Security operations configuration is locked at onboarding time.

1. Generate a new Defender deployment tool package with the desired capability set (Restricted-with-different-boxes-checked, or Full).
2. Offboard the device from Defender (standard offboarding procedure — Device page > Offboard, or via Graph/API).
3. Re-onboard using the new package.
4. Confirm: the **device ID remains the same** and all historical alerts/timeline/investigation data are preserved across the offboard/re-onboard cycle — this is not a loss-of-history operation, just a capability-reconfiguration one.
5. Re-verify the new Security operations status on the Device page post-onboarding.

**Rollback note:** if the re-onboard doesn't achieve the intended result, the same offboard/re-onboard cycle is the only rollback path — plan a maintenance window for Tier-0 assets rather than iterating live.

</details>

<details><summary>Fix 4 — "Restricted" option missing from the DDT package screen</summary>

1. security.microsoft.com > Settings > Endpoints > Advanced features > enable **"Allow restricted security operations during onboarding."**
2. Re-open the deployment package generation flow (System > Settings > Endpoints > Onboarding > Windows > Onboard) — Restricted should now appear alongside Full functionality.
3. This is a tenant-wide switch; it does not need to be re-enabled per package once turned on.

</details>

<details><summary>Fix 5 — Alerts/detections appear to have stopped on a Restricted-mode device</summary>

1. Stop — this is very unlikely to be caused by Restricted mode. Microsoft states explicitly that restricted mode "does not impact detection, alerting, or sensor coverage. All alerts, timelines, and threat detections continue to function as expected."
2. Investigate as a standard sensor-health problem instead: `Get-Service Sense, WinDefend`, onboarding status, cloud connectivity (`MpCmdRun.exe -SenseCncProxyTest`) — see the MDE onboarding runbook for the full triage path.
3. Do not spend time re-onboarding a Restricted device as a "fix" for a detection gap — it will not address a sensor-health root cause and burns a maintenance window for nothing.

</details>

<details><summary>Fix 6 — Onboarding a new Tier-0 asset with restricted response actions</summary>

1. Confirm the tenant switch is on (Fix 4).
2. System > Settings > Endpoints > Onboarding > choose **Windows** > **Onboard** > Generate Defender deployment tool with an access key.
3. Name the package descriptively (e.g., `DC01-Restricted-2026Q3`), set the **shortest reasonable expiration date** (up to 1 year, but shorter reduces the risk of an old package being reused later), select **Restricted**, and check only the capability categories the asset actually needs.
4. Generate, copy the access key, download the tool, and onboard per the standard [Defender deployment tool](https://learn.microsoft.com/en-us/defender-endpoint/defender-deployment-tool-windows) procedure.
5. Confirm the prerequisite Sense build/KB is installed first (see Learning Pointers) — onboarding will not silently fall back to Full mode if the OS/KB floor isn't met, so verify the OS build table before attempting Restricted onboarding on down-level Windows Server/10/11 builds.
6. Post-onboarding, confirm Device inventory shows **Restricted** and the **"Restricted security operations"** tag is present on the Device page.

</details>

---
## Escalation Evidence

```
SELECTIVE RESPONSE ACTIONS — ESCALATION TEMPLATE
============================================
Tenant:                     <tenant name/ID>
Device(s) affected:         <device name(s) / DeviceId>
Tenant feature switch:      <confirmed ON / OFF — Advanced features>
Device Security operations: <Full / Restricted>
Restricted categories:      <Basic / Advanced / Live response / Device protection — which are disallowed>
RestrictedDeviceSecurityOperations (Advanced Hunting): <paste value>
Onboarding package name:    <if known>
Action attempted:           <which response action failed>
API error (if attempted):   <paste exact error text>
Business justification:     <why this action/capability is needed now>
Requested change:           <offboard+re-onboard with new capability set / informational only>
```

---
## 🎓 Learning Pointers

- Selective Response Actions is an **onboarding-time-only** decision — there is no runtime "unlock this one action" switch. Plan the capability set for Tier-0 assets carefully before generating the package, since changing it later means an offboard/re-onboard maintenance window, not a settings tweak. [Restrict response actions on high-value assets](https://learn.microsoft.com/en-us/defender-endpoint/restrict-response-actions-high-value-assets)
- Live Response **script execution is always blocked** in Restricted mode, independent of which capability boxes were checked — "Restricted mode with all response actions allowed is not equivalent to full functionality," per Microsoft's own documentation. Don't assume checking every box reproduces Full mode.
- Restriction requires a **minimum Sense sensor version (10.8798+)** and, on most in-support OS builds, a specific 2025-era cumulative update — verify the KB/build table on the live Learn page before attempting to onboard a down-level device this way; a failed prerequisite will not produce an obvious "wrong version" error in the portal.
- Restricted mode does **not** reduce detection or alerting fidelity — it only restricts which *response* actions cloud admins/API callers can remotely trigger. Don't use it as a justification when investigating a genuine detection gap.
- The restriction is enforced **on the sensor and via the public API both** — a caller attempting a disallowed action through Graph/the public API gets an explicit error, so API-based automation (SOAR playbooks, Logic Apps) needs the same Tier-0 capability-set awareness as manual portal use.
- See [Manage predictive shielding](https://learn.microsoft.com/en-us/defender-xdr/shield-predict-threats-manage) and this repo's `PredictiveShielding-B.md` for a related but distinct autonomous Defender capability — predictive shielding decides *when* to act; Selective Response Actions decides *what a human/API caller is even allowed to trigger* on a given device. The two are not the same control surface.
