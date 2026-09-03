# Android Play Integrity / Strong Integrity — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Context:** Google redefined "Strong Integrity" for Android 13+ devices (rolled out May 2025) to require hardware‑backed security signals **and** a security patch released within the trailing 12 months. Microsoft Intune enforces this stricter definition against the **Play Integrity Verdict** / **Check strong integrity** compliance and app‑protection settings starting **October 31, 2026**. Any Android 13+ device that hasn't taken a security update in 12 months will fail Strong Integrity from that date, even if it passed last week. Source: [Support tip: Changes to Google Play strong integrity for Android 13 or above](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-changes-to-google-play-strong-integrity-for-android-13-or-above/4435130), [Android Enterprise compliance settings reference](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-android-enterprise-settings) (ms.date 2026-06-18).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run against a single affected user/device via Microsoft Graph (Microsoft.Graph.DeviceManagement module, already connected):

```powershell
$upn = "<user@contoso.com>"

# 1. Find the device and its Android security patch date
$device = Get-MgUserManagedDevice -ManagedDeviceUserId (Get-MgUser -UserId $upn).Id |
    Where-Object { $_.OperatingSystem -eq 'Android' }
$device | Select-Object DeviceName, OSVersion, ManagementAgent, ComplianceState,
    AndroidSecurityPatchLevel, EnrolledDateTime

# 2. Pull the compliance policy states for this device
Get-MgDeviceManagementManagedDeviceDeviceCompliancePolicyState -ManagedDeviceId $device.Id |
    Select-Object DisplayName, State, Platform

# 3. Check the specific setting states (look for Play Integrity / strong integrity)
Get-MgDeviceManagementManagedDeviceDeviceComplianceSettingState -ManagedDeviceId $device.Id |
    Where-Object { $_.Setting -match 'PlayIntegrity|StrongIntegrity|DeviceThreat' } |
    Select-Object SettingName, State, CurrentValue
```

