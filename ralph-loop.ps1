<#>
.SYNOPSIS
    Ralph Loop Orchestration Script - PowerShell Implementation
    Cross-platform orchestration for the Ralph Loop iterative development technique
    For Windows (PowerShell 5.1+ / PowerShell 7+)

.DESCRIPTION
    Orchestrates the Ralph Loop by running worker and reviewer phases with different LLM models,
    using the MCP server for state management.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration
$script:McpServerCmd = $env:RALPH_MCP_SERVER ?? '.\ralph-loop-mcp.ps1'
$script:DefaultMaxIterations = 10

# Configuration from environment or prompts
$script:WorkerModel = $env:RALPH_WORKER_MODEL ?? ''
$script:WorkerProvider = $env:RALPH_WORKER_PROVIDER ?? ''
$script:ReviewerModel = $env:RALPH_REVIEWER_MODEL ?? ''
$script:ReviewerProvider = $env:RALPH_REVIEWER_PROVIDER ?? ''
$script:MaxIterations = [int]($env:RALPH_MAX_ITERATIONS ?? $script:DefaultMaxIterations)
$script:TaskInput = $args[0] ?? ''

# Helper: Null-coalescing for PS 5.1
function Coalesce { param($Value, $Default); if ($null -ne $Value -and $Value -ne '') { return $Value }; return $Default }

# Colors
$Red = 'Red'; $Green = 'Green'; $Yellow = 'Yellow'; $Blue = 'Cyan'; $Gray = 'Gray'
function Write-Color { param([string]$Message, [ConsoleColor]$Color = 'White'); Write-Host $Message -ForegroundColor $Color }

function Write-Header {
    Write-Color "═══════════════════════════════════════════════════════════════" $Blue
    Write-Color "  Ralph Loop - Multi-Model Edition" $Blue
    Write-Color "═══════════════════════════════════════════════════════════════" $Blue
    Write-Host ""
}

function Write-Step { param([string]$Message); Write-Host ""; Write-Color "───────────────────────────────────────────────────────────────" $Blue; Write-Color "  $Message" $Blue; Write-Color "───────────────────────────────────────────────────────────────" $Blue; Write-Host "" }

function Call-Mcp {
    param([string]$Method, [string]$Params, [string]$SessionId)
    $request = "{\"jsonrpc\":\"2.0\",\"id\":$(Get-Random -Maximum 2147483647),\"method\":\"tools/call\",\"params\":{\"name\":\"$Method\",\"arguments\":$Params}}"
    $result = $request | & $script:McpServerCmd 2>$null | Select-Object -Last 1
    return $result
}

function Call-McpInit {
    $request = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ralph-loop","version":"1.0"}}}'
    $request | & $script:McpServerCmd 2>$null | Select-Object -First 1
}

function Prompt-Config {
    if (-not $script:WorkerModel) {
        Write-Host -NoNewline "$($Blue)Worker model$($Gray): "
        $script:WorkerModel = Read-Host
        if (-not $script:WorkerModel) { Write-Color "Error: Worker model is required" $Red; exit 1 }
    }
    if (-not $script:WorkerProvider) {
        Write-Host -NoNewline "$($Blue)Worker provider$($Gray) (anthropic/openai/google/goose): "
        $script:WorkerProvider = Read-Host
        if (-not $script:WorkerProvider) { Write-Color "Error: Worker provider is required" $Red; exit 1 }
    }
    if (-not $script:ReviewerModel) {
        Write-Host -NoNewline "$($Blue)Reviewer model$($Gray) (should be different from worker): "
        $script:ReviewerModel = Read-Host
        if (-not $script:ReviewerModel) { Write-Color "Error: Reviewer model is required" $Red; exit 1 }
    }
    if (-not $script:ReviewerProvider) {
        Write-Host -NoNewline "$($Blue)Reviewer provider$($Gray) (anthropic/openai/google/goose): "
        $script:ReviewerProvider = Read-Host
        if (-not $script:ReviewerProvider) { Write-Color "Error: Reviewer provider is required" $Red; exit 1 }
    }
    if ($script:WorkerModel -eq $script:ReviewerModel -and $script:WorkerProvider -eq $script:ReviewerProvider) {
        Write-Color "Warning: Worker and reviewer are the same model/provider." $Yellow
        Write-Host "For best results, use different models for cross-model review."
        Write-Host -NoNewline "Continue anyway? [y/N]: "
        $confirm = Read-Host
        if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
    }
    Write-Host -NoNewline "$($Blue)Max iterations$($Gray) [$($script:DefaultMaxIterations)]: "
    $input = Read-Host
    if ($input) { $script:MaxIterations = [int]$input }
}

