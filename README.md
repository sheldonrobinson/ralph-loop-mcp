# Ralph Loop MCP Server

A cross-platform MCP (Model Context Protocol) server implementing the **Ralph Loop** — a multi-model iterative development technique where a "worker" model does the work and a "reviewer" model provides cross-model review, iterating until the reviewer says "SHIP".

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

- **Cross-platform Native**: Bash (Linux/macOS) and PowerShell (Windows) implementations — no Node.js runtime required
- **MCP Compliant**: JSON-RPC 2.0 over stdio
- **Session-based**: Multiple concurrent Ralph Loop sessions supported
- **File-based State**: Persistent state stored in `~/.goose/ralph/{sessionId}/`
- **10 Tools**: Complete workflow control via MCP tools
- **Cross-Model Review**: Worker/reviewer model configuration with validation

## Implementations

| Platform | File | Requirements |
|----------|------|--------------|
| Linux/macOS | `ralph-loop-mcp.sh` | bash, jq |
| Windows | `ralph-loop-mcp.ps1` | PowerShell 5.1+, jq |

Both implementations provide identical functionality.

## Installation

### Native Shell (Recommended - No Node.js Required)

**Linux/macOS:**
```bash
# Ensure jq is installed
# Ubuntu/Debian: sudo apt-get install jq
# macOS: brew install jq

# Make executable
chmod +x ralph-loop-mcp.sh

# Run directly:

{
  "mcpServers": {
    "ralph-loop": {
      "command": "/path/to/ralph-loop-mcp.sh",
      "args": []
    }
  }
}
```

**Windows (PowerShell):**
```powershell
# Ensure jq is installed
# choco install jq
# or: winget install jqlang.jq In claude_desktop_config.json: {
  "mcpServers": {    "ralph-loop": {
      "command": "powershell.exe",
      "args": ["-File", "C:\\path\\to\\ralph-loop-mcp.ps1"]
    }
  }
}
```

### Node.js Version (Alternative)

```bash
# Clone and install
git clone <repository-url>
cd ralph-loop-mcp
npm install
npm run build
```

**Claude Desktop (Node.js):**
```json
{
  "mcpServers": {
    "ralph-loop": {
      "command": "node",
      "args": ["path/to/ralph-loop-mcp/dist/index.js"]
    }
  }
}
```

## Usage with MCP Clients

### Goose (Native Shell)

```bash
# Linux/macOS
goose session --mcp ralph-loop --command "/path/to/ralph-loop-mcp.sh"

# Windows
goose session --mcp ralph-loop --command "powershell.exe" --args "-File C:\\path\\to\\ralph-loop-mcp.ps1"
```

### Direct STDIO

```bash
# Linux/macOS
./ralph-loop-mcp.sh

# Windows
powershell.exe -File ralph-loop-mcp.ps1
```

## Running the Ralph Loop (Orchestration Scripts)

The MCP server manages state, but you also need an orchestration script to actually run the worker/reviewer loop with different LLM models. Use these scripts for automated end-to-end execution:

### Linux/macOS (Bash)
```bash
# Make executable
chmod +x ralph-loop.sh

# Run with task from command line
./ralph-loop.sh "Implement user authentication with JWT tokens"

# Run with task from file
./ralph-loop.sh /path/to/task.md

# With environment variables (skips prompts)
RALPH_WORKER_MODEL=claude-3-5-sonnet \
RALPH_WORKER_PROVIDER=anthropic \
RALPH_REVIEWER_MODEL=gpt-4o \
RALPH_REVIEWER_PROVIDER=openai \
RALPH_MAX_ITERATIONS=5 \
./ralph-loop.sh "Your task here"
```

### Windows (PowerShell)
```powershell
# Run with task from command line
.\ralph-loop.ps1 "Implement user authentication with JWT tokens"

# Run with task from file
.\ralph-loop.ps1 C:\path\to\task.md

# With environment variables (skips prompts)
$env:RALPH_WORKER_MODEL = "claude-3-5-sonnet"
$env:RALPH_WORKER_PROVIDER = "anthropic"
$env:RALPH_REVIEWER_MODEL = "gpt-4o"
$env:RALPH_REVIEWER_PROVIDER = "openai"
$env:RALPH_MAX_ITERATIONS = 5
.\ralph-loop.ps1 "Your task here"
```

The orchestration script will:
1. Initialize a session with the MCP server
2. Run the WORK phase using the worker model
3. Run the REVIEW phase using the reviewer model
4. Loop until SHIP or max iterations reached

**Requirements:** jq + LLM CLI (claude, openai, gemini, or goose)

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

## Workflow Example

### 1. Initialize a Session

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
      "reviewerModel": "gpt-4o",
      "reviewerProvider": "openai",
      "crossModelReviewEnforced": true
    }
  }
}
```

### 2. Worker Phase - Get Task

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_get_task",
    "arguments": { "sessionId": "my-feature" }
  }
}
```

### 3. Worker Phase - Submit Work

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

### 4. Reviewer Phase - Get Work

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_get_work",
    "arguments": { "sessionId": "my-feature" }
  }
}
```

### 5. Reviewer Phase - Submit Review

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

### 6. Next Iteration - Get Feedback

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_get_feedback",
    "arguments": { "sessionId": "my-feature" }
  }
}
```

### 7. Check Status

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_get_status",
    "arguments": { "sessionId": "my-feature" }
  }
}
```

### 8. Get Configuration

```json
{
  "method": "tools/call",
  "params": {
    "name": "ralph_loop_get_config",
    "arguments": { "sessionId": "my-feature" }
  }
}
```

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

## API Reference

### ralph_loop_initialize
```typescript
{
  sessionId?: string;              // default: "default"
  task: string;                    // required
  maxIterations?: number;          // default: 10, max: 50
  workerModel?: string;            // e.g., "claude-3-5-sonnet"
  workerProvider?: string;         // e.g., "anthropic"
  reviewerModel?: string;          // e.g., "gpt-4o"
  reviewerProvider?: string;       // e.g., "openai"
  crossModelReviewEnforced?: boolean; // default: true
}
```

### ralph_loop_get_task
```typescript
{
  sessionId?: string;  // default: "default"
}
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
{
  sessionId?: string;  // default: "default"
}
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
{
  sessionId?: string;  // default: "default"
}
```

### ralph_loop_get_status
```typescript
{
  sessionId?: string;  // default: "default"
}
```

### ralph_loop_get_config
```typescript
{
  sessionId?: string;  // default: "default"
}
```

### ralph_loop_reset
```typescript
{
  sessionId?: string;  // default: "default"
}
```

### ralph_loop_block
```typescript
{
  sessionId?: string;  // default: "default"
  reason: string;      // required
}
```

## Development (Node.js Version)

```bash
# Install dependencies
npm install

# Build TypeScript
npm run build

# Run server
npm start

# Development (build + run)
npm run dev
```

## Requirements

- **jq** - JSON processor (required for both Bash and PowerShell)
  - Linux: `apt-get install jq` / `yum install jq` / `apk add jq`
  - macOS: `brew install jq`
  - Windows: `choco install jq` / `winget install jqlang.jq` / `scoop install jq`

- **Bash** (Linux/macOS) or **PowerShell 5.1+** (Windows)

## License

MIT