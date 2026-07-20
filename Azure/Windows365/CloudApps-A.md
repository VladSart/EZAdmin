# Windows 365 Cloud Apps — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

This runbook covers **Windows 365 Cloud Apps** — published, individual-application delivery to end users without handing out a full Cloud PC desktop per user. Cloud Apps is not a separate compute product: it is a delivery mode layered entirely on top of **Windows 365 Flex, Shared mode** (`Azure/Windows365/Flex-A.md`), and every Shared-mode mechanic described there (pooled licensing, non-persistence, no concurrency buffer, Azure Global Cloud only) applies here unchanged. This file covers only what is Cloud-Apps-specific: the provisioning policy property pairing that defines a Cloud Apps policy, the app discovery/publish lifecycle, and the client-side app-launch model.

This runbook assumes familiarity with `Flex-A.md` (the Shared-mode licensing/concurrency model this topic depends on) and `Windows365-A.md` (the underlying Cloud PC provisioning pipeline, Intune enrollment, and AVD connection broker shared by all Windows 365 products).

**Assumes:**
- Microsoft Graph PowerShell SDK (beta module): `Install-Module Microsoft.Graph.Beta -Scope CurrentUser`
- Authenticated with `Connect-MgGraph` and `CloudPC.ReadWrite.All`, `DeviceManagementConfiguration.Read.All` scopes
- Tenant has Windows 365 Flex licenses purchased and at least one Shared-mode provisioning policy configured

**Not covered:** Windows 365 Flex Dedicated mode and general Shared-mode licensing/concurrency mechanics (see `Flex-A.md`); Windows 365 Enterprise/Business (see `Windows365-A.md`); Application Control for Windows (WDAC) policy authoring itself, referenced here only as the mechanism to restrict cross-app launching; Azure Virtual Desktop RemoteApp, a related but architecturally separate published-app product.

---
## How It Works

<details><summary>Full architecture</summary>

### Cloud Apps is a policy-property pairing, not a separate resource

Windows 365 Cloud Apps is defined entirely by two properties on a standard `cloudPcProvisioningPolicy` object:

- **`userExperienceType = cloudApp`** — tells the platform end users access individual published apps rather than a full desktop. The default value if unspecified is `cloudPc` (full desktop). This property **cannot be changed after the policy is created** — there is no in-place conversion from a desktop policy to a Cloud Apps policy or back.
- **`provisioningType = sharedByEntraGroup`** — when `userExperienceType` is `cloudApp`, `provisioningType` **must** be `sharedByEntraGroup`. This is a validated pairing enforced by the platform at creation time, not two independently configurable settings. Attempting `cloudApp` with `dedicated`, `sharedByUser`, or the deprecated `shared` value fails.

Because Cloud Apps runs on Shared-mode Cloud PCs, the underlying Cloud PC devices it creates still appear in the normal Cloud PC device list — `userExperienceType` is the only property that distinguishes a Cloud Apps deployment from a plain Shared-mode desktop deployment when scanning the fleet.

### App discovery: how the platform finds what to publish

After the first Cloud PC under a Cloud Apps policy finishes provisioning, a scan runs against that Cloud PC's Start Menu to build the list of publishable apps:

