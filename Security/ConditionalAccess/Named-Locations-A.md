# Conditional Access Named Locations — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains how Named Locations work in Azure AD CA policy evaluation, common failure modes, and how to manage them at scale.

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

**What this covers:**
- Azure AD Named Locations (IP ranges and Countries/Regions)
- How CA policies evaluate Named Locations at sign-in
- Trusted vs. non-trusted locations and their effect on MFA, Compliant Network, and risk scores
- Diagnosing incorrect block/allow based on location conditions
- Managing Named Locations at scale via Graph API

**What this does NOT cover:**
- IPv6 Named Locations (supported but behaves identically — just use CIDR notation)
- MFA Trusted IPs (legacy, separate from Named Locations — migration path covered below)
- CA policy design patterns (see `CA-Design-A.md`)

**Assumed environment:**
- Azure AD P1 or P2 (Named Locations require P1 minimum for CA)
- Tenant has Conditional Access policies in use
- Engineer has Security Administrator or Conditional Access Administrator role

---

## How It Works

<details><summary>Full architecture — Named Location evaluation in CA</summary>

### What Named Locations ARE

Named Locations are **labelled network/geography ranges** that CA policies reference to allow or block sign-ins based on where they originate. There are two types:

**Type 1: IP range locations**
- Define one or more IPv4/IPv6 CIDR ranges (e.g., `203.0.113.0/24`)
- Can be marked as **Trusted** — which feeds into:
  - Sign-in risk downgrade (Microsoft Identity Protection uses this signal)
  - MFA registration policies (Trusted = can be exempted)
  - Compliant Network Check (requires Trusted mark)
- Max 2,000 IP range Named Locations per tenant
- Each location can hold up to 2,000 CIDR ranges

**Type 2: Countries/Regions locations**
- Define a set of countries based on IP geolocation databases
- Optional: "Include unknown countries/regions" — includes IPs that don't map to any country
- Useful for blocking sign-ins from unexpected geographies

### How CA evaluates location at sign-in

When a sign-in occurs, Azure AD:

1. Captures the source IP of the sign-in request
2. Resolves which Named Locations match that IP (if any)
3. Checks if any matching location is marked **Trusted**
4. Passes this context (`networkLocationDetails`) to all active CA policies
5. Each CA policy evaluates its `locations` condition:
   - `includeLocations`: policy applies to sign-ins FROM these locations
   - `excludeLocations`: policy does NOT apply to sign-ins FROM these locations
   - `AnyLocation` matches all sign-ins
   - `AllTrusted` matches only sign-ins from Trusted Named Locations

### CA policy location condition logic

```
Policy triggers if:
    source IP ∈ includeLocations
    AND source IP ∉ excludeLocations
```

Common pattern — **MFA for external access**:
```
Include: AnyLocation
Exclude: [CorpNetwork] (Trusted Named Location)
Effect: MFA required for all sign-ins NOT from CorpNetwork
```

Common pattern — **Block specific geographies**:
```
Include: [Blocked Countries NL]
Exclude: (none)
Grant: Block
Effect: Sign-ins from those countries are denied
```

### Trusted location and Identity Protection interaction

When a sign-in comes from a Trusted Named Location:
- Microsoft Identity Protection **lowers the calculated sign-in risk** (Trusted = known safe network)
- Policies checking for "Low risk or above" may not trigger for trusted IPs
- This is intentional: reducing friction for users on corporate networks

### MFA Trusted IPs (legacy) vs Named Locations

Legacy MFA Trusted IPs (in the old Per-User MFA portal) are separate from Named Locations. They do NOT feed into CA policy evaluation. Microsoft is deprecating legacy MFA Trusted IPs — migrate to Named Locations for all CA-based MFA exemptions.

### Geolocation accuracy

Microsoft uses the MaxMind GeoIP2 database (among others) for country resolution. Known limitations:
- IPv6 geolocation is less accurate than IPv4
- Large ISPs and cloud providers (AWS, Azure, GCP) may have IPs geolocated to one country but used globally
- VPNs and proxies allow geolocation bypass — country-based blocks are not security boundaries, they are friction increases

</details>

---

## Dependency Stack

