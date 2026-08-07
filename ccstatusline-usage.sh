#!/bin/bash
#
# ccstatusline-usage.sh — Claude Code 5-hour usage widget for ccstatusline
#
# Use as a custom-command widget in ccstatusline (https://github.com/sirmalloc/ccstatusline)
# Outputs: "3:42 67%" meaning 3h42m left in window, 67% of capacity used
#
# Setup:
#   1. Copy to ~/.local/bin/ccstatusline-usage.sh
#   2. chmod +x ~/.local/bin/ccstatusline-usage.sh
#   3. In ccstatusline TUI, add a "custom-command" widget pointing to ~/.local/bin/ccstatusline-usage.sh
#
# Requirements: curl, jq, Claude Code (logged in)
#

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERR: $cmd not found" >&2
    echo "--:-- --%"
    exit 1
  fi
done

CACHE_FILE="$HOME/.cache/ccstatusline-usage.txt"
LOCK_FILE="$HOME/.cache/ccstatusline-usage.lock"

# Use cache if < 180 seconds old
if [[ -f "$CACHE_FILE" ]]; then
  AGE=$(($(date +%s) - $(stat -f '%m' "$CACHE_FILE")))
  [[ $AGE -lt 180 ]] && cat "$CACHE_FILE" && exit 0
fi

# Rate limit: only try API once per 30 seconds
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(($(date +%s) - $(stat -f '%m' "$LOCK_FILE")))
  if [[ $LOCK_AGE -lt 30 ]]; then
    [[ -f "$CACHE_FILE" ]] && cat "$CACHE_FILE" && exit 0
    echo "--:-- --%"  && exit 1
  fi
fi
touch "$LOCK_FILE"

# Take the token only while it's still valid. expiresAt is epoch milliseconds;
# an expired token buys a guaranteed 401, and enough of those in a row earn a
# 429 with a long Retry-After. Credentials with no expiresAt are used as-is.
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | jq -r --argjson now "$(( ($(date +%s) + 60) * 1000 ))" \
      '.claudeAiOauth | select((.expiresAt // infinite) > $now) | .accessToken // empty' 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  [[ -f "$CACHE_FILE" ]] && cat "$CACHE_FILE" && exit 0
  echo "--:-- --%"
  exit 1
fi

RESPONSE=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)

if [[ -z "$RESPONSE" ]]; then
  [[ -f "$CACHE_FILE" ]] && cat "$CACHE_FILE" && exit 0
  echo "--:-- --%"
  exit 1
fi

SESSION_RESET=$(echo "$RESPONSE" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
SESSION_UTIL=$(echo "$RESPONSE" | jq -r '.five_hour.utilization // empty' 2>/dev/null)

if [[ -z "$SESSION_RESET" || -z "$SESSION_UTIL" ]]; then
  [[ -f "$CACHE_FILE" ]] && cat "$CACHE_FILE" && exit 0
  echo "--:-- --%"
  exit 1
fi

# Parse ISO8601 timestamp - extract just the date/time part and treat as UTC
RESET_DATETIME=$(echo "$SESSION_RESET" | sed 's/\.[0-9]*+.*//')
RESET_TS=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$RESET_DATETIME" "+%s" 2>/dev/null)
NOW_TS=$(date +%s)
REMAINING=$((RESET_TS - NOW_TS))

if [[ $REMAINING -gt 0 ]]; then
  HOURS=$((REMAINING / 3600))
  MINS=$(((REMAINING % 3600) / 60))
  printf "%d:%02d %s%%\n" $HOURS $MINS "${SESSION_UTIL%.*}" | tee "$CACHE_FILE"
else
  echo "0:00 ${SESSION_UTIL%.*}%" | tee "$CACHE_FILE"
fi
