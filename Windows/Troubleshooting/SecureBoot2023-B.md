# Secure Boot 2011→2023 Certificate Transition — Hotfix Runbook (Mode B: Ops)
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

This is a fleet-wide, time-boxed issue, not a per-ticket one — but individual devices will surface it as "Windows Security shows a warning about Secure Boot" or as an unexplained item on a compliance/Secure Score report. Original 2011-era Secure Boot certificates begin expiring **June 24, 2026** (KEK), **June 27, 2026** (UEFI CA / Option ROM CA), and **October 19, 2026** (Windows Production PCA). Devices that have not received the replacement 2023 certificates will keep booting and keep receiving normal Windows updates — this is NOT a "device won't boot" emergency — but they progressively lose the ability to receive new boot-chain security protections.

```powershell
# 1. Confirm Secure Boot is even enabled on this device (prerequisite for everything below)
Confirm-SecureBootUEFI

# 2. Check the primary status/error registry keys (fastest single check)
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -ErrorAction SilentlyContinue |
    Select-Object UEFICA2023Status, UEFICA2023Error, WindowsUEFICA2023Capable

# 3. Check whether IT-managed deployment has been triggered on this device at all
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -ErrorAction SilentlyContinue |
    Select-Object AvailableUpdates, AvailableUpdatesPolicy, HighConfidenceOptOut, MicrosoftUpdateManagedOptIn

# 4. Confirm current OS build (2023-cert servicing requires a reasonably current build)
[System.Environment]::OSVersion.Version
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" | Select-Object DisplayVersion, CurrentBuild, UBR
```

| Result | Interpretation |
|---|---|
| `Confirm-SecureBootUEFI` returns `False` | Secure Boot is off entirely — a separate, higher-priority firmware/BIOS-mode issue. Fix that first; the 2023-cert transition is irrelevant until Secure Boot is on. |
| `UEFICA2023Status = Updated`, `UEFICA2023Error = 0` | Fully updated. No action needed on this device. |
| `UEFICA2023Status = NotStarted` and `AvailableUpdates` is `0` or unset | Device has not been targeted for update yet — deploy via Intune/GPO/registry (see Fix 1). |
| `UEFICA2023Status = InProgress` for more than ~24h with no error | Normal — the servicing task runs every 12 hours and a restart is often required to complete the boot manager swap. Prompt a restart. |
| `UEFICA2023Error` is non-zero | A genuine failure — check Secure Boot events in Event Viewer (see Fix 3) before re-triggering. |
| `WindowsUEFICA2023Capable = 0` after deployment was triggered | Certificate did not make it into the firmware DB — likely a hardware/firmware limitation; escalate to OEM (Fix 4). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Secure Boot enabled in UEFI firmware (Confirm-SecureBootUEFI = True)
    └── Device on a supported Windows version (Server 2012+ / Win10 22H2+ / Win11
            22H2+ for the confidence-data-driven rollout; older builds can still
            receive the keys but aren't part of Microsoft's automated confidence
            targeting)
            └── Deployment trigger present — ONE of:
                    ├── Registry: AvailableUpdates = 0x5944 (manual/fleet-tool)
                    ├── GPO: Secure Boot policy applied → writes AvailableUpdatesPolicy
                    ├── Intune: Secure Boot CSP profile applied → writes
                    │       AvailableUpdatesPolicy (same mechanism as GPO, different
                    │       delivery channel)
                    └── Microsoft-managed automatic rollout (HighConfidenceOptOut=0,
                            device in a "high confidence" bucket) OR
                            MicrosoftUpdateManagedOptIn=1 (opt-in to Controlled
                            Feature Rollout / diagnostic-data-gated)
                    └── Scheduled task "\Microsoft\Windows\PI\Secure-Boot-Update"
                            runs (every 12h) and processes the AvailableUpdates
                            bitmask
                            └── New certs written to UEFI DB/KEK
                                    └── Restart occurs (required to swap the boot
                                            manager to the 2023-signed version)
                                            └── UEFICA2023Status → Updated
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm Secure Boot itself is on.** `Confirm-SecureBootUEFI`. If `False`, this entire topic is moot until Secure Boot is re-enabled — troubleshoot that first.