- **Gallery images** (Microsoft's own Windows 365 images, which include Microsoft 365 Apps) discover apps automatically with no extra configuration.
- **Custom images** rely on a PowerShell script performing the Start Menu scan. This has two documented failure modes with no user-facing error: a tenant enforcing extra authentication or a restrictive execution policy on PowerShell blocks the scan entirely, and an unsupported custom image simply won't produce results. Neither failure surfaces as an explicit error — the symptom in both cases is just an empty or incomplete "Ready to publish" list.
- **APPX/MSIX support was added after some tenants' policies were already created.** Existing policies do not retroactively gain APPX/MSIX discovery — they require a bulk reprovision to pick it up. The image preview shown during policy **creation** also does not include APPX/MSIX apps, so that preview should never be used to judge final discoverability.
- **Autopilot Device Preparation** (public preview) is a second, distinct path for getting Intune-managed (Win32/LOB) apps in front of Cloud Apps' discovery. For those apps to actually be discovered, the Configuration tab's "Prevent users from connection to Cloud PC upon installation failure or timeout" checkbox must be selected — this is a separate, easy-to-miss prerequisite from Autopilot device prep itself reporting success.

### The publish lifecycle

Once discovered, each app moves through: **Ready to publish → Publishing → Published**, or **Failed** if publishing errors out. Microsoft's own documented fix for `Failed` is unpublish, then republish — no further diagnostic detail is surfaced. **Unpublish** reverts `Published → Ready to publish`, immediately removes the app from Windows App, and resets any edited details (display name, description, command line, icon) back to their originally discovered values. **Reset** performs the same detail-revert without changing publish state. **There is no delete action for an individual app** — apps are inherently tied to what's discoverable on the image; removing one permanently requires either removing the policy's assignment (removes everything under it) or altering the image so the Start Menu shortcut no longer exists, then reprovisioning.

Edits to an app's display name, description, command line, or icon apply **immediately** to Windows App — there is no publish/republish cycle for detail edits, only for the underlying publish state itself. Scope tags and assignment are always inherited from the provisioning policy; they cannot be set per-app.

### Licensing and concurrency — identical to Flex Shared mode, not a separate model

Cloud Apps introduces **no separate licensing or concurrency system**. The maximum number of simultaneously active Cloud App sessions for a given policy equals the number of Windows 365 Flex licenses assigned to that specific policy — the exact same math documented in `Flex-A.md` for plain Shared-mode desktop delivery. There is no per-app session limit, no Cloud-Apps-specific throttle, and no concurrency buffer (Shared mode never has one). Concurrency is monitored the same way as any Flex Shared-mode policy: the Connected Windows 365 Flex Cloud PCs report and the Flex concurrency alert in the Intune admin center — there is no live per-second concurrency reading via Graph.

All other Shared-mode inherited behavior also applies unchanged: no local persistence between sessions unless User Experience Sync (UES) is enabled on the policy, redirection and idle-timeout settings configured on the underlying Cloud PC also govern Cloud App sessions, and Shared mode (and therefore Cloud Apps) is available in **Azure Global Cloud only** as of this writing.

### Client access and the cross-app launch model

End users access published apps exclusively through **Windows App** (Windows, macOS, iOS, Android). A critical, frequently misunderstood behavior: a published app can launch **any other app present on the Cloud PC**, published or not — for example, Outlook (published) opening Edge (never published) via a clicked email link. Cloud Apps' publish mechanism governs what's *visible in Windows App*, not what a running process is technically capable of invoking on its own Cloud PC. The only supported way to actually restrict this is deploying **Application Control for Windows (WDAC)** policies on the underlying image — Cloud Apps itself has no app-isolation or launch-restriction feature.

On supported Windows versions (Windows 11 Enterprise 24H2, or 22H2/23H2 with the 2024-07 cumulative update KB5040442 or later), Cloud Apps sessions automatically launch OneDrive — a background convenience behavior, not something requiring separate configuration.

### Enhanced user experience (preview)

A public preview feature improves Cloud Apps' visual fidelity and window behavior: Windows Snap support, full-screen mode, better DPI handling, and refined visuals (borders, shadows, theme integration). This is enabled via the same **RemoteApp enhancements** toggle used by Azure Virtual Desktop's own RemoteApp feature — Cloud Apps and AVD RemoteApp share this specific enhancement mechanism even though they are otherwise separate products.

### The Frontline/Flex naming lag reaches this topic too

Microsoft's own Cloud Apps documentation still describes apps as running "on Windows 365 Frontline Cloud PCs in shared mode" in places, despite the May 8, 2026 Frontline→Flex rename covered in full in `Flex-A.md`. Treat any reference to "Frontline" here as identical to "Flex" — this is the same UI/documentation lag already documented for the parent product, not a second naming issue specific to Cloud Apps.

</details>

---
## Dependency Stack

```
Windows 365 Flex license pool (Shared-mode allotment assigned to THIS specific policy)
  └── Provisioning Policy — property pairing validated at creation, neither changeable after
        ├── userExperienceType = cloudApp   (immutable; default is cloudPc if unspecified)
        └── provisioningType   = sharedByEntraGroup   (the ONLY valid pairing with cloudApp)
              └── Cloud PC provisioning (Shared mode, Experience type "Cloud App")
                    ├── Same underlying platform as Windows365-A.md below this point:
                    │     Cloud PC VM, Windows 365 agent, Intune enrollment, AVD broker
                    └── Image — app discovery source
                          ├── Gallery image → automatic discovery (M365 Apps preinstalled)
                          └── Custom image → PowerShell Start Menu scan
                                ├── Blocked by: tenant PowerShell auth/execution policy
                                └── Blocked by: unsupported custom image
                          └── APPX/MSIX discovery → requires reprovisioning on pre-existing
                                policies; NOT shown in policy-creation-time image preview
                          └── Autopilot Device Preparation (alternate app source, preview)
                                └── Requires: "Prevent users from connection... on install
                                    failure/timeout" checked on Configuration tab
                    └── App discovered → Ready to publish
                          └── Admin action: Publish → Publishing → Published (or Failed)
                                ├── Failed → Unpublish, then republish (documented fix)
                                ├── Unpublish → reverts to Ready to publish, resets edits
                                └── Edit (name/description/command/icon) → applies immediately
                          └── Published app visible in Windows App to policy-assigned users
                                └── Session concurrency = Flex licenses assigned to THIS policy
                                      (identical to Flex Shared mode — no separate Cloud Apps limit)
                                └── Launched app may spawn any other app on the same Cloud PC
                                      (published or not) — restrict only via App Control (WDAC)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Policy creation fails when setting `userExperienceType = cloudApp` | `provisioningType` isn't `sharedByEntraGroup` — the only valid pairing | Both properties together, not `provisioningType` alone |
| An existing policy shows `cloudApp` with a different `provisioningType` | A pre-validation-era policy, or a manual Graph edit bypassing normal UI validation | Confirm via direct property read; plan a re-create since the type can't be changed in place |
| Zero apps ever appear as "Ready to publish" | Custom image PowerShell discovery scan blocked (tenant PowerShell auth policy) or unsupported image | Image type; tenant Conditional Access/execution-policy restrictions on PowerShell |
| A specific known APPX/MSIX app (e.g., newer Teams) never appears | Policy was created before APPX/MSIX discovery support and has not been reprovisioned | Reprovision history on the policy |
| App shows `Failed` after Publish | Transient publish error, or a Start Menu shortcut/command line changed after discovery | Unpublish/republish; re-verify shortcut validity on the image |
| App or Cloud PC stuck in `Preparing` | Provisioning stall or first-boot discovery scan hang | Bulk reprovision; if unresolved, delete/recreate the policy assignment |
| Autopilot Device Prep succeeds, but no Intune apps show in Cloud Apps | "Prevent users from connection... on install failure/timeout" checkbox not selected on the Configuration tab | Policy Configuration tab setting, independently of Autopilot's own success/failure status |
| Users get "no session available" for a published app | Concurrency ceiling reached — session count equals Flex licenses assigned to this policy | Provisioned Cloud PC count vs. assigned license count (same check as `Flex-B.md` Fix 1/7) |
| A published app opens a second, never-published app and this is reported as a bug | Documented, expected cross-app launch behavior — publish/unpublish controls Windows App visibility only, not runtime app-launch capability | Whether Application Control for Windows (WDAC) is deployed to actually restrict this |
| No "Delete app" action exists | By design — apps are derived from the image, not independently managed objects | Whether the goal is removing the policy assignment or altering the image's Start Menu content |
| Edited app details (name/icon/command) don't seem to apply | Edits apply immediately to Windows App — a stale client cache on the end-user device is more likely than a backend failure | Ask the user to restart Windows App / sign out and back in |
| A ticket references "Frontline Cloud Apps" and nothing matches current documentation | Same Frontline→Flex rename and UI/doc lag as the parent product (see `Flex-A.md`) | Confirm current Flex Shared-mode documentation rather than treating this as a separate legacy feature |

---
## Validation Steps

**1. Confirm Graph connection and required scopes**
```powershell
Connect-MgGraph -Scopes "CloudPC.ReadWrite.All","DeviceManagementConfiguration.Read.All"
Get-MgContext | Select-Object Scopes
```
Expected: Both scopes present.

**2. Confirm the policy's Cloud Apps property pairing**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object DisplayName, UserExperienceType, ProvisioningType, Id
```
Expected: `UserExperienceType = cloudApp` paired with `ProvisioningType = sharedByEntraGroup`. Any other pairing means this is not a valid Cloud Apps policy regardless of what the ticket assumes.

**3. Confirm image type — determines the discovery path to troubleshoot**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'" |
    Select-Object ImageType, ImageId, ImageDisplayName
```
Expected: `gallery` for out-of-box discovery, `custom` for the PowerShell-scan path that has its own distinct failure modes.

**4. Confirm Cloud PC provisioning state**
```powershell
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<policy-name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } | Select-Object DisplayName, Status
```
Expected: At least one Cloud PC in `provisioned` state — app discovery cannot begin before this.

**5. Confirm assignment and license count (concurrency ceiling)**
```powershell
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id
```
Expected: An `sharedByEntraGroup` target with a defined `allotmentLicensesCount` — this number is the hard ceiling on simultaneous active Cloud App sessions for this policy.

**6. Confirm actual per-app publish state (portal only)**
```
Intune admin center → Devices → Windows 365 → All Cloud Apps → filter to the policy's apps.
No Graph/PowerShell surface exists for this state as of this writing.
```
Expected: Apps present with status Ready to publish/Publishing/Published; anything showing Failed needs the unpublish/republish fix.

**7. Confirm end-user assignment**
```powershell
Get-MgGroupMember -GroupId "<backing-group-id>" -All | Select-Object DisplayName, Id
```
Expected: The affected user is a member of the Entra ID group the policy is assigned to — Cloud Apps visibility in Windows App is entirely group-membership-driven.

---
## Troubleshooting Steps (by phase)

### Phase 1: Policy Validity

1. Confirm the policy pairs `userExperienceType = cloudApp` with `provisioningType = sharedByEntraGroup` — any other combination means the ticket is describing a misconfigured or non-Cloud-Apps policy
2. If misconfigured, plan a re-create — neither property can be changed on an existing policy

### Phase 2: Cloud PC Provisioning

1. Confirm at least one Cloud PC under the policy has reached `provisioned` status
2. If stuck in `Preparing`, treat as a standard Shared-mode provisioning stall first (bulk reprovision), escalating to policy-assignment recreation if that doesn't clear it

### Phase 3: App Discovery

1. Determine image type (gallery vs. custom) — this determines which discovery path applies
2. For custom images, check for tenant-level PowerShell execution-policy/authentication restrictions before assuming an unsupported image
3. For APPX/MSIX apps specifically, confirm whether the policy predates that support and needs reprovisioning
4. For Autopilot-Device-Prep-sourced apps, confirm the Configuration tab's "Prevent users from connection... on install failure/timeout" checkbox independently of Autopilot's own reported success

### Phase 4: Publish State

1. Check the app's actual state in All Cloud Apps (portal only)
2. For `Failed`, apply the unpublish/republish fix and re-verify the Start Menu shortcut/command line on the image first
3. Remember Edit changes apply immediately — a user reporting stale details is more likely experiencing a client cache issue than a backend lag

### Phase 5: Access & Concurrency

1. Confirm group membership for the affected user
2. Confirm concurrency ceiling (Flex licenses assigned to this policy) against currently active sessions
3. If a published app launching an unpublished app is the complaint, confirm this is expected behavior before treating it as a fault — only Application Control for Windows (WDAC) can restrict it

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield Cloud Apps Rollout</summary>

Use when: Standing up Cloud Apps for a new user population from scratch.

```powershell
# Step 1: Create the policy with the correct, validated property pairing
$body = @{
    "@odata.type"      = "#microsoft.graph.cloudPcProvisioningPolicy"
    displayName        = "<policy-name>"
    description        = "Cloud Apps — <business justification>"
    userExperienceType = "cloudApp"
    provisioningType   = "sharedByEntraGroup"
    imageType          = "gallery"
    imageId            = "<gallery-image-id-with-required-apps>"
    domainJoinConfigurations = @(
        @{
            "@odata.type"  = "microsoft.graph.cloudPcDomainJoinConfiguration"
            domainJoinType = "azureADJoin"
            regionName     = "<region-or-automatic>"
        }
    )
}
$policy = New-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -BodyParameter $body

