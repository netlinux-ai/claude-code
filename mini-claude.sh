#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
API_URL="https://api.anthropic.com/v1/messages"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
MAX_TOKENS=4096
CONVERSATION='[]'
SKIP_PERMISSIONS=false

COMPACT_THRESHOLD=320000  # ~80k tokens at chars/4
COMPACT_KEEP_LAST=10      # keep last N messages verbatim after compaction

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
    repair_conversation
    local turns
    turns=$(printf '%s' "$CONVERSATION" | jq 'length')
    local compacted_file="${file%.json}.compacted.txt"
    local compacted_note=""
    [[ -f "$compacted_file" ]] && compacted_note=" [compacted]"
    printf 'Resumed session: %s (%s messages%s)\n' "$(basename "$file")" "$turns" "$compacted_note" >&2
  else
    printf 'Session file not found: %s\n' "$file" >&2
  fi
}

# --- Repair orphaned tool_use/tool_result pairs ---
repair_conversation() {
  local orig_len
  orig_len=$(printf '%s' "$CONVERSATION" | jq 'length')

  local repaired
  repaired=$(printf '%s' "$CONVERSATION" | jq '
    . as $arr | length as $len |
    reduce range($len) as $i (
      {out: [], skip: false};
      if .skip then .skip = false
      elif $arr[$i].role == "assistant" and
           ([$arr[$i].content[] | objects | select(.type == "tool_use")] | length) > 0 then
        ([$arr[$i].content[] | objects | select(.type == "tool_use") | .id]) as $needed |
        if ($i + 1) < $len then
          ([$arr[$i + 1].content[]? | objects | select(.type == "tool_result") | .tool_use_id]) as $have |
          if ($needed | all(. as $id | $have | index($id))) then
            .out += [$arr[$i]]
          else
            .skip = true
          end
        else .
        end
      else
        .out += [$arr[$i]]
      end
    ) | .out
  ')

  # Also merge consecutive same-role messages (API requires alternating roles)
  repaired=$(printf '%s' "$repaired" | jq '
    reduce .[] as $msg (
      [];
      if length > 0 and .[-1].role == $msg.role then
        .[-1].content += $msg.content
      else
        . + [$msg]
      end
    )
  ')

  local new_len
  new_len=$(printf '%s' "$repaired" | jq 'length')

  if [[ "$new_len" -lt "$orig_len" ]]; then
    CONVERSATION="$repaired"
    save_session
    printf 'Repaired session: removed %s orphaned messages.\n' "$(( orig_len - new_len ))" >&2
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

# --- Token estimation ---
estimate_tokens() {
  local chars
  chars=$(printf '%s' "$CONVERSATION" | wc -c)
  echo $(( chars / 4 ))
}

# --- Compaction ---
compact_conversation() {
  local token_est
  token_est=$(estimate_tokens)
  local msg_count
  msg_count=$(printf '%s' "$CONVERSATION" | jq 'length')

  if [[ "$msg_count" -le "$COMPACT_KEEP_LAST" ]]; then
    printf 'Conversation too short to compact (%s messages).\n' "$msg_count" >&2
    return
  fi

  printf '\033[33mCompacting conversation (~%sk tokens, %s messages)...\033[0m\n' \
    "$(( token_est / 1000 ))" "$msg_count" >&2

  # Find a clean split point — never split inside a tool_use/tool_result exchange.
  # Start near (length - COMPACT_KEEP_LAST) and scan forward to find a user message
  # with plain text (not tool_results), which is a safe boundary.
  local split_idx
  split_idx=$(printf '%s' "$CONVERSATION" | jq --argjson n "$COMPACT_KEEP_LAST" '
    . as $arr | length as $len |
    ([$len - $n, 2] | max) as $start |
    first(
      range($start; $len) |
      select(
        $arr[.].role == "user" and
        ([$arr[.].content[]? | objects | select(.type == "tool_result")] | length) == 0
      )
    ) // $start
  ')

  local older recent
  older=$(printf '%s' "$CONVERSATION" | jq --argjson i "$split_idx" '.[:$i]')
  recent=$(printf '%s' "$CONVERSATION" | jq --argjson i "$split_idx" '.[$i:]')

  # Build a summarization request with the older messages
  local summary_payload
  summary_payload=$(jq -n \
    --argjson older "$older" \
    --arg model "$MODEL" \
    '{
      model: $model,
      max_tokens: 4096,
      messages: [
        {
          role: "user",
          content: ([{
            type: "text",
            text: "Below is a conversation between a user and an AI assistant. Produce a concise summary that captures: (1) what tasks were worked on, (2) key decisions and outcomes, (3) any important file paths, commands, or code discussed, (4) current state of any ongoing work. Be factual and specific — this summary will replace the conversation history.\n\nConversation:\n"
          }] + [
            $older[] |
            {type: "text", text: ((.role) + ": " + (
              if .content | type == "array" then
                [.content[] | select(.type == "text") | .text] | join("\n")
              else
                .content | tostring
              end
            ) + "\n")}
          ] + [{
            type: "text",
            text: "\n---\nProduce the summary now. Be concise but preserve all important details."
          }])
        }
      ]
    }')

  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f '$tmpfile'" RETURN

  local -a curl_args=(
    -s -o "$tmpfile" -w "%{http_code}" "$API_URL"
    -H "$AUTH_HEADER"
    -H "anthropic-version: 2023-06-01"
    -H "content-type: application/json"
  )
  [[ -n "${OAUTH_BETA:-}" ]] && curl_args+=(-H "anthropic-beta: $OAUTH_BETA")

  local http_code
  http_code=$(printf '%s' "$summary_payload" | curl "${curl_args[@]}" -d @-)

  if [[ "$http_code" -ne 200 ]]; then
    printf 'Compaction failed (HTTP %s):\n' "$http_code" >&2
    cat "$tmpfile" >&2
    printf '\n' >&2
    return 1
  fi

  local summary
  summary=$(jq -r '.content[] | select(.type=="text") | .text' "$tmpfile")

  if [[ -z "$summary" ]]; then
    printf 'Compaction failed: empty summary returned.\n' >&2
    return 1
  fi

  # Rebuild conversation: synthetic summary pair + recent messages
  local summary_user summary_assistant
  summary_user=$(jq -n --arg s "[This conversation was compacted. Summary of prior context follows.]" \
    '[{"type":"text","text":$s}]')
  summary_assistant=$(jq -n --arg s "$summary" \
    '[{"type":"text","text":$s}]')

  CONVERSATION=$(jq -n \
    --argjson su "$summary_user" \
    --argjson sa "$summary_assistant" \
    --argjson recent "$recent" \
    '[{"role":"user","content":$su},{"role":"assistant","content":$sa}] + $recent')

  # Safety net: repair any orphaned tool_use in the kept recent messages
  repair_conversation
  save_session

  # Save summary alongside session for reference
  if [[ -n "$SESSION_FILE" ]]; then
    local summary_file="${SESSION_FILE%.json}.compacted.txt"
    printf 'Compacted at %s (~%sk tokens → ~%sk tokens)\n\n%s\n' \
      "$(date)" "$(( token_est / 1000 ))" "$(( $(estimate_tokens) / 1000 ))" \
      "$summary" >> "$summary_file"
  fi

  local new_token_est
  new_token_est=$(estimate_tokens)
  local new_msg_count
  new_msg_count=$(printf '%s' "$CONVERSATION" | jq 'length')
  printf '\033[32mCompacted: %s messages → %s (~%sk tokens → ~%sk tokens)\033[0m\n' \
    "$msg_count" "$new_msg_count" "$(( token_est / 1000 ))" "$(( new_token_est / 1000 ))" >&2
}

# --- Auto-compact check ---
check_auto_compact() {
  local chars
  chars=$(printf '%s' "$CONVERSATION" | wc -c)
  if [[ "$chars" -gt "$COMPACT_THRESHOLD" ]]; then
    compact_conversation
  fi
}

# --- Main loop ---
printf 'mini-claude — minimal agentic shell (model: %s)\n' "$MODEL"
if [[ "$SKIP_PERMISSIONS" == true ]]; then
  printf '\033[33m⚠  --dangerously-skip-permissions active: all tool calls run without confirmation\033[0m\n'
fi
printf 'Commands: /clear  /compact  /sessions  /quit\n'
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
    /compact)
      compact_conversation
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

    # Check if content actually has tool_use blocks
    has_tool_use=$(printf '%s' "$content" | jq '[.[] | select(.type=="tool_use")] | length')

    # If stop_reason isn't "tool_use" but content has tool_use blocks,
    # strip them — they're truncated/invalid (e.g. from max_tokens cutoff)
    if [[ "$stop_reason" != "tool_use" ]] && [[ "$has_tool_use" -gt 0 ]]; then
      printf '\033[33m(stripped %s orphaned tool_use blocks from truncated response)\033[0m\n' "$has_tool_use" >&2
      content=$(printf '%s' "$content" | jq -c '[.[] | select(.type != "tool_use")]')
      has_tool_use=0
    fi

    # Print any text blocks
    printf '%s' "$content" | jq -r '.[] | select(.type=="text") | .text'

    # Add assistant response to conversation
    add_message "assistant" "$content"

    # If no tool use, show token count and break back to user input
    if [[ "$has_tool_use" -eq 0 ]]; then
      tok_est=$(estimate_tokens)
      printf '\033[2m[~%sk tokens]\033[0m\n' "$(( tok_est / 1000 ))" >&2
      check_auto_compact
      break
    fi

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