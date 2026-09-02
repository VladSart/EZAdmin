# Windows Recall — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why Recall behaves the way it does on Copilot+ PCs, not just what to click.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Windows Recall's hardware eligibility model (Copilot+ PC / NPU requirement)
- The opt-in enrollment flow and its hard dependencies (BitLocker/device encryption, Windows Hello Enhanced Sign-in Security)
- Local on-device snapshot capture, storage, indexing, and retrieval architecture
- Sensitive-content filtering and app/site exclusion mechanics
- IT admin governance: Intune Settings Catalog / CSP (`WindowsAI`) and Group Policy (`Windows AI` ADMX category)
- Data governance implications: eDiscovery/Purview posture, offboarding, legal-hold considerations

**Out of scope:**
- Other Copilot+ NPU-dependent features (Click to Do, Cocreator, Live Captions translation) beyond noting they share the same hardware gate and `WindowsAI`/related CSP family
- Microsoft 365 Copilot (the cloud-based, tenant-data-grounded product) — architecturally unrelated; Recall never sends snapshot content to any cloud service
- Third-party "Recall-like" screen-recording/audit tools

**Assumptions:**
- Windows 11, version 24H2 or later, on certified Copilot+ PC hardware (NPU rated at 40+ TOPS — initially Qualcomm Snapdragon X Elite/Plus, extended to Intel Core Ultra 200V "Lunar Lake" and later Panther Lake, and AMD Ryzen AI 300 "Strix Point"/"Kraken Point" generations)
- Reader has local admin on the device and Intune/GPO edit rights if a policy-level fix is needed
- PowerShell 5.1 baseline; most Recall-specific state is read via registry and process/service checks since no dedicated `Recall` PowerShell module exists as of this writing

---

## How It Works

<details><summary>Full architecture</summary>

### Why Recall Is Hardware-Gated

Recall's core workload — periodic screen capture, on-device semantic indexing via a local small language model, and OCR-style text extraction from every captured frame — is computationally expensive enough that Microsoft restricted it to devices with a Neural Processing Unit (NPU) capable of at least 40 trillion operations per second (TOPS). This is the same hardware bar Microsoft defined for the "Copilot+ PC" branding as a whole. The gate is enforced by Windows component licensing/feature-detection at the OS level, not by a simple registry flag an admin can toggle — a device without the NPU tier will never show Recall as available, full stop, regardless of Windows build or policy configuration.

```
Copilot+ PC certification (NPU ≥ 40 TOPS)
        │
Windows 11 24H2+ Windows AI platform components present
        │
   ┌────┴────┐
   │  Recall │   (this runbook)
   │Click to │   (shares hardware gate + WindowsAI CSP family, not covered here)
   │   Do    │
   └─────────┘
```

### The Opt-In Enrollment Flow

Unlike most Windows features that ship enabled-by-default and rely on policy to turn them *off*, Recall shipped (after the June 2024 preview redesign, following public and regulatory scrutiny of screenshot-based capture) as **off by default with a mandatory, non-bypassable setup flow**:

1. User navigates to Settings > Privacy & security > Recall & snapshots (or is prompted at first sign-in on eligible hardware)
2. Windows verifies: Copilot+ PC eligibility, BitLocker/device encryption status, and Windows Hello Enhanced Sign-in Security (ESS) enrollment
3. If BitLocker/device encryption is off, setup blocks and directs the user to enable it first
4. If no ESS-backed Windows Hello factor (biometric, or PIN under specific TPM-backed conditions) is enrolled, setup blocks and directs enrollment first
5. Only after both are satisfied does the actual Recall toggle become interactable
6. The user chooses a storage allocation (a slider, roughly 3GB-150GB depending on available disk space) and confirms

This sequencing is why "Recall is greyed out" tickets are overwhelmingly a missing-prerequisite problem (encryption or Hello ESS), not a Recall-specific bug — the UI is deliberately gating on those two conditions before it will let the feature itself be touched.

### Windows Hello Enhanced Sign-in Security (ESS) — Why It's Different From "Hello Configured"

