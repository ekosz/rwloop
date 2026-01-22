#!/usr/bin/env bash
#
# utils.sh - Shared utilities for rwloop
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Logging functions
log() {
  echo -e "${CYAN}[rwloop]${NC} $*"
}

info() {
  echo -e "${BLUE}[info]${NC} $*"
}

success() {
  echo -e "${GREEN}[ok]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[warn]${NC} $*" >&2
}

error() {
  echo -e "${RED}[error]${NC} $*" >&2
}

# Desktop notifications
notify() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}"  # low, normal, critical

  if command -v notify-send &>/dev/null; then
    # Linux
    notify-send -u "$urgency" "$title" "$message"
  elif command -v osascript &>/dev/null; then
    # macOS
    osascript -e "display notification \"$message\" with title \"$title\""
  else
    # Fallback: terminal bell
    echo -e "\a"
    log "$title: $message"
  fi
}

# Get project identifier (hash of git remote + current dir + branch)
get_project_id() {
  local remote=""
  local dir_path=""
  local branch=""

  if git rev-parse --is-inside-work-tree &>/dev/null; then
    remote=$(git remote get-url origin 2>/dev/null || echo "")
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  dir_path=$(pwd)

  echo -n "${remote}:${dir_path}:${branch}" | sha256sum | cut -c1-12
}

# Get current session directory
get_session_dir() {
  local project_id
  project_id=$(get_project_id)
  echo "$RWLOOP_HOME/sessions/$project_id"
}

# Ensure session exists
require_session() {
  local session_dir
  session_dir=$(get_session_dir)

  if [[ ! -d "$session_dir" ]]; then
    error "No session found. Run 'rwloop init <prd.md>' first."
    exit 1
  fi
}

# Check if session is active (Sprite running)
is_session_active() {
  local session_dir
  session_dir=$(get_session_dir)

  [[ -f "$session_dir/sprite_id" ]]
}

# Read session config
read_session_config() {
  local session_dir
  session_dir=$(get_session_dir)

  if [[ -f "$session_dir/session.json" ]]; then
    cat "$session_dir/session.json"
  else
    echo "{}"
  fi
}

# Write session config
write_session_config() {
  local session_dir
  session_dir=$(get_session_dir)
  local config="$1"

  echo "$config" > "$session_dir/session.json"
}

# JSON helpers using jq
json_get() {
  local file="$1"
  local path="$2"
  jq -r "$path" "$file" 2>/dev/null || echo ""
}

json_set() {
  local file="$1"
  local path="$2"
  local value="$3"
  local tmp
  tmp=$(mktemp)

  jq "$path = $value" "$file" > "$tmp" && mv "$tmp" "$file"
}

# Count tasks by status
count_tasks() {
  local file="$1"
  local status="$2"  # "complete" or "incomplete"

  if [[ "$status" == "complete" ]]; then
    jq '[.[] | select(.passes == true)] | length' "$file"
  else
    jq '[.[] | select(.passes == false)] | length' "$file"
  fi
}

# Get GitHub token
get_github_token() {
  # Try environment variable first
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "$GITHUB_TOKEN"
    return 0
  fi

  # Try gh CLI
  if command -v gh &>/dev/null; then
    local token
    token=$(gh auth token 2>/dev/null || echo "")
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
  fi

  return 1
}

# Get git remote URL (convert any SSH format to HTTPS with token)
get_clone_url() {
  local token="${1:-}"
  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")

  if [[ -z "$remote" ]]; then
    error "No git remote found"
    return 1
  fi

  # Extract org/repo from various URL formats
  local repo_path=""

  if [[ "$remote" == git@*:* ]]; then
    # SSH format: git@hostname:org/repo.git (handles custom hostnames like github_ek)
    repo_path="${remote#*:}"
  elif [[ "$remote" == ssh://* ]]; then
    # SSH URL format: ssh://git@hostname/org/repo.git
    repo_path="${remote#ssh://*/}"
  elif [[ "$remote" == https://github.com/* ]]; then
    # Already HTTPS github.com
    repo_path="${remote#https://github.com/}"
  elif [[ "$remote" == https://*github.com/* ]]; then
    # HTTPS with token or other prefix
    repo_path="${remote#*github.com/}"
  else
    error "Unrecognized remote format: $remote"
    return 1
  fi

  # Remove .git suffix if present
  repo_path="${repo_path%.git}"

  # Build clean HTTPS URL
  remote="https://github.com/${repo_path}"

  # Add token if provided
  if [[ -n "$token" ]]; then
    remote="https://x-access-token:${token}@github.com/${repo_path}"
  fi

  echo "$remote"
}

# Get current branch name
get_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
}

# Get repo name (org/repo format)
get_repo_name() {
  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")

  # Extract org/repo from various URL formats
  if [[ "$remote" == git@github.com:* ]]; then
    echo "${remote#git@github.com:}" | sed 's/\.git$//'
  elif [[ "$remote" == https://github.com/* ]]; then
    echo "${remote#https://github.com/}" | sed 's/\.git$//'
  else
    echo ""
  fi
}

# Check for required commands
check_dependencies() {
  local missing=()

  for cmd in jq git claude; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

# Spinner for long operations
spinner() {
  local pid=$1
  local message="${2:-Working...}"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % ${#spin} ))
    printf "\r${CYAN}[%s]${NC} %s" "${spin:$i:1}" "$message"
    sleep 0.1
  done
  printf "\r"
}

# Confirm prompt
confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-n}"

  if [[ "$default" == "y" ]]; then
    prompt="$prompt [Y/n] "
  else
    prompt="$prompt [y/N] "
  fi

  read -rp "$prompt" response
  response="${response:-$default}"

  [[ "$response" =~ ^[Yy] ]]
}

# Wait for file to exist (with timeout)
wait_for_file() {
  local file="$1"
  local timeout="${2:-60}"
  local elapsed=0

  while [[ ! -f "$file" ]] && [[ $elapsed -lt $timeout ]]; do
    sleep 1
    ((elapsed++))
  done

  [[ -f "$file" ]]
}

# Format duration (seconds to human readable)
format_duration() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" $hours $minutes $secs
  elif [[ $minutes -gt 0 ]]; then
    printf "%dm %ds" $minutes $secs
  else
    printf "%ds" $secs
  fi
}
