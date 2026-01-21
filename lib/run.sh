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

# Copy a file to the sprite using base64 encoding
copy_to_sprite() {
  local sprite_id="$1"
  local local_file="$2"
  local remote_path="$3"

  local content
  content=$(base64 < "$local_file")
  sprite exec -s "$sprite_id" -- sh -c "echo '$content' | base64 -d > '$remote_path'"
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
  for file in "$RWLOOP_HOME/templates"/*.md; do
    if [[ -f "$file" ]]; then
      copy_to_sprite "$sprite_id" "$file" "/var/local/rwloop/templates/$(basename "$file")" || {
        warn "Failed to copy template: $(basename "$file")"
      }
    fi
  done

  success "Sprite setup complete"
}

run_loop() {
  local session_dir="$1"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  local iteration=0
  local start_time
  start_time=$(date +%s)
  local max_seconds=$((MAX_DURATION_HOURS * 3600))

  log "Starting iteration loop..."
  echo ""

  while true; do
    iteration=$((iteration + 1))

    # Check iteration limit
    if [[ $iteration -gt $MAX_ITERATIONS ]]; then
      warn "Max iterations ($MAX_ITERATIONS) reached"
      notify "rwloop" "Max iterations reached" "critical"
      handle_pause "$session_dir" "max_iterations"
      return
    fi

    # Check duration limit
    local elapsed=$(($(date +%s) - start_time))
    if [[ $elapsed -gt $max_seconds ]]; then
      warn "Max duration (${MAX_DURATION_HOURS}h) exceeded"
      notify "rwloop" "Max duration exceeded" "critical"
      handle_pause "$session_dir" "max_duration"
      return
    fi

    log "=== Iteration $iteration ==="

    # Run one iteration
    run_iteration "$session_dir" "$iteration"

    # Sync state from Sprite
    sync_state_from_sprite "$session_dir"

    # Read state
    local status
    status=$(json_get "$session_dir/state.json" '.status')
    local summary
    summary=$(json_get "$session_dir/state.json" '.summary')

    info "Status: $status"
    info "Summary: $summary"

    # Handle status
    case "$status" in
      DONE)
        if all_tasks_complete "$session_dir"; then
          success "All tasks complete!"
          notify "rwloop" "All tasks complete! Run 'rwloop done' to create PR." "normal"
          handle_complete "$session_dir"
          return
        else
          warn "Agent said DONE but tasks incomplete, continuing..."
        fi
        ;;
      NEEDS_INPUT)
        local question
        question=$(json_get "$session_dir/state.json" '.question')
        warn "Agent needs input: $question"
        notify "rwloop" "Input needed: $question" "critical"
        handle_pause "$session_dir" "needs_input"
        return
        ;;
      BLOCKED)
        local error_msg
        error_msg=$(json_get "$session_dir/state.json" '.error')
        error "Agent blocked: $error_msg"
        notify "rwloop" "Agent blocked: $error_msg" "critical"
        handle_pause "$session_dir" "blocked"
        return
        ;;
      CONTINUE)
        # Check for stuck
        if is_stuck "$session_dir"; then
          warn "No progress detected in $STUCK_THRESHOLD iterations"
          notify "rwloop" "Agent appears stuck" "critical"
          handle_pause "$session_dir" "stuck"
          return
        fi
        ;;
      *)
        warn "Unknown status: $status"
        ;;
    esac

    # Brief pause between iterations
    sleep 2
  done
}

run_iteration() {
  local session_dir="$1"
  local iteration="$2"
  local sprite_id
  sprite_id=$(cat "$session_dir/sprite_id")

  # Build the iteration prompt - write to temp files to avoid quoting issues
  local prompt_file="/var/local/rwloop/session/iterate_prompt.md"
  local context_file="/var/local/rwloop/session/context_prompt.md"

  # Copy prompts to sprite
  copy_to_sprite "$sprite_id" "$RWLOOP_HOME/templates/iterate.md" "$prompt_file" || {
    error "Failed to copy iterate prompt to sprite"
    return 1
  }
  copy_to_sprite "$sprite_id" "$RWLOOP_HOME/templates/context.md" "$context_file" || {
    error "Failed to copy context prompt to sprite"
    return 1
  }

  # Run Claude on Sprite
  log "Running Claude on sprite..."
  local cmd="cd $SPRITE_REPO_DIR && claude -p \"\$(cat $prompt_file)\" --append-system-prompt \"\$(cat $context_file)\" --dangerously-skip-permissions --max-turns 200 --output-format stream-json"

  set +e
  sprite exec -s "$sprite_id" -- sh -c "$cmd" 2>&1 | while IFS= read -r line; do
    # Stream output - show assistant text
    if [[ "$line" == *'"type":"assistant"'* ]] || [[ "$line" == *'"type":"text"'* ]]; then
      echo "$line" | jq -r '.message.content[]?.text // .content // empty' 2>/dev/null || true
    elif [[ "$line" == *'"type":"result"'* ]]; then
      info "Claude finished"
    elif [[ "$line" == *'Error'* ]] || [[ "$line" == *'error'* ]]; then
      warn "$line"
    fi
  done
  local claude_exit=${PIPESTATUS[0]}
  set -e

  if [[ $claude_exit -ne 0 ]]; then
    warn "Claude exited with code $claude_exit"
  fi

  # Update iteration count in session
  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq --argjson i "$iteration" '.iteration = $i')
  write_session_config "$config"
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

is_stuck() {
  local session_dir="$1"
  local history_file="$session_dir/history.json"

  if [[ ! -f "$history_file" ]]; then
    return 1
  fi

  local history_length
  history_length=$(jq 'length' "$history_file")

  if [[ $history_length -lt $STUCK_THRESHOLD ]]; then
    return 1
  fi

  # Check if tasks_completed changed in last N iterations
  local recent_completions
  recent_completions=$(jq -r "[.[-$STUCK_THRESHOLD:][].tasks_completed] | unique | length" "$history_file")

  [[ "$recent_completions" -eq 1 ]]
}

handle_pause() {
  local session_dir="$1"
  local reason="$2"

  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq --arg r "$reason" '.status = "paused" | .pause_reason = $r | .paused_at = now')
  write_session_config "$config"

  echo ""
  warn "Session paused: $reason"
  echo ""
  echo "To continue:"
  echo "  rwloop resume       # Resume the loop"
  echo "  rwloop respond      # Provide input (if NEEDS_INPUT)"
  echo "  rwloop status       # Check current status"
  echo "  rwloop stop         # Cancel and cleanup"
}

handle_complete() {
  local session_dir="$1"

  local config
  config=$(read_session_config)
  config=$(echo "$config" | jq '.status = "complete" | .completed_at = now')
  write_session_config "$config"

  echo ""
  success "Session complete!"
  echo ""
  echo "Next steps:"
  echo "  rwloop done         # Create PR and cleanup"
  echo "  rwloop status       # Review final status"
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
    echo ""
    echo "Sprite ID:   $(cat "$session_dir/sprite_id")"
  fi

  echo ""
}

cmd_resume() {
  require_session

  local session_dir
  session_dir=$(get_session_dir)

  local config
  config=$(read_session_config)
  local status
  status=$(echo "$config" | jq -r '.status')

  if [[ "$status" != "paused" && "$status" != "initialized" ]]; then
    error "Session is not paused. Current status: $status"
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
