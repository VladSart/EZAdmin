# Jamf Pro ↔ Microsoft Intune (macOS) — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers **two genuinely distinct architectures** MSPs encounter around Jamf Pro and Microsoft Intune for macOS, and is deliberately structured to keep them separate rather than presenting one as a variant of the other:

1. **Coexistence via the Compliance Connector (Partner Device Management)** — Jamf Pro remains the macOS MDM. Intune acts as a compliance/Conditional Access broker: Jamf syncs device inventory to Intune via Microsoft Entra ID, Intune's compliance engine evaluates it, and Microsoft Entra Conditional Access enforces resource access based on that evaluation. The device is never Intune-managed — only Intune-*evaluated*.
2. **Full migration off Jamf onto Intune-as-MDM** — using Microsoft's community-maintained migration script (`intuneMigration.sh` in `microsoft/shell-intune-samples`) to unmanage the device from Jamf Pro via its API and hand it to Intune enrollment.

**Explicitly out of scope / cross-referenced elsewhere:**
- Apple's own **Assign Device Management** wipe-free MDM-to-MDM re-enrollment workflow (macOS 26+, Apple Business/School Manager-driven, MDM-agnostic) is covered in `DeviceMigration-A.md`/`-B.md`. That mechanism doesn't know or care that the source MDM is Jamf specifically — this file covers the Jamf-specific API-driven unmanage path, which is a different and currently more commonly deployed approach for organizations not yet on macOS 26 fleet-wide, or that need the Company-Portal-first onboarding flow this script provides.
- Jamf Pro's own native MDM mechanics (profile push, Smart/Static Groups, Self Service catalog) are Jamf-console-side and not duplicated here.
- Third-party MDM-to-MDM migrations that are not Jamf-specific (Kandji, JumpCloud, etc.) are not covered.

**A documented Microsoft inconsistency worth knowing before you rely on either date:** the current `setup-jamf-manually` Learn page (last updated 2026-07-01) states Jamf's legacy **Conditional Access** integration's underlying platform stopped being supported **January 31, 2025**. A separately-maintained support article (`troubleshoot-jamf.md`, `ms.date` 2026-03-30) states the same deprecation event as **September 1, 2024**. Both pages currently exist and neither has been corrected to match the other as of this writing — treat this as a live example of why a single Microsoft Learn page should never be assumed authoritative in isolation when a specific date matters to a customer conversation.

---
## How It Works

<details><summary>Full architecture</summary>

**Coexistence model (Compliance Connector):**

The integration is built on an Entra app registration (created either manually or by the Jamf Cloud Connector) holding exactly three application permissions: `update_device_attributes` against the Intune API, and `Application.Read.All` against both Microsoft Graph and the legacy "Windows Azure Active Directory" API surface. Intune's **Partner device management** page stores this app's Application (client) ID and uses Include/Exclude security groups to decide which users' macOS devices should be routed to Jamf for management rather than enrolling natively in Intune (Exclude always wins over Include).

On the Jamf Pro side, the same app's Application ID and a client secret are entered under **Global Management → Conditional Access → macOS Intune Integration**, alongside a **Connection type** (Manual or Cloud Connector) and **Sovereign Cloud** selection. Once enabled, Jamf Pro periodically syncs macOS inventory data to Intune, keyed through the device's Microsoft Entra ID identity — established when the user registers the device via **Jamf Self Service** launching the **Company Portal for macOS**, which performs the actual workplace-join and issues the device an Entra token (refreshed every 12 hours, with a 7-day refresh token behind it).

Intune's compliance engine evaluates the synced inventory against a compliance policy (which **must** target a user group — device-group targeting is explicitly unsupported for Jamf-sourced devices and fails silently). The resulting compliance state feeds Microsoft Entra Conditional Access exactly as it would for a natively Intune-managed device.

Jamf Pro expects a device check-in every 15 minutes and marks a device **Unresponsive** after a 24-hour gap; independently, if the device's Entra token fails to refresh for 24+ hours, Jamf Pro also marks it Unresponsive — two different failure conditions producing the same displayed status, which is why triage always starts by determining *which* clock actually lapsed.

