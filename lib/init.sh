#!/usr/bin/env bash
#
# init.sh - Initialize session from PRD
#

cmd_init() {
  local prd_file="${1:-}"

  if [[ -z "$prd_file" ]]; then
    error "Usage: rwloop init <prd.md>"
    exit 1
  fi

  if [[ ! -f "$prd_file" ]]; then
    error "PRD file not found: $prd_file"
    exit 1
  fi

  check_dependencies

  local session_dir
  session_dir=$(get_session_dir)
  local project_id
  project_id=$(get_project_id)

  # Check for existing session
  if [[ -d "$session_dir" ]] && [[ -f "$session_dir/session.json" ]]; then
    local existing_status
    existing_status=$(jq -r '.status // "unknown"' "$session_dir/session.json" 2>/dev/null || echo "unknown")

    # Check task progress
    local total_tasks=0
    local completed_tasks=0
    if [[ -f "$session_dir/tasks.json" ]]; then
      total_tasks=$(jq 'length' "$session_dir/tasks.json" 2>/dev/null || echo 0)
      completed_tasks=$(jq '[.[] | select(.passes == true)] | length' "$session_dir/tasks.json" 2>/dev/null || echo 0)
    fi

    warn "Existing session found for this project"
    info "Status: $existing_status"
    if [[ $total_tasks -gt 0 ]]; then
      info "Tasks: $completed_tasks/$total_tasks completed"
    fi
    echo ""

    echo "What would you like to do?"
    echo "  1) Start fresh (delete existing session)"
    echo "  2) Continue with existing session (just update PRD)"
    echo "  3) Cancel"
    echo ""
    read -rp "Choice [1/2/3]: " choice

    case "$choice" in
      1)
        log "Deleting existing session..."
        rm -rf "$session_dir"
        success "Old session deleted"
        ;;
      2)
        log "Continuing with existing session, updating PRD..."
        cp "$prd_file" "$session_dir/prd.md"
        success "PRD updated"
        echo ""
        echo "Next steps:"
        echo "  rwloop plan --refresh   # Re-analyze and update tasks"
        echo "  rwloop tasks            # View/edit tasks"
        echo "  rwloop run              # Continue the loop"
        exit 0
        ;;
      *)
        echo "Cancelled"
        exit 0
        ;;
    esac
  fi

  log "Initializing session for project: $project_id"

  # Create session directory
  mkdir -p "$session_dir"

  # Copy PRD
  cp "$prd_file" "$session_dir/prd.md"
  success "Copied PRD to session"

  # Generate initial session config
  local repo_name branch
  repo_name=$(get_repo_name)
  branch=$(get_current_branch)

  cat > "$session_dir/session.json" <<EOF
{
  "project_id": "$project_id",
  "repo": "$repo_name",
  "branch": "$branch",
  "source_dir": "$(pwd)",
  "created_at": "$(date -Iseconds)",
  "status": "initialized"
}
EOF

  # Initialize empty state
  cat > "$session_dir/state.json" <<EOF
{
  "status": "READY",
  "summary": "Session initialized, awaiting planning",
  "iteration": 0,
  "question": null,
  "error": null
}
EOF

  # Initialize empty history
  echo "[]" > "$session_dir/history.json"

  success "Session initialized at: $session_dir"
  echo ""
  echo "Next step:"
  echo "  rwloop plan    # Interactive planning session with Claude"
}

cmd_plan() {
  local refresh=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --refresh)
        refresh=true
        shift
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  check_dependencies

  local session_dir
  session_dir=$(get_session_dir)

  # Check if session exists and has required files
  if [[ ! -d "$session_dir" ]]; then
    error "No session found. Run 'rwloop init <prd.md>' first."
    exit 1
  fi

  if [[ ! -f "$session_dir/prd.md" ]]; then
    error "Session exists but PRD is missing."
    error "The previous 'rwloop init' may have failed."
    echo ""
    echo "Try running 'rwloop init <prd.md>' again."
    exit 1
  fi

  if [[ ! -f "$session_dir/session.json" ]]; then
    error "Session exists but session.json is missing."
    error "The previous 'rwloop init' may have failed."
    echo ""
    echo "Try running 'rwloop init <prd.md>' again."
    exit 1
  fi

  log "Starting interactive planning session..."
  echo ""
  info "This is a conversation with Claude to plan the implementation."
  info "Discuss architecture, share your thoughts, ask questions."
  info "When ready, ask Claude to 'generate the tasks' and it will write tasks.json"
  echo ""

  if [[ "$refresh" == "true" ]]; then
    info "Refresh mode: existing completed tasks will be preserved"
    echo ""
  fi

  # Build system prompt
  local system_prompt
  system_prompt=$(build_plan_system_prompt "$session_dir" "$refresh")

  # Run Claude interactively
  claude \
    --system-prompt "$system_prompt" \
    --dangerously-skip-permissions

  # Check if tasks were generated
  if [[ -f "$session_dir/tasks.json" ]]; then
    local task_count
    task_count=$(jq 'length' "$session_dir/tasks.json" 2>/dev/null || echo 0)
    if [[ $task_count -gt 0 ]]; then
      local complete_count
      complete_count=$(jq '[.[] | select(.passes == true)] | length' "$session_dir/tasks.json")
      echo ""
      success "Planning complete: $task_count tasks"
      echo ""
      echo "Next steps:"
      echo "  rwloop tasks        # Review/edit tasks"
      echo "  rwloop run          # Start the loop"
    else
      echo ""
      warn "No tasks in tasks.json. Run 'rwloop plan' again to continue."
    fi
  else
    echo ""
    info "No tasks generated yet. Run 'rwloop plan' again to continue planning."
  fi
}

