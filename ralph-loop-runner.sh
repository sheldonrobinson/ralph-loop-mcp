#!/usr/bin/env bash
# ralph-loop-runner - Bash Implementation (Unified: MCP Server + CLI Orchestration)
# Cross-platform implementation of the Ralph Loop iterative development technique
# For Linux/macOS

set -euo pipefail

# =============================================================================
# CONFIGURATION (from environment variables with defaults)
# =============================================================================
RALPH_STATE_BASE="${HOME}/.goose/ralph"
RALPH_RECIPE_DIR="${RALPH_RECIPE_DIR:-/usr/local/share/ralph-loop-runner/recipes}"
SAFE_COMMANDS=("ls" "pwd" "echo" "date" "cat" "mkdir" "rm" "cp" "mv" "jq")
CMD_TIMEOUT=30

# Environment variable defaults
WORKER_MODEL="${RALPH_WORKER_MODEL:-}"
WORKER_PROVIDER="${RALPH_WORKER_PROVIDER:-}"
WORKER_AGENT="${RALPH_WORKER_AGENT:-goose}"
REVIEWER_MODEL="${RALPH_REVIEWER_MODEL:-}"
REVIEWER_PROVIDER="${RALPH_REVIEWER_PROVIDER:-}"
REVIEWER_AGENT="${RALPH_REVIEWER_AGENT:-goose}"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-10}"
WORK_GUIDELINES="${RALPH_WORK_GUIDELINES:-${RALPH_RECIPE_DIR}/ralph-work.yaml}"
REVIEW_GUIDELINES="${RALPH_REVIEW_GUIDELINES:-${RALPH_RECIPE_DIR}/ralph-review.yaml}"

# CLI argument defaults (can be overridden by command line)
CLI_TASK=""
CLI_SESSION_ID=""

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"jq is required but not installed"}}' >&2
    exit 1
fi

# =============================================================================
# UTILITY FUNCTIONS (shared by both modes)
# =============================================================================
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

