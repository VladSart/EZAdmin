# Exchange Transport Rule Conflicts — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers rules that "don't fire," rules that fire on the wrong messages, two rules fighting each other, and rules stuck in test mode.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# Connect first (skip if already connected)
Connect-ExchangeOnline -UserPrincipalName admin@contoso.com

# 1. List every enabled rule in evaluation order (lowest Priority number = evaluated first)
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Sort-Object Priority |
  Select Priority, Name, Mode, StopRuleProcessing | Format-Table -AutoSize

# 2. Check a specific rule's Mode — this is the #1 cause of "rule does nothing"
Get-TransportRule -Identity "<RuleName>" | Select Name, Mode, State, Priority

# 3. Confirm whether the affected message actually matched the rule
Get-MessageTraceDetail -MessageTraceId <guid> -RecipientAddress <recipient@domain.com> |
  Where-Object { $_.Event -match "Transport Rule|TransportRuleAgent" } |
  Select Date, Event, Detail

# 4. Check for StopRuleProcessing on any rule with a lower priority number than the one you expect to fire
Get-TransportRule | Where-Object { $_.StopRuleProcessing -eq $true } |
  Select Priority, Name, StopRuleProcessing | Sort-Object Priority

# 5. Check DLP policies — they evaluate in the same pipeline stage and can pre-empt an ETR
Get-DlpCompliancePolicy | Select Name, Enabled, Mode
```

**Interpret immediately:**

| Finding | Meaning | Go to |
|---------|---------|-------|
| `Mode = AuditAndNotify` or `Mode = Audit` | Rule is logging matches but NOT taking action | [Fix 1](#fix-1--rule-stuck-in-test-mode) |
| Rule not in the enabled list at all | Disabled, or deleted, or wrong tenant | [Fix 2](#fix-2--rule-disabled-or-missing) |
| A higher-priority (lower number) rule has `StopRuleProcessing = $true` and also matches | That rule wins; your rule never evaluates | [Fix 3](#fix-3--stoprule processing-short-circuit) |
| `Get-MessageTraceDetail` shows no `Transport Rule` event at all | Message never reached the transport rule stage — check EOP/anti-spam first | See Mail-Flow-B.md |
| Two rules both match and both act (e.g. one adds a header, another redirects) | Order-dependent conflict — check Priority | [Fix 4](#fix-4--conflicting-actions-from-two-rules) |
| Rule condition uses `-except` incorrectly, matching more or less than intended | Condition/exception logic error | [Fix 5](#fix-5--conditionexception-logic-error) |
| DLP policy and ETR both target the same content | DLP evaluates independently — can double-act or contradict the ETR | [Fix 6](#fix-6--dlp-and-etr-fighting-each-other) |

---

## Dependency Cascade

<details><summary>What must be true for a transport rule to fire the way you expect</summary>

```
[Message enters transport pipeline]
         │
         ▼
[EOP anti-spam / anti-malware — already resolved before this stage]
         │
         ▼
[Transport Rules (ETRs) evaluated in Priority order — lowest number first]
  ✗ Rule.State = Disabled → skipped entirely
  ✗ Rule.Mode = Audit/AuditAndNotify → conditions match but NO action taken, only logged
         │
         ├─ Rule 1 (Priority 0) evaluates conditions
         │     ✗ StopRuleProcessing = $true AND conditions match → ALL LOWER-PRIORITY RULES SKIPPED
         │     ✓ conditions match, StopRuleProcessing = $false → action applies, continue to next rule
         │     ✓ conditions don't match → continue to next rule
         │
         ├─ Rule 2 (Priority 1) evaluates conditions
         │     (same logic — every enabled rule evaluates unless short-circuited above)
         │
         └─ Rule N (Priority N) evaluates conditions
         │
         ▼
[Data Loss Prevention (DLP) policies evaluated — SEPARATE pipeline stage, runs regardless of ETR outcome]
  ✗ DLP policy targets same content as an ETR → can independently block/encrypt/notify
         │
         ▼
