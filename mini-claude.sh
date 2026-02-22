#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
API_URL="https://api.anthropic.com/v1/messages"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
MAX_TOKENS=4096
CONVERSATION='[]'
SKIP_PERMISSIONS=false

SESSION_DIR="$HOME/.mini-claude/sessions"
mkdir -p "$SESSION_DIR"

# --- Parse flags ---
for arg in "$@"; do
  case "$arg" in
    --dangerously-skip-permissions)
      SKIP_PERMISSIONS=true
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

# --- Check dependencies ---
for cmd in curl jq; do
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd is required but not installed." >&2; exit 1; }
done

# --- Resolve API key: env var > Claude Code OAuth credentials ---
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"

AUTH_HEADER=""

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_HEADER="x-api-key: $ANTHROPIC_API_KEY"
elif [[ -f "$CREDENTIALS_FILE" ]]; then
  oauth_token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE")
  if [[ -z "$oauth_token" ]]; then
    echo "Error: No access token found in $CREDENTIALS_FILE" >&2
    exit 1
  fi

  # Check if token has expired
  expires_at=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDENTIALS_FILE")
  now_ms=$(($(date +%s) * 1000))
  if [[ "$now_ms" -gt "$expires_at" ]]; then
    printf 'Warning: Claude Code OAuth token has expired. Run "claude" to refresh it.\n' >&2
    exit 1
  fi

  sub_type=$(jq -r '.claudeAiOauth.subscriptionType // "unknown"' "$CREDENTIALS_FILE")
  printf 'Using Claude Code OAuth credentials (%s subscription)\n' "$sub_type"
  AUTH_HEADER="Authorization: Bearer $oauth_token"
  OAUTH_BETA="oauth-2025-04-20"
else
  echo "Error: ANTHROPIC_API_KEY is not set and no Claude Code credentials found." >&2
  echo "Either: export ANTHROPIC_API_KEY=sk-ant-... or run 'claude login' first." >&2
  exit 1
fi

# --- Session management ---
SESSION_FILE=""

new_session() {
  SESSION_FILE="$SESSION_DIR/$(date +%Y%m%d-%H%M%S).json"
  CONVERSATION='[]'
  printf '[]' > "$SESSION_FILE"
  printf 'Started new session: %s\n' "$(basename "$SESSION_FILE")" >&2
}

save_session() {
  [[ -n "$SESSION_FILE" ]] && printf '%s' "$CONVERSATION" > "$SESSION_FILE"
}

load_session() {
  local file="$1"
  if [[ -f "$file" ]]; then
    CONVERSATION=$(cat "$file")
    SESSION_FILE="$file"
    local turns
    turns=$(printf '%s' "$CONVERSATION" | jq 'length')
    printf 'Resumed session: %s (%s messages)\n' "$(basename "$file")" "$turns" >&2
  else
    printf 'Session file not found: %s\n' "$file" >&2
  fi
}