function Get-Task {
    if (Test-Path $script:TaskInput) { return Get-Content $script:TaskInput -Raw }
    elseif ($script:TaskInput) { return $script:TaskInput }
    return $null
}

function Call-WorkerLlm {
    param([string]$Task, [string]$Feedback, [int]$Iteration, [string]$SessionId)
    
    $prompt = @"
You are the WORKER in a Ralph Loop iteration $Iteration.

Task: $Task
"@
    
    if ($Feedback) {
        $prompt += @"

Previous feedback from reviewer: $Feedback

Please revise your work based on this feedback.
"@
    }
    
    $prompt += @"

Provide your complete work output and a brief summary.
Output format:
WORK:
[your complete work here]

SUMMARY:
[brief summary of what you did]
"@

    switch ($script:WorkerProvider) {
        'anthropic' { return $prompt | claude --model $script:WorkerModel --print 2>$null }
        'openai'    { return $prompt | openai chat --model $script:WorkerModel 2>$null }
        'google'    { return $prompt | gemini --model $script:WorkerModel 2>$null }
        'goose'     { 
            $env:GOOSE_MODEL = $script:WorkerModel
            $env:GOOSE_PROVIDER = $script:WorkerProvider
            return goose run --recipe ralph-work --session $SessionId --task $Task --feedback $Feedback 2>$null
        }
        default { Write-Color "Error: Unknown provider $($script:WorkerProvider)" $Red; return $null }
    }
}

function Call-ReviewerLlm {
    param([string]$Task, [string]$Work, [string]$Summary, [int]$Iteration, [string]$SessionId)
    
    $prompt = @"
You are the REVIEWERVIEWERVIEWER in a Ralph Loop iteration $Iteration.

Original Task: $Task

Worker's Work:
$Work

Worker's Summary: $Summary

Review this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).
If REVISE, provide specific, actionable feedback for the worker.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [your feedback, or empty if SHIP]
"@

    switch ($script:ReviewerProvider) {
        'anthropic' { return $prompt | claude --model $script:ReviewerModel --print 2>$null }
        'openai'    { return $prompt | openai chat --model $script:ReviewerModel 2>$null }
        'google'    { return $prompt | gemini --model $script:ReviewerModel 2>$null }
        'goose'     { 
            $env:GOOSE_MODEL = $script:ReviewerModel
            $env:GOOSE_PROVIDER = $script:ReviewerProvider
            return goose run --recipe ralph-review --session $SessionId --work $Work --summary $Summary 2>$null
        }
        default { Write-Color "Error: Unknown provider $($script:ReviewerProvider)" $Red; return $null }
    }
}

function Parse-WorkerOutput {
    param([string]$Output)
    $work = ''; $summary = ''
    if ($Output -match '(?s)WORK:(.*?)SUMMARY:') { $work = $matches[1].Trim() }
    if ($Output -match '(?s)SUMMARY:(.*)') { $summary = $matches[1].Trim() }
    return @{ work = $work; summary = $summary }
}

function Parse-ReviewerOutput {
    param([string]$Output)
    $decision = ''; $feedback = ''
    if ($Output -match '(?i)DECISION:\s*(SHIP|REVISE)') { $decision = $matches[1].ToUpper() }
    if ($Output -match '(?s)FEEDBACK:\s*(.*)') { $feedback = $matches[1].Trim() }
    return @{ decision = $decision; feedback = $feedback }
}

function Check-Deps {
    $missing = @()
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { $missing += 'jq' }
    
    switch ($script:WorkerProvider) {
        'anthropic' { if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { $missing += 'claude (Anthropic CLI)' } }
        'openai'    { if (-not (Get-Command openai -ErrorAction SilentlyContinue)) { $missing += 'openai (OpenAI CLI)' } }
        'google'    { if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) { $missing += 'gemini (Google CLI)' } }
        'goose'     { if (-not (Get-Command goose -ErrorAction SilentlyContinue)) { $missing += 'goose' } }
    }
    switch ($script:ReviewerProvider) {
        'anthropic' { if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { $missing += 'claude (Anthropic CLI)' } }
        'openai'    { if (-not (Get-Command openai -ErrorAction SilentlyContinue)) { $missing += 'openai (OpenAI CLI)' } }
        'google'    { if (-not (Get-Command gemini -ErrorAction SilentlyContinue)) { $missing += 'gemini (Google CLI)' } }
        'goose'     { if (-not (Get-Command goose -ErrorAction SilentlyContinue)) { $missing += 'goose' } }
    }
    
    if ($missing.Count -gt 0) {
        Write-Color "Missing dependencies:" $Red
        foreach ($dep in $missing) { Write-Host "  - $dep" }
        exit 1
    }
}

# Main
Write-Header

# Initialize MCP server
Call-McpInit | Out-Null

