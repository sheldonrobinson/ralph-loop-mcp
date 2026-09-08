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

# Rate limit & retry configuration
RALPH_MAX_RETRIES="${RALPH_MAX_RETRIES:-3}"
RALPH_INITIAL_BACKOFF="${RALPH_INITIAL_BACKOFF:-5}"
RALPH_THROTTLE_DELAY="${RALPH_THROTTLE_DELAY:-0}"

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
MONITOR_MODEL="${RALPH_MONITOR_MODEL:-}"
MONITOR_PROVIDER="${RALPH_MONITOR_PROVIDER:-}"
MONITOR_AGENT="${RALPH_MONITOR_AGENT:-goose}"

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

# Check if output contains rate limit / quota / resource errors
is_rate_limit_error() {
    local output="$1"
    if echo "${output}" | grep -iqE "(rate_limit|rate limit|429|quota_exceeded|quota exceeded|resource_exhausted|resource exhausted|too many requests|overloaded|throttled)"; then
        return 0
    else
        return 1
    fi
}

# Rate throttling helper
apply_rate_throttling() {
    if [[ "${RALPH_THROTTLE_DELAY}" -gt 0 ]]; then
        sleep "${RALPH_THROTTLE_DELAY}"
    fi
}

# Retry helper with exponential backoff and rate throttling for LLM execution
execute_llm_with_retry() {
    apply_rate_throttling
    local role_name="$1"
    shift
    local cmd=("$@")
    local attempt=1
    local backoff="${RALPH_INITIAL_BACKOFF}"
    local max_attempts=$((RALPH_MAX_RETRIES + 1))
    local output=""
    local exit_code=0

    while [[ ${attempt} -le ${max_attempts} ]]; do
        set +e
        output=$("${cmd[@]}" 2>&1)
        exit_code=$?
        set -e

        # Success case (exit code 0 and non-empty output that is not a rate limit error string)
        if [[ ${exit_code} -eq 0 && -n "${output}" ]] && ! is_rate_limit_error "${output}"; then
            echo "${output}"
            return 0
        fi

        # Check for rate limit or transient error
        if is_rate_limit_error "${output}" || [[ ${exit_code} -ne 0 ]]; then
            if [[ ${attempt} -lt ${max_attempts} ]]; then
                echo "⚠️  [${role_name}] Rate limit / resource constraint detected on attempt ${attempt}/${RALPH_MAX_RETRIES}. Retrying in ${backoff}s..." >&2
                sleep "${backoff}"
                backoff=$((backoff * 2))
                attempt=$((attempt + 1))
                continue
            else
                echo "✗ [${role_name}] Rate limit / quota error persisted after ${RALPH_MAX_RETRIES} retries." >&2
                if is_rate_limit_error "${output}"; then
                    echo "RATE_LIMIT_EXCEEDED: ${output}"
                fi
                return 1
            fi
        fi

        echo "${output}"
        return 0
    done

    return 1
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
    local work_guidelines="${10:-}"
    local review_guidelines="${11:-}"
    local monitor_model="${12:-}"
    local monitor_provider="${13:-}"
    local monitor_agent="${14:-goose}"
    
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
  "monitorModel": $(json_escape "${monitor_model}"),
  "monitorProvider": $(json_escape "${monitor_provider}"),
  "monitorAgent": $(json_escape "${monitor_agent}"),
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
# WORK MANAGEMENT & ITERATION HISTORY
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

    # Persist iteration history
    local hist_dir="$(get_state_dir "${session_id}")/history/iteration_${iteration}"
    mkdir -p "${hist_dir}"
    cp "${work_file}" "${hist_dir}/work.json"
    local work_out="$(get_state_file "${session_id}" "work.out")"
    if [[ -f "${work_out}" ]]; then
        cp "${work_out}" "${hist_dir}/work.out"
    fi
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
# REVIEW MANAGEMENT & ITERATION HISTORY
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
    
    # Persist iteration history
    local hist_dir="$(get_state_dir "${session_id}")/history/iteration_${iteration}"
    mkdir -p "${hist_dir}"
    cp "${review_file}" "${hist_dir}/review.json"
    local review_out="$(get_state_file "${session_id}" "review.out")"
    if [[ -f "${review_out}" ]]; then
        cp "${review_out}" "${hist_dir}/review.out"
    fi

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
    local monitor_model="" monitor_provider="" monitor_agent=""
    local cross_model_enforced="" cross_model_valid="" cross_model_warning="" work_guidelines="" review_guidelines=""
    if [[ -n "${config}" ]]; then
        worker_model=$(echo "${config}" | jq -r '.workerModel // empty')
        worker_provider=$(echo "${config}" | jq -r '.workerProvider // empty')
        worker_agent=$(echo "${config}" | jq -r '.workerAgent // empty')
        reviewer_model=$(echo "${config}" | jq -r '.reviewerModel // empty')
        reviewer_provider=$(echo "${config}" | jq -r '.reviewerProvider // empty')
        reviewer_agent=$(echo "${config}" | jq -r '.reviewerAgent // empty')
        monitor_model=$(echo "${config}" | jq -r '.monitorModel // empty')
        monitor_provider=$(echo "${config}" | jq -r '.monitorProvider // empty')
        monitor_agent=$(echo "${config}" | jq -r '.monitorAgent // empty')
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
        --arg monitorModel "${monitor_model}" \
        --arg monitorProvider "${monitor_provider}" \
        --arg monitorAgent "${monitor_agent}" \
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
            monitorModel: (if $monitorModel == "" then null else $monitorModel end),
            monitorProvider: (if $monitorProvider == "" then null else $monitorProvider end),
            monitorAgent: (if $monitorAgent == "" then null else $monitorAgent end),
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
    rm -f "$(get_state_file "${session_id}" "work.out")"
    rm -f "$(get_state_file "${session_id}" "review.out")"
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
# ORCHESTRATION FUNCTIONS (CLI mode & Monitoring Agent)
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
    local is_existing="${9:-false}"
    
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
    
    case "${worker_agent}" in
        anthropic)
            execute_llm_with_retry "WORKER" bash -c "echo $(json_escape "${prompt}") | claude --model ${worker_model} --print"
            ;;
        openai)
            execute_llm_with_retry "WORKER" bash -c "echo $(json_escape "${prompt}") | openai chat --model ${worker_model} --no-stream"
            ;;
        google)
            execute_llm_with_retry "WORKER" bash -c "echo $(json_escape "${prompt}") | gemini --model ${worker_model} --format=text"
            ;;
        copilot)
            execute_llm_with_retry "WORKER" copilot -p --allow-all-tools "${prompt}"
            ;;
        goose)
            local goose_args=("run")
            if [[ -n "${work_guidelines}" && -f "${work_guidelines}" ]]; then
                goose_args+=("--recipe" "${work_guidelines}")
            fi
            local params_str="task=${task}"
            if [[ -n "${feedback}" ]]; then
                params_str+=" feedback=${feedback}"
            fi
            goose_args+=("--params" "${params_str}")
            if [[ -n "${session_id}" ]]; then
                if [[ "${is_existing}" == "true" ]]; then
                    goose_args+=("--resume")
                fi
                goose_args+=("--name" "${session_id}")
            else
                goose_args+=("--no-session")
            fi
            goose_args+=("--text" "${prompt}")
            
            execute_llm_with_retry "WORKER" env GOOSE_MODEL="${worker_model}" GOOSE_PROVIDER="${worker_provider}" goose "${goose_args[@]}"
            ;;
        *)
            echo "Error: Unknown agent ${worker_agent}" >&2
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
    local is_existing="${10:-false}"
    
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
    
    case "${reviewer_agent}" in
        anthropic)
            execute_llm_with_retry "REVIEWER" bash -c "echo $(json_escape "${prompt}") | claude --model ${reviewer_model} --print"
            ;;
        openai)
            execute_llm_with_retry "REVIEWER" bash -c "echo $(json_escape "${prompt}") | openai chat --model ${reviewer_model} --no-stream"
            ;;
        google)
            execute_llm_with_retry "REVIEWER" bash -c "echo $(json_escape "${prompt}") | gemini --model ${reviewer_model} --format=text"
            ;;
        copilot)
            execute_llm_with_retry "REVIEWER" copilot -p --allow-all-tools "${prompt}"
            ;;
        goose)
            local goose_args=("run")
            if [[ -n "${review_guidelines}" && -f "${review_guidelines}" ]]; then
                goose_args+=("--recipe" "${review_guidelines}")
            fi
            goose_args+=("--params" "task=${task} work=${work} summary=${summary}")
            if [[ -n "${session_id}" ]]; then
                if [[ "${is_existing}" == "true" ]]; then
                    goose_args+=("--resume")
                fi
                goose_args+=("--name" "${session_id}")
            else
                goose_args+=("--no-session")
            fi
            goose_args+=("--text" "${prompt}")
            
            execute_llm_with_retry "REVIEWER" env GOOSE_MODEL="${reviewer_model}" GOOSE_PROVIDER="${reviewer_provider}" goose "${goose_args[@]}"
            ;;
        *)
            echo "Error: Unknown agent ${reviewer_agent}" >&2
            return 1
            ;;
    esac
}

