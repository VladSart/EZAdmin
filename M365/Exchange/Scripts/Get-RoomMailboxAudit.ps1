<#
.SYNOPSIS
    Fleet-wide audit of Exchange Online room/resource mailboxes — booking policy gaps, calendar
    processing misconfiguration, and the Entra sign-in security risk called out in the runbooks.

.DESCRIPTION
    Companion script for RoomMailbox-B.md / RoomMailbox-A.md. Automates the Triage and Diagnosis &
    Validation Flow steps across every room mailbox (or a target set) instead of the runbooks'
    one-room-at-a-time walkthrough.

    Checks and flags, per room:
    - WRONG_MAILBOX_TYPE: RecipientTypeDetails is not RoomMailbox despite ResourceType=Room, or vice
      versa — the "object created wrong" case from the Symptom → Cause table (Fix 6)
    - NO_BOOKING_PATH: AllBookInPolicy is $false AND BookInPolicy is empty — nobody can book the room
      directly, the single most common root cause of blanket booking declines (Learning Pointers)
    - NOT_AUTO_ACCEPT: AutomateProcessing is not AutoAccept — bookings require manual delegate
      approval or go straight to an inbox, which reads to end users as "the room is broken"
    - HIDDEN_FROM_GAL: HiddenFromAddressListsEnabled=$true — informational; confirm this is
      intentional rather than the reason a room "doesn't exist" for users searching in Outlook/Teams
    - ZERO_CAPACITY: ResourceCapacity is 0 or unset — can cause capacity-based scheduling assistant
      warnings even when the room is otherwise bookable
    - SIGNIN_NOT_BLOCKED (requires -CheckEntraSignIn + Microsoft.Graph.Users module): the room's
      associated Entra account has AccountEnabled=$true — a standing security risk the runbook's
      Learning Pointers flags as something to verify for every room in the tenant
    - CALENDAR_PERMISSION_NONE: Calendar folder Default permission is None instead of the expected
      AvailabilityOnly — causes "No information" in the scheduling assistant even for otherwise
      healthy rooms

    Does NOT cover:
    - Changing calendar processing, booking policy, or mailbox type (this script is read-only; apply
      Fix 2/Fix 3/Fix 6 manually after reviewing findings, since AllBookInPolicy/BookInPolicy changes
      and Set-Mailbox -Type conversions are organisational decisions, not blanket fixes)
    - Hybrid on-premises room mailboxes (on-prem CalendarProcessing requires on-prem Exchange
      PowerShell, out of scope for an Exchange Online-connected session)

.PARAMETER Room
    One or more room mailboxes (UPN, alias, or display name) to audit. Accepts pipeline input.
    Defaults to ALL room mailboxes if not specified.

.PARAMETER CheckEntraSignIn
    Switch. Also checks whether each room's associated Entra account has sign-in blocked
    (AccountEnabled=$false), per the runbook's security Learning Pointer. Requires Microsoft.Graph.Users
    and an active Connect-MgGraph session with User.Read.All.

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\RoomMailboxAudit-<timestamp>.csv

.EXAMPLE
    .\Get-RoomMailboxAudit.ps1

.EXAMPLE
    .\Get-RoomMailboxAudit.ps1 -Room "boardroom-3@contoso.com" -CheckEntraSignIn

.NOTES
    Requires: Exchange Online module (ExchangeOnlineManagement) v3.0+; Microsoft.Graph.Users for
    -CheckEntraSignIn
    Permissions: Exchange Administrator or View-Only Recipients (read-only cmdlets used); User.Read.All
    (Graph) for -CheckEntraSignIn
    Run-as: Connect-ExchangeOnline (and Connect-MgGraph if using -CheckEntraSignIn) before running
    Safe: Read-only. Makes no changes to any mailbox, calendar processing, or Entra account.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Room,

    [switch]$CheckEntraSignIn,

    [string]$OutputPath = "C:\Temp\RoomMailboxAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Preflight
Write-Status "Checking Exchange Online connection..."
Try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Status "Exchange Online connected" -Status "OK"
} Catch {
    Write-Status "Not connected to Exchange Online. Run: Connect-ExchangeOnline" -Status "ERROR"
    Exit 1
}

If ($CheckEntraSignIn) {
    Try {
        $null = Get-MgContext -ErrorAction Stop
        Write-Status "Microsoft Graph connected" -Status "OK"
    } Catch {
        Write-Status "-CheckEntraSignIn requires an active Connect-MgGraph session — skipping that check" -Status "WARN"
        $CheckEntraSignIn = $false
    }
}

New-Item -Path (Split-Path $OutputPath) -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

# Resolve rooms
Write-Status "Resolving room mailboxes..."
$rooms = @()
If ($Room) {
    ForEach ($r in $Room) {
        Try {
            $rooms += Get-Mailbox -Identity $r -ErrorAction Stop
        } Catch {
            Write-Status "Could not find mailbox: $r — skipping" -Status "WARN"
        }
    }
} Else {
    $rooms = Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited
}

Write-Status "Auditing $($rooms.Count) room mailbox(es)..."

$findings = [System.Collections.Generic.List[string]]::new()
$results  = [System.Collections.Generic.List[PSObject]]::new()

