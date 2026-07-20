# Universal Print on macOS — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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

This covers the **native Universal Print Mac App** — Microsoft's Mac App Store client that lets macOS users discover, install, and print to Universal Print printers from any application, without drivers or manually entered IP addresses. It is architecturally a sibling to, not a variant of, the Windows-native client covered in `Universal-Print-A.md`.

**Covers:**
- The Universal Print Mac App's architecture, install paths (manual vs. MDM/VPP), and sign-in model
- macOS version floor (Sonoma 14.6.1+) and why this is a hard, non-negotiable gate
- The per-device-install / per-user-permission split and how it produces "printer is there but this user still can't print" tickets
- The tenant-wide **macOS Support** setting and **Document Conversion** feature as they apply specifically to macOS clients
- The macOS default admin-required-to-install-printers restriction (a CUPS policy) and the supported MDM remediation
- Known issues and specific known-broken printer models as of the current Microsoft documentation

**Does not cover:**
- Windows-native Universal Print client behaviour, connector architecture, or Intune provisioning-policy deployment of printers to Windows devices — see `Universal-Print-A.md`/`Universal-Print-B.md`
- On-premises print servers, IPP Everywhere/AirPrint used independently of Universal Print, or third-party print management (PaperCut, Printix) — see `Universal-Print-A.md`'s own Scope & Assumptions
- iOS/iPadOS — not yet supported by Universal Print at all (roadmap item, not shipped)

**Assumed role:** Intune/Apple Business administrator for MDM-based deployment; Universal Print Administrator or Printer Administrator in Entra ID/Azure Portal for tenant-level settings.

**Prerequisites:**
- macOS **Sonoma 14.6.1 or later** — a hard floor with no exceptions or workarounds
- Entra ID account with a Universal Print-eligible license
- The tenant's Universal Print application enabled
- At least one printer registered with Universal Print and shared to the user or a group they belong to
- The tenant's **macOS Support** global setting configured to show the printers in question

---

## How It Works

<details><summary>Full architecture</summary>

**The client is a real, first-party macOS app — not a bridge.** Since its General Availability, Universal Print on macOS ships as a dedicated Mac App Store application (`Universal Print.app`), distinct from the Windows-native experience and from generic IPP/AirPrint printing. It is built on the same underlying IPP/Mopria-based Universal Print service used by Windows, but the client itself, its install path, and its known-issue surface are entirely macOS-specific.

```
┌────────────────────────────┐   Entra ID sign-in   ┌──────────────────────────┐
│  Universal Print Mac App     │◄────────────────────►│  Microsoft Entra ID       │
│  (Mac App Store)             │                       │                          │
└────────────────────────────┘                       └──────────────────────────┘
        │  discover/install printers
        ▼
┌────────────────────────────┐    IPP/Mopria print    ┌──────────────────────────┐
│  System print dialog          │──────────────────────►│  Universal Print service  │
│  (Cmd+P from any app)         │                       │  (cloud)                 │
└────────────────────────────┘                       └──────────┬───────────────┘
                                                                  │
                                                    ┌─────────────┴─────────────┐
                                                    ▼                           ▼
                                        Direct IPP-ready printer      Universal Print Connector
                                        (registered directly)         (on-prem bridge, for
                                                                       non-UP-ready or known-
                                                                       problematic-model printers)
```

**Install paths.** Two supported routes:
1. **Manual** — a user with local administrator privileges downloads the app directly from the Mac App Store.
2. **MDM-provisioned** — the organization licenses the Universal Print app in Apple Business (formerly Apple Business Manager) via Volume Purchase, then deploys it through Intune (or another linked MDM) as a standard VPP app assignment. Regardless of install path, **users must still sign in and select their own printers manually** — Microsoft has stated system-wide SSO and automatic printer provisioning are planned but not yet available, so MDM deployment only solves distribution, not sign-in or printer selection.

**Sign-in and licensing.** No additional license is required beyond whatever Universal Print-eligible license the user's Entra ID account already holds — macOS printing is included, not a separate SKU or add-on. The app requests sign-in via a standard Entra ID authentication flow; a known cosmetic defect can show "not signed in" after closing and reopening the app even though the underlying session and printing both still function correctly.