# Step 2: Assign to the target Entra ID group with sized license allotment
$assignBody = @{
    assignments = @(
        @{
            target = @{
                "@odata.type"          = "#microsoft.graph.cloudPcManagementGroupAssignmentTarget"
                groupId                = "<entra-group-id>"
                servicePlanId          = "<flex-shared-service-plan-id>"
                allotmentLicensesCount = <peak-concurrent-users>
                allotmentDisplayName   = "<friendly-label>"
            }
        }
    )
}
Invoke-MgBetaAssignDeviceManagementVirtualEndpointProvisioningPolicy -ProvisioningPolicyId $policy.Id -BodyParameter $assignBody

# Step 3: Wait for first Cloud PC to provision, then confirm app discovery in the portal
# (Intune admin center → Devices → Windows 365 → All Cloud Apps — no Graph read for this)

# Step 4: Publish the required apps in the portal, then confirm visibility in Windows App
# for a test user before rolling out to the full group
```

**Rollback:** Remove the policy assignment to stop new provisioning; existing Shared-mode Cloud PCs and their sessions are non-persistent by design so no data-migration concern exists on rollback.

</details>

<details><summary>Playbook 2 — Custom Image App-Discovery Remediation</summary>

Use when: A custom-image-based Cloud Apps policy shows zero or partial apps in "Ready to publish."

```
Step 1: Confirm the tenant does not enforce a restrictive PowerShell execution policy or
        extra authentication requirement that would block the first-boot Start Menu scan
        (check Conditional Access / Endpoint Privilege Management policies scoped to the
        image, if any).

