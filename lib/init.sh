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

  # Generate tasks using Claude
  log "Generating tasks from PRD..."
  generate_tasks "$session_dir"

  # Let user edit tasks
  if confirm "Edit tasks before continuing?" "y"; then
    cmd_tasks
  fi

  success "Session initialized at: $session_dir"
  echo ""
  echo "Next steps:"
  echo "  1. Review tasks:  rwloop tasks"
  echo "  2. Start loop:    rwloop run"
}

generate_tasks() {
  local session_dir="$1"
  local prd_content
  local template_path="$RWLOOP_DIR/templates/create-tasks.md"

  # Verify template exists
  if [[ ! -f "$template_path" ]]; then
    error "Template not found: $template_path"
    exit 1
  fi

  prd_content=$(cat "$session_dir/prd.md")

  # Build prompt with PRD content
  local prompt
  prompt=$(cat "$template_path")
  prompt="$prompt

---

# PRD Content

$prd_content"

  # Run Claude in background with spinner
  local output_file
  output_file=$(mktemp)

  # Run claude and capture exit code properly
  set +e  # Temporarily disable exit on error
  claude -p "$prompt" --output-format text > "$output_file" 2>&1 &
  local claude_pid=$!

  spinner $claude_pid "Generating tasks with Claude..."

  wait $claude_pid
  local exit_code=$?
  set -e  # Re-enable exit on error

  local output
  output=$(cat "$output_file" 2>/dev/null || echo "")
  rm -f "$output_file"

  # Check for empty output
  if [[ -z "$output" ]]; then
    error "Claude returned empty output"
    error "This usually means Claude CLI failed to start or authenticate"
    echo ""
    echo "Try running manually: claude -p 'hello'"
    exit 1
  fi

  if [[ $exit_code -ne 0 ]]; then
    error "Claude failed to generate tasks (exit code: $exit_code)"
    echo "$output" | head -50
    exit 1
  fi

  # Extract JSON array from output
  # The output might have explanation text before/after the JSON
  local tasks_json
  local tmp_file
  tmp_file=$(mktemp)
  echo "$output" > "$tmp_file"

  # Try to extract JSON array - find the first [ and last ]
  tasks_json=$(awk '/^\[/{found=1} found{print} /^\]/{if(found) exit}' "$tmp_file")

  # If that didn't work, try a more aggressive extraction
  if [[ -z "$tasks_json" ]] || ! echo "$tasks_json" | jq . &>/dev/null; then
    # Extract everything between first [ and last ]
    tasks_json=$(sed -n '/\[/,/\]/p' "$tmp_file")
  fi

  # Clean up
  rm -f "$tmp_file"

  # Validate JSON
  if ! echo "$tasks_json" | jq . &>/dev/null; then
    error "Failed to parse tasks JSON from Claude output"
    error "Tip: Claude may have included extra text. Check the output below."
    echo "---"
    echo "$output" | head -100
    echo "---"
    exit 1
  fi

  # Save tasks
  echo "$tasks_json" | jq '.' > "$session_dir/tasks.json"

  local task_count
  task_count=$(jq 'length' "$session_dir/tasks.json")
  success "Generated $task_count tasks"

  # Initialize state
  cat > "$session_dir/state.json" <<EOF
{
  "status": "READY",
  "summary": "Session initialized with $task_count tasks",
  "iteration": 0,
  "question": null,
  "error": null
}
EOF

  # Initialize empty history
  echo "[]" > "$session_dir/history.json"
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

  log "Running planning phase..."
  if [[ "$refresh" == "true" ]]; then
    info "Refresh mode: preserving completed tasks"
  fi

  # Run planning with Claude locally (analyzes codebase against PRD)
  run_planning "$session_dir" "$refresh"

  # Show results
  if [[ -f "$session_dir/tasks.json" ]]; then
    local task_count
    task_count=$(jq 'length' "$session_dir/tasks.json")
    local complete_count
    complete_count=$(jq '[.[] | select(.passes == true)] | length' "$session_dir/tasks.json")
    success "Plan complete: $task_count tasks ($complete_count completed)"
  fi

  # Show summary if generated
  if [[ -f "$session_dir/plan_summary.md" ]]; then
    echo ""
    log "Plan Summary:"
    cat "$session_dir/plan_summary.md"
  fi

  echo ""
  echo "Next steps:"
  echo "  rwloop tasks        # Review/edit tasks"
  echo "  rwloop run          # Start the loop"
}

run_planning() {
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

  # Build the prompt
  local prompt
  prompt=$(cat "$template_path")

  if [[ "$refresh" == "true" ]]; then
    prompt="$prompt

---

NOTE: This is a --refresh operation. Read existing tasks.json and preserve completed tasks (passes: true). Re-evaluate and update incomplete tasks based on current codebase state."
  fi

  log "Running Claude for planning..."

  # Run Claude with planning prompt
  local output_file
  output_file=$(mktemp)

  # Run claude and capture exit code properly
  set +e  # Temporarily disable exit on error
  claude -p "$prompt" \
    --append-system-prompt "$(cat "$context_path")" \
    --dangerously-skip-permissions \
    --max-turns 50 \
    --output-format text > "$output_file" 2>&1 &
  local claude_pid=$!

  spinner $claude_pid "Analyzing codebase and generating plan..."

  wait $claude_pid
  local exit_code=$?
  set -e  # Re-enable exit on error

  local output
  output=$(cat "$output_file" 2>/dev/null || echo "")
  rm -f "$output_file"

  # Check for empty output
  if [[ -z "$output" ]]; then
    error "Claude returned empty output"
    error "This usually means Claude CLI failed to start or authenticate"
    echo ""
    echo "Try running manually: claude -p 'hello'"
    exit 1
  fi

  if [[ $exit_code -ne 0 ]]; then
    error "Claude planning failed (exit code: $exit_code)"
    echo "$output" | head -50
    exit 1
  fi

  # Verify tasks.json was created/updated
  if [[ ! -f "$session_dir/tasks.json" ]]; then
    error "Planning did not generate tasks.json"
    echo ""
    echo "Claude output (first 50 lines):"
    echo "$output" | head -50
    exit 1
  fi

  # Validate JSON
  if ! jq . "$session_dir/tasks.json" &>/dev/null; then
    error "Invalid tasks.json generated"
    echo ""
    echo "Contents of tasks.json:"
    cat "$session_dir/tasks.json" | head -20
    exit 1
  fi

  success "Planning complete"
}

cmd_tasks() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)
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
