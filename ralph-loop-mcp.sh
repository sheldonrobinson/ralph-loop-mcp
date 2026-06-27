#!/usr/bin/env bash
# Ralph Loop MCP Server - Bash Implementation
# Cross-platform MCP server implementing the Ralph Loop iterative development technique
# For Linux/macOS - COMBINED: MCP Server + Orchestration

set -euo pipefail

# Configuration
RALPH_STATE_BASE="${HOME}/.goose/ralph"
SAFE_COMMANDS=("ls" "pwd" "echo" "date" "cat" "mkdir" "rm" "cp" "mv" "jq")
CMD_TIMEOUT=30

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq is required but not installed"}}' >&2
    exit 1
fi

# Utility functions
get_state_dir() {
    local session_id="${1:-default}"
    echo "${RALPH_STATE_BASE}/${session_id}"
}

get_state_file() {
    local session_id="${1:-default}"
    local file_name="${2}"
    echo "$(get_state_dir "${session_id}")/${file_name}"
}

ensure_state_dir() {
    local session_id="${1:-default}"
    mkdir -p "$(get_state_dir "${session_id}")"
}

json_escape() {
    printf '%s' "$1" | jq -Rs .
}

json_response() {
    local id="${1}"
    local result="${2}"
    local error="${3}"
    local resp='{"jsonrpc":"2.0"'
    if [[ -n "${id}" && "${id}" != "null" ]]; then
        resp+=",\"id\":${id}"
    else
        resp+=",\"id\":null"
    fi
    if [[ -n "${error}" ]]; then
        resp+=",\"error\":${error}"
    else
        resp+=",\"result\":${result}"
    fi
    resp+='}'
    echo "${resp}"
}

# Config management
set_config() {
    local session_id="${1}"
    local worker_model="${2}"
    local worker_provider="${3}"
    local reviewer_model="${4}"
    local reviewer_provider="${5}"
    local max_iterations="${6:-10}"
    local cross_model_enforced="${7:-true}"
    
    ensure_state_dir "${session_id}"
    local config_file="$(get_state_file "${session_id}" "config.json")"
    
    cat > "${config_file}" <<EOF
{
  "workerModel": $(json_escape "${worker_model}"),
  "workerProvider": $(json_escape "${worker_provider}"),
  "reviewerModel": $(json_escape "${reviewer_model}"),
  "reviewerProvider": $(json_escape "${reviewer_provider}"),
  "maxIterations": ${max_iterations},
  "crossModelReviewEnforced": ${cross_model_enforced},
  "configuredAt": "$(date -Iseconds)"
}
EOF
}

get_config() {
    local session_id="${1:-default}"
    local config_file="$(get_state_file "${session_id}" "config.json")"
    if [[ -f "${config_file}" ]]; then
        cat "${config_file}"
    else
        echo ""
    fi
}

validate_cross_model() {
    local session_id="${1:-default}"
    local config
    config=$(get_config "${session_id}")
    if [[ -z "${config}" ]]; then
        echo '{"valid":true}'
        return
    fi
    local enforced
    enforced=$(echo "${config}" | jq -r '.crossModelReviewEnforced // true')
    if [[ "${enforced}" != "true" ]]; then
        echo '{"valid":true}'
        return
    fi
    local worker_model worker_provider reviewer_model reviewer_provider
    worker_model=$(echo "${config}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${config}" | jq -r '.workerProvider // empty')
    reviewer_model=$(echo "${config}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${config}" | jq -r '.reviewerProvider // empty')
    
    if [[ -n "${worker_model}" && -n "${reviewer_model}" && \
          "${worker_model}" == "${reviewer_model}" && \
          "${worker_provider}" == "${reviewer_provider}" ]]; then
        echo '{"valid":false,"warning":"Worker and reviewer are the same model/provider. Cross-model review requires different models."}'
    else
        echo '{"valid":true}'
    fi
}

