# EZAdmin

A collection of PowerShell scripts and troubleshooting runbooks for Windows and M365 administration.
Targeted at Intune/Entra ID environments. Use at your own risk — nothing is guaranteed in IT.

---

## Structure

```
EzAdmin/
├── Autopilot/
│   ├── Scripts/                        # Enrollment, hash upload, diagnostics
│   └── Troubleshooting/                # Network connectivity and triage scripts
├── Intune/
│   └── IntuneChecker.ps1               # Checks Intune enrollment and compliance state
├── Windows/
│   ├── Scripts/                        # Update tools, VBS, USB diagnostics, app setup
│   └── Troubleshooting/
│       ├── Time/                       # Time sync runbooks (A = verbose, B = ops)
│       └── Windows Update/             # WU and WSUS→WfUB runbooks
├── M365/
│   ├── Calendar-Permission-Delegation.ps1
│   └── Disable-OneDrive-Shortcuts.ps1
├── Modules/
│   └── PsAdminModules.ps1              # Ensures required PS modules are present
└── LLM/
    └── Prompt/                         # Prompt templates for generating runbooks and scripts
        └── Archive/                    # Old prompt versions
```

---

## Runbook Formats

Troubleshooting docs come in two flavours:

- **A — Reference / Verbose** — full depth, explains why, for L2/L3 or future-you at 2am
- **B — Ops / Short** — skim-first, triage-first, fix or escalate in under 10 minutes

---

## Generating New Docs

Use the templates in `LLM/Prompt/`:

| File | Use for |
|------|---------|
| `Troubleshooting.md` | Generate A or B runbooks for any Windows/M365 issue |
| `PowerShellScriptPrompt.md` | Generate production-grade PS scripts with preflight, logging, rollback |