# =============================================================================
# CONFIG MANAGEMENT
# =============================================================================
set_config() {
    local session_id="${1}"
    local worker_model="${2}"
    local worker_provider="${3}"
    local reviewer_model="${4}"
    local reviewer_provider="${5}"
    local max_iterations="${6:-10}"
    local cross_model_enforced="${7:-true}"
    local worker_agent="${8:-goose}"
    local reviewer_agent="${9:-goose}"
    local work_guidelines="${10}"
    local review_guidelines="${11}"
    
    ensure_state_dir "${session_id}"
    local config_file="$(get_state_file "${session_id}" "config.json")"
    
    cat > "${config_file}" <<EOF
{
  "workerModel": $(json_escape "${worker_model}"),
  "workerProvider": $(json_escape "${worker_provider}"),
  "workerAgent": $(json_escape "${worker_agent}"),
  "reviewerModel": $(json_escape "${reviewer_model}"),
  "reviewerProvider": $(json_escape "${reviewer_provider}"),
  "reviewerAgent": $(json_escape "${reviewer_agent}"),
  "maxIterations": ${max_iterations},
  "crossModelReviewEnforced": ${cross_model_enforced},
  "workGuidelines": $(json_escape "${work_guidelines}"),
  "reviewGuidelines": $(json_escape "${review_guidelines}"),
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

# =============================================================================
# TASK MANAGEMENT
# =============================================================================
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

# =============================================================================
# WORK MANAGEMENT
# =============================================================================
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

# =============================================================================
# REVIEW MANAGEMENT
# =============================================================================
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

# =============================================================================
# STATUS MANAGEMENT
# =============================================================================
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
    
    local worker_model="" worker_provider="" worker_agent="" reviewer_model="" reviewer_provider="" reviewer_agent=""
    local cross_model_enforced="" cross_model_valid="" cross_model_warning="" work_guidelines="" review_guidelines=""
    if [[ -n "${config}" ]]; then
        worker_model=$(echo "${config}" | jq -r '.workerModel // empty')
        worker_provider=$(echo "${config}" | jq -r '.workerProvider // empty')
        worker_agent=$(echo "${config}" | jq -r '.workerAgent // empty')
        reviewer_model=$(echo "${config}" | jq -r '.reviewerModel // empty')
        reviewer_provider=$(echo "${config}" | jq -r '.reviewerProvider // empty')
        reviewer_agent=$(echo "${config}" | jq -r '.reviewerAgent // empty')
        cross_model_enforced=$(echo "${config}" | jq -r '.crossModelReviewEnforced // true')
        cross_model_valid=$(echo "${cross_model_validation}" | jq -r '.valid // true')
        cross_model_warning=$(echo "${cross_model_validation}" | jq -r '.warning // empty')
        work_guidelines=$(echo "${config}" | jq -r '.workGuidelines // empty')
        review_guidelines=$(echo "${config}" | jq -r '.reviewGuidelines // empty')
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
        --arg workerAgent "${worker_agent}" \
        --arg reviewerModel "${reviewer_model}" \
        --arg reviewerProvider "${reviewer_provider}" \
        --arg reviewerAgent "${reviewer_agent}" \
        --argjson crossModelEnforced "${cross_model_enforced}" \
        --argjson crossModelValid "${cross_model_valid}" \
        --arg crossModelWarning "${cross_model_warning}" \
        --arg workGuidelines "${work_guidelines}" \
        --arg reviewGuidelines "${review_guidelines}" \
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
            workerAgent: (if $workerAgent == "" then null else $workerAgent end),
            reviewerModel: (if $reviewerModel == "" then null else $reviewerModel end),
            reviewerProvider: (if $reviewerProvider == "" then null else $reviewerProvider end),
            reviewerAgent: (if $reviewerAgent == "" then null else $reviewerAgent end),
            crossModelReviewEnforced: $crossModelEnforced,
            crossModelReviewValid: $crossModelValid,
            crossModelReviewWarning: (if $crossModelWarning == "" then null else $crossModelWarning end),
            workGuidelines: (if $workGuidelines == "" then null else $workGuidelines end),
            reviewGuidelines: (if $reviewGuidelines == "" then null else $reviewGuidelines end)
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
# ORCHESTRATION FUNCTIONS (CLI mode)
# =============================================================================

call_llm_worker() {
    local task="$1"
    local feedback="$2"
    local iteration="$3"
    local session_id="$4"
    local worker_model="$5"
    local worker_provider="$6"
    local worker_agent="$7"
    local work_guidelines="$8"
    
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
        copilot)
            # GitHub Copilot CLI
            copilot -p --allow-all-tools "${prompt}" 2>/dev/null
            ;;
        goose)
            if [[ -n "${work_guidelines}" && -f "${work_guidelines}" ]]; then
                GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
                goose run --recipe "${work_guidelines}" --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null
            else
                GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
                goose run --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null
            fi
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
    local reviewer_agent="$8"
    local review_guidelines="$9"
    
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
        copilot)
            # GitHub Copilot CLI
            copilot -p --allow-all-tools "${prompt}" 2>/dev/null
            ;;
        goose)
            if [[ -n "${review_guidelines}" && -f "${review_guidelines}" ]]; then
                GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
                goose run --recipe "${review_guidelines}" --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null
            else
                GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
                goose run --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null
            fi
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

