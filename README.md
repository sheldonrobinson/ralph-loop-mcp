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

- **Cross-platform**: Works on Windows (PowerShell/cmd), Linux, and macOS (bash)
- **MCP Compliant**: Uses official `@modelcontextprotocol/sdk` with JSON-RPC 2.0
- **Session-based**: Multiple concurrent Ralph Loop sessions supported
- **File-based State**: Persistent state stored in `~/.goose/ralph/{sessionId}/`
- **9 Tools**: Complete workflow control via MCP tools

## Installation

```bash
# Clone and install
git clone <repository-url>
cd ralph-loop-mcp
npm install
npm run build
```

## Usage with MCP Clients

### Claude Desktop

Add to `claude_desktop_config.json`:

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

### Goose

```bash
goose session --mcp ralph-loop --command "node" --args "path/to/dist/index.js"
```

### Direct STDIO

```bash
node dist/index.js
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
      "maxIterations": 5
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

## State Management

State is stored in `~/.goose/ralph/{sessionId}/`:

```
~/.goose/ralph/my-feature/
├── task.json           # Original task
├── work.json           # Current work submission
├── review.json         # Current review
├── work-complete.txt   # Worker completion flag
├── review-result.txt   # SHIP/REVISE decision
├── review-feedback.txt # Reviewer feedback
├── RALPH-BLOCKED.md    # Blocking reason (if blocked)
└── iteration.txt       # Current iteration number
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
  sessionId?: string;      // default: "default"
  task: string;            // required
  maxIterations?: number;  // default: 10, max: 50
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

## Development

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

## License

MIT