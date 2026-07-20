# Universal Print — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Universal Print (UP) architecture and connector model
- Printer registration, sharing, and Entra ID integration
- User and group assignment to shared printers
- Windows 11 / Windows 10 native UP client behaviour
- Universal Print connector (for non-UP-ready printers)
- Intune deployment of UP printers (via Universal Print provisioning policy)
- Print job lifecycle and cloud-spooling
- Common break patterns: connector offline, auth failures, job stuck

**Does not cover:**
- On-premises print servers (Windows Server Print Spooler)
- IPP Everywhere or AirPrint natively (though UP uses IPP internally)
- Third-party print management (PaperCut, Printix, Printix Cloud)
- The native Universal Print Mac App (macOS Sonoma 14.6.1+) — a separate client with its own install paths, per-device-install/per-user-permission model, and known-issue surface — see `Universal-Print-macOS-A.md`/`Universal-Print-macOS-B.md`

**Assumed role:** Global Administrator or Printer Administrator in Entra ID / Universal Print.

**Prerequisites:**
- Microsoft 365 E3/E5, Microsoft 365 Business Premium, or a Universal Print add-on license assigned to the tenant (not per user for Basic — but per printer for the 1 printer/license model in some plans)
- Printers must either support UP natively (IPP-based firmware) or have the Universal Print Connector installed on a Windows server/PC on the same network

---

## How It Works

<details><summary>Full architecture</summary>

### Service Architecture

Universal Print is a **cloud print spooler** hosted in Azure. It replaces the traditional Windows Server print spooler in the cloud-only model.

```
USER DEVICE (Windows 10/11, Entra ID Joined/Registered)
    │
    │  [1] User sends print job via Windows Print Dialog
    │
    ▼
Windows Print System (winspool / IPP client)
    │
    │  [2] Job submitted to Universal Print service via HTTPS (IPP over TLS)
    │      Auth: OAuth 2.0 bearer token (user's Entra ID identity)
    │
    ▼
Microsoft Universal Print Service (Azure)
    │
    │  [3] Job accepted, stored in Azure blob (encrypted at rest)
    │      Job routed to target printer's queue
    │
    ├─ IF NATIVE UP PRINTER:
    │       │
    │       │  [4] Printer polls UP service (HTTPS long-poll every 30s)
    │       │      Auth: Printer's registered certificate / device token
    │       │
    │       ▼
    │   Physical Printer (IPP-Everywhere capable firmware)
    │       Pulls job, prints, reports status back to UP
    │
    └─ IF LEGACY PRINTER (via Connector):
            │
            │  [4] Universal Print Connector (Windows service on local PC/server)
            │      polls UP service, downloads job, submits to local print queue
            │
            ▼
        Windows Machine running UP Connector
            │
            ▼
        Local Print Driver / Shared Printer → Physical Printer
```

### Key Components

**Universal Print Connector:** A Windows application/service installed on any Windows 10/11 or Windows Server machine. It bridges the cloud to printers that lack native UP support. The connector machine must have network access to both the printer AND the internet (Azure endpoints).

**Printer Registration:** Printers are registered into the UP tenant via either the printer's own firmware UI (for native UP printers) or via the UP Connector (for legacy). After registration, printers appear in the Azure Portal under Universal Print.

**Sharing:** Registered printers must be explicitly **shared** and users/groups assigned before they appear in Windows Settings > Printers & Scanners. Sharing ≠ registration — a registered but unshared printer is invisible to end users.

**Intune Integration:** The Universal Print provisioning policy in Intune pushes shared printers to Entra-joined devices automatically. This is the MSP-preferred method — no GPO, no script, no logon script required.

### Print Job Lifecycle (cloud path)

```
1. User prints
2. Windows checks: is this a UP printer? (via PrintConfig in registry)
3. IPP job submitted to UP cloud queue (HTTPS POST to Azure)
4. UP validates user auth and printer assignment (user must be in printer's access list)
5. Job stored in Azure Blob Storage
6. Printer (or Connector) polls for pending jobs
7. Job downloaded and rendered by printer
8. Status (Completed/Error) reported back to UP
9. Job removed from cloud queue
```