ForEach ($rm in $rooms) {

    $record = [ordered]@{
        DisplayName           = $rm.DisplayName
        PrimarySmtpAddress    = $rm.PrimarySmtpAddress
        RecipientTypeDetails  = $rm.RecipientTypeDetails
        ResourceType          = $rm.ResourceType
        ResourceCapacity      = $rm.ResourceCapacity
        HiddenFromGAL         = $rm.HiddenFromAddressListsEnabled
        AutomateProcessing    = $null
        AllBookInPolicy       = $null
        BookInPolicyCount     = $null
        EntraSignInBlocked    = $null
        CalendarDefaultPerm   = $null
        Flags                 = ""
    }

    $flags = @()

    If ($rm.RecipientTypeDetails -ne "RoomMailbox") {
        $flags += "WRONG_MAILBOX_TYPE"
        $findings.Add("WRONG_MAILBOX_TYPE: $($rm.DisplayName) is RecipientTypeDetails=$($rm.RecipientTypeDetails)")
    }

    If (-not $rm.ResourceCapacity -or $rm.ResourceCapacity -eq 0) {
        $flags += "ZERO_CAPACITY"
    }

    If ($rm.HiddenFromAddressListsEnabled) {
        $flags += "HIDDEN_FROM_GAL"
    }

    # Calendar processing
    Try {
        $cp = Get-CalendarProcessing -Identity $rm.Identity -ErrorAction Stop
        $record.AutomateProcessing = $cp.AutomateProcessing
        $record.AllBookInPolicy    = $cp.AllBookInPolicy
        $record.BookInPolicyCount  = ($cp.BookInPolicy | Measure-Object).Count

        If ($cp.AutomateProcessing -ne "AutoAccept") {
            $flags += "NOT_AUTO_ACCEPT"
        }

        If (-not $cp.AllBookInPolicy -and $record.BookInPolicyCount -eq 0) {
            $flags += "NO_BOOKING_PATH"
            $findings.Add("NO_BOOKING_PATH: $($rm.DisplayName) has AllBookInPolicy=`$false and an empty BookInPolicy — nobody can book directly")
        }
    } Catch {
        $flags += "CALENDAR_PROCESSING_QUERY_FAILED"
    }

    # Calendar folder default permission
    Try {
        $calPerm = Get-MailboxFolderPermission -Identity "$($rm.PrimarySmtpAddress):\Calendar" -ErrorAction Stop
        $defaultPerm = ($calPerm | Where-Object { $_.User.DisplayName -eq "Default" }).AccessRights -join ','
        $record.CalendarDefaultPerm = $defaultPerm
        If ($defaultPerm -eq "None") {
            $flags += "CALENDAR_PERMISSION_NONE"
            $findings.Add("CALENDAR_PERMISSION_NONE: $($rm.DisplayName) Calendar Default permission is None — scheduling assistant will show 'No information'")
        }
    } Catch {
        # Non-fatal — some tenants restrict this query
    }

    # Optional Entra sign-in check
    If ($CheckEntraSignIn) {
        Try {
            $mgUser = Get-MgUser -UserId $rm.ExternalDirectoryObjectId -Property AccountEnabled -ErrorAction Stop
            $record.EntraSignInBlocked = -not $mgUser.AccountEnabled
            If ($mgUser.AccountEnabled) {
                $flags += "SIGNIN_NOT_BLOCKED"
                $findings.Add("SIGNIN_NOT_BLOCKED: $($rm.DisplayName)'s Entra account has AccountEnabled=`$true — sign-in should be blocked for room accounts")
            }
        } Catch {
            # Non-fatal — account may not resolve via this property set
        }
    }

    $record.Flags = ($flags -join ', ')
    $results.Add([PSCustomObject]$record)
}

# Summary
Write-Host ""
Write-Status "=== SUMMARY ===" -Status "OK"

$summary = @{
    WrongType          = ($results | Where-Object { $_.Flags -match "WRONG_MAILBOX_TYPE" }).Count
    NoBookingPath      = ($results | Where-Object { $_.Flags -match "NO_BOOKING_PATH" }).Count
    NotAutoAccept      = ($results | Where-Object { $_.Flags -match "NOT_AUTO_ACCEPT" }).Count
    SignInNotBlocked   = ($results | Where-Object { $_.Flags -match "SIGNIN_NOT_BLOCKED" }).Count
    CalendarPermNone   = ($results | Where-Object { $_.Flags -match "CALENDAR_PERMISSION_NONE" }).Count
}

Write-Host "  Wrong mailbox type:                $($summary.WrongType)"
Write-Host "  No direct booking path:            $($summary.NoBookingPath)"
Write-Host "  Not set to AutoAccept:             $($summary.NotAutoAccept)"
Write-Host "  Calendar Default permission=None:  $($summary.CalendarPermNone)"
If ($CheckEntraSignIn) {
    Write-Host "  Entra sign-in NOT blocked:         $($summary.SignInNotBlocked)"
}

If ($summary.SignInNotBlocked -gt 0) {
    Write-Status "$($summary.SignInNotBlocked) room account(s) can sign in interactively — this is a standing security risk, verify and block" -Status "WARN"
}
If ($summary.NoBookingPath -gt 0) {
    Write-Status "$($summary.NoBookingPath) room(s) have no direct booking path — check AllBookInPolicy/BookInPolicy" -Status "WARN"
}

$results | Where-Object { $_.Flags -ne "" } | Format-Table DisplayName, RecipientTypeDetails, AutomateProcessing, Flags -AutoSize

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" -Status "OK"