# CLI orchestration main function
run_cli() {
    local task_input="${1}"
    local worker_model="${WORKER_MODEL}"
    local worker_provider="${WORKER_PROVIDER}"
    local worker_agent="${WORKER_AGENT}"
    local reviewer_model="${REVIEWER_MODEL}"
    local reviewer_provider="${REVIEWER_PROVIDER}"
    local reviewer_agent="${REVIEWER_AGENT}"
    local max_iterations="${MAX_ITERATIONS}"
    local work_guidelines="${WORK_GUIDELINES}"
    local review_guidelines="${REVIEW_GUIDELINES}"
    
    # Get task from file or argument
    local task
    if [[ -f "${task_input}" ]]; then
        task=$(cat "${task_input}")
    else
        task="${task_input}"
    fi
    
    if [[ -z "${task}" ]]; then
        echo "Error: No task provided"
        echo "Usage: $0 \"task description\" or $0 /path/to/task.md"
        echo ""
        echo "Options:"
        echo "  --worker-model MODEL         Worker model (default: \$RALPH_WORKER_MODEL)"
        echo "  --worker-provider PROVIDER   Worker provider (default: \$RALPH_WORKER_PROVIDER)"
        echo "  --worker-agent AGENT         Worker agent (default: \$RALPH_WORKER_AGENT)"
        echo "  --reviewer-model MODEL       Reviewer model (default: \$RALPH_REVIEWER_MODEL)"
        echo "  --reviewer-provider PROVIDER Reviewer provider (default: \$RALPH_REVIEWER_PROVIDER)"
        echo "  --reviewer-agent AGENT       Reviewer agent (default: \$RALPH_REVIEWER_AGENT)"
        echo "  --max-iterations N           Max iterations, -1 for infinite (default: \$RALPH_MAX_ITERATIONS)"
        echo "  --work-guidelines FILE       Work guidelines/recipe file (default: \$RALPH_WORK_GUIDELINES)"
        echo "  --review-guidelines FILE     Review guidelines/recipe file (default: \$RALPH_REVIEW_GUIDELINES)"
        echo "  --session-id ID              Session ID (default: auto-generated)"
        exit 1
    fi
    
    # Parse command line arguments
    while [[ $# -gt 1 ]]; do
        case "${2}" in
            --worker-model)
                worker_model="${3}"
                shift 2
                ;;
            --worker-provider)
                worker_provider="${3}"
                shift 2
                ;;
            --worker-agent)
                worker_agent="${3}"
                shift 2
                ;;
            --reviewer-model)
                reviewer_model="${3}"
                shift 2
                ;;
            --reviewer-provider)
                reviewer_provider="${3}"
                shift 2
                ;;
            --reviewer-agent)
                reviewer_agent="${3}"
                shift 2
                ;;
            --max-iterations)
                max_iterations="${3}"
                shift 2
                ;;
            --work-guidelines)
                work_guidelines="${3}"
                shift 2
                ;;
            --review-guidelines)
                review_guidelines="${3}"
                shift 2
                ;;
            --session-id)
                CLI_SESSION_ID="${3}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Prompt for missing config
    if [[ -z "${worker_model}" ]]; then
        echo -ne "Worker model: "
        read -r worker_model
        if [[ -z "${worker_model}" ]]; then exit 1; fi
    fi
    if [[ -z "${worker_provider}" ]]; then
        echo -ne "Worker provider (anthropic/openai/google/goose/copilot): "
        read -r worker_provider
        if [[ -z "${worker_provider}" ]]; then exit 1; fi
    fi
    if [[ -z "${worker_agent}" ]]; then
        echo -ne "Worker agent (goose/claude/openai/gemini/copilot): "
        read -r worker_agent
        if [[ -z "${worker_agent}" ]]; then exit 1; fi
    fi
    if [[ -z "${reviewer_model}" ]]; then
        echo -ne "Reviewer model (should be different from worker): "
        read -r reviewer_model
        if [[ -z "${reviewer_model}" ]]; then exit 1; fi
    fi
    if [[ -z "${reviewer_provider}" ]]; then
        echo -ne "Reviewer provider (anthropic/openai/google/goose/copilot): "
        read -r reviewer_provider
        if [[ -z "${reviewer_provider}" ]]; then exit 1; fi
    fi
    if [[ -z "${reviewer_agent}" ]]; then
        echo -ne "Reviewer agent (goose/claude/openai/gemini/copilot): "
        read -r reviewer_agent
        if [[ -z "${reviewer_agent}" ]]; then exit 1; fi
    fi
    
    if [[ "${worker_model}" == "${reviewer_model}" && "${worker_provider}" == "${reviewer_provider}" ]]; then
        echo "Warning: Worker and reviewer are the same model/provider."
        echo -ne "Continue? [y/N]: "
        read -r confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then exit 1; fi
    fi
    
    local session_id="${CLI_SESSION_ID:-ralph-$(date +%s)}"
    echo "Session: ${session_id}"
    echo "Task: ${task}"
    echo "Worker: ${worker_model} (${worker_provider}) via ${worker_agent}"
    echo "Reviewer: ${reviewer_model} (${reviewer_provider}) via ${reviewer_agent}"
    if [[ "${max_iterations}" -eq -1 ]]; then
        echo "Max Iterations: unlimited"
    else
        echo "Max Iterations: ${max_iterations}"
    fi
    echo ""
    
    # Initialize session
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "true" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}"
    
    local feedback=""
    local iteration=1
    
    # Handle infinite iterations
    local max_iter
    if [[ "${max_iterations}" -eq -1 ]]; then
        max_iter=999999
    else
        max_iter="${max_iterations}"
    fi
    
    for ((i=1; i<=max_iter; i++)); do
        iteration=$i
        echo "â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
        echo "  Iteration ${iteration} / ${max_iterations}"
        echo "â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
        
        # WORK PHASE
        echo "â–¶ WORK PHASE"
        echo "Worker: ${worker_model} (${worker_provider}) via ${worker_agent}"
        
        local worker_output
        worker_output=$(call_llm_worker "${task}" "${feedback}" "${iteration}" "${session_id}" "${worker_model}" "${worker_provider}" "${worker_agent}" "${work_guidelines}")
        
        if [[ -z "${worker_output}" ]]; then
            echo "âœ— WORK PHASE FAILED - No output from worker" >&2
            exit 1
        fi
        
        local parsed work summary
        parsed=$(parse_worker_output "${worker_output}")
        work=$(echo "${parsed}" | cut -d'|' -f1)
        summary=$(echo "${parsed}" | cut -d'|' -f2)
        
        if [[ -z "${work}" || -z "${summary}" ]]; then
            echo "âœ— WORK PHASE FAILED - Could not parse output" >&2
            exit 1
        fi
        
        set_work "${session_id}" "${work}" "${summary}" "${iteration}"
        echo "Work submitted. Summary: ${summary}"
        echo ""
        
        # REVIEW PHASE
        echo "â–¶ REVIEW PHASE"
        echo "Reviewer: ${reviewer_model} (${reviewer_provider}) via ${reviewer_agent}"
        
        local reviewer_output
        reviewer_output=$(call_llm_reviewer "${task}" "${work}" "${summary}" "${iteration}" "${session_id}" "${reviewer_model}" "${reviewer_provider}" "${reviewer_agent}" "${review_guidelines}")
        
        if [[ -z "${reviewer_output}" ]]; then
            echo "âœ— REVIEW PHASE FAILED - No output from reviewer" >&2
            exit 1
        fi
        
        parsed=$(parse_reviewer_output "${reviewer_output}")
        local decision=$(echo "${parsed}" | cut -d'|' -f1)
        feedback=$(echo "${parsed}" | cut -d'|' -f2)
        
        if [[ "${decision}" != "SHIP" && "${decision}" != "REVISE" ]]; then
            echo "âœ— REVIEW PHASE FAILED - Invalid decision: ${decision}" >&2
            exit 1
        fi
        
        set_review "${session_id}" "${decision}" "${feedback}" "${iteration}"
        
        if [[ "${decision}" == "SHIP" ]]; then
            echo ""
            echo "â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
            echo "  âœ“ SHIPPED after ${iteration} iteration(s)"
            echo "â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
            echo "Session: ${session_id}"
            echo "Complete: $(date)"
            exit 0
        else
            echo ""
            echo "â†» REVISE - Feedback for next iteration:"
            echo "${feedback}"
            echo ""
        fi
    done
    
    echo "âœ— Max iterations (${max_iterations}) reached" >&2
    exit 1
}