**The per-device-install, per-user-permission split — the architectural fact that explains most real tickets.** Once a printer is added via "Add printers," it becomes visible in the macOS system print dialog for **every account on that Mac**, not just the user who added it. However, Universal Print's own sharing/permission model is still enforced **per user at print time** — a print job submitted by a user who lacks permission on that printer share will fail, even though the printer appears fully installed and selectable. This produces the single most common macOS-specific support pattern: "the printer is right there, why won't it print for me" on a shared or multi-user Mac.

**The "macOS Support" tenant setting.** Because not every Universal Print-compatible printer implements the full feature set macOS's client expects (some finishing options, page flipping, and detailed status indicators like toner level may be unavailable), Microsoft exposes a tenant-wide toggle (Azure Portal → Universal Print → Settings) letting administrators choose between showing all printers to macOS clients or hiding "partially supported" ones. This is a genuine administrative trade-off — hiding partial-support printers reduces functionality-gap tickets at the cost of making some otherwise-usable printers invisible to Mac users entirely. The companion reference (`up-macos-supported-printers`) documents per-model support tiers for exactly this decision.

**Document Conversion's role for non-native formats.** Universal Print's cloud service can convert between XPS and PDF automatically via the tenant-wide Document Conversion feature. Native XPS printing works without conversion; PDF, URF, and octet-stream content require Document Conversion to be enabled or the print job fails outright. This is a tenant-wide toggle, not macOS-specific, but interacts with macOS printing because many macOS applications render print content as PDF by default.

**The macOS admin-to-install-printers default, and its Universal Print-specific fix.** By default, macOS requires the logged-in user to be an administrator to install, delete, or modify ANY printer — a `cupsd.conf` access-control policy (`CUPS-Add-Modify-Printer` gated behind `@SYSTEM`), not something Universal Print introduces. For standard (non-admin) users to add Universal Print printers themselves, an MDM-deployed script must move the `CUPS-Add-Modify-Printer` operation out of the `@SYSTEM`-gated `<Limit>` block into the ungated default-access block in `cupsd.conf`. This is a real, supported, Microsoft-documented remediation — not an unsupported system hack — but it is a system-wide change to print policy, not scoped to Universal Print printers specifically.

**Known, model-specific breakage.** A defined list of Brother DCP/HL/MFC-L-series printers and some Xerox color printers are documented as failing or aborting jobs specifically when connected **directly** to Universal Print from macOS. Registering the same physical printer via the **Universal Print connector** instead resolves this — the connector mediates the print protocol translation in a way the direct macOS-to-cloud-to-printer path does not for these specific firmware implementations.

</details>

---

## Dependency Stack