# Task management
set_task() {
    local session_id="${1}"
    local task="${2}"
    ensure_state_dir "${session_id}"
    local task_file="$(get_state_file "${session_id}" "task.json")"
    cat > "${task_file}" <<EOF
{
  "task": $(json_escape "${task}"),
  "createdAt": "$(date -Iseconds)"
}
EOF
    rm -f "$(get_state_file "${session_id}" "RALPH-BLOCKED.md")"
}

get_task() {
    local session_id="${1:-default}"
    local task_file="$(get_state_file "${session_id}" "task.json")"
    if [[ -f "${task_file}" ]]; then
        cat "${task_file}"
    else
        echo ""
    fi
}

# Work management
set_work() {
    local session_id="${1}"
    local work="${2}"
    local summary="${3}"
    local iteration="${4}"
    ensure_state_dir "${session_id}"
    local work_file="$(get_state_file "${session_id}" "work.json")"
    cat > "${work_file}" <<EOF
{
  "work": $(json_escape "${work}"),
  "summary": $(json_escape "${summary}"),
  "submittedAt": "$(date -Iseconds)",
  "iteration": ${iteration}
}
EOF
    echo '{"ok":true}' > "$(get_state_file "${session_id}" "work-complete.txt")"
}

get_work() {
    local session_id="${1:-default}"
    local work_file="$(get_state_file "${session_id}" "work.json")"
    if [[ -f "${work_file}" ]]; then
        cat "${work_file}"
    else
        echo ""
    fi
}

# Review management
set_review() {
    local session_id="${1}"
    local decision="${2}"
    local feedback="${3}"
    local iteration="${4}"
    ensure_state_dir "${session_id}"
    local review_file="$(get_state_file "${session_id}" "review.json")"
    cat > "${review_file}" <<EOF
{
  "decision": $(json_escape "${decision}"),
  "feedback": $(json_escape "${feedback}"),
  "reviewedAt": "$(date -Iseconds)",
  "iteration": ${iteration}
}
EOF
    echo "{\"decision\":$(json_escape "${decision}")}" > "$(get_state_file "${session_id}" "review-result.txt")"
    echo "{\"feedback\":$(json_escape "${feedback}")}" > "$(get_state_file "${session_id}" "review-feedback.txt")"
    
    if [[ "${decision}" == "REVISE" ]]; then
        cleanup_for_next_iteration "${session_id}"
    fi
}

get_review() {
    local session_id="${1:-default}"
    local review_file="$(get_state_file "${session_id}" "review.json")"
    if [[ -f "${review_file}" ]]; then
        cat "${review_file}"
    else
        echo ""
    fi
}

get_review_result() {
    local session_id="${1:-default}"
    local result_file="$(get_state_file "${session_id}" "review-result.txt")"
    if [[ -f "${result_file}" ]]; then
        cat "${result_file}" | jq -r '.decision // empty'
    else
        echo ""
    fi
}

get_feedback() {
    local session_id="${1:-default}"
    local feedback_file="$(get_state_file "${session_id}" "review-feedback.txt")"
    if [[ -f "${feedback_file}" ]]; then
        cat "${feedback_file}" | jq -r '.feedback // empty'
    else
        echo ""
    fi
}