[Final action set: combination of all matched rule actions + DLP actions, applied in order]
         │
         ▼
[Mailbox delivery — or Reject/Redirect/Quarantine short-circuits before this point]
```

**Key facts that explain most "conflicts":**
- Rules run in **Priority order**, lowest number first. Priority 0 always evaluates before Priority 1.
- `StopRuleProcessing = $true` on a matching rule prevents every rule below it (higher Priority number) from ever evaluating — not just from acting.
- Multiple rules **can** all fire on the same message if none of them stop processing. Their actions stack.
- DLP policies are a **separate system** from transport rules. They evaluate independently and are not ordered relative to ETRs by the same Priority field.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm the rule is even enabled and not in test mode**
```powershell
Get-TransportRule -Identity "<RuleName>" | Select Name, State, Mode, Priority, StopRuleProcessing
```
> `Mode` must be `Enforce` for the rule to actually take action. `Audit` and `AuditAndNotify` only log matches — this is the single most common reason a "working" rule appears to do nothing.

**Step 2 — List every rule with a lower Priority number (evaluates before yours)**
```powershell
$myPriority = (Get-TransportRule -Identity "<RuleName>").Priority
Get-TransportRule | Where-Object { $_.State -eq "Enabled" -and $_.Priority -lt $myPriority } |
  Select Priority, Name, StopRuleProcessing, Conditions | Sort-Object Priority | Format-Table -Wrap
```
> Any rule here with `StopRuleProcessing = $true` that ALSO matches the same message will prevent your rule from ever running.

**Step 3 — Confirm what actually happened to the specific message**
```powershell
$trace = Get-MessageTrace -SenderAddress <sender> -RecipientAddress <recipient> -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date)
Get-MessageTraceDetail -MessageTraceId $trace[0].MessageTraceId -RecipientAddress <recipient> |
  Select Date, Event, Action, Detail | Format-Table -Wrap
```
> Look for `Event = "Transport Rule"` or `TransportRuleAgent` — the `Detail` field names which rule(s) actually fired.

**Step 4 — Re-check the rule's own conditions and exceptions for logic errors**
```powershell
Get-TransportRule -Identity "<RuleName>" | Format-List Name, Conditions, Exceptions, Actions
```
> Conditions between different property types (e.g. SenderDomainIs + RecipientDomainIs) are ANDed together. Multiple values within the SAME condition (e.g. two domains in one SenderDomainIs) are ORed. Mixing these up is the #1 cause of a rule matching too much or too little.

**Step 5 — Check for DLP policy overlap**
```powershell
Get-DlpCompliancePolicy | Select Name, Enabled, Mode, Priority
Get-DlpComplianceRule | Select Name, Policy, Disabled | Format-Table -Wrap
```
> If a DLP rule targets the same sensitive content or recipients as your ETR, both will act — DLP does not respect ETR `StopRuleProcessing`.

**Step 6 — Test in isolation (safe, non-destructive)**
```powershell
# Temporarily set the rule to Audit mode to see what WOULD have matched, without affecting mail flow
Set-TransportRule -Identity "<RuleName>" -Mode AuditAndNotify

# Send a test message matching the intended conditions, then check:
Get-MessageTraceDetail -MessageTraceId <new-guid> -RecipientAddress <recipient> |
  Where-Object { $_.Event -match "Transport Rule" }

# Revert once confirmed
Set-TransportRule -Identity "<RuleName>" -Mode Enforce
```

---

## Common Fix Paths

<details id="fix-1"><summary>Fix 1 — Rule stuck in test mode</summary>

**Symptom:** Rule conditions match (confirmed via trace) but no action (redirect, reject, header) actually applies.

```powershell
Get-TransportRule -Identity "<RuleName>" | Select Name, Mode