```
Layer 5 — Print job
  User prints from any macOS application (Cmd+P → system dialog → selected printer)
        ▲
Layer 4 — Per-user permission (enforced at print time, independent of visibility)
  User or their group has been granted access on the printer share
        ▲
Layer 3 — Printer added to this device
  User ran "Add printers" in the app at least once
  (installed printers then show for ALL users of the device)
        ▲
Layer 2 — App sign-in and licensing
  Signed in with an Entra ID account holding a Universal Print-eligible license
        ▲
Layer 1 — Client and platform prerequisites
  Universal Print Mac App installed (manual or MDM/VPP)
  macOS Sonoma 14.6.1+ (hard floor)
        ▲
Layer 0 — Tenant-level configuration (shared with Windows, but macOS-gated separately)
  Universal Print application enabled · printer registered · printer shared to
  user/group · tenant "macOS Support" setting not hiding this printer ·
  Document Conversion enabled if non-native format printing is required
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Double-clicking the app does nothing | Stale app state/process | Quit via Activity Monitor, `defaults delete com.microsoft.universalprintmac`, relaunch |
| App shows "not signed in" after reopening | Known cosmetic auth-state-reset defect | Test an actual print job before assuming printing is broken |
| Unexpected login popup while using the app | Multiple Entra tenants signed in via Safari | Sign out/forget other accounts in Safari; doesn't affect Platform SSO/Intune users |
| No printers appear at all in "Add printers" | Missing license, no sharing, or app not enabled tenant-wide | Confirm license, printer share membership, and app-enablement setting |
| Some printers appear, but not the specific one wanted | Sharing/permission gap for that specific printer, not a discovery problem | Check that printer's specific share membership |
| Printer visible and added, but this user's jobs fail | Per-user share permission not granted (printer visibility ≠ permission) | Add user/group to the printer share's Members |
| Print jobs never show in the print queue view | Known cosmetic issue — job is likely still processing | Confirm actual physical output before treating as stuck |
| Job aborts or times out on a specific printer model | Printer is on the known-issues list (certain Brother/Xerox models) for direct connections | Re-register the printer via the Universal Print connector |
| PDF/URF jobs fail, XPS jobs succeed | Document Conversion disabled tenant-wide | Enable Document Conversion in Azure Portal → Universal Print |
| Standard (non-admin) users can't add printers themselves | macOS's default admin-required cupsd.conf policy — not Universal Print-specific | Deploy the documented cupsd.conf remediation script via MDM |
| Some printers missing only for macOS users, present for Windows users on the same share | Tenant's macOS Support setting is hiding partially supported printers | Azure Portal → Universal Print → Settings → macOS Support toggle |
| A color Xerox printer can't print in color from macOS specifically | Documented Xerox-specific color limitation on Universal Print for macOS | Confirm against the known-issues list; contact Xerox for updates per Microsoft's own guidance |
| Everything works on one Mac but not another for the same user | Printer was never added on the second Mac — install/add is per-device | Have the user (or MDM) run "Add printers" on the affected device |

---

## Validation Steps

1. **Confirm macOS version meets the floor.** `sw_vers -productVersion` on the affected Mac. Good: 14.6.1 or later. Bad: anything earlier — no workaround exists, the app will not function correctly.

2. **Confirm the app is installed and its version.** Check `/Applications/Universal Print.app` exists; compare against the latest App Store version if troubleshooting a known-issue that may already be fixed in a newer release.

3. **Confirm sign-in state matches actual printing capability**, not just the UI indicator — given the known auth-state-reset cosmetic defect, always validate with an actual test print rather than trusting the sign-in indicator alone.

4. **Confirm license assignment.** The affected user's Entra ID account must carry a Universal Print-eligible license (see Microsoft's list of qualifying subscriptions). Good: license present. Bad: absent — no printer will ever be discoverable regardless of every other setting being correct.

5. **Confirm printer share membership** for the specific user (not just "a" user in the org) via Azure Portal → Universal Print → Printer shares → [share] → Members.

6. **Confirm the tenant's macOS Support setting** isn't hiding the specific printer in question if it's classified as partially supported.

7. **Confirm Document Conversion state** if the failure is specific to PDF/URF/octet-stream content rather than XPS.

8. **Cross-check on Windows or Azure Portal directly** whenever a Mac-only discovery/permission issue is suspected — if the same gap reproduces there too, it's a tenant/sharing configuration issue, not a macOS client defect.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Platform and app health**
Confirm macOS version floor and app presence/launchability before anything else — these are absolute gates with zero workaround if unmet.

**Phase 2 — Identity and licensing**
Confirm sign-in (validated by an actual print test, not just the UI) and license assignment. A missing license produces the same "no printers found" symptom as a sharing gap, so check both rather than assuming.

**Phase 3 — Discovery vs. permission disambiguation**
Determine whether the printer is failing to *appear* (a discovery-layer problem: license, sharing, macOS Support setting) or *appearing but failing to print* (a permission-layer problem: per-user share membership). These have different fixes and it's easy to conflate them because both present as "can't print."

**Phase 4 — Format and model-specific checks**
For jobs that submit successfully but fail downstream, check Document Conversion state (format-specific) and the known-issues printer-model list (hardware-specific) before assuming a generic connectivity problem.

**Phase 5 — Fleet-wide configuration checks**
If multiple users/Macs are affected identically, check tenant-wide settings (macOS Support toggle, Document Conversion, app enablement) rather than continuing to debug individual devices.

**Phase 6 — Escalate**
Collect the device-local log (`~/Library/Group Containers/UBF8T346G9.com.microsoft.universalprintmac/Library/Caches/log.txt`) plus a Console.app recording spanning the reproduction, and escalate with the Evidence Pack below if all of the above are ruled out.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Deploy the Universal Print Mac App fleet-wide via MDM</summary>

1. Confirm an Apple Business (formerly Apple Business Manager) account exists and is linked to the MDM (Intune or other).
2. License the Universal Print app in Apple Business via Volume Purchase (VPP).
3. In Intune, deploy the app as a VPP-licensed macOS app assignment to the target device or user group.
4. After deployment, communicate to end users that they must still **manually sign in and select their own printers** — MDM deployment solves distribution only, not sign-in or printer selection, since system-wide SSO/auto-provisioning isn't yet available.
5. If standard (non-admin) users need to add printers themselves, pair this with Playbook 2 below.

**Rollback note:** Removing the VPP app assignment uninstalls the app on next MDM sync but does not remove printers already added to affected devices; those persist as ordinary macOS printer queues until manually removed.

</details>

<details>
<summary>Playbook 2 — Allow non-administrator users to add/modify printers</summary>

1. Deploy an MDM script (Intune shell script) that edits `/etc/cups/cupsd.conf`:
   - In the `<Policy default>` block's `<Limit Create-Job Print-Job Print-URI Validate-Job CUPS-Add-Modify-Printer>` section, remove any `Require` clause so it uses the default, ungated access group.
   - In the block that lists `CUPS-Add-Modify-Printer` alongside `CUPS-Delete-Printer`/`CUPS-Add-Modify-Class`/etc. under `Require user @SYSTEM`, remove `CUPS-Add-Modify-Printer` from that gated list.
2. Restart the `cupsd` service (or have the device reboot) for the policy change to take effect.
3. Validate with a genuinely non-admin test account that it can now run "Add printers" successfully.

**Rollback note:** This is a system-wide print-policy change, not scoped to Universal Print specifically — reverting requires redeploying the original, unmodified `cupsd.conf` (Microsoft's documentation includes the original file for exactly this purpose).

</details>

<details>
<summary>Playbook 3 — Move a known-problematic printer to connector-based registration</summary>

1. Confirm the affected printer model against Microsoft's known-issues list (specific Brother DCP/HL/MFC-L-series and some Xerox color models as of current documentation — verify against the live list, as it is actively maintained).
2. Set up the Universal Print connector on a Windows server/PC on the same network as the printer, if not already present.
3. Re-register the printer through the connector rather than direct IPP registration.
4. Re-share the printer to the same users/groups under its new registration — sharing does not automatically carry over between direct and connector-based registrations of the "same" physical printer, since Universal Print treats them as distinct printer objects.

**Rollback note:** The original direct-registered printer object can be left in place or deleted; keeping both temporarily lets you validate the connector-based version before fully cutting over.

</details>

---

## Evidence Pack

```powershell
<#
Collects tenant-side Universal Print evidence relevant to a macOS-specific issue.
Device-local logs (Console.app recording, the app's own log.txt) must be collected
separately per this runbook's Escalation Evidence section — this script only covers
what's queryable via Microsoft Graph.

Requires: Microsoft.Graph.Print module (or equivalent Graph SDK cmdlets)
Connect-MgGraph -Scopes "Printer.Read.All","PrintSettings.Read.All"
#>

param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [string]$PrinterNameFilter
)

