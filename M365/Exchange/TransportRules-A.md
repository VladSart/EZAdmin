# Exchange Transport Rule Conflicts — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Covers ETR evaluation order, condition/exception logic, multi-rule interaction, and DLP overlap.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

| In scope | Out of scope |
|----------|-------------|
| Exchange Online Transport Rules (ETRs / mail flow rules) | General mail delivery / NDR troubleshooting (see `Mail-Flow-A.md`) |
| Rule priority ordering and `StopRuleProcessing` behaviour | On-premises Exchange transport agents (different pipeline) |
| Condition/exception logic (AND/OR semantics) | Third-party mail security gateway rule engines |
| Interaction between ETRs and Purview DLP policies | Full DLP policy authoring (see `Security/Purview/DLP-Policy-A.md`) |
| Rule Mode (Enforce / Test / AuditAndNotify) | Journal rules (related but distinct feature) |

**Assumptions:**
- You have Exchange Online admin rights or Global Admin, and (for DLP overlap checks) Compliance Administrator
- `ExchangeOnlineManagement` module v3+ installed
- `Connect-ExchangeOnline` already run in this session
- You understand basic mail flow (see `Mail-Flow-A.md` if not — this runbook assumes the message already reached the transport rule stage)

---

## How It Works

<details><summary>Full evaluation architecture (click to expand)</summary>

### Where ETRs sit in the pipeline

```
[EOP: connection filter → anti-spam → anti-malware]  (resolved before this runbook's scope)
         │
         ▼
[Transport Rule Agent — ETRs evaluated]
         │
         ▼
[Data Loss Prevention (DLP) — separate compliance pipeline]
         │
         ▼
[Journal rules, if configured]
         │
         ▼
[Mailbox delivery]
```

ETRs and DLP policies are both "transport-time" controls but they are **architecturally separate systems**:

| | Transport Rules (ETR) | DLP Policies |
|---|---|---|
| Managed in | Exchange admin center / `Get-TransportRule` | Microsoft Purview compliance portal / `Get-DlpCompliancePolicy` |
| Ordering field | `Priority` (integer, 0 = first) | `Priority` on the policy, independent numbering space from ETRs |
| Short-circuit mechanism | `StopRuleProcessing` | Policy/rule `Disabled` flag; no cross-system stop |
| Typical use | Routing, headers, disclaimers, redirect, reject | Sensitive-content detection (PII, PCI, PHI), classification labels |
| Interacts with the other system? | No native awareness of DLP state | No native awareness of ETR state |

This lack of mutual awareness is the single biggest source of "conflicting rule" tickets — engineers assume one system's priority governs the other, when in fact both evaluate independently and can both act on the same message.

### Rule evaluation order in detail

1. Exchange retrieves every **enabled** ETR (`State = Enabled`), sorted by `Priority` ascending.
2. For each rule, conditions are evaluated against the message.
   - **Different condition types are ANDed.** E.g. `SenderDomainIs` + `RecipientDomainIs` on the same rule means BOTH must be true.
   - **Multiple values within a single condition are ORed.** E.g. `SenderDomainIs @("a.com","b.com")` matches either domain.
   - **Exceptions are evaluated after conditions and always win.** Any exception match removes the message from that rule's scope regardless of how broadly conditions matched.
3. If conditions match (and no exception applies):
   - The rule's `Mode` determines behaviour:
     - `Enforce` — actions are applied for real.
     - `Test` — actions are simulated, no notification, no effect on mail flow.
     - `AuditAndNotify` — actions are simulated, a notification is sent to the configured recipient, no effect on mail flow.
   - If `StopRuleProcessing = $true` **and the rule is in Enforce mode**, no further ETR is evaluated for this message. Rules in Test/AuditAndNotify mode do NOT stop processing even if the flag is set — because they never truly acted in the first place.
4. If conditions don't match, evaluation proceeds to the next rule by Priority.
5. After all ETRs are evaluated (or short-circuited), the message proceeds to DLP evaluation independently.