Typical end-to-end latency for a native UP printer: **5-20 seconds**. For connector-based printers: **15-45 seconds** depending on connector poll interval.

### Authentication Flow

Users authenticate to UP using their **Entra ID token** (the same token used for M365). This means:
- MFA-required Conditional Access policies can block printing if the UP app is included in the policy scope
- Shared device scenarios (kiosk mode) need special handling — UP is tied to the signed-in user identity
- Guest users cannot print to UP printers without explicit assignment to the printer share

</details>

---

## Dependency Stack

```
Physical Printer
    │
    │  [Native UP: IPP firmware] OR [Legacy: UP Connector on Windows machine]
    │
    ▼
Universal Print Service (Azure)
    │
    ├── Entra ID
    │       ├── User assigned to printer share
    │       ├── Printer registered as service principal
    │       └── OAuth 2.0 token issuance
    │
    ├── Microsoft 365 Licensing
    │       └── UP license assigned to tenant (printer-based for add-on)
    │
    ├── Azure Connectivity
    │       ├── *.print.microsoft.com (HTTPS/443)
    │       ├── login.microsoftonline.com (HTTPS/443 — auth)
    │       └── Azure Blob Storage endpoints (job storage)
    │
    └── End User Windows Device
            ├── Windows 10 21H1+ or Windows 11 (native UP client built-in)
            ├── Entra ID Joined or Hybrid Joined
            └── Up-to-date Windows Update (UP client bugs are patched via WU)
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Printer not visible in Windows Settings | Not shared OR user not in printer access list | Azure Portal → UP → Printer → Shares → Users |
| "You don't have permission to print" | User not assigned to the printer share | UP portal: printer share assignments |
| Jobs submitted but never print (connector path) | UP Connector service offline or unable to reach Azure | Check connector status in UP portal; service on connector machine |
| Jobs submitted but never print (native UP path) | Printer firmware not polling; firewall blocking outbound HTTPS | Test internet from printer; check firewall rules |
| Connector registered but showing "Error" status | Connector machine lost Azure connectivity or token expired | Re-register connector; check proxy/firewall |
| Printer appears but Intune provisioning fails | Intune provisioning policy not targeted correctly | Check Intune device group assignment |
| Job stuck in queue (Windows side) | Windows print spooler issue; or job submission to UP failed | Clear spooler; check UP portal for job status |
| Authentication error when printing | CA policy blocking the Universal Print app | Check CA sign-in logs for UP app ID: `da9b70f6-5323-4ce6-ae5c-88dcc5082966` |
| Printer shows offline in UP portal | Printer powered off, firmware issue, or IP changed | Check physical printer; verify network connectivity |
| Slow printing (connector path) | Connector poll interval; large job size; network to printer | Review connector machine specs; check print driver |

---

## Validation Steps

**1. Verify tenant has Universal Print enabled and licensed**
```powershell
# Via Graph API (requires Global Admin or Printer Admin)
Connect-MgGraph -Scopes "PrinterShare.ReadBasic.All","Printer.Read.All"
$printers = Get-MgPrint
$printers | Select Id, DisplayName, Status
```
If this returns an error about the feature not being available, check tenant licensing in M365 Admin Center.

**2. List registered printers and their status**
```powershell
# Graph: list all printers
$headers = @{Authorization = "Bearer $(Get-MgContext).AccessToken"}
$response = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/print/printers" -OutputType PSObject
$response.value | Select displayName, id, status
```
_Good:_ `status.state = idle` or `processing`  
_Bad:_ `status.state = stopped` or `error`

**3. Verify printer shares and user assignments**
```powershell
# List shares for a printer
$printerId = "<printer-id-from-above>"
Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/print/printers/$printerId/shares" `
    -OutputType PSObject | Select -ExpandProperty value | Select displayName, id
