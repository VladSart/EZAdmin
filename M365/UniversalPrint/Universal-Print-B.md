# Universal Print — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer.

```powershell
# 1. Check Universal Print connector service on the connector host
Get-Service -Name "UPConnectorSvc" -ComputerName <ConnectorHostname>

# 2. Check connector registration status in Azure
Connect-MgGraph -Scopes "PrinterShare.ReadWrite.All","Printer.ReadWrite.All"
Get-MgPrintConnector | Select-Object DisplayName, RegisteredDateTime, IsAcceptingJobs

# 3. Check printer share status
Get-MgPrintPrinterShare | Select-Object DisplayName, IsAcceptingJobs, AllowAllUsers | Format-Table

# 4. Check user licence (M365 Business Premium, E3+, or Microsoft 365 F3 required)
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber

# 5. Confirm printer connector host has outbound HTTPS to *.print.microsoft.com
Test-NetConnection -ComputerName "print.microsoft.com" -Port 443
```

| Result | Action |
|--------|--------|
| `UPConnectorSvc` Stopped | → Fix 1: Restart connector service |
| Connector shows `IsAcceptingJobs: False` | → Fix 2: Re-register connector |
| Printer share `IsAcceptingJobs: False` | → Fix 3: Release printer share |
| User missing `MICROSOFT_365_*` or `SPB` SKU | → Fix 4: Assign licence |
| `Test-NetConnection` TcpTestSucceeded: False | → Fix 5: Firewall/proxy block |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Internet: *.print.microsoft.com :443]
         |
[Connector Host (Windows Server/10/11)]
  └─ UPConnectorSvc running
  └─ Entra ID registered (device)
  └─ Outbound HTTPS not proxied/blocked
         |
[Universal Print Connector (registered)]
  └─ Connector <-> printer driver installed
  └─ Local printer queue healthy
         |
[Universal Print Service (Azure)]
  └─ Printer object registered
  └─ Printer Share created
  └─ Users/groups assigned to share
         |
[End User]
  └─ Valid licence (M365 Business Premium / E3 / F3)
  └─ Printer share assigned (direct or via group)
  └─ Windows 10 21H1+ or Windows 11
```

</details>

---
## Diagnosis & Validation Flow

**1. Verify connector host connectivity**
```powershell
Test-NetConnection -ComputerName "print.microsoft.com" -Port 443
Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
```
Expected: `TcpTestSucceeded: True` for both. If False → proxy/firewall issue (Fix 5).

**2. Check connector service state**
```powershell
Get-Service -Name "UPConnectorSvc" | Select-Object Status, StartType
```
Expected: `Status: Running`, `StartType: Automatic`. If Stopped → Fix 1.

**3. Validate connector is registered and active**
```powershell
Connect-MgGraph -Scopes "Printer.Read.All"
Get-MgPrintConnector | Select-Object Id, DisplayName, RegisteredDateTime, IsAcceptingJobs
```
Expected: `IsAcceptingJobs: True`. If False or connector missing → Fix 2.

**4. Check printer share assignment**
```powershell
$share = Get-MgPrintPrinterShare -Filter "displayName eq '<ShareName>'"
Get-MgPrintPrinterShareAllowedGroup -PrinterShareId $share.Id
Get-MgPrintPrinterShareAllowedUser -PrinterShareId $share.Id
```
Expected: User or their group appears in allowed list. If missing → Fix 3.

**5. Verify user licence**
```powershell
Get-MgUserLicenseDetail -UserId <UPN> | Where-Object { $_.SkuPartNumber -match "SPB|ENTERPRISEPACK|M365" }
```
Expected: At least one qualifying SKU. None → Fix 4.

**6. Test print job submission**
```powershell
# On the client — list Universal Print queues
Get-Printer | Where-Object { $_.PortName -like "*UniversalPrint*" }
```
Expected: Printer listed. If absent, user needs to add it via Settings → Bluetooth & devices → Printers.

---
## Common Fix Paths

<details><summary>Fix 1 — Restart Universal Print Connector service</summary>

Use when: `UPConnectorSvc` is stopped or in an error state.

```powershell
# Run on the connector host
Restart-Service -Name "UPConnectorSvc" -Force
Start-Sleep -Seconds 10
Get-Service -Name "UPConnectorSvc"

# If service fails to start, check event log
Get-WinEvent -LogName "Application" -MaxEvents 20 |
    Where-Object { $_.ProviderName -like "*UniversalPrint*" } |
    Select-Object TimeCreated, LevelDisplayName, Message
```

**Rollback:** None needed — restarting the service is non-destructive. If the service won't start after restart, move to Fix 2.

</details>

<details><summary>Fix 2 — Re-register Universal Print Connector</summary>

Use when: Connector shows `IsAcceptingJobs: False` or is missing from `Get-MgPrintConnector`.

```powershell
# On the connector host — open the UP Connector app
# C:\Program Files\Universal Print Connector\UPConnector.exe
# Click "Sign out", then sign back in with a Global Admin or Printer Administrator account

