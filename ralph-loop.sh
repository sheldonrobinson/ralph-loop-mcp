#!/usr/bin/env bash
# Ralph Loop Orchestration Script - Bash Implementation
# Cross-platform orchestration for the Ralph Loop iterative development technique
# For Linux/macOS

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default configuration
MCP_SERVER_CMD="${RALPH_MCP_SERVER:-./ralph-loop-mcp.sh}"
DEFAULT_MAX_ITERATIONS=10
STATE_DIR_BASE="${HOME}/.goose/ralph"

# Configuration from environment or prompts
WORKER_MODEL="${RALPH_WORKER_MODEL:-}"
WORKER_PROVIDER="${RALPH_WORKER_PROVIDER:-}"
REVIEWER_MODEL="${RALPH_REVIEWER_MODEL:-}"
REVIEWER_PROVIDER="${RALPH_REVIEWER_PROVIDER:-}"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
TASK_INPUT="${1:-}"

# Helper functions
print_header() {
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}  Ralph Loop - Multi-Model Edition${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}---------------------------------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}---------------------------------------------------------------${NC}"
    echo ""
}

call_mcp() {
    local method="$1"
    local params="$2"
    local session_id="$3"
    
    local request="{\"jsonrpc\":\"2.0\",\"id\":$(date +%s%N),\"method\":\"tools/call\",\"params\":{\"name\":\"$method\",\"arguments\":$params}}"
    echo "$request" | $MCP_SERVER_CMD 2>/dev/null | tail -1
}

call_mcp_init() {
    local request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ralph-loop","version":"1.0"}}}'
    echo "$request" | $MCP_SERVER_CMD 2>/dev/null | head -1
}

# Prompt for configuration if not set
prompt_config() {
    if [[ -z "$WORKER_MODEL" ]]; then
        echo -ne "${BLUE}Worker model${NC}: "
        read -r WORKER_MODEL
        if [[ -z "$WORKER_MODEL" ]]; then
            echo -e "${RED}Error: Worker model is required${NC}"
            exit 1
        fi
    fi
    
    if [[ -z "$WORKER_PROVIDER" ]]; then
        echo -ne "${BLUE}Worker provider${NC} (anthropic/openai/google): "
        read -r WORKER_PROVIDER
        if [[ -z "$WORKER_PROVIDER" ]]; then
            echo -e "${RED}Error: Worker provider is required${NC}"
            exit 1
        fi
    fi
    
    if [[ -z "$REVIEWER_MODEL" ]]; then
        echo -ne "${BLUE}Reviewer model${NC} (should be different from worker): "
        read -r REVIEWER_MODEL
        if [[ -z "$REVIEWER_MODEL" ]]; then
            echo -e "${RED}Error: Reviewer model is required${NC}"
            exit 1
        fi
    fi
    
    if [[ -z "$REVIEWER_PROVIDER" ]]; then
        echo -ne "${BLUE}Reviewer provider${NC} (anthropic/openai/google): "
        read -r REVIEWER_PROVIDER
        if [[ -z "$REVIEWER_PROVIDER" ]]; then
            echo -e "${RED}Error: Reviewer provider is required${NC}"
            exit 1
        fi
    fi
    
    # Warn if same model
    if [[ "$WORKER_MODEL" == "$REVIEWER_MODEL" && "$WORKER_PROVIDER" == "$REVIEWER_PROVIDER" ]]; then
        echo -e "${YELLOW}Warning: Worker and reviewer are the same model/provider.${NC}"
        echo "For best results, use different models for cross-model review."
        echo -ne "Continue anyway? [y/N]: "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 1
        fi
    fi
    
    echo -ne "${BLUE}Max iterations${NC} [$DEFAULT_MAX_ITERATIONS]: "
    read -r user_input
    MAX_ITERATIONS="${user_input:-$DEFAULT_MAX_ITERATIONS}"
}

# Get task from file or argument
get_task() {
    if [[ -f "$TASK_INPUT" ]]; then
        cat "$TASK_INPUT"
        return 0
    elif [[ -n "$TASK_INPUT" ]]; then
        echo "$TASK_INPUT"
        return 0
    fi
    return 1
}