Connect-MgGraph -Scopes "Printer.Read.All","PrintSettings.Read.All","User.Read.All" -NoWelcome

Write-Host "=== User license check ===" -ForegroundColor Cyan
$user = Get-MgUser -UserId $UserPrincipalName -Property AssignedLicenses,DisplayName
Write-Host "User: $($user.DisplayName) — assigned license count: $($user.AssignedLicenses.Count)"
Write-Host "(Cross-check assigned SKUs against the Universal Print-eligible subscription list manually.)"

Write-Host "`n=== Printers matching filter (if provided) ===" -ForegroundColor Cyan
$printers = Get-MgPrinter -All
if ($PrinterNameFilter) {
    $printers = $printers | Where-Object { $_.DisplayName -like "*$PrinterNameFilter*" }
}
$printers | Select-Object DisplayName, Id, IsShared, ManufacturerAndModel |
    Format-Table -AutoSize

Write-Host "`n=== Printer shares and this user's membership ===" -ForegroundColor Cyan
foreach ($p in $printers) {
    try {
        $shares = Get-MgPrintShare -Filter "printer/id eq '$($p.Id)'" -ExpandProperty "allowedUsers"
        foreach ($share in $shares) {
            $isMember = $share.AllowedUsers.Id -contains $user.Id
            Write-Host "Printer: $($p.DisplayName)  Share: $($share.DisplayName)  UserHasAccess: $isMember"
        }
    } catch {
        Write-Host "Could not resolve shares for $($p.DisplayName): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "`nReminder — manual checks still required:" -ForegroundColor Yellow
Write-Host "  - Azure Portal > Universal Print > Settings > macOS Support toggle"
Write-Host "  - Azure Portal > Universal Print > Document Conversion state"
Write-Host "  - Device-local log: ~/Library/Group Containers/UBF8T346G9.com.microsoft.universalprintmac/Library/Caches/log.txt"
Write-Host "  - macOS version via sw_vers -productVersion (must be 14.6.1+)"
```

---

## Command Cheat Sheet

| Command / Location | Purpose |
|---|---|
| `sw_vers -productVersion` | Confirm macOS meets the Sonoma 14.6.1+ floor |
| `ls "/Applications/Universal Print.app"` | Confirm the app is installed |
| `defaults delete com.microsoft.universalprintmac` | Reset app preferences when the app won't launch |
| `~/Library/Group Containers/UBF8T346G9.com.microsoft.universalprintmac/Library/Caches/log.txt` | App's own log file for escalation |
| Azure Portal → Universal Print → Settings → macOS Support | Show all vs. hide partially supported printers for macOS clients |
| Azure Portal → Universal Print → Document Conversion | Enable/check XPS↔PDF conversion for non-native format printing |
| Azure Portal → Universal Print → Printer shares → [share] → Members | Check/grant per-user print permission |
| `Get-MgPrinter -All` | List all Universal Print printers via Graph |
| `Get-MgPrintShare` | List printer shares and membership via Graph |
| MDM script editing `/etc/cups/cupsd.conf` | Remove admin requirement for installing/modifying printers |

---

## 🎓 Learning Pointers

- **The macOS client is genuinely native, built on the same IPP/Mopria foundation Universal Print already used** — this isn't a bolt-on or a third-party bridge, and treating it with the same rigor as the Windows client (rather than as an afterthought) will resolve tickets faster. See: [Discover Universal Print](https://learn.microsoft.com/en-us/universal-print/discover-universal-print)

- **"The printer is visible" and "this user can print to it" are two separate claims** — visibility is per-device, permission is per-user-at-print-time. This is the single most valuable mental model for triaging macOS Universal Print tickets on shared or multi-user Macs. See: [Set up Universal Print on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-setup)

- **The admin-required-to-install-printers behavior is a macOS/CUPS default, not something Microsoft added** — but Microsoft does document and support a specific remediation script, which is worth deploying proactively for any fleet expecting standard users to self-service printer installs. See: [Allow non-administrator users to install printers on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-guide-remove-admin-requirement)

- **Known-issue printer models aren't edge cases to work around per-ticket — fix them structurally** by moving them to connector-based registration once, rather than repeatedly troubleshooting the same direct-connection failure. See: [Troubleshooting & Known Issues — Universal Print on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-known-issues)

- **The macOS Support tenant toggle is a real policy decision with a real trade-off**, not a checkbox to leave at default — walk through the supported-printer list with the org before deciding whether to hide partially supported printers. See: [Universal Print on macOS — Supported Printer List](https://learn.microsoft.com/en-us/universal-print/macos/up-macos-supported-printers)

- **iOS support is roadmap-only as of current documentation** — don't extrapolate macOS behavior onto iPhone/iPad tickets; there is currently no equivalent client.
