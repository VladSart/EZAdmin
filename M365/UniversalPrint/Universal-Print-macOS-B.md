# Universal Print on macOS — Hotfix Runbook (Mode B: Ops)
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

**Scope note:** This covers the native **Universal Print Mac App** (Mac App Store, macOS Sonoma 14.6.1+). It is a separate client from the Windows-native Universal Print experience covered in `Universal-Print-B.md`/`Universal-Print-A.md` — the underlying service, printer registration, and sharing model are shared, but the client-side app, install method, and known issues are entirely macOS-specific.

Run these first to classify the issue:

```
1. Is the Universal Print app even installed on this Mac?
   /Applications/Universal Print.app should exist

2. Is the user signed in to the app?
   System Settings > Universal Print > check sign-in state

3. Has the user actually added the printer via "Add printers" in the app,
   not just expecting it to appear automatically?

4. Is this a "can't find/add printer" problem or a "added it but can't print" problem?

5. Is the printer on the known-problem-model list (certain Brother/Xerox models)?
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| App not in `/Applications` | Never installed | → Fix 1 |
| Signed out, or "Login dialog" keeps popping up | Auth state issue — printing may still work despite showing signed out | → Fix 2 |
| Signed in, but printer never appears in "Add printers" list | License, sharing, or the tenant's macOS Support setting is blocking discovery | → Fix 3 |
| Printer appears and is added, but user can't print to it | Per-user permission not granted, even though printer is visible to everyone on the device | → Fix 4 |
| Job submitted but never completes / times out | Printer model is on the known-issues list, or Document Conversion is off for a non-native format | → Fix 5 |
| macOS is older than Sonoma 14.6.1 | Hard version floor — app will not function | Upgrade macOS; no workaround |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
User prints from any macOS application (Cmd+P)
        │
        ▼
Printer was explicitly ADDED via the Universal Print Mac App's
"Add printers" flow (installed printers show in system print dialog
for ALL users on the device, but must be added at least once)
        │
        ▼
User is SIGNED IN to the Universal Print Mac App with a Microsoft
Entra ID account
        │
        ▼
Universal Print Mac App is INSTALLED (Mac App Store, or provisioned
via MDM/VPP through Apple Business)
        │
        ▼
macOS Sonoma 14.6.1 or later (hard floor — no exceptions)
        │
        ▼
User's Entra ID account holds a Universal Print-eligible license
        │
        ▼
Printer is registered with Universal Print AND shared to this user
or a group they belong to
        │
        ▼
Tenant's "macOS Support" global setting (Azure Portal > Universal
Print > Settings) doesn't hide this printer from macOS clients
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the app is installed and can launch**

```bash
ls -la "/Applications/Universal Print.app" 2>/dev/null && echo "App present" || echo "App NOT installed"
```

If double-clicking the app does nothing and it's not listed under System Settings' sidebar:
```bash
osascript -e 'tell application "Activity Monitor" to activate'
# Manually quit "Universal Print" if listed as a running process, then:
defaults delete com.microsoft.universalprintmac
```
Then relaunch from `/Applications`.

---

**Step 2 — Confirm sign-in state**

System Settings → scroll to the bottom of the sidebar → **Universal Print**. Compare against the signed-in vs. signed-out screenshots in Microsoft's own troubleshooting doc (linked in Learning Pointers) if the state is ambiguous.

Known cosmetic issue: closing and reopening the app can show "not signed in" even though **printing still works in this state**. Don't assume a sign-out broke printing without testing an actual print job first.

---

**Step 3 — Confirm the printer is discoverable**

In the app, click **Add printers** and search by exact name or by location (partial name match is supported). If nothing appears at all:

1. Confirm the user's Entra ID account has a Universal Print-eligible license
2. Confirm the printer is registered and shared to this user or their group (check in Azure Portal → Universal Print → Printer shares if a Windows device isn't available to cross-check)
3. Confirm the tenant's **macOS Support** setting is "Show all printers," not hiding partially supported ones

If SOME printers appear but not the specific one the user wants, permissions are the more likely cause than discovery — the printer shares that ARE visible confirm the app/license/version stack is fine.

---

**Step 4 — Confirm per-user print permission**

Installed printers are visible in the system print dialog for **every user of the Mac**, but jobs are submitted under the currently logged-in user's identity. A print job can fail even though the printer is clearly listed, if that specific user hasn't been granted access to the printer share.

```
# Check share permissions in Azure Portal > Universal Print > Printer shares > [share] > Members
```

---

**Step 5 — Check the known-issues printer list**

Certain Brother DCP/HL/MFC-L-series models and some Xerox color printers are known to fail or abort jobs when connected **directly** to Universal Print from macOS. If the affected printer matches, this is a known limitation, not a misconfiguration — see Fix 5.

---

## Common Fix Paths

<details>
<summary>Fix 1 — App not installed</summary>

**Manual install (requires local admin privileges on the Mac):**
Download from the Mac App Store: `https://aka.ms/UniversalPrint/macOS/app`

**MDM-provisioned install (recommended for fleet deployment):**
1. Confirm an Apple Business (formerly Apple Business Manager) account exists for the organization
2. License the Universal Print app in Apple Business via Volume Purchase (VPP)
3. Deploy via Intune as a VPP app assignment to the target device/user group

No additional Universal Print license is required for the app itself — printing from macOS is included in any Universal Print-eligible license the user already holds.

</details>

<details>
<summary>Fix 2 — Signed out / login dialog popup</summary>

**When:** App shows signed out despite prior successful sign-in, or a login popup appears unexpectedly.