# Status management
get_status() {
    local session_id="${1:-default}"
    local max_iterations="${2:-10}"
    
    local task work review review_result feedback blocked config
    task=$(get_task "${session_id}")
    work=$(get_work "${session_id}")
    review=$(get_review "${session_id}")
    review_result=$(get_review_result "${session_id}")
    feedback=$(get_feedback "${session_id}")
    config=$(get_config "${session_id}")
    
    local blocked="false"
    if [[ -f "$(get_state_file "${session_id}" "RALPH-BLOCKED.md")" ]]; then
        blocked="true"
    fi
    
    local cross_model_validation
    cross_model_validation=$(validate_cross_model "${session_id}")
    
    local phase="WORK"
    local status="running"
    local current_iteration=1
    
    if [[ "${blocked}" == "true" ]]; then
        phase="BLOCKED"
        status="blocked"
    elif [[ "${review_result}" == "SHIP" ]]; then
        phase="COMPLETE"
        status="shipped"
        if [[ -n "${work}" ]]; then
            current_iteration=$(echo "${work}" | jq -r '.iteration // 1')
        fi
    elif [[ "${review_result}" == "REVISE" ]]; then
        phase="WORK"
        status="revised"
        if [[ -n "${work}" ]]; then
            current_iteration=$(($(echo "${work}" | jq -r '.iteration // 1') + 1))
        fi
    elif [[ -n "${work}" ]]; then
        phase="REVIEW"
        status="running"
        current_iteration=$(echo "${work}" | jq -r '.iteration // 1')
    fi
    
    if [[ ${current_iteration} -gt ${max_iterations} && "${status}" == "running" ]]; then
        status="max_iterations_reached"
        phase="COMPLETE"
    fi
    
    local task_text="" created_at=""
    if [[ -n "${task}" ]]; then
        task_text=$(echo "${task}" | jq -r '.task // empty')
        created_at=$(echo "${task}" | jq -r '.createdAt // empty')
    fi
    
    local work_summary=""
    if [[ -n "${work}" ]]; then
        work_summary=$(echo "${work}" | jq -r '.summary // empty')
    fi
    
    local worker_model="" worker_provider="" reviewer_model="" reviewer_provider=""
    local cross_model_enforced="" cross_model_valid="" cross_model_warning=""
    if [[ -n "${config}" ]]; then
        worker_model=$(echo "${config}" | jq -r '.workerModel // empty')
        worker_provider=$(echo "${config}" | jq -r '.workerProvider // empty')
        reviewer_model=$(echo "${config}" | jq -r '.reviewerModel // empty')
        reviewer_provider=$(echo "${config}" | jq -r '.reviewerProvider // empty')
        cross_model_enforced=$(echo "${config}" | jq -r '.crossModelReviewEnforced // true')
        cross_model_valid=$(echo "${cross_model_validation}" | jq -r '.valid // true')
        cross_model_warning=$(echo "${cross_model_validation}" | jq -r '.warning // empty')
    fi
    
    local status_json
    status_json=$(jq -n \
        --arg sessionId "${session_id}" \
        --argjson currentIteration "${current_iteration}" \
        --argjson maxIterations "${max_iterations}" \
        --arg phase "${phase}" \
        --arg status "${status}" \
        --arg task "${task_text}" \
        --arg lastWorkSummary "${work_summary}" \
        --arg lastFeedback "${feedback}" \
        --arg createdAt "${created_at}" \
        --arg updatedAt "$(date -Iseconds)" \
        --arg workerModel "${worker_model}" \
        --arg workerProvider "${worker_provider}" \
        --arg reviewerModel "${reviewer_model}" \
        --arg reviewerProvider "${reviewer_provider}" \
        --argjson crossModelEnforced "${cross_model_enforced}" \
        --argjson crossModelValid "${cross_model_valid}" \
        --arg crossModelWarning "${cross_model_warning}" \
        '{
            sessionId: $sessionId,
            currentIteration: $currentIteration,
            maxIterations: $maxIterations,
            phase: $phase,
            status: $status,
            task: (if $task == "" then null else $task end),
            lastWorkSummary: (if $lastWorkSummary == "" then null else $lastWorkSummary end),
            lastFeedback: (if $lastFeedback == "" then null else $lastFeedback end),
            createdAt: (if $createdAt == "" then null else $createdAt end),
            updatedAt: $updatedAt,
            workerModel: (if $workerModel == "" then null else $workerModel end),
            workerProvider: (if $workerProvider == "" then null else $workerProvider end),
            reviewerModel: (if $reviewerModel == "" then null else $reviewerModel end),
            reviewerProvider: (if $reviewerProvider == "" then null else $reviewerProvider end),
            crossModelReviewEnforced: $crossModelEnforced,
            crossModelReviewValid: $crossModelValid,
            crossModelReviewWarning: (if $crossModelWarning == "" then null else $crossModelWarning end)
        }')
    
    echo "${status_json}"
}

