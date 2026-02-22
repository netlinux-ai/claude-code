# claude-code

Claude Code CLI — repackaged for Debian with source-built components, plus a minimal agentic shell script.

---

## Contents

### `mini-claude.sh` — Minimal Agentic Shell

A lightweight, transparent alternative to the full Claude Code CLI. It's a single bash script (~750 lines) that gives Claude the ability to run commands, read files, and write files on your machine — driven by a simple terminal conversation loop.

**Features:**
- Fully readable and hackable — no black boxes
- Agentic loop: Claude can chain multiple tool calls before responding
- Three tools: `bash`, `read_file`, `write_file`
- Asks for confirmation before running any bash command or writing any file
- `--dangerously-skip-permissions` flag to bypass all confirmations
- Persistent sessions stored as files and folders in `~/.mini-claude/sessions/`
- On startup, offers to resume the last session
- `/sessions` command to list and resume any past session
- `/clear` to start a fresh session
- `/compact` to manually compress conversation history
- Auto-compaction when context grows too large (~80k tokens)
- Session repair on load (fixes orphaned tool calls, mismatched IDs, consecutive same-role messages)
- Uses your existing Claude Code OAuth credentials (no separate API key needed)
- Falls back to `$ANTHROPIC_API_KEY` if set
- Defaults to `claude-opus-4-6` (override with `CLAUDE_MODEL` env var)

**Requirements:**
- `curl`
- `jq`
- Either: a Claude Code login (`claude login`), or `ANTHROPIC_API_KEY` set in your environment

**Usage:**
```bash
chmod +x mini-claude.sh
./mini-claude.sh
```

Override the model:
```bash
CLAUDE_MODEL=claude-sonnet-4-6 ./mini-claude.sh
```

Skip all permission prompts (use with caution):
```bash
./mini-claude.sh --dangerously-skip-permissions
```

Then just type your message at the `you>` prompt.

**Slash commands:**
| Command | Effect |
|---|---|
| `/clear` | Start a new session, discarding current context |
| `/compact` | Summarise and compress conversation history |
| `/sessions` | List saved sessions and optionally resume one |
| `/quit` | Exit |

**Session storage:**

Sessions are stored as directories in `~/.mini-claude/sessions/`, named by timestamp (e.g. `20250222-120000/`). Each message is a numbered subdirectory containing plain text and JSON files:

```
sessions/20250222-120000/
  00000-user/text.md
  00001-assistant/text.md + tool_use.json
  00002-user/tool_result.json
  00003-assistant/text.md
  .last_payload.json          # most recent API request (debug)
  .last_response.json         # most recent API response (debug)
  summary.md                  # compaction history
```

Sessions are human-readable, debuggable, crash-resilient, and editable with standard Unix tools.

**How it works:**
1. On startup, offers to resume the last session (or start fresh)
2. Runs a repair pass to fix any corruption from prior crashes
3. Your message is added to the conversation history and saved to disk
4. The conversation is sent to the Anthropic API along with tool definitions
5. If Claude wants to use a tool (bash, read\_file, write\_file), you are asked to confirm
6. The tool result is fed back to the API and Claude continues
7. This loops until Claude is done, then waits for your next message
8. After each response, checks if auto-compaction is needed

---

### Debian Repackaging

This repo also contains tooling to repackage the Claude Code CLI for Debian-based systems with source-built components.

- `Makefile` — build/package automation
- `patches/` — patches applied to upstream source
- `scripts/` — helper scripts for packaging

---

## Differences: `mini-claude.sh` vs Claude Code CLI

| | `mini-claude.sh` | Claude Code |
|---|---|---|
| Size | ~750 lines of bash | ~215 MB compiled Node.js |
| Dependencies | `curl`, `jq` | Node.js runtime, bundled binaries |
| Tools | 3 (bash, read\_file, write\_file) | 15+ (diff/patch, grep, glob, web fetch, memory, etc.) |
| Default model | `claude-opus-4-6` | `claude-opus-4-6` |
| Permissions | Confirm every command (or `--dangerously-skip-permissions`) | Configurable allow-lists and auto-approval |
| Session storage | Filesystem directories with plain text files | Internal database, opaque format |
| Context management | Auto-compaction with API-generated summaries | Intelligent compaction and summarisation |
| Session repair | Automatic on load | Managed internally |
| Project awareness | None — Claude must explore via tools | Full codebase understanding via CLAUDE.md |
| Streaming | No — waits for complete response | Yes — tokens stream in real-time |
| Transparency | Fully readable source | Compiled Node.js binary |

See [DESCRIPTION.md](DESCRIPTION.md) for a detailed technical writeup.

---

## License

MIT
