<#
.SYNOPSIS
    Read-only audit of Microsoft Defender for Endpoint AI agent runtime protection readiness and configuration.

.DESCRIPTION
    Checks the local device against the full dependency chain for AI agent runtime protection
    (preview): Defender AV health/mode, signature version floor, current AiAgentProtection /
    AiAgentNetworkInspection settings, Tamper Protection state, presence of supported local AI
    agent binaries, and any recent local threat detections matching AI-agent/prompt-injection
    patterns.

    This script does NOT:
      - Enable, disable, or change AiAgentProtection / AiAgentNetworkInspection in any way
      - Confirm tenant-level licensing eligibility (Defender for Endpoint Plan 2 / M365 E5 /
        Microsoft Agent 365 / M365 E7) — no supported local API surfaces that; verify via the
        Microsoft 365 admin center or partner tooling
      - Confirm whether a specific installed agent VERSION actually exposes the vendor hook
        interface required for agent-native event inspection — cross-check the agent's own
        changelog/hooks documentation for that

    Intended for local execution (interactively or via Intune remediation/platform script in
    read-only/detection mode) as a triage aid before opening or escalating a ticket.

.PARAMETER OutputPath
    Folder to write the JSON evidence export to. Defaults to the current directory.

.EXAMPLE
    .\Get-AIAgentRuntimeProtectionAudit.ps1

    Runs the audit on the local device and writes a timestamped JSON evidence file to the
    current directory.

.EXAMPLE
    .\Get-AIAgentRuntimeProtectionAudit.ps1 -OutputPath 'C:\Temp\Evidence'

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+, Microsoft Defender Antivirus module
    (ConfigDefender) available (built into Windows).
    Run-as: Standard user is sufficient for all read operations used here.
    Safe/unsafe: Fully read-only. Makes no configuration changes.
    Signature floor referenced (1.451.224.0) and supported-agent list are current as of the
    AI agent runtime protection Learn documentation dated 2026-08-14 — this is an explicitly
    labeled PREVIEW feature and both may change; re-verify against
    https://learn.microsoft.com/en-us/defender-endpoint/ai-agent-runtime-protection-overview
    before treating this script's thresholds as permanently authoritative.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# Minimum signature version documented as required for runtime protection to function.
$script:SignatureFloor = [version]"1.451.224.0"

# Agent-native event inspection supported agents (binary name -> friendly name).
$script:SupportedAgents = [ordered]@{
    "claude" = "Claude Code"
    "codex"  = "Codex CLI"
    "gh"     = "GitHub CLI / GitHub Copilot CLI extension"
}