Step 2: Confirm the custom image itself is a supported source for Cloud Apps discovery —
        if unsupported, the only fix is switching to a supported custom image or a gallery
        image and reprovisioning.

Step 3: If APPX/MSIX apps specifically are missing and the policy predates that support,
        bulk reprovision (Intune admin center → Devices → Windows 365 → Provisioning
        policies → select policy → Reprovision) rather than waiting for automatic pickup —
        it will not happen without an explicit reprovision.

Step 4: Confirm results in All Cloud Apps after the reprovision completes.
```

**Rollback:** Reprovisioning wipes local Shared-mode Cloud PC state (already non-persistent unless UES is enabled) — communicate the maintenance window to affected users first.

</details>

<details><summary>Playbook 3 — Failed/Stuck App Recovery</summary>

Use when: One or more apps are stuck `Failed` or `Preparing` and the simple unpublish/republish or reprovision hasn't resolved it.

```
Step 1: Unpublish, then republish the affected app (documented first-line fix for Failed).

Step 2: If still Failed, verify the underlying Start Menu shortcut and any custom command-
        line parameters set via Edit are still valid against the current image — a shortcut
        removed or altered after discovery is a common silent cause.

Step 3: If stuck in Preparing rather than Failed, bulk reprovision the policy first.

Step 4: If reprovisioning does not clear a stuck Preparing state, delete and re-create the
        Cloud Apps policy ASSIGNMENT (not the whole policy) — this is Microsoft's own
        documented second-line fix specifically for this symptom.
