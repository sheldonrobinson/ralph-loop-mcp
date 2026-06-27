<#>
.SYNOPSIS
    Ralph Loop MCP Server - PowerShell Implementation
    Cross-platform MCP server implementing the Ralph Loop iterative development technique
    For Windows (PowerShell 5.1+ / PowerShell 7+)

.DESCRIPTION
    Implements the Model Context Protocol (MCP) over stdio using JSON-RPC 2.0
    Provides tools for the Ralph Loop worker/reviewer iterative workflow
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration
$script:RalphStateBase = Join-Path (Join-Path $env:USERPROFILE '.goose') 'ralph'
$script:SafeCommands = @('ls', 'pwd', 'echo', 'date', 'cat', 'mkdir', 'rm', 'cp', 'mv', 'jq')
$script:CmdTimeout = 30

# Helper: Null-coalescing for PS 5.1 compatibility
function Coalesce {
    param($Value, $Default)
    if ($null -ne $Value -and $Value -ne '') { return $Value }
    return $Default
}

# Helper: Safely convert JSON to dictionary for strict mode compatibility
function JsonToDict {
    param([string]$Json)
    $obj = $Json | JsonToDict
    # Handle non-object values (strings, numbers, etc.)
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ value = $obj }
    }
    $dict = @{}
    foreach ($prop in $obj.PSObject.Properties) {
        $dict[$prop.Name] = $prop.Value
    }
    return $dict
}

# Ensure jq is available
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    $errorResp = @{
        jsonrpc = '2.0'
        id = $null
        error = @{ code = -32603; message = 'jq is required but not installed' }
    }
    Write-Output ($errorResp | ConvertTo-Json -Compress -Depth 10)
    exit 1
}

# Utility functions
function Get-StateDir {
    param([string]$SessionId = 'default')
    return Join-Path $script:RalphStateBase $SessionId
}

function Get-StateFile {
    param([string]$SessionId = 'default', [string]$FileName)
    return Join-Path (Get-StateDir -SessionId $SessionId) $FileName
}

