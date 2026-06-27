# ralph-loop-runner

A cross-platform implementation of the **Ralph Loop** — a multi-model iterative development technique where a "worker" model does the work and a "reviewer" model provides cross-model review, iterating until the reviewer says "SHIP".

Based on:
- [Ralph Wiggum as a "software engineer"](https://ghuntley.com/ralph/) by Geoffrey Huntley
- [Ralph Loop | goose](https://goose-docs.ai/docs/tutorials/ralph-loop/)
- [ralph-wiggum-mcp npm package](https://www.npmjs.com/package/ralph-wiggum-mcp)

## Overview

The Ralph Loop implements a two-phase iterative workflow:

```
┌─────────────────────────────────────────────────────────────┐
│                    RALPH LOOP                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────────┐      WORK PHASE      ┌─────────┐             │
│   │  TASK   │ ──────────────────▶  │ WORKER  │             │
│   │         │   fresh context      │ (Model A)│             │
│   └─────────┘                      └────┬────┘             │
│                                         │                  │
│                                         ▼                  │
│                              ┌─────────────────┐          │
│                              │ Submit Work +   │          │
│                              │ Summary         │          │
│                              └────────┬────────┘          │
│                                       │                   │
│                                       ▼                   │
│   ┌─────────┐      REVIEW PHASE    ┌─────────┐           │
│   │ REVIEWER│ ◀─────────────────── │  WORK   │           │
│   │(Model B)│   cross-model review │ OUTPUT  │           │
│   └────┬────┘                      └─────────┘           │
│        │                                                  │
│        ▼                                                  │
│   ┌─────────┐                                             │
│   │ DECISION│                                             │
│   │ SHIP    │──────▶ COMPLETE ✓                            │
│   │ REVISE  │──────▶ Next Iteration (fresh context)        │
│   └─────────┘                                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **Cross-platform Native**: Single script per platform (Bash for Linux/macOS, PowerShell for Windows) — no Node.js runtime required
- **Dual Mode Operation**: 
  - **MCP Server Mode** — JSON-RPC 2.0 over stdio for integration with AI agents
  - **CLI Mode** — Run the full loop directly from command line
- **Session-based**: Multiple concurrent Ralph Loop sessions supported
- **File-based State**: Persistent state stored in `~/.goose/ralph/{sessionId}/`
- **11 MCP Tools**: Complete workflow control via MCP tools, including `ralph_loop_run` for full automation
- **Cross-Model Review**: Worker/reviewer model configuration with validation
- **Multiple LLM Providers**: Anthropic (Claude), OpenAI, Google (Gemini), GitHub Copilot, Goose
- **Flexible Configuration**: Environment variables, CLI arguments, or MCP tool calls

## Implementations

| Platform | File | Requirements |
|----------|------|--------------|
| Linux/macOS | `ralph-loop-runner.sh` | bash, jq |
| Windows | `ralph-loop-runner.ps1` | PowerShell 5.1+, jq |

Both implementations provide identical functionality in a single script file each.

## Installation

### Prerequisites

- **jq** - JSON processor (required for both Bash and PowerShell)
  - Linux: `apt-get install jq` / `yum install jq` / `apk add jq`
  - macOS: `brew install jq`
  - Windows: `choco install jq` / `winget install jqlang.jq` / `scoop install jq`

- **Bash** (Linux/macOS) or **PowerShell 5.1+** (Windows)

- **LLM CLI** (for `ralph_loop_run` and CLI mode): 
  - `claude` (Anthropic)
  - `openai` (OpenAI)
  - `gemini` (Google)
  - `copilot` (GitHub Copilot) — `npm install -g @github/copilot`
  - `goose` (Goose) — `go install github.com/aaif-goose/goose@latest`

### Setup

```bash
# Clone the repository
git clone https://github.com/sheldonrobinson/ralph-loop-mcp
cd ralph-loop-mcp

# Make executable (Linux/macOS)
chmod +x ralph-loop-runner.sh

# Configure in Claude Desktop (MCP mode):
{
  mode):
{
  "mcpServers": {
    "ralph-loop": {
      "command": "/path/to/ralph-loop-runner.sh",
      "args": []
    }
  }
}
```

**Windows (PowerShell):**
```powershell
# Configure in claude_desktop_config.json:
{
  "mcpServers": {
    "ralph-loop": {
      "command": "powershell.exe",
      "args": ["-File", "C:\\path\\to\\ralph-loop-runner.ps1"]
    }
  }
}
```

## Usage

### CLI Mode (Direct Execution)

Run the complete Ralph Loop directly from the command line:

```bash
# Linux/macOS - task as argument
./ralph-loop-runner.sh "Implement user authentication with JWT tokens"

# Linux/macOS - task from file
./ralph-loop-runner.sh ./task.md

# Windows
.\ralph-loop-runner.ps1 "Implement user authentication with JWT tokens"
.\ralph-loop-runner.ps1 .\task.md
```

**With environment variables:**
```bash
RALPH_WORKER_MODEL=claude-3-5-sonnet \
RALPH_WORKER_PROVIDER=anthropic \
RALPH_REVIEWER_MODEL=gpt-4o \
RALPH_REVIEWER_PROVIDER=openai \
RALPH_MAX_ITERATIONS=5 \
./ralph-loop-runner.sh "Your task here"
```

**With command-line arguments:**
```bash
./ralph-loop-runner.sh "Your task here" \
  --worker-model claude-3-5-sonnet \
  --worker-provider anthropic \
  --worker-agent goose \
  --reviewer-model gpt-4o \
  --reviewer-provider openai \
  --reviewer-agent goose \
  --max-iterations 5 \
  --work-guidelines ./recipes/ralph-work.yaml \
  --review-guidelines ./recipes/ralph-review.yaml \
  --session-id my-feature
```

### MCP Server Mode

When run without arguments, the script runs as an MCP server over stdio:

```bash
# Linux/macOS
./ralph-loop-runner.sh

# Windows
powershell.exe -File ralph-loop-runner.ps1
```

### Quick Start: Full Automated Loop (Recommended)

Use the `ralph_loop_run` tool to run the complete worker/reviewer loop automatically:

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_run",
    "arguments": {
      "sessionId": "my-feature",
      "task": "Implement user authentication with JWT tokens",
      "maxIterations": 5,
      "workerModel": "claude-3-5-sonnet",
      "workerProvider": "anthropic",
      "workerAgent": "goose",
      "reviewerModel": "gpt-4o",
      "reviewerProvider": "openai",
      "reviewerAgent": "goose",
      "crossModelReviewEnforced": true,
      "workGuidelines": "/path/to/ralph-work.yaml",
      "reviewGuidelines": "/path/to/ralph-review.yaml"
    }
  }
}
```

This tool handles:
1. **Initialization** - Creates session with worker/reviewer configuration
2. **Orchestration** - Loops through WORK → REVIEW phases
3. **Execution** - Calls LLM providers via CLI (claude, openai, gemini, copilot, goose)
4. **State Management** - Persists all state to `~/.goose/ralph/{sessionId}/`

### Manual Step-by-Step Workflow

For more control, use individual tools:

1. **Initialize Session**
```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_initialize",
    "arguments": {
      "sessionId": "my-feature",
      "task": "Implement user authentication with JWT tokens",
      "maxIterations": 5,
      "workerModel": "claude-3-5-sonnet",
      "workerProvider": "anthropic",
      "workerAgent": "goose",
      "reviewerModel": "gpt-4o",
      "reviewerProvider": "openai",
      "reviewerAgent": "goose"
    }
  }
}
```

2. **Worker Phase - Get Task**
```json
{
  "method": "tools/call",
  "params": { "name": "ralph_loop_get_task", "arguments": { "sessionId": "my-feature" } }
}
```

3. **Worker Phase - Submit Work**
```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_submit_work",
    "arguments": {
      "sessionId": "my-feature",
      "iteration": 1,
      "work": "// Complete JWT implementation...",
      "summary": "Implemented JWT auth with access/refresh tokens, middleware, and tests"
    }
  }
}
```

4. **Reviewer Phase - Get Work**
```json
{
  "method": "tools/call",
  "params": { "name": "ralph_loop_get_work", "arguments": { "sessionId": "my-feature" } }
}
```

5. **Reviewer Phase - Submit Review**
```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_submit_review",
    "arguments": {
      "sessionId": "my-feature",
      "iteration": 1,
      "decision": "REVISE",
      "feedback": "Add token expiration handling and improve error messages"
    }
  }
}
```

6. **Next Iteration - Get Feedback**
```json
{
  "method": "tools/call",
  "params": { "name": "ralph_loop_get_feedback", "arguments": { "sessionId": "my-feature" } }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `ralph_loop_initialize` | Initialize a new Ralph Loop session with a task |
| `ralph_loop_get_task` | Get the current task for the worker phase |
| `ralph_loop_submit_work` | Submit work results and summary from worker |
| `ralph_loop_get_work` | Get worker's submitted work for reviewer |
| `ralph_loop_submit_review` | Submit review decision (SHIP/REVISE) with feedback |
| `ralph_loop_get_feedback` | Get reviewer feedback for next iteration |
| `ralph_loop_get_status` | Get current session status (iteration, phase, state) |
| `ralph_loop_get_config` | Get worker/reviewer model configuration |
| `ralph_loop_reset` | Reset/clear a session |
| `ralph_loop_block` | Block current iteration with reason |
| `ralph_loop_run` | **Run complete automated loop** (initialization → orchestration → execution → state management) |

## State Management

State is stored in `~/.goose/ralph/{sessionId}/`:

```
~/.goose/ralph/my-feature/
├── config.json           # Worker/reviewer model configuration
├── task.json             # Original task
├── work.json             # Current work submission
├── review.json           # Current review
├── work-complete.txt     # Worker completion flag
├── review-result.txt     # SHIP/REVISE decision
├── review-feedback.txt   # Reviewer feedback
├── RALPH-BLOCKED.md      # Blocking reason (if blocked)
└── iteration.txt         # Current iteration number
```

## Cross-Model Review Setup

For true cross-model review, use different models for worker and reviewer:

**Worker (e.g., Claude Sonnet)**:
- Gets fresh context each iteration
- Receives only task + feedback
- Does the actual work

**Reviewer (e.g., GPT-4, Gemini, or another Claude)**:
- Reviews worker's output
- Provides SHIP/REVISE decision
- Gives specific feedback for revision

The `crossModelReviewEnforced` option (default: true) validates that worker and reviewer use different models/providers, warning if they are the same.

## Blocking

If the worker gets stuck, they can block the iteration:

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_block",
    "arguments": {
      "sessionId": "my-feature",
      "reason": "Cannot proceed - missing API credentials for external service"
    }
  }
}
```

This creates `RALPH-BLOCKED.md` and stops the loop until resolved.

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RALPH_WORKER_MODEL` | Worker model name | — |
| `RALPH_WORKER_PROVIDER` | Worker provider (anthropic/openai/google/copilot/goose) | — |
| `RALPH_WORKER_AGENT` | Worker agent (goose/claude/openai/gemini/copilot) | goose |
| `RALPH_REVIEWER_MODEL` | Reviewer model name | — |
| `RALPH_REVIEWER_PROVIDER` | Reviewer provider (anthropic/openai/google/copilot/goose) | — |
| `RALPH_REVIEWER_AGENT` | Reviewer agent (goose/claude/openai/gemini/copilot) | goose |
| `RALPH_MAX_ITERATIONS` | Max iterations (-1 for unlimited) | 10 |
| `RALPH_WORK_GUIDELINES` | Path to work guidelines/recipe | `$RALPH_RECIPE_DIR/ralph-work.yaml` |
| `RALPH_REVIEW_GUIDELINES` | Path to review guidelines/recipe | `$RALPH_RECIPE_DIR/ralph-review.yaml` |
| `RALPH_RECIPE_DIR` | Base directory for recipes | `/usr/local/share/ralph-loop-runner/recipes` |

### Command-Line Arguments (CLI Mode)

| Argument | Description |
|----------|-------------|
| `--worker-model MODEL` | Worker model name |
| `--worker-provider PROVIDER` | Worker provider (anthropic/openai/google/copilot/goose) |
| `--worker-agent AGENT` | Worker agent (goose/claude/openai/gemini/copilot) |
| `--reviewer-model MODEL` | Reviewer model name |
| `--reviewer-provider PROVIDER` | Reviewer provider (anthropic/openai/google/copilot/goose) |
| `--reviewer-agent AGENT` | Reviewer agent (goose/claude/openai/gemini/copilot) |
| `--max-iterations N` | Max iterations (-1 for unlimited) |
| `--work-guidelines FILE` | Work guidelines/recipe file |
| `--review-guidelines FILE` | Review guidelines/recipe file |
| `--session-id ID` | Custom session ID |

## Supported Providers

| Provider | CLI Command | Notes |
|----------|-------------|-------|
| Anthropic | `claude --model <model> --print` | Requires Anthropic API key |
| OpenAI | `openai chat --model <model> --no-stream` | Requires OpenAI API key |
| Google | `gemini --model <model> --format=text` | Requires Google API key |
| GitHub Copilot | `copilot -p --allow-all-tools --model <model>` | Requires `gh auth login` + Copilot subscription |
| Goose | `goose run --recipe <file> --session <id>` | Uses Goose recipes for structured workflows |

## API Reference

### ralph_loop_initialize
```typescript
{
  sessionId?: string;              // default: "default"
  task: string;                    // required
  maxIterations?: number;          // default: 10, -1 = unlimited
  workerModel?: string;            // e.g., "claude-3-5-sonnet"
  workerProvider?: string;         // e.g., "anthropic"
  workerAgent?: string;            // e.g., "goose"
  reviewerModel?: string;          // e.g., "gpt-4o"
  reviewerProvider?: string;       // e.g., "openai"
  reviewerAgent?: string;          // e.g., "goose"
  crossModelReviewEnforced?: boolean; // default: true
  workGuidelines?: string;         // path to work guidelines
  reviewGuidelines?: string;       // path to review guidelines
}
```

### ralph_loop_get_task
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_submit_work
```typescript
{
  sessionId?: string;  // default: "default"
  work: string;        // required
  summary: string;     // required
  iteration: number;   // required, >= 1
}
```

### ralph_loop_get_work
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_submit_review
```typescript
{
  sessionId?: string;           // default: "default"
  decision: "SHIP" | "REVISE";  // required
  feedback?: string;            // required for REVISE
  iteration: number;            // required, >= 1
}
```

### ralph_loop_get_feedback
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_get_status
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_get_config
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_reset
```typescript
{ sessionId?: string; }  // default: "default"
```

### ralph_loop_block
```typescript
{
  sessionId?: string;  // default: "default"
  reason: string;      // required
}
```

### ralph_loop_run
```typescript
{
  sessionId?: string;              // default: "default"
  task: string;                    // required
  maxIterations?: number;          // default: 10, -1 = unlimited
  workerModel: string;             // required
  workerProvider: string;          // required
  workerAgent?: string;            // default: "goose"
  reviewerModel: string;           // required
  reviewerProvider: string;        // required
  reviewerAgent?: string;          // default: "goose"
  crossModelReviewEnforced?: boolean; // default: true
  workGuidelines?: string;         // path to work guidelines
  reviewGuidelines?: string;       // path to review guidelines
}
```

## License

MIT