2. **Read the servicing status keys.**
   ```powershell
   Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing"
   ```
   Expected healthy end state: `UEFICA2023Status = Updated`, `UEFICA2023Error = 0`.

3. **If status is `NotStarted`, confirm a deployment trigger actually exists.**
   Check `AvailableUpdatesPolicy` (Intune/GPO-driven — read-only, don't hand-edit) vs. `AvailableUpdates` (manually/fleet-tool-set). If both are `0`/unset and the device isn't in Microsoft's automatic high-confidence rollout, nothing will happen until you explicitly deploy — see Fix 1.

4. **If status is `InProgress` and has been for a long time,** check whether a restart has occurred since deployment was triggered — the boot manager swap specifically requires one. Force a scheduled-task run to accelerate the check-in:
   ```powershell
   Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
   ```

5. **If `UEFICA2023Error` is non-zero,** check the Windows Security app (`Windows Security > Device security > Secure Boot`) for a plain-language status message, and check Event Viewer for Secure Boot DB/DBX update events referenced by the error.

6. **Confirm the actual firmware-level result**, not just the registry claim:
   ```powershell
   Get-SecureBootUEFI -Name db -Decoded   # Windows 11 22H2+ / recent builds — needs the -Decoded parameter support
   ```
   Look for "Windows UEFI CA 2023" / "Microsoft UEFI CA 2023" entries in the returned certificate list — their presence is the ground-truth confirmation, independent of what the registry status key claims.

---
## Common Fix Paths

<details><summary>Fix 1 — Device shows NotStarted and needs to be deployed now (single device / lab test)</summary>

```powershell
# Trigger deployment (0x5944 = deploy all needed certs + KEK update + new boot manager)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot" /v AvailableUpdates /t REG_DWORD /d 0x5944 /f

# Force the servicing task to process it immediately instead of waiting up to 12h
Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"

# Check the value — should move toward 0x4100 once certs are written
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" | Select AvailableUpdates

# Restart the device, then run the task again to complete the boot manager swap
Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
```
For fleet-wide deployment, use GPO or Intune (Settings Catalog Secure Boot CSP / model-based targeting) instead of per-device registry edits — see `SecureBoot2023-A.md` Remediation Playbook 1.

Rollback: there is no supported rollback — this only adds trust for the new certificates; it does not remove the 2011-era ones or revoke anything. Adding the 2023 certs is additive and safe.

</details>

<details><summary>Fix 2 — Fleet-wide visibility: which devices are behind before the June 2026 deadline</summary>

Don't chase this one device at a time. Run `Scripts/Get-SecureBoot2023CertStatus.ps1` against your fleet (via RMM/Intune script deployment or a targeted remote session sweep) to get a status/error/capability inventory, then prioritize `WindowsUEFICA2023Capable = 0` and non-zero-`UEFICA2023Error` devices first — those need manual intervention, unlike `NotStarted` devices which just need the standard trigger.

</details>

<details><summary>Fix 3 — UEFICA2023Error is non-zero</summary>

1. Note the exact error code from `UEFICA2023Error` and the correlated `UEFICA2023ErrorEvent` ID.
2. Check Windows Event Logs for the matching Secure Boot DB/DBX update event (Microsoft's "Secure Boot DB and DBX variable update events" reference documents the event catalog).
3. Common root cause: a firmware-level limitation preventing the DB/KEK write — this is frequently an OEM firmware issue, not something fixable purely from Windows. If the error persists after a retry and reboot, escalate to the device manufacturer (see Fix 4).
4. Retry after any firmware update from the OEM:
   ```powershell
   Start-ScheduledTask -TaskName "\Microsoft\Windows\PI\Secure-Boot-Update"
   ```

Rollback: not applicable — this is a failed-forward state, not something to roll back.

</details>

<details><summary>Fix 4 — WindowsUEFICA2023Capable = 0 or Windows Security app shows "hardware or firmware limitation"</summary>

This means the device's firmware genuinely cannot accept the new certificate — no PowerShell/registry/policy fix exists for this. The Windows Security app will show: *"Secure Boot is on, but your device does not support the automated Secure Boot certificate update due to hardware or firmware limitations. Contact your device manufacturer for assistance."*

1. Check for an available firmware/BIOS update from the OEM — many vendors are shipping firmware updates specifically to add 2023 certificate support.
2. If no firmware update exists or is planned, document the device as a permanent exception and plan for hardware refresh ahead of the relevant expiration date, prioritized by the device's exposure (internet-facing, BitLocker-protected, high-value user).
3. Do not disable Secure Boot as a workaround — that removes boot-chain protection entirely, which is strictly worse than running with an aging-but-still-valid 2011 certificate.

</details>

<details><summary>Fix 5 — Windows Security app shows a yellow/red Secure Boot badge and users are asking about it</summary>

- **Yellow ("Not yet updated" with action required, from May 2026 onward)**: usually a hardware/firmware limitation blocking automatic delivery — see Fix 4.
- **Red ("Requires action")**: a boot-process security update exists that cannot be delivered to this device's current, un-updated boot configuration. This is the most urgent state — treat as a priority remediation item, not just an informational badge.
- On enterprise-managed devices these badges are **disabled by default** (`HideSecureBootStates` registry value) to reduce notification noise — if a user reports seeing one, either it was deliberately enabled for your org, or the device fell outside your management scope. Confirm before assuming a config drift.
- Users should not be told to click "I accept the risks, don't remind me" on a red badge without IT sign-off — that dismissal requires admin privileges and silences the warning without fixing the underlying gap.

</details>

---
## Escalation Evidence

```
=== Secure Boot 2023 Certificate Transition — Escalation Template ===
Device name:                          <fill in>
Confirm-SecureBootUEFI result:        <True/False>
UEFICA2023Status:                     <NotStarted/InProgress/Updated>
UEFICA2023Error (code):               <fill in, 0 = none>
WindowsUEFICA2023Capable:             <0/1/2>
AvailableUpdates value:               <fill in>
Deployment method attempted:          <registry / GPO / Intune / Microsoft-managed>
OS build / DisplayVersion:            <fill in>
Windows Security app badge colour:    <green/yellow/red/not visible>
Restart performed since trigger?:     <yes/no>
Firmware update available from OEM?:  <yes/no/unknown>
Business impact:                      <fill in>
Requested next step:                  <firmware escalation to OEM / policy deployment / exception documentation>
```

---
## 🎓 Learning Pointers

- This is not a "device will stop booting" emergency for the vast majority of hardware — devices without the 2023 certs keep booting and keep receiving normal Windows updates; what they lose is the ability to receive *new boot-chain security protections* going forward. See [Windows Secure Boot certificate expiration and CA updates](https://support.microsoft.com/en-us/topic/windows-secure-boot-certificate-expiration-and-ca-updates-7ff40d33-95dc-4c3c-8725-a9b95457578e).
- The expiration is a **window**, not a single date: KEK/UEFI CA/Option ROM CA certs expire June 24-27, 2026; the Windows Production PCA (boot loader signing) expires October 19, 2026.
- `AvailableUpdates = 0x5944` is the documented enterprise deployment trigger value — don't guess at other bitmask values; Microsoft explicitly states other bits are undocumented behavior.
- `AvailableUpdatesPolicy` is **read-only** — it reflects what GPO/Intune has set, and hand-editing it does nothing useful; edit policy instead. See [Registry key updates for Secure Boot](https://support.microsoft.com/en-us/help/5068202).
- Cross-reference `Windows/Troubleshooting/BitLocker/BitLocker-A.md` and `Windows/Troubleshooting/VBS-CredentialGuard-A.md` — both already document Secure Boot as a hard dependency; a device stuck on an expiring cert is a risk multiplier for those features too, not an isolated concern.
