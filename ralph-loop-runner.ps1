<#>
.SYNOPSIS
    ralph-loop-runner - PowerShell Implementation (Unified: MCP Server + CLI Orchestration)
    Cross-platform implementation of the Ralph Loop iterative development technique
    For Windows (PowerShell 5.1+ / PowerShell 7+)
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# HELPER: Null-coalescing for PS 5.1
# =============================================================================
function Coalesce { param($Value, $Default); if ($null -ne $Value -and $Value -ne '') { return $Value }; return $Default }

# Helper: Safely convert JSON to dictionary
function JsonToDict { param([string]$Json); $obj = $Json | ConvertFrom-Json; if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return @{ value = $obj } }; $dict = @{}; foreach ($prop in $obj.PSObject.Properties) { $val = $prop.Value; if ($val -is [System.Management.Automation.PSCustomObject]) { $val = $val | ConvertTo-Json -Depth 10 | ConvertFrom-Json }; $dict[$prop.Name] = $val }; return $dict }

# Ensure jq is available
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    $errorResp = @{ jsonrpc = '2.0'; id = $null; error = @{ code = -32603; message = 'jq is required but not installed' } }
    Write-Output ($errorResp | ConvertTo-Json -Compress -Depth 10)
    exit 1
}

# =============================================================================
# CONFIGURATION (from environment variables with defaults)
# =============================================================================
$script:RalphStateBase = Join-Path (Join-Path $env:USERPROFILE '.goose') 'ralph'
$script:RalphRecipeDir = Coalesce $env:RALPH_RECIPE_DIR '/usr/local/share/ralph-loop-runner/recipes'
$script:SafeCommands = @('ls', 'pwd', 'echo', 'date', 'cat', 'mkdir', 'rm', 'cp', 'mv', 'jq')
$script:CmdTimeout = 30

# Rate limit & retry configuration
$script:MaxRetries = [int](Coalesce $env:RALPH_MAX_RETRIES 3)
$script:InitialBackoff = [int](Coalesce $env:RALPH_INITIAL_BACKOFF 5)
$script:ThrottleDelay = [int](Coalesce $env:RALPH_THROTTLE_DELAY 0)

# Environment variable defaults
$script:WorkerModel = Coalesce $env:RALPH_WORKER_MODEL ''
$script:WorkerProvider = Coalesce $env:RALPH_WORKER_PROVIDER ''
$script:WorkerAgent = Coalesce $env:RALPH_WORKER_AGENT 'goose'
$script:ReviewerModel = Coalesce $env:RALPH_REVIEWER_MODEL ''
$script:ReviewerProvider = Coalesce $env:RALPH_REVIEWER_PROVIDER ''
$script:ReviewerAgent = Coalesce $env:RALPH_REVIEWER_AGENT 'goose'
$script:MaxIterations = [int](Coalesce $env:RALPH_MAX_ITERATIONS 10)
$script:WorkGuidelines = Coalesce $env:RALPH_WORK_GUIDELINES (Join-Path $script:RalphRecipeDir 'ralph-work.yaml')
$script:ReviewGuidelines = Coalesce $env:RALPH_REVIEW_GUIDELINES (Join-Path $script:RalphRecipeDir 'ralph-review.yaml')
$script:MonitorModel = Coalesce $env:RALPH_MONITOR_MODEL ''
$script:MonitorProvider = Coalesce $env:RALPH_MONITOR_PROVIDER ''
$script:MonitorAgent = Coalesce $env:RALPH_MONITOR_AGENT 'goose'

# Profile support via environment variable
if ($env:RALPH_PROFILE -and (Test-Path $env:RALPH_PROFILE)) {
    try {
        $profile = Get-Content $env:RALPH_PROFILE -Raw | ConvertFrom-Json
        if ($profile.workerModel) { $script:WorkerModel = $profile.workerModel }
        if ($profile.workerProvider) { $script:WorkerProvider = $profile.workerProvider }
        if ($profile.workerAgent) { $script:WorkerAgent = $profile.workerAgent }
        if ($profile.reviewerModel) { $script:ReviewerModel = $profile.reviewerModel }
        if ($profile.reviewerProvider) { $script:ReviewerProvider = $profile.reviewerProvider }
        if ($profile.reviewerAgent) { $script:ReviewerAgent = $profile.reviewerAgent }
        if ($profile.monitorModel) { $script:MonitorModel = $profile.monitorModel }
        if ($profile.monitorProvider) { $script:MonitorProvider = $profile.monitorProvider }
        if ($profile.monitorAgent) { $script:MonitorAgent = $profile.monitorAgent }
        if ($profile.maxIterations) { $script:MaxIterations = [int]$profile.maxIterations }
        if ($profile.workGuidelines) { $script:WorkGuidelines = $profile.workGuidelines }
        if ($profile.reviewGuidelines) { $script:ReviewGuidelines = $profile.reviewGuidelines }
    }
    catch {
        Write-Error "Failed to load profile from '$env:RALPH_PROFILE': $_" 
    }
    # Extract profile name from path for adaptive tracking
    $script:CurrentProfile = Split-Path $env:RALPH_PROFILE -Leaf
    $script:CurrentProfile = $script:CurrentProfile -replace '\.json$', ''
}

# CLI argument placeholders
$script:CLITask = ''
$script:CLISessionId = ''
$script:CurrentProfile = Coalesce $script:CurrentProfile ''

