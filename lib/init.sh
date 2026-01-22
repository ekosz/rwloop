#!/usr/bin/env bash
#
# init.sh - Initialize session from PRD
#

# Sprite paths (must match run.sh)
SPRITE_SESSION_DIR="/var/local/rwloop/session"
SPRITE_REPO_DIR="/var/local/rwloop/repo"

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

  success "Session initialized"

  # Now create and setup the Sprite
  echo ""
  log "Creating Sprite VM..."

  # Check if sprite CLI exists
  if ! command -v sprite &>/dev/null; then
    error "'sprite' CLI not found in PATH"
    echo ""
    echo "The sprite CLI is required."
    echo "See: https://github.com/anthropics/sprite"
    exit 1
  fi

  # Create sprite
  local sprite_name="rwloop-$(get_project_id)"

  # Check if sprite already exists (from previous failed init)
  if sprite list 2>/dev/null | grep -q "$sprite_name"; then
    warn "Found existing Sprite from previous attempt: $sprite_name"
    log "Destroying old Sprite..."
    sprite destroy -s "$sprite_name" --force 2>/dev/null || true
    sleep 2
  fi

  set +e
  local sprite_output
  sprite_output=$(sprite create "$sprite_name" 2>&1)
  local sprite_exit_code=$?
  set -e

  if [[ $sprite_exit_code -ne 0 ]]; then
    error "Failed to create Sprite"
    if [[ -n "$sprite_output" ]]; then
      echo "$sprite_output"
    fi
    echo ""
    echo "Troubleshooting:"
    echo "  - Check sprite version: sprite --version"
    echo "  - Check auth status: sprite auth status"
    echo "  - List existing sprites: sprite list"
    exit 1
  fi

  echo "$sprite_name" > "$session_dir/sprite_id"
  success "Sprite created: $sprite_name"

  # Setup the Sprite (clone repo, install deps, etc.)
  setup_sprite_for_init "$session_dir"

  success "Initialization complete!"
  echo ""
  echo "Next step:"
  echo "  rwloop plan    # Interactive planning session with Claude (runs in Sprite)"
}

