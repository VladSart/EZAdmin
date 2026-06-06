# Conditional Access — Named Locations — Hotfix Runbook (Mode B: Ops)
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

Run these immediately to determine what's broken:

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Policy.Read.All","Policy.ReadWrite.ConditionalAccess"

# 1. List all named locations
Get-MgIdentityConditionalAccessNamedLocation | Select-Object DisplayName, Id, `
  @{N='Type';E={$_.AdditionalProperties.'@odata.type'}}, `
  @{N='IsTrusted';E={$_.AdditionalProperties.isTrusted}}, `
  @{N='IpRanges';E={($_.AdditionalProperties.ipRanges | ConvertTo-Json -Compress)}} |
  Format-Table -AutoSize

# 2. List CA policies referencing named locations
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.State -ne "disabled" } |
  Select-Object DisplayName, State,
    @{N='IncludeLocations';E={$_.Conditions.Locations.IncludeLocations}},
    @{N='ExcludeLocations';E={$_.Conditions.Locations.ExcludeLocations}} |
  Format-Table -AutoSize

# 3. Check sign-in logs for a specific user (last 50 sign-ins)
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@domain.com>'" -Top 50 |
  Select-Object CreatedDateTime, AppDisplayName, IPAddress,
    @{N='Location';E={"$($_.Location.City), $($_.Location.CountryOrRegion)"}},
    @{N='CAResult';E={$_.AppliedConditionalAccessPolicies | ConvertTo-Json -Compress}},
    Status | Format-Table -AutoSize
```

**Interpretation:**

| What you see | What it means |
|---|---|
| Named location missing from list | Location was deleted — recreate from documentation |
| `isTrusted = False` on a location used to bypass MFA | Trusted mark removed — re-mark as trusted |
| CA policy shows `IncludeLocations = AllTrusted` | Policy applies everywhere marked trusted — check all trusted locations |
| Sign-in blocked from known office IP | Office IP not in named location range, or range incorrect |
| Sign-in from "Unknown" location flagged | IP not covered by any named location — may need to add new IP block |
| User blocked from travelling location | Travel IP not excluded in policy; consider Entra ID sign-in risk instead |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Named Location (IP Range or Country)
        │
        │ referenced by
        ▼
Conditional Access Policy
  ├── Conditions > Locations > Include [Named Location]
  │     → Policy applies when user signs in FROM this location
  └── Conditions > Locations > Exclude [Named Location]
        → Policy is SKIPPED when user signs in FROM this location
        │
        │ evaluated against
        ▼
Sign-in IP Address (from user's auth request)
  └── IP must fall within named location CIDR range(s) to match
        │
        │ result feeds
        ▼
CA Grant / Block decision
  ├── If location = trusted → may skip MFA requirement
  ├── If location = untrusted/unknown → enforce MFA or block
  └── If location = blocked country → hard block
        │
        │ depends on
        ▼
Accurate IP Range Data
  ├── Office/VPN IPs must match actual egress IPs
  └── If IP changes (ISP renewal, failover link) → range must be updated
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the sign-in event and IP address**
```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

# Get the specific blocked/affected sign-in
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<user@domain.com>'" -Top 20 |
  Select-Object CreatedDateTime, IPAddress, IsInteractive, Status,
    @{N='CAApplied';E={$_.AppliedConditionalAccessPolicies.DisplayName}},
    @{N='CAResult';E={$_.AppliedConditionalAccessPolicies.Result}} |
  Format-Table -AutoSize
```
Note the IP address from the affected sign-in — this is what you'll validate against named locations.

**Step 2 — Verify the IP is in the correct named location**
```powershell
# Get all IP-based named locations and their ranges
Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.ipNamedLocation' } |
  ForEach-Object {
    [PSCustomObject]@{
      Name     = $_.DisplayName
      IsTrusted = $_.AdditionalProperties.isTrusted
      Ranges   = ($_.AdditionalProperties.ipRanges | ForEach-Object { $_.cidrAddress }) -join ', '
    }
  } | Format-Table -AutoSize
```
Manually verify the sign-in IP falls within one of the listed CIDR ranges. Use an online CIDR calculator if needed (e.g., https://cidr.xyz).

**Step 3 — Check which CA policies affected the sign-in**
In Entra portal: Users > [User] > Sign-in logs > [Event] > Conditional Access tab.
Shows each policy, whether it applied, and the result (Success, Failure, Not Applied).

**Step 4 — Verify the named location is correctly marked as trusted** (if used for MFA bypass)
```powershell
$location = Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.DisplayName -eq "<LocationName>" }
$location.AdditionalProperties.isTrusted
```
Expected: `True` if this location should bypass MFA.  
Bad: `False` — CA policies using "All trusted locations" won't treat this as trusted.

**Step 5 — Check for country-based location blocks**
```powershell
Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.countryNamedLocation' } |
  ForEach-Object {
    [PSCustomObject]@{
      Name      = $_.DisplayName
      Countries = ($_.AdditionalProperties.countriesAndRegions) -join ', '
      IncludeUnknown = $_.AdditionalProperties.includeUnknownCountriesAndRegions
    }
  } | Format-Table -AutoSize
```
If the user's country appears in a blocked-country location, that's the cause.

---

## Common Fix Paths

<details><summary>Fix 1 — Add a missing IP range to an existing named location</summary>

**Symptom:** Users at a specific office or on a new VPN are being prompted for MFA or blocked despite being "at the office."

**Cause:** Office IP changed (ISP renewal) or a new egress IP was added but not added to the named location.

**Fix:**
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

# Get existing named location
$location = Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.DisplayName -eq "<OfficeLocationName>" }

$locationId = $location.Id

# Get existing IP ranges from location
$existingRanges = $location.AdditionalProperties.ipRanges

# Add new range (update the existing list, don't replace)
$newRanges = $existingRanges + @(@{
    "@odata.type" = "#microsoft.graph.iPv4CidrRange"
    cidrAddress   = "<NewIP>/32"   # Use /24 or /16 for subnets
})

# Update the location
$body = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName   = $location.DisplayName
    isTrusted     = $location.AdditionalProperties.isTrusted
    ipRanges      = $newRanges
}

Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId `
    -BodyParameter ($body | ConvertTo-Json -Depth 5)

Write-Host "Named location updated. Verify in Entra portal." -ForegroundColor Green
```