# =============================================================================
# UTILITY FUNCTIONS (shared by both modes)
# =============================================================================
function Get-StateDir { param([string]$SessionId = 'default'); return Join-Path $script:RalphStateBase $SessionId }
function Get-StateFile { param([string]$SessionId = 'default', [string]$FileName); return Join-Path (Get-StateDir -SessionId $SessionId) $FileName }
function Ensure-StateDir { param([string]$SessionId = 'default'); $dir = Get-StateDir -SessionId $SessionId; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
function ConvertTo-JsonEscaped { param([string]$Input); return ($Input | ConvertTo-Json -Compress -Depth 10).Trim('"') }
function New-JsonResponse { param($Id, [string]$Result = '', [hashtable]$Error = $null); $resp = @{ jsonrpc = '2.0' }; if ($null -ne $Id -and $Id -ne 'null') { $resp.id = $Id } else { $resp.id = $null }; if ($null -ne $Error) { $resp.error = $Error } else { $resp.result = if ($Result) { $Result | ConvertFrom-Json } else { @{} } }; return $resp | ConvertTo-Json -Compress -Depth 10 }

function Test-RateLimitError {
    param([string]$Output)
    if ($Output -match '(?i)(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled)') {
        return $true
    }
    return $false
}

function Apply-RateThrottling {
    if ($script:ThrottleDelay -gt 0) {
        Start-Sleep -Seconds $script:ThrottleDelay
    }
}

function Invoke-LlmWithRetry {
    param(
        [string]$RoleName,
        [scriptblock]$ScriptBlock
    )
    Apply-RateThrottling
    $attempt = 1
    $backoff = $script:InitialBackoff
    $maxAttempts = $script:MaxRetries + 1
    $output = ''

    while ($attempt -le $maxAttempts) {
        $output = & $ScriptBlock
        if ($output -and (-not (Test-RateLimitError -Output $output))) {
            return $output
        }

        if ((Test-RateLimitError -Output $output) -or (-not $output)) {
            if ($attempt -lt $maxAttempts) {
                Write-Host "[WARN] [$RoleName] Rate limit / resource constraint detected on attempt $attempt/$($script:MaxRetries). Retrying in ${backoff}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $backoff
                $backoff = $backoff * 2
                $attempt++
                continue
            } else {
                Write-Host "[ERROR] [$RoleName] Rate limit / quota error persisted after $($script:MaxRetries) retries." -ForegroundColor Red
                if (Test-RateLimitError -Output $output) {
                    return "RATE_LIMIT_EXCEEDED: $output"
                }
                return $null
            }
        }
        return $output
    }
    return $null
}

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================
function Set-Config { 
    param(
        [string]$SessionId,
        [string]$WorkerModel,
        [string]$WorkerProvider,
        [string]$ReviewerModel,
        [string]$ReviewerProvider,
        [int]$MaxIterations = 10,
        [bool]$CrossModelEnforced = $true,
        [string]$WorkerAgent = 'goose',
        [string]$ReviewerAgent = 'goose',
        [string]$WorkGuidelines = '',
        [string]$ReviewGuidelines = '',
        [string]$MonitorModel = '',
        [string]$MonitorProvider = '',
        [string]$MonitorAgent = 'goose'
    )
    Ensure-StateDir -SessionId $SessionId
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    $config = @{
        workerModel = $WorkerModel
        workerProvider = $WorkerProvider
        workerAgent = $WorkerAgent
        reviewerModel = $ReviewerModel
        reviewerProvider = $ReviewerProvider
        reviewerAgent = $ReviewerAgent
        monitorModel = $MonitorModel
        monitorProvider = $MonitorProvider
        monitorAgent = $MonitorAgent
        maxIterations = $MaxIterations
        crossModelReviewEnforced = $CrossModelEnforced
        workGuidelines = $WorkGuidelines
        reviewGuidelines = $ReviewGuidelines
        configuredAt = (Get-Date).ToString('o')
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Encoding UTF8 
}

function Get-Config { param([string]$SessionId = 'default'); $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'; if (Test-Path $configFile) { return Get-Content $configFile -Raw -Encoding UTF8 }; return '' }

function Test-CrossModel { 
    param([string]$SessionId = 'default')
    $config = Get-Config -SessionId $SessionId
    if (-not $config) { return '{"valid":true}' }
    $configObj = $config | ConvertFrom-Json
    $enforced = Coalesce $configObj.crossModelReviewEnforced $true
    if ($enforced -ne $true) { return '{"valid":true}' }
    $workerModel = Coalesce $configObj.workerModel ''
    $workerProvider = Coalesce $configObj.workerProvider ''
    $reviewerModel = Coalesce $configObj.reviewerModel ''
    $reviewerProvider = Coalesce $configObj.reviewerProvider ''
    if ($workerModel -and $reviewerModel -and $workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) { 
        return '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}' 
    }
    return '{"valid":true}'
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================
function Set-Task { 
    param([string]$SessionId, [string]$Task)
    Ensure-StateDir -SessionId $SessionId
    $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'
    $task = @{ task = $Task; createdAt = (Get-Date).ToString('o') }
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile -Encoding UTF8
    $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'
    if (Test-Path $blockedFile) { Remove-Item $blockedFile -Force }
}

function Get-Task { param([string]$SessionId = 'default'); $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'; if (Test-Path $taskFile) { return Get-Content $taskFile -Raw -Encoding UTF8 }; return '' }

# =============================================================================
# WORK MANAGEMENT & ITERATION HISTORY
# =============================================================================
function Set-Work { 
    param([string]$SessionId, [string]$Work, [string]$Summary, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $workFile = Get-StateFile -SessionId $SessionId -FileName ''
    $workObj = @{ work = $Work; summary = $Summary; submittedAt = (Get-Date).ToString('o'); iteration = $Iteration }
    $workObj | ConvertTo-Json -Depth 10 | Set-Content -Path $workFile -Encoding UTF8
    $completeFile = Get-StateFile -SessionId $SessionId -FileName 'work-complete.txt'
    '{"ok":true}' | Set-Content -Path $completeFile -Encoding UTF8

    # Iteration History Persistence
    $histDir = Join-Path (Join-Path (Get-StateDir -SessionId $SessionId) 'history') "iteration_$Iteration"
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    Copy-Item -Path $workFile -Destination (Join-Path $histDir '') -Force
    $workOutFile = Get-StateFile -SessionId $SessionId -FileName 'work.out'
    if (Test-Path $workOutFile) { Copy-Item -Path $workOutFile -Destination (Join-Path $histDir 'work.out') -Force }
}

function Get-Work { param([string]$SessionId = 'default'); $workFile = Get-StateFile -SessionId $SessionId -FileName ''; if (Test-Path $workFile) { return Get-Content $workFile -Raw -Encoding UTF8 }; return '' }

# =============================================================================
# REVIEW MANAGEMENT & ITERATION HISTORY
# =============================================================================
function Set-Review { 
    param([string]$SessionId, [string]$Decision, [string]$Feedback, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $reviewFile = Get-StateFile -SessionId $SessionId -FileName ''
    $reviewObj = @{ decision = $Decision; feedback = $Feedback; reviewedAt = (Get-Date).ToString('o'); iteration = $Iteration }
    $reviewObj | ConvertTo-Json -Depth 10 | Set-Content -Path $reviewFile -Encoding UTF8
    $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'
    @{ decision = $Decision } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $resultFile -Encoding UTF8
    $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'
    @{ feedback = $Feedback } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $feedbackFile -Encoding UTF8

    # Iteration History Persistence
    $histDir = Join-Path (Join-Path (Get-StateDir -SessionId $SessionId) 'history') "iteration_$Iteration"
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }
    Copy-Item -Path $reviewFile -Destination (Join-Path $histDir '') -Force
    $reviewOutFile = Get-StateFile -SessionId $SessionId -FileName 'review.out'
    if (Test-Path $reviewOutFile) { Copy-Item -Path $reviewOutFile -Destination (Join-Path $histDir 'review.out') -Force }

    if ($Decision -eq 'REVISE') { Cleanup-ForNextIteration -SessionId $SessionId }
}

function Get-Review { param([string]$SessionId = 'default'); $reviewFile = Get-StateFile -SessionId $SessionId -FileName ''; if (Test-Path $reviewFile) { return Get-Content $reviewFile -Raw -Encoding UTF8 }; return '' }
function Get-ReviewResult { param([string]$SessionId = 'default'); $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'; if (Test-Path $resultFile) { $content = Get-Content $resultFile -Raw -Encoding UTF8; return ($content | ConvertFrom-Json).decision }; return '' }
function Get-Feedback { param([string]$SessionId = 'default'); $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'; if (Test-Path $feedbackFile) { $content = Get-Content $feedbackFile -Raw -Encoding UTF8; return ($content | ConvertFrom-Json).feedback }; return '' }

# =============================================================================
# STATUS MANAGEMENT
# =============================================================================
function Get-Status { 
    param([string]$SessionId = 'default', [int]$MaxIterations = 10)
    $task = Get-Task -SessionId $SessionId
    $work = Get-Work -SessionId $SessionId
    $reviewResult = Get-ReviewResult -SessionId $SessionId
    $feedback = Get-Feedback -SessionId $SessionId
    $config = Get-Config -SessionId $SessionId
    $blocked = Test-Path (Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md')
    $crossModelValidation = Test-CrossModel -SessionId $SessionId | JsonToDict
    $phase = 'WORK'
    $status = 'running'
    $currentIteration = 1
    if ($blocked) {
        $phase = 'BLOCKED'
        $status = 'blocked'
    } elseif ($reviewResult -eq 'SHIP') {
        $phase = 'COMPLETE'
        $status = 'shipped'
        if ($work) {
            $workObj = JsonToDict $work
            $currentIteration = Coalesce $workObj['iteration'] 1
        }
    } elseif ($reviewResult -eq 'REVISE') {
        $phase = 'WORK'
        $status = 'revised'
        if ($work) {
            $workObj = JsonToDict $work
            $currentIteration = (Coalesce $workObj['iteration'] 1) + 1
        }
    } elseif ($work) {
        $phase = 'REVIEW'
        $status = 'running'
        $workObj = JsonToDict $work
        $currentIteration = Coalesce $workObj['iteration'] 1
    }
    if ($currentIteration -gt $MaxIterations -and $status -eq 'running') {
        $status = 'max_iterations_reached'
        $phase = 'COMPLETE'
    }
    $taskText = ''
    $createdAt = ''
    if ($task) {
        $taskObj = JsonToDict $task
        $taskText = Coalesce $taskObj['task'] ''
        $createdAt = Coalesce $taskObj['createdAt'] ''
    }
    $workSummary = ''
    if ($work) {
        $workObj = JsonToDict $work
        $workSummary = Coalesce $workObj['summary'] ''
    }
    $workerModel = ''
    $workerProvider = ''
    $workerAgent = ''
    $reviewerModel = ''
    $reviewerProvider = ''
    $reviewerAgent = ''
    $monitorModel = ''
    $monitorProvider = ''
    $monitorAgent = ''
    $crossModelEnforced = $true
    $crossModelValid = $true
    $crossModelWarning = ''
    $workGuidelines = ''
    $reviewGuidelines = ''
    if ($config) {
        $configObj = JsonToDict $config
        $workerModel = Coalesce $configObj['workerModel'] ''
        $workerProvider = Coalesce $configObj['workerProvider'] ''
        $workerAgent = Coalesce $configObj['workerAgent'] ''
        $reviewerModel = Coalesce $configObj['reviewerModel'] ''
        $reviewerProvider = Coalesce $configObj['reviewerProvider'] ''
        $reviewerAgent = Coalesce $configObj['reviewerAgent'] ''
        $monitorModel = Coalesce $configObj['monitorModel'] ''
        $monitorProvider = Coalesce $configObj['monitorProvider'] ''
        $monitorAgent = Coalesce $configObj['monitorAgent'] ''
        $crossModelEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true
        $crossModelValid = Coalesce $crossModelValidation['valid'] $true
        $crossModelWarning = Coalesce $crossModelValidation['warning'] ''
        $workGuidelines = Coalesce $configObj['workGuidelines'] ''
        $reviewGuidelines = Coalesce $configObj['reviewGuidelines'] ''
    }
    return @{
        sessionId = $SessionId
        currentIteration = $currentIteration
        maxIterations = $MaxIterations
        phase = $phase
        status = $status
        task = if ($taskText) { $taskText } else { $null }
        lastWorkSummary = if ($workSummary) { $workSummary } else { $null }
        lastFeedback = if ($feedback) { $feedback } else { $null }
        createdAt = if ($createdAt) { $createdAt } else { $null }
        updatedAt = (Get-Date).ToString('o')
        workerModel = if ($workerModel) { $workerModel } else { $null }
        workerProvider = if ($workerProvider) { $workerProvider } else { $null }
        workerAgent = if ($workerAgent) { $workerAgent } else { $null }
        reviewerModel = if ($reviewerModel) { $reviewerModel } else { $null }
        reviewerProvider = if ($reviewerProvider) { $reviewerProvider } else { $null }
        reviewerAgent = if ($reviewerAgent) { $reviewerAgent } else { $null }
        monitorModel = if ($monitorModel) { $monitorModel } else { $null }
        monitorProvider = if ($monitorProvider) { $monitorProvider } else { $null }
        monitorAgent = if ($monitorAgent) { $monitorAgent } else { $null }
        crossModelReviewEnforced = $crossModelEnforced
        crossModelReviewValid = $crossModelValid
        crossModelReviewWarning = if ($crossModelWarning) { $crossModelWarning } else { $null }
        workGuidelines = if ($workGuidelines) { $workGuidelines } else { $null }
        reviewGuidelines = if ($reviewGuidelines) { $reviewGuidelines } else { $null }
    }
}

function Cleanup-ForNextIteration { 
    param([string]$SessionId)
    $files = @('work-complete.txt', 'review-result.txt', 'review-feedback.txt', '', '', 'work.out', 'review.out')
    foreach ($file in $files) { 
        $path = Get-StateFile -SessionId $SessionId -FileName $file
        if (Test-Path $path) { Remove-Item $path -Force } 
    } 
}

function Reset-Session { 
    param([string]$SessionId)
    $stateDir = Get-StateDir -SessionId $SessionId
    if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force } 
}

function Block-Iteration { 
    param([string]$SessionId, [string]$Reason)
    Ensure-StateDir -SessionId $SessionId
    $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'
    $Reason | Set-Content -Path $blockedFile -Encoding UTF8 
}

# =============================================================================
# ORCHESTRATION HELPERS (CLI mode)
# =============================================================================
function Call-WorkerLlm { 
    param([string]$Task, [string]$Feedback, [int]$Iteration, [string]$SessionId, [string]$WorkerModel, [string]$WorkerProvider, [string]$WorkerAgent, [string]$WorkGuidelines, [bool]$IsExisting = $false)
    $prompt = "You are the WORKER in a Ralph Loop iteration $Iteration.`n`nTask: $Task`n"
    if ($Feedback) { $prompt += "Previous feedback from reviewer: $Feedback`nPlease revise your work based on this feedback.`n" }
    $prompt += "Provide your complete work output and a brief summary.`nOutput format:`nWORK:`n[your complete work here]`n`nSUMMARY:`n[brief summary of what you did]`n"

    return Invoke-LlmWithRetry -RoleName 'WORKER' -ScriptBlock {
        switch ($WorkerAgent) { 
            'anthropic' { return $prompt | claude --model $WorkerModel --print 2>$null } 
            'openai'    { return $prompt | openai chat --model $WorkerModel --no-stream 2>$null } 
            'google'    { return $prompt | gemini --model $WorkerModel --format=text 2>$null }
            'copilot'   { return $prompt | copilot -p --allow-all-tools 2>$null } 
            'goose' { 
                $gooseParams = @("task=$Task", "sessionId=$SessionId")
                if ($Feedback) { $gooseParams += "feedback=$Feedback" }
                $gooseArgs = @('run')
                if ($WorkGuidelines -and (Test-Path $WorkGuidelines)) { 
                    $gooseArgs += '--recipe', $WorkGuidelines
                }
                $gooseArgs += '--params', ($gooseParams -join ' ')
                if ($SessionId) { 
                    if ($IsExisting) { $gooseArgs += '--resume' }
                    $gooseArgs += '--name', $SessionId
                } else { 
                    $gooseArgs += '--no-session' 
                } 
                $gooseArgs += '--text', $prompt
                $env:GOOSE_MODEL = $WorkerModel
                $env:GOOSE_PROVIDER = $WorkerProvider
                $stateDir = Get-StateDir -SessionId $SessionId; Push-Location $stateDir; goose $gooseArgs 1>work.out 2>$null; Pop-Location
                if (Test-Path work.out) { return Get-Content work.out -Raw } else { return $null }
            }
            default { Write-Host "Error: Unknown provider $WorkerProvider" -ForegroundColor Red; return $null } 
        } 
    }
}

function Call-ReviewerLlm { 
    param([string]$Task, [string]$Work, [string]$Summary, [int]$Iteration, [string]$SessionId, [string]$ReviewerModel, [string]$ReviewerProvider, [string]$ReviewerAgent, [string]$ReviewGuidelines, [bool]$IsExisting = $false)
    $prompt = "You are the REVIEWER in a Ralph Loop iteration $Iteration.`n`nOriginal Task: $Task`n`nWorker's Work:`n$Work`n`nWorker's Summary: $Summary`n`nReview this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).`nIf REVISE, provide specific, actionable feedback for the worker.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [your feedback, or empty if SHIP]`n"

    return Invoke-LlmWithRetry -RoleName 'REVIEWER' -ScriptBlock {
        switch ($ReviewerAgent) { 
            'anthropic' { return $prompt | claude --model $ReviewerModel --print 2>$null } 
            'openai'    { return $prompt | openai chat --model $ReviewerModel --no-stream 2>$null } 
            'google'    { return $prompt | gemini --model $ReviewerModel --format=text 2>$null } 
            'copilot'   { return $prompt | copilot -p --allow-all-tools 2>$null } 
            'goose' { 
                $gooseParams = @("task=$Task", "work=$Work", "summary=$Summary", "sessionId=$SessionId")
                $gooseArgs = @('run')
                if ($ReviewGuidelines -and (Test-Path $ReviewGuidelines)) { 
                    $gooseArgs += '--recipe', $ReviewGuidelines
                }
                $gooseArgs += '--params', ($gooseParams -join ' ')
                if ($SessionId) {
                    if ($IsExisting) { $gooseArgs += '--resume' }
                    $gooseArgs += '--name', $SessionId
                } else { 
                    $gooseArgs += '--no-session' 
                } 
                $gooseArgs += '--text', $prompt
                $env:GOOSE_MODEL = $ReviewerModel
                $env:GOOSE_PROVIDER = $ReviewerProvider
                $stateDir = Get-StateDir -SessionId $SessionId; Push-Location $stateDir; goose $gooseArgs 1>review.out 2>$null; Pop-Location
                if (Test-Path review.out) { return Get-Content review.out -Raw } else { return $null }
            }
            default { Write-Host "Error: Unknown provider $ReviewerProvider" -ForegroundColor Red; return $null } 
        } 
    }
}

function Call-MonitorLlm {
    param([string]$Prompt, [string]$MonitorModel, [string]$MonitorProvider, [string]$MonitorAgent)
    if (-not $MonitorModel) { $MonitorModel = $script:MonitorModel }
    if (-not $MonitorProvider) { $MonitorProvider = $script:MonitorProvider }
    if (-not $MonitorAgent) { $MonitorAgent = $script:MonitorAgent }
    # Fall back to worker settings if monitor not configured
    if (-not $MonitorModel) { $config = Get-Config -SessionId $SessionId | JsonToDict; if ($config) { $MonitorModel = Coalesce $config["monitorModel"] "" }; if (-not $MonitorModel) { $MonitorModel = $script:WorkerModel } }
    if (-not $MonitorProvider) { $config = Get-Config -SessionId $SessionId | JsonToDict; if ($config) { $MonitorProvider = Coalesce $config["monitorProvider"] "" }; if (-not $MonitorProvider) { $MonitorProvider = $script:WorkerProvider } }
    if (-not $MonitorAgent) { $config = Get-Config -SessionId $SessionId | JsonToDict; if ($config) { $MonitorAgent = Coalesce $config["monitorAgent"] "" }; if (-not $MonitorAgent) { $MonitorAgent = $script:WorkerAgent } }

    return Invoke-LlmWithRetry -RoleName 'MONITOR' -ScriptBlock {
        switch ($MonitorAgent) {
            'anthropic' { return $Prompt | claude --model $MonitorModel --print 2>$null }
            'openai'    { return $Prompt | openai chat --model $MonitorModel --no-stream 2>$null }
            'google'    { return $Prompt | gemini --model $MonitorModel --format=text 2>$null }
            'goose'     {
                          $env:GOOSE_MODEL = $MonitorModel
                          $env:GOOSE_PROVIDER = $MonitorProvider
                          # Write prompt to temp file and pipe via stdin to avoid command-line length limits
                          $tempFile = Join-Path $env:TEMP "ralph-monitor-$([System.IO.Path]::GetRandomFileName()).txt"
                          try {
                              $Prompt | Out-File -FilePath $tempFile -Encoding UTF8
                              return goose run --no-session -i $tempFile 2>$null
                          } finally {
                              if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
                          }
                        }
            default     { return $Prompt | openai chat --model $MonitorModel --no-stream 2>$null }
        }
    }
}

function Parse-WorkerOutput {
    param([string]$Output, [string]$MonitorModel = '', [string]$MonitorProvider = '', [string]$MonitorAgent = '', [string]$OutputFile = '')
    $work = ''; $summary = ''
    $mWork = [regex]::Match($Output, '(?s)WORK:(.*?)SUMMARY:')
    if ($mWork.Success) { $work = $mWork.Groups[1].Value.Trim() }
    $mSummary = [regex]::Match($Output, '(?s)SUMMARY:(.*)')
    if ($mSummary.Success) { $summary = $mSummary.Groups[1].Value.Trim() }
    # Regex failed -- try Monitor LLM fallback
    if (-not $work -or -not $summary) {
        Write-Host "  Regex parsing failed for worker output, consulting Monitor LLM..." -ForegroundColor Yellow
        # For goose agent, reference the output file to avoid command-line length issues
        if ($MonitorAgent -eq 'goose' -and $OutputFile -and (Test-Path $OutputFile)) {
            $monitorPrompt = "Read the file at '$OutputFile' then extract the WORK and SUMMARY sections from its content.`n`nIf the agent created or modified files, include the file paths and key content in WORK.`nSummarize what was accomplished in SUMMARY.`n`nOutput format:`nWORK:`n[extracted work content]`n`nSUMMARY:`n[one-line summary]"
        } else {
            $monitorPrompt = "Extract the WORK and SUMMARY sections from the following raw agent output.`n`nIf the agent created or modified files, include the file paths and key content in WORK.`nSummarize what was accomplished in SUMMARY.`n`nOutput format:`nWORK:`n[extracted work content]`n`nSUMMARY:`n[one-line summary]`n`n---`n$Output"
        }
        $monitorResponse = Call-MonitorLlm -Prompt $monitorPrompt -MonitorModel $MonitorModel -MonitorProvider $MonitorProvider -MonitorAgent $MonitorAgent
        if ($monitorResponse) {
            $mWork2 = [regex]::Match($monitorResponse, '(?s)WORK:(.*?)SUMMARY:')
            if ($mWork2.Success) { $work = $mWork2.Groups[1].Value.Trim() }
            $mSummary2 = [regex]::Match($monitorResponse, '(?s)SUMMARY:(.*)')
            if ($mSummary2.Success) { $summary = $mSummary2.Groups[1].Value.Trim() }
        }
        if ($work -or $summary) { Write-Host "  Monitor LLM parsed successfully." -ForegroundColor Green }
        else { Write-Host "  Monitor LLM also could not parse the output." -ForegroundColor Red }
    }
    return @{ work = $work; summary = $summary }
}

function Parse-ReviewerOutput {
    param([string]$Output, [string]$MonitorModel = '', [string]$MonitorProvider = '', [string]$MonitorAgent = '', [string]$OutputFile = '')
    $decision = ''; $feedback = ''
    $mDecision = [regex]::Match($Output, '(?i)DECISION:\s*(SHIP|REVISE)')
    if ($mDecision.Success) { $decision = $mDecision.Groups[1].Value.ToUpper() }
    $mFeedback = [regex]::Match($Output, '(?s)FEEDBACK:\s*(.*)')
    if ($mFeedback.Success) { $feedback = $mFeedback.Groups[1].Value.Trim() }
    # Regex failed -- try Monitor LLM fallback
    if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') {
        Write-Host "  Regex parsing failed for reviewer output, consulting Monitor LLM..." -ForegroundColor Yellow
        # For goose agent, reference the output file to avoid command-line length issues
        if ($MonitorAgent -eq 'goose' -and $OutputFile -and (Test-Path $OutputFile)) {
            $monitorPrompt = "Read the file at '$OutputFile' then extract the DECISION (SHIP or REVISE) and FEEDBACK from its content.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [the review feedback]"
        } else {
            $monitorPrompt = "Extract the DECISION (SHIP or REVISE) and FEEDBACK from the following raw agent output.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [the review feedback]`n`n---`n$Output"
        }
        $monitorResponse = Call-MonitorLlm -Prompt $monitorPrompt -MonitorModel $MonitorModel -MonitorProvider $MonitorProvider -MonitorAgent $MonitorAgent
        if ($monitorResponse) {
            $mDecision2 = [regex]::Match($monitorResponse, '(?i)DECISION:\s*(SHIP|REVISE)')
            if ($mDecision2.Success) { $decision = $mDecision2.Groups[1].Value.ToUpper() }
            $mFeedback2 = [regex]::Match($monitorResponse, '(?s)FEEDBACK:\s*(.*)')
            if ($mFeedback2.Success) { $feedback = $mFeedback2.Groups[1].Value.Trim() }
        }
        if ($decision -eq 'SHIP' -or $decision -eq 'REVISE') { Write-Host "  Monitor LLM parsed successfully." -ForegroundColor Green }
        else { Write-Host "  Monitor LLM also could not parse the output." -ForegroundColor Red }
    }
    return @{ decision = $decision; feedback = $feedback }
}

# CLI orchestration main function

# Strategy profile orderings.
# Each strategy maps a trigger class to an ordered list of profiles to walk through.
#   trigger 'resource' = rate limit / quota / resource exhaustion  -> move toward cheaper/faster
#   trigger 'quality' = token repetition / low quality output      -> move toward higher quality
$script:AdaptiveOrders = @{
    'quality'  = @{ resource = @('ultra','super','pro','plus','lite'); quality = @('lite','plus','pro','super','ultra'); start = 'ultra' }
    'price'    = @{ resource = @('ultra','super','pro','plus','lite'); quality = @('lite','plus','pro','super','ultra'); start = 'lite' }
    'balanced' = @{ resource = @('pro','plus','lite'); quality = @('pro','super','ultra'); start = 'pro' }
}

# Direct transition table for the 'balanced' strategy: (current profile, trigger) -> next profile.
# A 'quality' error switches to the quality ladder; a 'resource' error switches to the resource ladder.
# The mode ("optimizing for") is implied by the trigger type, so no separate state is tracked.
$script:AdaptiveBalancedTransitions = @{
    'pro'   = @{ quality = 'super'; resource = 'plus'  }
    'super' = @{ quality = 'ultra'; resource = 'lite'  }
    'ultra' = @{ quality = 'pro';   resource = 'pro'   }
    'plus'  = @{ quality = 'ultra'; resource = 'lite'  }
    'lite'  = @{ quality = 'pro';   resource = 'pro'   }
}

# Detect a resource/rate-limit trigger in the combined output/feedback.
function Test-ResourceTrigger {
    param([string]$WorkerOutput, [string]$ReviewerOutput, [string]$Feedback)
    $regex = '(?i)(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled|out of memory|insufficient (quota|resources))'
    return ($WorkerOutput -and $WorkerOutput -match $regex) -or
           ($ReviewerOutput -and $ReviewerOutput -match $regex) -or
           ($Feedback -and $Feedback -match '(?i)(resource|memory|cpu|quota|limit)')
}

# Detect a low-quality / token-repetition trigger in the combined output/feedback.
function Test-QualityTrigger {
    param([string]$WorkerOutput, [string]$ReviewerOutput, [string]$Feedback)
    # Heuristics: repeated long tokens, repetition keywords, or explicit low-quality markers
    foreach ($text in @($WorkerOutput, $ReviewerOutput, $Feedback)) {
        if (-not $text) { continue }
        # Explicit low-quality markers
        if ($text -match '(?i)(low quality|poor quality|nonsensical|incoherent|garbled|repetitive|repeating itself|lorem ipsum|placeholder)') {
            return $true
        }
        # Token repetition: a >= 8-char word repeated 5+ times
        $words = [regex]::Matches($text, '\b\w{8,}\b') | ForEach-Object { $_.Value.ToLower() }
        $counts = @{}
        foreach ($w in $words) { $counts[$w] = [int]$counts[$w] + 1 }
        foreach ($k in $counts.Keys) { if ($counts[$k] -ge 6) { return $true } }
    }
    return $false
}

# Decide the next profile for a given strategy + trigger + current profile.
# Returns profile name to switch to, or $null if no further switch is possible.
function Get-AdaptiveProfileSwitch {
    param(
        [string]$Strategy,
        [string]$Trigger,
        [string]$CurrentProfile
    )

    if ($Strategy -eq 'balanced') {
        $table = $script:AdaptiveBalancedTransitions
        if ($table.ContainsKey($CurrentProfile)) {
            $row = $table[$CurrentProfile]
            if ($row.ContainsKey($Trigger)) { return $row[$Trigger] }
            return 'pro'
        }
        return 'pro'
    }

    $order = $script:AdaptiveOrders[$Strategy][$Trigger]
    if (-not $order) { return $null }

    # If current profile is not in the order, default into the start position.
    if (-not $CurrentProfile -or $order -notcontains $CurrentProfile) {
        # Start from the first entry in the order (next profile after the strategy's start).
        return $order[0]
    }

    $idx = [Array]::IndexOf($order, $CurrentProfile)
    if ($idx -eq -1) { return $order[0] }
    # Cycle back to the start of the order when reaching the end
    return $order[($idx + 1) % $order.Count]
}

# Helper function to apply a profile
function Apply-Profile {
    param(
        [string]$SessionId,
        [string]$ProfileName
    )
    
    $profilePath = "profiles/$ProfileName.json"
    if (-not (Test-Path $profilePath)) {
        Write-Host "[ERROR] Profile file not found: $profilePath" -ForegroundColor Red
        return
    }
    
    $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
    
    # Update config with profile settings
    $config = @{
        workerModel = $profile.workerModel
        workerProvider = $profile.workerProvider
        workerAgent = $profile.workerAgent
        reviewerModel = $profile.reviewerModel
        reviewerProvider = $profile.reviewerProvider
        reviewerAgent = $profile.reviewerAgent
        monitorModel = $profile.monitorModel
        monitorProvider = $profile.monitorProvider
        monitorAgent = $profile.monitorAgent
        maxIterations = $profile.maxIterations
        crossModelReviewEnforced = $true
        workGuidelines = $profile.workGuidelines
        reviewGuidelines = $profile.reviewGuidelines
        configuredAt = (Get-Date).ToString('o')
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path (Get-StateFile -SessionId $SessionId -FileName 'config.json') -Encoding UTF8
    
    Write-Host "[ADAPTIVE] Applied profile: $ProfileName" -ForegroundColor Green
}

# Helper function to switch profile and return new config values
function Switch-AdaptiveProfile {
    param(
        [string]$SessionId,
        [string]$NewProfile,
        [string]$OldProfile = ''
    )
    Write-Host "[ADAPTIVE] Switching profile from '$OldProfile' to '$NewProfile'" -ForegroundColor Cyan
    Apply-Profile -SessionId $SessionId -ProfileName $NewProfile
    $config = Get-Config -SessionId $SessionId | JsonToDict
    return @{
        workerModel = Coalesce $config['workerModel'] ''
        workerProvider = Coalesce $config['workerProvider'] ''
        workerAgent = Coalesce $config['workerAgent'] 'goose'
        reviewerModel = Coalesce $config['reviewerModel'] ''
        reviewerProvider = Coalesce $config['reviewerProvider'] ''
        reviewerAgent = Coalesce $config['reviewerAgent'] 'goose'
        monitorModel = Coalesce $config['monitorModel'] ''
        monitorProvider = Coalesce $config['monitorProvider'] ''
        monitorAgent = Coalesce $config['monitorAgent'] 'goose'
        maxIterations = Coalesce $config['maxIterations'] 10
    }
}

function Run-Cli { 
    $cliArgs = $script:ScriptArgs
    if ($cliArgs -contains '-h' -or $cliArgs -contains '--help') {
        Write-Host "ralph-loop-runner - PowerShell Implementation"
        Write-Host "Usage: .\ralph-loop-runner.ps1 [options] \"task description\" or .\ralph-loop-runner.ps1 [options] path/to/task.md"
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  --worker-model MODEL         Worker model (default: `$env:RALPH_WORKER_MODEL)"
        Write-Host "  --worker-provider PROVIDER   Worker provider (default: `$env:RALPH_WORKER_PROVIDER)"
        Write-Host "  --worker-agent AGENT         Worker agent (default: `$env:RALPH_WORKER_AGENT)"
        Write-Host "  --reviewer-model MODEL       Reviewer model (default: `$env:RALPH_REVIEWER_MODEL)"
        Write-Host "  --reviewer-provider PROVIDER Reviewer provider (default: `$env:RALPH_REVIEWER_PROVIDER)"
        Write-Host "  --reviewer-agent AGENT       Reviewer agent (default: `$env:RALPH_REVIEWER_AGENT)"
        Write-Host "  --monitor-model MODEL        Monitor model (default: `$env:RALPH_MONITOR_MODEL)"
        Write-Host "  --monitor-provider PROVIDER  Monitor provider (default: `$env:RALPH_MONITOR_PROVIDER)"
        Write-Host "  --monitor-agent AGENT        Monitor agent (default: `$env:RALPH_MONITOR_AGENT)"
        Write-Host "  --max-iterations N           Max iterations, -1 for infinite (default: `$env:RALPH_MAX_ITERATIONS)"
        Write-Host "  --work-guidelines FILE       Work guidelines/recipe file"
        Write-Host "  --review-guidelines FILE     Review guidelines/recipe file"
        Write-Host "  --session-id ID              Session ID (default: auto-generated)"
        Write-Host "  --max-retries N              Max retry attempts for rate limits (default: `$env:RALPH_MAX_RETRIES)"
        Write-Host "  --initial-backoff N          Initial backoff seconds for retries (default: `$env:RALPH_INITIAL_BACKOFF)"
        Write-Host "  --throttle-delay N           Delay between requests in seconds (default: `$env:RALPH_THROTTLE_DELAY)"
        Write-Host "  --enable-adaptive            Enable adaptive profile switching (rate limits/quota/iteration progress)"
        Write-Host "  --adaptive-strategy STRATEGY Adaptive strategy: quality, price, or balanced (default: balanced)"
        Write-Host "  -h, --help                   Show this help message"
        exit 0
    }

    $workerModel = $script:WorkerModel
    $workerProvider = $script:WorkerProvider
    $workerAgent = $script:WorkerAgent
    $reviewerModel = $script:ReviewerModel
    $reviewerProvider = $script:ReviewerProvider
    $reviewerAgent = $script:ReviewerAgent
    $maxIterations = $script:MaxIterations
    $workGuidelines = $script:WorkGuidelines
    $reviewGuidelines = $script:ReviewGuidelines
    $monitorModel = $script:MonitorModel
    $monitorProvider = $script:MonitorProvider
    $monitorAgent = $script:MonitorAgent
    $maxRetries = $script:MaxRetries
    $initialBackoff = $script:InitialBackoff
    $throttleDelay = $script:ThrottleDelay
    $enableAdaptive = $false
    $adaptiveStrategy = 'balanced'
    $currentProfile = Coalesce $script:CurrentProfile ''


    # Parse command line arguments.
    # Flags are consumed by name; the last positional (non-flag) argument is the task.
    $cliArgs = $script:ScriptArgs
    $positionalArgs = @()
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        switch ($cliArgs[$i]) {
            '--worker-model' { $workerModel = $cliArgs[$i+1]; $i++ }
            '--worker-provider' { $workerProvider = $cliArgs[$i+1]; $i++ }
            '--worker-agent' { $workerAgent = $cliArgs[$i+1]; $i++ }
            '--reviewer-model' { $reviewerModel = $cliArgs[$i+1]; $i++ }
            '--reviewer-provider' { $reviewerProvider = $cliArgs[$i+1]; $i++ }
            '--reviewer-agent' { $reviewerAgent = $cliArgs[$i+1]; $i++ }
            '--max-iterations' { $maxIterations = [int]$cliArgs[$i+1]; $i++ }
            '--work-guidelines' { $workGuidelines = $cliArgs[$i+1]; $i++ }
            '--review-guidelines' { $reviewGuidelines = $cliArgs[$i+1]; $i++ }
            '--session-id' { $script:CLISessionId = $cliArgs[$i+1]; $i++ }
            '--monitor-model' { $monitorModel = $cliArgs[$i+1]; $i++ }
            '--monitor-provider' { $monitorProvider = $cliArgs[$i+1]; $i++ }
            '--monitor-agent' { $monitorAgent = $cliArgs[$i+1]; $i++ }
            '--max-retries' { $maxRetries = [int]$cliArgs[$i+1]; $i++ }
            '--initial-backoff' { $initialBackoff = [int]$cliArgs[$i+1]; $i++ }
            '--throttle-delay' { $throttleDelay = [int]$cliArgs[$i+1]; $i++ }
            '--enable-adaptive' { $enableAdaptive = $true }
            '--adaptive-strategy' { $adaptiveStrategy = $cliArgs[$i+1]; $i++ }
            default { $positionalArgs += $cliArgs[$i] }
        }
    }
    # Last positional argument is the task
    $taskInput = if ($positionalArgs.Count -gt 0) { $positionalArgs[-1] } else { '' }
    $task = if (Test-Path $taskInput) { Get-Content $taskInput -Raw } else { $taskInput }
    if (-not $task) { Write-Host "Error: No task provided" -ForegroundColor Red; Write-Host "Usage: .\ralph-loop-runner.ps1 [options] \"task description\" or .\ralph-loop-runner.ps1 [options] path/to/task.md" -ForegroundColor Red; Write-Host ""; Write-Host "Options:" -ForegroundColor Cyan; Write-Host "  --worker-model MODEL         Worker model (default: `$env:RALPH_WORKER_MODEL)"; Write-Host "  --worker-provider PROVIDER   Worker provider (default: `$env:RALPH_WORKER_PROVIDER)"; Write-Host "  --worker-agent AGENT         Worker agent (default: `$env:RALPH_WORKER_AGENT)"; Write-Host "  --reviewer-model MODEL       Reviewer model (default: `$env:RALPH_REVIEWER_MODEL)"; Write-Host "  --reviewer-provider PROVIDER Reviewer provider (default: `$env:RALPH_REVIEWER_PROVIDER)"; Write-Host "  --reviewer-agent AGENT       Reviewer agent (default: `$env:RALPH_REVIEWER_AGENT)"; Write-Host "  --monitor-model MODEL        Monitor model (default: `$env:RALPH_MONITOR_MODEL)"; Write-Host "  --monitor-provider PROVIDER  Monitor provider (default: `$env:RALPH_MONITOR_PROVIDER)"; Write-Host "  --monitor-agent AGENT        Monitor agent (default: `$env:RALPH_MONITOR_AGENT)"; Write-Host "  --max-iterations N           Max iterations, -1 for infinite (default: `$env:RALPH_MAX_ITERATIONS)"; Write-Host "  --work-guidelines FILE       Work guidelines/recipe file (default: `$env:RALPH_WORK_GUIDELINES)"; Write-Host "  --review-guidelines FILE     Review guidelines/recipe file (default: `$env:RALPH_REVIEW_GUIDELINES)"; Write-Host "  --session-id ID              Session ID (default: auto-generated)"; Write-Host "  --max-retries N              Max retry attempts for rate limits (default: `$env:RALPH_MAX_RETRIES)"; Write-Host "  --initial-backoff N          Initial backoff seconds for retries (default: `$env:RALPH_INITIAL_BACKOFF)"; Write-Host "  --throttle-delay N           Delay between requests in seconds (default: `$env:RALPH_THROTTLE_DELAY)"; Write-Host "  --enable-adaptive            Enable adaptive profile switching based on rate limits, quota errors, resource exhaustion, and low quality output"; Write-Host "  --adaptive-strategy STRATEGY Adaptive strategy: quality, price, or balanced (default: balanced)"; exit 1 }

    # Update script-level retry config from CLI options
    $script:MaxRetries = $maxRetries
    $script:InitialBackoff = $initialBackoff
    $script:ThrottleDelay = $throttleDelay

    if (-not $workerModel) { Write-Host -NoNewline "Worker model: "; $workerModel = Read-Host; if (-not $workerModel) { exit 1 } }
    if (-not $workerProvider) { Write-Host -NoNewline "Worker provider (anthropic/openai/google/goose/copilot): "; $workerProvider = Read-Host; if (-not $workerProvider) { exit 1 } }
    if (-not $workerAgent) { Write-Host -NoNewline "Worker agent (goose/claude/openai/gemini/copilot): "; $workerAgent = Read-Host; if (-not $workerAgent) { exit 1 } }
    if (-not $reviewerModel) { Write-Host -NoNewline "Reviewer model (different from worker): "; $reviewerModel = Read-Host; if (-not $reviewerModel) { exit 1 } }
    if (-not $reviewerProvider) { Write-Host -NoNewline "Reviewer provider (anthropic/openai/google/goose/copilot): "; $reviewerProvider = Read-Host; if (-not $reviewerProvider) { exit 1 } }
    if (-not $reviewerAgent) { Write-Host -NoNewline "Reviewer agent (goose/claude/openai/gemini/copilot): "; $reviewerAgent = Read-Host; if (-not $reviewerAgent) { exit 1 } }

    if ($workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) {
        Write-Host "Warning: Worker and reviewer are the same model/provider." -ForegroundColor Yellow
        Write-Host -NoNewline "Continue? [y/N]: "
        $confirm = Read-Host
        if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
    }

    $sessionId = Coalesce $script:CLISessionId "ralph-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "Session: $sessionId"
    Write-Host "Task: $task"
    Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"
    Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"
    if ($monitorModel) {
        Write-Host "Monitor: $monitorModel ($monitorProvider) via $monitorAgent"
    }
    if ($maxIterations -eq -1) { Write-Host "Max Iterations: unlimited" } else { Write-Host "Max Iterations: $maxIterations" }
    Write-Host ""

    # Validate adaptive strategy and resolve start profile
    if ($enableAdaptive) {
        if ($script:AdaptiveOrders -notcontains $adaptiveStrategy) {
            Write-Host "[WARNING] Unknown adaptive strategy '$adaptiveStrategy'; falling back to 'balanced'." -ForegroundColor Yellow
            $adaptiveStrategy = 'balanced'
        }
        if (-not $currentProfile) {
            $currentProfile = $script:AdaptiveOrders[$adaptiveStrategy]['start']
            Write-Host "[ADAPTIVE] Strategy '$adaptiveStrategy' (start profile '$currentProfile')" -ForegroundColor Cyan
        } else {
            Write-Host "[ADAPTIVE] Strategy '$adaptiveStrategy' (starting from '$currentProfile')" -ForegroundColor Cyan
        }
    }

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $true -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent

    $feedback = ''
    $iteration = 1
    $workerOutput = ''
    $reviewerOutput = ''

    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }

    for ($i = 1; $i -le $maxIter; $i++) {
        $iteration = $i
        
        Write-Host "======================================================================"
        Write-Host "  Iteration $iteration / $maxIterations"
        Write-Host "======================================================================"

        Write-Host ">> WORK PHASE"
        Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"

        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $iteration -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
        
        if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                    Write-Host "[ADAPTIVE] Retrying work phase with upgraded profile '$currentProfile'" -ForegroundColor Cyan
                    $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $iteration -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
                }
            }
            if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
                Write-Host "[ERROR] WORK PHASE FAILED - Rate limit, quota error, or no output from worker" -ForegroundColor Red
                Block-Iteration -SessionId $sessionId -Reason 'WORK PHASE FAILED - Rate limit or quota error from worker LLM'
                exit 1
            }
        }

        # Save worker output to file for Monitor LLM fallback
        $workOutFile = Get-StateFile -SessionId $sessionId -FileName 'work.out'
        $workerOutput | Out-File -FilePath $workOutFile -Encoding UTF8

        $parsed = Parse-WorkerOutput -Output $workerOutput -OutputFile $workOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) { Write-Host "[ERROR] WORK PHASE FAILED - Could not parse output" -ForegroundColor Red; exit 1 }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $iteration
        Write-Host "Work submitted. Summary: $summary"
        Write-Host ""

        Write-Host ">> REVIEW PHASE"
        Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $iteration -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
        
        if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                    Write-Host "[ADAPTIVE] Retrying review phase with upgraded profile '$currentProfile'" -ForegroundColor Cyan
                    $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $iteration -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting (($script:CLISessionId -ne '') -or ($iteration -gt 1))
                }
            }
            if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
                Write-Host "[ERROR] REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer" -ForegroundColor Red
                Block-Iteration -SessionId $sessionId -Reason 'REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM'
                exit 1
            }
        }

        # Save reviewer output to file for Monitor LLM fallback
        $reviewOutFile = Get-StateFile -SessionId $sessionId -FileName 'review.out'
        $reviewerOutput | Out-File -FilePath $reviewOutFile -Encoding UTF8

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput -OutputFile $reviewOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') { Write-Host "[ERROR] REVIEW PHASE FAILED - Invalid decision: $decision" -ForegroundColor Red; exit 1 }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $iteration

        if ($decision -eq 'SHIP') {
            Write-Host ""
            Write-Host "======================================================================"
            Write-Host "  ** SHIPPED after $iteration iteration(s)" -ForegroundColor Green
            Write-Host "======================================================================"
            Write-Host "Session: $sessionId"
            Write-Host "Complete: $(Get-Date)"
            exit 0
        } else {
            Write-Host ""
            Write-Host ">> REVISE - Feedback for next iteration:" -ForegroundColor Yellow
            Write-Host $feedback
            Write-Host ""

            # Adaptive profile switching based on output quality or resource constraints
            if ($enableAdaptive) {
                $trigger = ''
                if (Test-QualityTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'quality' }
                elseif (Test-ResourceTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'resource' }
                $newProfile = if ($trigger) { Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger $trigger -CurrentProfile $currentProfile } else { $null }
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $maxIterations = $sw.maxIterations
                    $maxIter = if ($maxIterations -eq -1) { [int]::MaxValue } else { $maxIterations }
                }
            }
        }
    }

    Write-Host "[ERROR] Max iterations ($maxIterations) reached" -ForegroundColor Red
    exit 1
}

