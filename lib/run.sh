#!/usr/bin/env bash
#
# run.sh - Run the Ralph Wiggum loop on a Sprite
#

# Configuration
MAX_ITERATIONS="${RWLOOP_MAX_ITERATIONS:-50}"
MAX_DURATION_HOURS="${RWLOOP_MAX_DURATION:-4}"
STUCK_THRESHOLD="${RWLOOP_STUCK_THRESHOLD:-3}"
SPRITE_SESSION_DIR="/var/local/rwloop/session"
SPRITE_REPO_DIR="/var/local/rwloop/repo"

cmd_run() {
  require_session
  check_dependencies

  local branch=""
  local token=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch="$2"
        shift 2
        ;;
      --token)
        token="$2"
        shift 2
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  local session_dir
  session_dir=$(get_session_dir)

  # Get GitHub token
  if [[ -z "$token" ]]; then
    token=$(get_github_token) || {
      warn "No GitHub token found. Private repos won't be accessible."
      warn "Set GITHUB_TOKEN or run 'gh auth login'"
    }
  fi

  # Get branch name
  if [[ -z "$branch" ]]; then
    branch=$(get_current_branch)
  fi

  # Update session config
  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq --arg b "$branch" '.branch = $b | .status = "running" | .started_at = now | .iteration = 0')
  write_session_config "$config"

  log "Starting Ralph Wiggum loop"
  info "Branch: $branch"
  info "Max iterations: $MAX_ITERATIONS"
  info "Max duration: ${MAX_DURATION_HOURS}h"

  # Check if sprite CLI exists
  if ! command -v sprite &>/dev/null; then
    error "'sprite' CLI not found in PATH"
    echo ""
    echo "The sprite CLI is required to run VMs."
    echo "See: https://github.com/anthropics/sprite"
    exit 1
  fi

  # Check for existing sprite or create new one
  local sprite_name="rwloop-$(get_project_id)"
  local sprite_id
  local sprite_output

  # Check if sprite already exists
  if sprite list 2>/dev/null | grep -q "$sprite_name"; then
    log "Found existing Sprite: $sprite_name"
    if confirm "Reuse existing sprite?" "y"; then
      sprite_id="$sprite_name"
      success "Using existing Sprite: $sprite_id"
    else
      log "Destroying existing Sprite..."
      sprite destroy -s "$sprite_name" --force 2>/dev/null || true
      sleep 2  # Give it a moment to clean up

      log "Creating new Sprite VM..."
      set +e
      sprite_output=$(sprite create "$sprite_name" 2>&1)
      local sprite_exit_code=$?
      set -e

      if [[ $sprite_exit_code -ne 0 ]]; then
        error "Failed to create Sprite"
        echo "$sprite_output"
        exit 1
      fi
      sprite_id="$sprite_name"
      success "Sprite created: $sprite_id"
    fi
  else
    log "Creating Sprite VM..."
    set +e
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
    sprite_id="$sprite_name"
    success "Sprite created: $sprite_id"
  fi

  # Save sprite ID
  echo "$sprite_id" > "$session_dir/sprite_id"
  success "Sprite created: $sprite_id"

  # Setup Sprite
  setup_sprite "$session_dir" "$token"

  # Run the loop
  run_loop "$session_dir"
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

  # Set HOME so Claude can find credentials
  # Also set XDG_CONFIG_HOME as fallback
  success "Claude credentials copied to sprite"
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
    # Show output
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

# Copy a file to the sprite (with retry)
copy_to_sprite() {
  local sprite_id="$1"
  local local_file="$2"
  local remote_path="$3"
  local max_retries=3
  local retry=0

  # Read file and encode as base64 (single line, shell-safe)
  local encoded
  encoded=$(base64 -w 0 < "$local_file" 2>/dev/null || base64 < "$local_file" | tr -d '\n')

  while [[ $retry -lt $max_retries ]]; do
    if sprite exec -s "$sprite_id" -- sh -c "echo '$encoded' | base64 -d > '$remote_path'" 2>&1; then
      return 0
    fi

    retry=$((retry + 1))
    if [[ $retry -lt $max_retries ]]; then
      warn "copy_to_sprite attempt $retry failed, retrying..."
      sleep 2
    fi
  done

  error "copy_to_sprite failed after $max_retries attempts for $local_file"
  return 1
}

# Copy a file from the sprite
copy_from_sprite() {
  local sprite_id="$1"
  local remote_path="$2"
  local local_file="$3"

  sprite exec -s "$sprite_id" -- cat "$remote_path" > "$local_file"
}