list_sessions() {
  local files=("$SESSION_DIR"/*.json)
  if [[ ! -e "${files[0]}" ]]; then
    printf 'No saved sessions.\n'
    return
  fi
  printf '\nSaved sessions:\n'
  local i=1
  for f in "${files[@]}"; do
    local turns
    turns=$(jq 'length' "$f")
    printf '  [%d] %s  (%s messages)\n' "$i" "$(basename "$f")" "$turns"
    (( i++ ))
  done
  printf '\nEnter session number to resume, or press enter to start new: '
  read -r choice < /dev/tty
  if [[ -n "$choice" ]] && [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$(( choice - 1 ))
    load_session "${files[$idx]}"
  else
    new_session
  fi
}

# --- On startup: offer to resume last session ---
last_session=$(ls -t "$SESSION_DIR"/*.json 2>/dev/null | head -1 || true)
if [[ -n "$last_session" ]]; then
  turns=$(jq 'length' "$last_session")
  printf 'Last session: %s (%s messages). Resume? [Y/n] ' "$(basename "$last_session")" "$turns"
  read -r resume < /dev/tty
  if [[ "${resume:-y}" =~ ^[Yy]$ ]]; then
    load_session "$last_session"
  else
    new_session
  fi
else
  new_session
fi

# --- Tool definitions sent to the API ---
TOOLS='[
  {
    "name": "bash",
    "description": "Run a bash command and return stdout/stderr",
    "input_schema": {
      "type": "object",
      "properties": {
        "command": { "type": "string", "description": "The command to run" }
      },
      "required": ["command"]
    }
  },
  {
    "name": "read_file",
    "description": "Read a file and return its contents",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the file" }
      },
      "required": ["path"]
    }
  },
  {
    "name": "write_file",
    "description": "Write content to a file",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the file" },
        "content": { "type": "string", "description": "Content to write" }
      },
      "required": ["path", "content"]
    }
  }
]'

# --- Tool execution ---
execute_tool() {
  local name="$1" input="$2"

  case "$name" in
    bash)
      local cmd
      cmd=$(printf '%s' "$input" | jq -r '.command')
      printf '[tool] bash: %s\n' "$cmd" >&2
      if [[ "$SKIP_PERMISSIONS" == false ]]; then
        read -rp "Allow? [y/N] " confirm < /dev/tty
        [[ "$confirm" == "y" ]] || { echo "Denied by user"; return; }
      fi
      bash -c "$cmd" 2>&1 || true
      ;;
    read_file)
      local path
      path=$(printf '%s' "$input" | jq -r '.path')
      printf '[tool] read: %s\n' "$path" >&2
      cat "$path" 2>&1 || echo "Error: could not read file"
      ;;
    write_file)
      local path content
      path=$(printf '%s' "$input" | jq -r '.path')
      content=$(printf '%s' "$input" | jq -r '.content')
      printf '[tool] write: %s\n' "$path" >&2
      if [[ "$SKIP_PERMISSIONS" == false ]]; then
        read -rp "Allow write? [y/N] " confirm < /dev/tty
        [[ "$confirm" == "y" ]] || { echo "Denied by user"; return; }
      fi
      mkdir -p "$(dirname "$path")"
      printf '%s' "$content" > "$path" && echo "OK" || echo "Error writing file"
      ;;
    *)
      echo "Unknown tool: $name"
      ;;
  esac
}

# --- Send messages to API, return response ---
call_api() {
  local payload
  payload=$(jq -n \
    --argjson messages "$CONVERSATION" \
    --argjson tools "$TOOLS" \
    --arg model "$MODEL" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{model: $model, max_tokens: $max_tokens, tools: $tools, messages: $messages}')

  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f '$tmpfile'" RETURN

  local http_code
  local -a curl_args=(
    -s -o "$tmpfile" -w "%{http_code}" "$API_URL"
    -H "$AUTH_HEADER"
    -H "anthropic-version: 2023-06-01"
    -H "content-type: application/json"
  )
  [[ -n "${OAUTH_BETA:-}" ]] && curl_args+=(-H "anthropic-beta: $OAUTH_BETA")

  http_code=$(printf '%s' "$payload" | curl "${curl_args[@]}" -d @-)

  if [[ "$http_code" -ne 200 ]]; then
    printf 'API error (HTTP %s):\n' "$http_code" >&2
    cat "$tmpfile" >&2
    printf '\n' >&2
    return 1
  fi

  cat "$tmpfile"
}

# --- Append to conversation ---
add_message() {
  local role="$1" content="$2"
  CONVERSATION=$(printf '%s' "$CONVERSATION" | jq \
    --arg role "$role" \
    --argjson content "$content" \
    '. + [{"role": $role, "content": $content}]')
  save_session
}

# --- Main loop ---
printf 'mini-claude — minimal agentic shell (model: %s)\n' "$MODEL"
if [[ "$SKIP_PERMISSIONS" == true ]]; then
  printf '\033[33m⚠  --dangerously-skip-permissions active: all tool calls run without confirmation\033[0m\n'
fi
printf 'Commands: /clear  /sessions  /quit\n'
printf '%.0s─' {1..40}; printf '\n'

while true; do
  printf '\nyou> '
  read -r user_input || { printf '\n'; exit 0; }

  # Built-in slash commands
  case "$user_input" in
    /quit|/exit) exit 0 ;;
    /clear)
      new_session
      printf 'Conversation cleared.\n'
      continue
      ;;
    /sessions)
      list_sessions
      continue
      ;;
    '') continue ;;
  esac

  add_message "user" "$(jq -n --arg t "$user_input" '[{"type":"text","text":$t}]')"

  # Agent loop: keep going until no more tool calls
  while true; do
    printf '\033[2m(thinking...)\033[0m\n' >&2

    if ! response=$(call_api); then
      printf 'Failed. Check the error above.\n' >&2
      break
    fi

    stop_reason=$(printf '%s' "$response" | jq -r '.stop_reason')
    content=$(printf '%s' "$response" | jq -c '.content')

    # Print any text blocks
    printf '%s' "$content" | jq -r '.[] | select(.type=="text") | .text'

    # Add assistant response to conversation
    add_message "assistant" "$content"

    # If no tool use, break back to user input
    [[ "$stop_reason" != "tool_use" ]] && break

    # Process each tool call, collect results
    tool_results='[]'
    while IFS= read -r row; do
      tool_id=$(printf '%s' "$row" | jq -r '.id')
      tool_name=$(printf '%s' "$row" | jq -r '.name')
      tool_input=$(printf '%s' "$row" | jq -c '.input')

      result=$(execute_tool "$tool_name" "$tool_input")

      # Truncate very long results to avoid blowing the context
      if [[ "${#result}" -gt 30000 ]]; then
        result="${result:0:30000}... [truncated]"
      fi

      tool_results=$(printf '%s' "$tool_results" | jq \
        --arg id "$tool_id" \
        --arg result "$result" \
        '. + [{"type":"tool_result","tool_use_id":$id,"content":$result}]')
    done < <(printf '%s' "$content" | jq -c '.[] | select(.type=="tool_use")')

    # Feed tool results back as a user message
    add_message "user" "$tool_results"
  done
done