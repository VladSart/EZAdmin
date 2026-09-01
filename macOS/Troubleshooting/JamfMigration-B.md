# Jamf Pro ↔ Microsoft Intune (macOS) — Hotfix Runbook (Mode B: Ops)
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

Run these against the **Intune (Entra ID) side** first — Jamf Pro console access is frequently a different admin/ticket queue than the one that opened this ticket.

```powershell
# 1. Is the Jamf Partner Device Management connector even configured/healthy?
Get-MgDeviceManagementDeviceManagementPartner | Select-Object DisplayName, PartnerState, IsConfigured, MacOsOnboarded, WhenPartnerDevicesWillBeRemoved

# 2. Does the Jamf Entra app registration have EXACTLY the permissions Microsoft documents (one extra scope breaks registration — Cause 1 below)?
Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')" | ForEach-Object {
    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $_.Id | Select-Object AppRoleId, ResourceDisplayName
}

# 3. Are there duplicate macOS device records for the affected user (the #1 root cause behind most Cause-6-style tickets)?
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
    Group-Object SerialNumber | Where-Object Count -gt 1 |
    Select-Object Name, Count

# 4. Is the macOS compliance policy assigned to a DEVICE group instead of a USER group (Jamf integration silently can't evaluate device-group-targeted policies)?
Get-MgDeviceManagementDeviceCompliancePolicy -Filter "startswith(displayName,'macOS')" |
    ForEach-Object { Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $_.Id }

# 5. Is the affected user/device correctly licensed (Intune + Entra ID P1)?
Get-MgUserLicenseDetail -UserId <user-upn>
```