setup_sprite() {
  local session_dir="$1"
  local token="$2"
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

  # Clone repository
  local clone_url
  clone_url=$(get_clone_url "$token")
  local branch
  branch=$(json_get "$session_dir/session.json" '.branch')

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
    info "No .rwloop/setup.md found, skipping setup"
  fi

  # Copy session files to Sprite
  log "Copying session files..."
  for file in prd.md tasks.json state.json history.json; do
    if [[ -f "$session_dir/$file" ]]; then
      copy_to_sprite "$sprite_id" "$session_dir/$file" "$SPRITE_SESSION_DIR/$file" || {
        error "Failed to copy $file to Sprite"
        exit 1
      }
    fi
  done

  # Copy templates
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

# Check if loop is running in tmux on sprite
is_loop_running() {
  local sprite_id="$1"
  sprite exec -s "$sprite_id" -- sh -c "tmux has-session -t rwloop" 2>/dev/null
}

# Start the loop in tmux on sprite
start_loop_on_sprite() {
  local session_dir="$1"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  log "Starting loop on sprite..."

  # Copy loop runner script
  copy_to_sprite "$sprite_id" "$RWLOOP_DIR/templates/loop-runner.sh" "/var/local/rwloop/loop-runner.sh" || {
    error "Failed to copy loop runner"
    return 1
  }

  # Copy templates for the loop
  copy_to_sprite "$sprite_id" "$RWLOOP_DIR/templates/iterate.md" "$SPRITE_SESSION_DIR/iterate_prompt.md" || {
    error "Failed to copy iterate prompt"
    return 1
  }
  copy_to_sprite "$sprite_id" "$RWLOOP_DIR/templates/context.md" "$SPRITE_SESSION_DIR/context_prompt.md" || {
    error "Failed to copy context prompt"
    return 1
  }

  # Make runner executable and start in tmux
  sprite exec -s "$sprite_id" -- sh -c "chmod +x /var/local/rwloop/loop-runner.sh"

  sprite exec -s "$sprite_id" -- sh -c "tmux new-session -d -s rwloop 'cd /var/local/rwloop/repo && /var/local/rwloop/loop-runner.sh; echo Loop ended. Press enter to close; read'" || {
    error "Failed to start tmux session"
    return 1
  }

  success "Loop started in background"
}

# Attach to the running loop
attach_to_loop() {
  local sprite_id="$1"

  echo ""
  log "Attaching to loop (press 'd' to detach, loop continues in background)"
  echo ""

  # Attach to tmux - this will show output and allow 'd' to detach
  sprite console -s "$sprite_id" -- tmux attach-session -t rwloop

  # After detaching, sync state
  echo ""
  log "Detached from loop"

  # Check if loop is still running
  if is_loop_running "$sprite_id"; then
    success "Loop still running in background"
    echo "Run 'rwloop attach' to reconnect"
  else
    info "Loop has stopped"
  fi
}

run_loop() {
  local session_dir="$1"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  # Start loop if not already running
  if ! is_loop_running "$sprite_id"; then
    start_loop_on_sprite "$session_dir" || return 1
  else
    log "Loop already running"
  fi

  # Attach to it
  attach_to_loop "$sprite_id"

  # Sync state after detaching
  sync_state_from_sprite "$session_dir"
}

sync_state_from_sprite() {
  local session_dir="$1"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  # Copy state files back
  for file in tasks.json state.json history.json; do
    copy_from_sprite "$sprite_id" "$SPRITE_SESSION_DIR/$file" "$session_dir/$file" 2>/dev/null || true
  done
}

all_tasks_complete() {
  local session_dir="$1"
  local incomplete
  incomplete=$(count_tasks "$session_dir/tasks.json" "incomplete")
  [[ "$incomplete" -eq 0 ]]
}

cmd_status() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  echo ""
  log "Session Status"
  echo "─────────────────────────────────"

  # Session info
  local config
  config=$(read_session_config)
  echo "Project ID:  $(echo "$config" | jq -r '.project_id')"
  echo "Repository:  $(echo "$config" | jq -r '.repo')"
  echo "Branch:      $(echo "$config" | jq -r '.branch')"
  echo "Status:      $(echo "$config" | jq -r '.status')"
  echo "Iteration:   $(echo "$config" | jq -r '.iteration // 0')"

  # Task summary
  if [[ -f "$session_dir/tasks.json" ]]; then
    local total complete incomplete
    total=$(jq 'length' "$session_dir/tasks.json")
    complete=$(count_tasks "$session_dir/tasks.json" "complete")
    incomplete=$(count_tasks "$session_dir/tasks.json" "incomplete")
    echo ""
    echo "Tasks:       $complete/$total complete ($incomplete remaining)"
  fi

  # Current state
  if [[ -f "$session_dir/state.json" ]]; then
    echo ""
    echo "Last State:"
    echo "  Status:    $(json_get "$session_dir/state.json" '.status')"
    echo "  Summary:   $(json_get "$session_dir/state.json" '.summary')"

    local question
    question=$(json_get "$session_dir/state.json" '.question')
    if [[ -n "$question" && "$question" != "null" ]]; then
      echo "  Question:  $question"
    fi

    local error_msg
    error_msg=$(json_get "$session_dir/state.json" '.error')
    if [[ -n "$error_msg" && "$error_msg" != "null" ]]; then
      echo "  Error:     $error_msg"
    fi
  fi

  # Sprite status
  if [[ -f "$session_dir/sprite_id" ]]; then
    local sprite_id
    sprite_id=$(cat "$session_dir/sprite_id")
    echo ""
    echo "Sprite ID:   $sprite_id"

    # Check if loop is running
    if sprite list 2>/dev/null | grep -q "$sprite_id"; then
      if is_loop_running "$sprite_id"; then
        echo -e "Loop:        ${GREEN}running in background${NC}"
        echo "             Run 'rwloop attach' to reconnect"
      else
        echo "Loop:        not running"
      fi
    else
      echo "Sprite:      not found (destroyed?)"
    fi
  fi

  echo ""
}