try {
    Write-Status "Starting AI agent runtime protection readiness audit on $env:COMPUTERNAME" "INFO"

    # --- Preflight: confirm Defender cmdlets are available ---
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        Write-Status "Get-MpComputerStatus not available — Microsoft Defender Antivirus module not present on this device. Aborting." "ERROR"
        return
    }

    # --- Detect: Defender AV health ---
    $mpStatus = Get-MpComputerStatus
    $amRunningMode = $mpStatus.AMRunningMode
    $rtpEnabled    = $mpStatus.RealTimeProtectionEnabled
    $sigVersionRaw = $mpStatus.AntivirusSignatureVersion
    $onboardState  = $mpStatus.OnboardingState

    $sigVersionParsed = $null
    try { $sigVersionParsed = [version]$sigVersionRaw } catch { $sigVersionParsed = $null }

    if ($amRunningMode -eq "Normal") {
        Write-Status "Defender AV running mode: Normal (active)" "OK"
    } else {
        Write-Status "Defender AV running mode: $amRunningMode — likely a third-party AV is primary. Runtime protection cannot enforce in this state." "WARN"
    }

    if ($rtpEnabled) {
        Write-Status "Real-time protection: Enabled" "OK"
    } else {
        Write-Status "Real-time protection: Disabled — prerequisite gap, unrelated to AI-agent config specifically." "WARN"
    }

    if ($sigVersionParsed -and $sigVersionParsed -ge $script:SignatureFloor) {
        Write-Status "Antivirus signature version: $sigVersionRaw (meets floor $script:SignatureFloor)" "OK"
    } else {
        Write-Status "Antivirus signature version: $sigVersionRaw — BELOW required floor $script:SignatureFloor. Runtime protection will silently no-op. Run Update-MpSignature." "WARN"
    }

    # --- Detect: current runtime protection configuration ---
    $mpPref = Get-MpPreference
    $aiAgentProtection        = $mpPref.AiAgentProtection
    $aiAgentNetworkInspection = $mpPref.AiAgentNetworkInspection

    if ([string]::IsNullOrEmpty($aiAgentProtection) -or $aiAgentProtection -eq "Disabled") {
        Write-Status "AiAgentProtection (agent-native event inspection): Disabled or not set" "WARN"
    } else {
        Write-Status "AiAgentProtection (agent-native event inspection): $aiAgentProtection" "OK"
    }

    if ([string]::IsNullOrEmpty($aiAgentNetworkInspection) -or $aiAgentNetworkInspection -eq "Disabled") {
        Write-Status "AiAgentNetworkInspection: Disabled or not set" "WARN"
    } else {
        Write-Status "AiAgentNetworkInspection: $aiAgentNetworkInspection" "OK"
    }

    # --- Detect: Tamper Protection ---
    $tamperProtected = $null
    try { $tamperProtected = $mpStatus.IsTamperProtected } catch { $tamperProtected = "Unknown" }
    Write-Status "Tamper Protection enabled: $tamperProtected" "INFO"

    # --- Detect: supported agent binaries present on this device ---
    $foundAgents = @()
    foreach ($binary in $script:SupportedAgents.Keys) {
        $cmd = Get-Command $binary -ErrorAction SilentlyContinue
        if ($cmd) {
            $foundAgents += [pscustomobject]@{
                Binary       = $binary
                FriendlyName = $script:SupportedAgents[$binary]
                Source       = $cmd.Source
                Version      = $cmd.Version
            }
            Write-Status "Supported agent found: $($script:SupportedAgents[$binary]) ($binary) at $($cmd.Source)" "INFO"
        }
    }
    if ($foundAgents.Count -eq 0) {
        Write-Status "No supported agent-native binaries (claude/codex/gh) found on PATH for the current user context. Note: GitHub Copilot app and non-PATH installs won't be detected by this heuristic." "INFO"
    }

    # --- Detect: recent local AI-agent-related threat detections ---
    $aiDetections = @()
    if (Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue) {
        $aiDetections = Get-MpThreatDetection | Where-Object { $_.ThreatName -match 'AiAgent|PromptInjection' } | Select-Object -First 20
        Write-Status "Recent local AI-agent-related threat detections: $($aiDetections.Count)" "INFO"
    }

    # --- Assemble evidence ---
    $evidence = [ordered]@{
        ComputerName              = $env:COMPUTERNAME
        Timestamp                 = (Get-Date).ToString("o")
        OnboardingState           = $onboardState
        AMRunningMode             = $amRunningMode
        RealTimeProtectionEnabled = $rtpEnabled
        AntivirusSignatureVersion = $sigVersionRaw
        SignatureFloorMet         = [bool]($sigVersionParsed -and $sigVersionParsed -ge $script:SignatureFloor)
        AiAgentProtection         = $aiAgentProtection
        AiAgentNetworkInspection  = $aiAgentNetworkInspection
        TamperProtectionEnabled   = $tamperProtected
        SupportedAgentsDetected   = $foundAgents
        RecentAIThreatDetections  = $aiDetections
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $exportFile = Join-Path $OutputPath "AIAgentRuntimeProtection-Audit-$($env:COMPUTERNAME)-$(Get-Date -f yyyyMMdd-HHmmss).json"
    $evidence | ConvertTo-Json -Depth 5 | Out-File -FilePath $exportFile -Encoding utf8

    Write-Status "Audit complete. Evidence exported to $exportFile" "OK"
    $evidence

} catch {
    Write-Status "Audit failed: $($_.Exception.Message)" "ERROR"
    throw
}
