# Secure Boot 2011→2023 Certificate Transition — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from live fetches of Microsoft's own Secure Boot certificate-update support hub (general overview KB 5062710, `lastPublishedDate` 2026-05-18; registry key reference KB 5068202, `updated_at` 2026-07-13; Windows Security app status KB 5087130, `updated_at` 2026-07-13). This is an actively-updated, multi-article Microsoft Support hub (not a single static Learn conceptual page) with a visible change log on each article — re-check the "Change log" section of each linked article before treating any specific bitmask, date, or registry value below as unconditionally current.

---
## Skim Index (with jump links)
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

This runbook covers the fleet-wide transition of Windows physical/on-prem-managed devices from the original 2011-issued Secure Boot certificate chain to the 2023 replacement chain. It covers Windows 10 (1607+, including LTSC), Windows 11 (21H2+), and Windows Server 2012 through 2025. It does **not** cover Azure VM Trusted Launch/Confidential VM certificate handling (Azure manages that chain independently for Azure Virtual Desktop/Windows 365/Azure Local — see the "Azure, Windows 365 and Secure Boot" guidance on the same Microsoft Support hub if that scenario applies), and does not cover Linux Secure Boot on Azure VMs.

Assumes Secure Boot is already enabled in firmware — this runbook is about certificate *content* inside an already-functioning Secure Boot chain, not about enabling Secure Boot itself.

---
## How It Works

<details><summary>Full architecture</summary>

Secure Boot verifies the digital signature of every piece of pre-boot software (firmware drivers/Option ROMs, boot loaders, boot applications) against a trust hierarchy stored in UEFI firmware:

- **PK (Platform Key)** — top of the hierarchy, owned by the OEM.
- **KEK (Key Enrollment Key)** — includes a Microsoft KEK plus any OEM KEKs; controls who may update the DB/DBX.
- **DB (Signature Database)** — the allow-list of trusted signing certificates; Microsoft- and OEM-managed.
- **DBX (Revoked Signature Database)** — the deny-list, updated by Microsoft as vulnerabilities are found.

Every Windows device shipped since Windows 8 has carried the same four Microsoft certificates in this chain, all issued in **2011**. Those originals are now approaching their natural expiration:

| Expiring certificate | Expires | Replacement | Stored in | Purpose |
|---|---|---|---|---|
| Microsoft Corporation KEK CA 2011 | **June 24, 2026** | Microsoft Corporation KEK 2K CA 2023 | KEK | Signs updates to DB/DBX |
| Microsoft UEFI CA 2011 | **June 27, 2026** | Microsoft UEFI CA 2023 | DB | Signs third-party boot loaders/EFI applications |
| Microsoft UEFI CA 2011 (same source cert, split on renewal) | **June 27, 2026** | Microsoft Option ROM UEFI CA 2023 | DB | Signs third-party option ROMs |
| Microsoft Windows Production PCA 2011 | **October 19, 2026** | Windows UEFI CA 2023 | DB | Signs the Windows boot loader itself |

Note the renewal deliberately **splits** boot-loader trust from option-ROM trust into two separate 2023 certificates (previously combined in the single 2011 UEFI CA) — giving organizations finer-grained control (e.g. trusting option ROMs without trusting arbitrary third-party boot loaders).

**Impact of not updating:** a device that never receives the 2023 certificates continues to boot and continues to receive ordinary Windows updates — there is no cliff-edge "device bricks" event for the overwhelming majority of hardware. What it loses, progressively, is the ability to receive *new* protections for the early boot process specifically: Windows Boot Manager updates, Secure Boot DB/DBX updates, revocation-list updates, and mitigations for newly discovered boot-level vulnerabilities. This has second-order effects on scenarios that lean on Secure Boot trust, including BitLocker's boot-integrity hardening and third-party bootloader trust relationships.

**Deployment mechanics (IT-managed path):** a device-local registry bitmask (`AvailableUpdates`, canonical enterprise value `0x5944`) signals a scheduled task (`\Microsoft\Windows\PI\Secure-Boot-Update`, runs every 12 hours) to write the new certificates into DB/KEK and stage the new boot manager. A restart is required to complete the boot-manager swap specifically — the certificate write itself does not force one. Status is tracked in a second registry location under `\Servicing`, separately from the trigger key.

