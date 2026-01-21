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

  claude -p "$prompt" --output-format text > "$output_file" 2>&1 &
  local claude_pid=$!

  spinner $claude_pid "Generating tasks with Claude..."

  # Check if Claude succeeded
  wait $claude_pid
  local exit_code=$?

  local output
  output=$(cat "$output_file")
  rm -f "$output_file"

  if [[ $exit_code -ne 0 ]]; then
    error "Claude failed to generate tasks"
    echo "$output"
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