```
User Sign-in Attempt
        │
        ▼
Azure AD Authentication (Entra ID)
        │
        ▼
Source IP Captured
        │
        ▼
Named Location Lookup
  ├─ IP Range Locations (CIDR matching)
  │       └─ Trusted flag resolved
  └─ Country/Region Locations (GeoIP lookup)
        │
        ▼
CA Policy Engine
  ├─ Location condition evaluated per policy
  ├─ Other conditions (user, device, app, risk)
  └─ Grant/Block/Session controls applied
        │
        ▼
Sign-in Allowed / Blocked / Challenged
        │
        ▼
Sign-in Logs (Azure AD) → Evidence
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Users blocked unexpectedly from corp network | IP range not in Named Location, or location not marked Trusted | Verify CIDR range covers the user's actual egress IP |
| MFA still required from trusted office IP | Location exists but not marked Trusted, OR CA policy uses wrong exclude | Check location Trust flag; check CA policy excludeLocations |
| Country block not working, sign-ins still succeed from blocked country | User is on VPN exiting from unblocked country | Expected — country blocks are not VPN-proof |
| Users in Country block also blocked when on VPN | VPN exit IP geolocates to blocked country | Add VPN egress ranges to a Trusted Named Location and exclude it |
| "AllTrusted" condition not matching | No Named Locations are marked Trusted, or user's IP doesn't match | Check Trust flag on all relevant locations |
| "Include unknown countries" blocking legitimate users | ISP's IP not in any geolocation database | Add the ISP's CIDR to a Named Location explicitly |
| Named Location shows in portal but CA policy doesn't use it | Policy was not updated after location creation | Edit CA policy and add the new location to include/excludeLocations |
| Sign-in from correct location still fails policy | Cached token from previous location being used | Token was issued at previous location; sign-in risk signal uses issue-time IP |
| Named Location edit not taking effect | Policy evaluation uses point-in-time snapshot; propagation delay | Wait 5-10 minutes for location change to propagate |

---

## Validation Steps

**Step 1 — Confirm the user's actual egress IP**

Have the user navigate to [https://whatismyipaddress.com](https://whatismyipaddress.com) or run:
```powershell
# From user's machine
(Invoke-WebRequest -Uri "https://api64.ipify.org?format=text" -UseBasicParsing).Content
```

Compare this IP against the CIDR ranges in your Named Location.

---

**Step 2 — Verify CIDR coverage**

```powershell
function Test-IPInCIDR {
    param(
        [string]$IPAddress,
        [string]$CIDR
    )
    $parts    = $CIDR.Split('/')
    $baseIP   = [System.Net.IPAddress]::Parse($parts[0])
    $prefix   = [int]$parts[1]
    $mask     = [uint32](0xFFFFFFFF -shl (32 - $prefix))
    $baseInt  = [uint32][System.BitConverter]::ToUInt32($baseIP.GetAddressBytes()[3..0], 0)
    $testInt  = [uint32][System.BitConverter]::ToUInt32(([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()[3..0], 0)
    return ($baseInt -band $mask) -eq ($testInt -band $mask)
}

# Test: does 203.0.113.45 fall in 203.0.113.0/24?
Test-IPInCIDR -IPAddress "203.0.113.45" -CIDR "203.0.113.0/24"
# Returns True
```

---

**Step 3 — Check Named Locations via Graph API**

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

# List all Named Locations
$locations = Get-MgIdentityConditionalAccessNamedLocation -All

foreach ($loc in $locations) {
    $trusted = if ($loc.AdditionalProperties.isTrusted) { "TRUSTED" } else { "not trusted" }
    $type    = $loc.AdditionalProperties.'@odata.type'
    Write-Host "[$trusted] $($loc.DisplayName) — $type" -ForegroundColor $(if ($loc.AdditionalProperties.isTrusted) {"Green"} else {"Yellow"})
    
    # Show IP ranges
    if ($loc.AdditionalProperties.ipRanges) {
        foreach ($range in $loc.AdditionalProperties.ipRanges) {
            Write-Host "  $($range.cidrAddress)"
        }
    }
    # Show countries
    if ($loc.AdditionalProperties.countriesAndRegions) {
        Write-Host "  Countries: $($loc.AdditionalProperties.countriesAndRegions -join ', ')"
    }
}
```

**Good output:** Your corporate CIDR ranges are present and the location shows `[TRUSTED]`.

**Bad output:** Location missing CIDR, or shows `[not trusted]` when you expect MFA bypass.

---

**Step 4 — Check sign-in logs for location details**

Azure AD portal: Monitoring → Sign-in logs → [find the failed sign-in]

In the sign-in detail, check:
- **Location** tab → shows resolved IP, country, city
- **Conditional Access** tab → shows which policies applied and why they succeeded/failed

Or via PowerShell:
```powershell
Connect-MgGraph -Scopes "AuditLog.Read.All"

$upn = "<UserUPN>"
$logs = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 10 |
    Select-Object CreatedDateTime, AppDisplayName, IpAddress, Location, Status,
        ConditionalAccessStatus, @{N="CADetails";E={$_.AppliedConditionalAccessPolicies | 
            Select-Object DisplayName,Result | Format-Table | Out-String}}

$logs | Format-List
```

---

**Step 5 — Confirm CA policy is referencing the correct location**

```powershell
Connect-MgGraph -Scopes "Policy.Read.All"

$policies = Get-MgIdentityConditionalAccessPolicy -All |
    Where-Object { $_.State -eq "enabled" }

foreach ($policy in $policies) {
    $locations = $policy.Conditions.Locations
    if ($locations.IncludeLocations -or $locations.ExcludeLocations) {
        Write-Host "Policy: $($policy.DisplayName)" -ForegroundColor Cyan
        Write-Host "  Include: $($locations.IncludeLocations -join ', ')"
        Write-Host "  Exclude: $($locations.ExcludeLocations -join ', ')"
    }
}
```

Cross-reference the Location IDs shown against the Named Location IDs from Step 3.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Gather context

1. What is the user's source IP? (collect via Step 1)
2. What Named Location should cover that IP? (check portal or Step 3)
3. What CA policy is triggering/not triggering? (check sign-in logs)
4. Is the location Trusted? (check Step 3)

### Phase 2 — Test coverage

1. Run `Test-IPInCIDR` against each CIDR in the Named Location
2. If NO range covers the IP: need to add/update the CIDR ranges
3. If a range DOES cover the IP but policy still applies: check Trust flag and CA policy exclude list

### Phase 3 — Policy logic review

1. Is the Named Location in the CA policy's `excludeLocations`? Should it be?
2. Is the CA policy using `AllTrusted` — and is the Named Location actually marked Trusted?
3. Are there other CA policies that may be blocking BEFORE this policy's exclude can apply?

### Phase 4 — Propagation / timing

1. Was the Named Location recently changed? Wait 5-10 minutes and test again
2. Is the user's token cached from a previous location? Ask user to sign out completely and re-authenticate

---

## Remediation Playbooks

<details><summary>Fix 1 — Add new IP range to existing Named Location</summary>

**Via Intune/Azure AD portal:**
1. Azure AD → Security → Conditional Access → Named Locations
2. Select the location → Edit → Add IP range → Enter CIDR → Save

**Via PowerShell (Graph API):**
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$locationId = "<NamedLocationGUID>"  # From portal or Get-MgIdentityConditionalAccessNamedLocation
$newCIDR    = "<NewCIDR>"            # e.g., "198.51.100.0/24"

# Get current location
$location   = Get-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId
$existingRanges = $location.AdditionalProperties.ipRanges

# Add new range
$updatedRanges  = $existingRanges + @{ "@odata.type" = "#microsoft.graph.iPv4CidrRange"; cidrAddress = $newCIDR }

$params = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    ipRanges      = $updatedRanges
    isTrusted     = $location.AdditionalProperties.isTrusted
}

Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId -BodyParameter $params
Write-Host "Added $newCIDR to $($location.DisplayName)" -ForegroundColor Green
```

**Rollback:** Remove the CIDR range using the same script without the new range in `$updatedRanges`.

</details>

<details><summary>Fix 2 — Mark Named Location as Trusted</summary>

**Via portal:**
1. Named Locations → [location] → Edit
2. Check "Mark as trusted location" → Save

**Via PowerShell:**
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$locationId = "<NamedLocationGUID>"
$location   = Get-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId

$params = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    ipRanges      = $location.AdditionalProperties.ipRanges
    isTrusted     = $true
}

Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $locationId -BodyParameter $params
Write-Host "Marked $($location.DisplayName) as Trusted" -ForegroundColor Green
```

**Effect:** Existing CA policies using "All trusted locations" will now include this location. Identity Protection will treat sign-ins from these IPs as lower risk.

**Rollback:** Set `isTrusted = $false` with the same script.

</details>

<details><summary>Fix 3 — Migrate legacy MFA Trusted IPs to Named Locations</summary>

**Context:** Legacy Per-User MFA Trusted IPs are separate from CA Named Locations. They do not integrate with modern CA. Microsoft recommends migrating to Named Locations.

**Steps:**
1. Retrieve legacy Trusted IPs:
   - Azure AD → Security → MFA → Additional cloud-based MFA settings
   - Note all Trusted IPs listed there

2. Create a new IP Named Location with those ranges:
```powershell
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$params = @{
    "@odata.type" = "#microsoft.graph.ipNamedLocation"
    displayName   = "Migrated MFA Trusted IPs"
    isTrusted     = $true
    ipRanges      = @(
        @{ "@odata.type" = "#microsoft.graph.iPv4CidrRange"; cidrAddress = "<CIDR1>" },
        @{ "@odata.type" = "#microsoft.graph.iPv4CidrRange"; cidrAddress = "<CIDR2>" }
        # Add all your legacy trusted IPs here
    )
}

New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params
```

3. Update CA MFA policies to exclude the new Named Location
4. Test sign-in from each IP range
5. Clear out the legacy Trusted IPs once confirmed working

</details>

<details><summary>Fix 4 — Bulk create Named Locations from CSV</summary>

**Use case:** Onboarding a new site with many branch office IP ranges.

```powershell
<#
.SYNOPSIS  Bulk creates or updates Named Locations from a CSV file
.NOTES     CSV format: Name,CIDR,Trusted
           Example row: HeadOffice-London,203.0.113.0/24,TRUE
#>
Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess"

$csvPath = "<PathToCSV>"
$rows    = Import-Csv $csvPath

# Group by Name (one Named Location per unique Name)
$groups  = $rows | Group-Object -Property Name

foreach ($group in $groups) {
    $locationName = $group.Name
    $isTrusted    = $group.Group[0].Trusted -eq "TRUE"
    $ranges       = $group.Group | ForEach-Object {
        @{ "@odata.type" = "#microsoft.graph.iPv4CidrRange"; cidrAddress = $_.CIDR }
    }

    # Check if location already exists
    $existing = Get-MgIdentityConditionalAccessNamedLocation -All |
        Where-Object { $_.DisplayName -eq $locationName }

    if ($existing) {
        Write-Host "Updating existing location: $locationName" -ForegroundColor Yellow
        $params = @{
            "@odata.type" = "#microsoft.graph.ipNamedLocation"
            ipRanges      = $ranges
            isTrusted     = $isTrusted
        }
        Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId $existing.Id -BodyParameter $params
    } else {
        Write-Host "Creating new location: $locationName" -ForegroundColor Green
        $params = @{
            "@odata.type" = "#microsoft.graph.ipNamedLocation"
            displayName   = $locationName
            isTrusted     = $isTrusted
            ipRanges      = $ranges
        }
        New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params
    }
}
Write-Host "Done." -ForegroundColor Green
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects CA Named Location evidence for escalation or audit
.NOTES     Requires: Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Reports modules
#>
Connect-MgGraph -Scopes "Policy.Read.All","AuditLog.Read.All"

$upn        = "<UserUPN>"          # User experiencing the issue
$outputPath = "C:\Temp\CALocationEvidence_$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

# 1. All Named Locations
$locations = Get-MgIdentityConditionalAccessNamedLocation -All
$locReport = foreach ($loc in $locations) {
    [PSCustomObject]@{
        DisplayName  = $loc.DisplayName
        Id           = $loc.Id
        Type         = $loc.AdditionalProperties.'@odata.type'
        IsTrusted    = $loc.AdditionalProperties.isTrusted
        IPRanges     = ($loc.AdditionalProperties.ipRanges.cidrAddress -join '; ')
        Countries    = ($loc.AdditionalProperties.countriesAndRegions -join '; ')
    }
}
$locReport | Export-Csv "$outputPath\NamedLocations.csv" -NoTypeInformation

# 2. CA Policies with location conditions
$policies = Get-MgIdentityConditionalAccessPolicy -All | Where-Object { $_.State -eq "enabled" }
$policyReport = foreach ($p in $policies) {
    $locs = $p.Conditions.Locations
    if ($locs.IncludeLocations -or $locs.ExcludeLocations) {
        [PSCustomObject]@{
            PolicyName       = $p.DisplayName
            State            = $p.State
            IncludeLocations = ($locs.IncludeLocations -join '; ')
            ExcludeLocations = ($locs.ExcludeLocations -join '; ')
        }
    }
}
$policyReport | Export-Csv "$outputPath\CALocationPolicies.csv" -NoTypeInformation

# 3. Recent sign-ins for user
$signIns = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 20 |
    Select-Object CreatedDateTime, IpAddress, 
        @{N="City";E={$_.Location.City}},
        @{N="Country";E={$_.Location.CountryOrRegion}},
        ConditionalAccessStatus, AppDisplayName,
        @{N="CAResult";E={($_.AppliedConditionalAccessPolicies | ForEach-Object {"$($_.DisplayName):$($_.Result)"}) -join ' | '}}
$signIns | Export-Csv "$outputPath\RecentSignIns.csv" -NoTypeInformation

Write-Host "Evidence saved to: $outputPath" -ForegroundColor Green
Write-Host "`n=== NAMED LOCATIONS ===" -ForegroundColor Cyan
$locReport | Format-Table -AutoSize
Write-Host "`n=== CA POLICIES WITH LOCATION CONDITIONS ===" -ForegroundColor Cyan
$policyReport | Format-Table -AutoSize
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|-------------------|
| List all Named Locations | `Get-MgIdentityConditionalAccessNamedLocation -All` |
| Create new IP Named Location | `New-MgIdentityConditionalAccessNamedLocation -BodyParameter $params` |
| Update Named Location | `Update-MgIdentityConditionalAccessNamedLocation -NamedLocationId <id>` |
| Delete Named Location | `Remove-MgIdentityConditionalAccessNamedLocation -NamedLocationId <id>` |
| Check if IP is in CIDR | Use `Test-IPInCIDR` function above |
| Get user's current IP | `(Invoke-WebRequest -Uri "https://api64.ipify.org?format=text").Content` |
| View sign-in logs | Azure AD → Monitoring → Sign-in logs |
| Get sign-ins via Graph | `Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'"` |
| List CA policies with location | `Get-MgIdentityConditionalAccessPolicy -All` + filter conditions |
| Named Location limit | 2,000 locations, 2,000 CIDR ranges each |
| Check GeoIP for an IP | [https://ipinfo.io](https://ipinfo.io) or `Invoke-RestMethod -Uri "https://ipinfo.io/<ip>/json"` |

---

## 🎓 Learning Pointers

- **Named Locations are evaluated at sign-in time, not token use.** If a user signs in from a trusted IP and then moves to an untrusted network, their existing access token remains valid until expiry. CAE (Continuous Access Evaluation) can revoke tokens mid-session for some apps — but not all. Reference: [Continuous Access Evaluation](https://learn.microsoft.com/en-us/azure/active-directory/conditional-access/concept-continuous-access-evaluation)

- **Country blocks are friction, not security.** Any user on a VPN exiting in an unblocked country bypasses geography-based CA policies. Use country blocks for reducing noise (blocking sign-ins from countries you never operate in) rather than as a primary security control. Reference: [Conditional Access location conditions](https://learn.microsoft.com/en-us/azure/active-directory/conditional-access/location-condition)

- **"AllTrusted" is powerful but fragile.** CA policies using `AllTrusted` as an exclude condition will silently stop working if someone removes the Trusted flag from a Named Location. Audit Trusted flag changes via Azure AD audit logs: `Get-MgAuditLogDirectoryAudit -Filter "category eq 'Policy'"`.

- **IP Named Locations and Identity Protection interact.** Sign-ins from Trusted Named Locations get their risk score reduced by Microsoft Identity Protection. This means risk-based CA policies (requiring MFA for risky sign-ins) will be less likely to trigger from trusted IPs — even if the user's account is under attack. Review this trade-off for high-privileged accounts.

- **The 2,000 range limit per location can be a constraint for large enterprises.** If you have many branch offices, consider consolidating ranges with a supernet (e.g., use `10.0.0.0/8` instead of hundreds of individual /24s) if your IP space allows it. Reference: [Named Location limits](https://learn.microsoft.com/en-us/azure/active-directory/conditional-access/named-locations)

- **Legacy MFA Trusted IPs are being deprecated.** Any organization still relying on Per-User MFA Trusted IPs (in the old MFA portal) should migrate to CA Named Locations before the feature is removed. The migration is straightforward — export the legacy IPs and recreate them as a Named Location with `isTrusted = true`.
