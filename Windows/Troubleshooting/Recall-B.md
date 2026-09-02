# Windows Recall — Hotfix Runbook (Mode B: Ops)
> Fix, block, or evidence-collect on a Recall ticket in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run these first — results tell you which fix path to follow:

```powershell
# 1. Is this even a Copilot+ PC (Recall's hard hardware gate)?
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions" -ErrorAction SilentlyContinue
(Get-CimInstance Win32_ComputerSystem).SystemSKU
# Reliable check: Settings > System > About shows "Copilot+ PC" — no single documented
# registry flag is guaranteed to exist on every OEM image, so treat Settings as ground truth

# 2. Is Recall policy-blocked or policy-allowed?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction SilentlyContinue
# Expected keys: DisableAIDataAnalysis (1 = Recall snapshot saving blocked)
#                AllowRecallEnablement (0 = enrollment blocked, 1/absent = allowed)

# 3. Is the device actually enrolled in Recall (user completed setup)?
Get-Process -Name "aihost" -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName "*Recall*" -ErrorAction SilentlyContinue
# A running aihost.exe / present scheduled task = Recall is active and taking snapshots

# 4. Windows Hello enrollment (hard prerequisite for enabling Recall AND viewing snapshots)
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Enum" -ErrorAction SilentlyContinue
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined"
# Recall setup will not proceed without at least one enrolled Windows Hello factor
# (face, fingerprint, or PIN with ESS) — check via Settings > Accounts > Sign-in options

# 5. Storage allocation and disk headroom
Get-PSDrive -Name C | Select-Object Used, Free
# Recall's snapshot store needs real headroom on top of whatever slider allocation
# (3-150GB) the user or policy set — a full system drive silently stalls snapshot capture
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Not a Copilot+ PC | Not fixable — Recall is hardware-gated (NPU ≥40 TOPS). Close as "not eligible," no further troubleshooting |
| `DisableAIDataAnalysis = 1` present | Recall is intentionally blocked by policy — confirm this is the desired org state before "fixing" anything (see Fix 1) |
| Copilot+ PC, no policy block, Recall missing from Settings | Enrollment/eligibility issue → Fix 2 |
| Recall enrolled but no Windows Hello enhanced sign-in | Recall silently can't save/view snapshots → Fix 3 |
| Recall running but snapshots stop growing | Storage/disk space exhaustion → Fix 4 |
| A sensitive app or site is showing up in snapshots | Filtering/exclusion gap → Fix 5 |
| Org wants Recall fully disabled fleet-wide | Deploy the blocking policy → Fix 1 |
| Legal/compliance needs existing snapshots purged | Snapshot deletion → Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Copilot+ PC hardware certification
   NPU capable of 40+ TOPS (Snapdragon X, Intel Lunar Lake/Panther Lake, AMD Strix/Kraken Point)
        │
Windows 11 24H2+ with the Recall/Windows AI components present
        │
Group Policy / Intune CSP does NOT block enrollment
   WindowsAI CSP: AllowRecallEnablement = 1 (or not configured)
   GPO: "Turn off saving snapshots for Recall" = Not Configured / Disabled
        │
Device encryption (BitLocker or Device Encryption) enabled
        │
Windows Hello Enhanced Sign-in Security (ESS) enrolled — face, fingerprint, or
PIN-backed — required both to TURN ON Recall and to unlock/view the snapshot timeline
        │
User completes Recall opt-in setup (Settings > Privacy & security > Recall & snapshots)
   Off by default — this is a deliberate per-user action, not silently enabled
        │
Storage allocation configured (3-150GB slider) AND actual free disk space available
        │
aihost.exe / Recall background task capturing snapshots on the configured interval
        │
On-device semantic indexing (small language model) + OCR-style text extraction
   runs locally against each snapshot — no snapshot content leaves the device
        │
Sensitive-content filtering applied at capture time
   Built-in filters (best-effort: passwords, card numbers) + app/site exclusion lists
   + private/InPrivate browsing auto-excluded
        │
User (or IT via Intune device action / local delete) can pause, delete snapshots,
or fully disable — no cloud sync of snapshot content
```

