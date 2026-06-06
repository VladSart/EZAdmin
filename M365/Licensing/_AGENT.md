# M365 Licensing — Agent Instructions

## What's in this folder
Runbooks and scripts for Microsoft 365 licensing issues. Covers license assignment failures, group-based licensing errors, license conflicts, and audit/reporting of license consumption across the tenant.

## Before responding, also check
- `M365/_AGENT.md` — M365-wide triage context
- `EntraID/` — if group membership is not being applied (affects group-based licensing)
- `M365/Teams/` — if a Teams feature is missing (usually a Teams add-on license)
- `Intune/` — if Intune enrollment fails due to licensing (requires EMS/Intune license)

## Folder contents

| File | What it covers |
|------|---------------|
| `License-Assignment-B.md` | Direct license assignment failures, missing service plans, license errors per user |
| `Group-Based-Licensing-B.md` | Group-based licensing errors, processing failures, inherited assignment problems |

## Common entry points

- "User missing a feature (Teams, Defender, etc.)" → `License-Assignment-B.md` — check SKU and service plan status
- "License assignment failed / shows error" → `License-Assignment-B.md` Triage
- "Group-based licensing not applying" → `Group-Based-Licensing-B.md` — check group type and errors
- "License errors in Entra ID admin centre" → `Group-Based-Licensing-B.md` — error mapping table
- "How many licenses are left?" → `License-Assignment-B.md` Fix 5 (license inventory)
- "User was licensed but feature disappeared" → check group-based licensing reassignment or SKU change

## Key diagnostic commands

```powershell
# Get user's current licenses
Get-MgUserLicenseDetail -UserId <UPN> | Select-Object SkuPartNumber, SkuId

# Get user's disabled service plans within a license
Get-MgUserLicenseDetail -UserId <UPN> | ForEach-Object {
    $sku = $_.SkuPartNumber
    $_.ServicePlans | Where-Object {$_.ProvisioningStatus -ne "Success"} | ForEach-Object {
        [PSCustomObject]@{SKU=$sku; ServicePlan=$_.ServicePlanName; Status=$_.ProvisioningStatus}
    }
} | Format-Table

# Get tenant license overview
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N="Available";E={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}} | Format-Table -AutoSize

# Get group-based licensing errors for a user
(Get-MgUser -UserId <UPN> -Property LicenseAssignmentStates).LicenseAssignmentStates | Where-Object {$_.State -eq "Error"} | Format-List
```

## Key dependency chain

```
Tenant subscription (purchased SKUs / seats)
    └── Available license pool (purchased - consumed)
        └── Group-based licensing group (Dynamic or Assigned)
            │   └── Entra ID group membership
            │       └── License assignment to user (inherited)
            └── Direct license assignment (overrides or supplements)
                └── Service plans enabled/disabled per user
                    └── Feature available in M365 app/service
```

## Response format reminder (always 3 layers)

1. **Triage** — identify which SKU/service plan is missing or erroring in 60 seconds
2. **Fix** — assign license, resolve conflict, or fix group membership
3. **Validate** — confirm license applied, service plan shows "Success"
