import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { fileURLToPath } from "url";
import { dirname, resolve } from "path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "fs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// State directory - cross-platform
const getStateDir = (sessionId: string = "default"): string => {
  const homeDir = process.env.HOME || process.env.USERPROFILE || ".";
  return resolve(homeDir, ".goose", "ralph", sessionId);
};

// State file paths
const getStateFile = (sessionId: string, fileName: string): string => {
  return resolve(getStateDir(sessionId), fileName);
};

// Configuration types
interface RalphConfig {
  workerModel?: string;
  workerProvider?: string;
  reviewerModel?: string;
  reviewerProvider?: string;
  maxIterations: number;
  crossModelReviewEnforced: boolean;
}

// State types
interface RalphTask {
  task: string;
  createdAt: string;
}

interface RalphConfigState extends RalphConfig {
  configuredAt: string;
}

interface RalphWork {
  work: string;
  summary: string;
  submittedAt: string;
  iteration: number;
}

interface RalphReview {
  decision: "SHIP" | "REVISE";
  feedback: string;
  reviewedAt: string;
  iteration: number;
}

interface RalphStatus {
  sessionId: string;
  currentIteration: number;
  maxIterations: number;
  phase: "WORK" | "REVIEW" | "COMPLETE" | "BLOCKED";
  status: "running" | "shipped" | "revised" | "blocked" | "max_iterations_reached";
  task?: string;
  lastWorkSummary?: string;
  lastFeedback?: string;
  createdAt: string;
  updatedAt: string;
  workerModel?: string;
  workerProvider?: string;
  reviewerModel?: string;
  reviewerProvider?: string;
  crossModelReviewEnforced?: boolean;
  crossModelReviewValid?: boolean;
  crossModelReviewWarning?: string;
}

// Session state management
class RalphState {
  private sessionId: string;

  constructor(sessionId: string = "default") {
    this.sessionId = sessionId;
    this.ensureStateDir();
  }

  private ensureStateDir(): void {
    const dir = getStateDir(this.sessionId);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }

  private readJson<T>(fileName: string): T | null {
    const path = getStateFile(this.sessionId, fileName);
    if (!existsSync(path)) return null;
    try {
      return JSON.parse(readFileSync(path, "utf-8")) as T;
    } catch {
      return null;
    }
  }

  private writeJson<T>(fileName: string, data: T): void {
    const path = getStateFile(this.sessionId, fileName);
    writeFileSync(path, JSON.stringify(data, null, 2), "utf-8");
  }

  private removeFile(fileName: string): void {
    const path = getStateFile(this.sessionId, fileName);
    if (existsSync(path)) {
      rmSync(path);
    }
  }

  // Config management
  setConfig(config: RalphConfig): void {
    const configData: RalphConfigState = {
      ...config,
      configuredAt: new Date().toISOString(),
    };
    this.writeJson("config.json", configData);
  }

  getConfig(): RalphConfigState | null {
    return this.readJson<RalphConfigState>("config.json");
  }

  // Validate cross-model review configuration
  validateCrossModelReview(): { valid: boolean; warning?: string } {
    const config = this.getConfig();
    if (!config) {
      return { valid: true }; // Not configured yet
    }
    if (
      config.crossModelReviewEnforced &&
      config.workerModel === config.reviewerModel &&
      config.workerProvider === config.reviewerProvider
    ) {
      return {
        valid: false,
        warning: "Worker and reviewer are the same model/provider. Cross-model review requires different models.",
      };
    }
    return { valid: true };
  }

  // Task management
  setTask(task: string): void {
    const taskData: RalphTask = {
      task,
      createdAt: new Date().toISOString(),
    };
    this.writeJson("task.json", taskData);
    this.removeFile("RALPH-BLOCKED.md");
  }

  getTask(): RalphTask | null {
    return this.readJson<RalphTask>("task.json");
  }

  // Work management
  setWork(work: string, summary: string, iteration: number): void {
    const workData: RalphWork = {
      work,
      summary,
      submittedAt: new Date().toISOString(),
      iteration,
    };
    this.writeJson("work.json", workData);
    this.writeJson("work-complete.txt", { ok: true });
  }