# Mode values:
#   Enforce           → conditions matched, actions applied (production behaviour)
#   Test              → actions NOT applied, no notification
#   AuditAndNotify    → actions NOT applied, notification email sent to configured address

# Fix: switch to Enforce once verified in Test/Audit
Set-TransportRule -Identity "<RuleName>" -Mode Enforce
```

> Best practice: always create new/edited rules in `AuditAndNotify` first, verify the match set is correct for 24-48h, then switch to `Enforce`. Do not skip this step for anything touching Reject or Redirect actions.

</details>

<details id="fix-2"><summary>Fix 2 — Rule disabled or missing</summary>

**Symptom:** Rule doesn't appear in `Get-TransportRule` output, or `State = Disabled`.

```powershell
# Confirm it isn't just disabled
Get-TransportRule -Identity "<RuleName>" | Select Name, State

# Re-enable
Enable-TransportRule -Identity "<RuleName>"

# If it truly doesn't exist, check the audit log for who deleted it and when
Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
  -Operations "Remove-TransportRule","New-TransportRule","Set-TransportRule" |
  Select CreationDate, UserIds, Operations | Format-Table -Wrap
```

</details>

<details id="fix-3"><summary>Fix 3 — StopRuleProcessing short-circuit</summary>

**Symptom:** Your rule's conditions clearly match the message, but the rule never appears in the trace's Transport Rule events at all.

```powershell
# Find every enabled rule with a LOWER priority number that also has StopRuleProcessing = $true
Get-TransportRule | Where-Object { $_.State -eq "Enabled" -and $_.StopRuleProcessing -eq $true } |
  Select Priority, Name | Sort-Object Priority

# Inspect the suspect upstream rule's conditions to confirm it's catching your message too
Get-TransportRule -Identity "<UpstreamRuleName>" | Format-List Conditions, Exceptions

# Fix A: re-order priorities so the intended rule runs first
Set-TransportRule -Identity "<RuleName>" -Priority 0

# Fix B: narrow the upstream rule's conditions or remove its StopRuleProcessing flag
Set-TransportRule -Identity "<UpstreamRuleName>" -StopRuleProcessing $false
```

> Rollback: priority changes are reversible instantly — note the original priority number before changing.

</details>

<details id="fix-4"><summary>Fix 4 — Conflicting actions from two rules</summary>

**Symptom:** Message gets two contradictory actions (e.g. one rule adds a disclaimer, another rule blind-copies it before the disclaimer is added, so the BCC misses it) — or one rule's action undoes another's.

```powershell
# List all enabled rules with their full action set, in evaluation order
Get-TransportRule | Where-Object { $_.State -eq "Enabled" } |
  Sort-Object Priority | Select Priority, Name, Actions | Format-Table -Wrap

# Actions apply cumulatively in Priority order. A rule that appends a disclaimer AFTER
# a rule that BCCs the original message will mean the BCC copy lacks the disclaimer.

# Fix: re-order so dependent actions happen in the correct sequence
Set-TransportRule -Identity "Add Disclaimer" -Priority 0
Set-TransportRule -Identity "BCC Compliance" -Priority 1
```

</details>

<details id="fix-5"><summary>Fix 5 — Condition/exception logic error</summary>

**Symptom:** Rule matches messages it shouldn't, or misses messages it should catch.

```powershell
Get-TransportRule -Identity "<RuleName>" | Format-List Conditions, Exceptions

# Common mistakes:
# 1. Exception too narrow — e.g. ExceptIfSenderDomainIs "contoso.com" doesn't cover subdomains
#    or aliases on a different accepted domain in the same tenant
# 2. Multiple SenderDomainIs values are OR'd — adding a second domain WIDENS the match, it doesn't narrow it
# 3. Regex conditions (SubjectMatchesPatterns) are case-sensitive by default in some builds —
#    test with actual sample subject lines, don't assume
# 4. Attachment content conditions (AttachmentContainsWords) only scan supported file types —
#    confirm the format is on the supported list before assuming the condition is broken