**Deployment mechanics (Microsoft-managed path):** for devices Microsoft has empirically observed updating successfully on similar hardware/firmware ("high confidence" buckets), Microsoft delivers the update automatically through cumulative updates with no IT action required. This is opt-out (`HighConfidenceOptOut`), not opt-in, by default. A separate opt-in-only mechanism, Controlled Feature Rollout (`MicrosoftUpdateManagedOptIn`), lets organizations that don't naturally fall into a high-confidence bucket still get Microsoft-managed deployment, at the cost of sending required diagnostic data.

</details>

---
## Dependency Stack

```
Layer 4: End-user visibility
         Windows Security app (Device security > Secure Boot) — green/yellow/red
         badge + plain-language status text, rolling out from April 2026; disabled
         by default on enterprise-managed devices (HideSecureBootStates)
Layer 3: Status tracking
         HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing
         UEFICA2023Status (NotStarted/InProgress/Updated), UEFICA2023Error,
         WindowsUEFICA2023Capable, BucketHash, ConfidenceLevel
Layer 2: Deployment trigger (any ONE of, in priority order admin should check)
         a) Registry: AvailableUpdates = 0x5944 (manual / fleet tooling)
         b) Policy-driven: GPO or Intune Secure Boot CSP → writes
            AvailableUpdatesPolicy (read-only reflection, do not hand-edit)
         c) Microsoft-managed: HighConfidenceOptOut=0 (default) or
            MicrosoftUpdateManagedOptIn=1
Layer 1: Servicing execution
         Scheduled task \Microsoft\Windows\PI\Secure-Boot-Update (runs every 12h)
         → writes new certs to firmware DB/KEK → stages new boot manager
         → requires a restart to complete the boot-manager swap
Layer 0: Firmware capability
         UEFI firmware must be able to accept the DB/KEK write at all — a hard
         OEM/hardware-firmware limitation here has NO Windows-side workaround
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| `UEFICA2023Status = NotStarted` indefinitely | No deployment trigger set; device not in Microsoft's high-confidence bucket | `AvailableUpdates`/`AvailableUpdatesPolicy`, `HighConfidenceOptOut` |
| `UEFICA2023Status = InProgress` for days | Restart hasn't occurred since the cert write | Prompt/force a restart, then re-run the scheduled task |
| `UEFICA2023Error` non-zero | Firmware-level failure during DB/KEK write | Correlate `UEFICA2023ErrorEvent` against Secure Boot DB/DBX event log entries |
| `WindowsUEFICA2023Capable = 0` after deployment attempted | Hardware/firmware cannot accept the new cert — permanent, not transient | Check for OEM firmware update; otherwise document as an exception |
| Windows Security app shows yellow/red but registry shows `Updated` | App-level badge state can lag or reflect a different signal (e.g. a temporarily paused rollout for a known compatibility issue) | Cross-check registry state directly rather than trusting the badge alone during the rollout period |
| GPO/Intune policy applied but nothing changes on-device | `AvailableUpdatesPolicy` correctly reflects policy but the servicing task hasn't run yet, or device is offline/not checking in | Force `Start-ScheduledTask` for testing; confirm device last-checkin via Intune/GPO reporting |
| Org-wide: badges not appearing on any managed device even where enabled centrally | `HideSecureBootStates` still set to hide by default | Explicitly set to `0` per the IT admin guidance if visibility is desired |

---
## Validation Steps

1. **Confirm Secure Boot is enabled.**
   ```powershell
   Confirm-SecureBootUEFI
   ```
   Good: `True`. Bad: `False` — a prerequisite gap, not part of this topic.

2. **Confirm current certificate content in firmware directly (ground truth, not just registry claim).**
   ```powershell
   Get-SecureBootUEFI -Name db -Decoded
   Get-SecureBootUEFI -Name KEK -Decoded
   ```
   Good: entries for "Windows UEFI CA 2023" / "Microsoft UEFI CA 2023" / "Microsoft Option ROM UEFI CA 2023" present in DB, "Microsoft Corporation KEK 2K CA 2023" present in KEK. Bad: only 2011-era certificate names present. Note: the `-Decoded` parameter's certificate-name output requires a sufficiently recent build — treat an empty/unparseable result on a very old build as inconclusive, not as proof of absence.

3. **Confirm registry-reported status agrees with firmware ground truth.**
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"
   ```
   Good: `UEFICA2023Status = Updated` matches the certs actually present in step 2. Bad: a mismatch — trust the firmware content over the registry status if they disagree, and treat the mismatch itself as a data point worth investigating (possible stale status after an out-of-band firmware update).

