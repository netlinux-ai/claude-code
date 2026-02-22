#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
API_URL="https://api.anthropic.com/v1/messages"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
MAX_TOKENS=4096
SKIP_PERMISSIONS=false

COMPACT_THRESHOLD=320000  # ~80k tokens at chars/4
COMPACT_KEEP_LAST=10      # keep last N messages verbatim after compaction

SESSIONS_ROOT="$HOME/.mini-claude/sessions"
mkdir -p "$SESSIONS_ROOT"

SESSION_DIR=""  # current session directory (e.g. sessions/20250222-120000/)
MSG_SEQ=0       # next message sequence number

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

# --- Tool definitions (JSON for API, only used in build_payload) ---
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

# =============================================================================
# SESSION STORAGE — files and folders, no JSON blobs
#
# Structure:
#   sessions/20250222-120000/
#     00000-user/
#       text.md
#     00001-assistant/
#       text.md
#       tool_use.json        (optional: [{id, name, input, ...}])
#     00002-user/
#       tool_result.json     (optional: [{tool_use_id, content}])
#     00003-assistant/
#       text.md
#     summary.md             (written during compaction)
# =============================================================================

# --- List message dirs in order ---
msg_dirs() {
  local d="${1:-$SESSION_DIR}"
  find "$d" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-*' | sort
}

msg_count() {
  msg_dirs "$@" | wc -l
}

# --- Create a new session directory ---
new_session() {
  SESSION_DIR="$SESSIONS_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SESSION_DIR"
  MSG_SEQ=0
  printf 'Started new session: %s\n' "$(basename "$SESSION_DIR")" >&2
}