# Fix: rebuild the condition explicitly rather than patching
Set-TransportRule -Identity "<RuleName>" `
  -SenderDomainIs "contoso.com" `
  -ExceptIfSentToScope InOrganization

# Always test edits in AuditAndNotify mode first (see Diagnosis Step 6)
```

</details>

<details id="fix-6"><summary>Fix 6 — DLP and ETR fighting each other</summary>

**Symptom:** A message gets blocked or encrypted unexpectedly even though the relevant transport rule looks correct — or vice versa, a DLP-protected pattern still reaches the recipient.

```powershell
# List active DLP policies and their rules
Get-DlpCompliancePolicy | Select Name, Enabled, Mode
Get-DlpComplianceRule | Select Name, Policy, Disabled, BlockAccess, NotifyUser | Format-Table -Wrap

# DLP and Transport Rules are independent pipelines — there is no shared StopRuleProcessing between them.
# If both target overlapping content (e.g. credit card numbers), BOTH will attempt to act.

# Fix: scope one system out of the overlap explicitly. Easiest is to exclude the DLP rule's
# scope from a location/recipient already handled by the ETR:
Set-DlpComplianceRule -Identity "<DlpRuleName>" -ExceptIfRecipientDomainIs "trusted-partner.com"

# Or, if the ETR should defer to DLP entirely, disable the overlapping ETR condition:
Disable-TransportRule -Identity "<RuleName>"
```

> DLP policies are managed in Microsoft Purview, not the Exchange admin center — check both consoles when troubleshooting overlap. See `Security/Purview/DLP-Policy-A.md` for DLP-specific dependency chain.

</details>

---

## Escalation Evidence

```
Transport Rule Conflict — Evidence Pack
========================================
Tenant:
Rule name(s) involved:
Priority number(s):
Mode (Enforce/Test/AuditAndNotify) for each:
StopRuleProcessing value for each:
Affected sender/recipient:
MessageTraceId:
Get-MessageTraceDetail Transport Rule events (paste):
Full Conditions/Exceptions for each rule (paste Format-List output):
Any overlapping DLP policy name(s):
Expected behaviour:
Actual behaviour:
Change history (Search-UnifiedAuditLog output, last 30 days):
```

---

## 🎓 Learning Pointers

- **`Mode` is the first thing to check, always.** A rule left in `Test` or `AuditAndNotify` after initial creation is the single most common "why isn't my rule working" ticket. Build a habit of confirming `Mode = Enforce` before troubleshooting anything deeper. [MS Docs: Mail flow rule actions](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/mail-flow-rule-actions)
- **Priority order is absolute, not advisory.** `StopRuleProcessing` on any matching rule with a lower Priority number is a hard stop — rules below it never even evaluate their own conditions. Always check for this before assuming a rule's conditions are wrong.
- **Conditions across different fields AND together; multiple values within one field OR together.** This is the most misunderstood part of ETR logic and the root cause of most over/under-matching. [MS Docs: Mail flow rule conditions and exceptions](https://learn.microsoft.com/en-us/exchange/security-and-compliance/mail-flow-rules/conditions-and-exceptions)
- **DLP and Transport Rules are architecturally separate.** They share the transport pipeline conceptually but are configured, prioritized, and evaluated independently (DLP in Purview, ETRs in EAC/PowerShell). Never assume disabling one automatically defers to the other.
- **Always stage rule changes through `AuditAndNotify` before `Enforce`**, especially for anything with Reject, Redirect, or BCC actions — these are the actions most likely to cause silent, hard-to-diagnose mail loss if the conditions are wrong.
- **`Search-UnifiedAuditLog` is your best friend for "who changed this rule and when."** Transport rule changes are logged there for 90 days by default (longer with E5/Purview Audit Premium) — check it before assuming a rule was always broken.
