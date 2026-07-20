# Universal Print — Agent Instructions

## What's in this folder

Universal Print troubleshooting and reference content for Microsoft's cloud-based print infrastructure. Covers printer registration, Universal Print connector, user/group share assignments, driver deployment via Intune, print job diagnostics, and the native **Universal Print Mac App** (macOS Sonoma 14.6.1+) — a separate client from the Windows-native experience, with its own install paths, per-device-install/per-user-permission split, and known-issue surface.

---

## Before responding, also check

- `M365/_AGENT.md` — general M365 agent context and cross-service dependencies
- `Intune/Troubleshooting/` — if the print issue involves Intune-deployed printer CSP or printer provisioning scripts
- `EntraID/Troubleshooting/` — if users can't authenticate to Universal Print (Entra ID sign-in issues)
- `Windows/_AGENT.md` — if the issue is on the Windows client side (driver, port, queue state)
- `macOS/_AGENT.md` — if the issue is on the macOS client side (Universal Print Mac App, not the Windows client)

---

## Folder contents

| File | What it covers |
|------|---------------|
| `Universal-Print-B.md` | Hotfix runbook — diagnose and resolve print failures in under 10 min; covers connector offline, share assignment gaps, print job stuck (Windows-native client) |
| `Universal-Print-A.md` | Deep dive reference — full architecture, connector internals, driver deployment, Intune printer CSP, job lifecycle (Windows-native client) |
| `Universal-Print-macOS-B.md` | Hotfix runbook — Universal Print Mac App: sign-in/auth-state issues, printer discovery vs. permission split, known-problem printer models |
| `Universal-Print-macOS-A.md` | Deep dive reference — Universal Print Mac App architecture, macOS Support tenant setting, Document Conversion, cupsd.conf admin-requirement removal |
| `Scripts/Get-UniversalPrintReport.ps1` | Graph API script — inventories all printers, shares, connectors, and user/group assignments; exports to CSV |
| `Scripts/Get-UniversalPrintMacOSReadiness.ps1` | Graph API script — per-user license/printer-share readiness check specific to the macOS client; does not check device-local state (app install, sign-in, macOS version) |

---

## Common entry points

- "User can't see the printer" → `Universal-Print-B.md` § Triage — check share assignment for user/group in Entra ID
- "Print job stuck / not printing" → `Universal-Print-B.md` § Common Fix Paths — Fix 2 (clear job queue)
- "Connector offline" → `Universal-Print-B.md` § Triage — check connector service, certificate, network egress
- "How do I deploy printers via Intune?" → `Universal-Print-A.md` § Intune Printer CSP Deployment
- "Printer shows in Windows but fails to print" → `Universal-Print-A.md` § Diagnosis & Validation
- "How does Universal Print work?" → `Universal-Print-A.md` § How It Works
- "Get a report of all printers and who can access them" → `Scripts/Get-UniversalPrintReport.ps1`
- "Mac user can't find/add a printer" → `Universal-Print-macOS-B.md` § Triage — check app install, sign-in state, license, and the tenant's macOS Support setting
- "Printer visible on the Mac but this user's jobs fail" → `Universal-Print-macOS-B.md` Fix 4 — printer visibility is per-device, permission is per-user at print time
- "Specific Brother/Xerox printer aborts jobs from macOS" → `Universal-Print-macOS-A.md` § Symptom → Cause Map — known-issue models; re-register via the connector
- "Standard macOS users can't install printers themselves" → `Universal-Print-macOS-A.md` Playbook 2 — cupsd.conf admin-requirement removal via MDM script
- "Check a Mac user's Universal Print license/share readiness" → `Scripts/Get-UniversalPrintMacOSReadiness.ps1`

---

## Key diagnostic commands

```powershell
# Check Universal Print connector service (run on connector server)
Get-Service "Universal Print Connector" | Select-Object Status, StartType

# View connector logs (Windows Event Log)
Get-WinEvent -LogName "Microsoft-PrintWorkflowService-UniversalPrint/Admin" -MaxEvents 50 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

# List all printers via Graph
Connect-MgGraph -Scopes "Printer.Read.All"
Get-MgPrint -Property printers | Select-Object -ExpandProperty Printers |
    Select-Object DisplayName, Id, IsShared, Status

# List printer shares
Get-MgPrintShare | Select-Object DisplayName, Id, Printer

# Check user's accessible printer shares
$upn = "<UserUPN>"
$user = Get-MgUser -UserId $upn
Get-MgUserPrinter -UserId $user.Id | Select-Object DisplayName, Id

# Get print jobs for a printer
$printerId = "<PrinterObjectId>"
Get-MgPrintPrinterJob -PrinterId $printerId | Select-Object Id, State, CreatedDateTime

# Test connector network egress
Test-NetConnection -ComputerName "print.print.microsoft.com" -Port 443
```

---

## Key dependency chain

```
User prints →
  Windows Universal Print queue →
    Entra ID authentication (user token validated against printer share) →
      Universal Print Service (cloud) →
        Universal Print Connector (on-prem server, if connector-attached printer) →
          On-prem print server / printer
        OR
        Direct IP printer (cloud-native, no connector required)
```

**For Intune-deployed printers:**
```
Intune Policy → Universal Print Printer Provisioning CSP →
  Windows device → Adds printer share to device →
    User prints (no connector required for cloud-native printers)
```

---

## Response format reminder (always 3 layers)

1. **Triage first** — is it connector, share assignment, authentication, or driver?
2. **Fix the specific failure** — use the matching fix path from the B runbook
3. **Confirm resolution** — print test page; verify job completes in Universal Print portal (https://portal.azure.com → Universal Print → Printers → [Printer] → Jobs)

**Portal shortcuts:**
- Universal Print admin: https://portal.azure.com/#blade/Universal_Print/MainMenuBlade/Overview
- Printer share assignments: Portal → Universal Print → Printer shares → [Share] → Members
- Connector health: Portal → Universal Print → Connectors
