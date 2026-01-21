# Iteration Instructions

You are in iteration mode. Follow these steps exactly:

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

For the current task:
1. Read any relevant code files
2. Implement the required changes
3. Run tests to verify (`npm test`, `pytest`, etc.)
4. If tests pass, commit with a descriptive message

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
2. **Verify before marking complete** - Run tests, check the code works
3. **Commit after completing** - One commit per task
4. **Always update state files** - This is how continuity works
5. **Be honest about progress** - Don't mark tasks complete if they're not

## CRITICAL: Exit After One Task

After completing ONE task:
1. Update tasks.json (set `passes: true` for the completed task)
2. Write state.json with status "CONTINUE"
3. Append to history.json
4. **STOP IMMEDIATELY** - Do not start the next task!

The loop controller will start a fresh iteration for the next task. This keeps context small and prevents drift.

## Start Now

Read the state files, complete the next incomplete task, update state files, then exit.