# =============================================================================
# MCP SERVER FUNCTIONS
# =============================================================================

handle_initialize() {
    local id="${1}"
    local params="${2}"
    local session_id task max_iterations worker_model worker_provider worker_agent reviewer_model reviewer_provider reviewer_agent cross_model_enforced work_guidelines review_guidelines
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    task=$(echo "${params}" | jq -r '.task // empty')
    max_iterations=$(echo "${params}" | jq -r '.maxIterations // 10')
    worker_model=$(echo "${params}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${params}" | jq -r '.workerProvider // empty')
    worker_agent=$(echo "${params}" | jq -r '.workerAgent // "goose"')
    reviewer_model=$(echo "${params}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${params}" | jq -r '.reviewerProvider // empty')
    reviewer_agent=$(echo "${params}" | jq -r '.reviewerAgent // "goose"')
    cross_model_enforced=$(echo "${params}" | jq -r '.crossModelReviewEnforced // true')
    work_guidelines=$(echo "${params}" | jq -r '.workGuidelines // empty')
    review_guidelines=$(echo "${params}" | jq -r '.reviewGuidelines // empty')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}"
    
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
        '{success: true, config: {workerModel: $config.workerModel, workerProvider: $config.workerProvider, workerAgent: $config.workerAgent, reviewerModel: $config.reviewerModel, reviewerProvider: $config.reviewerProvider, reviewerAgent: $config.reviewerAgent, maxIterations: $config.maxIterations, crossModelReviewEnforced: $config.crossModelReviewEnforced, workGuidelines: $config.workGuidelines, reviewGuidelines: $config.reviewGuidelines, configuredAt: $config.configuredAt}, crossModelReview: {enforced: $config.crossModelReviewEnforced, valid: $validation.valid, warning: $validation.warning}}')
    
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