### Multi-rule action stacking

When multiple rules match the same message (no `StopRuleProcessing` in between), their actions are applied in Priority order and stack. This is by design and useful — e.g. Rule 1 adds a compliance header, Rule 2 BCCs a compliance mailbox, Rule 3 appends a disclaimer. But it means the **order determines what each subsequent action sees**. A BCC that runs before a disclaimer is added will BCC a copy without the disclaimer.

</details>

---

## Dependency Stack

```
┌─────────────────────────────────────────────┐
│         Purview DLP Compliance Policies      │  Independent pipeline, own priority space
├─────────────────────────────────────────────┤
│      Transport Rule Agent (ETR engine)       │  Evaluates in Priority order, 0 = first
├─────────────────────────────────────────────┤
│   Individual Transport Rule (State/Mode)     │  Disabled = skipped; Test/Audit = no-op
├─────────────────────────────────────────────┤
│      Rule Conditions (AND across types)      │  Determines IF the rule matches
├─────────────────────────────────────────────┤
│      Rule Exceptions (always override)       │  Determines exclusions from a match
├─────────────────────────────────────────────┤
│   Rule Actions (Reject/Redirect/Header/etc)  │  What happens once matched
├─────────────────────────────────────────────┤
│         StopRuleProcessing flag              │  Governs whether lower-priority rules run
└─────────────────────────────────────────────┘
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Rule "does nothing" despite matching conditions | `Mode` is `Test` or `AuditAndNotify`, not `Enforce` | `Get-TransportRule -Identity <name> \| Select Mode` |
| Rule never appears to evaluate at all | Higher-priority rule with `StopRuleProcessing = $true` also matches | List all lower-Priority-number rules, check flag |
| Rule matches messages it shouldn't | Condition too broad (OR'd values wider than intended) or exception too narrow | `Format-List Conditions, Exceptions` |
| Rule misses messages it should catch | Exception too broad, or AND logic between condition types excludes valid cases | Same as above, re-derive intended logic from scratch |
| Two rules both act, producing unexpected combined result | Action stacking — Priority order determines sequence of application | `Sort-Object Priority \| Select Priority, Name, Actions` |
| Message blocked/encrypted unexpectedly, ETR looks fine | Overlapping Purview DLP policy acting independently | `Get-DlpCompliancePolicy`, `Get-DlpComplianceRule` |
| Rule worked yesterday, not today | Someone edited priority, conditions, or mode — check audit log | `Search-UnifiedAuditLog -Operations Set-TransportRule` |
| Regex condition (`SubjectMatchesPatterns`) inconsistent matches | Case sensitivity or anchoring assumptions wrong | Test regex independently against sample subjects |
| Rule fires for internal mail when meant for external only | Missing `SentToScope`/`FromScope` condition, or exception not covering internal aliases | Add explicit `-FromScope InOrganization` / `-SentToScope NotInOrganization` |
| Disclaimer/BCC copy missing expected content | Action order — a later action didn't see an earlier action's change | Reorder priorities so dependent actions run in the intended sequence |

---

## Validation Steps

**1. Enumerate every enabled rule in true evaluation order**
```powershell
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Sort-Object Priority |
  Select Priority, Name, Mode, StopRuleProcessing | Format-Table -AutoSize
# Good: the rule you're troubleshooting appears where you expect relative to others
# Bad:  a higher-priority (lower number) rule you didn't account for also matches your target messages
```

**2. Confirm Mode for the specific rule**
```powershell
Get-TransportRule -Identity "<RuleName>" | Select Name, Mode, State
# Good: Mode = Enforce
# Bad:  Mode = Test or AuditAndNotify — actions are simulated only
```

**3. Reconstruct the exact condition/exception logic**
```powershell
Get-TransportRule -Identity "<RuleName>" | Format-List Conditions, Exceptions, Actions
# Manually re-derive: which condition types are present (ANDed) and which have multiple
# values (ORed within that type). Write it out as a boolean expression before assuming
# a bug — most "logic errors" are the engineer's mental model, not the rule engine.
```

**4. Trace an actual affected message**
```powershell
$trace = Get-MessageTrace -SenderAddress <s> -RecipientAddress <r> -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date)
Get-MessageTraceDetail -MessageTraceId $trace[0].MessageTraceId -RecipientAddress <r> |
  Select Date, Event, Action, Detail | Format-Table -Wrap