  getWork(): RalphWork | null {
    return this.readJson<RalphWork>("work.json");
  }

  // Review management
  setReview(decision: "SHIP" | "REVISE", feedback: string, iteration: number): void {
    const reviewData: RalphReview = {
      decision,
      feedback,
      reviewedAt: new Date().toISOString(),
      iteration,
    };
    this.writeJson("review.json", reviewData);
    this.writeJson("review-result.txt", { decision });
    this.writeJson("review-feedback.txt", { feedback });
  }

  getReview(): RalphReview | null {
    return this.readJson<RalphReview>("review.json");
  }

  getReviewResult(): string | null {
    const result = this.readJson<{ decision: string }>("review-result.txt");
    return result?.decision || null;
  }

  getFeedback(): string | undefined {
    const feedback = this.readJson<{ feedback: string }>("review-feedback.txt");
    return feedback?.feedback;
  }

  // Status management
  getStatus(maxIterations: number = 10): RalphStatus {
    const task = this.getTask();
    const work = this.getWork();
    const review = this.getReview();
    const reviewResult = this.getReviewResult();
    const feedback = this.getFeedback();
    const blocked = existsSync(getStateFile(this.sessionId, "RALPH-BLOCKED.md"));
    const config = this.getConfig();

    const crossModelValidation = this.validateCrossModelReview();

    let phase: RalphStatus["phase"] = "WORK";
    let status: RalphStatus["status"] = "running";
    let currentIteration = 1;

    if (blocked) {
      phase = "BLOCKED";
      status = "blocked";
    } else if (reviewResult === "SHIP") {
      phase = "COMPLETE";
      status = "shipped";
      currentIteration = work?.iteration || 1;
    } else if (reviewResult === "REVISE") {
      phase = "WORK";
      status = "revised";
      currentIteration = (work?.iteration || 1) + 1;
    } else if (work) {
      phase = "REVIEW";
      status = "running";
      currentIteration = work.iteration;
    } else {
      phase = "WORK";
      status = "running";
      currentIteration = 1;
    }

    if (currentIteration > maxIterations && status === "running") {
      status = "max_iterations_reached";
      phase = "COMPLETE";
    }

    return {
      sessionId: this.sessionId,
      currentIteration,
      maxIterations,
      phase,
      status,
      task: task?.task,
      lastWorkSummary: work?.summary,
      lastFeedback: feedback,
      createdAt: task?.createdAt || new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      workerModel: config?.workerModel,
      workerProvider: config?.workerProvider,
      reviewerModel: config?.reviewerModel,
      reviewerProvider: config?.reviewerProvider,
      crossModelReviewEnforced: config?.crossModelReviewEnforced,
      crossModelReviewValid: crossModelValidation.valid,
      crossModelReviewWarning: crossModelValidation.warning,
    };
  }

  // Check if work is complete (for worker phase)
  isWorkComplete(): boolean {
    return existsSync(getStateFile(this.sessionId, "work-complete.txt"));
  }

  // Check if blocked
  isBlocked(): string | null {
    const blockedPath = getStateFile(this.sessionId, "RALPH-BLOCKED.md");
    if (existsSync(blockedPath)) {
      return readFileSync(blockedPath, "utf-8");
    }
    return null;
  }

  // Clean up temporary files for next iteration
  cleanupForNextIteration(): void {
    this.removeFile("work-complete.txt");
    this.removeFile("review-result.txt");
    this.removeFile("review-feedback.txt");
    this.removeFile("work.json");
    this.removeFile("review.json");
  }

  // Reset session
  reset(): void {
    const dir = getStateDir(this.sessionId);
    if (existsSync(dir)) {
      rmSync(dir, { recursive: true, force: true });
    }
  }
}