```

**4. Check Connector status in Azure Portal**
- Navigate to: portal.azure.com → Universal Print → Connectors
- Check "Last seen" timestamp — should be within last 5 minutes for an active connector
- Status should be "Online"

**5. Verify user's device has UP printer installed**
```powershell
# Run on the user's device
Get-Printer | Where-Object {$_.Type -eq "Connection"} | Select Name, DriverName, PortName, PrinterStatus
```
_Good:_ Printer listed with `PrinterStatus = Normal`  
_Bad:_ Printer absent — Intune policy not applied, or user not assigned to share

**6. Check Windows UP client registration**
```powershell
# Check if device has UP client active (registry)
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\UniversalPrint" -ErrorAction SilentlyContinue
```

**7. Test UP endpoint connectivity from connector machine**
```powershell
# Run on the Universal Print Connector machine
$endpoints = @(
    "login.microsoftonline.com",
    "apc.print.microsoft.com",  # APAC
    "emea.print.microsoft.com", # EMEA
    "nam.print.microsoft.com"   # North America
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443
    Write-Host "$ep : TcpTestSucceeded=$($result.TcpTestSucceeded)" -ForegroundColor $(if($result.TcpTestSucceeded){"Green"}else{"Red"})
}
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Printer Not Appearing for User

1. Log in to [portal.azure.com](https://portal.azure.com) → Universal Print → Printers
2. Select the printer → Shares → confirm a share exists
3. Select the share → Users and groups → confirm user or user's group is listed
4. If user is missing, add them:
   ```powershell
   # Via Graph API
   $shareId = "<share-id>"
   $userId = "<user-object-id>"
   Invoke-MgGraphRequest -Method POST `
       -Uri "https://graph.microsoft.com/v1.0/print/shares/$shareId/allowedUsers/`$ref" `
       -Body @{
           "@odata.id" = "https://graph.microsoft.com/v1.0/users/$userId"
       } -ContentType "application/json"
   ```
5. On the user's device, go to Settings → Bluetooth & devices → Printers & scanners → "Add a printer or scanner" → the shared printer should now appear
6. If the printer still doesn't appear after 5 minutes, sign out and back into Windows on the device (forces UP client token refresh)

### Phase 2 — Connector Issues

1. Check connector machine: open Services.msc, locate "Universal Print Connector" service — should be Running
2. If stopped: `Start-Service "Universal Print Connector"`
3. Check connector logs: `%ProgramData%\Microsoft\UniversalPrintConnector\Logs\`
4. Common error patterns in logs:
   - `401 Unauthorized` → token expired; re-register the connector
   - `Unable to reach print.microsoft.com` → firewall/proxy blocking outbound HTTPS
   - `Printer not found` → printer IP changed or printer offline
5. Re-register connector if token is stale:
   - Open Universal Print Connector app on the machine
   - Click "Sign out" then "Sign in" with Printer Admin credentials
   - Confirm connector appears Online in Azure Portal within 2 minutes

### Phase 3 — Jobs Submit But Don't Print

1. Check job status in Azure Portal → Universal Print → Printers → [Printer] → Jobs
2. If job shows "Processing" for more than 2 minutes:
   - For native UP: check if printer is polling (printer's embedded web page should show UP status)
   - For connector: check connector service is running; check connector machine can reach the printer
3. If job shows "Error":
   - Note the error code in the portal
   - Common: `clientError.documentFormatNotSupported` → driver/format mismatch; try printing as PDF
   - Common: `printerError.paperJam` / hardware states → physical printer issue
4. Clear and resubmit: cancel the job in the portal or from Windows print queue, then reprint

### Phase 4 — Intune Provisioning Not Installing Printers

1. In Intune Admin Center → Devices → Configuration → [Universal Print Policy] → verify the policy is assigned to the correct device group
2. Confirm devices are Entra ID Joined (not just registered) — Intune UP provisioning requires Entra Join
3. On the device, force policy sync:
   ```powershell
   Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" -MethodName "TriggerSchedule" -Arguments @{sScheduleID="{00000000-0000-0000-0000-000000000021}"} -ErrorAction SilentlyContinue
   # Or simpler: Start-Process "ms-settings:workplace" then click Sync
   # Or via Intune Company Portal: Settings > Sync
   ```
4. Check Event Viewer: `Applications and Services Logs → Microsoft → Windows → PrintService → Operational`
5. Look for event ID 300-399 (Universal Print provisioning events)

### Phase 5 — Authentication / CA Policy Blocks

1. In Entra ID → Sign-in logs, filter by Application: "Universal Print" (App ID: `da9b70f6-5323-4ce6-ae5c-88dcc5082966`)
2. Look for failures with Conditional Access as the reason
3. If a CA policy requiring compliant device or MFA is blocking UP:
   - Option A: Add the UP application as an exclusion from that specific CA policy
   - Option B: Ensure device compliance policy allows the print action (usually compliant devices pass without MFA prompt for UP)
   - Option C: Create a named location exclusion for the connector machine's IP (for connector auth scenarios)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Register a legacy printer via Connector</summary>

**On the connector machine (Windows 10/11 or Windows Server):**

1. Download Universal Print Connector from aka.ms/UPConnector
2. Install and launch the application
3. Sign in with a Printer Administrator or Global Admin account
4. The connector registers itself with the UP service automatically
5. In the "Printers" tab of the connector app, click "Add a printer"
6. Select printers visible on the local network / listed in Windows
7. Each printer added here gets registered in the UP portal

**Verify in Azure Portal:**
```
Universal Print → Printers → [new printer should appear]
Then: Universal Print → Connectors → [connector should show Online]
```

</details>

<details><summary>Playbook 2 — Share a printer and assign users via Graph PowerShell</summary>

```powershell
Connect-MgGraph -Scopes "PrinterShare.ReadWrite.All","Printer.ReadWrite.All","User.Read.All","Group.Read.All"

# Get printer ID
$printers = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/print/printers" -OutputType PSObject
$printer = $printers.value | Where-Object {$_.displayName -like "*<PrinterName>*"}
$printerId = $printer.id

# Create a share
$shareBody = @{
    displayName = "<ShareDisplayName>"
    printer     = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/print/printers/$printerId" }
} | ConvertTo-Json

$share = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/print/shares" -Body $shareBody -ContentType "application/json" -OutputType PSObject
$shareId = $share.id
Write-Host "Share created: $shareId"

# Assign a group
$groupId = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '<GroupName>'" -OutputType PSObject).value[0].id

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/print/shares/$shareId/allowedGroups/`$ref" `
    -Body (@{"@odata.id" = "https://graph.microsoft.com/v1.0/groups/$groupId"} | ConvertTo-Json) `
    -ContentType "application/json"

Write-Host "Group assigned to printer share." -ForegroundColor Green
```

</details>

<details><summary>Playbook 3 — Deploy printer to devices via Intune</summary>

1. In Intune Admin Center: Devices → Configuration → Create → New Policy
2. Platform: **Windows 10 and later**; Profile type: **Templates** → **Universal Print**
3. Give the policy a name, then click Configure
4. Under "Printers", search for and select the shared printer(s) to deploy
5. Set one as the **default printer** if desired
6. Assign the policy to an Entra ID device group (Dynamic or Static)
7. Save. Devices in the group will receive the printer at next policy check-in (30-60 min, or force sync)

**Verify deployment on device:**
```powershell
# On managed device after policy applies
Get-Printer | Where-Object {$_.Name -like "*<PrinterShareName>*"}
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collect Universal Print diagnostic evidence for escalation.
.NOTES Requires Graph PowerShell and Printer Administrator role.
       Run interactively — will prompt for auth.
#>
param(
    [string]$OutputPath = "$env:TEMP\UP-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
)

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Connect-MgGraph -Scopes "Printer.Read.All","PrinterShare.ReadBasic.All","PrintJob.Read.All"

# List all printers and status
$printers = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/print/printers?`$select=id,displayName,status,isShared" -OutputType PSObject
$printers.value | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\printers.json"
$printers.value | Select displayName, id, @{N='State';E={$_.status.state}}, isShared | Export-Csv "$OutputPath\printers-summary.csv" -NoTypeInformation

# List connectors
$connectors = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/print/connectors" -OutputType PSObject
$connectors.value | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\connectors.json"

# List shares
$shares = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/print/shares" -OutputType PSObject
$shares.value | ConvertTo-Json -Depth 5 | Out-File "$OutputPath\shares.json"

# Connectivity test (run on connector machine if available)
$endpoints = @("login.microsoftonline.com","nam.print.microsoft.com","emea.print.microsoft.com","apc.print.microsoft.com")
$connResults = foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{Endpoint=$ep; Reachable=$r.TcpTestSucceeded; LatencyMs=$r.PingReplyDetails.RoundtripTime}
}
$connResults | Export-Csv "$OutputPath\connectivity.csv" -NoTypeInformation