# Good: Event = "Transport Rule", Detail names the expected rule
# Bad:  no Transport Rule event at all (never reached this stage, or short-circuited earlier)
```

**5. Check DLP overlap**
```powershell
Get-DlpCompliancePolicy | Select Name, Enabled, Mode
Get-DlpComplianceRule | Select Name, Policy, Disabled, BlockAccess | Format-Table -Wrap
# Good: no DLP rule scoped to the same recipients/content as your ETR
# Bad:  a DLP rule with BlockAccess=$true targeting overlapping content — it will act independently
```

**6. Confirm recent changes**
```powershell
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
  -Operations "New-TransportRule","Set-TransportRule","Remove-TransportRule","Enable-TransportRule","Disable-TransportRule" |
  Select CreationDate, UserIds, Operations | Sort-Object CreationDate -Descending | Format-Table -Wrap
# Good: no unexpected recent changes
# Bad:  a Set-TransportRule entry around the time the behaviour changed — check who and why
```

---

## Troubleshooting Steps by Phase

### Phase 1 — Establish what SHOULD happen vs what DID happen (5 min)
1. Write down the intended condition, exception, and action in plain English before looking at PowerShell output.
2. Run Validation Step 4 to see what the pipeline actually recorded for the specific message.
3. Compare — if they diverge, the gap tells you whether this is a Mode issue, a short-circuit, or a logic error.

### Phase 2 — Mode and enablement check (2 min)
1. Run Validation Step 2. If `Mode ≠ Enforce`, this is very likely the entire issue. Fix and re-test before going further.
2. Confirm `State = Enabled`. A rule can exist and look correctly configured while sitting disabled.

### Phase 3 — Priority and short-circuit audit (5 min)
1. Run Validation Step 1. Identify every enabled rule with a Priority number lower than the target rule.
2. For each, check `StopRuleProcessing` and whether its conditions could plausibly also match your test message.
3. If found, decide: reorder priorities, or narrow the upstream rule's conditions/exceptions. Document the decision — priority changes affect every message going forward, not just the one you're debugging.

### Phase 4 — Condition/exception logic reconstruction (10 min)
1. Run Validation Step 3. Write the AND/OR expression explicitly.
2. Test edge cases mentally: internal-to-internal, internal-to-external, external-to-internal, and any alias/subdomain variants.
3. If a regex condition is involved, test it in isolation against 3-5 real subject/body samples before trusting it in the rule.

### Phase 5 — DLP cross-check (5 min)
1. Run Validation Step 5.
2. If overlap exists, decide which system should own the behaviour — don't run duplicate/conflicting logic in both. Prefer DLP for sensitive-data-type detection (SSNs, credit cards, health data) and ETRs for routing/header/organizational logic.

### Phase 6 — Stage the fix safely
1. Any change to Reject, Redirect, BCC, or Mode should go through `AuditAndNotify` for 24-48h before `Enforce`, even for "obviously correct" fixes — regressions in transport rules are often silent.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Reorder priorities to resolve a short-circuit</summary>

**When:** A higher-priority rule with `StopRuleProcessing = $true` is silently preventing a lower-priority rule from ever running.

```powershell
# Confirm current order
Get-TransportRule | Sort-Object Priority | Select Priority, Name, StopRuleProcessing

# Record original priorities before changing anything (for rollback)
$before = Get-TransportRule | Select Name, Priority

# Move the intended rule ahead of the short-circuiting rule
Set-TransportRule -Identity "<RuleName>" -Priority 0