**Full migration model (unenroll-and-migrate script):**

`intuneMigration.sh` is a shell script, not a Microsoft product feature, maintained inside the community-facing `microsoft/shell-intune-samples` GitHub repository (contact: a named Microsoft employee, not a support queue). It is designed to be deployed as a **Jamf Self Service** policy so the end user self-initiates migration, though it also runs manually via `sudo`.

On execution it: checks for a `com.jamfsoftware` configuration profile (exits immediately if absent — this device isn't Jamf-managed); installs `swiftDialog` if missing for user-facing progress UI; prompts the user to **Migrate** or **Exit**; on Migrate, authenticates to the Jamf Pro API (either **basic** auth using a Jamf Pro user account's credentials against `/api/v1/auth/token`, or **OAuth** using an API Roles & Clients credential against `/api/oauth/token` — OAuth is the only path available if the tenant has disabled basic-auth user tokens, and is Jamf's own recommended method on Jamf Pro 10.49+); looks up the device's `computer_id`; sends an **unmanage** command through the Jamf Pro API; then runs `jamf removeFramework` to physically remove the Jamf agent from the Mac.

The script then installs or validates the Microsoft Intune Company Portal app, optionally strips leftover `MS-Organization-Access` (WorkplaceJoin) certificates from the user's login keychain (controlled by `REMOVE_WORKPLACE_JOIN_CERTS`, default `true` — these certs, left behind from Entra device registration under the old Jamf-Intune compliance-connector coexistence, actively block a clean new Intune enrollment if not removed), and branches on ADE (Automated Device Enrollment / DEP) status: ADE-enrolled devices have their profiles renewed and the user walks back through relevant Setup Assistant screens; non-ADE devices are handed to the user to sign into Company Portal manually.

**Critical architectural point:** the script's own documentation is explicit that reaching the "Waiting for Intune" status screen is where the script's job *ends* — it does not configure or trigger any actual Intune enrollment experience itself. If no onboarding experience (Enrollment Status Page, or a separate onboarding tool such as the swiftDialog onboarding sample Microsoft cross-references) has been independently deployed and assigned, the device sits at that screen indefinitely. This is the single most common "the migration script doesn't work" report, and it is not a script defect.

A structurally identical Intune-to-Intune variant of the same script exists in the same repository for tenant-to-tenant migrations (e.g., M&A), authenticating via a dedicated Entra app registration with `DeviceManagementManagedDevices.ReadWrite.All` Graph permission instead of the Jamf Pro API — mentioned here for completeness but out of this file's primary scope.

</details>

---
## Dependency Stack

```
Layer 7 — Microsoft Entra Conditional Access policy (enforcement, coexistence model only)
Layer 6 — Intune device compliance policy, assigned to a USER group (evaluation)
Layer 5 — Intune Company Portal for macOS registration / workplace join (Entra token, 12h refresh)
Layer 4 — Jamf Self Service policy: deploy Company Portal + trigger registration
              (bypassing this via manual Company Portal launch = Cause 4 failure mode)
Layer 3 — Jamf Pro ▸ Conditional Access ▸ macOS Intune Integration toggle + credentials
Layer 2 — Intune ▸ Partner device management: App ID + Include/Exclude group config
Layer 1 — Entra app registration: EXACTLY 3 application permissions
              (update_device_attributes + Graph Application.Read.All
               + Windows Azure AD Application.Read.All)
Layer 0 — Microsoft Intune + Microsoft Entra ID P1 licensing on the affected user
```

For the **full-migration path**, the dependency chain is orthogonal to the above:

```
Apple Business Manager: device reassigned from Jamf MDM server → Intune MDM server
              (must happen BEFORE the migration script's ADE branch runs)
        │
Jamf Pro API credentials with "Send Computer Unmanage Command" + "Read Computers"
        │
intuneMigration.sh execution (unmanage → removeFramework → Company Portal install)
        │
Independently-configured Intune enrollment/onboarding experience
              (the script does not create this — its absence is the #1 "stuck" cause)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device marked "Unresponsive" in Jamf Pro | Check-in gap (24h) or Entra token refresh failure (24h) | User sign-in prompt history; `Get-MgDeviceManagementDeviceManagementPartner` for tenant-wide health |
| Repeated keychain "wants to access key 'Microsoft Workplace Join Key'" prompts | Normal per-app Entra auth prompt from Jamf-deployed apps, not a fault | Confirm user selected Always Allow per app; explain this is expected, not a bug |
| "Unable to connect to Microsoft Intune. Check your Microsoft Intune Integration configuration." | Expired Jamf **or** Intune license | `Get-MgUserLicenseDetail`; confirm with Jamf admin on their side too |
| Device stuck showing "Not registered" in Company Portal, with a `WelcomeViewController` log line about partner management | User opened Company Portal directly instead of via Jamf Self Service (Cause 4) | Company Portal logs; re-run via Self Service after cleanup |
| "Invalid command line input... Registration-only command line flag (-r)..." | Intune integration toggle is OFF in Jamf Pro | Jamf Pro console → Conditional Access → macOS Intune Integration |
| Multiple entries for the same Mac in Intune console | Prior enrollment not fully cleaned up before re-enrollment (Cause 6) | `Get-MgDeviceManagementManagedDevice` grouped by `SerialNumber` |
| Device shows compliant in Intune, noncompliant in Entra ID / blocked by Conditional Access | Same root cause as duplicate entries — stale registration artifact | Same as above; resolve via full cleanup, not a policy change |
| Compliance policy never evaluates for Jamf-managed Macs | Policy assigned to a device group (unsupported for this integration) | `Get-MgDeviceManagementDeviceCompliancePolicyAssignment` — confirm target is a user group |
| "Could not retrieve the access token for Microsoft Graph API..." | Wrong/extra app permissions, expired license, or blocked network ports | App registration permission list; license check; port reachability (443 Intune, 2195/2196/5223 Apple, 80/5223 Jamf) |
| Migration script exits immediately with no prompt | No `com.jamfsoftware` profile present — device is already not Jamf-managed | `sudo profiles list -all` on the Mac |
| Migration script hangs at "Waiting for Intune" indefinitely | ABM device reassignment not done before script ran, OR no Intune onboarding experience configured | Apple Business Manager device assignment; Intune Enrollment Status Page / onboarding config |
| Device re-enrolled after migration but Company Portal won't complete sign-in | Leftover `MS-Organization-Access` WorkplaceJoin certs from prior coexistence registration | Login keychain inspection; re-run script with `REMOVE_WORKPLACE_JOIN_CERTS=true` or run cleanup manually |
| Migration script's Jamf Pro API auth fails immediately | Jamf Pro has disabled basic-auth user tokens; script configured for `basic` instead of `oauth` | `JAMF_AUTH_METHOD` variable in the script; confirm Jamf Pro version (10.49+ required for OAuth API Roles/Clients) |

---
## Validation Steps

1. **Confirm the partner connector's tenant-wide state.**
   ```powershell
   Get-MgDeviceManagementDeviceManagementPartner | Select-Object DisplayName, PartnerState, IsConfigured, MacOsOnboarded
   ```
   Good: `PartnerState` = `enabled`. Bad: `unresponsive`, `unavailable`, or `terminated` with a `WhenPartnerDevicesWillBeRemoved` date already populated.

2. **Confirm the app registration's permission set is exactly the documented three.**
   ```powershell
   $sp = Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')"
   Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id | Select-Object ResourceDisplayName, AppRoleId
   ```
   Good: three entries — Intune (`update_device_attributes`), Microsoft Graph (`Application.Read.All`), Windows Azure Active Directory (`Application.Read.All`). Bad: any additional permission present, or fewer than three, or admin consent not granted.

3. **Confirm compliance policy assignment target type.**
   ```powershell
   $policy = Get-MgDeviceManagementDeviceCompliancePolicy -Filter "startswith(displayName,'macOS')"
   Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $policy.Id
   ```
   Good: target references a group whose membership type is user-based. Bad: assignment references a dynamic **device** group.

4. **Check for duplicate device records.**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
       Group-Object SerialNumber | Where-Object Count -gt 1
   ```
   Good: empty result. Bad: any serial number with count > 1 — treat as a live Cause 6 case even if the device isn't currently the subject of a ticket.

5. **On the Mac, confirm current MDM enrollment state matches expectation.**
   ```bash
   sudo profiles status -type enrollment
   sudo profiles list -all
   ```
   Good (coexistence model): `com.jamfsoftware.*` profile present, MDM enrolled = Yes. Good (post-migration): `Microsoft.Profiles.MDM` present, no `com.jamfsoftware` profile remains.

6. **For a full-migration ticket, confirm ABM device assignment before assuming a script defect.**
   In Apple Business Manager (or Apple School Manager), confirm the device's assigned MDM server is now Intune, not Jamf. If it's still assigned to Jamf, the migration script cannot succeed regardless of how many times it's re-run.

7. **Review the migration script's own log for a definitive execution trail.**
   ```bash
   cat "/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log"
   ```
   Confirms exactly which step (unmanage call, `removeFramework`, Company Portal install, ADE branch) the script last completed successfully.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Establish which architecture this ticket is about.** Do not proceed further until you know whether Jamf Pro is meant to remain the MDM (coexistence) or is being removed entirely (migration). Every fix path below assumes you got this right.

**Phase 2 — Tenant-side connector health (coexistence tickets only).** Run [Validation Steps 1-4](#validation-steps). A broken app registration or a terminated connector explains an entire tenant's worth of tickets at once — check this before triaging individual devices.

**Phase 3 — Device-side registration state.** [Validation Step 5](#validation-steps) on the affected Mac. Cross-reference against Company Portal's own registration status and log output.

**Phase 4 — Exact error text matching.** Match the literal error string against the [Symptom → Cause Map](#symptom--cause-map) — Microsoft's own documented errors for this integration are specific enough to skip most of the guesswork phase entirely.

**Phase 5 — Cleanup, if a stale registration is implicated.** Cause 6's full manual cleanup (see [Playbook 2](#remediation-playbooks)) is destructive and time-consuming (30-minute mandatory wait built in) — confirm via [Validation Step 4](#validation-steps) that duplicates genuinely exist before starting it, rather than running it reflexively on every "weird" ticket.

**Phase 6 — For migration tickets, confirm ABM assignment and onboarding config before touching the script again.** [Validation Steps 6-7](#validation-steps). Re-running the script against a device still ABM-assigned to Jamf, or against a tenant with no onboarding experience configured, will reproduce the exact same "stuck" result every time.

**Phase 7 — Escalate to the correct vendor.** Jamf Pro license issues, Jamf Pro role/permission configuration, and Jamf-side check-in health are outside Intune-side remediation entirely — route to Jamf Customer Success rather than continuing to iterate on the Intune side.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up compliance-connector coexistence from scratch</summary>

1. Confirm prerequisites: Jamf Pro 10.1.0+, Intune + Entra ID P1 licensing, a Global Administrator account, the Company Portal for macOS app package, and macOS 10.12+ on target devices.
2. Confirm the required network ports are open (443 Intune; 2195/2196/5223 Apple push; 80/5223 Jamf; plus the Apple `17.0.0.0/8` block on 5223/443).
3. In Entra ID: create a new app registration, remove all default API permissions, then add exactly `update_device_attributes` (Intune, Application permission) and `Application.Read.All` against both Microsoft Graph and Windows Azure Active Directory. Grant admin consent. Record the Application (client) ID and a client secret.
4. In Intune: **Tenant administration → Connectors and tokens → Partner device management**, paste the Application ID into "Specify the Microsoft Entra App ID for Jamf," Save.
5. In Jamf Pro: **Global Management → Conditional Access → macOS Intune Integration → Edit**, enable Intune Integration for macOS, select Manual connection type and the correct Sovereign Cloud, open the administrator consent URL and approve the Jamf Native macOS Connector app, then enter the tenant name, Application ID, and client secret. Save.
6. Back in Intune's Partner device management page, configure Include/Exclude groups, select **Evaluate** to preview enrollment counts, then **Save**.
7. Deploy the Company Portal for macOS app via a Jamf policy, and create a Jamf Self Service policy that has users register with Microsoft Entra ID.
8. Build and assign a macOS compliance policy targeted to a **user** group (not device group).
9. Pilot with a small group before wide rollout; validate via [Validation Steps 1-5](#validation-steps).

**Rollback:** disable "Enable Intune Integration for macOS" in Jamf Pro and select **Terminate** in Intune's Partner device management page — devices are removed from Intune roughly 90 days after termination (both sides describe this consistently as approximately three months).

</details>

<details><summary>Playbook 2 — Full stale-registration cleanup (Cause 6)</summary>

The complete, Microsoft-documented sequence — this is intentionally thorough because a partial cleanup is the most common reason the same device generates a repeat ticket weeks later.

1. On the Mac: `sudo jamf removemdmprofile` then `sudo jamf removeFramework`.
2. In the Jamf Pro console, delete the computer's inventory record entirely.
3. In the Entra admin center, delete the device object(s) for this Mac.
4. On the Mac, delete (if present) and then restart:
   - `/Library/Application Support/com.microsoft.CompanyPortal.usercontext.info`
   - `/Library/Application Support/com.microsoft.CompanyPortal`
   - `/Library/Application Support/com.jamfsoftware.selfservice.mac`
   - `/Library/Saved Application State/com.jamfsoftware.selfservice.mac.savedState`
   - `/Library/Saved Application State/com.microsoft.CompanyPortal.savedState`
   - `/Library/Preferences/com.microsoft.CompanyPortal.plist`
   - `/Library/Preferences/com.jamfsoftware.selfservice.mac.plist`
   - `/Library/Preferences/com.jamfsoftware.management.jamfAAD.plist`
   - Per-user: `~/Library/Cookies/com.microsoft.CompanyPortal.binarycookies`, `~/Library/Cookies/com.jamf.management.jamfAAD.binarycookies`
5. In Keychain Access, remove entries referencing Microsoft, Intune, Company Portal, and DeviceLogin/`MS-Organization-Access` certificates. Remove JAMF-referencing entries **except** the JAMF public/private key pair — removing that pair breaks device enrollment outright and is not part of this cleanup.
6. Uninstall Company Portal.
7. In the Intune admin center, delete every remaining instance of the device. **Wait at least 30 minutes** before proceeding — this is a Microsoft-documented required wait, not a suggestion.
8. Re-enroll the device in Jamf Pro.
9. Reopen Self Service and re-run the registration policy.

**Rollback:** none — this playbook is itself the recovery path. There is no safe partial-undo; if interrupted partway through, finish the full sequence rather than reverting individual steps.

</details>

<details><summary>Playbook 3 — Full migration off Jamf onto Intune-as-MDM</summary>

1. **Before touching any device:** in Apple Business Manager (or Apple School Manager), reassign the target device(s)' MDM server from Jamf to Intune. This must happen first — the migration script's ADE branch depends on it.
2. Separately configure and assign an Intune enrollment/onboarding experience (Enrollment Status Page or an equivalent onboarding tool) to the group the migrating devices will land in. Skipping this step is the top cause of devices stuck at "Waiting for Intune."
3. In Jamf Pro, create (or confirm) a Jamf Pro role with **Send Computer Unmanage Command** (Server Action) and **Read Computers** (Server Object) permissions, assigned to either a service account (basic auth) or an API Roles & Clients credential (OAuth, required if basic-auth user tokens are disabled, recommended on Jamf Pro 10.49+).
4. Configure the script's top-of-file variables: `JAMF_AUTH_METHOD` (`basic` or `oauth`), `JAMF_PRO_URL`, and credentials, plus `REMOVE_WORKPLACE_JOIN_CERTS` (leave `true` unless this environment never used Entra device registration alongside Jamf).
5. Host `intuneMigration.sh` as a Jamf Self Service policy so users self-initiate (recommended), or distribute for manual `sudo ./intuneMigration.sh` execution.
6. Pilot on a small set of test Macs first. Confirm via the script's own log (`/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log`) that each phase (unmanage → removeFramework → Company Portal install → ADE/non-ADE branch) completes.
7. Validate end state per [Validation Step 5](#validation-steps) — `com.jamfsoftware` profile gone, `Microsoft.Profiles.MDM` present.
8. Roll out in waves once pilot devices confirm clean end-to-end completion.

**Rollback:** there is no single-command rollback — by the time the script has run, the Jamf framework has already been removed from the device. To revert, reassign the device back to Jamf in Apple Business Manager and re-enroll through Jamf's normal ADE flow from scratch.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS Collects Jamf/Intune integration health evidence for escalation.
.NOTES Read-only. Requires Microsoft.Graph.DeviceManagement and
       Microsoft.Graph.Applications modules with DeviceManagementManagedDevices.Read.All,
       DeviceManagementConfiguration.Read.All, and Application.Read.All scopes.
#>
$evidence = [ordered]@{
    PartnerConnector   = Get-MgDeviceManagementDeviceManagementPartner
    AppRegistration    = Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')" |
                          ForEach-Object { Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $_.Id }
    DuplicateDevices   = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
                          Group-Object SerialNumber | Where-Object Count -gt 1
    CompliancePolicies = Get-MgDeviceManagementDeviceCompliancePolicy -Filter "startswith(displayName,'macOS')" |
                          ForEach-Object {
                              [PSCustomObject]@{
                                  Policy      = $_.DisplayName
                                  Assignments = Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $_.Id
                              }
                          }
    Timestamp          = Get-Date -Format o
}
$evidence | ConvertTo-Json -Depth 6 | Out-File ".\JamfIntuneEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).json"
```

On the affected Mac, additionally collect:
```bash
sudo profiles status -type enrollment
sudo profiles list -all
cat "/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log" 2>/dev/null
```

---
## Command Cheat Sheet

```powershell
# Partner connector tenant-wide status
Get-MgDeviceManagementDeviceManagementPartner

# App registration permission audit
Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId <sp-id>

# Duplicate macOS device detection
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
    Group-Object SerialNumber | Where-Object Count -gt 1

# Compliance policy assignment target check
Get-MgDeviceManagementDeviceCompliancePolicy -Filter "startswith(displayName,'macOS')"
Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId <policy-id>

# License check
Get-MgUserLicenseDetail -UserId <user-upn>
```

```bash
# On the Mac — enrollment / profile state
sudo profiles status -type enrollment
sudo profiles list -all

# Full stale-registration cleanup (Playbook 2, steps 1-2)
sudo jamf removemdmprofile
sudo jamf removeFramework

# Migration script log
cat "/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log"

# Run the migration script manually
chmod +x intuneMigration.sh
sudo ./intuneMigration.sh
```

---
## 🎓 Learning Pointers
- The Compliance Connector model and a full MDM migration are not two points on the same spectrum — one keeps Jamf as the MDM forever, the other removes it entirely. Misidentifying which one a ticket is about is the single most common reason a fix path from this file fails to resolve anything.
- `update_device_attributes` is a narrow, purpose-built Intune API permission — the integration is designed to fail closed if the app registration has *anything* beyond the three documented permissions, which is an unusually strict (and easy to accidentally violate during a "let's just add Directory.Read.All while we're in here" cleanup pass) security posture worth calling out to customers.
- The 30-minute mandatory wait in the stale-registration cleanup procedure is not conservative padding — it reflects real propagation delay in Intune's device-removal pipeline; re-enrolling before the wait completes reliably reproduces the same duplicate-entry problem the cleanup was meant to fix.
- The migration script's silent dependency on a *separately* configured Intune onboarding experience is a good general lesson: a script or automation that "hands off" to a platform's normal enrollment flow should always be evaluated together with whatever depends on that flow already being configured, not treated as self-contained.
- See [Manually configure Jamf Pro integration with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/conditional-access-integration/setup-jamf-manually), [Troubleshooting integration of Jamf Pro with Microsoft Intune](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/support/mem/intune/device-protection/troubleshoot-jamf.md), and [microsoft/shell-intune-samples — macOS Migration Tools](https://github.com/microsoft/shell-intune-samples/blob/master/macOS/Tools/Migration/readme.md) for the primary sources this runbook is built from.
- Cross-reference `DeviceMigration-A.md`/`-B.md` for Apple's own MDM-agnostic Assign Device Management workflow — a genuinely different mechanism worth knowing about as an alternative for macOS 26+ fleets.
