# Iteration Instructions

You are in iteration mode. Follow these steps exactly.

## IMPORTANT: Keep Context Small with Agents

Your context window is precious - don't fill it with file contents. Use agents strategically:

**For Reading/Searching (use Explore agents liberally):**
- Spawn multiple explore agents in parallel to search the codebase
- Have agents return summaries, not full file contents
- Fan out: one agent per area (e.g., "find auth patterns", "check test structure", "look for utilities")

**For Building/Testing (use ONE agent at a time):**
- Builds and tests need sequential execution with full output visibility
- Don't parallelize destructive or stateful operations

**Rule of thumb:** If you need to understand code but not edit it, use an explore agent. Only read files directly into your context when you're about to modify them.

---

## Step 1: Read State Files

Read these files from `/var/local/rwloop/session/`:
- `prd.md` - The original Product Requirements Document (read this first to understand context)
- `tasks.json` - Current task list
- `state.json` - Previous iteration state
- `history.json` - Iteration history

## Step 2: Check for Human Response

If `/var/local/rwloop/session/response.txt` exists:
1. Read the human's response
2. Delete the file after reading
3. Use the response to inform your work

## Step 3: Find Next Task

Look through `tasks.json` and find the first task where `passes: false`.

If all tasks have `passes: true`:
- Write state.json with `status: "DONE"`
- You're finished!

## Step 4: Work on the Task

### CRITICAL GUARDRAIL: Search Before Implementing

Before implementing ANY functionality, use **explore agents** to search:

1. **Spawn parallel explore agents** to search for:
   - Existing implementations of similar features
   - Shared libraries and utilities (`/lib`, `/utils`, `/shared`, `/common`)
   - Patterns used elsewhere in the codebase
   - Related tests to understand expected behavior

2. **Don't assume something doesn't exist** - verify first by searching
3. **Treat existing shared libraries as single source of truth**
4. **Only read files directly** when you're ready to modify them

This prevents duplicate code, reinventing existing patterns, AND keeps your context small.

### Implementation Steps

For the current task:
1. Search for existing relevant code and patterns
2. Read any relevant code files
3. Implement the required changes (using existing patterns where possible)
4. Run backpressure validations (see below)
5. If all validations pass, commit with a descriptive message
6. Push to the remote (`git push`)

### BACKPRESSURE: Validation Before Committing

**ALL of these must pass before committing:**

1. **Build** - Ensure the project compiles/builds successfully
   - Check `package.json` scripts, `Makefile`, `pyproject.toml`, etc.

2. **Tests** - Run the project's test suite
   - Look for: `npm test`, `pytest`, `go test`, `make test`

3. **Type Checking** (if applicable)
   - TypeScript: `npx tsc --noEmit`
   - Python with types: `mypy` or `pyright`

4. **Linting** (if configured)
   - Check for: `eslint`, `ruff`, `golangci-lint`

**If ANY validation fails:**
- Fix the issue immediately
- Re-run all validations
- Only commit when ALL pass

**Never skip validations. Never commit failing code.**

Tests, type checks, lints, and builds are your backpressure system - they reject invalid work and ensure convergence.

### Verify Acceptance Criteria

Before marking a task complete, verify ALL acceptance criteria in the task:

1. **Read the task's `acceptance_criteria` array**
2. **Verify each criterion is met** - manually test or check that the behavior works
3. **Only mark `passes: true` when ALL criteria are satisfied**

Example task with acceptance criteria:
```json
{
  "id": 2,
  "description": "Implement login endpoint",
  "acceptance_criteria": [
    "POST /login returns token for valid credentials",
    "Invalid credentials return 401 error"
  ],
  "passes": false
}
```

For this task, you must verify BOTH criteria work before setting `passes: true`.

### If you get stuck:
- Need clarification? Set `status: "NEEDS_INPUT"` and `question: "your question"`
- Hit an error you can't fix? Set `status: "BLOCKED"` and `error: "description"`

## Step 5: Update State Files

### Update tasks.json
If task is complete and verified:
```json
{
  "id": 1,
  "description": "...",
  "passes": true  // Changed from false
}
```

### Write state.json
```json
{
  "status": "CONTINUE",
  "summary": "Completed task 1: Set up TypeScript config. Tests passing.",
  "iteration": 5,
  "question": null,
  "error": null
}
```

### Append to history.json
Add a new entry:
```json
{
  "iteration": 5,
  "summary": "Completed task 1: Set up TypeScript config",
  "tasks_completed": 1,
  "status": "CONTINUE"
}
```

## Rules

1. **ONE task per iteration then STOP** - Complete exactly one task, update state files, then EXIT
2. **Verify before marking complete** - Run tests, check acceptance criteria are met
3. **All backpressure validations must pass** - Build, tests, types, linting
4. **Commit and push after completing** - One commit per task, push immediately
5. **Always update state files** - This is how continuity works
6. **Be honest about progress** - Don't mark tasks complete if they're not

## CRITICAL: Exit After One Task

After completing ONE task:
1. Update tasks.json (set `passes: true` for the completed task)
2. Write state.json with status "CONTINUE"
3. Append to history.json
4. **STOP IMMEDIATELY** - Do not start the next task!

The loop controller will start a fresh iteration for the next task. This keeps context small and prevents drift.

## Start Now

Read the state files, complete the next incomplete task, update state files, then exit.