build_plan_system_prompt() {
  local session_dir="$1"
  local refresh="$2"
  local template_path="$RWLOOP_DIR/templates/plan.md"
  local context_path="$RWLOOP_DIR/templates/context.md"

  # Verify templates exist
  if [[ ! -f "$template_path" ]]; then
    error "Template not found: $template_path"
    exit 1
  fi
  if [[ ! -f "$context_path" ]]; then
    error "Template not found: $context_path"
    exit 1
  fi

  # Build composite system prompt
  local prompt
  prompt="$(cat "$template_path")

---

$(cat "$context_path")

---

# PRD (Product Requirements Document)

The session directory is: $session_dir
Write tasks to: $session_dir/tasks.json

Here is the PRD:

$(cat "$session_dir/prd.md")"

  # Add existing tasks if refresh mode
  if [[ "$refresh" == "true" ]] && [[ -f "$session_dir/tasks.json" ]]; then
    prompt="$prompt

---

# Existing Tasks (--refresh mode)

This is a refresh operation. Preserve completed tasks (passes: true).
Re-evaluate incomplete tasks based on current codebase state.

Current tasks.json:
\`\`\`json
$(cat "$session_dir/tasks.json")
\`\`\`"
  fi

  echo "$prompt"
}

cmd_sessions() {
  local sessions_dir="$RWLOOP_HOME/sessions"

  if [[ ! -d "$sessions_dir" ]] || [[ -z "$(ls -A "$sessions_dir" 2>/dev/null)" ]]; then
    info "No sessions found"
    exit 0
  fi

  # Get current session ID for highlighting
  local current_id
  current_id=$(get_project_id)

  # Print header
  printf "${BOLD}%-14s %-30s %-20s %-12s %-10s %s${NC}\n" "ID" "REPO" "BRANCH" "STATUS" "TASKS" "CREATED"
  printf "%s\n" "$(printf '%.0s-' {1..120})"

  # List sessions
  while IFS='|' read -r id repo branch status tasks created; do
    [[ -z "$id" ]] && continue

    # Format created date (just date part)
    local created_short
    created_short=$(echo "$created" | cut -d'T' -f1)

    # Highlight current session
    local prefix=""
    if [[ "$id" == "$current_id" ]]; then
      prefix="${GREEN}* "
      printf "${GREEN}%-14s %-30s %-20s %-12s %-10s %s${NC}\n" "$id" "$repo" "$branch" "$status" "$tasks" "$created_short"
    else
      printf "%-14s %-30s %-20s %-12s %-10s %s\n" "$id" "$repo" "$branch" "$status" "$tasks" "$created_short"
    fi
  done < <(list_sessions)

  echo ""
  info "* = current session (based on directory and branch)"
}

cmd_tasks() {
  local session_id=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session)
        session_id="$2"
        shift 2
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  local session_dir
  session_dir=$(get_session_dir "$session_id")

  if [[ ! -d "$session_dir" ]]; then
    if [[ -n "$session_id" ]]; then
      error "Session not found: $session_id"
    else
      error "No session found. Run 'rwloop init <prd.md>' first."
    fi
    exit 1
  fi
  local tasks_file="$session_dir/tasks.json"

  if [[ ! -f "$tasks_file" ]]; then
    error "No tasks file found. Run 'rwloop init' first."
    exit 1
  fi

  # Show current tasks
  log "Current tasks:"
  echo ""
  jq -r 'to_entries[] | "\(.key + 1). [\(if .value.passes then "x" else " " end)] \(.value.description)"' "$tasks_file"
  echo ""

  # Open in editor if requested
  if confirm "Open in editor?" "y"; then
    local editor="${EDITOR:-vim}"
    "$editor" "$tasks_file"

    # Validate JSON after edit
    if ! jq . "$tasks_file" &>/dev/null; then
      error "Invalid JSON after edit. Please fix the syntax."
      "$editor" "$tasks_file"
    fi

    success "Tasks updated"
  fi
}