| Result | Interpretation |
|---|---|
| `PartnerState` = `unresponsive` or `unavailable` | Connector itself is broken tenant-wide → [Fix 1](#fix-1) |
| `WhenPartnerDevicesWillBeRemoved` has a date | Someone already hit **Terminate** — this is a planned deprovision, not a bug → confirm with the requester before doing anything |
| App registration shows more than one Intune permission, or is missing `Application.Read.All` on Microsoft Graph / Windows Azure Active Directory | Cause 1 — bad app registration → [Fix 2](#fix-2) |
| Same `SerialNumber` appears 2+ times in the duplicate check | Cause 6 — orphaned prior enrollment → [Fix 3](#fix-3) |
| Compliance policy assignment target is a device group | Documented, unsupported configuration → [Fix 4](#fix-4) |
| License missing/expired for Intune or Entra ID P1 | → [Fix 5](#fix-5) |
| All of the above look clean | Move to [Diagnosis & Validation Flow](#diagnosis--validation-flow) — likely a device-local (Mac-side) or Jamf-console-side issue, not an Intune-side one |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Entra ID P1 + Intune license on the user
        │
        ▼
Entra app registration "Jamf Conditional Access" / "Jamf Native macOS Connector"
   (EXACTLY: update_device_attributes [Intune] + Application.Read.All [Graph]
             + Application.Read.All [Windows Azure Active Directory])
        │
        ▼
Intune ▸ Tenant administration ▸ Connectors and tokens ▸ Partner device management
   (Application ID pasted in, Include/Exclude group assignment saved + Evaluated)
        │
        ▼
Jamf Pro ▸ Global Management ▸ Conditional Access ▸ macOS Intune Integration
   (Enable Intune Integration for macOS = ON, tenant name + App ID + secret entered)
        │
        ▼
Company Portal for macOS deployed via JAMF POLICY (not manually) + user runs it via
JAMF SELF SERVICE (not by opening Company Portal directly)
        │
        ▼
Device registers with Microsoft Entra ID → workplace-join cert issued →
Jamf Pro syncs inventory → Intune compliance engine evaluates → Conditional Access enforces
```

Break any link above the last arrow and the symptom is the same from the end user's chair: **"Teams/Outlook keeps asking me to sign in" or "I can't get past the compliance check."**

</details>

---
## Diagnosis & Validation Flow

1. **Confirm which architecture is actually in play.** Ask: is Jamf Pro still the MDM (compliance-connector coexistence) or is this ticket about migrating OFF Jamf entirely onto Intune-as-MDM? These are different failure domains — do not run Fix 1-5 (all coexistence-connector fixes) against a full-migration ticket.
   - Coexistence signal: device shows up in **both** Jamf Pro and Intune consoles, Intune shows it as "co-managed"/partner-owned.
   - Migration signal: `com.jamfsoftware` profile still present on the Mac (`sudo profiles list -all | grep -i jamf`) and the goal is to remove it.

2. **On the Mac itself**, check enrollment state:
   ```bash
   sudo profiles status -type enrollment
   sudo profiles list -all | grep -iE "jamf|intune|microsoft"
   ```
   Expect to see either a `com.jamfsoftware.*` profile (still Jamf-managed) or `Microsoft.Profiles.MDM` (Intune-managed) — not neither, not conflicting partial sets of both.

3. **Check Company Portal's own registration state** in the app itself (Settings → About). `Not registered` combined with a Company Portal log line similar to:
   ```
   WelcomeViewController.swift:253 (startLogin()) Portal launched without WPJ only arg while account is under partner management
   ```
   confirms Cause 4 (user opened Company Portal manually instead of via Jamf Self Service) — go straight to [Fix 6](#fix-6).

4. **Pull the exact error text.** Jamf/Intune integration failures are almost always identifiable from the literal string:
   - `Unable to connect to Microsoft Intune. Check your Microsoft Intune Integration configuration.` → license issue → [Fix 5](#fix-5)
   - `Invalid command line input... Registration-only command line flag (-r) can only be used when partner management is enabled...` → integration toggle is OFF in Jamf → [Fix 7](#fix-7)
   - `Could not retrieve the access token for Microsoft Graph API...` → app permissions, license, or network ports → [Fix 2](#fix-2) / [Fix 5](#fix-5) / [Fix 8](#fix-8)

5. **If this is a full-migration ticket** (not coexistence), confirm the device was already reassigned to Intune in **Apple Business Manager** before the migration script ran — this is the single most common precondition miss. `sudo profiles show -type enrollment` after the script completes will hang at "Waiting for Intune" forever if ABM assignment wasn't switched first.

---
## Common Fix Paths

<details><summary>Fix 1 — Partner connector itself is unresponsive/unavailable tenant-wide</summary>

The `deviceManagementPartner` resource reports `unresponsive` when Jamf hasn't sent Intune a heartbeat, or `unavailable` when the connection was never fully established.

```powershell
Get-MgDeviceManagementDeviceManagementPartner | Format-List *
```

1. In the Jamf Pro console: **Global Management → Conditional Access → macOS Intune Integration**, confirm **Enable Intune Integration for macOS** is checked and **Save** again (this re-sends the pulse Intune is waiting on).
2. In Intune: **Tenant administration → Connectors and tokens → Partner device management**, select **Evaluate** to confirm group targeting still resolves, then **Save**.
3. Wait up to 15 minutes (Jamf Pro's own check-in interval) and re-run the triage query.

**Rollback:** none — this only re-asserts existing configuration, no data changes.

</details>

<details><summary>Fix 2 — App registration has wrong/extra permissions (Cause 1)</summary>

The integration **fails outright** if the Entra app registration has anything other than exactly:
- Intune → Application permission → `update_device_attributes`
- Microsoft Graph → Application permission → `Application.Read.All`
- Windows Azure Active Directory (APIs my organization uses) → Application permission → `Application.Read.All`

```powershell
$sp = Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id
```

1. In the Entra admin center, open the app registration (App registrations, not Enterprise applications) used for Jamf.
2. Under **API permissions**, remove every permission that is not one of the three listed above.
3. Re-add any that are missing, then select **Grant admin consent for `<tenant>`**.
4. Refresh the page and confirm only the expected permissions show as **Granted**.

**Rollback:** if you're not sure what was there before, screenshot the current (broken) permission list before editing — there is no "undo," only re-adding.

</details>

<details><summary>Fix 3 — Duplicate device records / stuck prior enrollment (Cause 6)</summary>

This is the fix behind **most** "shows compliant in Intune but not in Entra," "duplicate entries," and "fails to register" tickets. It is destructive to the device's current registration state — warn the user before starting, they will need to sign back in.

On the Mac:
```bash
sudo jamf removemdmprofile
sudo jamf removeFramework
```

Then, in order:
1. Jamf Pro console — delete the computer's inventory record.
2. Entra admin center — delete the stale device object(s) for this Mac.
3. On the Mac, remove these if present, then restart:
   ```
   /Library/Application Support/com.microsoft.CompanyPortal.usercontext.info
   /Library/Application Support/com.microsoft.CompanyPortal
   /Library/Application Support/com.jamfsoftware.selfservice.mac
   /Library/Preferences/com.microsoft.CompanyPortal.plist
   /Library/Preferences/com.jamfsoftware.management.jamfAAD.plist
   ```
4. In Keychain Access, remove entries referencing *Microsoft*, *Intune*, *Company Portal*, and `MS-Organization-Access` certificates — **except** the JAMF public/private key pair (removing that breaks device enrollment outright).
5. Uninstall Company Portal, then go to the Intune admin center and delete every remaining instance of this device. **Wait at least 30 minutes.**
6. Re-enroll via Jamf Pro, then reopen Self Service and re-run the registration policy.

**Rollback:** none — this is itself the recovery procedure. Do not attempt it on a device that is currently working correctly.

</details>

<details><summary>Fix 4 — Compliance policy assigned to a device group</summary>

Jamf Pro integration **does not support** compliance policy assigned to device groups — only user groups.

```powershell
$policy = Get-MgDeviceManagementDeviceCompliancePolicy -Filter "startswith(displayName,'macOS')"
Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $policy.Id
```

1. In the Intune admin center, open the macOS compliance policy.
2. Under **Assignments**, remove the device-group assignment.
3. Re-assign to the equivalent **user** group instead.

**Rollback:** re-add the original device-group assignment — but note it will silently fail to evaluate again for any Jamf-managed Mac.

</details>

<details><summary>Fix 5 — License expired or missing</summary>

`Unable to connect to Microsoft Intune. Check your Microsoft Intune Integration configuration.` is Microsoft's own documented error text for an expired Jamf **or** Intune license — the message doesn't tell you which side.

```powershell
Get-MgUserLicenseDetail -UserId <user-upn>
```

1. Confirm the user holds a valid **Microsoft Intune** and **Microsoft Entra ID P1** license (or an equivalent EMS bundle).
2. If Intune-side license is missing, assign it and allow up to 8 hours for propagation.
3. If the license looks fine on the Intune side, the Jamf Pro license itself has likely lapsed — this requires the customer's Jamf Pro admin/Jamf Customer Success, not an Intune-side fix.

**Rollback:** n/a — assigning a license has no destructive rollback concern.

</details>

<details><summary>Fix 6 — User bypassed Jamf Self Service (Cause 4)</summary>

If a user opens Company Portal directly instead of launching it from Jamf Self Service, the device registers as **Intune-native**, not Jamf-partnered, and silently breaks the intended coexistence model.

1. [Run Fix 3](#fix-3) to remove the device from Intune cleanly first.
2. Confirm Company Portal for macOS is deployed via a **Jamf policy**, not left for manual download.
3. Confirm a Jamf policy exists that has the user register their device with Microsoft Entra ID.
4. Have the user open **Jamf Self Service** (not Company Portal directly) and run that registration policy.

**Rollback:** none required — this restores intended behavior, doesn't remove anything that was working correctly.

</details>

<details><summary>Fix 7 — Integration toggle is OFF in Jamf Pro</summary>

Symptom: `Invalid command line input... Registration-only command line flag (-r) can only be used when partner management is enabled in Intune.`

1. In Jamf Pro: **Global Management → Conditional Access → macOS Intune Integration → Edit**.
2. Check **Enable Intune Integration for macOS**.
3. **Save.**

**Rollback:** uncheck the box again — this is the intended toggle, safe either direction.

</details>

<details><summary>Fix 8 — Network ports blocked</summary>

If Graph token retrieval fails and Fix 2/Fix 5 both check out clean, confirm outbound connectivity from the Jamf Pro server / affected Mac:

| Path | Ports |
|---|---|
| Intune | 443 |
| Apple push (APNs) | 2195, 2196, 5223 |
| Jamf Pro | 80, 5223 |

Also confirm outbound access to the Apple `17.0.0.0/8` block over 5223/443 is not blocked by a firewall or SSL-inspecting proxy.

**Rollback:** n/a — this is a network configuration check, not a destructive change.

</details>

<details><summary>Fix 9 — Full migration stuck at "Waiting for Intune"</summary>

Microsoft's own migration script (`intuneMigration.sh`) intentionally stops here and **waits forever** unless an actual Intune onboarding experience has been separately configured and deployed — this is not a script bug.

1. Confirm the device was reassigned to **Intune** (not Jamf) in **Apple Business Manager** before the script ran. If it wasn't, ADE will keep re-offering the old MDM's profile and the migration cannot complete — re-run after fixing ABM assignment.
2. Confirm an Intune enrollment status page / onboarding experience is actually assigned to the target group (e.g., the swiftDialog onboarding sample Microsoft references, or your own ESP configuration).
3. If ADE assignment is correct and onboarding is configured but the device is still stuck, have the user manually complete Setup Assistant screens, then check `sudo profiles status -type enrollment` on the Mac directly.

**Rollback:** if the migration needs to be aborted, the device is left mid-transition — Jamf framework has already been removed by this point, so rollback means re-enrolling into Jamf from scratch via ADE reassignment back to Jamf in ABM, not resuming a "cancel."

</details>

---
## Escalation Evidence

```
JAMF ↔ INTUNE ESCALATION TEMPLATE
==================================
Ticket #: ____________
Affected user (UPN): ____________
Affected device serial number: ____________
Architecture in play: [ ] Coexistence (compliance connector)   [ ] Full migration to Intune-only

Triage query 1 output (deviceManagementPartner state): ____________
Triage query 2 output (app registration permissions):  ____________
Triage query 3 output (duplicate device check):        ____________
Triage query 4 output (compliance policy target type): ____________

Exact error text seen (copy verbatim): ____________
Where seen: [ ] Jamf Pro console  [ ] Company Portal  [ ] Intune admin center  [ ] End-user prompt

Jamf Pro version: ____________
Company Portal for macOS version: ____________
macOS version on affected device: ____________

Fixes already attempted (Fix # from this runbook): ____________
Result of each attempt: ____________

Company Portal log excerpt (~/Library/Logs/Company Portal/ or
/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log for migration tickets):
____________
```

---
## 🎓 Learning Pointers
- The two Microsoft Learn pages describing the exact same Conditional Access deprecation give **two different dates** — one says January 31, 2025, the other (an older, separately-maintained support article) says September 1, 2024. Never assume Microsoft's own docs are internally consistent; when a date matters for a ticket, cite the page you actually pulled it from and its last-updated timestamp.
- Jamf's legacy **Conditional Access** integration and the current **Device Compliance** integration (`jamf-entra-id`) are not the same product even though both report compliance to Entra ID — confirm which one a given tenant is actually running before applying fixes from the wrong generation of documentation.
- `Include`/`Exclude` group targeting in Partner device management is evaluated with **Exclude always winning** — a device in both groups goes to Intune directly, not Jamf, which is a common source of "why is this Mac not appearing in Jamf" tickets that look like a sync failure but are actually working as configured.
- The full unenroll-and-migrate script is community-maintained inside Microsoft's own `microsoft/shell-intune-samples` GitHub org, not a supported product feature — treat it as a strong reference implementation to adapt, not a guaranteed-stable tool to run unmodified in production without testing.
- See [Manually configure Jamf Pro integration with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/conditional-access-integration/setup-jamf-manually), the [Jamf troubleshooting support article](https://github.com/MicrosoftDocs/SupportArticles-docs/blob/main/support/mem/intune/device-protection/troubleshoot-jamf.md), and [microsoft/shell-intune-samples — macOS Migration Tools](https://github.com/microsoft/shell-intune-samples/blob/master/macOS/Tools/Migration/readme.md) for full detail beyond this hotfix scope.