# Setup sprite during init (clone repo, credentials, run setup)
setup_sprite_for_init() {
  local session_dir="$1"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  log "Setting up Sprite environment..."

  # Create directories on Sprite
  sprite exec -s "$sprite_id" -- mkdir -p "$SPRITE_SESSION_DIR" "$SPRITE_REPO_DIR" || {
    error "Failed to create directories on Sprite"
    exit 1
  }

  # Setup Claude credentials
  setup_claude_credentials "$sprite_id" || {
    error "Failed to setup Claude credentials"
    exit 1
  }

  # Get GitHub token
  local token
  token=$(get_github_token) || {
    warn "No GitHub token found. Private repos won't be accessible."
    warn "Set GITHUB_TOKEN or run 'gh auth login'"
  }

  # Clone repository
  local clone_url
  clone_url=$(get_clone_url "$token")
  local branch
  branch=$(jq -r '.branch' "$session_dir/session.json")

  log "Cloning repository..."
  sprite exec -s "$sprite_id" -- git clone --branch "$branch" "$clone_url" "$SPRITE_REPO_DIR" 2>&1 || {
    error "Failed to clone repository"
    exit 1
  }
  success "Repository cloned"

  # Run setup via Claude if .rwloop/setup.md exists
  log "Checking for setup instructions..."
  if sprite exec -s "$sprite_id" -- test -f "$SPRITE_REPO_DIR/.rwloop/setup.md" 2>/dev/null; then
    log "Running Claude to setup environment..."
    run_setup_claude "$sprite_id"
  else
    info "No .rwloop/setup.md found, skipping environment setup"
  fi

  # Copy PRD to Sprite session directory
  log "Copying PRD to Sprite..."
  copy_to_sprite "$sprite_id" "$session_dir/prd.md" "$SPRITE_SESSION_DIR/prd.md" || {
    error "Failed to copy PRD to Sprite"
    exit 1
  }

  # Copy templates to Sprite
  sprite exec -s "$sprite_id" -- mkdir -p /var/local/rwloop/templates
  for file in "$RWLOOP_DIR/templates"/*.md; do
    if [[ -f "$file" ]]; then
      copy_to_sprite "$sprite_id" "$file" "/var/local/rwloop/templates/$(basename "$file")" || {
        warn "Failed to copy template: $(basename "$file")"
      }
    fi
  done

  success "Sprite setup complete"
}

# Get local Claude credentials and copy to sprite
setup_claude_credentials() {
  local sprite_id="$1"
  local credentials=""

  log "Setting up Claude credentials..."

  # Try macOS Keychain first
  if [[ "$(uname)" == "Darwin" ]]; then
    credentials=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo "")
  fi

  # Fall back to file-based credentials
  if [[ -z "$credentials" ]]; then
    local cred_paths=(
      "$HOME/.claude/.credentials.json"
      "$HOME/.config/claude/.credentials.json"
    )
    for cred_path in "${cred_paths[@]}"; do
      if [[ -f "$cred_path" ]]; then
        credentials=$(cat "$cred_path")
        break
      fi
    done
  fi

  if [[ -z "$credentials" ]]; then
    error "Claude credentials not found. Run 'claude login' first."
    return 1
  fi

  # Create .claude directory on sprite and write credentials
  sprite exec -s "$sprite_id" -- mkdir -p /var/local/rwloop/.claude

  # Write credentials via base64 to avoid quoting issues
  local encoded
  encoded=$(echo "$credentials" | base64)
  sprite exec -s "$sprite_id" -- sh -c "echo '$encoded' | base64 -d > /var/local/rwloop/.claude/.credentials.json"

  success "Claude credentials copied to Sprite"
}

# Run Claude to setup the sprite environment based on .rwloop/setup.md
run_setup_claude() {
  local sprite_id="$1"

  local setup_prompt="You are setting up a development environment. Read the setup instructions in .rwloop/setup.md and execute them.

Your goal is to ensure the environment is ready for development and testing. This may include:
- Installing required runtimes/languages
- Installing dependencies
- Setting up databases
- Running migrations
- Any other setup tasks described

Work through each requirement and verify it's complete before moving on. If something fails, try to fix it.

When done, simply say 'Setup complete' - do not update any state files."

  local cmd="cd $SPRITE_REPO_DIR && HOME=/var/local/rwloop claude -p \"$setup_prompt\" --dangerously-skip-permissions --max-turns 50"

  set +e
  sprite exec -s "$sprite_id" -- sh -c "$cmd" 2>&1 | while IFS= read -r line; do
    echo "  $line"
  done
  local exit_code=${PIPESTATUS[0]}
  set -e

  if [[ $exit_code -ne 0 ]]; then
    warn "Setup Claude exited with code $exit_code"
  else
    success "Environment setup complete"
  fi
}

# Copy a file to the sprite
copy_to_sprite() {
  local sprite_id="$1"
  local local_file="$2"
  local remote_path="$3"

  # Read file and encode as base64
  local encoded
  encoded=$(base64 -w 0 < "$local_file" 2>/dev/null || base64 < "$local_file" | tr -d '\n')

  sprite exec -s "$sprite_id" -- sh -c "echo '$encoded' | base64 -d > '$remote_path'" 2>&1
}

# Copy a file from the sprite
copy_from_sprite() {
  local sprite_id="$1"
  local remote_path="$2"
  local local_file="$3"

  sprite exec -s "$sprite_id" -- cat "$remote_path" > "$local_file"
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

  # Check if session exists
  if [[ ! -d "$session_dir" ]]; then
    error "No session found. Run 'rwloop init <prd.md>' first."
    exit 1
  fi

  # Check if sprite exists
  if [[ ! -f "$session_dir/sprite_id" ]]; then
    error "No Sprite found. Run 'rwloop init <prd.md>' first."
    exit 1
  fi

  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  # Verify sprite is running
  if ! sprite list 2>/dev/null | grep -q "$sprite_id"; then
    error "Sprite '$sprite_id' not found. It may have been destroyed."
    echo ""
    echo "Run 'rwloop init <prd.md>' to create a new session."
    exit 1
  fi

  log "Starting interactive planning session..."
  echo ""
  info "This is a conversation with Claude to plan the implementation."
  info "Claude is running inside the Sprite VM (sandboxed)."
  info "Discuss architecture, share your thoughts, ask questions."
  info "When ready, ask Claude to 'generate the tasks'."
  echo ""

  if [[ "$refresh" == "true" ]]; then
    info "Refresh mode: existing completed tasks will be preserved"
    # Sync current tasks.json to sprite if it exists locally
    if [[ -f "$session_dir/tasks.json" ]]; then
      copy_to_sprite "$sprite_id" "$session_dir/tasks.json" "$SPRITE_SESSION_DIR/tasks.json"
    fi
    echo ""
  fi

  # Build system prompt and copy to sprite
  local system_prompt
  system_prompt=$(build_plan_system_prompt "$refresh")

  # Write system prompt to a temp file on sprite
  local encoded_prompt
  encoded_prompt=$(echo "$system_prompt" | base64)
  sprite exec -s "$sprite_id" -- sh -c "echo '$encoded_prompt' | base64 -d > /tmp/plan_system_prompt.txt"

  # Run Claude interactively inside the Sprite
  # Use sprite console for interactive session
  log "Connecting to Sprite for planning session..."
  echo ""

  local claude_cmd="cd $SPRITE_REPO_DIR && HOME=/var/local/rwloop claude --system-prompt \"\$(cat /tmp/plan_system_prompt.txt)\" --dangerously-skip-permissions"

  sprite exec -s "$sprite_id" -it -- sh -c "$claude_cmd"

  echo ""
  log "Planning session ended. Syncing results..."

  # Sync tasks.json back from sprite
  if sprite exec -s "$sprite_id" -- test -f "$SPRITE_SESSION_DIR/tasks.json" 2>/dev/null; then
    copy_from_sprite "$sprite_id" "$SPRITE_SESSION_DIR/tasks.json" "$session_dir/tasks.json"

    local task_count
    task_count=$(jq 'length' "$session_dir/tasks.json" 2>/dev/null || echo 0)
    if [[ $task_count -gt 0 ]]; then
      success "Synced $task_count tasks from Sprite"
      echo ""
      echo "Next steps:"
      echo "  rwloop tasks        # Review/edit tasks"
      echo "  rwloop run          # Start the loop"
    else
      warn "tasks.json is empty. Run 'rwloop plan' again to continue."
    fi
  else
    echo ""
    info "No tasks generated yet. Run 'rwloop plan' again to continue planning."
  fi
}

build_plan_system_prompt() {
  local refresh="$1"
  local template_path="$RWLOOP_DIR/templates/plan.md"
  local context_path="$RWLOOP_DIR/templates/context.md"
  local session_dir
  session_dir=$(get_session_dir)

  # Verify templates exist
  if [[ ! -f "$template_path" ]]; then
    error "Template not found: $template_path"
    exit 1
  fi
  if [[ ! -f "$context_path" ]]; then
    error "Template not found: $context_path"
    exit 1
  fi

  # Build composite system prompt (using Sprite paths)
  local prompt
  prompt="$(cat "$template_path")

---

$(cat "$context_path")

---

# PRD (Product Requirements Document)

The session directory on this VM is: $SPRITE_SESSION_DIR
Write tasks to: $SPRITE_SESSION_DIR/tasks.json

Here is the PRD:

$(cat "$session_dir/prd.md")"

  # Add refresh mode note
  if [[ "$refresh" == "true" ]]; then
    prompt="$prompt

---

# Refresh Mode

This is a --refresh operation.
- Read existing tasks from $SPRITE_SESSION_DIR/tasks.json
- Preserve completed tasks (passes: true)
- Re-evaluate incomplete tasks based on current codebase state
- Add new tasks if needed, remove obsolete ones"
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