# Call LLM for work phase
call_worker_llm() {
    local task="$1"
    local feedback="$2"
    local iteration="$3"
    local session_id="$4"
    
    # Build prompt for worker
    local prompt="You are the WORKER in a Ralph Loop iteration $iteration.
    
Task: $task"
    
    if [[ -n "$feedback" ]]; then
        prompt="$prompt

Previous feedback from reviewer: $feedback

Please revise your work based on this feedback."
    fi
    
    prompt="$prompt

Provide your complete work output and a brief summary.
Output format:
WORK:
[your complete work here]

SUMMARY:
[brief summary of what you did]"
    
    # Call the worker LLM via provider CLI
    case "$WORKER_PROVIDER" in
        anthropic)
            echo "$prompt" | claude --model "$WORKER_MODEL" --print 2>/dev/null
            ;;
        openai)
            echo "$prompt" | openai chat --model "$WORKER_MODEL" 2>/dev/null
            ;;
        google)
            echo "$prompt" | gemini --model "$WORKER_MODEL" 2>/dev/null
            ;;
        goose)
            # Use goose with the ralph-work recipe
            GOOSE_MODEL="$WORKER_MODEL" GOOSE_PROVIDER="$WORKER_PROVIDER" \
            goose run --recipe ralph-work --session "$session_id" --task "$task" --feedback "$feedback" 2>/dev/null
            ;;
        *)
            echo "Error: Unknown provider $WORKER_PROVIDER" >&2
            return 1
            ;;
    esac
}

# Call LLM for review phase
call_reviewer_llm() {
    local task="$1"
    local work="$2"
    local summary="$3"
    local iteration="$4"
    local session_id="$5"
    
    local prompt="You are the REVIEWER in a Ralph Loop iteration $iteration.
    
Original Task: $task

Worker's Work:
$work

Worker's Summary: $summary

Review this work thoroughly. Decide: SHIP (work is complete and correct) or REVISE (needs changes).
If REVISE, provide specific, actionable feedback for the worker.

Output format:
DECISION: SHIP or REVISE
FEEDBACK: [your feedback, or empty if SHIP]"
    
    case "$REVIEWER_PROVIDER" in
        anthropic)
            echo "$prompt" | claude --model "$REVIEWER_MODEL" --print 2>/dev/null
            ;;
        openai)
            echo "$prompt" | openai chat --model "$REVIEWER_MODEL" 2>/dev/null
            ;;
        google)
            echo "$prompt" | gemini --model "$REVIEWER_MODEL" 2>/dev/null
            ;;
        goose)
            GOOSE_MODEL="$REVIEWER_MODEL" GOOSE_PROVIDER="$REVIEWER_PROVIDER" \
            goose run --recipe ralph-review --session "$session_id" --work "$work" --summary "$summary" 2>/dev/null
            ;;
        *)
            echo "Error: Unknown provider $REVIEWER_PROVIDER" >&2
            return 1
            ;;
    esac
}