- If printing still works despite showing "signed out" — this is a known cosmetic issue with no workaround yet; no action needed beyond reassuring the user.
- If a login dialog pops up because the user is signed in to multiple tenants in Safari: in Safari, sign out of and "forget" the other accounts. This does **not** affect users authenticating via Platform SSO (Intune-managed sign-in) — that path is unaffected by this Safari-specific issue.
- If genuinely signed out: click Sign In in the app, re-enter the Entra ID account credentials.

</details>

<details>
<summary>Fix 3 — Printer never appears in "Add printers"</summary>

**When:** Signed in successfully, but the target printer never shows up even after searching by name/location.

1. Confirm license: the user's Entra ID account must have a Universal Print-eligible license assigned.
2. Confirm sharing: the printer must be shared with this specific user or a group they're a member of — check Azure Portal → Universal Print → Printer shares.
3. Confirm the tenant-wide **macOS Support** setting: Azure Portal → Universal Print → Settings → set the toggle to **"Show all printers"** if partially supported printers are currently hidden and this is one of them.
4. Cross-check on Windows or directly in Azure Portal if available — if the same user/printer combination also fails to discover there, the problem is sharing/licensing, not the macOS client specifically.
5. If prerequisites all check out and the printer still can't be found, collect logs and escalate (see Escalation Evidence).

</details>

<details>
<summary>Fix 4 — Printer visible, but this user's jobs fail</summary>

**When:** The printer shows in the system print dialog (because it was added once on this device), but this specific user's print jobs fail.

Installed printers display for **all users on the device** — but permission is enforced per-user at print time, not at printer-list time. Grant this user (or their group) explicit permission on the printer share:

```
# Azure Portal > Universal Print > Printer shares > [share] > Members > Add
```

</details>

<details>
<summary>Fix 5 — Job stuck, times out, or the printer is on the known-issues list</summary>

**When:** Job submitted, printer confirmed reachable and shared, but the job aborts or never completes.

1. Check whether the printer model is on Microsoft's known-issues list (specific Brother DCP/HL/MFC-L-series and some Xerox color models) — if so, register the printer via the **Universal Print connector** instead of connecting it directly; this resolves the abort behavior for affected models.
2. If the printer requires Document Conversion (non-native XPS/PDF workflows) and jobs are failing silently, confirm **Document Conversion** is enabled tenant-wide: Azure Portal → Universal Print → Document Conversion.
3. Note: the print job may legitimately not appear in the print queue view even though it IS processing — this is a known cosmetic issue and not itself evidence of failure. Confirm the physical output before assuming the job is stuck.

**Rollback note:** Switching a printer's registration method (direct vs. connector) does not affect existing print history, but does require re-sharing the printer to affected users under its new registration.

</details>

---

## Escalation Evidence

```
=== Universal Print on macOS Escalation Package ===
Date/Time:              ___________
Mac model / macOS version: ___________  (must be Sonoma 14.6.1+)
Universal Print app version: ___________
User UPN:               ___________
Printer name:           ___________
Printer registration method (direct / connector): ___________
Tenant macOS Support setting (Show all / Hide partial): ___________

=== Checks Performed ===
App installed?                Yes / No
Signed in?                     Yes / No
License assigned?              Yes / No
Printer shared to this user?   Yes / No
Printer on known-issues list?  Yes / No

=== Log Collection ===
1. Copy: ~/Library/Group Containers/UBF8T346G9.com.microsoft.universalprintmac/Library/Caches/log.txt
2. Open /Applications/Utilities/Console.app > Start Recording > reproduce issue > Stop > select all, copy, save

=== Error Description ===
- Exact behavior: ___________
- First occurred: ___________
- Affects one user / many users on this Mac / many users on many Macs: ___________
```

---

## 🎓 Learning Pointers

- **This is a genuinely native macOS client, not a workaround.** Since macOS Sonoma, Microsoft ships a real Universal Print Mac App from the Mac App Store — it isn't a Windows-only feature bridged over IPP or a third-party tool. See: [Universal Print on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos)

- **Printers are per-device, jobs are per-user.** Once added, a printer shows in the system dialog for every account on that Mac — but Universal Print still enforces sharing permissions per user at print time. A printer "being there" is not proof a given user can actually print to it. See: [Set up Universal Print on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-setup)

- **The "macOS Support" tenant setting is a real lever, not cosmetic.** Admins can hide partially supported printers from macOS clients entirely to reduce support tickets, at the cost of some printers being unavailable to Mac users who could otherwise print to them with reduced functionality. See: [Configure tenant-wide settings — macOS support](https://learn.microsoft.com/en-us/universal-print/reference/portal/settings#1-macos-support)

- **A handful of specific printer models are known-broken when connected directly — the fix is architectural, not a client-side tweak.** Registering the same printer via the Universal Print connector instead of direct IPP resolves it. Check the known-issues list before spending time on repeated retries. See: [Troubleshooting & Known Issues — Universal Print on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-known-issues)

- **By default, macOS requires admin rights to install or modify ANY printer** (a CUPS policy, not a Universal Print-specific restriction) — this blocks standard users from adding Universal Print printers themselves unless the org deploys a script via MDM that relaxes the `cupsd.conf` policy. See: [Allow non-administrator users to install printers on macOS](https://learn.microsoft.com/en-us/universal-print/macos/universal-print-macos-guide-remove-admin-requirement)

- **iOS is not yet supported** (it's on Microsoft's roadmap, not shipped) — don't troubleshoot an iPhone/iPad as if this same client should be present there.