Ordinary Windows Hello (PIN, face, fingerprint) authenticates the user for sign-in. **Enhanced Sign-in Security** is a stricter mode that uses VBS (Virtualization-Based Security) and, where available, a Secure Enclave / discrete TPM to isolate biometric data and authentication logic from the main OS, resisting spoofing and replay attacks. Recall specifically requires the ESS-backed key material because the same isolated, hardware-protected trust boundary is used to encrypt the snapshot database and to gate the semantic-search UI that lets a user browse their own history — Microsoft's stated design goal is that "if you can't prove you're you at the same trust level as Hello ESS, you can't unlock your own screenshot history." This is a materially higher bar than "the PIN prompt works," and it's the number one reason an otherwise-eligible device shows Recall present in Settings but fails partway through setup or fails to display snapshots later.

### Local Capture, Indexing, and Storage

Once enrolled, a background process (`aihost.exe`, running under a dedicated Recall scheduled task/service context) periodically captures a screenshot of the active desktop — the interval adapts to activity level and is not user-configurable as a fixed number. Each snapshot is:

1. **OCR/text-extracted** — visible text is pulled out via an on-device model so it becomes searchable
2. **Semantically indexed** — a local small language model generates embeddings so natural-language search ("that PDF about the Q3 budget") can match snapshots without exact keyword matching
3. **Filtered** — a best-effort sensitive-content classifier attempts to detect and skip capturing frames containing things like visible password fields or payment card number patterns; private/InPrivate browser windows are excluded at the OS window-handle level (Recall recognizes the private-browsing window flag and simply never snapshots it), and specific apps/sites can be explicitly excluded by the user or by policy
4. **Stored encrypted, locally only** — snapshots and their index land in a per-user store (`%LOCALAPPDATA%\CoreAIPlatform.00\UKP\` in current builds), protected using keys derived from the Hello ESS trust chain. **No snapshot content is ever uploaded to any Microsoft cloud service** — this is an architectural, not just policy, distinction from Microsoft 365 Copilot, which explicitly does operate against cloud-held tenant data.

```
Active desktop
     │  (interval-based capture, not fixed/configurable)
     ▼
aihost.exe screenshot capture
     │
     ├─ Private/InPrivate window? ──yes──▶ SKIPPED, never captured
     │        │no
     ├─ Excluded app/site (user or policy list)? ──yes──▶ SKIPPED
     │        │no
     ├─ Sensitive-content filter (best-effort: passwords, card numbers) ──flagged──▶ SKIPPED/redacted
     │        │clear
     ▼
On-device OCR text extraction + semantic embedding (local SLM)
     │
     ▼
Encrypted write to per-user local store (keys derived from Hello ESS trust chain)
     │
     ▼
User-facing timeline UI + natural-language search
     (unlock requires Hello ESS re-authentication, same as enrollment)
```

### Storage Allocation and Retention

The user (or a policy-configured default) sets a storage cap via a slider. When the cap is reached, Recall ages out the oldest snapshots to make room for new ones — it does not simply stop capturing, except when the underlying disk itself runs low on free space independent of the allocation cap, in which case capture does silently stall. There is currently no built-in fixed retention-period setting (e.g., "keep 30 days") — retention is governed purely by the storage-size cap and rate of new capture, which is a relevant caveat for any compliance conversation expecting a Purview-style retention label model.

### Governance Surface: WindowsAI CSP and the "Windows AI" GPO Category

Microsoft ships Recall governance under a `WindowsAI` configuration service provider (CSP) node, exposed in Intune via the Settings Catalog's **Windows AI** category, and mirrored on-premises via a new **Windows AI** node under `Computer Configuration > Administrative Templates > Windows Components` in the ADMX templates shipped with Windows 11 24H2+ management tooling. The two settings that matter most operationally:

- **Allow Recall to be enabled** — gates whether the *enrollment* flow can even be started. Setting this to Disabled prevents a user from ever completing setup, even on fully eligible hardware.
- **Turn off saving snapshots for Recall** — a stronger, capture-level block. Even on a device where Recall was already enrolled before this policy landed, enabling this setting stops new snapshot capture going forward (it does not retroactively delete existing snapshots — see the Escalation/Playbook section for purge guidance).

Both policies are honored identically whether delivered via Intune (MDM CSP) or GPO — there is no meaningful precedence conflict between the two paths as long as only one management channel is authoritative for a given device (the general co-management precedence rules that apply to any other Intune/GPO overlap apply here too).

### Data Governance Posture (eDiscovery / Purview / Legal Hold)

As of this writing, Recall's local snapshot store is **not** a Microsoft Purview-indexed or -discoverable data source, and it is not currently reachable by standard eDiscovery holds the way mailbox or SharePoint content is. This has two practical implications for MSPs advising clients:

1. **Legal hold requests referencing "everything on the device" should explicitly call out whether Recall snapshots are in scope** — if they are, the only reliable current mechanism is preserving the device itself (image/hold the machine) rather than relying on tenant-side discovery tooling to reach the local store.
2. **Offboarding/termination workflows that assume a remote wipe clears all sensitive local data should verify this assumption includes the Recall store** — a full device wipe or Autopilot Reset does clear it (it's part of the OS volume), but a narrower "remove work account" or selective-wipe action may not.

Confirm current Purview integration status with compliance stakeholders before making firm representations in a legal or regulatory context — this is an area Microsoft has stated intent to expand, and specifics may change between when this was written and when it's read.

</details>

---

## Dependency Stack

```
Copilot+ PC hardware certification (NPU ≥ 40 TOPS)
   │  enforced at OS component level — no policy bypass exists
   ▼
Windows 11 24H2+ with Windows AI platform components
   │
   ▼
Governance layer NOT blocking enrollment
   WindowsAI CSP: AllowRecallEnablement = 1 / Not Configured
   GPO: "Allow Recall to be enabled" = Not Configured / Enabled
   │
   ▼
BitLocker / Device Encryption = On (OS volume)
   │
   ▼
Windows Hello Enhanced Sign-in Security (ESS) enrolled
   (biometric preferred; PIN path requires TPM-backed conditions)
   │
   ▼
User completes opt-in Recall setup (storage allocation slider)
   │
   ▼
Governance layer NOT blocking capture
   WindowsAI CSP: DisableAIDataAnalysis = 0 / Not Configured
   GPO: "Turn off saving snapshots for Recall" = Not Configured / Disabled
   │
   ▼
aihost.exe background capture process running
   │
   ├─ Private/InPrivate window exclusion (automatic, OS-level)
   ├─ App/site exclusion list (user- or policy-configured)
   └─ Best-effort sensitive-content filter (passwords, card numbers)
   │
   ▼
On-device OCR + semantic indexing (local SLM, no cloud round-trip)
   │
   ▼
Encrypted per-user local store (%LOCALAPPDATA%\CoreAIPlatform.00\UKP\)
   keys derived from Hello ESS trust chain
   │
   ▼
Storage cap (3-150GB slider) governs retention — oldest-first aging,
independent of the underlying disk's actual free space, which can
separately stall capture if exhausted
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Recall option doesn't exist anywhere in Settings | Not a Copilot+ PC — hardware gate | Settings > System > About > Device specifications |
| Recall visible but toggle greyed out | BitLocker/device encryption off, or Windows Hello ESS not enrolled | `Get-BitLockerVolume`, Settings > Accounts > Sign-in options |
| Recall was available yesterday, gone today | An `AllowRecallEnablement`/GPO policy landed and blocked further enrollment (does not retroactively remove an already-enrolled state) | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` |
| Recall enrolled, snapshots stopped appearing | `DisableAIDataAnalysis` policy landed after enrollment (capture-level block) | Same registry path as above |
| Recall enrolled, user can't open/search the timeline | Hello ESS factor was removed/expired after enrollment | Re-check Sign-in options enrollment state |
| Snapshots stop growing but no error shown | Disk free space exhausted (distinct from the storage-allocation cap) | `Get-PSDrive C` |
| A known-sensitive internal app shows up in snapshots | Built-in filter is best-effort and app wasn't explicitly excluded | Settings > Recall & snapshots > per-app filter list |
| Private/incognito browsing still appears (rare) | Confirm the browser window was genuinely in a recognized private-browsing mode — some third-party/embedded browser surfaces don't set the flag Recall checks for | Reproduce and confirm window type; escalate as a platform gap if confirmed |
| User asks whether Recall content is searchable via Purview/eDiscovery | Not currently a Purview-indexed source | Confirm current state with compliance stakeholders before answering definitively |
| Two otherwise-identical devices differ on Recall availability | One is genuinely non-Copilot+ despite similar branding/marketing name, or one has an org policy scoped to a different device group | Compare `SystemSKU`/eligibility directly, don't infer from model name alone |

---

## Validation Steps

**1. Confirm hardware eligibility (authoritative source is Settings, not registry):**
- Settings > System > About > Device specifications should read "Copilot+ PC"
- Expected "good": present. "Bad": absent — nothing downstream in this runbook applies

**2. Confirm governance policy state:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction SilentlyContinue |
    Select-Object AllowRecallEnablement, DisableAIDataAnalysis
```
Expected "good" (Recall permitted): both absent, or `AllowRecallEnablement=1` and `DisableAIDataAnalysis=0`.
Expected "intentionally blocked": `AllowRecallEnablement=0` and/or `DisableAIDataAnalysis=1` — this is a valid, common org-chosen state, not automatically a fault.

**3. Confirm BitLocker/device encryption:**
```powershell
Get-BitLockerVolume -MountPoint C: | Select-Object VolumeStatus, ProtectionStatus
```
Expected: `ProtectionStatus = On`.

**4. Confirm Windows Hello ESS enrollment:**
- Settings > Accounts > Sign-in options — a biometric factor (or ESS-qualifying PIN) should show as configured
- No fully reliable single registry/WMI read exists across all hardware generations; treat the Settings UI as ground truth and use `WinBio` registry presence only as a supporting signal

**5. Confirm active capture process (if Recall should be enrolled and running):**
```powershell
Get-Process -Name "aihost" -ErrorAction SilentlyContinue
```
Expected: process present while the user session is active. Absent while all prerequisites check out → capture may be freshly stopped by policy or storage exhaustion; recheck steps 2 and 6.

**6. Confirm disk headroom independent of the storage-allocation slider:**
```powershell
Get-PSDrive -Name C | Select-Object Used, Free, @{N='FreeGB';E={[math]::Round($_.Free/1GB,1)}}
```
A drive under roughly 10% free will stall capture regardless of how much of the Recall storage allocation itself has been consumed.

**7. Confirm local store presence/size (post-enrollment sanity check):**
```powershell
Get-ChildItem "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP" -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum
```
Non-empty and growing over time on an actively-used, enrolled device is the expected healthy state.

---

## Troubleshooting Steps (by phase)

### Phase 1: Eligibility and Governance

1. Confirm Copilot+ PC status via Settings (authoritative).
2. Confirm `WindowsAI` policy keys aren't intentionally blocking — resolve with the requester whether this is a fault or a working-as-designed governance decision before proceeding.

### Phase 2: Prerequisite Gaps (Enrollment Won't Complete)

1. Confirm BitLocker/device encryption is On; enable via Intune BitLocker policy or `manage-bde -on C:` if genuinely missing.
2. Confirm Windows Hello ESS enrollment; have the user complete biometric or ESS-qualifying PIN enrollment.
3. Re-attempt Recall setup from Settings.

### Phase 3: Enrolled But Not Capturing

1. Recheck `DisableAIDataAnalysis` — a policy landing after initial enrollment is the most common cause and does not require re-doing setup once cleared.
2. Check disk free space independent of the storage-allocation slider.
3. Confirm `aihost.exe` is running during an active session; if absent with no policy block and adequate disk space, a sign-out/sign-in cycle typically restarts the background capture context.

### Phase 4: Enrolled and Capturing, But Content or Access Issues

1. Timeline won't open / snapshots won't decrypt → Windows Hello ESS factor likely expired or was removed; re-enrollment resolves this without data loss (the encryption key chain persists as long as the underlying TPM/Secure Enclave state is intact).
2. Sensitive content appearing → apply explicit app/site exclusions (Fix 5 in the companion hotfix runbook); do not treat the built-in filter as sufficient on its own for genuinely sensitive workflows.

### Phase 5: Compliance / Data-Governance Requests

1. Legal hold or termination request referencing Recall content → confirm with compliance stakeholders whether the local store is in scope; if so, preserve the physical/imaged device rather than relying on tenant-side eDiscovery tooling.
2. Snapshot purge request → user self-service delete, or full device wipe/reset if the device is being retired; there is no supported remote "delete just the Recall store" MDM action as of this writing.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide Recall block via Intune Settings Catalog</summary>

```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Windows AI
  Allow Recall to be enabled: Disabled
  Turn off saving snapshots for Recall: Enabled
Assign: target device group (consider scoping by org data-sensitivity tier
rather than a blanket tenant-wide block, if some populations have a legitimate use case)
```

**Verify (post-sync, on-device):**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" |
    Select-Object AllowRecallEnablement, DisableAIDataAnalysis
```

**Rollback:** remove the assignment or set both settings to Not Configured, then re-sync.

</details>

<details><summary>Playbook 2 — Scoped exclusion list for a sensitive line-of-business app</summary>

Use when Recall is org-permitted generally, but a specific application (e.g., an internal PHI/PCI-handling tool) must never be captured.

```
Devices > Configuration > Policies > Create > Windows 10 and later > Settings catalog
Category: Windows AI
  Recall app exclusion list: <add the target application's process name / identifier>
Assign to the device group that runs this application
```

**Verify:** have a user with the app open confirm no new snapshots are generated while it's in focus, using the local store growth check from Validation Step 7 as a before/after comparison.

**Rollback:** remove the entry from the exclusion list.

</details>

<details><summary>Playbook 3 — Recovering a device stuck mid-enrollment</summary>

Use when a user reports Recall setup hangs or errors partway through after all prerequisites appear satisfied.

```powershell
# Restart the underlying Windows AI platform service context
Get-Service -Name "*aihost*", "*WindowsAI*" -ErrorAction SilentlyContinue | Restart-Service -ErrorAction SilentlyContinue

# If no matching service is found (varies by build), a full sign-out/sign-in is the
# supported reset path — there is no documented standalone "reset Recall setup" command
```
Then have the user retry Settings > Privacy & security > Recall & snapshots from a fresh sign-in.

**Rollback:** N/A — this is a state-reset action with no destructive side effect.

</details>

<details><summary>Playbook 4 — Compliance-driven full purge before device reassignment</summary>

```powershell
# Preferred: full wipe/reset guarantees complete removal along with all other user data
# Trigger via Intune: Devices > [device] > Wipe (or Autopilot Reset for re-provisioning)

# If the device must stay in its current state and only Recall data needs clearing,
# have the user run the in-Settings delete, then verify locally:
Get-ChildItem "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP" -ErrorAction SilentlyContinue
# Expect empty or absent after "Delete all snapshots" completes
```

**Rollback:** N/A by design — this is a deliberate, irreversible compliance action. Document who requested it and why before executing, same as any other legal-hold-adjacent action.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows Recall evidence for escalation or compliance review
.NOTES     Run as the affected user (some state is per-user) with local admin for
           the BitLocker/policy reads. Read-only — makes no changes.
#>

$OutputDir = "C:\Temp\Recall-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Hardware eligibility signal (supporting only — Settings UI remains authoritative)
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemSKU |
    Out-File "$OutputDir\Hardware.txt"

# 2. Governance policy state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\WindowsAI-Policy.txt"

# 3. BitLocker/device encryption state
Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue |
    Select-Object MountPoint, VolumeStatus, ProtectionStatus |
    Out-File "$OutputDir\BitLocker.txt"

# 4. Windows Hello enrollment (supporting signal)
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Enum" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\WindowsHello.txt"

# 5. Active capture process
Get-Process -Name "aihost" -ErrorAction SilentlyContinue |
    Select-Object Id, StartTime, CPU | Out-File "$OutputDir\aihost-Process.txt"

# 6. Disk headroom
Get-PSDrive -Name C | Select-Object Used, Free |
    Out-File "$OutputDir\DiskSpace.txt"

# 7. Local snapshot store size (existence/size only — never reads snapshot content)
$storePath = "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP"
if (Test-Path $storePath) {
    Get-ChildItem $storePath -Recurse -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum |
        Select-Object Count, @{N='TotalMB';E={[math]::Round($_.Sum/1MB,1)}} |
        Out-File "$OutputDir\LocalStore-Summary.txt"
} else {
    "Local store path not present — Recall likely never enrolled on this profile" |
        Out-File "$OutputDir\LocalStore-Summary.txt"
}

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Hardware eligibility (supporting signal — Settings > System > About is authoritative)
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemSKU

# Governance policy state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -ErrorAction SilentlyContinue

# BitLocker / device encryption
Get-BitLockerVolume -MountPoint C: | Select-Object VolumeStatus, ProtectionStatus
manage-bde -on C:

# Windows Hello enrollment (supporting signal)
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Enum" -ErrorAction SilentlyContinue

# Active capture process / related services
Get-Process -Name "aihost" -ErrorAction SilentlyContinue
Get-Service -Name "*aihost*", "*WindowsAI*" -ErrorAction SilentlyContinue

# Disk headroom
Get-PSDrive -Name C | Select-Object Used, Free

# Local snapshot store (existence/size checks only)
Test-Path "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP"
Get-ChildItem "$env:LOCALAPPDATA\CoreAIPlatform.00\UKP" -Recurse -ErrorAction SilentlyContinue

# Force Intune policy re-sync (after deploying/removing a WindowsAI Settings Catalog policy)
# Company Portal app > Settings > Sync, or:
Get-ScheduledTask -TaskName "PushLaunch" -ErrorAction SilentlyContinue | Start-ScheduledTask

# GPO refresh (on-prem/domain-managed policy path)
gpupdate /force
```

---

## 🎓 Learning Pointers

- **The NPU hardware gate is the fact that resolves the largest fraction of Recall tickets fastest.** Before touching any policy or Hello configuration, confirm Copilot+ PC status in Settings — a huge share of "why can't I enable Recall" tickets are simply ineligible hardware being mistaken for a config problem, especially on machines marketed with AI-adjacent branding that don't actually meet the 40 TOPS NPU bar. [Copilot+ PC and NPU requirements](https://learn.microsoft.com/en-us/windows/ai/npu-devices/)

- **Recall's opt-in redesign is a direct result of the June 2024 preview backlash** — understanding that history explains why the current architecture is so heavily gated on encryption and Hello ESS compared to a typical Windows feature. It's worth knowing this context when a client asks "why is this so hard to turn on," since the friction is deliberate, not a bug.

- **Windows Hello ESS is a distinct, stricter trust tier from ordinary Hello sign-in** — conflating the two is the most common misdiagnosis in this topic area. If a device signs in fine with Hello but Recall setup won't complete, check ESS enrollment specifically, not just "is Hello configured." [Windows Hello Enhanced Sign-in Security](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/windows-hello-enhanced-sign-in-security)

- **Recall snapshot content never leaves the device — this is architectural, not policy-dependent.** It's a useful, accurate talking point when a client's security team raises Recall as a "data exfiltration to Microsoft" concern; the actual risk profile is local-device data exposure (e.g., a compromised or improperly wiped machine), which is a different threat model than cloud data handling.

- **The `Windows AI` GPO/CSP category is genuinely new** relative to the Administrative Templates most engineers have memorized — don't waste time searching under Privacy, AI, or Copilot nodes; both the Settings Catalog and ADMX tree place these settings under their own `Windows AI` category introduced alongside Recall.

- **Purview/eDiscovery reach into the local Recall store is not yet established as of this writing** — treat this as an evolving area and verify current state with compliance/legal stakeholders rather than relying on this document (or general assumption) when the stakes are a legal hold or regulatory response. [Recall privacy and controls overview](https://support.microsoft.com/en-us/windows/privacy-and-control-over-your-recall-experience-d404f672-7647-41e5-886c-a3c59680af6d)