function Ensure-StateDir {
    param([string]$SessionId = 'default')
    $dir = Get-StateDir -SessionId $SessionId
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function ConvertTo-JsonEscaped {
    param([string]$Input)
    return ($Input | ConvertTo-Json -Compress -Depth 10).Trim('"')
}

function New-JsonResponse {
    param(
        $Id,
        [string]$Result = '',
        [hashtable]$Error = $null
    )
    $resp = @{ jsonrpc = '2.0' }
    if ($null -ne $Id -and $Id -ne 'null') {
        $resp.id = $Id
    } else {
        $resp.id = $null
    }
    if ($null -ne $Error) {
        $resp.error = $Error
    } else {
        $resp.result = if ($Result) { $Result | JsonToDict } else { @{} }
    }
    return $resp | ConvertTo-Json -Compress -Depth 10
}

# Config management
function Set-Config {
    param(
        [string]$SessionId,
        [string]$WorkerModel,
        [string]$WorkerProvider,
        [string]$ReviewerModel,
        [string]$ReviewerProvider,
        [int]$MaxIterations = 10,
        [bool]$CrossModelEnforced = $true
    )
    Ensure-StateDir -SessionId $SessionId
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    
    $config = @{
        workerModel = $WorkerModel
        workerProvider = $WorkerProvider
        reviewerModel = $ReviewerModel
        reviewerProvider = $ReviewerProvider
        maxIterations = $MaxIterations
        crossModelReviewEnforced = $CrossModelEnforced
        configuredAt = (Get-Date).ToString('o')
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Encoding UTF8
}

function Get-Config {
    param([string]$SessionId = 'default')
    $configFile = Get-StateFile -SessionId $SessionId -FileName 'config.json'
    if (Test-Path $configFile) {
        return Get-Content $configFile -Raw -Encoding UTF8
    }
    return ''
}

function Test-CrossModel {
    param([string]$SessionId = 'default')
    $config = Get-Config -SessionId $SessionId
    if (-not $config) {
        return '{"valid":true}'
    }
    $configObj = $config | JsonToDict
    $enforced = $configObj.crossModelReviewEnforced
    if ($enforced -ne $true) {
        return '{"valid":true}'
    }
    $workerModel = Coalesce $configObj.workerModel ''
    $workerProvider = Coalesce $configObj.workerProvider ''
    $reviewerModel = Coalesce $configObj.reviewerModel ''
    $reviewerProvider = Coalesce $configObj.reviewerProvider ''
    
    if ($workerModel -and $reviewerModel -and $workerModel -eq $reviewerModel -and $workerProvider -eq $reviewerProvider) {
        return '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}'
    }
    return '{"valid":true}'
}

# Task management
function Set-Task {
    param([string]$SessionId, [string]$Task)
    Ensure-StateDir -SessionId $SessionId
    $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'
    $task = @{
        task = $Task
        createdAt = (Get-Date).ToString('o')
    }
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $taskFile -Encoding UTF8
    $blockedFile = Get-StateFile -SessionId $SessionId -FileName 'RALPH-BLOCKED.md'
    if (Test-Path $blockedFile) { Remove-Item $blockedFile -Force }
}

function Get-Task {
    param([string]$SessionId = 'default')
    $taskFile = Get-StateFile -SessionId $SessionId -FileName 'task.json'
    if (Test-Path $taskFile) {
        return Get-Content $taskFile -Raw -Encoding UTF8
    }
    return ''
}

# Work management
function Set-Work {
    param([string]$SessionId, [string]$Work, [string]$Summary, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'
    $work = @{
        work = $Work
        summary = $Summary
        submittedAt = (Get-Date).ToString('o')
        iteration = $Iteration
    }
    $work | ConvertTo-Json -Depth 10 | Set-Content -Path $workFile -Encoding UTF8
    $completeFile = Get-StateFile -SessionId $SessionId -FileName 'work-complete.txt'
    '{"ok":true}' | Set-Content -Path $completeFile -Encoding UTF8
}

function Get-Work {
    param([string]$SessionId = 'default')
    $workFile = Get-StateFile -SessionId $SessionId -FileName 'work.json'
    if (Test-Path $workFile) {
        return Get-Content $workFile -Raw -Encoding UTF8
    }
    return ''
}

# Review management
function Set-Review {
    param([string]$SessionId, [string]$Decision, [string]$Feedback, [int]$Iteration)
    Ensure-StateDir -SessionId $SessionId
    $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'
    $review = @{
        decision = $Decision
        feedback = $Feedback
        reviewedAt = (Get-Date).ToString('o')
        iteration = $Iteration
    }
    $review | ConvertTo-Json -Depth 10 | Set-Content -Path $reviewFile -Encoding UTF8
    
    $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'
    @{ decision = $Decision } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $resultFile -Encoding UTF8
    
    $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'
    @{ feedback = $Feedback } | ConvertTo-Json -Compress -Depth 10 | Set-Content -Path $feedbackFile -Encoding UTF8
    
    if ($Decision -eq 'REVISE') {
        Cleanup-ForNextIteration -SessionId $SessionId
    }
}

function Get-Review {
    param([string]$SessionId = 'default')
    $reviewFile = Get-StateFile -SessionId $SessionId -FileName 'review.json'
    if (Test-Path $reviewFile) {
        return Get-Content $reviewFile -Raw -Encoding UTF8
    }
    return ''
}

function Get-ReviewResult {
    param([string]$SessionId = 'default')
    $resultFile = Get-StateFile -SessionId $SessionId -FileName 'review-result.txt'
    if (Test-Path $resultFile) {
        $content = Get-Content $resultFile -Raw -Encoding UTF8
        return ($content | JsonToDict).decision
    }
    return ''
}

function Get-Feedback {
    param([string]$SessionId = 'default')
    $feedbackFile = Get-StateFile -SessionId $SessionId -FileName 'review-feedback.txt'
    if (Test-Path $feedbackFile) {
        $content = Get-Content $feedbackFile -Raw -Encoding UTF8
        return ($content | JsonToDict).feedback
    }
    return ''
}

# Status management
function Get-Status {
    param([string]$SessionId = 'default', [int]$MaxIterations = 10)
    
    $task = Get-Task -SessionId $SessionId
    $work = Get-Work -SessionId $SessionId
    $review = Get-Review -SessionId $SessionId
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
    $reviewerModel = ''
    $reviewerProvider = ''
    $crossModelEnforced = $true
    $crossModelValid = $true
    $crossModelWarning = ''
    
    if ($config) {
        $configObj = JsonToDict $config
        $workerModel = Coalesce $configObj['workerModel'] ''
        $workerProvider = Coalesce $configObj['workerProvider'] ''
        $reviewerModel = Coalesce $configObj['reviewerModel'] ''
        $reviewerProvider = Coalesce $configObj['reviewerProvider'] ''
        $crossModelEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true
        $crossModelValid = Coalesce $crossModelValidation['valid'] $true
        $crossModelWarning = Coalesce $crossModelValidation['warning'] ''
    }
    
    $statusObj = @{
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
        reviewerModel = if ($reviewerModel) { $reviewerModel } else { $null }
        reviewerProvider = if ($reviewerProvider) { $reviewerProvider } else { $null }
        crossModelReviewEnforced = $crossModelEnforced
        crossModelReviewValid = $crossModelValid
        crossModelReviewWarning = if ($crossModelWarning) { $crossModelWarning } else { $null }
    }
    return $statusObj | ConvertTo-Json -Depth 10
}

function Cleanup-ForNextIteration {
    param([string]$SessionId)
    $files = @('work-complete.txt', 'review-result.txt', 'review-feedback.txt', 'work.json', 'review.json')
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

# Tool handlers
function Handle-Initialize {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    $task = Coalesce $paramsObj['task'] ''
    $maxIterations = Coalesce $paramsObj['maxIterations'] 10
    $workerModel = Coalesce $paramsObj['workerModel'] ''
    $workerProvider = Coalesce $paramsObj['workerProvider'] ''
    $reviewerModel = Coalesce $paramsObj['reviewerModel'] ''
    $reviewerProvider = Coalesce $paramsObj['reviewerProvider'] ''
    $crossModelEnforced = Coalesce $paramsObj['crossModelReviewEnforced'] $true
    
    if (-not $task) {
        return New-JsonResponse -Id $Id -Error @{ code = -32602; message = 'Task is required' }
    }
    
    Set-Task -SessionId $sessionId -Task $task
    Set-Config -SessionId $sessionId -WorkerModel $workerModel -WorkerProvider $workerProvider -ReviewerModel $reviewerModel -ReviewerProvider $reviewerProvider -MaxIterations $maxIterations -CrossModelEnforced $crossModelEnforced
    
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
    
    $result = @{
        success = $true
        message = "Work submitted for iteration $iteration"
        status = $status
    }
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
    
    $result = @{
        success = $true
        message = "Review submitted: $decision"
        decision = $decision
        feedback = $feedback
        status = $status
    }
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
    
    $result = @{
        success = $true
        shipped = $false
        feedback = $feedback
        iteration = $status.currentIteration
        status = $status
    }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
}

function Handle-GetStatus {
    param($Id, $Params)
    $paramsObj = JsonToDict $Params
    $sessionId = Coalesce $paramsObj['sessionId'] 'default'
    
    $config = Get-Config -SessionId $sessionId
    $maxIterations = 10
    if ($config) {
        $configObj = $config | JsonToDict
        $maxIterations = Coalesce $configObj.maxIterations 10
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
            reviewerModel = Coalesce $configObj['reviewerModel'] ''
            reviewerProvider = Coalesce $configObj['reviewerProvider'] ''
            maxIterations = Coalesce $configObj['maxIterations'] 10
            crossModelReviewEnforced = Coalesce $configObj['crossModelReviewEnforced'] $true
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

function Handle-ListMethods {
    param($Id)
    $methods = @('ralph_loop_initialize','ralph_loop_get_task','ralph_loop_submit_work','ralph_loop_get_work','ralph_loop_submit_review','ralph_loop_get_feedback','ralph_loop_get_status','ralph_loop_get_config','ralph_loop_reset','ralph_loop_block')
    $result = @{ methods = $methods }
    return New-JsonResponse -Id $Id -Result ($result | ConvertTo-Json -Depth 10)
}

# Main loop
$initResp = @{
    jsonrpc = '2.0'
    id = $null
    result = @{
        protocolVersion = '2024-11-05'
        capabilities = @{ tools = @{} }
        serverInfo = @{ name = 'ralph-loop-mcp'; version = '1.0.0' }
    }
}
Write-Output ($initResp | ConvertTo-Json -Compress -Depth 10)

# Read all input from stdin (handles both piped and console input)
$allInput = $null
if ($MyInvocation.ExpectingInput) {
    $allInput = $input | Out-String
} else {
    $allInput = [Console]::In.ReadToEnd()
}
$lines = $allInput.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)

foreach ($line in $lines) {
    
    # Validate JSON
    try {
        $request = $line | JsonToDict
        $requestDict = @{}
        foreach ($prop in $request.PSObject.Properties) {
            $requestDict[$prop.Name] = $prop.Value
        }
    } catch {
        Write-Output (New-JsonResponse -Id 'null' -Error @{ code = -32700; message = 'Parse error' })
        continue
    }
    
    $method = if ($requestDict.ContainsKey('method')) { $requestDict['method'] } else { '' }
    $id = if ($requestDict.ContainsKey('id')) { $requestDict['id'] } else { 'null' }
    $params = if ($requestDict.ContainsKey('params')) { $requestDict['params'] } else { @{} }
    $paramsJson = $params | ConvertTo-Json -Compress -Depth 10
    
    switch ($method) {
        'initialize' {
            $resp = @{
                jsonrpc = '2.0'
                id = $id
                result = @{
                    protocolVersion = '2024-11-05'
                    capabilities = @{ tools = @{} }
                    serverInfo = @{ name = 'ralph-loop-mcp'; version = '1.0.0' }
                }
            }
            Write-Output ($resp | ConvertTo-Json -Compress -Depth 10)
        }
        'tools/list' {
            Write-Output (Handle-ListMethods -Id $id)
        }
        'tools/call' {
            $toolName = Coalesce $params.name ''
            $toolArgs = Coalesce $params.arguments @{}
            $toolArgsJson = $toolArgs | ConvertTo-Json -Compress -Depth 10
            
            switch ($toolName) {
                'ralph_loop_initialize' { Write-Output (Handle-Initialize -Id $id -Params $toolArgsJson) }
                'ralph_loop_get_task' { Write-Output (Handle-GetTask -Id $id -Params $toolArgsJson) }
                'ralph_loop_submit_work' { Write-Output (Handle-SubmitWork -Id $id -Params $toolArgsJson) }
                'ralph_loop_get_work' { Write-Output (Handle-GetWork -Id $id -Params $toolArgsJson) }
                'ralph_loop_submit_review' { Write-Output (Handle-SubmitReview -Id $id -Params $toolArgsJson) }
                'ralph_loop_get_feedback' { Write-Output (Handle-GetFeedback -Id $id -Params $toolArgsJson) }
                'ralph_loop_get_status' { Write-Output (Handle-GetStatus -Id $id -Params $toolArgsJson) }
                'ralph_loop_get_config' { Write-Output (Handle-GetConfig -Id $id -Params $toolArgsJson) }
                'ralph_loop_reset' { Write-Output (Handle-Reset -Id $id -Params $toolArgsJson) }
                'ralph_loop_block' { Write-Output (Handle-Block -Id $id -Params $toolArgsJson) }
                default { Write-Output (New-JsonResponse -Id $id -Error @{ code = -32601; message = "Unknown tool: $toolName" }) }
            }
        }
        default { Write-Output (New-JsonResponse -Id $id -Error @{ code = -32601; message = "Unknown method: $method" }) }
    }
}