// Tool definitions
const TOOLS: Tool[] = [
  {
    name: "ralph_loop_initialize",
    description: "Initialize a new Ralph Loop session with a task. Starts the iterative worker/reviewer cycle.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Unique session identifier (optional, defaults to 'default')",
          default: "default",
        },
        task: {
          type: "string",
          description: "The task description for the Ralph Loop to work on",
        },
        maxIterations: {
          type: "number",
          description: "Maximum number of iterations (default: 10)",
          default: 10,
          minimum: 1,
          maximum: 50,
        },
        workerModel: {
          type: "string",
          description: "Model for the worker phase (e.g., 'claude-3-5-sonnet', 'gpt-4o')",
        },
        workerProvider: {
          type: "string",
          description: "Provider for the worker phase (e.g., 'anthropic', 'openai')",
        },
        reviewerModel: {
          type: "string",
          description: "Model for the reviewer phase (should be different from worker for cross-model review)",
        },
        reviewerProvider: {
          type: "string",
          description: "Provider for the reviewer phase (e.g., 'anthropic', 'openai', 'google')",
        },
        crossModelReviewEnforced: {
          type: "boolean",
          description: "Enforce cross-model review (worker and reviewer must be different)",
          default: true,
        },
      },
      required: ["task"],
    },
  },
  {
    name: "ralph_loop_get_task",
    description: "Get the current task for the worker phase. Returns the task description.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_submit_work",
    description: "Submit work results and summary from the worker phase. Transitions to review phase.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
        work: {
          type: "string",
          description: "The complete work output/results",
        },
        summary: {
          type: "string",
          description: "Brief summary of what was done",
        },
        iteration: {
          type: "number",
          description: "Current iteration number",
          minimum: 1,
        },
      },
      required: ["work", "summary", "iteration"],
    },
  },
  {
    name: "ralph_loop_get_work",
    description: "Get the worker's submitted work for the reviewer phase. Returns work output and summary.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_submit_review",
    description: "Submit review decision (SHIP or REVISE) with feedback from the reviewer phase.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
        decision: {
          type: "string",
          enum: ["SHIP", "REVISE"],
          description: "Review decision - SHIP to complete, REVISE to iterate again",
        },
        feedback: {
          type: "string",
          description: "Feedback for the worker (required for REVISE, optional for SHIP)",
        },
        iteration: {
          type: "number",
          description: "Current iteration number",
          minimum: 1,
        },
      },
      required: ["decision", "iteration"],
    },
  },
  {
    name: "ralph_loop_get_feedback",
    description: "Get reviewer feedback for the next worker iteration. Returns feedback if REVISE, or completion status if SHIP.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_get_status",
    description: "Get current status of the Ralph Loop session including iteration, phase, and state.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_get_config",
    description: "Get the worker/reviewer model configuration for the session.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_reset",
    description: "Reset/clear a Ralph Loop session, removing all state files.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
      },
      required: [],
    },
  },
  {
    name: "ralph_loop_block",
    description: "Block the current iteration with a reason (creates RALPH-BLOCKED.md). Worker uses this when stuck.",
    inputSchema: {
      type: "object",
      properties: {
        sessionId: {
          type: "string",
          description: "Session identifier",
          default: "default",
        },
        reason: {
          type: "string",
          description: "Reason for blocking",
        },
      },
      required: ["reason"],
    },
  },
];

// Create MCP server
const server = new Server(
  {
    name: "ralph-loop-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List tools handler
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: TOOLS };
});