cmd_attach() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  if [[ ! -f "$session_dir/sprite_id" ]]; then
    error "No sprite found. Run 'rwloop run' first."
    exit 1
  fi

  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  # Check if sprite exists
  if ! sprite list 2>/dev/null | grep -q "$sprite_id"; then
    error "Sprite no longer exists. Run 'rwloop run' to create a new one."
    exit 1
  fi

  # Check if loop is running
  if ! is_loop_running "$sprite_id"; then
    error "Loop is not running. Use 'rwloop resume' to start it."
    exit 1
  fi

  attach_to_loop "$sprite_id"

  # Sync state after detaching
  sync_state_from_sprite "$session_dir"
}

cmd_resume() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  # Check if sprite exists and loop is running - if so, just attach
  if [[ -f "$session_dir/sprite_id" ]]; then
    local sprite_id
    sprite_id=$(cat "$session_dir/sprite_id")

    if sprite list 2>/dev/null | grep -q "$sprite_id"; then
      if is_loop_running "$sprite_id"; then
        log "Loop already running, attaching..."
        attach_to_loop "$sprite_id"
        sync_state_from_sprite "$session_dir"
        return
      fi
    fi
  fi

  # Otherwise, normal resume logic
  local config
  config=$(read_session_config)
  local status
  status=$(echo "$config" | jq -r '.status')

  if [[ "$status" != "paused" && "$status" != "initialized" && "$status" != "running" ]]; then
    error "Session cannot be resumed. Current status: $status"
    exit 1
  fi

  # Check if sprite still exists, create new one if needed
  if [[ -f "$session_dir/sprite_id" ]]; then
    local sprite_id
    sprite_id=$(cat "$session_dir/sprite_id")
    if ! sprite list 2>/dev/null | grep -q "$sprite_id"; then
      log "Previous Sprite no longer exists, creating new one..."
      rm "$session_dir/sprite_id"

      # Get token
      local token
      token=$(get_github_token) || warn "No GitHub token found"

      # Create and setup new Sprite
      local sprite_name="rwloop-$(get_project_id)"
      sprite_id=$(sprite create "$sprite_name" 2>&1)
      echo "$sprite_id" > "$session_dir/sprite_id"
      setup_sprite "$session_dir" "$token"
    else
      log "Reusing existing Sprite: $sprite_id"
      # Check if repo still exists on sprite
      if ! sprite exec -s "$sprite_id" -- test -d "$SPRITE_REPO_DIR/.git" 2>/dev/null; then
        warn "Repo not found on sprite, re-running setup..."
        local token
        token=$(get_github_token) || warn "No GitHub token found"
        setup_sprite "$session_dir" "$token"
      else
        success "Repo still exists on sprite"
      fi
    fi
  fi

  # Update status and continue
  config=$(echo "$config" | jq '.status = "running"')
  write_session_config "$config"

  log "Resuming session..."
  run_loop "$session_dir"
}