4. **Confirm fleet-wide deployment trigger is actually reaching devices** (Intune/GPO path):
   Check policy assignment success in Intune reporting or `gpresult /h` on a sample device, then confirm `AvailableUpdatesPolicy` reflects the intended value on that device.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish fleet-wide visibility before touching individual devices.** Run the fleet audit script (`Get-SecureBoot2023CertStatus.ps1`) broadly first. Individual-device firefighting on a certificate-rollout topic with a hard external deadline is the wrong starting point — you need to know your NotStarted/InProgress/Updated/Error/Incapable distribution before prioritizing.

**Phase 2 — Segment by cause, not by device.** Group devices into: (a) simply not yet triggered — cheapest fix, deploy policy; (b) InProgress awaiting restart — communicate a restart requirement, don't re-trigger; (c) Error — investigate per-device, often firmware-related; (d) Incapable — a hard hardware ceiling requiring OEM engagement or refresh planning, not a software fix.

**Phase 3 — Deploy the trigger fleet-wide via policy, not per-device registry edits.** Registry edits are for testing/validation on individual devices; production rollout should go through GPO or Intune so `AvailableUpdatesPolicy` is centrally managed and auditable.

**Phase 4 — Track against the actual expiration dates, prioritizing by risk.** The KEK/UEFI CA/Option ROM CA certs expire first (late June 2026); the Windows Production PCA (boot loader signing) expires later (October 2026) — but treat June as the real deadline for planning purposes, since a device behind on any one of the four certs is already losing protection.

**Phase 5 — Handle Incapable devices as a distinct workstream.** These need OEM firmware engagement or hardware refresh budgeting, not repeated retriggers — repeatedly re-running the servicing task against a hardware-incapable device wastes time and won't change the outcome.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide managed rollout via Intune/GPO (the standard path for most MSP-managed estates)</summary>

1. Inventory current state fleet-wide using `Get-SecureBoot2023CertStatus.ps1` to establish a baseline before deploying anything.
2. Deploy via Microsoft's documented Intune method (Settings Catalog Secure Boot CSP profile, including the model-based-targeting option Microsoft provides for staged rollout by device model) or GPO, rather than registry edits — this keeps `AvailableUpdatesPolicy` centrally managed.
3. Consider Microsoft's own sample "Monitoring Secure Boot certificate status with Microsoft Intune remediations" pattern (a remediation script pair — detection reads `UEFICA2023Status`, remediation triggers deployment) for devices Intune-manages, rather than building this from scratch.
4. Re-run the fleet audit weekly during the rollout window; prioritize Error and Incapable buckets, since NotStarted devices should self-resolve once policy reaches them and a restart occurs.
5. Track completion against the June 2026 (KEK/UEFI CA) and October 2026 (Production PCA) expiration dates, treating June as the operational deadline.

Rollback: none required — additive trust only. If a specific device shows a genuine regression after deployment (extremely rare, and would indicate a firmware compatibility issue), Microsoft's own automatic pause mechanism ("Secure Boot certificate updates are temporarily paused" status) is the documented safety valve, not a manual rollback procedure.

</details>

<details><summary>Playbook 2 — Emergency triage close to a certificate expiration deadline</summary>

1. Run the fleet audit immediately and sort by `UEFICA2023Status = NotStarted` combined with device criticality (internet-facing, BitLocker-protected, VIP users first).
2. For NotStarted devices with no deployment blocker, force deployment via registry + `Start-ScheduledTask` on a sample first to confirm the mechanism works in your environment, then push via policy at scale.
3. For InProgress devices, communicate a mandatory restart window rather than waiting for organic reboots — the boot-manager swap will not complete otherwise.
4. For Incapable devices, do NOT attempt workarounds like disabling Secure Boot — running with an aging-but-still-valid 2011 certificate is safer than running with Secure Boot off entirely. Escalate to OEM and document as a tracked risk exception with a target hardware-refresh date.
5. After the relevant deadline passes, treat any device still on `NotStarted`/`Error`/`Incapable` as an active risk item requiring executive-level exception sign-off, not routine ticket triage.

Rollback: not applicable — this playbook is about acceleration under deadline pressure, not undoing anything.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Secure Boot 2023 certificate transition evidence for a single device,
    combining registry-reported status with actual firmware DB/KEK content.
