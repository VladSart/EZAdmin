# Endpoint DLP Protection for Excluded Windows Folders — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Triage

Run these within the first 60 seconds to classify the problem. This feature (Microsoft 365 Roadmap ID 562992, Message Center MC1384420) has **no dedicated PowerShell/Graph read or write surface** — the excluded-folder list and its new "protected" opt-in flag are configured entirely in the Purview portal (**Data loss prevention > Overview > Data loss prevention settings > Endpoint settings > File path exclusions for Windows**). Triage instead leans on the local Defender client prerequisite and the DLP policies that must be extended to cover the newly-protected paths.

```powershell
# 1. Local Defender anti-malware client version — hard prerequisite (4.18.26051 or later)
Get-MpComputerStatus | Select-Object AMProductVersion, AMServiceVersion, AntivirusSignatureLastUpdated

# 2. Same check against a remote device (requires PS remoting / WinRM to the endpoint)
Invoke-Command -ComputerName <deviceName> -ScriptBlock {
    Get-MpComputerStatus | Select-Object AMProductVersion, AMServiceVersion
}

# 3. Is the device even onboarded to Endpoint DLP at all? (Intune-managed Windows population, via Graph)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All |
    Select-Object DeviceName, OSVersion, LastSyncDateTime | Sort-Object LastSyncDateTime

# 4. Which DLP policies are scoped to the Devices workload and could need extending to cover protected paths?
Connect-IPPSSession -UserPrincipalName <adminUPN>
Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" } |
    Select-Object Name, Mode, Enabled, Workload

# 5. Recent Endpoint DLP activity for the user/device in question — did anything even fire?
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -PageSize 100 |
    Where-Object { $_.Workload -eq "EndpointDevices" } |
    Select-Object PolicyName, RuleName, UserId, DeviceName, Action, Timestamp
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| `AMProductVersion` below `4.18.26051` | Device cannot receive protected-excluded-folder enforcement yet — this is the #1 cause of "I turned it on and nothing happens" | Go to Fix 1 |
| Device missing entirely from the Intune Windows managed-device list | Device isn't Intune-managed / not in scope for Endpoint DLP onboarding at all — a much bigger prerequisite gap than this feature | Escalate as an onboarding gap, not a feature bug |
| No DLP policy scoped to `EndpointDevices` workload | The base Endpoint DLP policy layer doesn't exist yet — protected-excluded-folder is an *extension* of existing policy, not a standalone toggle | Go to Fix 2 |
| Policy exists, client version is current, but files in `AppData` still aren't flagged | Path likely hasn't been added to the **protected exclusion paths** list in the portal, or policy hasn't been extended to cover it | Go to Fix 3 |
| User in audit mode reports a block, or vice versa | Check for **both** an audit-mode and a block-mode policy matching the same user — block always wins when both apply | Go to Fix 4 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft Purview Endpoint DLP onboarded device] (Windows, Intune or onboarding script)
        └── [Microsoft Defender anti-malware client 4.18.26051 or later] ── HARD PREREQUISITE
              └── [Endpoint DLP central settings] (Purview portal, tenant-wide, portal-only — no cmdlet)
                    ├── [File path exclusions for Windows] (base layer, pre-existing)
                    │     ├── Default-excluded: %SystemDrive%\Users\*(1)\AppData\Roaming
                    │     ├── Default-excluded: %SystemDrive%\Users\*(1)\AppData\Local
                    │     └── Any admin-added custom exclusion path
                    └── [Protected exclusion paths] (NEW — Roadmap 562992, GA mid-late Sept 2026)
                          │   Opt-in flag: marks specific excluded paths as still subject to
                          │   DLP policy checks during EGRESS actions only (copy, print,
                          │   save-to-network-share, cloud upload). Files in a protected-
                          │   excluded path are NOT scanned/audited at rest or on open —
                          │   only when they leave the device via a monitored activity.
                          └── [DLP policy scoped to Devices workload, with rules covering
                                the relevant egress activities] ── must exist and be extended
                                to actually enforce against the newly-protected paths
                                      ├── Audit mode → action proceeds, logged only
                                      └── Block mode → action prevented
                                            (if both apply to the same user: BLOCK WINS)
```