# =============================================================================
# TOOL HANDLERS (MCP Server mode)
# =============================================================================
function Handle-Initialize { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $task = Coalesce $paramsObj['task'] ''
    $maxIterations = Coalesce $paramsObj['maxIterations'] 10
    $workerModel = Coalesce $paramsObj['workerModel'] ''
    $workerProvider = Coalesce $paramsObj['workerProvider'] ''
    $workerAgent = Coalesce $paramsObj['workerAgent'] 'goose'
    $reviewerModel = Coalesce $paramsObj['reviewerModel'] ''
    $reviewerProvider = Coalesce $paramsObj['reviewerProvider'] ''
    $reviewerAgent = Coalesce $paramsObj['reviewerAgent'] 'goose'
    $monitorModel = Coalesce $paramsObj['monitorModel'] $script:MonitorModel
    $monitorProvider = Coalesce $paramsObj['monitorProvider'] $script:MonitorProvider
    $monitorAgent = Coalesce $paramsObj['monitorAgent'] $script:MonitorAgent
    $crossModelEnforced = Coalesce $paramsObj['crossModelReviewEnforced'] $true
    $workGuidelines = Coalesce $paramsObj['workGuidelines'] ''
    $reviewGuidelines = Coalesce $paramsObj['reviewGuidelines'] ''
    
    if (-not $task) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Task is required' } 
    }
    
    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent
    $validation = Test-CrossModel -SessionId $sessionId | JsonToDict
    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
    $result = @{ 
        success = $true
        message = "Ralph Loop initialized for session `"$sessionId`""
        status = $status
        crossModelReview = @{ 
            enforced = $crossModelEnforced
            valid = Coalesce $validation['valid'] $true
            warning = Coalesce $validation['warning'] '' 
        } 
    }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-GetTask { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $task = Get-Task -SessionId $sessionId
    if (-not $task) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No task found. Initialize the session first with ralph_loop_initialize.' } 
    }
    $taskObj = JsonToDict $task
    $result = @{ success = $true; task = Coalesce $taskObj['task'] ''; createdAt = Coalesce $taskObj['createdAt'] '' }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-SubmitWork { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $work = Coalesce $paramsObj['work'] ''
    $summary = Coalesce $paramsObj['summary'] ''
    $iteration = $paramsObj['iteration']
    if (-not $work -or -not $summary -or -not $iteration) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'work, summary, and iteration are required' } 
    }
    Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $iteration
    $status = Get-Status -SessionId $sessionId | JsonToDict
    $result = @{ success = $true; message = "Work submitted for iteration $iteration"; status = $status }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-GetWork { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $work = Get-Work -SessionId $sessionId
    if (-not $work) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No work submitted yet. Worker must submit work first.' } 
    }
    $workObj = JsonToDict $work
    $result = @{ success = $true; work = Coalesce $workObj['work'] ''; summary = Coalesce $workObj['summary'] ''; iteration = Coalesce $workObj['iteration'] 0; submittedAt = Coalesce $workObj['submittedAt'] '' }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-SubmitReview { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $decision = Coalesce $paramsObj['decision'] ''
    $feedback = Coalesce $paramsObj['feedback'] ''
    $iteration = $paramsObj['iteration']
    if (-not $decision -or -not $iteration) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'decision and iteration are required' } 
    }
    if ($decision -eq 'REVISE' -and -not $feedback) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Feedback is required when decision is REVISE' } 
    }
    Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $iteration
    $status = Get-Status -SessionId $sessionId | JsonToDict
    $result = @{ success = $true; message = "Review submitted: $decision"; decision = $decision; feedback = $feedback; status = $status }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-GetFeedback { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $reviewResult = Get-ReviewResult -SessionId $sessionId
    $feedback = Get-Feedback -SessionId $sessionId
    $status = Get-Status -SessionId $sessionId | JsonToDict
    if (-not $reviewResult) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No review completed yet. Reviewer must submit review first.' } 
    }
    if ($reviewResult -eq 'SHIP') { 
        $result = @{ success = $true; shipped = $true; message = 'Work approved! SHIPPED.'; status = $status }
        return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
    }
    $result = @{ success = $true; shipped = $false; feedback = $feedback; iteration = $status.currentIteration; status = $status }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-GetStatus { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $config = Get-Config -SessionId $sessionId
    $maxIterations = 10
    if ($config) { 
        $configObj = JsonToDict $config
        $maxIterations = Coalesce $configObj['maxIterations'] 10 
    }
    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
    $result = @{ success = $true } + $status
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-GetConfig { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $config = Get-Config -SessionId $sessionId
    if (-not $config) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No configuration found. Initialize the session first with ralph_loop_initialize.' } 
    }
    $configObj = JsonToDict $config
    $validation = Test-CrossModel -SessionId $sessionId | JsonToDict
    $result = @{ 
        success = $true
        config = @{ 
            workerModel = Coalesce $configObj['workerModel'] ''
            workerProvider = Coalesce $configObj['workerProvider'] ''
            workerAgent = Coalesce $configObj['workerAgent'] ''
            reviewerModel = Coalesce $configObj['reviewerModel'] ''
            reviewerProvider = Coalesce $configObj['reviewerProvider'] ''
            reviewerAgent = Coalesce $configObj['reviewerAgent'] ''
            monitorModel = Coalesce $configObj['monitorModel'] ''
            monitorProvider = Coalesce $configObj['monitorProvider'] ''
            monitorAgent = Coalesce $configObj['monitorAgent'] ''
            maxIterations = Coalesce $configObj['maxIterations'] 10
            crossModelReviewEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true
            workGuidelines = Coalesce $configObj['workGuidelines'] ''
            reviewGuidelines = Coalesce $configObj['reviewGuidelines'] ''
            configuredAt = Coalesce $configObj['configuredAt'] '' 
        }
        crossModelReview = @{ 
            enforced = Coalesce $configObj['crossModelReviewEnforced'] $true
            valid = Coalesce $validation['valid'] $true
            warning = Coalesce $validation['warning'] '' 
        } 
    }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-Reset { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    Reset-Session -SessionId $sessionId
    $result = @{ success = $true; message = "Session `"$sessionId`" has been reset" }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-Block { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $reason = Coalesce $paramsObj['reason'] ''
    if (-not $reason) { 
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Reason is required for blocking' } 
    }
    Block-Iteration -SessionId $sessionId -Reason $reason
    $result = @{ success = $true; message = 'Iteration blocked'; reason = $reason }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

function Handle-Run { 
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $task = Coalesce $paramsObj['task'] ''
    $maxIterations = Coalesce $paramsObj['maxIterations'] 10
    $workerModel = Coalesce $paramsObj['workerModel'] ''
    $workerProvider = Coalesce $paramsObj['workerProvider'] ''
    $workerAgent = Coalesce $paramsObj['workerAgent'] 'goose'
    $reviewerModel = Coalesce $paramsObj['reviewerModel'] ''
    $reviewerProvider = Coalesce $paramsObj['reviewerProvider'] ''
    $reviewerAgent = Coalesce $paramsObj['reviewerAgent'] 'goose'
    $crossModelEnforced = Coalesce $paramsObj['crossModelReviewEnforced'] $true
    $workGuidelines = Coalesce $paramsObj['workGuidelines'] ''
    $reviewGuidelines = Coalesce $paramsObj['reviewGuidelines'] ''
    $monitorModel = Coalesce $paramsObj['monitorModel'] $script:MonitorModel
    $monitorProvider = Coalesce $paramsObj['monitorProvider'] $script:MonitorProvider
    $monitorAgent = Coalesce $paramsObj['monitorAgent'] $script:MonitorAgent
    $enableAdaptive = Coalesce $paramsObj['enableAdaptive'] $false
    $adaptiveStrategy = Coalesce $paramsObj['adaptiveStrategy'] 'balanced'
    $currentProfile = Coalesce $paramsObj['profile'] ''

    if (-not $task) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Task is required' } }
    if (-not $workerModel -or -not $workerProvider -or -not $reviewerModel -or -not $reviewerProvider) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'workerModel, workerProvider, reviewerModel, and reviewerProvider are required' } }

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent

    # Validate adaptive strategy and resolve start profile
    if ($enableAdaptive) {
        if ($script:AdaptiveOrders -notcontains $adaptiveStrategy) {
            $adaptiveStrategy = 'balanced'
        }
        if (-not $currentProfile) {
            $currentProfile = $script:AdaptiveOrders[$adaptiveStrategy]['start']
        }
    }

    $feedback = ''

    for ($i = 1; $i -le $maxIterations; $i++) {
        $workerPrompt = "You are the WORKER in a Ralph Loop iteration $i.`n`nTask: $task`n"
        if ($feedback) { $workerPrompt += "Previous feedback from reviewer: $feedback`nPlease revise your work based on this feedback.`n" }
        $workerPrompt += "Provide your complete work output and a brief summary.`nOutput format:`nWORK:`n[your complete work here]`n`nSUMMARY:`n[brief summary of what you did]`n"

        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting ($i -gt 1)
        
        if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines -IsExisting ($i -gt 1)
                }
            }
            if ($workerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $workerOutput)) {
                Block-Iteration -SessionId $sessionId -Reason 'WORK PHASE FAILED - Rate limit or quota error from worker LLM'
                return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'WORK PHASE FAILED - Rate limit, quota error, or no output from worker' }
            }
        }

        # Save worker output to file for Monitor LLM fallback
        $workOutFile = Get-StateFile -SessionId $sessionId -FileName 'work.out'
        $workerOutput | Out-File -FilePath $workOutFile -Encoding UTF8

        $parsed = Parse-WorkerOutput -Output $workerOutput -OutputFile $workOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'WORK PHASE FAILED - Could not parse output' } }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $i

        $reviewerPrompt = "You are the REVIEWER in a Ralph Loop iteration $i.`n`nOriginal Task: $task`n`nWorker's Work:`n$work`n`nWorker's Summary: $summary`n`nReview this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).`nIf REVISE, provide specific, actionable feedback for the worker.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [your feedback, or empty if SHIP]`n"

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting ($i -gt 1)
        
        if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
            if ($enableAdaptive) {
                $newProfile = Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger 'resource' -CurrentProfile $currentProfile
                if ($newProfile -and $newProfile -ne $currentProfile) {
                    $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                    $currentProfile = $newProfile
                    $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                    $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                    $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
                    $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines -IsExisting ($i -gt 1)
                }
            }
            if ($reviewerOutput -like 'RATE_LIMIT_EXCEEDED*' -or (-not $reviewerOutput)) {
                Block-Iteration -SessionId $sessionId -Reason 'REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM'
                return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer' }
            }
        }

        # Save reviewer output to file for Monitor LLM fallback
        $reviewOutFile = Get-StateFile -SessionId $sessionId -FileName 'review.out'
        $reviewerOutput | Out-File -FilePath $reviewOutFile -Encoding UTF8

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput -OutputFile $reviewOutFile -MonitorModel $monitorModel -MonitorProvider $monitorProvider -MonitorAgent $monitorAgent -SessionId $sessionId
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'REVIEW PHASE FAILED - Invalid decision: ' + $decision } }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $i

        if ($decision -eq 'SHIP') {
            $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
            $result = @{ success = $true; message = "SHIPPED after $i iteration(s)"; status = $status; shipped = $true; iterations = $i }
            return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
        }

        # Adaptive profile switching based on output quality or resource constraints
        if ($enableAdaptive) {
            $trigger = ''
            if (Test-QualityTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'quality' }
            elseif (Test-ResourceTrigger -WorkerOutput $workerOutput -ReviewerOutput $reviewerOutput -Feedback $feedback) { $trigger = 'resource' }
            $newProfile = if ($trigger) { Get-AdaptiveProfileSwitch -Strategy $adaptiveStrategy -Trigger $trigger -CurrentProfile $currentProfile } else { $null }
            if ($newProfile -and $newProfile -ne $currentProfile) {
                $sw = Switch-AdaptiveProfile -SessionId $sessionId -NewProfile $newProfile -OldProfile $currentProfile
                $currentProfile = $newProfile
                $workerModel = $sw.workerModel; $workerProvider = $sw.workerProvider; $workerAgent = $sw.workerAgent
                $reviewerModel = $sw.reviewerModel; $reviewerProvider = $sw.reviewerProvider; $reviewerAgent = $sw.reviewerAgent
                $monitorModel = $sw.monitorModel; $monitorProvider = $sw.monitorProvider; $monitorAgent = $sw.monitorAgent
            }
        }
    }

    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
    $result = @{ success = $false; message = "Max iterations ($maxIterations) reached"; status = $status; shipped = $false }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
}