# --- Load an existing session ---
load_session() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    SESSION_DIR="$dir"
    # Find the highest sequence number
    local last
    last=$(msg_dirs | tail -1 || true)
    if [[ -n "$last" ]]; then
      local base
      base=$(basename "$last")
      MSG_SEQ=$(( 10#${base%%-*} + 1 ))
    else
      MSG_SEQ=0
    fi
    repair_session
    local count
    count=$(msg_count)
    local compacted=""
    [[ -f "$SESSION_DIR/summary.md" ]] && compacted=" [compacted]"
    printf 'Resumed session: %s (%s messages%s)\n' "$(basename "$dir")" "$count" "$compacted" >&2
  else
    printf 'Session not found: %s\n' "$dir" >&2
  fi
}

# --- Add a message to the session ---
# Note: we avoid $(add_msg ...) subshells because MSG_SEQ increments would be lost.
# Instead, each function computes the dir inline.

next_msg_dir() {
  # Sets NEXT_DIR and increments MSG_SEQ — call directly, never in $(...)
  NEXT_DIR=$(printf '%s/%05d-%s' "$SESSION_DIR" "$MSG_SEQ" "$1")
  mkdir -p "$NEXT_DIR"
  MSG_SEQ=$(( MSG_SEQ + 1 ))
}

# Write a user text message
add_user_text() {
  local text="$1"
  next_msg_dir "user"
  printf '%s' "$text" > "$NEXT_DIR/text.md"
}

# Write an assistant response (text + optional tool_use)
add_assistant_response() {
  local content_json="$1"
  next_msg_dir "assistant"

  # Extract and save text
  local text
  text=$(printf '%s' "$content_json" | jq -r '[.[] | select(.type=="text") | .text] | join("\n")')
  [[ -n "$text" ]] && printf '%s' "$text" > "$NEXT_DIR/text.md"

  # Extract and save tool_use blocks
  local tool_uses
  tool_uses=$(printf '%s' "$content_json" | jq -c '[.[] | select(.type=="tool_use")]')
  if [[ "$tool_uses" != "[]" ]]; then
    printf '%s' "$tool_uses" > "$NEXT_DIR/tool_use.json"
  fi
}

# Write tool results as a user message
add_tool_results() {
  local results_json="$1"
  next_msg_dir "user"
  printf '%s' "$results_json" > "$NEXT_DIR/tool_result.json"
}

# =============================================================================
# BUILD JSON PAYLOAD — the only place we construct JSON from files
# =============================================================================

build_payload() {
  # Write one JSON file per message into a temp dir, then jq -s merge.
  # No large strings ever live in a shell variable.
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local seq=0
  while IFS= read -r msg_dir; do
    [[ -z "$msg_dir" ]] && continue
    local base role outfile
    base=$(basename "$msg_dir")
    role="${base#*-}"
    outfile=$(printf '%s/%05d.json' "$tmpdir" "$seq")
    seq=$(( seq + 1 ))

    if [[ "$role" == "user" ]]; then
      if [[ -f "$msg_dir/tool_result.json" ]]; then
        jq -n --arg role "$role" --slurpfile c "$msg_dir/tool_result.json" \
          '{role:$role, content:$c[0]}' > "$outfile"
      elif [[ -f "$msg_dir/text.md" ]]; then
        jq -n --arg role "$role" --rawfile t "$msg_dir/text.md" \
          '{role:$role, content:[{type:"text",text:$t}]}' > "$outfile"
      fi

    elif [[ "$role" == "assistant" ]]; then
      local content='[]'
      if [[ -f "$msg_dir/text.md" ]]; then
        content=$(jq -n --rawfile t "$msg_dir/text.md" '[{type:"text",text:$t}]')
      fi
      if [[ -f "$msg_dir/tool_use.json" ]]; then
        content=$(printf '%s' "$content" | jq --slurpfile tu "$msg_dir/tool_use.json" '. + $tu[0]')
      fi
      printf '%s' "$content" | jq --arg role "$role" '{role:$role, content:.}' > "$outfile"
    fi
  done < <(msg_dirs)

  # Merge all per-message files into the final payload
  local payload_file="$SESSION_DIR/.last_payload.json"
  if compgen -G "$tmpdir/*.json" > /dev/null; then
    jq -n \
      --slurpfile msgs <(jq -s '.' "$tmpdir"/*.json) \
      --argjson tools "$TOOLS" \
      --arg model "$MODEL" \
      --argjson max_tokens "$MAX_TOKENS" \
      '{model:$model, max_tokens:$max_tokens, tools:$tools, messages:$msgs[0]}' \
      > "$payload_file"
  else
    jq -n \
      --argjson tools "$TOOLS" \
      --arg model "$MODEL" \
      --argjson max_tokens "$MAX_TOKENS" \
      '{model:$model, max_tokens:$max_tokens, tools:$tools, messages:[]}' \
      > "$payload_file"
  fi
  echo "$payload_file"
}

# =============================================================================
# REPAIR — just delete bad folders
# =============================================================================

repair_session() {
  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(msg_dirs)

  local removed=0
  local i=0
  while [[ $i -lt ${#dirs[@]} ]]; do
    local d="${dirs[$i]}"
    local role
    role=$(basename "$d" | cut -d- -f2-)

    if [[ "$role" == "assistant" ]] && [[ -f "$d/tool_use.json" ]]; then
      # This assistant message has tool_use — check next message
      local next_i=$(( i + 1 ))
      if [[ $next_i -lt ${#dirs[@]} ]]; then
        local next_d="${dirs[$next_i]}"
        local next_role
        next_role=$(basename "$next_d" | cut -d- -f2-)
        if [[ "$next_role" == "user" ]] && [[ -f "$next_d/tool_result.json" ]]; then
          # Check all tool_use ids have matching tool_result ids
          local needed have
          needed=$(jq -r '.[].id' "$d/tool_use.json" | sort)
          have=$(jq -r '.[].tool_use_id' "$next_d/tool_result.json" | sort)
          if [[ "$needed" == "$have" ]]; then
            i=$(( i + 1 ))  # skip past the pair, both are good
          else
            # Mismatch — remove both
            rm -rf "$d" "$next_d"
            removed=$(( removed + 2 ))
            i=$(( next_i + 1 ))
            continue
          fi
        else
          # Next message isn't a tool_result — remove the assistant message
          rm -rf "$d"
          removed=$(( removed + 1 ))
        fi
      else
        # No next message — remove trailing tool_use
        rm -rf "$d"
        removed=$(( removed + 1 ))
      fi
    fi
    i=$(( i + 1 ))
  done

  # Fix consecutive same-role messages by merging text
  dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(msg_dirs)

  i=0
  while [[ $i -lt $(( ${#dirs[@]} - 1 )) ]]; do
    local d="${dirs[$i]}"
    local next_d="${dirs[$((i+1))]}"
    local role next_role
    role=$(basename "$d" | cut -d- -f2-)
    next_role=$(basename "$next_d" | cut -d- -f2-)

    if [[ "$role" == "$next_role" ]] && [[ -f "$d/text.md" ]] && [[ -f "$next_d/text.md" ]]; then
      # Merge next into current, delete next
      printf '\n' >> "$d/text.md"
      cat "$next_d/text.md" >> "$d/text.md"
      rm -rf "$next_d"
      removed=$(( removed + 1 ))
      # Re-read dirs since we deleted one
      dirs=()
      while IFS= read -r dd; do
        dirs+=("$dd")
      done < <(msg_dirs)
    else
      i=$(( i + 1 ))
    fi
  done

  # Re-sync MSG_SEQ
  local last
  last=$(msg_dirs | tail -1 || true)
  if [[ -n "$last" ]]; then
    MSG_SEQ=$(( 10#$(basename "$last" | cut -d- -f1) + 1 ))
  else
    MSG_SEQ=0
  fi

  if [[ "$removed" -gt 0 ]]; then
    printf 'Repaired session: removed %s orphaned messages.\n' "$removed" >&2
  fi
}

# =============================================================================
# TOKEN ESTIMATION
# =============================================================================

estimate_tokens() {
  local chars=0
  while IFS= read -r f; do
    local sz
    sz=$(wc -c < "$f")
    chars=$(( chars + sz ))
  done < <(find "$SESSION_DIR" -maxdepth 2 -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null)
  echo $(( chars / 4 ))
}

# =============================================================================
# COMPACTION
# =============================================================================

compact_conversation() {
  local tok_est
  tok_est=$(estimate_tokens)
  local count
  count=$(msg_count)

  if [[ "$count" -le "$COMPACT_KEEP_LAST" ]]; then
    printf 'Conversation too short to compact (%s messages).\n' "$count" >&2
    return
  fi

  printf '\033[33mCompacting conversation (~%sk tokens, %s messages)...\033[0m\n' \
    "$(( tok_est / 1000 ))" "$count" >&2

  # Collect message dirs into an array
  local all_dirs=()
  while IFS= read -r d; do
    all_dirs+=("$d")
  done < <(msg_dirs)

  # Find a clean split point: scan from (count - COMPACT_KEEP_LAST) forward
  # to find a user text message (not a tool_result)
  local start_idx=$(( ${#all_dirs[@]} - COMPACT_KEEP_LAST ))
  [[ $start_idx -lt 2 ]] && start_idx=2
  local split_idx=$start_idx

  for (( idx=start_idx; idx < ${#all_dirs[@]}; idx++ )); do
    local d="${all_dirs[$idx]}"
    local role
    role=$(basename "$d" | cut -d- -f2-)
    if [[ "$role" == "user" ]] && [[ -f "$d/text.md" ]] && [[ ! -f "$d/tool_result.json" ]]; then
      split_idx=$idx
      break
    fi
  done

  # Build text summary of older messages — append to temp file, not shell var
  local conv_file
  conv_file=$(mktemp)
  for (( idx=0; idx < split_idx; idx++ )); do
    local d="${all_dirs[$idx]}"
    local role
    role=$(basename "$d" | cut -d- -f2-)
    if [[ -f "$d/text.md" ]]; then
      printf '%s: ' "$role" >> "$conv_file"
      cat "$d/text.md" >> "$conv_file"
      printf '\n' >> "$conv_file"
    fi
  done

  # Call API to summarize — payload and response go through files
  local compact_payload="$SESSION_DIR/.compact_payload.json"
  jq -n \
    --arg model "$MODEL" \
    --rawfile conv "$conv_file" \
    '{
      model: $model,
      max_tokens: 4096,
      messages: [{
        role: "user",
        content: ("Below is a conversation between a user and an AI assistant. Produce a concise summary that captures: (1) what tasks were worked on, (2) key decisions and outcomes, (3) any important file paths, commands, or code discussed, (4) current state of any ongoing work. Be factual and specific — this summary will replace the conversation history.\n\nConversation:\n" + $conv + "\n---\nProduce the summary now. Be concise but preserve all important details.")
      }]
    }' > "$compact_payload"
  rm -f "$conv_file"

  local compact_response="$SESSION_DIR/.compact_response.json"
  local -a curl_args=(
    -s -o "$compact_response" -w "%{http_code}" "$API_URL"
    -H "$AUTH_HEADER"
    -H "anthropic-version: 2023-06-01"
    -H "content-type: application/json"
  )
  [[ -n "${OAUTH_BETA:-}" ]] && curl_args+=(-H "anthropic-beta: $OAUTH_BETA")

  local http_code
  http_code=$(curl "${curl_args[@]}" -d "@$compact_payload")

  if [[ "$http_code" -ne 200 ]]; then
    printf 'Compaction failed (HTTP %s):\n' "$http_code" >&2
    cat "$compact_response" >&2
    printf '\n' >&2
    return 1
  fi

  local summary
  summary=$(jq -r '.content[] | select(.type=="text") | .text' "$compact_response")

  if [[ -z "$summary" ]]; then
    printf 'Compaction failed: empty summary returned.\n' >&2
    return 1
  fi

  # Save summary for reference
  printf 'Compacted at %s (~%sk tokens)\n\n%s\n' \
    "$(date)" "$(( tok_est / 1000 ))" "$summary" >> "$SESSION_DIR/summary.md"

  # Delete old message dirs
  for (( idx=0; idx < split_idx; idx++ )); do
    rm -rf "${all_dirs[$idx]}"
  done

  # Renumber: move kept messages to start from 00002
  local kept_dirs=()
  while IFS= read -r d; do
    kept_dirs+=("$d")
  done < <(msg_dirs)

  local new_seq=2
  for d in "${kept_dirs[@]}"; do
    local role
    role=$(basename "$d" | cut -d- -f2-)
    local new_name
    new_name=$(printf '%s/%05d-%s' "$SESSION_DIR" "$new_seq" "$role")
    if [[ "$d" != "$new_name" ]]; then
      mv "$d" "$new_name"
    fi
    new_seq=$(( new_seq + 1 ))
  done

  # Insert synthetic summary as messages 00000-user + 00001-assistant
  local sum_user_dir sum_asst_dir
  sum_user_dir=$(printf '%s/%05d-user' "$SESSION_DIR" 0)
  sum_asst_dir=$(printf '%s/%05d-assistant' "$SESSION_DIR" 1)
  mkdir -p "$sum_user_dir" "$sum_asst_dir"
  printf '%s' "[This conversation was compacted. Summary of prior context follows.]" > "$sum_user_dir/text.md"
  printf '%s' "$summary" > "$sum_asst_dir/text.md"

  MSG_SEQ=$new_seq

  local new_tok_est new_count
  new_tok_est=$(estimate_tokens)
  new_count=$(msg_count)
  printf '\033[32mCompacted: %s messages → %s (~%sk tokens → ~%sk tokens)\033[0m\n' \
    "$count" "$new_count" "$(( tok_est / 1000 ))" "$(( new_tok_est / 1000 ))" >&2
}

check_auto_compact() {
  local chars=0
  while IFS= read -r f; do
    local sz
    sz=$(wc -c < "$f")
    chars=$(( chars + sz ))
  done < <(find "$SESSION_DIR" -maxdepth 2 -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null)
  if [[ "$chars" -gt "$COMPACT_THRESHOLD" ]]; then
    compact_conversation
  fi
}

# =============================================================================
# SESSION LISTING
# =============================================================================

list_sessions() {
  local dirs=("$SESSIONS_ROOT"/*/)
  if [[ ! -d "${dirs[0]}" ]]; then
    printf 'No saved sessions.\n'
    return
  fi
  printf '\nSaved sessions:\n'
  local i=1
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    local count compacted=""
    count=$(msg_count "$d")
    [[ -f "$d/summary.md" ]] && compacted=" [compacted]"
    printf '  [%d] %s  (%s messages%s)\n' "$i" "$(basename "$d")" "$count" "$compacted"
    (( i++ ))
  done
  printf '\nEnter session number to resume, or press enter to start new: '
  read -r choice < /dev/tty
  if [[ -n "$choice" ]] && [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$(( choice - 1 ))
    load_session "${dirs[$idx]}"
  else
    new_session
  fi
}

# =============================================================================
# TOOL EXECUTION
# =============================================================================

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

# =============================================================================
# API CALL
# =============================================================================

call_api() {
  local payload_file
  payload_file=$(build_payload)

  local response_file="$SESSION_DIR/.last_response.json"

  local http_code
  local -a curl_args=(
    -s -o "$response_file" -w "%{http_code}" "$API_URL"
    -H "$AUTH_HEADER"
    -H "anthropic-version: 2023-06-01"
    -H "content-type: application/json"
  )
  [[ -n "${OAUTH_BETA:-}" ]] && curl_args+=(-H "anthropic-beta: $OAUTH_BETA")

  http_code=$(curl "${curl_args[@]}" -d "@$payload_file")

  if [[ "$http_code" -ne 200 ]]; then
    printf 'API error (HTTP %s):\n' "$http_code" >&2
    cat "$response_file" >&2
    printf '\n' >&2
    return 1
  fi

  cat "$response_file"
}

# =============================================================================
# STARTUP — offer to resume last session
# =============================================================================

last_session=$(ls -dt "$SESSIONS_ROOT"/*/ 2>/dev/null | head -1 || true)
if [[ -n "$last_session" ]] && [[ -d "$last_session" ]]; then
  count=$(msg_count "$last_session")
  printf 'Last session: %s (%s messages). Resume? [Y/n] ' "$(basename "$last_session")" "$count"
  read -r resume < /dev/tty
  if [[ "${resume:-y}" =~ ^[Yy]$ ]]; then
    load_session "$last_session"
  else
    new_session
  fi
else
  new_session
fi

# =============================================================================
# MAIN LOOP
# =============================================================================

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

  add_user_text "$user_input"

  # Agent loop: keep going until no more tool calls
  while true; do
    printf '\033[2m(thinking...)\033[0m\n' >&2

    if ! response=$(call_api); then
      printf 'Failed. Check the error above.\n' >&2
      break
    fi

    stop_reason=$(printf '%s' "$response" | jq -r '.stop_reason')
    content=$(printf '%s' "$response" | jq -c '.content')

    # Check if content has tool_use blocks
    has_tool_use=$(printf '%s' "$content" | jq '[.[] | select(.type=="tool_use")] | length')

    # Strip tool_use blocks from truncated responses
    if [[ "$stop_reason" != "tool_use" ]] && [[ "$has_tool_use" -gt 0 ]]; then
      printf '\033[33m(stripped %s orphaned tool_use from truncated response)\033[0m\n' "$has_tool_use" >&2
      content=$(printf '%s' "$content" | jq -c '[.[] | select(.type != "tool_use")]')
      has_tool_use=0
    fi

    # Print text
    printf '%s' "$content" | jq -r '.[] | select(.type=="text") | .text'

    # Save assistant response to disk
    add_assistant_response "$content"

    # No tool use — show tokens and break
    if [[ "$has_tool_use" -eq 0 ]]; then
      tok_est=$(estimate_tokens)
      printf '\033[2m[~%sk tokens]\033[0m\n' "$(( tok_est / 1000 ))" >&2
      check_auto_compact
      break
    fi

    # Process tool calls — write each result to a temp file, then merge
    results_dir=$(mktemp -d)
    tool_seq=0
    while IFS= read -r row; do
      tool_id=$(printf '%s' "$row" | jq -r '.id')
      tool_name=$(printf '%s' "$row" | jq -r '.name')
      tool_input=$(printf '%s' "$row" | jq -c '.input')

      result=$(execute_tool "$tool_name" "$tool_input")

      if [[ "${#result}" -gt 30000 ]]; then
        result="${result:0:30000}... [truncated]"
      fi

      jq -n --arg id "$tool_id" --arg result "$result" \
        '{type:"tool_result", tool_use_id:$id, content:$result}' \
        > "$results_dir/$(printf '%03d' "$tool_seq").json"
      tool_seq=$(( tool_seq + 1 ))
    done < <(printf '%s' "$content" | jq -c '.[] | select(.type=="tool_use")')

    # Merge all results into a single array and save
    merged_results=$(jq -s '.' "$results_dir"/*.json)
    rm -rf "$results_dir"
    add_tool_results "$merged_results"
  done
done
