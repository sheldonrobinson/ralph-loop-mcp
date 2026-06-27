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
function JsonToDict { param([string]$Json); $obj = $Json | ConvertFrom-Json; if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return @{ value = $obj } }; $dict = @{}; foreach ($prop in $obj.PSObject.Properties) { $dict[$prop.Name] = $prop.Value }; return $dict }

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

# CLI argument placeholders
$script:CLITask = ''
$script:CLISessionId = ''

# =============================================================================
# UTILITY FUNCTIONS (shared by both modes)
# =============================================================================
function Get-StateDir { param([string]$SessionId = 'default'); return Join-Path $script:RalphStateBase $SessionId }
function Get-StateFile { param([string]$SessionId = 'default', [string]$FileName); return Join-Path (Get-StateDir -SessionId $SessionId) $FileName }
function Ensure-StateDir { param([string]$SessionId = 'default'); $dir = Get-StateDir -SessionId $SessionId; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
function ConvertTo-JsonEscaped { param([string]$Input); return ($Input | ConvertTo-Json -Compress -Depth 10).Trim('"') }
function New-JsonResponse { param($Id, [string]$Result = '', [hashtable]$Error = $null); $resp = @{ jsonrpc = '2.0' }; if ($null -ne $Id -and $Id -ne 'null') { $resp.id = $Id } else { $resp.id = $null }; if ($null -ne $Error) { $resp.error = $Error } else { $resp.result = if ($Result) { $Result | ConvertFrom-Json } else { @{} } }; return $resp | ConvertTo-Json -Compress -Depth 10 }

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================
function Set-Config { 
    param([string]$SessionId, [string]$WorkerModel, [string]$WorkerProvider, [string]$ReviewerModel, [string]$ReviewerProvider, [int]$MaxIterations = 10, [bool]$CrossModelEnforced = $true, [string]$WorkerAgent = 'goose', [string]$ReviewerAgent = 'goose', [string]$WorkGuidelines = '', [string]$ReviewGuidelines = '')
    Ensure-StateDir -SessionId $SessionId
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    $config = @{ workerModel = $WorkerModel; workerProvider = $WorkerProvider; workerAgent = $WorkerAgent; reviewerModel = $ReviewerModel; reviewerProvider = $ReviewerProvider; reviewerAgent = $ReviewerAgent; maxIterations = $MaxIterations; crossModelReviewEnforced = $CrossModelEnforced; workGuidelines = $WorkGuidelines; reviewGuidelines = $ReviewGuidelines; configuredAt = (Get-Date).ToString('o') }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Encoding UTF8 
}
function Get-Config { param([string]$SessionId = 'default'); $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'; if (Test-Path $configFile) { return Get-Content $configFile -Raw -Encoding UTF8 }; return '' }
function Test-CrossModel { param([string]$SessionId = 'default'); $config = Get-Config -SessionId $SessionId; if (-not $config) { return '{"valid":true}' }; $configObj = $config | ConvertFrom-Json; $enforced = Coalesce $configObj.crossModelReviewEnforced $true; if ($enforced -ne $true) { return '{"valid":true}' }; $workerModel = Coalesce $configObj.workerModel ''; $workerProvider = Coalesce $configObj.workerProvider ''; $reviewerModel = Coalesce $configObj.reviewerModel ''; $reviewerProvider = Coalesce $configObj.reviewerProvider ''; if ($workerModel -and $reviewerModel -and $workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) { return '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}' }; return '{"valid":true}' }

# =============================================================================
# TASK MANAGEMENT
# =============================================================================
function Set-Task { param([string]$SessionId, [string]$Task); Ensure-StateDir -SessionId $SessionId; $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'; $task = @{ task = $Task; createdAt = (Get-Date).ToString('o') }; $task | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile -Encoding UTF8; $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'; if (Test-Path $blockedFile) { Remove-Item $blockedFile -Force } }
function Get-Task { param([string]$SessionId = 'default'); $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'; if (Test-Path $taskFile) { return Get-Content $taskFile -Raw -Encoding UTF8 }; return '' }

# =============================================================================
# WORK MANAGEMENT
# =============================================================================
function Set-Work { param([string]$SessionId, [string]$Work, [string]$Summary, [int]$Iteration); Ensure-StateDir -SessionId $SessionId; $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'; $work = @{ work = $Work; summary = $Summary; submittedAt = (Get-Date).ToString('o'); iteration = $Iteration }; $work | ConvertTo-Json -Depth 10 | Set-Content -Path $workFile -Encoding UTF8; $completeFile = Get-StateFile -SessionId $SessionId -FileName 'work-complete.txt'; '{"ok":true}' | Set-Content -Path $completeFile -Encoding UTF8 }
function Get-Work { param([string]$SessionId = 'default'); $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'; if (Test-Path $workFile) { return Get-Content $workFile -Raw -Encoding UTF8 }; return '' }

# =============================================================================
# REVIEW MANAGEMENT
# =============================================================================
function Set-Review { param([string]$SessionId, [string]$Decision, [string]$Feedback, [int]$Iteration); Ensure-StateDir -SessionId $SessionId; $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'; $review = @{ decision = $Decision; feedback = $Feedback; reviewedAt = (Get-Date).ToString('o'); iteration = $Iteration }; $review | ConvertTo-Json -Depth 10 | Set-Content -Path $reviewFile -Encoding UTF8; $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'; @{ decision = $Decision } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $resultFile -Encoding UTF8; $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'; @{ feedback = $Feedback } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $feedbackFile -Encoding UTF8; if ($Decision -eq 'REVISE') { Cleanup-ForNextIteration -SessionId $SessionId } }
function Get-Review { param([string]$SessionId = 'default'); $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'; if (Test-Path $reviewFile) { return Get-Content $reviewFile -Raw -Encoding UTF8 }; return '' }
function Get-ReviewResult { param([string]$SessionId = 'default'); $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'; if (Test-Path $resultFile) { $content = Get-Content $resultFile -Raw -Encoding UTF8; return ($content | ConvertFrom-Json).decision }; return '' }
function Get-Feedback { param([string]$SessionId = 'default'); $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'; if (Test-Path $feedbackFile) { $content = Get-Content $feedbackFile -Raw -Encoding UTF8; return ($content | ConvertFrom-Json).feedback }; return '' }

# =============================================================================
# STATUS MANAGEMENT
# =============================================================================
function Get-Status { param([string]$SessionId = 'default', [int]$MaxIterations = 10); $task = Get-Task -SessionId $SessionId; $work = Get-Work -SessionId $SessionId; $reviewResult = Get-ReviewResult -SessionId $SessionId; $feedback = Get-Feedback -SessionId $SessionId; $config = Get-Config -SessionId $SessionId; $blocked = Test-Path (Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'); $crossModelValidation = Test-CrossModel -SessionId $SessionId | JsonToDict; $phase = 'WORK'; $status = 'running'; $currentIteration = 1; if ($blocked) { $phase = 'BLOCKED'; $status = 'blocked' } elseif ($reviewResult -eq 'SHIP') { $phase = 'COMPLETE'; $status = 'shipped'; if ($work) { $workObj = JsonToDict $work; $currentIteration = Coalesce $workObj['iteration'] 1 } } elseif ($reviewResult -eq 'REVISE') { $phase = 'WORK'; $status = 'revised'; if ($work) { $workObj = JsonToDict $work; $currentIteration = (Coalesce $workObj['iteration'] 1) + 1 } } elseif ($work) { $phase = 'REVIEW'; $status = 'running'; $workObj = JsonToDict $work; $currentIteration = Coalesce $workObj['iteration'] 1 }; if ($currentIteration -gt $MaxIterations -and $status -eq 'running') { $status = 'max_iterations_reached'; $phase = 'COMPLETE' }; $taskText = ''; $createdAt = ''; if ($task) { $taskObj = JsonToDict $task; $taskText = Coalesce $taskObj['task'] ''; $createdAt = Coalesce $taskObj['createdAt'] '' }; $workSummary = ''; if ($work) { $workObj = JsonToDict $work; $workSummary = Coalesce $workObj['summary'] '' }; $workerModel = ''; $workerProvider = ''; $workerAgent = ''; $reviewerModel = ''; $reviewerProvider = ''; $reviewerAgent = ''; $crossModelEnforced = $true; $crossModelValid = $true; $crossModelWarning = ''; $workGuidelines = ''; $reviewGuidelines = ''; if ($config) { $configObj = JsonToDict $config; $workerModel = Coalesce $configObj['workerModel'] ''; $workerProvider = Coalesce $configObj['workerProvider'] ''; $workerAgent = Coalesce $configObj['workerAgent'] ''; $reviewerModel = Coalesce $configObj['reviewerModel'] ''; $reviewerProvider = Coalesce $configObj['reviewerProvider'] ''; $reviewerAgent = Coalesce $configObj['reviewerAgent'] ''; $crossModelEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true; $crossModelValid = Coalesce $crossModelValidation['valid'] $true; $crossModelWarning = Coalesce $crossModelValidation['warning'] ''; $workGuidelines = Coalesce $configObj['workGuidelines'] ''; $reviewGuidelines = Coalesce $configObj['reviewGuidelines'] '' }; $statusObj = @{ sessionId = $SessionId; currentIteration = $currentIteration; maxIterations = $MaxIterations; phase = $phase; status = $status; task = if ($taskText) { $taskText } else { $null }; lastWorkSummary = if ($workSummary) { $workSummary } else { $null }; lastFeedback = if ($feedback) { $feedback } else { $null }; createdAt = if ($createdAt) { $createdAt } else { $null }; updatedAt = (Get-Date).ToString('o'); workerModel = if ($workerModel) { $workerModel } else { $null }; workerProvider = if ($workerProvider) { $workerProvider } else { $null }; workerAgent = if ($workerAgent) { $workerAgent } else { $null }; reviewerModel = if ($reviewerModel) { $reviewerModel } else { $null }; reviewerProvider = if ($reviewerProvider) { $reviewerProvider } else { $null }; reviewerAgent = if ($reviewerAgent) { $reviewerAgent } else { $null }; crossModelReviewEnforced = $crossModelEnforced; crossModelReviewValid = $crossModelValid; crossModelReviewWarning = if ($crossModelWarning) { $crossModelWarning } else { $null }; workGuidelines = if ($workGuidelines) { $workGuidelines } else { $null }; reviewGuidelines = if ($reviewGuidelines) { $reviewGuidelines } else { $null } }; return $statusObj | ConvertTo-Json -Depth 10 }
function Cleanup-ForNextIteration { param([string]$SessionId); $files = @('work-complete.txt', 'review-result.txt', 'review-feedback.txt', 'work.json', 'review.json'); foreach ($file in $files) { $path = Get-StateFile -SessionId $SessionId -FileName $file; if (Test-Path $path) { Remove-Item $path -Force } } }
function Reset-Session { param([string]$SessionId); $stateDir = Get-StateDir -SessionId $SessionId; if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force } }
function Block-Iteration { param([string]$SessionId, [string]$Reason); Ensure-StateDir -SessionId $SessionId; $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'; $Reason | Set-Content -Path $blockedFile -Encoding UTF8 }

# =============================================================================
# ORCHESTRATION HELPERS (CLI mode)
# =============================================================================
function Call-WorkerLlm { 
    param([string]$Task, [string]$Feedback, [int]$Iteration, [string]$SessionId, [string]$WorkerModel, [string]$WorkerProvider, [string]$WorkerAgent, [string]$WorkGuidelines)
    $prompt = "You are the WORKER in a Ralph Loop iteration $Iteration.`n`nTask: $Task`n"
    if ($Feedback) { $prompt += "Previous feedback from reviewer: $Feedback`nPlease revise your work based on this feedback.`n" }
    $prompt += "Provide your complete work output and a brief summary.`nOutput format:`nWORK:`n[your complete work here]`n`nSUMMARY:`n[brief summary of what you did]`n"
    switch ($WorkerProvider) { 
        'anthropic' { return $prompt | claude --model $WorkerModel --print 2>$null } 
        'openai'    { return $prompt | openai chat --model $WorkerModel --no-stream 2>$null } 
        'google'    { return $prompt | gemini --model $WorkerModel --format=text 2>$null } 
        'goose'     { 
            if ($WorkGuidelines -and (Test-Path $WorkGuidelines)) { 
                $env:GOOSE_MODEL = $WorkerModel; $env:GOOSE_PROVIDER = $WorkerProvider; return goose run --recipe $WorkGuidelines --session $SessionId --task $Task --feedback $Feedback 2>$null 
            } else { 
                $env:GOOSE_MODEL = $WorkerModel; $env:GOOSE_PROVIDER = $WorkerProvider; return goose run --session $SessionId --task $Task --feedback $Feedback 2>$null 
            } 
        } 
        'copilot' { return $prompt | gh copilot suggest 2>$null }
        default { Write-Host "Error: Unknown provider $WorkerProvider" -ForegroundColor Red; return $null } 
    } 
}

function Call-ReviewerLlm { 
    param([string]$Task, [string]$Work, [string]$Summary, [int]$Iteration, [string]$SessionId, [string]$ReviewerModel, [string]$ReviewerProvider, [string]$ReviewerAgent, [string]$ReviewGuidelines)
    $prompt = "You are the REVIEWER in a Ralph Loop iteration $Iteration.`n`nOriginal Task: $Task`n`nWorker's Work:`n$Work`n`nWorker's Summary: $Summary`n`nReview this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).`nIf REVISE, provide specific, actionable feedback for the worker.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [your feedback, or empty if SHIP]`n"
    switch ($ReviewerProvider) { 
        'anthropic' { return $prompt | claude --model $ReviewerModel --print 2>$null } 
        'openai'    { return $prompt | openai chat --model $ReviewerModel --no-stream 2>$null } 
        'google'    { return $prompt | gemini --model $ReviewerModel --format=text 2>$null } 
        'goose'     { 
            if ($ReviewGuidelines -and (Test-Path $ReviewGuidelines)) { 
                $env:GOOSE_MODEL = $ReviewerModel; $env:GOOSE_PROVIDER = $ReviewerProvider; return goose run --recipe $ReviewGuidelines --session $SessionId --work $Work --summary $Summary 2>$null 
            } else { 
                $env:GOOSE_MODEL = $ReviewerModel; $env:GOOSE_PROVIDER = $ReviewerProvider; return goose run --session $SessionId --work $Work --summary $Summary 2>$null 
            } 
        } 
        'copilot' { return $prompt | gh copilot suggest 2>$null }
        default { Write-Host "Error: Unknown provider $ReviewerProvider" -ForegroundColor Red; return $null } 
    } 
}

function Parse-WorkerOutput { param([string]$Output); $work = ''; $summary = ''; if ($Output -match '(?s)WORK:(.*?)SUMMARY:') { $work = $matches[1].Trim() }; if ($Output -match '(?s)SUMMARY:(.*)') { $summary = $matches[1].Trim() }; return @{ work = $work; summary = $summary } }
function Parse-ReviewerOutput { param([string]$Output); $decision = ''; $feedback = ''; if ($Output -match '(?i)DECISION:\s*(SHIP|REVISE)') { $decision = $matches[1].ToUpper() }; if ($Output -match '(?s)FEEDBACK:\s*(.*)') { $feedback = $matches[1].Trim() }; return @{ decision = $decision; feedback = $feedback } }

# CLI orchestration main function
function Run-Cli { 
    param([string]$TaskInput)
    $workerModel = $script:WorkerModel
    $workerProvider = $script:WorkerProvider
    $workerAgent = $script:WorkerAgent
    $reviewerModel = $script:ReviewerModel
    $reviewerProvider = $script:ReviewerProvider
    $reviewerAgent = $script:ReviewerAgent
    $maxIterations = $script:MaxIterations
    $workGuidelines = $script:WorkGuidelines
    $reviewGuidelines = $script:ReviewGuidelines

    $task = if (Test-Path $TaskInput) { Get-Content $TaskInput -Raw } else { $TaskInput }
    if (-not $task) { Write-Host "Error: No task provided" -ForegroundColor Red; Write-Host "Usage: .\ralph-loop-runner.ps1 \"task description\" or .\ralph-loop-runner.ps1 path/to/task.md" -ForegroundColor Red; exit 1 }

    # Parse command line arguments
    $args = $global:args
    for ($i = 1; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            '--worker-model' { $workerModel = $args[$i+1]; $i++ }
            '--worker-provider' { $workerProvider = $args[$i+1]; $i++ }
            '--worker-agent' { $workerAgent = $args[$i+1]; $i++ }
            '--reviewer-model' { $reviewerModel = $args[$i+1]; $i++ }
            '--reviewer-provider' { $reviewerProvider = $args[$i+1]; $i++ }
            '--reviewer-agent' { $reviewerAgent = $args[$i+1]; $i++ }
            '--max-iterations' { $maxIterations = [int]$args[$i+1]; $i++ }
            '--work-guidelines' { $workGuidelines = $args[$i+1]; $i++ }
            '--review-guidelines' { $reviewGuidelines = $args[$i+1]; $i++ }
            '--session-id' { $script:CLISessionId = $args[$i+1]; $i++ }
        }
    }

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

    $sessionId = $script:CLISessionId ?? "ralph-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "Session: $sessionId"
    Write-Host "Task: $task"
    Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"
    Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"
    if ($maxIterations -eq -1) { Write-Host "Max Iterations: unlimited" } else { Write-Host "Max Iterations: $maxIterations" }
    Write-Host ""

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $true -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines

    $feedback = ''
    $iteration = 1

    $maxIter = if ($maxIterations -eq -1) { 999999 } else { $maxIterations }

    for ($i = 1; $i -le $maxIter; $i++) {
        $iteration = $i
        Write-Host "═══════════════════════════════════════════════════════════════════════════════════════════"
        Write-Host "  Iteration $iteration / $maxIterations"
        Write-Host "═══════════════════════════════════════════════════════════════════════════════════════════"

        Write-Host "▶ WORK PHASE"
        Write-Host "Worker: $workerModel ($workerProvider) via $workerAgent"

        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $iteration -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines
        if (-not $workerOutput) { Write-Host "✗ WORK PHASE FAILED - No output from worker" -ForegroundColor Red; exit 1 }

        $parsed = Parse-WorkerOutput -Output $workerOutput
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) { Write-Host "✗ WORK PHASE FAILED - Could not parse output" -ForegroundColor Red; exit 1 }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $iteration
        Write-Host "Work submitted. Summary: $summary"
        Write-Host ""

        Write-Host "▶ REVIEW PHASE"
        Write-Host "Reviewer: $reviewerModel ($reviewerProvider) via $reviewerAgent"

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $iteration -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines
        if (-not $reviewerOutput) { Write-Host "✗ REVIEW PHASE FAILED - No output from reviewer" -ForegroundColor Red; exit 1 }

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') { Write-Host "✗ REVIEW PHASE FAILED - Invalid decision: $decision" -ForegroundColor Red; exit 1 }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $iteration

        if ($decision -eq 'SHIP') {
            Write-Host ""
            Write-Host "══════════════════════════════════════════════════════════════════════════════════════════"
            Write-Host "  ✓ SHIPPED after $iteration iteration(s)" -ForegroundColor Green
            Write-Host "═══════════════════════════════════════════════════════════════════════════════════════════"
            Write-Host "Session: $sessionId"
            Write-Host "Complete: $(Get-Date)"
            exit 0
        } else {
            Write-Host ""
            Write-Host "↻ REVISE - Feedback for next iteration:" -ForegroundColor Yellow
            Write-Host $feedback
            Write-Host ""
        }
    }

    Write-Host "✗ Max iterations ($maxIterations) reached" -ForegroundColor Red
    exit 1
}

# =============================================================================
# TOOL HANDLERS (MCP Server mode)
# =============================================================================
function Handle-Initialize { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $task = Coalesce $paramsObj['task'] ''; $maxIterations = Coalesce $paramsObj['maxIterations'] 10; $workerModel = Coalesce $paramsObj['workerModel'] ''; $workerProvider = Coalesce $paramsObj['workerProvider'] ''; $workerAgent = Coalesce $paramsObj['workerAgent'] 'goose'; $reviewerModel = Coalesce $paramsObj['reviewerModel'] ''; $reviewerProvider = Coalesce $paramsObj['reviewerProvider'] ''; $reviewerAgent = Coalesce $paramsObj['reviewerAgent'] 'goose'; $crossModelEnforced = Coalesce $paramsObj['crossModelReviewEnforced'] $true; $workGuidelines = Coalesce $paramsObj['workGuidelines'] ''; $reviewGuidelines = Coalesce $paramsObj['reviewGuidelines'] ''; if (-not $task) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Task is required' } }; Set-Task -SessionId $sessionId -Task $task; Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines; $validation = Test-CrossModel -SessionId $sessionId | JsonToDict; $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict; $result = @{ success = $true; message = "Ralph Loop initialized for session `"$sessionId`""; status = $status; crossModelReview = @{ enforced = $crossModelEnforced; valid = Coalesce $validation['valid'] $true; warning = Coalesce $validation['warning'] '' } }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-GetTask { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $task = Get-Task -SessionId $sessionId; if (-not $task) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No task found. Initialize the session first with ralph_loop_initialize.' } }; $taskObj = JsonToDict $task; $result = @{ success = $true; task = Coalesce $taskObj['task'] ''; createdAt = Coalesce $taskObj['createdAt'] '' }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-SubmitWork { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $work = Coalesce $paramsObj['work'] ''; $summary = Coalesce $paramsObj['summary'] ''; $iteration = $paramsObj['iteration']; if (-not $work -or -not $summary -or -not $iteration) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'work, summary, and iteration are required' } }; Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $iteration; $status = Get-Status -SessionId $sessionId | JsonToDict; $result = @{ success = $true; message = "Work submitted for iteration $iteration"; status = $status }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-GetWork { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $work = Get-Work -SessionId $sessionId; if (-not $work) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No work submitted yet. Worker must submit work first.' } }; $workObj = JsonToDict $work; $result = @{ success = $true; work = Coalesce $workObj['work'] ''; summary = Coalesce $workObj['summary'] ''; iteration = Coalesce $workObj['iteration'] 0; submittedAt = Coalesce $workObj['submittedAt'] '' }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-SubmitReview { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $decision = Coalesce $paramsObj['decision'] ''; $feedback = Coalesce $paramsObj['feedback'] ''; $iteration = $paramsObj['iteration']; if (-not $decision -or -not $iteration) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'decision and iteration are required' } }; if ($decision -eq 'REVISE' -and -not $feedback) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Feedback is required when decision is REVISE' } }; Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $iteration; $status = Get-Status -SessionId $sessionId | JsonToDict; $result = @{ success = $true; message = "Review submitted: $decision"; decision = $decision; feedback = $feedback; status = $status }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-GetFeedback { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $reviewResult = Get-ReviewResult -SessionId $sessionId; $feedback = Get-Feedback -SessionId $sessionId; $status = Get-Status -SessionId $sessionId | JsonToDict; if (-not $reviewResult) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No review completed yet. Reviewer must submit review first.' } }; if ($reviewResult -eq 'SHIP') { $result = @{ success = $true; shipped = $true; message = 'Work approved! SHIPPED.'; status = $status }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }; $result = @{ success = $true; shipped = $false; feedback = $feedback; iteration = $status.currentIteration; status = $status }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-GetStatus { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $config = Get-Config -SessionId $sessionId; $maxIterations = 10; if ($config) { $configObj = JsonToDict $config; $maxIterations = Coalesce $configObj['maxIterations'] 10 }; $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict; $result = @{ success = $true } + $status; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-GetConfig { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $config = Get-Config -SessionId $sessionId; if (-not $config) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'No configuration found. Initialize the session first with ralph_loop_initialize.' } }; $configObj = JsonToDict $config; $validation = Test-CrossModel -SessionId $sessionId | JsonToDict; $result = @{ success = $true; config = @{ workerModel = Coalesce $configObj['workerModel'] ''; workerProvider = Coalesce $configObj['workerProvider'] ''; workerAgent = Coalesce $configObj['workerAgent'] ''; reviewerModel = Coalesce $configObj['reviewerModel'] ''; reviewerProvider = Coalesce $configObj['reviewerProvider'] ''; reviewerAgent = Coalesce $configObj['reviewerAgent'] ''; maxIterations = Coalesce $configObj['maxIterations'] 10; crossModelReviewEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true; workGuidelines = Coalesce $configObj['workGuidelines'] ''; reviewGuidelines = Coalesce $configObj['reviewGuidelines'] ''; configuredAt = Coalesce $configObj['configuredAt'] '' }; crossModelReview = @{ enforced = Coalesce $configObj['crossModelReviewEnforced'] $true; valid = Coalesce $validation['valid'] $true; warning = Coalesce $validation['warning'] '' } }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-Reset { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; Reset-Session -SessionId $sessionId; $result = @{ success = $true; message = "Session `"$sessionId`" has been reset" }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-Block { param($Id, $Params); $paramsObj = JsonToDict $Params; $sessionId = Coalesce $paramsObj['sessionId'] 'default'; $reason = Coalesce $paramsObj['reason'] ''; if (-not $reason) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Reason is required for blocking' } }; Block-Iteration -SessionId $sessionId -Reason $reason; $result = @{ success = $true; message = 'Iteration blocked'; reason = $reason }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }
function Handle-Run { param($Id, $Params)
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

    if (-not $task) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Task is required' } }
    if (-not $workerModel -or -not $workerProvider -or -not $reviewerModel -or -not $reviewerProvider) { return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'workerModel, workerProvider, reviewerModel, and reviewerProvider are required' } }

    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced -WorkerAgent $workerAgent -ReviewerAgent $reviewerAgent -WorkGuidelines $workGuidelines -ReviewGuidelines $reviewGuidelines

    $feedback = ''

    for ($i = 1; $i -le $maxIterations; $i++) {
        $workerPrompt = "You are the WORKER in a Ralph Loop iteration $i.`n`nTask: $task`n"
        if ($feedback) { $workerPrompt += "Previous feedback from reviewer: $feedback`nPlease revise your work based on this feedback.`n" }
        $workerPrompt += "Provide your complete work output and a brief summary.`nOutput format:`nWORK:`n[your complete work here]`n`nSUMMARY:`n[brief summary of what you did]`n"

        $workerOutput = Call-WorkerLlm -Task $task -Feedback $feedback -Iteration $i -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -WorkerAgent $workerAgent -WorkGuidelines $workGuidelines
        if (-not $workerOutput) { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'WORK PHASE FAILED - No output from worker' } }

        $parsed = Parse-WorkerOutput -Output $workerOutput
        $work = $parsed.work; $summary = $parsed.summary
        if (-not $work -or -not $summary) { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'WORK PHASE FAILED - Could not parse output' } }

        Set-Work -SessionId $sessionId -Work $work -Summary $summary -Iteration $i

        $reviewerPrompt = "You are the REVIEWER in a Ralph Loop iteration $i.`n`nOriginal Task: $task`n`nWorker's Work:`n$work`n`nWorker's Summary: $summary`n`nReview this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).`nIf REVISE, provide specific, actionable feedback for the worker.`n`nOutput format:`nDECISION: SHIP or REVISE`nFEEDBACK: [your feedback, or empty if SHIP]`n"

        $reviewerOutput = Call-ReviewerLlm -Task $task -Work $work -Summary $summary -Iteration $i -SessionId $sessionId -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -ReviewerAgent $reviewerAgent -ReviewGuidelines $reviewGuidelines
        if (-not $reviewerOutput) { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'REVIEW PHASE FAILED - No output from reviewer' } }

        $parsed = Parse-ReviewerOutput -Output $reviewerOutput
        $decision = $parsed.decision; $feedback = $parsed.feedback
        if ($decision -ne 'SHIP' -and $decision -ne 'REVISE') { return New-JsonResponse -Id $Id -Error @{ code = -32603; message = 'REVIEW PHASE FAILED - Invalid decision: ' + $decision } }

        Set-Review -SessionId $sessionId -Decision $decision -Feedback $feedback -Iteration $i

        if ($decision -eq 'SHIP') {
            $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
            $result = @{ success = $true; message = "SHIPPED after $i iteration(s)"; status = $status; shipped = $true; iterations = $i }
            return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
        }
    }

    $status = Get-Status -SessionId $sessionId -MaxIterations $maxIterations | JsonToDict
    $result = @{ success = $false; message = "Max iterations ($maxIterations) reached"; status = $status; shipped = $false }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
}

function Handle-ListMethods { param($Id); $methods = @('ralph_loop_initialize','ralph_loop_get_task','ralph_loop_submit_work','ralph_loop_get_work','ralph_loop_submit_review','ralph_loop_get_feedback','ralph_loop_get_status','ralph_loop_get_config','ralph_loop_reset','ralph_loop_block','ralph_loop_run'); $result = @{ methods = $methods }; return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10) }

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

if ($args.Count -gt 0) {
    # CLI MODE: Run orchestration with task argument
    Run-Cli -TaskInput $args[0]
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
                'tools/list' { Write-Output (Handle-ListMethods -Id $id) }
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