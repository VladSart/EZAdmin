# Entra ID — Microsoft Graph Useful Queries
> Copy-paste Graph API queries for day-to-day L2/L3 Entra ID operations.  
> Includes: PowerShell (Microsoft.Graph SDK), Graph Explorer URLs, and raw REST examples.

---

## Contents
- [Setup & Auth](#setup--auth)
- [Devices](#devices)
- [Users](#users)
- [Groups](#groups)
- [Sign-In & Audit Logs](#sign-in--audit-logs)
- [Conditional Access](#conditional-access)
- [Service Principals & App Registrations](#service-principals--app-registrations)
- [Directory Sync (Entra Connect)](#directory-sync-entra-connect)
- [Licenses](#licenses)
- [Batch Operations](#batch-operations)
- [Useful Graph Explorer Links](#useful-graph-explorer-links)

---

## Setup & Auth

### Connect with scopes for most admin queries
```powershell
Connect-MgGraph -Scopes `
    "Device.Read.All",
    "User.Read.All",
    "Group.Read.All",
    "AuditLog.Read.All",
    "Policy.Read.All",
    "Directory.Read.All",
    "Organization.Read.All"
```

### Connect with a client credential (service principal / automation)
```powershell
$tenantId = "<tenant-id>"
$appId    = "<app-id>"
$secret   = "<client-secret>"   # Use Key Vault in production

$body = @{
    grant_type    = "client_credentials"
    client_id     = $appId
    client_secret = $secret
    scope         = "https://graph.microsoft.com/.default"
}
$token = Invoke-RestMethod "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body
$headers = @{ Authorization = "Bearer $($token.access_token)" }
# Then: Invoke-RestMethod "https://graph.microsoft.com/v1.0/..." -Headers $headers
```

---

## Devices

### Get all Entra-registered/joined devices
```powershell
Get-MgDevice -All | Select DisplayName, TrustType, OperatingSystem, OperatingSystemVersion, ApproximateLastSignInDateTime, IsCompliant
```
`TrustType` values: `AzureAd` (Entra Join), `ServerAd` (Hybrid Join), `Workplace` (Entra Registered)

---

### Get stale devices (no sign-in for 90+ days)
```powershell
$cutoff = (Get-Date).AddDays(-90).ToString("yyyy-MM-ddTHH:mm:ssZ")
Get-MgDevice -Filter "approximateLastSignInDateTime le $cutoff" -All |
    Select DisplayName, TrustType, ApproximateLastSignInDateTime, IsManaged |
    Sort-Object ApproximateLastSignInDateTime
```

---

### Get all Hybrid-Joined devices only
```powershell
Get-MgDevice -Filter "trustType eq 'ServerAd'" -All |
    Select DisplayName, OperatingSystem, IsCompliant, ApproximateLastSignInDateTime
```

---

### Get devices in Pending state (userCertificate not yet synced)
```powershell
# Pending = TrustType eq 'ServerAd' AND profileType is Registered but missing cert
# In Graph, Pending devices appear with no deviceId in some views.
# Best approach: filter by ProfileType
Get-MgDevice -Filter "profileType eq 'RegisteredDevice' and trustType eq 'ServerAd'" -All |
    Where-Object { $_.ApproximateLastSignInDateTime -lt (Get-Date).AddDays(-30) } |
    Select DisplayName, ApproximateLastSignInDateTime, IsCompliant
```

---

### Get a single device by display name
```powershell
Get-MgDevice -Filter "displayName eq '<DeviceName>'" |
    Select Id, DisplayName, TrustType, IsManaged, IsCompliant, PhysicalIds
```

---

### Get device's registered owners
```powershell
$deviceId = "<device-object-id>"
Get-MgDeviceRegisteredOwner -DeviceId $deviceId | Select Id, DisplayName
```

---

### Disable a stale device
```powershell
Update-MgDevice -DeviceId "<device-id>" -AccountEnabled:$false
```

---

### Delete a device
```powershell
Remove-MgDevice -DeviceId "<device-id>"
```

---

## Users

### Get all users with key attributes
```powershell
Get-MgUser -All -Select "displayName,userPrincipalName,accountEnabled,assignedLicenses,lastPasswordChangeDateTime,userType" |
    Select DisplayName, UserPrincipalName, AccountEnabled, UserType
```

---

### Find a user by UPN or email
```powershell
Get-MgUser -Filter "userPrincipalName eq '<upn@domain.com>'" |
    Select DisplayName, Id, AccountEnabled, Mail, UserType
```

---

### Get users that haven't signed in for 30+ days
```powershell
# Requires AuditLog.Read.All scope
$cutoff = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
Get-MgUser -All -Filter "signInActivity/lastSignInDateTime le $cutoff" `
    -Select "displayName,userPrincipalName,signInActivity" |
    Select DisplayName, UserPrincipalName, @{n='LastSignIn';e={$_.SignInActivity.LastSignInDateTime}} |
    Sort-Object LastSignIn
```

---

### Get user's group memberships (direct + transitive)
```powershell
$userId = "<user-object-id>"
Get-MgUserTransitiveMemberOf -UserId $userId -All |
    Select @{n='DisplayName';e={$_.AdditionalProperties['displayName']}},
           @{n='Type';e={$_.AdditionalProperties['@odata.type']}}
```

---

### Get all guest users
```powershell
Get-MgUser -Filter "userType eq 'Guest'" -All |
    Select DisplayName, UserPrincipalName, Mail, CreatedDateTime |
    Sort-Object CreatedDateTime -Descending
```

---

### Reset a user's password (requires appropriate permissions)
```powershell
$userId  = "<user-object-id>"
$newPass = ConvertTo-SecureString "<NewPassword123!" -AsPlainText -Force
Update-MgUser -UserId $userId -PasswordProfile @{
    Password                      = "<NewPassword123!"
    ForceChangePasswordNextSignIn = $true
}
```

---

## Groups

### Get all groups
```powershell
Get-MgGroup -All | Select DisplayName, GroupTypes, SecurityEnabled, MailEnabled, MembershipRule
```

---

### Find a group by name
```powershell
Get-MgGroup -Filter "displayName eq '<GroupName>'" | Select Id, DisplayName, GroupTypes
```

---

### Get group members
```powershell
$groupId = "<group-object-id>"
Get-MgGroupMember -GroupId $groupId -All |
    Select @{n='DisplayName';e={$_.AdditionalProperties['displayName']}},
           @{n='UPN';e={$_.AdditionalProperties['userPrincipalName']}},
           @{n='Type';e={$_.AdditionalProperties['@odata.type']}}
```

---

### Get all dynamic groups and their membership rules
```powershell
Get-MgGroup -Filter "groupTypes/any(c:c eq 'DynamicMembership')" -All |
    Select DisplayName, MembershipRule, MembershipRuleProcessingState
```

---

### Add a member to a group
```powershell
$groupId  = "<group-object-id>"
$memberId = "<user-or-device-object-id>"
New-MgGroupMember -GroupId $groupId -DirectoryObjectId $memberId
```

---

## Sign-In & Audit Logs

### Get last 50 sign-in events for a user
```powershell
# Requires AuditLog.Read.All
$upn = "<user@domain.com>"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 50 |
    Select CreatedDateTime, AppDisplayName, IPAddress, Status, ConditionalAccessStatus |
    Sort-Object CreatedDateTime -Descending
```

---

### Get failed sign-ins in the last 24 hours
```powershell
$since = (Get-Date).AddHours(-24).ToString("yyyy-MM-ddTHH:mm:ssZ")
Get-MgAuditLogSignIn -Filter "createdDateTime ge $since and status/errorCode ne 0" -Top 100 |
    Select CreatedDateTime, UserPrincipalName, AppDisplayName, IPAddress,
           @{n='ErrorCode';e={$_.Status.ErrorCode}},
           @{n='FailureReason';e={$_.Status.FailureReason}}
```

---

### Get CA policy applied to a specific sign-in
```powershell
$signInId = "<sign-in-id>"
$signIn = Get-MgAuditLogSignIn -SignInId $signInId
$signIn.AppliedConditionalAccessPolicies | Select DisplayName, Result, GrantControls
```

---

### Get directory audit events (last 100)
```powershell
Get-MgAuditLogDirectoryAudit -Top 100 |
    Select ActivityDateTime, ActivityDisplayName, InitiatedBy, TargetResources |
    Sort-Object ActivityDateTime -Descending
```

---

### Get audit events for a specific user (e.g., password changes)
```powershell
$userId = "<user-upn-or-id>"
Get-MgAuditLogDirectoryAudit -Filter "targetResources/any(t:t/userPrincipalName eq '$userId')" -Top 50 |
    Select ActivityDateTime, ActivityDisplayName,
           @{n='Actor';e={$_.InitiatedBy.User.UserPrincipalName}}
```

---

## Conditional Access

### List all CA policies and their state
```powershell
Get-MgIdentityConditionalAccessPolicy -All |
    Select DisplayName, State, Id |
    Sort-Object State, DisplayName
```
`State` values: `enabled`, `disabled`, `enabledForReportingButNotEnforced`

---

### Export all CA policies to JSON (for backup)
```powershell
$outPath = "$env:TEMP\CA-Policies-Backup-$(Get-Date -Format 'yyyyMMdd').json"
Get-MgIdentityConditionalAccessPolicy -All | ConvertTo-Json -Depth 10 | Out-File $outPath -Encoding UTF8
Write-Host "Exported to $outPath"
```

---

### Get policies that target a specific group
```powershell
$groupId = "<group-object-id>"
Get-MgIdentityConditionalAccessPolicy -All | Where-Object {
    $_.Conditions.Users.IncludeGroups -contains $groupId -or
    $_.Conditions.Users.ExcludeGroups -contains $groupId
} | Select DisplayName, State
```

---

## Service Principals & App Registrations

### List all service principals
```powershell
Get-MgServicePrincipal -All | Select DisplayName, AppId, SignInAudience, AccountEnabled
```

---

### Find apps with expiring credentials (secrets or certs) in next 30 days
```powershell
$soon = (Get-Date).AddDays(30)
Get-MgApplication -All | ForEach-Object {
    $app = $_
    $app.PasswordCredentials | Where-Object { $_.EndDateTime -lt $soon -and $_.EndDateTime -gt (Get-Date) } |
        ForEach-Object {
            [PSCustomObject]@{
                AppName   = $app.DisplayName
                AppId     = $app.AppId
                Type      = "Secret"
                ExpiresOn = $_.EndDateTime
            }
        }
    $app.KeyCredentials | Where-Object { $_.EndDateTime -lt $soon -and $_.EndDateTime -gt (Get-Date) } |
        ForEach-Object {
            [PSCustomObject]@{
                AppName   = $app.DisplayName
                AppId     = $app.AppId
                Type      = "Certificate"
                ExpiresOn = $_.EndDateTime
            }
        }
} | Sort-Object ExpiresOn
```

---

### Get app permissions (OAuth2 delegated + application)
```powershell
$spId = "<service-principal-object-id>"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $spId -All |
    Select PrincipalDisplayName, ResourceDisplayName, AppRoleId
```

---

## Directory Sync (Entra Connect)

### Get sync status of a specific on-prem user
```powershell
# onPremisesSyncEnabled = true means the object is sync'd from on-prem AD
Get-MgUser -Filter "userPrincipalName eq '<upn@domain.com>'" `
    -Select "displayName,onPremisesSyncEnabled,onPremisesLastSyncDateTime,onPremisesDistinguishedName,onPremisesSamAccountName" |
    Select DisplayName, OnPremisesSyncEnabled, OnPremisesLastSyncDateTime, OnPremisesDistinguishedName
```

---

### Get all objects with sync errors
```powershell
# Returns users where onPremisesProvisioningErrors is non-empty
Get-MgUser -All -Filter "onPremisesProvisioningErrors/$count gt 0" -CountVariable count `
    -ConsistencyLevel "eventual" `
    -Select "displayName,userPrincipalName,onPremisesProvisioningErrors" |
    ForEach-Object {
        [PSCustomObject]@{
            DisplayName = $_.DisplayName
            UPN         = $_.UserPrincipalName
            ErrorCategory = ($_.OnPremisesProvisioningErrors | Select-Object -First 1).Category
            ErrorDetail   = ($_.OnPremisesProvisioningErrors | Select-Object -First 1).Value
        }
    }
```

---

### Get last directory sync time for the tenant
```powershell
(Get-MgOrganization).OnPremisesLastSyncDateTime
# Also check:
(Get-MgOrganization).OnPremisesSyncEnabled
```

---

## Licenses

### Get all SKUs available in the tenant
```powershell
Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits,
    @{n='Available';e={$_.PrepaidUnits.Enabled - $_.ConsumedUnits}},
    @{n='Suspended';e={$_.PrepaidUnits.Suspended}}
```

---

### Get users without any license
```powershell
Get-MgUser -All -Filter "assignedLicenses/$count eq 0" -CountVariable c `
    -ConsistencyLevel "eventual" |
    Select DisplayName, UserPrincipalName, UserType
```

---

### Get users with a specific license (by SKU ID)
```powershell
$skuId = "<sku-id>"  # Get from Get-MgSubscribedSku | Select SkuId, SkuPartNumber
Get-MgUser -All -Filter "assignedLicenses/any(x:x/skuId eq $skuId)" |
    Select DisplayName, UserPrincipalName
```

---

### Assign a license to a user
```powershell
$userId = "<user-object-id>"
$skuId  = "<sku-id>"
Set-MgUserLicense -UserId $userId `
    -AddLicenses @{SkuId = $skuId} `
    -RemoveLicenses @()
```

---

## Batch Operations

### Batch request — get multiple users in one HTTP call
```powershell
# Graph batch endpoint: POST https://graph.microsoft.com/v1.0/$batch
# Useful for high-volume queries to avoid throttling

$upns  = @("user1@domain.com","user2@domain.com","user3@domain.com")
$batch = @{
    requests = @(
        for ($i = 0; $i -lt $upns.Count; $i++) {
            @{
                id     = "$($i+1)"
                method = "GET"
                url    = "/users/$($upns[$i])?`$select=displayName,userPrincipalName,accountEnabled"
            }
        }
    )
}
$body    = $batch | ConvertTo-Json -Depth 5
$token   = (Get-MgContext).AccessToken
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$result  = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/`$batch" -Method Post -Headers $headers -Body $body
$result.responses | ForEach-Object {
    [PSCustomObject]@{
        Status = $_.status
        UPN    = $_.body.userPrincipalName
        Name   = $_.body.displayName
        Enabled = $_.body.accountEnabled
    }
}
```

---

## Useful Graph Explorer Links

Open these in [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer) (auto-authenticated to your own tenant):

| Query | URL |
|-------|-----|
| My profile | `GET /me` |
| All devices | `GET /devices?$top=100` |
| All CA policies | `GET /identity/conditionalAccess/policies` |
| Sign-in logs (last 10) | `GET /auditLogs/signIns?$top=10` |
| Directory audit (last 10) | `GET /auditLogs/directoryAudits?$top=10` |
| Tenant sync info | `GET /organization?$select=onPremisesLastSyncDateTime,onPremisesSyncEnabled` |
| Subscribed SKUs | `GET /subscribedSkus` |
| Apps with expiring secrets | `GET /applications?$select=displayName,appId,passwordCredentials,keyCredentials` |
| Named locations | `GET /identity/conditionalAccess/namedLocations` |

---

## 🎓 Learning Pointers

- **ConsistencyLevel: eventual is required for advanced filters.** Any query using `$count`, `startsWith()`, `endsWith()`, or the `not()` filter operator on large datasets requires the `ConsistencyLevel: eventual` header. In PowerShell SDK this is `-ConsistencyLevel "eventual"`. Without it the query returns 400 Bad Request with a cryptic message. [MS Docs: Advanced query capabilities](https://learn.microsoft.com/en-us/graph/aad-advanced-queries)

- **Graph Explorer is your fastest debugging tool.** When a PowerShell query fails, replicate it in Graph Explorer first — it shows the raw JSON response, consent status, and permission errors immediately. [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer)

- **Sign-in logs are only retained for 30 days (Entra ID Free/P1) or 90 days (P2).** If you need longer retention, export to a Log Analytics workspace or Storage Account via Diagnostic Settings. [MS Docs: Sign-in log retention](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/reference-reports-data-retention)

- **Throttling limits are per-app, not per-user.** If automation scripts hit 429 Too Many Requests, implement exponential back-off (retry after `Retry-After` header value in seconds) and consider batching requests. [MS Docs: Throttling guidance](https://learn.microsoft.com/en-us/graph/throttling)

- **`Get-MgUser -All` pages automatically, but watch memory on large tenants.** For tenants with 50k+ users, consider filtering server-side (`-Filter`) or using `$select` to limit returned attributes rather than pulling all properties for all users. The difference between an unfiltered `Get-MgUser -All` and a filtered one can be 10x in both time and memory.