# Verify new order
Get-TransportRule | Sort-Object Priority | Select Priority, Name

# Re-test with a message matching both rules' conditions, confirm via message trace
```

**Rollback:** Reapply each rule's original `Priority` value from `$before`.

</details>

<details><summary>Playbook 2 — Move a rule from Test/Audit into production safely</summary>

**When:** A rule has been validated in `AuditAndNotify` and is ready for `Enforce`.

```powershell
# Confirm audit notifications have been reviewed and match set looks correct
Get-TransportRule -Identity "<RuleName>" | Select Name, Mode, Priority, Conditions

# Promote to Enforce
Set-TransportRule -Identity "<RuleName>" -Mode Enforce

# Monitor message trace for the next 24h for any unexpected NDRs or redirects
Get-MessageTrace -StartDate (Get-Date).AddHours(-24) -EndDate (Get-Date) |
  Where-Object { $_.Status -eq "Failed" } | Select Received, SenderAddress, RecipientAddress, Status
```

**Rollback:** `Set-TransportRule -Identity "<RuleName>" -Mode AuditAndNotify`

</details>

<details><summary>Playbook 3 — Resolve an ETR/DLP overlap</summary>

**When:** Both an ETR and a DLP policy act on the same message with conflicting or redundant results.

```powershell
# Identify the overlap
Get-DlpComplianceRule | Where-Object { $_.Policy -eq "<PolicyName>" } | Select Name, BlockAccess, NotifyUser

# Decide ownership — example: let DLP own sensitive-content blocking, narrow the ETR to exclude that scope
Set-TransportRule -Identity "<RuleName>" -ExceptIfHeaderContainsMessageHeader "X-MS-Exchange-Organization-SCL" -ExceptIfHeaderContainsWords "-1"

# Or, narrow the DLP rule to exclude a scope already handled by the ETR
Set-DlpComplianceRule -Identity "<DlpRuleName>" -ExceptIfRecipientDomainIs "partner-handled-by-etr.com"
```

**Rollback:** Remove the added exception clause from whichever side was modified.

</details>

<details><summary>Playbook 4 — Rebuild a rule's conditions from scratch (when patching keeps failing)</summary>

**When:** Repeated small edits haven't fixed a persistent over/under-matching problem.

```powershell
# Export the current rule definition for reference before rebuilding
Get-TransportRule -Identity "<RuleName>" | Export-Clixml "$env:USERPROFILE\Desktop\OldRule_$(Get-Date -Format yyyyMMdd).xml"

# Remove and recreate cleanly rather than layering more exceptions on a tangled rule
Remove-TransportRule -Identity "<RuleName>" -Confirm:$false

New-TransportRule -Name "<RuleName>" `
  -SenderDomainIs "contoso.com" `
  -ExceptIfSentToScope InOrganization `
  -PrependSubject "[EXTERNAL] " `
  -Mode AuditAndNotify `
  -Priority 0

# Validate in Audit for 24-48h, then promote per Playbook 2
```

**Rollback:** `Import-Clixml` the exported definition and recreate with `New-TransportRule` using its properties.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Exchange transport rule evidence for escalation or peer review
.NOTES     Run as Exchange admin. Requires ExchangeOnlineManagement module.
#>
param(
    [string]$OutputPath = "$env:USERPROFILE\Desktop\TransportRuleEvidence_$(Get-Date -Format yyyyMMdd_HHmm)"
)

Connect-ExchangeOnline -UserPrincipalName (Read-Host "Admin UPN")
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "[INFO] Collecting all transport rules in priority order..." -ForegroundColor Cyan
Get-TransportRule | Sort-Object Priority |
  Select Priority, Name, State, Mode, StopRuleProcessing, Conditions, Exceptions, Actions |
  Export-Csv "$OutputPath\TransportRules.csv" -NoTypeInformation