# Verify registration after sign-in
Connect-MgGraph -Scopes "Printer.Read.All"
Get-MgPrintConnector | Select-Object DisplayName, IsAcceptingJobs, RegisteredDateTime
```

**If re-registration fails:** Uninstall and reinstall the connector from https://aka.ms/UPConnector. Printers associated with this connector will need to be re-registered.

**Rollback:** Re-registering overwrites the old connector record. Existing printer shares remain but may need the connector re-linked via Intune admin centre → Universal Print.

</details>

<details><summary>Fix 3 — Re-share printer and assign users</summary>

Use when: Printer exists but `IsAcceptingJobs: False` on the share, or user can't see the printer.

```powershell
Connect-MgGraph -Scopes "PrinterShare.ReadWrite.All","Printer.ReadWrite.All"

# Get printer ID
$printer = Get-MgPrintPrinter | Where-Object { $_.DisplayName -like "*<PrinterName>*" }

# Get share
$share = Get-MgPrintPrinterShare | Where-Object { $_.PrinterId -eq $printer.Id }

# Add a group to the share
$groupId = (Get-MgGroup -Filter "displayName eq '<GroupName>'").Id
New-MgPrintPrinterShareAllowedGroup -PrinterShareId $share.Id -GroupId $groupId

# Or allow all users on the share
Update-MgPrintPrinterShare -PrinterShareId $share.Id -AllowAllUsers
```

**Rollback:** Remove added group: `Remove-MgPrintPrinterShareAllowedGroup -PrinterShareId $share.Id -GroupId $groupId`

</details>

<details><summary>Fix 4 — Assign Universal Print licence</summary>

Use when: User has no qualifying SKU. Universal Print requires M365 Business Premium, E3, E5, or F3.

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All","Organization.Read.All"

# Find the SKU ID for M365 Business Premium (example)
$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq "SPB" }

# Assign licence to user
Set-MgUserLicense -UserId <UPN> `
    -AddLicenses @{ SkuId = $sku.SkuId } `
    -RemoveLicenses @()
```

**Note:** If no licences are available, purchase additional seats or use group-based licensing to redistribute.

</details>

<details><summary>Fix 5 — Resolve firewall or proxy blocking connector</summary>

Use when: `Test-NetConnection` to `print.microsoft.com:443` fails.

Required endpoints (all HTTPS/443):
- `*.print.microsoft.com`
- `login.microsoftonline.com`
- `aadcdn.msftauth.net`

```powershell
# Test all required endpoints from the connector host
$endpoints = @(
    "print.microsoft.com",
    "login.microsoftonline.com",
    "aadcdn.msftauth.net"
)
foreach ($e in $endpoints) {
    $result = Test-NetConnection -ComputerName $e -Port 443
    [PSCustomObject]@{
        Endpoint = $e
        Success  = $result.TcpTestSucceeded
    }
}
```

**Resolution:** Add the above endpoints to the proxy/firewall allow-list. If TLS inspection is in use, the Universal Print Connector does **not** support SSL interception — bypass it for these endpoints.

**Rollback:** N/A — firewall rules are additive.

</details>

---
## Escalation Evidence

```
UNIVERSAL PRINT ESCALATION
===========================
Date/Time          : 
Tenant ID          : 
Connector Hostname : 
Connector Version  : (check Programs & Features on connector host)
IsAcceptingJobs    : 
Printer Share Name : 
Affected User UPN  : 
User Licence SKUs  : 
Firewall/Proxy     : Yes / No (circle)
TLS Inspection     : Yes / No
Test-NetConnection print.microsoft.com:443 : Pass / Fail
Event Log Errors   : (paste from Get-WinEvent above)
Steps Already Tried: 
```

---
## 🎓 Learning Pointers

- **Universal Print has no on-prem server** — it routes all jobs through Azure. Outbound HTTPS from the connector host to `*.print.microsoft.com` is mandatory; treat it like an M365 endpoint in your proxy allow-list.
- **Connector re-registration doesn't delete printers** — the printer objects live in the Universal Print service, not on the connector. Re-registering only re-establishes the cloud ↔ connector link.
- **Licence requirement is per-user** — the person *sending* the job needs the licence, not the admin setting it up. F3 (Frontline) includes Universal Print for deskless workers.
- **TLS inspection breaks the connector** — Universal Print uses certificate pinning. Proxy SSL inspection must be bypassed for all `*.print.microsoft.com` traffic.
- **Official docs:** [Universal Print overview](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-whatis) | [Connector install guide](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-installation)
- **Community:** [aka.ms/UniversalPrintTech](https://techcommunity.microsoft.com/t5/universal-print/bd-p/UniversalPrint)