# Get task
$task = Get-Task
if (-not $task) {
    Write-Color "Error: No task provided" $Red
    Write-Host "Usage: $0 \"task description\" or $0 path/to/task.md"
    exit 1
}

# Prompt for config if needed
if (-not $script:WorkerModel -or -not $script:WorkerProvider -or -not $script:ReviewerModel -or -not $script:ReviewerProvider) {
    Prompt-Config
}

# Cost warning
Write-Color "⚠️  Cost Warning: This will run up to $($script:MaxIterations) iterations, each using both models." $Yellow
Write-Host -NoNewline "Continue? [y/N]: "
$confirm = Read-Host
if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }

$sessionId = "ralph-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host ""
Write-Color "  Task: $task" $Yellow
Write-Color "  Worker: $($script:WorkerModel) ($($script:WorkerProvider))" $Gray
Write-Color "  Reviewer: $($script:ReviewerModel) ($($script:ReviewerProvider))" $Gray
Write-Color "  Max Iterations: $($script:MaxIterations)" $Gray
Write-Color "  Session: $sessionId" $Gray
Write-Host ""

# Initialize session via MCP
$taskJson = $task | ConvertTo-Json -Compress
$initParams = "{\"sessionId\":\"$sessionId\",\"task\":$taskJson,\"maxIterations\":$($script:MaxIterations),\"workerModel\":\"$($script:WorkerModel)\",\"workerProvider\":\"$($script:WorkerProvider)\",\"reviewerModel\":\"$($script:ReviewerModel)\",\"reviewerProvider\":\"$($script:ReviewerProvider)\"}"
Call-Mcp "ralph_loop_initialize" $initParams $sessionId | Out-Null

$feedback = ''

for ($i = 1; $i -le $script:MaxIterations; $i++) {
    Write-Step "Iteration $i / $($script:MaxIterations)"
    
    # WORK PHASE
    Write-Color "▶ WORK PHASE" $Yellow
    Write-Color "Worker: $($script:WorkerModel) ($($script:WorkerProvider))" $Gray
    
    $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId
    
    if (-not $workerOutput) {
        Write-Color "✗ WORK PHASE FAILED - No output from worker" $Red
        exit 1
    }
    
    $parsed = Parse-WorkerOutput -Output $workerOutput
    $work = $parsed.work
    $summary = $parsed.summary
    
    if (-not $work -or -not $summary) {
        Write-Color "✗ WORK PHASE FAILED - Could not parse output" $Red
        Write-Host "Raw output: $workerOutput"
        exit 1
    }
    
    # Submit work via MCP
    $workJson = $work | ConvertTo-Json -Compress
    $summaryJson = $summary | ConvertTo-Json -Compress
    $workParams = "{\"sessionId\":\"$sessionId\",\"iteration\":$i,\"work\":$workJson,\"summary\":$summaryJson}"
    Call-Mcp "ralph_loop_submit_work" $workParams $sessionId | Out-Null
    
    Write-Host "Work submitted. Summary: $summary"
    Write-Host ""
    
    # REVIEW PHASE
    Write-Color "▶ REVIEW PHASE" $Yellow
    Write-Color "Reviewer: $($script:ReviewerModel) ($($script:ReviewerProvider))" $Gray
    
    $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId
    
    if (-not $reviewerOutput) {
        Write-Color "✗ REVIEW PHASE FAILED - No output from reviewer" $Red
        exit 1
    }
    
    $parsed = Parse-ReviewerOutput -Output $reviewerOutput
    $decision = $parsed.decision
    $feedback = $parsed.feedback
    
    if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') {
        Write-Color "✗ REVIEW PHASE FAILED - Invalid decision: $decision" $Red
        Write-Host "Raw output: $reviewerOutput"
        exit 1
    }
    
    # Submit review via MCP
    $feedbackJson = $feedback | ConvertTo-Json -Compress
    $reviewParams = "{\"sessionId\":\"$sessionId\",\"iteration\":$i,\"decision\":\"$decision\",\"feedback\":$feedbackJson}"
    Call-Mcp "ralph_loop_submit_review" $reviewParams $sessionId | Out-Null
    
    if ($decision -eq 'SHIP') {
        Write-Host ""
        Write-Color "═══════════════════════════════════════════════════════════════" $Green
        Write-Color "  ✓ SHIPPED after $i iteration(s)" $Green
        Write-Color "═══════════════════════════════════════════════════════════════" $Green
        Write-Host "Session: $sessionId"
        Write-Host "Complete: $(Get-Date)"
        exit 0
    } else {
        Write-Host ""
        Write-Color "↻ REVISE - Feedback for next iteration:" $Yellow
        Write-Host $feedback
        Write-Host ""
    }
}

Write-Color "✗ Max iterations ($($script:MaxIterations)) reached" $Red
exit 1