#>
$confirmSB = Confirm-SecureBootUEFI
$servicing = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -ErrorAction SilentlyContinue
$trigger   = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -ErrorAction SilentlyContinue
$osInfo    = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

$dbCerts = try { (Get-SecureBootUEFI -Name db -Decoded -ErrorAction Stop) } catch { "Unable to decode - build may not support -Decoded parameter: $($_.Exception.Message)" }
$kekCerts = try { (Get-SecureBootUEFI -Name KEK -Decoded -ErrorAction Stop) } catch { "Unable to decode - build may not support -Decoded parameter: $($_.Exception.Message)" }

[PSCustomObject]@{
    ComputerName            = $env:COMPUTERNAME
    SecureBootEnabled       = $confirmSB
    OSDisplayVersion        = $osInfo.DisplayVersion
    OSBuild                 = "$($osInfo.CurrentBuild).$($osInfo.UBR)"
    UEFICA2023Status        = $servicing.UEFICA2023Status
    UEFICA2023Error         = $servicing.UEFICA2023Error
    UEFICA2023ErrorEvent    = $servicing.UEFICA2023ErrorEvent
    WindowsUEFICA2023Capable= $servicing.WindowsUEFICA2023Capable
    BucketHash              = $servicing.BucketHash
    ConfidenceLevel         = $servicing.ConfidenceLevel
    AvailableUpdates        = $trigger.AvailableUpdates
    AvailableUpdatesPolicy  = $trigger.AvailableUpdatesPolicy
    HighConfidenceOptOut    = $trigger.HighConfidenceOptOut
    MicrosoftUpdateManagedOptIn = $trigger.MicrosoftUpdateManagedOptIn
    DbCertificateSummary    = $dbCerts
    KekCertificateSummary   = $kekCerts
} | ConvertTo-Json -Depth 5
```

---
## Command Cheat Sheet

```powershell
# Confirm Secure Boot enabled
Confirm-SecureBootUEFI

# Trigger enterprise deployment (all needed certs + KEK + new boot manager)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot" /v AvailableUpdates /t REG_DWORD /d 0x5944 /f

# Force the servicing task to run now instead of waiting up to 12h
Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"

# Read servicing status
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"

# Read trigger/opt-in/opt-out state
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot"

# Ground-truth firmware certificate content
Get-SecureBootUEFI -Name db -Decoded
Get-SecureBootUEFI -Name KEK -Decoded

# Enable Windows Security app badge visibility on a managed device (default: hidden)
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Security Health\SecureBoot" /v HideSecureBootStates /t REG_DWORD /d 0 /f

# Opt out of Microsoft-managed high-confidence automatic deployment (rarely needed)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot" /v HighConfidenceOptOut /t REG_DWORD /d 1 /f
```

---
## 🎓 Learning Pointers

- This is a **transition window across multiple certificates with different expiration dates**, not a single cutover event — the KEK and UEFI/Option ROM CAs expire June 24-27, 2026; the Windows Production PCA (boot loader signing) expires October 19, 2026. See [Windows Secure Boot certificate expiration and CA updates](https://support.microsoft.com/en-us/topic/windows-secure-boot-certificate-expiration-and-ca-updates-7ff40d33-95dc-4c3c-8725-a9b95457578e).
- `AvailableUpdates = 0x5944` is the one documented enterprise-deployment bitmask value — Microsoft's own docs explicitly warn other bit combinations are undocumented behavior; don't improvise a "partial" deployment value.
- `AvailableUpdatesPolicy` exists purely as a read reflection of GPO/Intune policy — editing it directly does nothing; edit the source policy.
- The Windows Security app badge (rolling out from April 2026) is **hidden by default on enterprise-managed devices** specifically to reduce notification noise — a missing badge on a managed fleet is expected, not a bug, unless you've deliberately unhidden it via `HideSecureBootStates`.
- A hardware/firmware-incapable device (`WindowsUEFICA2023Capable = 0` persisting after deployment) has no Windows-side fix — this is the single most important triage fork in this entire topic, since every other state responds to policy/retry/restart and this one does not.
- Related but explicitly out of scope here: Azure VM Trusted Launch/Confidential VM certificate handling (`Azure, Windows 365 and Secure Boot` guidance) and this repo's existing `BitLocker/BitLocker-A.md`/`VBS-CredentialGuard-A.md`, both of which already document Secure Boot as a hard prerequisite without covering this specific certificate-rotation mechanics.