cmd_respond() {
  local response="${1:-}"

  if [[ -z "$response" ]]; then
    error "Usage: rwloop respond \"<message>\""
    exit 1
  fi

  require_session

  local session_dir
  session_dir=$(get_session_dir)

  # Check we're waiting for input
  local status
  status=$(json_get "$session_dir/state.json" '.status')
  if [[ "$status" != "NEEDS_INPUT" ]]; then
    warn "Session is not waiting for input (status: $status)"
  fi

  # Write response file
  echo "$response" > "$session_dir/response.txt"

  # Copy to Sprite if running
  if [[ -f "$session_dir/sprite_id" ]]; then
    local sprite_id
    sprite_id=$(cat "$session_dir/sprite_id")
    copy_to_sprite "$sprite_id" "$session_dir/response.txt" "$SPRITE_SESSION_DIR/response.txt" 2>/dev/null || true
  fi

  success "Response saved"
  echo "Run 'rwloop resume' to continue the loop"
}

cmd_done() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  # Verify all tasks complete
  if ! all_tasks_complete "$session_dir"; then
    local incomplete
    incomplete=$(count_tasks "$session_dir/tasks.json" "incomplete")
    error "$incomplete tasks still incomplete"
    echo "Run 'rwloop status' to see details"
    exit 1
  fi

  local sprite_id=""
  if [[ -f "$session_dir/sprite_id" ]]; then
    sprite_id=$(cat "$session_dir/sprite_id")
  fi

  # Push branch
  log "Pushing branch..."
  if [[ -n "$sprite_id" ]]; then
    local branch
    branch=$(json_get "$session_dir/session.json" '.branch')
    sprite exec -s "$sprite_id" -- sh -c "cd $SPRITE_REPO_DIR && git push -u origin $branch" 2>&1 || {
      error "Failed to push branch"
      exit 1
    }
    success "Branch pushed"
  fi

  # Create PR
  if confirm "Create pull request?" "y"; then
    create_pr "$session_dir"
  fi

  # Cleanup Sprite
  if [[ -n "$sprite_id" ]]; then
    log "Cleaning up Sprite..."
    sprite destroy -s "$sprite_id" --force 2>/dev/null || true
    rm "$session_dir/sprite_id"
    success "Sprite deleted"
  fi

  # Update status
  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq '.status = "done" | .done_at = now')
  write_session_config "$config"

  success "Session complete!"
}

create_pr() {
  local session_dir="$1"
  local sprite_id=""

  if [[ -f "$session_dir/sprite_id" ]]; then
    sprite_id=$(cat "$session_dir/sprite_id")
  fi

  # Generate PR body from tasks
  local pr_title pr_body

  # Get first task description for title
  pr_title=$(jq -r '.[0].description // "Implementation complete"' "$session_dir/tasks.json")
  pr_title="feat: $pr_title"

  # Build body from all tasks
  pr_body="## Summary

$(jq -r '.[] | "- [x] \(.description)"' "$session_dir/tasks.json")

## Original PRD

<details>
<summary>Click to expand</summary>

$(cat "$session_dir/prd.md")

</details>

---
Generated by rwloop"

  # Create PR
  if [[ -n "$sprite_id" ]]; then
    sprite exec -s "$sprite_id" -- sh -c "cd $SPRITE_REPO_DIR && gh pr create --title '$pr_title' --body '$pr_body'" 2>&1 || {
      error "Failed to create PR"
      warn "You can create the PR manually"
      return 1
    }
  else
    # Try locally
    gh pr create --title "$pr_title" --body "$pr_body" || {
      error "Failed to create PR"
      return 1
    }
  fi

  success "PR created!"
}

cmd_stop() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  if ! confirm "This will delete the Sprite and cancel the session. Continue?" "n"; then
    echo "Cancelled"
    exit 0
  fi

  # Delete Sprite
  if [[ -f "$session_dir/sprite_id" ]]; then
    local sprite_id
    sprite_id=$(cat "$session_dir/sprite_id")
    log "Deleting Sprite..."
    sprite destroy -s "$sprite_id" --force 2>/dev/null || true
    rm "$session_dir/sprite_id"
    success "Sprite deleted"
  fi

  # Update status
  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq '.status = "cancelled" | .cancelled_at = now')
  write_session_config "$config"

  success "Session cancelled"
}