Write-Host "Evidence saved to: $OutputPath" -ForegroundColor Green
Invoke-Item $OutputPath
```

---

## Command Cheat Sheet

| Task | Method |
|------|--------|
| List all registered printers | Graph: `GET /v1.0/print/printers` |
| List all connectors | Graph: `GET /v1.0/print/connectors` |
| List all shares | Graph: `GET /v1.0/print/shares` |
| Get printer status | Graph: `GET /v1.0/print/printers/{id}` → `.status.state` |
| List users assigned to share | Graph: `GET /v1.0/print/shares/{id}/allowedUsers` |
| Add user to share | Graph: `POST /v1.0/print/shares/{id}/allowedUsers/$ref` |
| Add group to share | Graph: `POST /v1.0/print/shares/{id}/allowedGroups/$ref` |
| List pending jobs | Graph: `GET /v1.0/print/printers/{id}/jobs?$filter=status/state ne 'completed'` |
| Cancel a job | Graph: `POST /v1.0/print/printers/{id}/jobs/{jobId}/cancel` |
| Check connector machine connectivity | PowerShell: `Test-NetConnection -ComputerName nam.print.microsoft.com -Port 443` |
| Restart connector service | `Restart-Service "Universal Print Connector"` |
| Force Intune policy sync | `Start-Process "ms-settings:workplace"` → Sync |
| View UP events on device | Event Viewer: `Microsoft\Windows\PrintService\Operational` |

---

## 🎓 Learning Pointers

- **Universal Print uses IPP (Internet Printing Protocol) over HTTPS.** All print jobs travel as HTTPS POSTs to Azure endpoints. This is why firewall rules matter — outbound 443 to `*.print.microsoft.com` must be permitted from both the connector machine and native UP printers. If you have SSL inspection (deep packet inspection) on outbound HTTPS, you must add UP endpoints to the inspection bypass list or jobs will fail silently. [MS Docs — UP Firewall Requirements](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-whitelisting)

- **Sharing is not registration.** A printer registered in UP is invisible to users until it is explicitly shared AND users/groups are assigned to that share. This is a two-step process that trips up many first-time UP deployments. Always verify both steps.

- **The Connector machine is a single point of failure for legacy printers.** If the connector machine goes offline, reboots, or loses internet, all printers behind it stop printing. For production deployments, run the connector on a server (not a user workstation), configure it as a Windows service set to auto-restart, and monitor the connector status in the UP portal. [MS Docs — UP Connector Setup](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-installation)

- **Intune provisioning requires Entra ID Join, not just registration.** Workplace-registered (BYOD) devices cannot receive UP printers via Intune provisioning policy. Only Entra Joined (corporate, cloud-native) and Hybrid Entra Joined devices are eligible. If a user reports Intune is not deploying their printer, check the device join type first: `dsregcmd /status | findstr "AzureAd"`.

- **Conditional Access can silently block printing.** The Universal Print app ID (`da9b70f6-5323-4ce6-ae5c-88dcc5082966`) can be targeted by CA policies. If a CA policy requires MFA and the user is on a compliant device but the token expires mid-session, the next print job may fail with an auth error. Check Entra sign-in logs filtered by the UP App ID whenever you see unexplained print failures after a CA policy change. [MS Docs — UP and Conditional Access](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-security)

- **Print job data is encrypted in Azure Blob Storage but jobs are ephemeral.** Print jobs are stored temporarily in Azure Blob Storage during the cloud-spooling phase. They are deleted as soon as the printer confirms completion (or after a configurable retention period). This means there is no cloud-side "reprint" — if a job is delivered but the printer jams, the user must reprint from their application. Design this into your user training.