call_llm_monitor() {
    local prompt="$1"
    local monitor_model="${2:-${MONITOR_MODEL}}"
    local monitor_provider="${3:-${MONITOR_PROVIDER}}"
    local monitor_agent="${4:-${MONITOR_AGENT}}"
    
    # Fall back to worker settings if monitor not configured
    if [[ -z "${monitor_model}" ]]; then monitor_model="${WORKER_MODEL}"; fi
    if [[ -z "${monitor_provider}" ]]; then monitor_provider="${WORKER_PROVIDER}"; fi
    if [[ -z "${monitor_agent}" ]]; then monitor_agent="${WORKER_AGENT}"; fi
    
    case "${monitor_agent}" in
        anthropic)
            execute_llm_with_retry "MONITOR" bash -c "echo $(json_escape "${prompt}") | claude --model ${monitor_model} --print"
            ;;
        openai)
            execute_llm_with_retry "MONITOR" bash -c "echo $(json_escape "${prompt}") | openai chat --model ${monitor_model} --no-stream"
            ;;
        google)
            execute_llm_with_retry "MONITOR" bash -c "echo $(json_escape "${prompt}") | gemini --model ${monitor_model} --format=text"
            ;;
        goose)
            execute_llm_with_retry "MONITOR" env GOOSE_MODEL="${monitor_model}" GOOSE_PROVIDER="${monitor_provider}" goose run --no-session --text "${prompt}"
            ;;
        *)
            execute_llm_with_retry "MONITOR" bash -c "echo $(json_escape "${prompt}") | openai chat --model ${monitor_model} --no-stream"
            ;;
    esac
}