function Handle-ListTools { 
    param($Id)
    $tools = @(
        @{
            name = 'ralph_loop_initialize'
            description = 'Initialize a new Ralph Loop session with a task, model configuration, and guidelines'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Unique session identifier (default: 'default')" }
                    task = @{ type = 'string'; description = 'The task or feature description for the worker to implement' }
                    maxIterations = @{ type = 'integer'; description = 'Maximum number of iterations (-1 for unlimited, default: 10)' }
                    workerModel = @{ type = 'string'; description = "Worker LLM model name (e.g., 'claude-3-5-sonnet')" }
                    workerProvider = @{ type = 'string'; description = 'Worker provider (anthropic, openai, google, copilot, goose)' }
                    workerAgent = @{ type = 'string'; description = "Worker agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    reviewerModel = @{ type = 'string'; description = "Reviewer LLM model name (e.g., 'gpt-4o')" }
                    reviewerProvider = @{ type = 'string'; description = 'Reviewer provider (anthropic, openai, google, copilot, goose)' }
                    reviewerAgent = @{ type = 'string'; description = "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    monitorModel = @{ type = 'string'; description = 'Monitoring agent model name (fallback supervisor)' }
                    monitorProvider = @{ type = 'string'; description = 'Monitoring agent provider (anthropic, openai, google, copilot, goose)' }
                    monitorAgent = @{ type = 'string'; description = "Monitoring agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    crossModelReviewEnforced = @{ type = 'boolean'; description = 'Enforce cross-model review validation between worker and reviewer (default: true)' }
                    workGuidelines = @{ type = 'string'; description = 'Path to work recipe or guidelines file' }
                    reviewGuidelines = @{ type = 'string'; description = 'Path to review recipe or guidelines file' }
                }
                required = @('task')
            }
        },
        @{
            name = 'ralph_loop_get_task'
            description = 'Get the current task for the worker phase'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_submit_work'
            description = 'Submit work results and summary from worker phase'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    work = @{ type = 'string'; description = 'Complete work output / implementation' }
                    summary = @{ type = 'string'; description = 'Summary of changes made' }
                    iteration = @{ type = 'integer'; description = 'Current iteration number' }
                }
                required = @('work', 'summary', 'iteration')
            }
        },
        @{
            name = 'ralph_loop_get_work'
            description = "Get worker's submitted work for reviewer phase"
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_submit_review'
            description = 'Submit review decision (SHIP or REVISE) with feedback'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    decision = @{ type = 'string'; enum = @('SHIP', 'REVISE'); description = 'Review decision: SHIP to approve, REVISE to request changes' }
                    feedback = @{ type = 'string'; description = 'Actionable feedback for revision (required if decision is REVISE)' }
                    iteration = @{ type = 'integer'; description = 'Current iteration number' }
                }
                required = @('decision', 'iteration')
            }
        },
        @{
            name = 'ralph_loop_get_feedback'
            description = 'Get reviewer feedback for next iteration'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_get_status'
            description = 'Get current session status, phase, iteration, and configuration'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_get_config'
            description = 'Get worker, reviewer, and monitor configuration for a session'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_reset'
            description = 'Reset and clear all state and history for a session'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                }
            }
        },
        @{
            name = 'ralph_loop_block'
            description = 'Block the current iteration with a reason'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    reason = @{ type = 'string'; description = 'Reason why the loop cannot proceed' }
                }
                required = @('reason')
            }
        },
        @{
            name = 'ralph_loop_run'
            description = 'Run complete automated Ralph Loop (initialization -> orchestration -> execution -> state management)'
            inputSchema = @{
                type = 'object'
                properties = @{
                    sessionId = @{ type = 'string'; description = "Session ID (default: 'default')" }
                    task = @{ type = 'string'; description = 'Task description to accomplish' }
                    maxIterations = @{ type = 'integer'; description = 'Maximum number of iterations (-1 for unlimited, default: 10)' }
                    workerModel = @{ type = 'string'; description = 'Worker model name' }
                    workerProvider = @{ type = 'string'; description = 'Worker provider (anthropic, openai, google, copilot, goose)' }
                    workerAgent = @{ type = 'string'; description = "Worker agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    reviewerModel = @{ type = 'string'; description = 'Reviewer model name' }
                    reviewerProvider = @{ type = 'string'; description = 'Reviewer provider (anthropic, openai, google, copilot, goose)' }
                    reviewerAgent = @{ type = 'string'; description = "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    monitorModel = @{ type = 'string'; description = 'Monitor model name' }
                    monitorProvider = @{ type = 'string'; description = 'Monitor provider' }
                    monitorAgent = @{ type = 'string'; description = "Monitor agent CLI (goose, claude, openai, gemini, copilot, default: 'goose')" }
                    crossModelReviewEnforced = @{ type = 'boolean'; description = 'Enforce cross-model review validation (default: true)' }
                    workGuidelines = @{ type = 'string'; description = 'Path to work recipe or guidelines file' }
                    reviewGuidelines = @{ type = 'string'; description = 'Path to review recipe or guidelines file' }
                    enableAdaptive = @{ type = 'boolean'; description = 'Enable adaptive profile switching (default: false)' }
                    adaptiveStrategy = @{ type = 'string'; enum = @('quality', 'price', 'balanced'); description = 'Adaptive switching strategy (default: balanced)' }
                }
                required = @('task', 'workerModel', 'workerProvider', 'reviewerModel', 'reviewerProvider')
            }
        }
    )
    $result = @{ tools = $tools }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) 
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if ($args.Count -gt 0) {
    # CLI MODE: Run orchestration with task argument and options
    $script:ScriptArgs = $args
    Run-Cli
} else {
    # MCP SERVER MODE: Handle JSON-RPC requests
    $initResp = @{ jsonrpc = '2.0'; id = $null; result = @{ protocolVersion = '2024-11-05'; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'ralph-loop-runner'; version = '1.0.0' } } }
    Write-Output ($initResp | ConvertTo-Json -Compress -Depth 10)

    try {
        $stdin = [Console]::In
        while ($true) {
            $line = $stdin.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try { $request = $line | JsonToDict } catch { Write-Output (New-JsonResponse -Id 'null' -Error @{ code = -32700; message = 'Parse error' }); continue }

            $method = if ($request.ContainsKey('method')) { $request['method'] } else { '' }
            $id = if ($request.ContainsKey('id')) { $request['id'] } else { 'null' }
            $params = if ($request.ContainsKey('params')) { $request['params'] } else { @{} }

            switch ($method) {
                'initialize' { $resp = @{ jsonrpc = '2.0'; id = $id; result = @{ protocolVersion = '2024-11-05'; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'ralph-loop-runner'; version = '1.0.0' } } }; Write-Output ($resp | ConvertTo-Json -Compress -Depth 10) }
                'tools/list' { Write-Output (Handle-ListTools -Id $id) }
                'tools/call' {
                    $toolName = if ($params.ContainsKey('name')) { $params['name'] } else { '' }
                    $toolArgs = if ($params.ContainsKey('arguments')) { $params['arguments'] } else { @{} }
                    switch ($toolName) {
                        'ralph_loop_initialize'   { Write-Output (Handle-Initialize   -Id $id -Params $toolArgs) }
                        'ralph_loop_get_task'     { Write-Output (Handle-GetTask     -Id $id -Params $toolArgs) }
                        'ralph_loop_submit_work'  { Write-Output (Handle-SubmitWork  -Id $id -Params $toolArgs) }
                        'ralph_loop_get_work'     { Write-Output (Handle-GetWork     -Id $id -Params $toolArgs) }
                        'ralph_loop_submit_review'{ Write-Output (Handle-SubmitReview -Id $id -Params $toolArgs) }
                        'ralph_loop_get_feedback' { Write-Output (Handle-GetFeedback -Id $id -Params $toolArgs) }
                        'ralph_loop_get_status'   { Write-Output (Handle-GetStatus   -Id $id -Params $toolArgs) }
                        'ralph_loop_get_config'   { Write-Output (Handle-GetConfig   -Id $id -Params $toolArgs) }
                        'ralph_loop_reset'        { Write-Output (Handle-Reset       -Id $id -Params $toolArgs) }
                        'ralph_loop_block'        { Write-Output (Handle-Block       -Id $id -Params $toolArgs) }
                        'ralph_loop_run'          { Write-Output (Handle-Run         -Id $id -Params $toolArgs) }
                        default { Write-Output (New-JsonResponse -Id $id -Error @{ code = -32601; message = "Unknown tool: $toolName" }) }
                    }
                }
                default { Write-Output (New-JsonResponse -Id $id -Error @{ code = -32601; message = "Unknown method: $method" }) }
            }
        }
    } catch { Write-Error $_ }
}

































