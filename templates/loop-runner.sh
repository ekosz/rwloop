#!/bin/bash
#
# loop-runner.sh - Runs on the sprite inside tmux
# This script is copied to the sprite and executed there
#
set -uo pipefail

REPO_DIR="/var/local/rwloop/repo"
SESSION_DIR="/var/local/rwloop/session"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
MAX_DURATION_HOURS="${MAX_DURATION_HOURS:-4}"
STUCK_THRESHOLD="${STUCK_THRESHOLD:-3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[rwloop]${NC} $*"; }
info() { echo -e "${BLUE}[info]${NC} $*"; }
success() { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*" >&2; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# Read JSON field
json_get() {
  jq -r "$2" "$1" 2>/dev/null || echo ""
}

# Count tasks
count_incomplete() {
  jq '[.[] | select(.passes == false)] | length' "$SESSION_DIR/tasks.json"
}

# Check if stuck (no progress in N iterations)
is_stuck() {
  local history_file="$SESSION_DIR/history.json"
  [[ ! -f "$history_file" ]] && return 1

  local len
  len=$(jq 'length' "$history_file")
  [[ $len -lt $STUCK_THRESHOLD ]] && return 1

  local unique
  unique=$(jq -r "[.[-$STUCK_THRESHOLD:][].tasks_completed] | unique | length" "$history_file")
  [[ "$unique" -eq 1 ]]
}

# Run one iteration of Claude
run_iteration() {
  local iteration=$1

  log "Running Claude..."

  local prompt_file="$SESSION_DIR/iterate_prompt.md"
  local context_file="$SESSION_DIR/context_prompt.md"

  HOME=/var/local/rwloop claude \
    -p "$(cat "$prompt_file")" \
    --append-system-prompt "$(cat "$context_file")" \
    --dangerously-skip-permissions \
    --max-turns 200 \
    --output-format stream-json \
    --verbose 2>&1 | while IFS= read -r line; do
      if [[ "$line" == *'"type":"assistant"'* ]] || [[ "$line" == *'"type":"text"'* ]]; then
        echo "$line" | jq -r '.message.content[]?.text // .content // empty' 2>/dev/null || true
      elif [[ "$line" == *'"type":"result"'* ]]; then
        info "Claude finished"
      fi
    done

  return ${PIPESTATUS[0]}
}

# Main loop
main() {
  local iteration=0
  local start_time
  start_time=$(date +%s)
  local max_seconds=$((MAX_DURATION_HOURS * 3600))

  log "Starting iteration loop..."
  log "Press 'd' to detach (loop continues in background)"
  echo ""

  while true; do
    iteration=$((iteration + 1))

    # Check limits
    if [[ $iteration -gt $MAX_ITERATIONS ]]; then
      warn "Max iterations ($MAX_ITERATIONS) reached"
      echo '{"status":"PAUSED","summary":"Max iterations reached","error":"max_iterations"}' > "$SESSION_DIR/state.json"
      exit 0
    fi

    local elapsed=$(($(date +%s) - start_time))
    if [[ $elapsed -gt $max_seconds ]]; then
      warn "Max duration (${MAX_DURATION_HOURS}h) exceeded"
      echo '{"status":"PAUSED","summary":"Max duration exceeded","error":"max_duration"}' > "$SESSION_DIR/state.json"
      exit 0
    fi

    log "=== Iteration $iteration ==="

    # Run Claude
    if ! run_iteration "$iteration"; then
      error "Claude failed"
      echo '{"status":"PAUSED","summary":"Claude failed","error":"claude_failed"}' > "$SESSION_DIR/state.json"
      exit 1
    fi

    # Read state
    local status summary
    status=$(json_get "$SESSION_DIR/state.json" '.status')
    summary=$(json_get "$SESSION_DIR/state.json" '.summary')

    info "Status: $status"
    info "Summary: $summary"

    # Handle status
    case "$status" in
      DONE)
        local incomplete
        incomplete=$(count_incomplete)
        if [[ "$incomplete" -eq 0 ]]; then
          success "All tasks complete!"
          exit 0
        else
          warn "Agent said DONE but $incomplete tasks incomplete, continuing..."
        fi
        ;;
      NEEDS_INPUT)
        local question
        question=$(json_get "$SESSION_DIR/state.json" '.question')
        warn "Agent needs input: $question"
        warn "Run 'rwloop respond \"<answer>\"' then 'rwloop resume'"
        exit 0
        ;;
      BLOCKED)
        local err
        err=$(json_get "$SESSION_DIR/state.json" '.error')
        error "Agent blocked: $err"
        exit 1
        ;;
      CONTINUE)
        if is_stuck; then
          warn "No progress in $STUCK_THRESHOLD iterations - stuck"
          echo '{"status":"PAUSED","summary":"Stuck - no progress","error":"stuck"}' > "$SESSION_DIR/state.json"
          exit 1
        fi
        ;;
    esac

    sleep 2
  done
}

main "$@"