```

**Rollback:** Reprovisioning/re-assignment wipes local Shared-mode state by design; no data-loss concern since Shared mode is already non-persistent unless UES is configured.

</details>

<details><summary>Playbook 4 — Restrict Cross-App Launching with Application Control for Windows</summary>

Use when: A client requires that published Cloud Apps cannot spawn other, unpublished applications (e.g., regulatory or security requirement beyond Cloud Apps' own publish/unpublish visibility control).

```
Step 1: Confirm the requirement is genuinely about restricting runtime app-launch
        capability, not just Windows App visibility — Cloud Apps' publish/unpublish
        mechanism already fully controls the latter.

Step 2: Author an Application Control for Windows (WDAC) policy scoped to the image,
        allow-listing only the specific published apps and their legitimate dependencies.

Step 3: Deploy the WDAC policy through Intune to the image/Cloud PCs backing this
        Cloud Apps policy, and reprovision to apply it to already-provisioned Cloud PCs.

Step 4: Test that the previously-observed cross-app launch (e.g., Outlook → Edge) is now
        blocked as expected, and that legitimately required app dependencies still function.
```

**Rollback:** Remove or adjust the WDAC policy assignment; this does not affect Cloud Apps' own publish state or licensing.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Windows 365 Cloud Apps diagnostic evidence for a specific policy
.NOTES     Requires Microsoft.Graph.Beta module and CloudPC.Read.All scope
#>

param(
    [Parameter(Mandatory)][string]$ProvisioningPolicyName
)

$outputPath = "C:\W365CloudApps_Diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '$ProvisioningPolicyName'"
$policy | ConvertTo-Json -Depth 5 | Out-File "$outputPath\policy_detail.json"

Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id } |
    Select-Object DisplayName, Status, ProvisioningType |
    Export-Csv "$outputPath\policy_cloudpcs.csv" -NoTypeInformation

Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id |
    ConvertTo-Json -Depth 5 | Out-File "$outputPath\policy_assignment.json"

Write-Host "NOTE: Per-app publish state (Ready to publish/Publishing/Published/Failed) has no" -ForegroundColor Yellow
Write-Host "Graph/PowerShell surface as of this writing. Capture a screenshot of Intune admin" -ForegroundColor Yellow
Write-Host "center -> Devices -> Windows 365 -> All Cloud Apps filtered to this policy, and" -ForegroundColor Yellow
Write-Host "attach it alongside this evidence pack." -ForegroundColor Yellow

Write-Host "Evidence collected to: $outputPath" -ForegroundColor Green
Compress-Archive -Path "$outputPath\*" -DestinationPath "$outputPath.zip" -Force
Write-Host "Archive: $outputPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Confirm a policy's Cloud Apps property pairing
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<name>'" |
    Select DisplayName,UserExperienceType,ProvisioningType

# List all Cloud Apps policies tenant-wide
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All |
    Where-Object { $_.UserExperienceType -eq 'cloudApp' }

# Confirm image type/source for a policy
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<name>'" |
    Select ImageType,ImageId,ImageDisplayName

# Cloud PCs under a Cloud Apps policy
$policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -Filter "displayName eq '<name>'"
Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All |
    Where-Object { $_.ProvisioningPolicyId -eq $policy.Id }

# Policy assignment / licensed allotment (concurrency ceiling)
Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicyAssignment -ProvisioningPolicyId $policy.Id

# Group membership backing the policy (Cloud Apps visibility is group-driven)
Get-MgGroupMember -GroupId "<group-id>" -All

# Restart (non-destructive) — force-disconnect a stuck Cloud App session
Invoke-MgBetaDeviceManagementVirtualEndpointCloudPcRestart -CloudPcId "<id>"

# NOT available via Graph as of this writing — portal only:
#   - Per-app publish state (Ready to publish/Publishing/Published/Failed)
#   - Publish/Unpublish/Edit/Reset actions themselves
#   - Bulk reprovision with % keep-available
```