**Key concepts:**
- **Recall is opt-in, not opt-out** — even on an eligible, policy-permitted Copilot+ PC, nothing is captured until the user explicitly completes setup. A ticket saying "Recall turned itself on" is almost always the user having clicked through setup, not silent enablement.
- **Windows Hello ESS is not optional** — a password-only sign-in cannot enable or unlock Recall. This is the single most common "Recall option is greyed out" root cause on an otherwise-eligible device.
- **Snapshots never leave the device** — no cloud sync, no tenant-side storage. This matters for the eDiscovery/DLP conversation: Recall's local SQLite snapshot store is not currently a Purview-indexed data source.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm hardware eligibility**
```powershell
# Ground truth: Settings > System > About > Device specifications
# Should read "Copilot+ PC" — if absent, Recall cannot be enabled by any policy change
```
- Not present → not eligible, stop here
- Present → continue

**Step 2 — Confirm policy state**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction SilentlyContinue |
    Select-Object DisableAIDataAnalysis, AllowRecallEnablement
```
- `DisableAIDataAnalysis = 1` → Recall is blocked by design. If the ticket is "why can't I turn on Recall," this is the answer — verify with the requester whether an exception is appropriate (Fix 1, exception path)
- Not configured / `AllowRecallEnablement = 1` → continue

**Step 3 — Confirm BitLocker / device encryption**
```powershell
Get-BitLockerVolume -MountPoint C: | Select-Object VolumeStatus, ProtectionStatus
```
- `ProtectionStatus` must be `On` — Recall setup blocks itself silently if the OS volume isn't encrypted

**Step 4 — Confirm Windows Hello ESS enrollment**
- Settings > Accounts > Sign-in options > confirm a biometric or PIN-with-ESS factor is enrolled
- A domain/hybrid-joined device with only a synced AD password and no local Hello enrollment will show Recall as present in Settings but unable to complete setup

**Step 5 — Confirm storage headroom**
```powershell
Get-PSDrive -Name C | Select-Object Used, Free, @{N='FreeGB';E={[math]::Round($_.Free/1GB,1)}}
```
- Recall needs free space beyond its own slider allocation to actually write new snapshots; a drive under ~10% free will visibly stall capture with no user-facing error

---

## Common Fix Paths

<details><summary>Fix 1 — Block Recall fleet-wide (most common MSP request)</summary>

**Cause:** Org policy decision — Recall's local screenshot-and-index model is a data-governance conversation many orgs choose to opt out of entirely rather than manage exceptions.

**Via Intune (Settings Catalog, preferred):**
```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Windows AI
  → "Allow Recall to be enabled" = Disabled  (blocks enrollment CSP-side)
  → "Turn off saving snapshots for Recall" = Enabled  (blocks capture even if already enrolled)
Assign to the target device group, then force a policy sync:
```
```powershell
# On the device, after Intune sync:
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" |
    Select-Object DisableAIDataAnalysis, AllowRecallEnablement
# Expected: DisableAIDataAnalysis = 1
```

**Via on-prem GPO (hybrid/domain-joined estate):**
```
Computer Configuration > Administrative Templates > Windows Components > Windows AI
  → Turn off saving snapshots for Recall: Enabled
  → Allow Recall to be enabled: Disabled
```
Run `gpupdate /force` on affected machines; the policy takes effect without a reboot for new snapshot capture, but any in-progress Recall session should be signed out/in to fully clear.

**Rollback:** Set both settings back to Not Configured and re-sync/`gpupdate /force`. Existing local snapshot data (if any was captured before the block) is not automatically restored or deleted by this change alone — see Fix 6 if removal is also required.

</details>

<details><summary>Fix 2 — Recall missing/greyed out on an eligible, policy-permitted device</summary>

**Cause:** Almost always Windows Hello ESS not enrolled, or BitLocker/device encryption not on.

```powershell
# Confirm both prerequisites in one pass
Get-BitLockerVolume -MountPoint C: | Select-Object ProtectionStatus
Get-CimInstance -Namespace root/cimv2/security/microsofttpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue |
    Select-Object IsEnabled_InitialValue, IsActivated_InitialValue