**Rollback:** Re-run with `$newRanges = $existingRanges` (without the new entry).

</details>

<details><summary>Fix 2 — Restore trusted status to a named location</summary>

**Symptom:** Users at a corporate office are now being prompted for MFA that previously wasn't required.

**Cause:** Named location's "Mark as trusted location" was unchecked — possibly during an edit.

**Fix:**
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$location = Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.DisplayName -eq "<LocationName>" }

$body = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName   = $location.DisplayName
    isTrusted     = $true
    ipRanges      = $location.AdditionalProperties.ipRanges
}

Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $location.Id `
    -BodyParameter ($body | ConvertTo-Json -Depth 5)

Write-Host "Location marked as trusted." -ForegroundColor Green
```

**Rollback:** Set `isTrusted = $false`.

> ⚠️ Only mark locations as trusted if the network is genuinely controlled (corporate VPN, office with locked-down egress). Trusted locations bypass MFA in most CA policy designs.

</details>

<details><summary>Fix 3 — Create a new named location for a new office or VPN</summary>

**Symptom:** New office/VPN egress IP is causing MFA challenges or access blocks.

**Fix:**
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$body = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName   = "<NewOfficeName>"
    isTrusted     = $true   # Set to $false if not a trusted network
    ipRanges      = @(
        @{
            "@odata.type" = "#microsoft.graph.iPv4CidrRange"
            cidrAddress   = "<OfficeEgressIP>/32"
        }
        # Add more ranges as needed
    )
}

New-MgIdentityConditionalAccessNamedLocation -BodyParameter ($body | ConvertTo-Json -Depth 5)
Write-Host "Named location created." -ForegroundColor Green
```

After creating, verify the new location appears in any CA policies that reference "All trusted locations" (it will be automatically included if `isTrusted = $true`).

**Rollback:** Delete the new location in Entra portal > Security > CA > Named locations.

</details>

<details><summary>Fix 4 — Unblock a specific user from a country-blocked location (travel scenario)</summary>

**Symptom:** User is travelling and blocked because their country is in a blocked-country named location.

**Preferred fix (temporary access pass or exception):**
1. In Entra portal > Users > [User] > Authentication methods, issue a Temporary Access Pass (TAP) valid for the travel period.
2. TAP bypasses location-based CA policies and is time-limited.

**Alternative — Add user to a CA policy exclusion:**
1. In Entra portal: Security > Conditional Access > [Blocking Policy].
2. Under Users > Exclude, add the specific user or a "Travelling Users" group.
3. Document the exclusion with a ticket number and expiry date.
4. Remove the exclusion when the user returns.

> ⚠️ Do not modify country-block named locations for individual travel cases. Use TAP or targeted exclusions instead.

</details>

<details><summary>Fix 5 — Diagnose "Unknown location" sign-ins triggering blocks</summary>

**Symptom:** Sign-ins from "Unknown" country or location are being blocked.

**Cause:** IP geolocation database doesn't resolve to a country (private IP leaked, IPv6 not covered, or VPN exit node with no geo data).

**Diagnosis:**
```powershell
# Check if any named location includes unknown countries
Get-MgIdentityConditionalAccessNamedLocation |
  Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.countryNamedLocation' } |
  Select-Object DisplayName, @{N='IncludeUnknown';E={$_.AdditionalProperties.includeUnknownCountriesAndRegions}}