# Parse worker output
parse_worker_output() {
    local output="$1"
    local work=""
    local summary=""
    
    if [[ "$output" == *"WORK:"* ]]; then
        work=$(echo "$output" | sed -n '/^WORK:/,/^SUMMARY:/p' | sed '1d;$d' | sed '/^$/d')
    fi
    if [[ "$output" == *"SUMMARY:"* ]]; then
        summary=$(echo "$output" | sed -n '/^SUMMARY:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    echo "$work|$summary"
}

# Parse reviewer output
parse_reviewer_output() {
    local output="$1"
    local decision=""
    local feedback=""
    
    if [[ "$output" == *"DECISION:"* ]]; then
        decision=$(echo "$output" | grep -i "^DECISION:" | sed 's/DECISION: *//i' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        decision=$(echo "$decision" | tr '[:lower:]' '[:upper:]')
    fi
    if [[ "$output" == *"FEEDBACK:"* ]]; then
        feedback=$(echo "$output" | sed -n '/^FEEDBACK:/,$p' | sed '1d' | sed '/^$/d')
    fi
    
    echo "$decision|$feedback"
}

# Main orchestration
main() {
    print_header
    
    # Initialize MCP server connection
    call_mcp_init > /dev/null
    
    # Get task
    local task
    task=$(get_task)
    if [[ -z "$task" ]]; then
        echo -e "${RED}Error: No task provided${NC}"
        echo "Usage: $0 \"task description\" or $0 /path/to/task.md"
        exit 1
    fi
    
    # Prompt for config if needed
    if [[ -z "$WORKER_MODEL" || -z "$WORKER_PROVIDER" || -z "$REVIEWER_MODEL" || -z "$REVIEWER_PROVIDER" ]]; then
        prompt_config
    fi
    
    # Cost warning
    echo -e "${YELLOW}Warning: This will run up to ${MAX_ITERATIONS} iterations, each using both models.${NC}"
    echo -ne "Continue? [y/N]: "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        exit 1
    fi
    
    local session_id="ralph-$(date +%s)"
    echo ""
    echo -e "  Task: ${YELLOW}$task${NC}"
    echo -e "  Worker: ${WORKER_MODEL} (${WORKER_PROVIDER})"
    echo -e "  Reviewer: ${REVIEWER_MODEL} (${REVIEWER_PROVIDER})"
    echo -e "  Max Iterations: $MAX_ITERATIONS"
    echo -e "  Session: $session_id"
    echo ""
    
    # Initialize session via MCP
    local init_params="{\"sessionId\":\"$session_id\",\"task\":$(echo "$task" | jq -Rs .),\"maxIterations\":$MAX_ITERATIONS,\"workerModel\":\"$WORKER_MODEL\",\"workerProvider\":\"$WORKER_PROVIDER\",\"reviewerModel\":\"$REVIEWER_MODEL\",\"reviewerProvider\":\"$REVIEWER_PROVIDER\"}"
    call_mcp "ralph_loop_initialize" "$init_params" "$session_id" > /dev/null
    
    local feedback=""
    
    for i in $(seq 1 "$MAX_ITERATIONS"); do
        print_step "Iteration $i / $MAX_ITERATIONS"
        
        # WORK PHASE
        echo -e "${YELLOW}WORK PHASE${NC}"
        echo "Worker: $WORKER_MODEL ($WORKER_PROVIDER)"
        
        local worker_output
        worker_output=$(call_worker_llm "$task" "$feedback" "$i" "$session_id")
        
        if [[ -z "$worker_output" ]]; then
            echo -e "${RED}WORK PHASE FAILED - No output from worker${NC}"
            exit 1
        fi
        
        # Parse worker output
        local parsed
        parsed=$(parse_worker_output "$worker_output")
        local work=$(echo "$parsed" | cut -d'|' -f1)
        local summary=$(echo "$parsed" | cut -d'|' -f2)
        
        if [[ -z "$work" || -z "$summary" ]]; then
            echo -e "${RED}WORK PHASE FAILED - Could not parse output${NC}"
            echo "Raw output: $worker_output"
            exit 1
        fi
        
        # Submit work via MCP
        local work_params="{\"sessionId\":\"$session_id\",\"iteration\":$i,\"work\":$(echo "$work" | jq -Rs .),\"summary\":$(echo "$summary" | jq -Rs .)}"
        call_mcp "ralph_loop_submit_work" "$work_params" "$session_id" > /dev/null
        
        echo "Work submitted. Summary: $summary"
        echo ""
        
        # REVIEW PHASE
        echo -e "${YELLOW}REVIEW PHASE${NC}"
        echo "Reviewer: $REVIEWER_MODEL ($REVIEWER_PROVIDER)"
        
        local reviewer_output
        reviewer_output=$(call_reviewer_llm "$task" "$work" "$summary" "$i" "$session_id")
        
        if [[ -z "$reviewer_output" ]]; then
            echo -e "${RED}REVIEW PHASE FAILED - No output from reviewer${NC}"
            exit 1
        fi
        
        # Parse reviewer output
        parsed=$(parse_reviewer_output "$reviewer_output")
        local decision=$(echo "$parsed" | cut -d'|' -f1)
        feedback=$(echo "$parsed" | cut -d'|' -f2)
        
        if [[ "$decision" != "SHIP" && "$decision" != "REVISE" ]]; then
            echo -e "${RED}REVIEW PHASE FAILED - Invalid decision: $decision${NC}"
            echo "Raw output: $reviewer_output"
            exit 1
        fi
        
        # Submit review via MCP
        local review_params="{\"sessionId\":\"$session_id\",\"iteration\":$i,\"decision\":\"$decision\",\"feedback\":$(echo "$feedback" | jq -Rs .)}"
        call_mcp "ralph_loop_submit_review" "$review_params" "$session_id" > /dev/null
        
        if [[ "$decision" == "SHIP" ]]; then
            echo ""
            echo -e "${GREEN}===============================================================${NC}"
            echo -e "${GREEN}  SHIPPED after $i iteration(s)${NC}"
            echo -e "${GREEN}===============================================================${NC}"
            echo "Session: $session_id"
            echo "Complete: $(date)"
            exit 0
        else
            echo ""
            echo -e "${YELLOW}REVISE - Feedback for next iteration:${NC}"
            echo "$feedback"
            echo ""
        fi
    done
    
    echo -e "${RED}Max iterations ($MAX_ITERATIONS) reached${NC}"
    exit 1
}

# Check dependencies
check_deps() {
    local missing=()
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    case "$WORKER_PROVIDER" in
        anthropic) command -v claude &> /dev/null || missing+=("claude (Anthropic CLI)") ;;
        openai) command -v openai &> /dev/null || missing+=("openai (OpenAI CLI)") ;;
        google) command -v gemini &> /dev/null || missing+=("gemini (Google CLI)") ;;
        goose) command -v goose &> /dev/null || missing+=("goose") ;;
    esac
    
    case "$REVIEWER_PROVIDER" in
        anthropic) command -v claude &> /dev/null || missing+=("claude (Anthropic CLI)") ;;
        openai) command -v openai &> /dev/null || missing+=("openai (OpenAI CLI)") ;;
        google) command -v gemini &> /dev/null || missing+=("gemini (Google CLI)") ;;
        goose) command -v goose &> /dev/null || missing+=("goose") ;;
    esac
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing dependencies:${NC}"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

# Run
check_deps
main "$@"