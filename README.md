# rwloop

A bash tool for running autonomous AI coding loops with Claude Code and Sprite VMs.

Implements the "Ralph Wiggum" pattern: stateless agent with stateful controller, fresh context per iteration, file-based continuity.

## Quick Start

```bash
# 1. Initialize with a PRD
rwloop init ./docs/my-feature.md

# 2. Review/edit generated tasks
rwloop tasks

# 3. Start the loop on a Sprite VM
rwloop run --branch feature/my-feature

# 4. Press Ctrl+C to pause (or let it run to completion)

# 5. Resume later if paused
rwloop resume

# 6. When complete, create PR
rwloop done
```

## Installation

```bash
# Clone the repo
git clone https://github.com/ekosz/rwloop.git

# Add to PATH
export PATH="$PATH:$(pwd)/rwloop"
```

## Requirements

- `claude` CLI installed and authenticated
- `sprite` CLI (for Sprite VM management)
- `gh` CLI (for PR creation)
- `jq` (for JSON parsing)
- `git` with push access

## Commands

| Command | Description |
|---------|-------------|
| `rwloop init <prd.md>` | Initialize session from PRD, generate tasks |
| `rwloop tasks` | View/edit the task list |
| `rwloop run [--branch name]` | Start loop on Sprite VM |
| `rwloop status` | Check session status |
| `rwloop resume` | Resume a paused session |
| `rwloop respond "msg"` | Respond to NEEDS_INPUT |
| `rwloop done` | Complete session, create PR |
| `rwloop stop` | Cancel and cleanup |

## Project Setup

Create `.rwloop/setup.md` in your repo with plain-text instructions for setting up the environment. Claude will read this and figure out what to do:

```markdown
This is a Phoenix + Elixir project.

Please ensure:
- Elixir is properly installed
- Dependencies are fetched (mix deps.get)
- The project compiles (mix compile)
- PostgreSQL is installed and running
- The database is set up so tests can run (mix ecto.setup)
```

This runs automatically after cloning when you `rwloop run`.

## How It Works

1. **Init**: Claude reads your PRD and generates a task list (`tasks.json`)
2. **Run**: Creates a Sprite VM, clones your repo, runs setup, starts the loop
3. **Loop**: Each iteration, Claude:
   - Reads state files (PRD, tasks, history, previous state)
   - Finds next incomplete task
   - Implements and verifies (runs tests)
   - Commits and pushes changes
   - Updates state files
   - Exits (one task per iteration keeps context small)
4. **Exit**: Loop pauses on NEEDS_INPUT/BLOCKED, or completes when all tasks pass
5. **Done**: Create PR, cleanup Sprite

## State Files

Stored in `~/.rwloop/sessions/<project-hash>/`:

- `prd.md` - Original PRD
- `tasks.json` - Task list with completion status
- `state.json` - Current iteration state (status, summary)
- `history.json` - Rolling iteration log
- `session.json` - Session metadata

## Configuration

Environment variables:

```bash
GITHUB_TOKEN           # For cloning private repos (or use 'gh auth login')
RWLOOP_HOME            # Config dir (default: ~/.rwloop)
RWLOOP_MAX_ITERATIONS  # Default: 50
RWLOOP_MAX_DURATION    # Hours, default: 4
RWLOOP_STUCK_THRESHOLD # Iterations without progress before pausing, default: 3
```

## Status Values

- `CONTINUE` - More work to do
- `DONE` - All tasks complete
- `NEEDS_INPUT` - Agent needs clarification (run `rwloop respond`)
- `BLOCKED` - Agent hit an error

## License

MIT