```

**Remediation:**
1. Enable device encryption if off (Intune BitLocker policy, or locally: `manage-bde -on C:`)
2. Have the user enroll a Windows Hello biometric or PIN factor: Settings > Accounts > Sign-in options
3. Re-check Settings > Privacy & security > Recall & snapshots — the toggle should now be interactable

**Rollback:** N/A — this fix only unblocks a legitimate prerequisite gap, no destructive change.

</details>

<details><summary>Fix 3 — Recall enrolled but can't save or view snapshots</summary>

**Cause:** Windows Hello ESS factor was removed or expired after initial Recall setup (e.g., biometric hardware replaced, PIN reset without ESS re-enrollment).

```powershell
# Check current Hello enrollment state
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Enum" -ErrorAction SilentlyContinue
```

**Remediation:**
1. Settings > Accounts > Sign-in options — re-enroll the missing/expired factor
2. Sign out and back in to refresh the ESS-backed encryption key Recall relies on
3. Confirm snapshot capture resumes: `Get-Process -Name aihost -ErrorAction SilentlyContinue`

**Rollback:** N/A.

</details>

<details><summary>Fix 4 — Snapshots stop growing / storage exhausted</summary>

**Cause:** System drive free space fell below the threshold Recall needs to write new snapshots, or the user's storage slider allocation is already full.

```powershell
Get-PSDrive -Name C | Select-Object Used, Free
```

**Remediation:**
1. Free disk space (temp file cleanup, `Disk Cleanup`/`cleanmgr`, or storage sense)
2. User can raise or confirm the allocation: Settings > Privacy & security > Recall & snapshots > Storage
3. If space genuinely can't be freed, reduce the allocation slider rather than leaving Recall silently stalled — a stalled state gives the user a false sense that recent activity is being captured when it isn't

**Rollback:** N/A.

</details>

<details><summary>Fix 5 — Sensitive app or site appears in snapshots (compliance concern)</summary>

**Cause:** Recall's built-in sensitive-content filtering is best-effort (targets things like visible password fields and payment card patterns) — it is not a guaranteed DLP control, and unlisted internal line-of-business apps are not auto-excluded.

**Remediation — add explicit app/site exclusions:**
```
Settings > Privacy & security > Recall & snapshots > Filter Recall snapshots for this app
```
For fleet-wide enforcement, deploy exclusions via Intune Settings Catalog under the Windows AI category (per-app exclusion list) rather than relying on each user to self-configure.

**For browser-based sensitive sites:** confirm the relevant browser's Recall-exclusion extension/setting is enabled (Edge, and Chrome/Firefox where the vendor has added support) — private/InPrivate/incognito sessions are excluded automatically regardless of browser-level Recall settings.

**If the app absolutely cannot be reliably filtered:** the only fully deterministic control is Fix 1 (block Recall for the device/user population that runs that app) — filtering is defense-in-depth, not a hard guarantee.

**Rollback:** Remove the exclusion entry if no longer needed.

</details>

<details><summary>Fix 6 — Purge existing snapshots (legal hold, offboarding, compliance request)</summary>

**Cause:** A user is leaving, a legal/compliance request requires snapshot removal, or Recall was enabled in error and needs to be reset clean.

**User-initiated (self-service):**
```
Settings > Privacy & security > Recall & snapshots > Delete all snapshots
```

**IT-initiated (device already retrieved / offline):**
```powershell
# Snapshots live in a per-user, VBS-protected local store — there is no supported
# remote-wipe cmdlet for snapshot content alone as of this writing. For a departing
# employee or compliance case, treat this as a device-level action:
# 1. If the device is being wiped/retired anyway, a full Autopilot Reset or wipe
#    removes the snapshot store along with everything else — the simplest guaranteed path
# 2. If the device stays in service, disable Recall via Fix 1 AND have the user run
#    "Delete all snapshots" locally, then confirm via:
Get-ChildItem "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP" -ErrorAction SilentlyContinue
# An empty or absent UKP folder after deletion confirms the local store was cleared
```

**Rollback:** N/A — deletion is intentionally irreversible (that's the point for a compliance-driven purge).

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — Windows Recall Issue
=====================================
Device Name:            [hostname]
Copilot+ PC Eligible:    [Yes | No — Settings > System > About]
Windows Build:           [winver / ver output]
BitLocker/Device Enc.:   [Get-BitLockerVolume ProtectionStatus]
Windows Hello Enrolled:  [Yes/No, factor type — biometric/PIN+ESS]
Policy State:
  DisableAIDataAnalysis: [value or Not Configured]
  AllowRecallEnablement: [value or Not Configured]
Recall Enrollment State: [Enrolled | Not enrolled | Blocked by policy]
aihost.exe running:      [Yes/No]
Disk free space (C:):    [GB]
Storage allocation set:  [GB, from Recall settings]

Symptom description:
[what the user/admin reported]

Steps already attempted:
[ ] Confirmed Copilot+ PC hardware eligibility
[ ] Confirmed BitLocker/device encryption is On
[ ] Confirmed Windows Hello ESS enrollment
[ ] Checked WindowsAI policy keys (Intune/GPO)
[ ] Checked disk free space and storage allocation
[ ] Checked app/site exclusion list (if compliance-related)
```

