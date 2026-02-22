# claude-code

Claude Code CLI — repackaged for Debian with source-built components, plus a minimal agentic shell script.

---

## Contents

### `mini-claude.sh` — Minimal Agentic Shell

A lightweight, transparent alternative to the full Claude Code CLI. It's a single bash script that gives Claude the ability to run commands, read files, and write files on your machine — driven by a simple terminal conversation loop.

**Features:**
- Fully readable and hackable — no black boxes
- Agentic loop: Claude can chain multiple tool calls before responding
- Three tools: `bash`, `read_file`, `write_file`
- Asks for confirmation before running any bash command or writing any file
- Persistent sessions: conversations are saved to `~/.mini-claude/sessions/` as JSON files
- On startup, offers to resume the last session
- `/sessions` command to list and resume any past session
- `/clear` to start a fresh session
- Uses your existing Claude Code OAuth credentials (no separate API key needed)
- Falls back to `$ANTHROPIC_API_KEY` if set

**Requirements:**
- `curl`
- `jq`
- Either: a Claude Code login (`claude login`), or `ANTHROPIC_API_KEY` set in your environment

**Usage:**
```bash
chmod +x mini-claude.sh
./mini-claude.sh
```

Then just type your message at the `you>` prompt.

**Slash commands:**
| Command | Effect |
|---|---|
| `/clear` | Start a new session, discarding current context |
| `/sessions` | List saved sessions and optionally resume one |
| `/quit` | Exit |

**Session storage:**
Sessions are saved as JSON files in `~/.mini-claude/sessions/`, named by timestamp (e.g. `20250221-143022.json`). Each file contains the full conversation history and can be resumed at any time.

**How it works:**
1. On startup, offers to resume the last session (or start fresh)
2. Your message is added to the conversation history and saved to disk
3. The conversation is sent to the Anthropic API along with tool definitions
4. If Claude wants to use a tool (bash, read\_file, write\_file), you are asked to confirm
5. The tool result is fed back to the API and Claude continues
6. This loops until Claude is done, then waits for your next message
7. The conversation is saved to disk after every exchange

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
| Size | ~270 lines of bash | 215 MB binary |
| Tools | 3 (bash, read\_file, write\_file) | Many (diff/patch, grep, glob, web fetch, memory, etc.) |
| Permissions | Confirm every command | Configurable allow-lists and auto-approval |
| Session persistence | JSON files in `~/.mini-claude/sessions/` | Managed internally |
| Context management | Full history, persisted to disk | Intelligent compaction and summarisation |
| Project awareness | None | Full codebase understanding |
| Transparency | Fully readable source | Compiled Node.js binary |

---

## License

MIT