handle_run() {
    local id="${1}"
    local params="${2}"
    local session_id task max_iterations worker_model worker_provider worker_agent reviewer_model reviewer_provider reviewer_agent cross_model_enforced work_guidelines review_guidelines
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    task=$(echo "${params}" | jq -r '.task // empty')
    max_iterations=$(echo "${params}" | jq -r '.maxIterations // 10')
    worker_model=$(echo "${params}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${params}" | jq -r '.workerProvider // empty')
    worker_agent=$(echo "${params}" | jq -r '.workerAgent // "goose"')
    reviewer_model=$(echo "${params}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${params}" | jq -r '.reviewerProvider // empty')
    reviewer_agent=$(echo "${params}" | jq -r '.reviewerAgent // "goose"')
    cross_model_enforced=$(echo "${params}" | jq -r '.crossModelReviewEnforced // true')
    work_guidelines=$(echo "${params}" | jq -r '.workGuidelines // empty')
    review_guidelines=$(echo "${params}" | jq -r '.reviewGuidelines // empty')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    if [[ -z "${worker_model}" || -z "${worker_provider}" || -z "${reviewer_model}" || -z "${reviewer_provider}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"workerModel, workerProvider, reviewerModel, and reviewerProvider are required"}')
        return
    fi
    
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}"
    
    local feedback=""
    local result
    
    for ((i=1; i<=max_iterations; i++)); do
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
            copilot)
                # GitHub Copilot CLI
                worker_output=$(echo "${worker_prompt}" | copilot -p --allow-all-tools --model "${worker_model}" 2>/dev/null)
                ;;
            goose)
                if [[ -n "${work_guidelines}" && -f "${work_guidelines}" ]]; then
                    GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
                    worker_output=$(goose run --recipe "${work_guidelines}" --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null)
                else
                    GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" \
                    worker_output=$(goose run --session "${session_id}" --task "${task}" --feedback "${feedback}" 2>/dev/null)
                fi
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
        
        local work summary
        work=$(echo "${worker_output}" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
        summary=$(echo "${worker_output}" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
        
        if [[ -z "${work}" || -z "${summary}" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"WORK PHASE FAILED - Could not parse output"}')
            return
        fi
        
        set_work "${session_id}" "${work}" "${summary}" "${i}"
        
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
            copilot)
                # GitHub Copilot CLI
                reviewer_output=$(echo "${reviewer_prompt}" | copilot -p --allow-all-tools --model "${reviewer_model}" 2>/dev/null)
                ;;
            goose)
                if [[ -n "${review_guidelines}" && -f "${review_guidelines}" ]]; then
                    GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
                    reviewer_output=$(goose run --recipe "${review_guidelines}" --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null)
                else
                    GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" \
                    reviewer_output=$(goose run --session "${session_id}" --work "${work}" --summary "${summary}" 2>/dev/null)
                fi
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
        
        local decision
        decision=$(echo "${reviewer_output}" | grep -i "^DECISION:" | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        decision=$(echo "${decision}" | tr '[:lower:]' '[:upper:]')
        feedback=$(echo "${reviewer_output}" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
        
        if [[ "${decision}" != "SHIP" && "${decision}" != "REVISE" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"REVIEW PHASE FAILED - Invalid decision: '"${decision}"'"}')
            return
        fi
        
        set_review "${session_id}" "${decision}" "${feedback}" "${i}"
        
        if [[ "${decision}" == "SHIP" ]]; then
            local status
            status=$(get_status "${session_id}" "${max_iterations}")
            result=$(jq -n --arg msg "SHIPPED after ${i} iteration(s)" --argjson status "${status}" '{success: true, message: $msg, status: $status, shipped: true, iterations: $i}')
            echo $(json_response "${id}" "${result}")
            return
        fi
    done
    
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
# MAIN ENTRY POINT
# =============================================================================

if [[ $# -gt 0 ]]; then
    # CLI MODE: Run orchestration with task argument
    run_cli "$@"
else
    # MCP SERVER MODE: Handle JSON-RPC requests
    echo '{"jsonrpc":"2.0","id":null,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ralph-loop-runner","version":"1.0.0"}}}'
    
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        
        if ! echo "${line}" | jq empty >/dev/null 2>&1; then
            echo $(json_response "null" "" '{"code":-32700,"message":"Parse error"}')
            continue
        fi
        
        method=$(echo "${line}" | jq -r '.method // empty')
        id=$(echo "${line}" | jq -r '.id // null')
        params=$(echo "${line}" | jq -c '.params // {}')
        
        case "${method}" in
            "initialize")
                echo '{"jsonrpc":"2.0","id":'$id',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ralph-loop-runner","version":"1.0.0"}}}'
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
fi