---

## 🎓 Learning Pointers

- **Recall is hardware-gated before it's policy-gated.** No CSP, GPO, or registry edit makes Recall available on a non-Copilot+ PC — the NPU performance floor (40+ TOPS) is enforced at the OS component level, not just marketing. Rule this out in five seconds before investigating anything else. [Copilot+ PC requirements](https://learn.microsoft.com/en-us/windows/ai/npu-devices/)

- **Opt-in by design is the single most important fact to know for this topic.** Recall shipped through a public preview backlash in 2024 that resulted in Microsoft making it off-by-default with mandatory Windows Hello ESS gating. Most "Recall got enabled without permission" tickets resolve to a user having clicked through setup, sometimes without fully reading the prompts.

- **Windows Hello Enhanced Sign-in Security (ESS) is the real prerequisite, not just "Hello configured."** A device can show biometric sign-in working for login purposes while still lacking the ESS-backed key material Recall needs — this is why Fix 2/3 exist as distinct paths from ordinary Hello troubleshooting. [Windows Hello Enhanced Sign-in Security](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/windows-hello-enhanced-sign-in-security)

- **Sensitive-content filtering is best-effort, not a DLP guarantee.** Treat any compliance conversation about Recall the same way you'd treat a screen-recording tool: filtering reduces exposure, it does not eliminate it. For genuinely sensitive workflows, blocking Recall outright (Fix 1) is the only deterministic control.

- **Snapshot data has no current Purview/eDiscovery integration.** As of this writing, the local Recall store is not a searchable Purview data source — factor this into any legal-hold or discovery conversation rather than assuming existing eDiscovery tooling reaches it. Confirm current state with Purview/compliance stakeholders before making representations in a legal context.

- **The Windows AI GPO/CSP category is new relative to most Administrative Templates an engineer already knows** — don't assume it's under an existing Privacy or AI Copilot node; it's its own `Windows AI` category in both the Settings Catalog and the ADMX-backed GPO tree. [Recall privacy and controls overview](https://support.microsoft.com/en-us/windows/privacy-and-control-over-your-recall-experience-d404f672-7647-41e5-886c-a3c59680af6d)