// Call tool handler
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const sessionId = (args?.sessionId as string) || "default";
  const state = new RalphState(sessionId);

  try {
    switch (name) {
      case "ralph_loop_initialize": {
        const task = args?.task as string;
        const maxIterations = (args?.maxIterations as number) || 10;
        const workerModel = args?.workerModel as string | undefined;
        const workerProvider = args?.workerProvider as string | undefined;
        const reviewerModel = args?.reviewerModel as string | undefined;
        const reviewerProvider = args?.reviewerProvider as string | undefined;
        const crossModelReviewEnforced = (args?.crossModelReviewEnforced as boolean) ?? true;
        
        if (!task) {
          throw new Error("Task is required");
        }

        state.setTask(task);
        
        // Save configuration
        state.setConfig({
          workerModel,
          workerProvider,
          reviewerModel,
          reviewerProvider,
          maxIterations,
          crossModelReviewEnforced,
        });

        // Validate cross-model review
        const validation = state.validateCrossModelReview();
        
        const status = state.getStatus(maxIterations);
        
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                message: `Ralph Loop initialized for session "${sessionId}"`,
                status,
                crossModelReview: {
                  enforced: crossModelReviewEnforced,
                  valid: validation.valid,
                  warning: validation.warning,
                },
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_get_task": {
        const task = state.getTask();
        
        if (!task) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  success: false,
                  error: "No task found. Initialize the session first with ralph_loop_initialize.",
                }, null, 2),
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                task: task.task,
                createdAt: task.createdAt,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_submit_work": {
        const work = args?.work as string;
        const summary = args?.summary as string;
        const iteration = args?.iteration as number;

        if (!work || !summary || !iteration) {
          throw new Error("work, summary, and iteration are required");
        }

        state.setWork(work, summary, iteration);
        const status = state.getStatus();

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                message: `Work submitted for iteration ${iteration}`,
                status,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_get_work": {
        const work = state.getWork();

        if (!work) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  success: false,
                  error: "No work submitted yet. Worker must submit work first.",
                }, null, 2),
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                work: work.work,
                summary: work.summary,
                iteration: work.iteration,
                submittedAt: work.submittedAt,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_submit_review": {
        const decision = args?.decision as "SHIP" | "REVISE";
        const feedback = args?.feedback as string;
        const iteration = args?.iteration as number;

        if (!decision || !iteration) {
          throw new Error("decision and iteration are required");
        }

        if (decision === "REVISE" && !feedback) {
          throw new Error("Feedback is required when decision is REVISE");
        }

        state.setReview(decision, feedback || "", iteration);
        
        // Cleanup for next iteration if REVISE
        if (decision === "REVISE") {
          state.cleanupForNextIteration();
        }

        const status = state.getStatus();

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                message: `Review submitted: ${decision}`,
                decision,
                feedback: feedback || "",
                status,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_get_feedback": {
        const reviewResult = state.getReviewResult();
        const feedback = state.getFeedback();
        const status = state.getStatus();

        if (!reviewResult) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  success: false,
                  error: "No review completed yet. Reviewer must submit review first.",
                }, null, 2),
              },
            ],
          };
        }

        if (reviewResult === "SHIP") {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  success: true,
                  shipped: true,
                  message: "Work approved! SHIPPED.",
                  status,
                }, null, 2),
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                shipped: false,
                feedback: feedback || "Revise based on reviewer feedback",
                iteration: status.currentIteration,
                status,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_get_status": {
        const status = state.getStatus();

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                ...status,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_get_config": {
        const config = state.getConfig();

        if (!config) {
          return {
            content: [
              {
                type: "text",
                text: JSON.stringify({
                  success: false,
                  error: "No configuration found. Initialize the session first with ralph_loop_initialize.",
                }, null, 2),
              },
            ],
          };
        }

        const validation = state.validateCrossModelReview();

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                config: {
                  workerModel: config.workerModel,
                  workerProvider: config.workerProvider,
                  reviewerModel: config.reviewerModel,
                  reviewerProvider: config.reviewerProvider,
                  maxIterations: config.maxIterations,
                  crossModelReviewEnforced: config.crossModelReviewEnforced,
                  configuredAt: config.configuredAt,
                },
                crossModelReview: {
                  enforced: config.crossModelReviewEnforced,
                  valid: validation.valid,
                  warning: validation.warning,
                },
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_reset": {
        state.reset();
        
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                message: `Session "${sessionId}" has been reset`,
              }, null, 2),
            },
          ],
        };
      }

      case "ralph_loop_block": {
        const reason = args?.reason as string;
        
        if (!reason) {
          throw new Error("Reason is required for blocking");
        }

        const blockedPath = getStateFile(sessionId, "RALPH-BLOCKED.md");
        writeFileSync(blockedPath, reason, "utf-8");

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                success: true,
                message: "Iteration blocked",
                reason,
              }, null, 2),
            },
          ],
        };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            success: false,
            error: error instanceof Error ? error.message : String(error),
          }, null, 2),
        },
      ],
    };
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Ralph Loop MCP Server running on stdio");
}

main().catch((error) => {
  console.error("Server error:", error);
  process.exit(1);
});