cleanup_for_next_iteration() {
    local session_id="${1}"
    rm -f "$(get_state_file "${session_id}" "work-complete.txt")"
    rm -f "$(get_state_file "${session_id}" "review-result.txt")"
    rm -f "$(get_state_file "${session_id}" "review-feedback.txt")"
    rm -f "$(get_state_file "${session_id}" "work.json")"
    rm -f "$(get_state_file "${session_id}" "review.json")"
}

reset_session() {
    local session_id="${1}"
    local state_dir
    state_dir=$(get_state_dir "${session_id}")
    if [[ -d "${state_dir}" ]]; then
        rm -rf "${state_dir}"
    fi
}

block_iteration() {
    local session_id="${1}"
    local reason="${2}"
    ensure_state_dir "${session_id}"
    echo "${reason}" > "$(get_state_file "${session_id}" "RALPH-BLOCKED.md")"
}

# =============================================================================
# ORCHESTRATION FUNCTIONS (combined from ralph-loop.sh)
# =============================================================================

call_llm_worker() {
    local task="$1"
    local feedback="$2"
    local iteration="$3"
    local session_id="$4"
    local worker_model="$5"
    local worker_provider="$6"
    
    local prompt="You are the WORKER in a Ralph Loop iteration ${iteration}.
    
Task: ${task}"
    
    if [[ -n "${feedback}" ]]; then
        prompt="${prompt}

Previous feedback from reviewer: ${feedback}

Please revise your work based on this feedback."
    fi
    
    prompt="${prompt}

Provide your complete work output and a brief summary.
Output format:
WORK:
[your complete work here]

SUMMARY:
[brief summary of what you did]"
    
    case "${worker_provider}" in
        anthropic)
            echo "${prompt}" | claude --model "${worker_model}" --print 2>/dev/null
            ;;
        openai)
            echo "${prompt}" | openai chat --model "${worker_model}" --no-stream 2>/dev/null
            ;;
        google)
            echo "${prompt}" | gemini --model "${worker_model}" --format=text 2>/dev/null
            ;;
        goose)
            GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
            goose run --recipe ralph-work --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null
            ;;
        *)
            echo "Error: Unknown provider ${worker_provider}" >&2
            return 1
            ;;
    esac
}

call_llm_reviewer() {
    local task="$1"
    local work="$2"
    local summary="$3"
    local iteration="$4"
    local session_id="$5"
    local reviewer_model="$6"
    local reviewer_provider="$7"
    
    local prompt="You are the REVIEWER in a Ralph Loop iteration ${iteration}.
    
Original Task: ${task}

Worker's Work:
${work}

Worker's Summary: ${summary}

Review this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).
If REVISE, provide specific, actionable feedback for the worker.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [your feedback, or empty if SHIP]"
    
    case "${reviewer_provider}" in
        anthropic)
            echo "${prompt}" | claude --model "${reviewer_model}" --print 2>/dev/null
            ;;
        openai)
            echo "${prompt}" | openai chat --model "${reviewer_model}" --no-stream 2>/dev/null
            ;;
        google)
            echo "${prompt}" | gemini --model "${reviewer_model}" --format=text 2>/dev/null
            ;;
        goose)
            GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
            goose run --recipe ralph-review --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null
            ;;
        *)
            echo "Error: Unknown provider ${reviewer_provider}" >&2
            return 1
            ;;
    esac
}