---
## 🎓 Learning Pointers

- **Two policy properties, validated as one pair, neither changeable afterward** — `userExperienceType = cloudApp` only works with `provisioningType = sharedByEntraGroup`, and a misconfigured policy has no in-place fix, only re-creation. This is the same "looks like independent settings, is actually one gate" shape this repo has documented repeatedly elsewhere (compare UEBA's three-toggle model and LifecycleWorkflows' `IsEnabled`/`IsSchedulingEnabled` split). Reference: [cloudPcProvisioningPolicy resource type](https://learn.microsoft.com/en-us/graph/api/resources/cloudpcprovisioningpolicy?view=graph-rest-beta)
- **Cloud Apps has no licensing model of its own** — its concurrency ceiling is exactly the Flex Shared-mode license-count math already documented in `Flex-A.md`. Don't go looking for a separate Cloud-Apps-specific throttle or license type; there isn't one. Reference: [Windows 365 Cloud Apps](https://learn.microsoft.com/en-us/windows-365/enterprise/cloud-apps)
- **Publish/Unpublish controls visibility, not runtime capability** — a published app can launch any other app on its Cloud PC regardless of that app's own publish state. Only Application Control for Windows (WDAC) actually restricts this; treating the cross-app launch as a Cloud-Apps bug wastes troubleshooting time. Reference: [Windows 365 Cloud Apps](https://learn.microsoft.com/en-us/windows-365/enterprise/cloud-apps)
- **Two independent, easy-to-conflate silent discovery failures** — PowerShell-execution-policy-blocked custom-image scans and the unchecked Autopilot "Prevent users..." checkbox both present identically ("apps just don't appear"), but require completely different fixes. Confirm which pipeline produced the Cloud PC before choosing a remediation path.
- **APPX/MSIX support arrived after some policies were already built, and it doesn't retroactively apply** — a policy created before that support shipped needs an explicit reprovision, and the policy-creation-time image preview never showed APPX/MSIX apps in the first place, so don't use it to predict what will ultimately publish.
- **No API exists yet for the state technicians most want to check** — the actual Ready to publish/Publishing/Published/Failed status per app is portal-only. Build evidence packs and escalation tickets around a portal screenshot for this specific piece of information rather than assuming a Graph property will eventually surface it.