parse_worker_output() {
    local output="$1"
    local monitor_model="${2:-}"
    local monitor_provider="${3:-}"
    local monitor_agent="${4:-}"
    local output_file="${5:-}"
    
    local work=""
    local summary=""
    
    if [[ "${output}" == *"WORK:"* ]]; then
        work=$(echo "${output}" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
    fi
    if [[ "${output}" == *"SUMMARY:"* ]]; then
        summary=$(echo "${output}" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    # Regex failed -- try Monitor LLM fallback
    if [[ -z "${work}" || -z "${summary}" ]]; then
        echo "  Regex parsing failed for worker output, consulting Monitor LLM..." >&2
        local monitor_prompt
        if [[ "${monitor_agent}" == "goose" && -n "${output_file}" && -f "${output_file}" ]]; then
            monitor_prompt="Read the file at '${output_file}' then extract the WORK and SUMMARY sections from its content.

If the agent created or modified files, include the file paths and key content in WORK.
Summarize what was accomplished in SUMMARY.

Output format:
WORK:
[extracted work content]

SUMMARY:
[one-line summary]"
        else
            monitor_prompt="Extract the WORK and SUMMARY sections from the following raw agent output.

If the agent created or modified files, include the file paths and key content in WORK.
Summarize what was accomplished in SUMMARY.

Output format:
WORK:
[extracted work content]

SUMMARY:
[one-line summary]

---
${output}"
        fi
        
        local monitor_response
        monitor_response=$(call_llm_monitor "${monitor_prompt}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}")
        if [[ -n "${monitor_response}" ]]; then
            if [[ "${monitor_response}" == *"WORK:"* ]]; then
                work=$(echo "${monitor_response}" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
            fi
            if [[ "${monitor_response}" == *"SUMMARY:"* ]]; then
                summary=$(echo "${monitor_response}" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
            fi
        fi
        
        if [[ -n "${work}" || -n "${summary}" ]]; then
            echo "  Monitor LLM parsed successfully." >&2
        else
            echo "  Monitor LLM also could not parse the output." >&2
        fi
    fi
    
    echo "${work}|${summary}"
}

parse_reviewer_output() {
    local output="$1"
    local monitor_model="${2:-}"
    local monitor_provider="${3:-}"
    local monitor_agent="${4:-}"
    local output_file="${5:-}"
    
    local decision=""
    local feedback=""
    
    if [[ "${output}" == *"DECISION:"* ]]; then
        decision=$(echo "${output}" | grep -i "^DECISION:" | head -n 1 | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        decision=$(echo "${decision}" | tr '[:lower:]' '[:upper:]')
    fi
    if [[ "${output}" == *"FEEDBACK:"* ]]; then
        feedback=$(echo "${output}" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    # Regex failed -- try Monitor LLM fallback
    if [[ "${decision}" != "SHIP" && "${decision}" != "REVISE" ]]; then
        echo "  Regex parsing failed for reviewer output, consulting Monitor LLM..." >&2
        local monitor_prompt
        if [[ "${monitor_agent}" == "goose" && -n "${output_file}" && -f "${output_file}" ]]; then
            monitor_prompt="Read the file at '${output_file}' then extract the DECISION (SHIP or REVISE) and FEEDBACK from its content.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [the review feedback]"
        else
            monitor_prompt="Extract the DECISION (SHIP or REVISE) and FEEDBACK from the following raw agent output.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [the review feedback]

---
${output}"
        fi
        
        local monitor_response
        monitor_response=$(call_llm_monitor "${monitor_prompt}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}")
        if [[ -n "${monitor_response}" ]]; then
            if [[ "${monitor_response}" == *"DECISION:"* ]]; then
                decision=$(echo "${monitor_response}" | grep -i "^DECISION:" | head -n 1 | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                decision=$(echo "${decision}" | tr '[:lower:]' '[:upper:]')
            fi
            if [[ "${monitor_response}" == *"FEEDBACK:"* ]]; then
                feedback=$(echo "${monitor_response}" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
            fi
        fi
        
        if [[ "${decision}" == "SHIP" || "${decision}" == "REVISE" ]]; then
            echo "  Monitor LLM parsed successfully." >&2
        else
            echo "  Monitor LLM also could not parse the output." >&2
        fi
    fi
    
    echo "${decision}|${feedback}"
}

# CLI orchestration main function
run_cli() {
    local task_input="${1:-}"
    
    # Help message check
    if [[ "${task_input}" == "-h" || "${task_input}" == "--help" ]]; then
        task_input=""
    fi
    
    local worker_model="${WORKER_MODEL}"
    local worker_provider="${WORKER_PROVIDER}"
    local worker_agent="${WORKER_AGENT}"
    local reviewer_model="${REVIEWER_MODEL}"
    local reviewer_provider="${REVIEWER_PROVIDER}"
    local reviewer_agent="${REVIEWER_AGENT}"
    local max_iterations="${MAX_ITERATIONS}"
    local work_guidelines="${WORK_GUIDELINES}"
    local review_guidelines="${REVIEW_GUIDELINES}"
    local monitor_model="${MONITOR_MODEL}"
    local monitor_provider="${MONITOR_PROVIDER}"
    local monitor_agent="${MONITOR_AGENT}"
    
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
        echo "  --monitor-model MODEL        Monitor model (default: \$RALPH_MONITOR_MODEL)"
        echo "  --monitor-provider PROVIDER  Monitor provider (default: \$RALPH_MONITOR_PROVIDER)"
        echo "  --monitor-agent AGENT        Monitor agent (default: \$RALPH_MONITOR_AGENT)"
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
            --monitor-model)
                monitor_model="${3}"
                shift 2
                ;;
            --monitor-provider)
                monitor_provider="${3}"
                shift 2
                ;;
            --monitor-agent)
                monitor_agent="${3}"
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
    if [[ -n "${monitor_model}" ]]; then
        echo "Monitor: ${monitor_model} (${monitor_provider}) via ${monitor_agent}"
    fi
    if [[ "${max_iterations}" -eq -1 ]]; then
        echo "Max Iterations: unlimited"
    else
        echo "Max Iterations: ${max_iterations}"
    fi
    echo ""
    
    # Initialize session
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "true" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}"
    
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
        echo "======================================================================"
        echo "  Iteration ${iteration} / ${max_iterations}"
        echo "======================================================================"
        
        # WORK PHASE
        echo "▶ WORK PHASE"
        echo "Worker: ${worker_model} (${worker_provider}) via ${worker_agent}"
        
        local is_existing="false"
        if [[ -n "${CLI_SESSION_ID}" || ${iteration} -gt 1 ]]; then
            is_existing="true"
        fi

        local worker_output
        worker_output=$(call_llm_worker "${task}" "${feedback}" "${iteration}" "${session_id}" "${worker_model}" "${worker_provider}" "${worker_agent}" "${work_guidelines}" "${is_existing}")
        
        if [[ "${worker_output}" == RATE_LIMIT_EXCEEDED* ]] || [[ -z "${worker_output}" ]]; then
            echo "✗ WORK PHASE FAILED - Rate limit, quota error, or no output from worker" >&2
            block_iteration "${session_id}" "WORK PHASE FAILED - Rate limit or quota error from worker LLM"
            exit 1
        fi
        
        local work_out_file="$(get_state_file "${session_id}" "work.out")"
        echo "${worker_output}" > "${work_out_file}"

        local parsed work summary
        parsed=$(parse_worker_output "${worker_output}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}" "${work_out_file}")
        work=$(echo "${parsed}" | cut -d'|' -f1)
        summary=$(echo "${parsed}" | cut -d'|' -f2)
        
        if [[ -z "${work}" || -z "${summary}" ]]; then
            echo "✗ WORK PHASE FAILED - Could not parse output" >&2
            exit 1
        fi
        
        set_work "${session_id}" "${work}" "${summary}" "${iteration}"
        echo "Work submitted. Summary: ${summary}"
        echo ""
        
        # REVIEW PHASE
        echo "▶ REVIEW PHASE"
        echo "Reviewer: ${reviewer_model} (${reviewer_provider}) via ${reviewer_agent}"
        
        local reviewer_output
        reviewer_output=$(call_llm_reviewer "${task}" "${work}" "${summary}" "${iteration}" "${session_id}" "${reviewer_model}" "${reviewer_provider}" "${reviewer_agent}" "${review_guidelines}" "${is_existing}")
        
        if [[ "${reviewer_output}" == RATE_LIMIT_EXCEEDED* ]] || [[ -z "${reviewer_output}" ]]; then
            echo "✗ REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer" >&2
            block_iteration "${session_id}" "REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM"
            exit 1
        fi
        
        local review_out_file="$(get_state_file "${session_id}" "review.out")"
        echo "${reviewer_output}" > "${review_out_file}"

        parsed=$(parse_reviewer_output "${reviewer_output}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}" "${review_out_file}")
        local decision=$(echo "${parsed}" | cut -d'|' -f1)
        feedback=$(echo "${parsed}" | cut -d'|' -f2)
        
        if [[ "${decision}" != "SHIP" && "${decision}" != "REVISE" ]]; then
            echo "✗ REVIEW PHASE FAILED - Invalid decision: ${decision}" >&2
            exit 1
        fi
        
        set_review "${session_id}" "${decision}" "${feedback}" "${iteration}"
        
        if [[ "${decision}" == "SHIP" ]]; then
            echo ""
            echo "======================================================================"
            echo "  ✓ SHIPPED after ${iteration} iteration(s)"
            echo "======================================================================"
            echo "Session: ${session_id}"
            echo "Complete: $(date)"
            exit 0
        else
            echo ""
            echo "↪ REVISE - Feedback for next iteration:"
            echo "${feedback}"
            echo ""
        fi
    done
    
    echo "✗ Max iterations (${max_iterations}) reached" >&2
    exit 1
}

# =============================================================================
# MCP SERVER FUNCTIONS
# =============================================================================

handle_initialize() {
    local id="${1}"
    local params="${2}"
    local session_id task max_iterations worker_model worker_provider worker_agent
    local reviewer_model reviewer_provider reviewer_agent monitor_model monitor_provider monitor_agent
    local cross_model_enforced work_guidelines review_guidelines
    
    session_id=$(echo "${params}" | jq -r '.sessionId // "default"')
    task=$(echo "${params}" | jq -r '.task // empty')
    max_iterations=$(echo "${params}" | jq -r '.maxIterations // 10')
    worker_model=$(echo "${params}" | jq -r '.workerModel // empty')
    worker_provider=$(echo "${params}" | jq -r '.workerProvider // empty')
    worker_agent=$(echo "${params}" | jq -r '.workerAgent // "goose"')
    reviewer_model=$(echo "${params}" | jq -r '.reviewerModel // empty')
    reviewer_provider=$(echo "${params}" | jq -r '.reviewerProvider // empty')
    reviewer_agent=$(echo "${params}" | jq -r '.reviewerAgent // "goose"')
    monitor_model=$(echo "${params}" | jq -r '.monitorModel // env.RALPH_MONITOR_MODEL // empty')
    monitor_provider=$(echo "${params}" | jq -r '.monitorProvider // env.RALPH_MONITOR_PROVIDER // empty')
    monitor_agent=$(echo "${params}" | jq -r '.monitorAgent // env.RALPH_MONITOR_AGENT // "goose"')
    cross_model_enforced=$(echo "${params}" | jq -r '.crossModelReviewEnforced // true')
    work_guidelines=$(echo "${params}" | jq -r '.workGuidelines // empty')
    review_guidelines=$(echo "${params}" | jq -r '.reviewGuidelines // empty')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}"
    
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
        '{success: true, config: {workerModel: $config.workerModel, workerProvider: $config.workerProvider, workerAgent: $config.workerAgent, reviewerModel: $config.reviewerModel, reviewerProvider: $config.reviewerProvider, reviewerAgent: $config.reviewerAgent, monitorModel: $config.monitorModel, monitorProvider: $config.monitorProvider, monitorAgent: $config.monitorAgent, maxIterations: $config.maxIterations, crossModelReviewEnforced: $config.crossModelReviewEnforced, workGuidelines: $config.workGuidelines, reviewGuidelines: $config.reviewGuidelines, configuredAt: $config.configuredAt}, crossModelReview: {enforced: $config.crossModelReviewEnforced, valid: $validation.valid, warning: $validation.warning}}')
    
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
    local session_id task max_iterations worker_model worker_provider worker_agent reviewer_model reviewer_provider reviewer_agent cross_model_enforced work_guidelines review_guidelines monitor_model monitor_provider monitor_agent
    
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
    monitor_model=$(echo "${params}" | jq -r '.monitorModel // env.RALPH_MONITOR_MODEL // empty')
    monitor_provider=$(echo "${params}" | jq -r '.monitorProvider // env.RALPH_MONITOR_PROVIDER // empty')
    monitor_agent=$(echo "${params}" | jq -r '.monitorAgent // env.RALPH_MONITOR_AGENT // "goose"')
    
    if [[ -z "${task}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"Task is required"}')
        return
    fi
    
    if [[ -z "${worker_model}" || -z "${worker_provider}" || -z "${reviewer_model}" || -z "${reviewer_provider}" ]]; then
        echo $(json_response "${id}" "" '{"code":-32602,"message":"workerModel, workerProvider, reviewerModel, and reviewerProvider are required"}')
        return
    fi
    
    set_task "${session_id}" "${task}"
    set_config "${session_id}" "${worker_model}" "${worker_provider}" "${reviewer_model}" "${reviewer_provider}" "${max_iterations}" "${cross_model_enforced}" "${worker_agent}" "${reviewer_agent}" "${work_guidelines}" "${review_guidelines}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}"
    
    local feedback=""
    local result
    
    for ((i=1; i<=max_iterations; i++)); do
        local is_existing="false"
        if [[ ${i} -gt 1 ]]; then
            is_existing="true"
        fi

        local worker_output
        worker_output=$(call_llm_worker "${task}" "${feedback}" "${i}" "${session_id}" "${worker_model}" "${worker_provider}" "${worker_agent}" "${work_guidelines}" "${is_existing}")
        
        if [[ "${worker_output}" == RATE_LIMIT_EXCEEDED* ]] || [[ -z "${worker_output}" ]]; then
            block_iteration "${session_id}" "WORK PHASE FAILED - Rate limit or quota error from worker LLM"
            echo $(json_response "${id}" "" '{"code":-32603,"message":"WORK PHASE FAILED - Rate limit, quota error, or no output from worker"}')
            return
        fi
        
        local work_out_file="$(get_state_file "${session_id}" "work.out")"
        echo "${worker_output}" > "${work_out_file}"

        local parsed work summary
        parsed=$(parse_worker_output "${worker_output}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}" "${work_out_file}")
        work=$(echo "${parsed}" | cut -d'|' -f1)
        summary=$(echo "${parsed}" | cut -d'|' -f2)
        
        if [[ -z "${work}" || -z "${summary}" ]]; then
            echo $(json_response "${id}" "" '{"code":-32603,"message":"WORK PHASE FAILED - Could not parse output"}')
            return
        fi
        
        set_work "${session_id}" "${work}" "${summary}" "${i}"
        
        local reviewer_output
        reviewer_output=$(call_llm_reviewer "${task}" "${work}" "${summary}" "${i}" "${session_id}" "${reviewer_model}" "${reviewer_provider}" "${reviewer_agent}" "${review_guidelines}" "${is_existing}")
        
        if [[ "${reviewer_output}" == RATE_LIMIT_EXCEEDED* ]] || [[ -z "${reviewer_output}" ]]; then
            block_iteration "${session_id}" "REVIEW PHASE FAILED - Rate limit or quota error from reviewer LLM"
            echo $(json_response "${id}" "" '{"code":-32603,"message":"REVIEW PHASE FAILED - Rate limit, quota error, or no output from reviewer"}')
            return
        fi
        
        local review_out_file="$(get_state_file "${session_id}" "review.out")"
        echo "${reviewer_output}" > "${review_out_file}"

        parsed=$(parse_reviewer_output "${reviewer_output}" "${monitor_model}" "${monitor_provider}" "${monitor_agent}" "${review_out_file}")
        local decision=$(echo "${parsed}" | cut -d'|' -f1)
        feedback=$(echo "${parsed}" | cut -d'|' -f2)
        
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

handle_list_tools() {
    local id="${1}"
    local tools='[
  {
    "name": "ralph_loop_initialize",
    "description": "Initialize a new Ralph Loop session with a task, model configuration, and guidelines",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Unique session identifier (default: '\''default'\'')" },
        "task": { "type": "string", "description": "The task or feature description for the worker to implement" },
        "maxIterations": { "type": "integer", "description": "Maximum number of iterations (-1 for unlimited, default: 10)" },
        "workerModel": { "type": "string", "description": "Worker LLM model name (e.g., '\''claude-3-5-sonnet'\'')" },
        "workerProvider": { "type": "string", "description": "Worker provider (anthropic, openai, google, copilot, goose)" },
        "workerAgent": { "type": "string", "description": "Worker agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "reviewerModel": { "type": "string", "description": "Reviewer LLM model name (e.g., '\''gpt-4o'\'')" },
        "reviewerProvider": { "type": "string", "description": "Reviewer provider (anthropic, openai, google, copilot, goose)" },
        "reviewerAgent": { "type": "string", "description": "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "monitorModel": { "type": "string", "description": "Monitoring agent model name (fallback supervisor)" },
        "monitorProvider": { "type": "string", "description": "Monitoring agent provider (anthropic, openai, google, copilot, goose)" },
        "monitorAgent": { "type": "string", "description": "Monitoring agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "crossModelReviewEnforced": { "type": "boolean", "description": "Enforce cross-model review validation between worker and reviewer (default: true)" },
        "workGuidelines": { "type": "string", "description": "Path to work recipe or guidelines file" },
        "reviewGuidelines": { "type": "string", "description": "Path to review recipe or guidelines file" }
      },
      "required": ["task"]
    }
  },
  {
    "name": "ralph_loop_get_task",
    "description": "Get the current task for the worker phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_submit_work",
    "description": "Submit work results and summary from worker phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "work": { "type": "string", "description": "Complete work output / implementation" },
        "summary": { "type": "string", "description": "Summary of changes made" },
        "iteration": { "type": "integer", "description": "Current iteration number" }
      },
      "required": ["work", "summary", "iteration"]
    }
  },
  {
    "name": "ralph_loop_get_work",
    "description": "Get worker'\''s submitted work for reviewer phase",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_submit_review",
    "description": "Submit review decision (SHIP or REVISE) with feedback",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "decision": { "type": "string", "enum": ["SHIP", "REVISE"], "description": "Review decision: SHIP to approve, REVISE to request changes" },
        "feedback": { "type": "string", "description": "Actionable feedback for revision (required if decision is REVISE)" },
        "iteration": { "type": "integer", "description": "Current iteration number" }
      },
      "required": ["decision", "iteration"]
    }
  },
  {
    "name": "ralph_loop_get_feedback",
    "description": "Get reviewer feedback for next iteration",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_get_status",
    "description": "Get current session status, phase, iteration, and configuration",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_get_config",
    "description": "Get worker, reviewer, and monitor configuration for a session",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_reset",
    "description": "Reset and clear all state and history for a session",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" }
      }
    }
  },
  {
    "name": "ralph_loop_block",
    "description": "Block the current iteration with a reason",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "reason": { "type": "string", "description": "Reason why the loop cannot proceed" }
      },
      "required": ["reason"]
    }
  },
  {
    "name": "ralph_loop_run",
    "description": "Run complete automated Ralph Loop (initialization -> orchestration -> execution -> state management)",
    "inputSchema": {
      "type": "object",
      "properties": {
        "sessionId": { "type": "string", "description": "Session ID (default: '\''default'\'')" },
        "task": { "type": "string", "description": "Task description to accomplish" },
        "maxIterations": { "type": "integer", "description": "Maximum number of iterations (-1 for unlimited, default: 10)" },
        "workerModel": { "type": "string", "description": "Worker model name" },
        "workerProvider": { "type": "string", "description": "Worker provider (anthropic, openai, google, copilot, goose)" },
        "workerAgent": { "type": "string", "description": "Worker agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "reviewerModel": { "type": "string", "description": "Reviewer model name" },
        "reviewerProvider": { "type": "string", "description": "Reviewer provider (anthropic, openai, google, copilot, goose)" },
        "reviewerAgent": { "type": "string", "description": "Reviewer agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "monitorModel": { "type": "string", "description": "Monitor model name" },
        "monitorProvider": { "type": "string", "description": "Monitor provider" },
        "monitorAgent": { "type": "string", "description": "Monitor agent CLI (goose, claude, openai, gemini, copilot, default: '\''goose'\'')" },
        "crossModelReviewEnforced": { "type": "boolean", "description": "Enforce cross-model review validation (default: true)" },
        "workGuidelines": { "type": "string", "description": "Path to work recipe or guidelines file" },
        "reviewGuidelines": { "type": "string", "description": "Path to review recipe or guidelines file" }
      },
      "required": ["task", "workerModel", "workerProvider", "reviewerModel", "reviewerProvider"]
    }
  }
]'
    local result=$(jq -n --argjson tools "${tools}" '{tools: $tools}')
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
                handle_list_tools "${id}"
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