Write-Host "[INFO] Collecting DLP policies and rules..." -ForegroundColor Cyan
Get-DlpCompliancePolicy | Select Name, Enabled, Mode | Export-Csv "$OutputPath\DlpPolicies.csv" -NoTypeInformation
Get-DlpComplianceRule | Select Name, Policy, Disabled, BlockAccess, NotifyUser |
  Export-Csv "$OutputPath\DlpRules.csv" -NoTypeInformation

Write-Host "[INFO] Collecting recent transport rule change history (90 days)..." -ForegroundColor Cyan
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-90) -EndDate (Get-Date) `
  -Operations "New-TransportRule","Set-TransportRule","Remove-TransportRule","Enable-TransportRule","Disable-TransportRule" |
  Select CreationDate, UserIds, Operations |
  Export-Csv "$OutputPath\TransportRuleChangeHistory.csv" -NoTypeInformation

Write-Host "[OK] Evidence collected at: $OutputPath" -ForegroundColor Green
Disconnect-ExchangeOnline -Confirm:$false
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| List rules in evaluation order | `Get-TransportRule \| Sort-Object Priority \| Select Priority, Name, Mode, StopRuleProcessing` |
| Check a rule's Mode | `Get-TransportRule -Identity <name> \| Select Mode` |
| Full rule definition | `Get-TransportRule -Identity <name> \| Format-List *` |
| Promote to production | `Set-TransportRule -Identity <name> -Mode Enforce` |
| Stage for testing | `Set-TransportRule -Identity <name> -Mode AuditAndNotify` |
| Change priority | `Set-TransportRule -Identity <name> -Priority <n>` |
| Disable a rule | `Disable-TransportRule -Identity <name>` |
| Trace message through rules | `Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <r> \| Where Event -match "Transport Rule"` |
| List DLP policies | `Get-DlpCompliancePolicy \| Select Name, Enabled, Mode` |
| List DLP rules | `Get-DlpComplianceRule \| Select Name, Policy, BlockAccess` |
| Rule change history | `Search-UnifiedAuditLog -Operations Set-TransportRule,New-TransportRule,Remove-TransportRule` |
| Export rule before rebuild | `Get-TransportRule -Identity <name> \| Export-Clixml <path>` |

---

## 🎓 Learning Pointers

- **Mode is the single highest-leverage thing to check.** `Test` and `AuditAndNotify` exist specifically so engineers can validate a rule's match set before it can affect real mail — but this means a forgotten `Test` rule looks identical to a broken one from the outside. [MS Docs: Mail flow rule actions](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/mail-flow-rule-actions)
- **`StopRuleProcessing` only stops rules with a HIGHER priority number (lower precedence), and only when the stopping rule is in `Enforce` mode.** A rule sitting in Test/Audit mode with the flag set does not short-circuit anything, because it never truly matched in a production sense.
- **AND-across-types, OR-within-type is the exact semantics to internalize.** Engineers who assume everything is AND will under-scope exceptions; engineers who assume everything is OR will over-scope conditions. Write out the boolean expression before touching PowerShell. [MS Docs: Conditions and exceptions](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/conditions-and-exceptions)
- **ETRs and DLP policies are governed by entirely separate priority spaces and admin surfaces.** There is no built-in mechanism for one to defer to the other — overlap must be resolved manually by scoping one or both. See `Security/Purview/DLP-Policy-A.md` for the DLP side of this boundary.
- **Action order matters when actions are dependent on each other** (e.g. BCC before vs after a disclaimer is appended). Treat multi-rule sequences as a pipeline, not an unordered set — the same set of rules can produce different results purely by reordering priorities.
- **Stage every non-trivial change through `AuditAndNotify` for at least 24 hours**, particularly anything touching Reject, Redirect, or Quarantine actions. The blast radius of a bad transport rule (silently dropped or misrouted mail) is far larger and harder to detect than most other Exchange misconfigurations. [MS Docs: Manage mail flow rules](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/manage-mail-flow-rules)