| Observation | Meaning | Do |
|---|---|---|
| `AndroidSecurityPatchLevel` older than 12 months, OS is Android 13+ | Device no longer meets Google's redefined Strong Integrity bar | Go to [Fix 1](#fix-1) — patch the device |
| `ComplianceState = NonCompliant`, setting shows `PlayIntegrityVerdict` or `StrongIntegrity` failing, patch is recent (<12 mo) | Device hardware doesn't support strong integrity at all, or Play Services is stale | Go to [Fix 2](#fix-2) |
| Device is BYOD (personally owned work profile) and region has no Google Mobile Services | Play Integrity can never evaluate — unrelated to the Oct 2026 change | Go to [Fix 3](#fix-3) |
| Compliant today, user reports it will "break in October" | Expected — see [Fix 4](#fix-4) for proactive fleet remediation |
| Company Portal / Play Protect flags "device integrity" but compliance policy has **no** Play Integrity setting configured | Not this issue — check [Policy-Conflict-B.md](../Troubleshooting/Policy-Conflict-B.md) instead |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Google Play Integrity API (Google-side, not admin-configurable)
  └─ Play Protect certified device + Google Mobile Services present
        └─ Basic integrity verdict (app/device not tampered)
              └─ Device integrity verdict (genuine, Play-certified hardware)
                    └─ Strong integrity verdict (hardware-backed key attestation)
                          └─ NEW (Android 13+, enforced by Intune 2026-10-31):
                              security patch level within trailing 12 months
                                    └─ Intune compliance policy: "Play Integrity Verdict"
                                       = Check basic integrity & device integrity
                                          └─ "Check strong integrity using hardware-backed
                                             security features" = Check strong integrity
                                                └─ Device marked Compliant / Noncompliant
                                                └─ App protection policy conditional launch
                                                   (if strong integrity required there too)
```
Strong integrity is a *sub-requirement* of basic/device integrity, not independent — the "Check strong integrity" toggle is greyed out unless basic or device integrity is already required.
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the device is actually in scope.** This only affects Android **13 and above**. Android 12 and below devices are unaffected by the redefinition.
   ```powershell
   $device | Select-Object OSVersion
   ```
   Expected: version string starts `13`, `14`, `15`, or `16`. If lower, this isn't the cause.

2. **Check which compliance/app-protection policies actually require strong integrity.** Not every tenant configures this — many only require basic or device integrity.
   ```powershell
   Get-MgDeviceManagementDeviceCompliancePolicy -Filter "platform eq 'android'" |
       Select-Object DisplayName, Id
   # Then inspect the JSON body of each for the setting keys:
   #   playIntegrityVerdict, securityRequireGooglePlayIntegrityVerdict (naming varies by policy schema)
   ```
   If no policy sets `strong integrity` at all, this issue is out of scope — look elsewhere.

3. **Get the device's actual security patch date.**
   ```powershell
   $device.AndroidSecurityPatchLevel
   ```
   Compare against "today minus 12 months." If older, Google's own criteria will fail strong integrity regardless of what Intune does — this is not an Intune bug.

4. **Confirm Google Play Services / Company Portal are current.** A stale Play Services build can fail basic/device integrity independent of the patch-age issue.
   On-device: **Settings → Apps → Google Play Services → App details** and **Company Portal → About → Version**.

5. **Check for the GMS-availability edge case.** If the device operates in a region/market without Google Mobile Services, Play Integrity (all three levels) can never evaluate successfully — a separate, older limitation, not the 2026 change. See [Common Fix Paths → Fix 3](#fix-3).

---
## Common Fix Paths

<details><summary>Fix 1 — Device is out of security-patch date (the Oct 2026 scenario)</summary>

The only real fix is getting the device patched — there is no admin override for Google's own integrity criteria.

- **Company-owned (fully managed / dedicated / COPE):** push the pending OS update via Intune's Android Enterprise system update policy, or have the device physically connect to Wi-Fi and charge to pick up the OTA.
- **BYOD (personally owned work profile):** the update is entirely user-driven — Intune can only nudge via compliance non-compliance actions (email/block), it cannot force an OTA on personal hardware.
- If the device is end-of-life for vendor security updates (common on cheaper OEM hardware after ~2-3 years), it will **never** pass strong integrity again. Plan a device-refresh exception rather than chasing a fix that doesn't exist.

No PowerShell remediation exists for this — it's a device-side action. Rollback: none needed (nothing was changed).
</details>

<details><summary>Fix 2 — Hardware doesn't support strong integrity, or Play Services stale</summary>

Some devices (older/budget hardware, some AOSP-based custom ROMs) never support the hardware-backed key attestation strong integrity relies on — Intune will mark these permanently noncompliant against a strong-integrity requirement no matter how current the patch is.

1. Confirm via manufacturer spec sheet or by checking `basic integrity` and `device integrity` pass independently (strong fails only) — that pattern strongly suggests a hardware ceiling, not a patch problem.
2. Update Google Play Services and Company Portal to latest via Play Store.
3. If hardware genuinely can't support it, exempt the device group from the **strong integrity** requirement (keep basic/device integrity) rather than leaving it permanently noncompliant:
   ```powershell
   # Inspect current policy JSON, then patch just the strong-integrity setting off
   # for the affected policy (replace <policyId> and body with actual schema from step 2 above)
   Update-MgDeviceManagementDeviceCompliancePolicy -DeviceCompliancePolicyId <policyId> `
       -BodyParameter @{ "@odata.type" = "#microsoft.graph.androidCompliancePolicy" }
   ```
   Rollback: re-enable strong integrity on the policy once the device population is replaced/refreshed.
</details>

<details><summary>Fix 3 — No Google Mobile Services in region</summary>

Play Integrity (at any level) cannot evaluate on devices where GMS isn't present (some regions/markets, some OEM variants). This is a pre-existing limitation, unrelated to the 2026 change.

- Create a **separate compliance policy** scoped to the affected device group that does **not** require Play Integrity Verdict, per Microsoft's guidance in [Managing Android devices where Google Mobile Services isn't available](https://techcommunity.microsoft.com/t5/intune-customer-success/intune-customer-success-managing-android-devices-where-google/ba-p/1628793).
- Do not attempt to "fix" GMS on these devices — it's a market/hardware constraint, not a misconfiguration.

Rollback: remove the exception policy if the device population changes to GMS-capable hardware.
</details>

<details><summary>Fix 4 — Proactive fleet remediation ahead of Oct 31, 2026</summary>

Run the fleet-wide audit script (`Get-AndroidPlayIntegrityAudit.ps1` in `Intune/Scripts/`) now, not on Nov 1. It flags every Android 13+ managed device whose security patch is already outside the 12-month window, before enforcement flips them to noncompliant/blocked.

- Push pending OS updates to flagged company-owned devices.
- For BYOD, trigger a targeted Company Portal notification / non-compliance grace-period email campaign so users self-patch before the cutover.
- Re-run weekly until the flagged count trends to zero.

Rollback: N/A — this is a read-only audit, no policy changes made.
</details>

---
## Escalation Evidence

```
ANDROID PLAY INTEGRITY / STRONG INTEGRITY — ESCALATION
=======================================================
Ticket #: <>
User/UPN: <>
Device name: <>
Device ownership: <Corporate fully managed / Dedicated / COPE / BYOD work profile>
Android OS version: <>
Android security patch level (on-device): <YYYY-MM-DD>
Months since last patch: <>
Google Play Services version: <>
Company Portal version: <>
Compliance policy name(s) targeting device: <>
  Play Integrity Verdict setting: <Not configured / Basic / Basic+Device>
  Strong integrity setting: <Not configured / Required>
App protection policy also requiring integrity? <Y/N — name if Y>
Device compliance state (Graph): <Compliant / Noncompliant / Error>
Failing setting name (from ComplianceSettingState): <>
Region / GMS available?: <Y/N>
Is device hardware attestation-capable (per OEM spec)?: <Y/N/Unknown>
Business impact: <blocked from mail / Conditional Access denial / etc.>
```

---
## 🎓 Learning Pointers
- Strong integrity isn't an Intune setting Microsoft controls — Google evaluates it server-side via the Play Integrity API, and Microsoft can only surface pass/fail. When Google tightens the bar (as it did for Android 13+ patch recency), no Intune-side workaround restores a genuinely stale device's verdict — the fix is always the device's own security patch, a hardware capability limit, or an admin policy-scope decision.
- The "Check strong integrity" toggle only appears — and only matters — once basic or device integrity is already required. If a ticket claims a "strong integrity failure" but the policy shows Play Integrity Verdict as **Not configured**, look elsewhere; that setting isn't even evaluated.
- Distinguish this from the separate **Minimum security patch level** compliance setting (an admin-entered fixed date). That's an Intune-side rule you fully control; Play Integrity's patch-recency requirement is a rolling 12-month Google-side criterion baked into the strong integrity verdict itself — the two can disagree, and only one of them (the admin-configured one) is something you can loosen without a Microsoft policy change.
- Reference: [Support tip — Changes to Google Play strong integrity for Android 13 or above](https://techcommunity.microsoft.com/blog/intunecustomersuccess/support-tip-changes-to-google-play-strong-integrity-for-android-13-or-above/4435130) and [Android Enterprise compliance settings](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-android-enterprise-settings).
- For the underlying Google mechanics, see the [Play Integrity API overview](https://developer.android.com/google/play/integrity) and [Integrity verdicts](https://developer.android.com/google/play/integrity/setup#configure-api) on Android Developers.