parse_worker_output() {
    local output="$1"
    local work=""
    local summary=""
    
    if [[ "${output}" == *"WORK:"* ]]; then
        work=$(echo "${output}" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
    fi
    if [[ "${output}" == *"SUMMARY:"* ]]; then
        summary=$(echo "${output}" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    echo "${work}|${summary}"
}

parse_reviewer_output() {
    local output="$1"
    local decision=""
    local feedback=""
    
    if [[ "${output}" == *"DECISION:"* ]]; then
        decision=$(echo "${output}" | grep -i "^DECISION:" | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        decision=$(echo "${decision}" | tr '[:lower:]' '[:upper:]')
    fi
    if [[ "${output}" == *"FEEDBACK:"* ]]; then
        feedback=$(echo "${output}" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    echo "${decision}|${feedback}"
}

# =============================================================================
# TOOL HANDLERS
# =============================================================================

handle_initialize() {
    local id="${1}"
    local params="${2}"
    local session_id task max_iterations worker_model worker_provider reviewer_model reviewer_provider cross_model_enforced
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    task=$(echo "${params}" | jq -r '.task // empty')
    max_iterations=$(echo "${params}" | jq -r '.maxIterations // 10')
    worker_model=$(echo "${params}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${params}" | jq -r '.workerProvider // empty')
    reviewer_model=$(echo "${params}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${params}" | jq -r '.reviewerProvider // empty')
    cross_model_enforced=$(echo "${params}" | jq -r '.crossModelReviewEnforced // true')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}"
    
    local validation
    validation=$(validate_cross_model "${session_id}")
    local status
    status=$(get_status "${session_id}" "${max_iterations}")
    
    local result
    result=$(jq -n \
        --arg msg "Ralph Loop initialized for session \"${session_id}\"" \
        --argjson status "${status}" \
        --argjson validation "${validation}" \
        --argjson enforced "${cross_model_enforced}" \
        '{success: true, message: $msg, status: $status, crossModelReview: {enforced: $enforced, valid: $validation.valid, warning: $validation.warning}}')
    
    echo $(json_response "${id}" "${result}")
}

handle_get_task() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    local task
    task=$(get_task "${session_id}")
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"No task found. Initialize the session first with ralph_loop_initialize."}')
        return
    fi
    
    local result
    result=$(echo "${task}" | jq '{success: true, task: .task, createdAt: .createdAt}')
    echo $(json_response "${id}" "${result}")
}

handle_submit_work() {
    local id="${1}"
    local params="${2}"
    local session_id work summary iteration
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    work=$(echo "${params}" | jq -r '.work // empty')
    summary=$(echo "${params}" | jq -r '.summary // empty')
    iteration=$(echo "${params}" | jq -r '.iteration // empty')
    
    if [[ -z "${work}" || -z "${summary}" || -z "${iteration}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"work, summary, and iteration are required"}')
        return
    fi
    
    set_work "${session_id}" "${work}" "${summary}" "${iteration}"
    local status
    status=$(get_status "${session_id}")
    
    local result
    result=$(jq -n \
        --arg msg "Work submitted for iteration ${iteration}" \
        --argjson status "${status}" \
        '{success: true, message: $msg, status: $status}')
    
    echo $(json_response "${id}" "${result}")
}

handle_get_work() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    local work
    work=$(get_work "${session_id}")
    
    if [[ -z "${work}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"No work submitted yet. Worker must submit work first."}')
        return
    fi
    
    local result
    result=$(echo "${work}" | jq '{success: true, work: .work, summary: .summary, iteration: .iteration, submittedAt: .submittedAt}')
    echo $(json_response "${id}" "${result}")
}

handle_submit_review() {
    local id="${1}"
    local params="${2}"
    local session_id decision feedback iteration
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    decision=$(echo "${params}" | jq -r '.decision // empty')
    feedback=$(echo "${params}" | jq -r '.feedback // empty')
    iteration=$(echo "${params}" | jq -r '.iteration // empty')
    
    if [[ -z "${decision}" || -z "${iteration}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"decision and iteration are required"}')
        return
    fi
    
    if [[ "${decision}" == "REVISE" && -z "${feedback}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Feedback is required when decision is REVISE"}')
        return
    fi
    
    set_review "${session_id}" "${decision}" "${feedback}" "${iteration}"
    local status
    status=$(get_status "${session_id}")
    
    local result
    result=$(jq -n \
        --arg msg "Review submitted: ${decision}" \
        --arg decision "${decision}" \
        --arg feedback "${feedback}" \
        --argjson status "${status}" \
        '{success: true, message: $msg, decision: $decision, feedback: $feedback, status: $status}')
    
    echo $(json_response "${id}" "${result}")
}

handle_get_feedback() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    local review_result feedback status
    review_result=$(get_review_result "${session_id}")
    feedback=$(get_feedback "${session_id}")
    status=$(get_status "${session_id}")
    
    if [[ -z "${review_result}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"No review completed yet. Reviewer must submit review first."}')
        return
    fi
    
    if [[ "${review_result}" == "SHIP" ]]; then
        local result
        result=$(jq -n \
            --argjson status "${status}" \
            '{success: true, shipped: true, message: "Work approved! SHIPPED.", status: $status}')
        echo $(json_response "${id}" "${result}")
        return
    fi
    
    local result
    result=$(jq -n \
        --arg feedback "${feedback}" \
        --argjson iteration "$(echo "${status}" | jq -r '.currentIteration')" \
        --argjson status "${status}" \
        '{success: true, shipped: false, feedback: $feedback, iteration: $iteration, status: $status}')
    echo $(json_response "${id}" "${result}")
}

handle_get_status() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    local config max_iterations
    config=$(get_config "${session_id}")
    if [[ -n "${config}" ]]; then
        max_iterations=$(echo "${config}" | jq -r '.maxIterations // 10')
    else
        max_iterations=10
    fi
    
    local status
    status=$(get_status "${session_id}" "${max_iterations}")
    
    local result
    result=$(echo "${status}" | jq '{success: true} + .')
    echo $(json_response "${id}" "${result}")
}

handle_get_config() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    local config
    config=$(get_config "${session_id}")
    
    if [[ -z "${config}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"No configuration found. Initialize the session first with ralph_loop_initialize."}')
        return
    fi
    
    local validation
    validation=$(validate_cross_model "${session_id}")
    
    local result
    result=$(jq -n \
        --argjson config "${config}" \
        --argjson validation "${validation}" \
        '{success: true, config: {workerModel: $config.workerModel, workerProvider: $config.workerProvider, reviewerModel: $config.reviewerModel, reviewerProvider: $config.reviewerProvider, maxIterations: $config.maxIterations, crossModelReviewEnforced: $config.crossModelReviewEnforced, configuredAt: $config.configuredAt}, crossModelReview: {enforced: $config.crossModelReviewEnforced, valid: $validation.valid, warning: $validation.warning}}')
    
    echo $(json_response "${id}" "${result}")
}

handle_reset() {
    local id="${1}"
    local params="${2}"
    local session_id
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    
    reset_session "${session_id}"
    
    local result
    result=$(jq -n --arg msg "Session \"${session_id}\" has been reset" '{success: true, message: $msg}')
    echo $(json_response "${id}" "${result}")
}

handle_block() {
    local id="${1}"
    local params="${2}"
    local session_id reason
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    reason=$(echo "${params}" | jq -r '.reason // empty')
    
    if [[ -z "${reason}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Reason is required for blocking"}')
        return
    fi
    
    block_iteration "${session_id}" "${reason}"
    
    local result
    result=$(jq -n --arg msg "Iteration blocked" --arg reason "${reason}" '{success: true, message: $msg, reason: $reason}')
    echo $(json_response "${id}" "${result}")
}

# =============================================================================
# MAIN ORCHESTRATION TOOL: ralph_loop_run
# =============================================================================

handle_run() {
    local id="${1}"
    local params="${2}"
    local session_id task max_iterations worker_model worker_provider reviewer_model reviewer_provider cross_model_enforced
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    task=$(echo "${params}" | jq -r '.task // empty')
    max_iterations=$(echo "${params}" | jq -r '.maxIterations // 10')
    worker_model=$(echo "${params}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${params}" | jq -r '.workerProvider // empty')
    reviewer_model=$(echo "${params}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${params}" | jq -r '.reviewerProvider // empty')
    cross_model_enforced=$(echo "${params}" | jq -r '.crossModelReviewEnforced // true')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    if [[ -z "${worker_model}" || -z "${worker_provider}" || -z "${reviewer_model}" || -z "${reviewer_provider}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"workerModel, workerProvider, reviewerModel, and reviewerProvider are required"}')
        return
    fi
    
    # Initialize session (combines initialize + config)
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}"
    
    local feedback=""
    local result
    
    for ((i=1; i<=max_iterations; i++)); do
        # WORK PHASE
        local worker_prompt="You are the WORKER in a Ralph Loop iteration ${i}.
    
Task: ${task}"
        
        if [[ -n "${feedback}" ]]; then
            worker_prompt="${worker_prompt}

Previous feedback from reviewer: ${feedback}

Please revise your work based on this feedback."
        fi
        
        worker_prompt="${worker_prompt}

Provide your complete work output and a brief summary.
Output format:
WORK:
[your complete work here]

SUMMARY:
[brief summary of what you did]"
        
        local worker_output
        case "${worker_provider}" in
            anthropic)
                worker_output=$(echo "${worker_prompt}" | claude --model "${worker_model}" --print 2>/dev/null)
                ;;
            openai)
                worker_output=$(echo "${worker_prompt}" | openai chat --model "${worker_model}" --no-stream 2>/dev/null)
                ;;
            google)
                worker_output=$(echo "${worker_prompt}" | gemini --model "${worker_model}" --format=text 2>/dev/null)
                ;;
            goose)
                GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
                worker_output=$(goose run --recipe ralph-work --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null)
                ;;
            *)
                echo $(json_response "${id}" "" '{"code":-32602,"message":"Unknown worker provider: '"${worker_provider}"'"}')
                return
                ;;
        esac
        
        if [[ -z "${worker_output}" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"WORK PHASE FAILED - No output from worker"}')
            return
        fi
        
        # Parse worker output
        local work summary
        work=$(echo "${worker_output}" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
        summary=$(echo "${worker_output}" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
        
        if [[ -z "${work}" || -z "${summary}" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"WORK PHASE FAILED - Could not parse output"}')
            return
        fi
        
        # Submit work via internal state functions
        set_work "${session_id}" "${work}" "${summary}" "${i}"
        
        # REVIEW PHASE
        local reviewer_prompt="You are the REVIEWER in a Ralph Loop iteration ${i}.
    
Original Task: ${task}

Worker's Work:
${work}

Worker's Summary: ${summary}

Review this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).
If REVISE, provide specific, actionable feedback for the worker.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [your feedback, or empty if SHIP]"
        
        local reviewer_output
        case "${reviewer_provider}" in
            anthropic)
                reviewer_output=$(echo "${reviewer_prompt}" | claude --model "${reviewer_model}" --print 2>/dev/null)
                ;;
            openai)
                reviewer_output=$(echo "${reviewer_prompt}" | openai chat --model "${reviewer_model}" --no-stream 2>/dev/null)
                ;;
            google)
                reviewer_output=$(echo "${reviewer_prompt}" | gemini --model "${reviewer_model}" --format=text 2>/dev/null)
                ;;
            goose)
                GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
                reviewer_output=$(goose run --recipe ralph-review --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null)
                ;;
            *)
                echo $(json_response "${id}" "" '{"code":-32602,"message":"Unknown reviewer provider: '"${reviewer_provider}"'"}')
                return
                ;;
        esac
        
        if [[ -z "${reviewer_output}" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"REVIEW PHASE FAILED - No output from reviewer"}')
            return
        fi
        
        # Parse reviewer output
        local decision
        decision=$(echo "${reviewer_output}" | grep -i "^DECISION:" | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        decision=$(echo "${decision}" | tr '[:lower:]' '[:upper:]')
        feedback=$(echo "${reviewer_output}" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
        
        if [[ "${decision}" != "SHIP" && "${decision}" != "REVISE" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"REVIEW PHASE FAILED - Invalid decision: '"${decision}"'"}')
            return
        fi
        
        # Submit review via internal state functions
        set_review "${session_id}" "${decision}" "${feedback}" "${i}"
        
        if [[ "${decision}" == "SHIP" ]]; then
            local status
            status=$(get_status "${session_id}" "${max_iterations}")
            result=$(jq -n --arg msg "SHIPPED after ${i} iteration(s)" --argjson status "${status}" '{success: true, message: $msg, status: $status, shipped: true, iterations: $i}')
            echo $(json_response "${id}" "${result}")
            return
        else
            # Continue to next iteration
            continue
        fi
    done
    
    # Max iterations reached
    local status
    status=$(get_status "${session_id}" "${max_iterations}")
    result=$(jq -n --arg msg "Max iterations (${max_iterations}) reached" --argjson status "${status}" '{success: false, message: $msg, status: $status, shipped: false}')
    echo $(json_response "${id}" "${result}")
}

handle_list_methods() {
    local id="${1}"
    local methods='["ralph_loop_initialize","ralph_loop_get_task","ralph_loop_submit_work","ralph_loop_get_work","ralph_loop_submit_review","ralph_loop_get_feedback","ralph_loop_get_status","ralph_loop_get_config","ralph_loop_reset","ralph_loop_block","ralph_loop_run"]'
    local result=$(jq -n --argjson methods "${methods}" '{methods: $methods}')
    echo $(json_response "${id}" "${result}")
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Send initialization response
echo '{"jsonrpc":"2.0","id":null,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ralph-loop-mcp","version":"1.0.0"}}}'

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    
    # Validate JSON
    if ! echo "${line}" | jq empty >/dev/null 2>&1; then
        echo $(json_response "null" "" '{"code":-32700,"message":"Parse error"}')
        continue
    fi
    
    method=$(echo "${line}" | jq -r '.method // empty')
    id=$(echo "${line}" | jq -r '.id // null')
    params=$(echo "${line}" | jq -c '.params // {}')
    
    case "${method}" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":'$id',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ralph-loop-mcp","version":"1.0.0"}}}'
            ;;
        "tools/list")
            handle_list_methods "${id}"
            ;;
        "tools/call")
            tool_name=$(echo "${params}" | jq -r '.name // empty')
            tool_args=$(echo "${params}" | jq -c '.arguments // {}')
            case "${tool_name}" in
                "ralph_loop_initialize")
                    handle_initialize "${id}" "${tool_args}"
                    ;;
                "ralph_loop_get_task")
                    handle_get_task "${id}" "${tool_args}"
                    ;;
                "ralph_loop_submit_work")
                    handle_submit_work "${id}" "${tool_args}"
                    ;;
                "ralph_loop_get_work")
                    handle_get_work "${id}" "${tool_args}"
                    ;;
                "ralph_loop_submit_review")
                    handle_submit_review "${id}" "${tool_args}"
                    ;;
                "ralph_loop_get_feedback")
                    handle_get_feedback "${id}" "${tool_args}"
                    ;;
                "ralph_loop_get_status")
                    handle_get_status "${id}" "${tool_args}"
                    ;;
                "ralph_loop_get_config")
                    handle_get_config "${id}" "${tool_args}"
                    ;;
                "ralph_loop_reset")
                    handle_reset "${id}" "${tool_args}"
                    ;;
                "ralph_loop_block")
                    handle_block "${id}" "${tool_args}"
                    ;;
                "ralph_loop_run")
                    handle_run "${id}" "${tool_args}"
                    ;;
                *)
                    echo $(json_response "${id}" "" '{"code":-32601,"message":"Unknown tool: '"${tool_name}"'"}')
                    ;;
            esac
            ;;
        *)
            echo $(json_response "${id}" "" '{"code":-32601,"message":"Unknown method: '"${method}"'"}')
            ;;
    esac
done