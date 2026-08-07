#!/bin/bash
#
# claude-usage.sh — Show Claude Code 5-hour usage window remaining time & utilization
#
# Displays: "3:42 67%" meaning 3h42m left in window, 67% of capacity used
# Designed for status bars (tmux, Starship, i3bar, etc.) or quick terminal checks.
#
# Requirements: curl, jq, Claude Code (logged in via `claude` CLI)
#
# Usage:
#   ./claude-usage.sh          # prints e.g. "3:42 67%"
#   watch -n 60 ./claude-usage.sh  # refresh every minute
#

set -euo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_FILE="$CACHE_DIR/claude-usage.txt"
LOCK_FILE="$CACHE_DIR/claude-usage.lock"
CACHE_TTL=180   # seconds to use cached result (3 min)
LOCK_TTL=30     # seconds between API attempts

mkdir -p "$CACHE_DIR"

# --- Claude Code presence check ---
# Exit silently when the `claude` CLI isn't installed so status-bar
# consumers can hide the widget instead of showing a fallback.

if ! command -v claude &>/dev/null; then
  exit 0
fi

# --- Dependency check ---

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERR: $cmd not found" >&2
    echo "--:-- --%"
    exit 1
  fi
done

# --- Helpers ---

file_age() {
  local file="$1"
  local now
  now=$(date +%s)
  local mtime
  if [[ "$(uname)" == "Darwin" ]]; then
    mtime=$(stat -f '%m' "$file")
  else
    mtime=$(stat -c '%Y' "$file")
  fi
  echo $((now - mtime))
}

show_cached_or_fallback() {
  if [[ -f "$CACHE_FILE" ]]; then
    cat "$CACHE_FILE"
    exit 0
  fi
  echo "--:-- --%"
  exit 1
}

parse_utc_timestamp() {
  local ts="$1"
  # Strip fractional seconds and timezone offset for parsing
  local datetime
  datetime=$(echo "$ts" | sed 's/\.[0-9]*[+-].*//' | sed 's/\.[0-9]*Z$//')

  if [[ "$(uname)" == "Darwin" ]]; then
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$datetime" "+%s" 2>/dev/null
  else
    TZ=UTC date -d "${datetime}" "+%s" 2>/dev/null
  fi
}

# --- Cache check ---

if [[ -f "$CACHE_FILE" ]]; then
  age=$(file_age "$CACHE_FILE")
  if [[ $age -lt $CACHE_TTL ]]; then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

# --- Rate limit ---

if [[ -f "$LOCK_FILE" ]]; then
  lock_age=$(file_age "$LOCK_FILE")
  if [[ $lock_age -lt $LOCK_TTL ]]; then
    show_cached_or_fallback
  fi
fi
touch "$LOCK_FILE"

# --- Get OAuth token from Claude Code credentials ---

# Access tokens are short-lived (~8h) and only Claude Code itself refreshes
# them, so leaving Claude Code closed overnight guarantees an expired token
# here. Sending one anyway is worse than sending nothing: a status bar on a
# timer spends every poll on a certain 401, and enough consecutive failures
# earn a 429 with a long Retry-After -- so the widget stays dark for a while
# after Claude Code comes back and fixes the credentials. Check the expiry we
# were handed and skip the request we know cannot succeed.
EXPIRY_SKEW=60  # count a token expiring within the next minute as already gone

# Reads a credentials JSON blob on stdin, echoes .claudeAiOauth.accessToken
# only while .claudeAiOauth.expiresAt (epoch milliseconds) is still ahead of
# us. Credentials with no expiresAt are taken at face value: older Claude Code
# versions omit the field, and a 401 beats refusing to work at all.
token_if_valid() {
  jq -r --argjson now "$(( ($(date +%s) + EXPIRY_SKEW) * 1000 ))" \
    '.claudeAiOauth | select((.expiresAt // infinite) > $now) | .accessToken // empty' \
    2>/dev/null
}

get_token() {
  # macOS Keychain
  if command -v security &>/dev/null; then
    local token
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | token_if_valid || true)
    if [[ -n "$token" ]]; then
      echo "$token"
      return
    fi
  fi

  # Linux: check common credential file locations
  local cred_paths=(
    "$HOME/.claude/.credentials.json"
    "$HOME/.claude/credentials.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/claude/credentials.json"
  )
  for path in "${cred_paths[@]}"; do
    if [[ -f "$path" ]]; then
      local token
      token=$(token_if_valid < "$path" || true)
      if [[ -n "$token" ]]; then
        echo "$token"
        return
      fi
    fi
  done
}

TOKEN=$(get_token)

if [[ -z "${TOKEN:-}" ]]; then
  show_cached_or_fallback
fi

# --- Call usage API ---

RESPONSE=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null || true)

if [[ -z "$RESPONSE" ]]; then
  show_cached_or_fallback
fi

# --- Parse response ---

SESSION_RESET=$(echo "$RESPONSE" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
SESSION_UTIL=$(echo "$RESPONSE" | jq -r '.five_hour.utilization // empty' 2>/dev/null)

if [[ -z "$SESSION_RESET" || -z "$SESSION_UTIL" ]]; then
  show_cached_or_fallback
fi

RESET_TS=$(parse_utc_timestamp "$SESSION_RESET")
NOW_TS=$(date +%s)
REMAINING=$((RESET_TS - NOW_TS))

if [[ $REMAINING -gt 0 ]]; then
  HOURS=$((REMAINING / 3600))
  MINS=$(((REMAINING % 3600) / 60))
  printf "%d:%02d %s%%\n" "$HOURS" "$MINS" "${SESSION_UTIL%.*}" | tee "$CACHE_FILE"
else
  echo "0:00 ${SESSION_UTIL%.*}%" | tee "$CACHE_FILE"
fi
