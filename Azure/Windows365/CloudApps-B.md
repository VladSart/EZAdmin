# Windows 365 Cloud Apps — Hotfix Runbook (Mode B: Ops)
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

Run these first. Cloud Apps only exists on **Windows 365 Flex, Shared mode** policies — if the policy isn't Shared mode, stop and redirect to `Flex-B.md`/`Windows365-B.md`.

```powershell
# 1. Confirm the policy is actually a Cloud Apps policy (both properties must match)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object DisplayName, UserExperienceType, ProvisioningType, Id

# 2. Confirm the underlying Cloud PCs are provisioning/provisioned, not stuck
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status

# 3. Confirm image type — custom images need Start Menu app discovery, gallery images don't
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object ImageType, ImageId, ImageDisplayName

# 4. Confirm license/concurrency ceiling for the policy (identical math to Flex Shared mode)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id

# 5. Confirm the affected user is in the assigned group and using a current Windows App build
Get-MgGroupMember -GroupId "<backing-group-id>" -All | Select-Object DisplayName, Id
```

| Result | Action |
|--------|--------|
| `UserExperienceType` is `cloudApp` but `ProvisioningType` is not `sharedByEntraGroup` | → [Fix 1 — Invalid Policy Property Pairing](#fix-1--invalid-policy-property-pairing) |
| Policy correct, but no apps ever show as "Ready to publish" | → [Fix 2 — App Discovery Failure](#fix-2--app-discovery-failure) |
| APPX/MSIX apps (e.g. newer Teams) missing from the list | → [Fix 3 — APPX/MSIX Requires Reprovisioning](#fix-3--appxmsix-requires-reprovisioning) |
| An app shows status `Failed` after Publish | → [Fix 4 — Failed App Publish](#fix-4--failed-app-publish) |
| An app or Cloud PC is stuck in `Preparing` indefinitely | → [Fix 5 — Stuck in Preparing](#fix-5--stuck-in-preparing) |
| Cloud PCs provisioned fine, but no Intune/LOB apps appear in Cloud Apps | → [Fix 6 — Autopilot Device Prep Apps Missing](#fix-6--autopilot-device-prep-apps-missing) |
| Users hitting "no session available" for a published app | → [Fix 7 — Concurrency Exhausted](#fix-7--concurrency-exhausted) |
| Published app launches an unpublished app (e.g., Outlook opens Edge) and it's reported as a bug | → [Fix 8 — Expected Cross-App Launch Behavior](#fix-8--expected-cross-app-launch-behavior) |
| Technician can't find a "Delete app" button | → [Fix 9 — No Delete Button by Design](#fix-9--no-delete-button-by-design) |
| All triage clean, still failing | → Escalate — open a Microsoft 365 admin center service request under Windows 365 |

---
## Dependency Cascade

<details><summary>What must be true for a published Cloud App to reach a user</summary>

```
Windows 365 Flex license pool (Shared mode allotment on this specific policy)
  └── Provisioning Policy
        ├── userExperienceType = cloudApp   (immutable after creation)
        └── provisioningType   = sharedByEntraGroup   (the ONLY valid pairing — enforced at creation)
              └── Cloud PC (Shared mode, Experience type "Cloud App") provisions
                    └── Image
                          ├── Gallery image — Start Menu apps auto-available
                          └── Custom image — PowerShell Start Menu scan required
                                └── Blocked by: tenant PowerShell auth policy, unsupported image
                    └── App enters "Ready to publish" in All Cloud Apps
                          └── Admin: Publish → Publishing → Published (or Failed)
                                └── App visible in Windows App to all users assigned to the policy
                                      └── Session concurrency = Flex licenses assigned to THIS policy
                                            └── Same Shared-mode rules as Flex-A.md: no persistence
                                                (unless UES), no concurrency buffer, Global Cloud only
```

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm this is genuinely a Cloud Apps policy**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object UserExperienceType, ProvisioningType
```
Expected: `UserExperienceType = cloudApp` AND `ProvisioningType = sharedByEntraGroup`. These two properties are validated as a pair at creation time — Cloud Apps cannot exist on a Dedicated-mode or `sharedByUser` policy. If they don't match, this ticket is a policy-configuration problem, not an app problem — go to Fix 1.

**Step 2 — Confirm Cloud PC provisioning succeeded**
```powershell
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Select-Object DisplayName, Status
```
Expected: At least one Cloud PC in `provisioned` state. Apps cannot be discovered until the first Cloud PC finishes provisioning — if none have, this is a Fix 5 (stuck) or a plain provisioning failure (see `Troubleshoot provisioning errors`, out of scope here).

**Step 3 — Confirm image type before assuming an app-discovery bug**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object ImageType, ImageDisplayName
```
Expected: `gallery` images (with Microsoft 365 Apps preinstalled) discover apps automatically. `custom` images rely on a PowerShell-based Start Menu scan that can fail silently if the tenant enforces extra authentication on PowerShell execution, or if the custom image itself isn't supported for Cloud Apps.

**Step 4 — Confirm the actual per-app publish state (portal only — no API)**
```
No Graph/PowerShell surface exists for individual Cloud App publish state (Ready to publish /
Publishing / Published / Failed) as of this writing. Check Intune admin center → Devices →
Windows 365 → All Cloud Apps directly.
```
Expected: The app is present in the list. If it's missing entirely, this is a discovery problem (Fix 2/3), not a publish problem.

**Step 5 — Confirm concurrency headroom**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status
```
Expected: Provisioned Cloud PC count should track the number of Flex licenses assigned to this specific policy — this is exactly the Flex Shared-mode math in `Flex-B.md` Fix 1, not a Cloud-Apps-specific limit.

---
## Common Fix Paths

<details><summary>Fix 1 — Invalid Policy Property Pairing</summary>

**When:** Policy creation/update fails, or an existing policy shows `userExperienceType = cloudApp` with anything other than `provisioningType = sharedByEntraGroup`.

```powershell
# Confirm the mismatch
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object UserExperienceType, ProvisioningType

# userExperienceType CANNOT be changed after the policy is created. If the pairing is wrong,
# the policy must be re-created correctly — there is no in-place fix:
$body = @{
    "@odata.type"      = "#microsoft.graph.cloudPcProvisioningPolicy"
    displayName        = "<new-policy-name>"
    userExperienceType = "cloudApp"
    provisioningType   = "sharedByEntraGroup"
    imageType          = "gallery"
    imageId            = "<gallery-image-id>"
}
New-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -BodyParameter $body
```

**Rollback:** N/A — this is a create-time constraint, not a reversible setting. Delete the misconfigured policy only after confirming no users/Cloud PCs are actively relying on it.

</details>

<details><summary>Fix 2 — App Discovery Failure</summary>

**When:** Cloud PC(s) provisioned successfully, but zero apps ever appear as "Ready to publish."

```
1. Confirm image type (Step 3 above). Gallery images with Microsoft 365 Apps preinstalled
   should discover Office apps automatically — if even these are missing, suspect a broader
   provisioning fault rather than app discovery specifically.

2. For custom images: confirm the tenant does not enforce extra authentication/restricted
   execution policy on PowerShell — the Start Menu scan Cloud Apps uses to discover apps
   runs as a PowerShell script on first boot and fails silently under such policies.

3. Confirm the custom image itself is a supported Cloud Apps source image — an unsupported
   custom image also fails discovery with no user-facing error.

4. If neither applies, bulk reprovision the policy (see Fix 5) — a first-boot discovery
   scan that failed once does not automatically retry.
```

**Rollback:** N/A — diagnostic path. No configuration is changed until a fix (reprovision, image swap) is applied deliberately.

</details>

<details><summary>Fix 3 — APPX/MSIX Requires Reprovisioning</summary>

**When:** A known Start-Menu app that ships as APPX/MSIX (for example, newer builds of Microsoft Teams) never appears in "Ready to publish," even though classic Win32 apps from the same image do.

```
APPX/MSIX discovery support was added after some policies were first provisioned — existing
policies do NOT retroactively pick this up. The image preview shown during policy CREATION
also does not include APPX/MSIX apps, so don't use that preview to judge what will ultimately
be discoverable.

Fix: bulk reprovision the policy (Intune admin center → Devices → Windows 365 → Provisioning
policies → select policy → Reprovision) to force a fresh Start Menu scan that includes
APPX/MSIX discovery. There is no Graph cmdlet for this bulk action as of this writing.
```

**Rollback:** None — reprovisioning wipes local Shared-mode Cloud PC state by design (already non-persistent unless UES is enabled). Warn affected users of the maintenance window first.

</details>

<details><summary>Fix 4 — Failed App Publish</summary>

**When:** An app's status in All Cloud Apps shows `Failed` after a Publish attempt.

```
Microsoft's own documented fix is: Unpublish the app, then Publish it again. There is no
error detail or log surfaced beyond the "Failed" status itself.

Before retrying, confirm:
- The Start Menu shortcut this app was discovered from still exists and is valid on the
  image (path/command line intact) — a shortcut removed or altered after discovery but
  before republish is a common silent cause
- Any custom command-line parameters set via Edit are still valid for the current image
```

**Rollback:** Unpublish reverts the app to "Ready to publish" and resets any edited details (display name, description, command line, icon) back to the originally discovered values — this is expected, not data loss.

</details>

<details><summary>Fix 5 — Stuck in Preparing</summary>

**When:** A Cloud PC or its apps remain in `Preparing` status well beyond normal provisioning time.

```powershell
# Confirm the Cloud PC itself, not just the app list, is stuck
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Select-Object DisplayName, Status

# Step 1: bulk reprovision the policy (Intune admin center, no direct Graph cmdlet)
# Step 2: if reprovisioning does not clear the stuck state, delete and re-create the
#         Cloud Apps policy assignment (not the whole policy) — this is Microsoft's own
#         documented second-line fix for this specific symptom
```

**Rollback:** Reprovisioning/re-creating the assignment wipes local Shared-mode state (already non-persistent by design). Communicate to affected users before forcing it.

</details>

<details><summary>Fix 6 — Autopilot Device Prep Apps Missing</summary>

**When:** Cloud PCs provision successfully via an Autopilot Device Preparation policy, and Autopilot device prep itself reports success, but the expected Intune (Win32/LOB) apps never show up in Cloud Apps.

```
Check the Cloud Apps provisioning policy's Configuration tab: the checkbox "Prevent users
from connection to Cloud PC upon installation failure or timeout" MUST be selected for
Autopilot-Device-Prep-sourced apps to be discoverable by Cloud Apps. This is a specific,
easy-to-miss prerequisite distinct from Autopilot device prep succeeding on its own —
Autopilot can report a fully successful run while this separate box remains unchecked,
and Cloud Apps will still show nothing.

If Autopilot device prep itself is failing (not just app discovery), that's a separate
failure domain — see Autopilot Device Preparation monitoring/known-issues docs, out of
scope for this file.
```

**Rollback:** N/A — configuration correction on the provisioning policy, not destructive.

</details>

<details><summary>Fix 7 — Concurrency Exhausted</summary>

**When:** Users report "no session available" for a published Cloud App.

```powershell
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Group-Object Status

# The max number of ACTIVE Cloud App sessions for this policy equals the number of Flex
# licenses assigned to it — identical math to plain Flex Shared mode (Flex-B.md Fix 1).
# There is no separate Cloud-Apps-specific concurrency limit or buffer.
```

**Fix:** Add more Flex licenses to this policy's assignment, or split the user population across additional policies sized to observed peak usage. Cross-check the Connected Windows 365 Flex Cloud PCs report before assuming exhaustion — it's the only live concurrency view.

**Rollback:** N/A — capacity fix, not destructive.

</details>

<details><summary>Fix 8 — Expected Cross-App Launch Behavior</summary>

**When:** A user launches a published app (e.g., Outlook) which then opens a second app (e.g., Edge, via a clicked link) that was never itself published, and this is reported as a security or configuration bug.

```
This is documented, expected behavior — a published Cloud App can launch any other app
present on the underlying Cloud PC, published or not. Cloud Apps' publish/unpublish
mechanism controls what appears in Windows App, not what a running app is technically
capable of invoking on its own Cloud PC.

To actually restrict what can launch, deploy Application Control for Windows (WDAC)
policies on the underlying image — this is the only supported way to lock down
cross-app launching.
```

**Rollback:** N/A — no fault exists to roll back.

</details>

<details><summary>Fix 9 — No Delete Button by Design</summary>

**When:** A technician looks for a way to permanently remove an app from Cloud Apps and cannot find a "Delete" action.

```
There is no per-app delete action. Cloud Apps are discovered directly from the image's
Start Menu — to remove an app from scope, either:
  1. Remove the Cloud Apps provisioning policy's assignment (removes ALL apps under it), or
  2. Update the underlying image so the app's Start Menu shortcut no longer exists, then
     reprovision (Fix 3/5) so the change is picked up
Unpublish only hides the app from Windows App and resets its edited details — it does not
remove it from the Ready-to-publish list.
```

**Rollback:** N/A — this is explaining an intentional design limitation, not a fault.

</details>

---
## Escalation Evidence

Copy this template, fill in all fields, attach to ticket before escalating to Microsoft Support.

```
=== WINDOWS 365 CLOUD APPS ESCALATION EVIDENCE PACK ===
Date/Time (UTC): _______________
Reported by: _______________
Affected user(s)/group: _______________
Tenant ID: _______________
Provisioning Policy Name: _______________
Policy UserExperienceType: _______________
Policy ProvisioningType: _______________

SYMPTOM:
[ ] Invalid policy property pairing (cloudApp + not sharedByEntraGroup)
[ ] No apps discovered at all
[ ] APPX/MSIX app missing (reprovision not yet run)
[ ] App stuck in Failed after Publish
[ ] Cloud PC/app stuck in Preparing
[ ] Autopilot Device Prep apps missing ("Prevent users..." box unchecked)
[ ] Concurrency exhausted ("no session available")
[ ] Cross-app launch reported as bug (expected behavior)
[ ] Missing Delete button (expected — no such action exists)
[ ] Other: _______________

TRIAGE RESULTS:
Cloud PC Status: _______________
Image Type (gallery/custom): _______________
Provisioned Cloud PC count vs. assigned licenses: _______________
App status in All Cloud Apps (portal screenshot attached): [ ] Yes  [ ] No

ACTIONS TAKEN:
_______________

CORRELATION ID / Request ID: _______________
```

---
## 🎓 Learning Pointers

- **`userExperienceType` and `provisioningType` are a validated pair, not two independent settings** — `cloudApp` only works with `sharedByEntraGroup`, and neither can be changed after the policy is created. A misconfigured policy must be re-created, not patched. Reference: [cloudPcProvisioningPolicy resource type](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcprovisioningpolicy?view=graph-rest-beta)
- **There is no public API for the thing technicians actually want to check** — the per-app Ready-to-publish/Publishing/Published/Failed state lives only in the Intune admin center; don't waste time hunting for a Graph cmdlet that doesn't exist yet. Reference: [Windows 365 Cloud Apps](https://learn.microsoft.com/en-us/windows-365/enterprise/cloud-apps)
- **Concurrency math is inherited, not separate** — a Cloud Apps policy's session ceiling is the same "Flex licenses assigned to this policy" formula as plain Flex Shared mode; there's no separate Cloud-Apps-specific throttle to hunt for. See `Flex-B.md` Fix 1 and Fix 7 above.
- **Two silent failure modes share the same shape**: PowerShell-execution-policy-blocked image discovery (Fix 2) and the unchecked Autopilot "Prevent users..." box (Fix 6) both look identical from the outside — "apps just don't show up" — but have completely different root causes and fixes. Confirm which pipeline (custom image scan vs. Autopilot Device Prep) actually produced the Cloud PC before picking a fix.
- **"Frontline" naming lag applies here too** — this feature's own documentation still says Cloud Apps "run on Windows 365 Frontline Cloud PCs in shared mode" in places, even though Frontline was renamed Flex in May 2026. See `Flex-B.md` Fix 6 for the full naming-confusion context.
