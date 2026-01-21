# Planning Mode Instructions

You are in planning mode. Your job is to perform a gap analysis between the PRD (Product Requirements Document) and the current codebase, then generate or update a prioritized task list.

## Step 1: Read the PRD

Read `/var/local/rwloop/session/prd.md` to understand what needs to be built.

## Step 2: Analyze the Codebase

Use subagents to explore the codebase efficiently:

1. **Search for existing implementations** related to PRD requirements
2. **Check project structure** - understand how code is organized
3. **Find shared utilities** - identify reusable components
4. **Review existing tests** - understand testing patterns
5. **Check AGENTS.md/CLAUDE.md** - read project conventions

Fan out this analysis to multiple subagents to preserve context.

## Step 3: Gap Analysis

Compare PRD requirements against what already exists:

1. **What's already implemented?** - Don't create tasks for existing functionality
2. **What's partially implemented?** - Create tasks to complete these
3. **What's completely missing?** - Create tasks to build from scratch
4. **What needs modification?** - Create tasks to update existing code

## Step 4: Generate/Update Tasks

### If this is a fresh plan (no existing tasks.json or --refresh flag):
Generate a complete task list based on gap analysis.

### If updating an existing plan (--refresh):
1. Read existing `/var/local/rwloop/session/tasks.json`
2. Preserve tasks where `passes: true` (already completed)
3. Re-evaluate incomplete tasks against current codebase state
4. Add new tasks if requirements were missed
5. Remove tasks that are no longer relevant
6. Re-prioritize based on current state

## Task Format

Write tasks to `/var/local/rwloop/session/tasks.json`:

```json
[
  {
    "id": 1,
    "description": "Clear, specific description of what to build",
    "category": "setup|feature|bugfix|refactor|test|docs",
    "steps": [
      "Step 1: What to do first",
      "Step 2: What to do second"
    ],
    "acceptance_criteria": [
      "Verifiable outcome 1",
      "Verifiable outcome 2"
    ],
    "passes": false
  }
]
```

## Task Prioritization

Order tasks by:
1. **Dependencies** - Tasks that unblock others come first
2. **Foundation** - Setup and infrastructure before features
3. **Risk** - Higher risk/uncertainty earlier (fail fast)
4. **Value** - Higher value features before nice-to-haves

## Guidelines

1. **Search before planning** - Don't plan to build what already exists
2. **Be specific** - Vague tasks lead to vague implementations
3. **Include acceptance criteria** - Every task needs verifiable outcomes
4. **Right-size tasks** - Each task should be 1-3 iterations of work
5. **Consider testing** - Include test requirements in task steps
6. **Think about order** - Later tasks may depend on earlier ones

## Output

After completing the analysis:

1. Write the task list to `/var/local/rwloop/session/tasks.json`
2. Write a summary to `/var/local/rwloop/session/plan_summary.md` including:
   - Total tasks generated
   - Key findings from gap analysis
   - Any risks or concerns identified
   - Recommended approach

## The Plan is Disposable

Remember: Plans go stale during implementation. The plan can be regenerated at any time with `--refresh`. Don't over-engineer the plan - focus on getting started with good-enough tasks that can be refined later.