```

**Fix options:**
- If the user's corporate VPN exits through an IP with no geo data: add that IP range to a trusted named location.
- If a country-block policy has `includeUnknownCountriesAndRegions = true`, consider whether unknown should be blocked or allowed for your risk profile.
- To update unknown countries inclusion:
  ```powershell
  # Update country named location to exclude unknowns
  $location = Get-MgIdentityConditionalAccessNamedLocation | Where-Object { $_.DisplayName -eq "<BlockedCountriesLocation>" }
  $body = @{
      "@odata.type" = "#microsoft.graph.countryNamedLocation"
      displayName   = $location.DisplayName
      countriesAndRegions = $location.AdditionalProperties.countriesAndRegions
      includeUnknownCountriesAndRegions = $false  # Change as needed
  }
  Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $location.Id `
      -BodyParameter ($body | ConvertTo-Json -Depth 5)
  ```

</details>

---

## Escalation Evidence

```
=== Named Locations / CA Escalation Pack ===

Date/Time:              ___________________________
Tenant ID:              ___________________________
Affected User UPN:      ___________________________
Sign-in Date/Time:      ___________________________
Sign-in IP Address:     ___________________________
Geo-resolved Location:  ___________________________

Named Location Name:    ___________________________
Named Location ID:      ___________________________
Location Type:          [ ] IP Range   [ ] Country
IsTrusted:              [ ] Yes  [ ] No

CA Policy Triggering Block:  ___________________
CA Policy Result:            ___________________

Expected Behavior:      ___________________________
Actual Behavior:        ___________________________

Steps Already Taken:
  1. _____________________________________________
  2. _____________________________________________
  3. _____________________________________________

Sign-in log screenshot (CA tab): [attached]
Named Location config screenshot: [attached]

Raise via: Microsoft Entra / Azure AD support case
Portal path: https://entra.microsoft.com > Security > Conditional Access > Named locations
```

---

## 🎓 Learning Pointers

- **"All trusted locations" is a dynamic list.** Any named location with `isTrusted = true` is automatically included when a CA policy condition says "All trusted locations." If you uncheck trusted on a location, it silently drops out of MFA bypass policies. Always verify after edits. [MS Docs: Named locations](https://learn.microsoft.com/en-us/entra/identity/conditional-access/location-condition)

- **Trusted locations bypass MFA — treat IP ranges carefully.** If a public café or hotel gets the same IP block as a corporate office by coincidence, those users bypass MFA. Keep IP ranges as narrow as possible (prefer /32 per egress IP over /16 subnets). Audit named locations quarterly.

- **Country-based locations are coarse.** Geolocation databases have known gaps for cloud provider IPs, satellite internet, and VPN exit nodes. A user on a business VPN may appear in an unexpected country. Rely on sign-in risk (Entra ID Protection) rather than country blocks alone for high-security scenarios. [MS Docs: Location condition](https://learn.microsoft.com/en-us/entra/identity/conditional-access/location-condition#countries-and-regions)

- **Temporary Access Passes are the right tool for travel.** Instead of modifying CA policies for individual travel events, issue a time-limited TAP from Authentication methods. TAPs bypass location conditions, don't touch policy config, and self-expire. [MS Docs: Temporary Access Pass](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)

- **Sign-in logs show exactly which named location matched.** In Entra portal > Sign-in logs > [Event] > Location tab, you can see what named location (if any) the IP resolved to, and under the Conditional Access tab, which policies applied and what the verdict was. This is always your first stop for CA location debugging.

- **Named locations are tenant-wide — changes are instant.** Unlike CA policy changes which may take up to a few minutes to propagate, named location IP range changes take effect for new sign-ins almost immediately. Be careful editing trusted locations during business hours without a maintenance window. [MS Docs: CA best practices](https://learn.microsoft.com/en-us/entra/identity/conditional-access/best-practices)
