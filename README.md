# claude-code

Claude Code CLI — repackaged for Debian with source-built components, plus a minimal agentic shell script.

---

## Contents

### `mini-claude.sh` — Minimal Agentic Shell

A lightweight, transparent alternative to the full Claude Code CLI. It's a single 220-line bash script that gives Claude the ability to run commands, read files, and write files on your machine — driven by a simple terminal conversation loop.

**Features:**
- Fully readable and hackable — no black boxes
- Agentic loop: Claude can chain multiple tool calls before responding
- Three tools: `bash`, `read_file`, `write_file`
- Asks for confirmation before running any bash command or writing any file
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

Then just type your message at the `you>` prompt. Press Ctrl-C to quit.

**How it works:**
1. Your message is added to a conversation history (JSON array)
2. The conversation is sent to the Anthropic API along with tool definitions
3. If Claude wants to use a tool (bash, read\_file, write\_file), you are asked to confirm
4. The tool result is fed back to the API and Claude continues
5. This loops until Claude is done, then waits for your next message

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
| Size | 220 lines of bash | 215 MB binary |
| Tools | 3 (bash, read\_file, write\_file) | Many (diff/patch, grep, glob, web fetch, memory, etc.) |
| Permissions | Confirm every command | Configurable allow-lists and auto-approval |
| Context management | Raw accumulation in RAM | Intelligent compaction and summarisation |
| Project awareness | None | Full codebase understanding |
| Transparency | Fully readable source | Compiled Node.js binary |

---

## License

MIT