The protected-exclusion flag does nothing on its own — it only changes what the *existing* DLP policy layer is allowed to see. A tenant with no Devices-scoped DLP policy at all will see zero behavior change no matter how the exclusion list is configured.

</details>

---

## Diagnosis & Validation Flow

1. **Confirm the client-version prerequisite first, always.**
   `Get-MpComputerStatus` (Triage step 1/2) against `4.18.26051`.
   *Good:* version meets or exceeds the floor.
   *Bad:* version is older — this alone fully explains no-enforcement symptoms; nothing else in this runbook matters until the client updates.

2. **Confirm the tenant has actually received the GA rollout.**
   In the Purview portal: **Data loss prevention > Overview > Data loss prevention settings > Endpoint settings > File path exclusions for Windows**. Look for a per-path "Protect files in this excluded folder" (naming may vary slightly by rollout wave) toggle or equivalent column next to the exclusion list.
   *Good:* the control is visible.
   *Bad:* not visible — this is a staged-rollout timing gap (GA window: mid-September 2026 through end of September 2026, Worldwide standard multi-tenant only as of this writing). There is no tenant-level switch to force it early.

3. **Confirm the specific path is actually marked protected, not just excluded.**
   Being on the exclusion list is the *default* state for `AppData\Roaming` and `AppData\Local` — that alone does not enable protection. Compare the exact path syntax in the portal against the file location the client is testing; the same wildcard/subfolder-depth syntax rules as general file path exclusions apply (`\` = folder-only, `\*` = subfolders-only, `(number)` = exact subfolder depth).
   *Good:* path is present and explicitly marked protected.
   *Bad:* path absent, misspelled, or wrong wildcard depth — proceed to Fix 3.

4. **Confirm a Devices-scoped DLP policy rule actually covers the egress activity being tested.**
   `Get-DlpCompliancePolicy` / policy rule detail in the portal — check that Copy-to-USB, Cloud-upload, Print, or Network-share-save (whichever the test used) is one of the rule's monitored activities.
   *Good:* the specific activity is covered.
   *Bad:* protection is configured but the activity type itself isn't in scope — extend the rule (Fix 2).

---

## Common Fix Paths

<details><summary>Fix 1 — Defender client below the 4.18.26051 floor</summary>

1. Confirm current version: `Get-MpComputerStatus | Select AMProductVersion`.
2. Update via the normal Microsoft Defender Antivirus platform update channel (Windows Update, WSUS, or Intune-managed update ring) — there is no separate manual installer path recommended for this specific floor.
3. Re-run Triage step 1 after the next scheduled update cycle; force with:
   ```powershell
   Update-MpSignature
   ```
   (updates signatures only — platform/engine version updates ride the standard Defender platform update mechanism, not `Update-MpSignature`).
4. Do not attempt to enable protected-excluded-folder enforcement for this device until the version floor is met — Microsoft's own guidance treats this as a hard prerequisite, not a soft recommendation.

**Rollback:** none needed — this is a version-floor check, not a configuration change.

</details>

<details><summary>Fix 2 — No Devices-scoped DLP policy exists, or existing policy doesn't cover the egress activity</summary>

1. Identify or create a DLP policy scoped to the **Devices** workload in the Purview portal (or `New-DlpCompliancePolicy` with `-EndpointDlpLocation` for the relevant users/groups).
2. Extend the policy's rule to cover the specific activities needed: copy to removable media, copy/save to network share, upload to cloud service, print — whichever match the client's actual concern.
3. **Stage in audit mode first.** Do not deploy directly to block mode for a policy extension covering previously-invisible `AppData`/temp-folder content — audit for at least one review cycle to catch unexpected line-of-business tools that legitimately write sensitive content to `AppData` (a common false-positive source once these folders come into scope).
4. Promote to block mode only after audit-mode review confirms acceptable signal-to-noise.

**Rollback:** revert the policy rule's action back to audit, or remove the added activities from scope — both are immediate, non-destructive portal/cmdlet edits.

</details>

<details><summary>Fix 3 — Path is excluded but not marked protected (or protected but not extended into policy)</summary>

1. In the portal, add or confirm the exact path under **File path exclusions for Windows**, matching Microsoft's documented syntax rules (trailing `\`, `\*`, `(number)` subfolder depth, `%EnvironmentVariable%` support).
2. Toggle the path's protected/egress-monitoring flag on.
3. Cross-check against Fix 2 — a protected path with no covering policy rule still produces no enforcement. Both layers must be configured together.
4. Re-test the specific egress activity after allowing time for policy propagation (treat as up to 3 hours, consistent with standard DLP policy-configuration latency, until Microsoft publishes feature-specific timing).

**Rollback:** untoggle the protected flag to return the path to fully-invisible default-exclusion behavior.

</details>

<details><summary>Fix 4 — Conflicting audit/block policies produce unexpected block</summary>

1. Enumerate every Devices-scoped policy applying to the affected user:
   ```powershell
   Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "EndpointDevices" -and $_.Enabled -eq $true } |
       Select-Object Name, Mode
   ```
2. If more than one policy matches the same user/activity with different modes (Audit vs. Block), remember Microsoft's stated precedence: **block always wins** when both an audit and a block policy apply to the same user and activity.
3. Decide intentionally which mode should govern for this population — either scope the audit-mode policy away from this user/group, or accept the block behavior as correct and communicate it.

**Rollback:** adjusting policy scope (user/group exclusions) is non-destructive and reversible immediately.

</details>

---

## Escalation Evidence

```
=== Endpoint DLP Excluded-Folder Protection — Escalation Packet ===
Tenant:
Ticket #:
Date/Time (UTC):
Affected device name:
Affected user UPN:

1. Get-MpComputerStatus AMProductVersion (attach): ____________
2. Portal screenshot: File path exclusions for Windows, showing the specific path + protected flag state:
3. Exact file path/activity tested (copy / print / network share / cloud upload): ____________
4. Devices-scoped DLP policy name + Mode (Audit/Block) covering this user: ____________
5. Get-DlpDetailReport output for the test window (attach):
6. Time elapsed since policy/exclusion change (must be >3 hrs before escalating): ____________
7. Tenant cloud environment (Worldwide / GCC / GCC High / DoD): ____________
8. Prior fix paths attempted from this runbook: ____________
```

---

## 🎓 Learning Pointers

- The **default** state for `AppData\Roaming` and `AppData\Local` is fully excluded from Endpoint DLP — no auditing, no enforcement. This feature adds an *opt-in* middle ground (protected during egress only) rather than removing the exclusion outright. See [Configure endpoint DLP settings — File path exclusions](https://learn.microsoft.com/en-us/purview/dlp-configure-endpoint-settings#file-path-exclusions).
- Protection under this feature applies **only to monitored egress activities** (copy, print, network-share save, cloud upload) — it does not add at-rest scanning or on-open auditing to excluded folders. A file can sit in a protected `AppData` folder indefinitely without ever being scanned until someone tries to move it out.
- When both an audit-mode and a block-mode policy apply to the same user and activity, **block takes precedence** — this is explicit in Microsoft's own rollout guidance and is a common source of "why did this get blocked, I thought we were just auditing" tickets during a phased policy extension.
- The Defender anti-malware client version floor (4.18.26051) is a hard prerequisite, not a recommendation — devices below it silently get no enforcement rather than an error, which makes Fix 1 the correct default first hypothesis for any "nothing happens" report.
- This capability's rollout timeline has already shifted once (originally early July 2026, revised to mid–end September 2026 per the MC1384420 version history) — always re-check the live Message Center entry before quoting a date to a client rather than relying on a cached date.
