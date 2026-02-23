# mini-claude Agentic CI

An AI-powered CI/CD system that uses mini-claude as a git `post-receive` hook. When you push to main/master, Claude automatically reviews your code changes and reports results.

## How it works

1. You push to a repo on `projects.netlinux.org.uk`
2. The `post-receive` hook fires, forks to background (so your push returns immediately)
3. The hook shallow-clones the repo, extracts the commit log and diff
4. It detects test infrastructure (Makefile, pytest, npm, cargo) and adds test instructions
5. It calls `mini-claude --prompt` with the diff and review instructions
6. Claude's analysis is written to `/mnt/projects/ci/<repo>/latest.log`
7. Timestamped archives are kept alongside

## Components

| File | Server path | Purpose |
|------|-------------|---------|
| `mini-claude.sh` | `/usr/local/bin/mini-claude` | The agentic shell with `--prompt` non-interactive mode |
| `ci/post-receive-hook` | `/usr/local/lib/mini-claude/post-receive-hook` | Git hook that builds the prompt and invokes mini-claude |
| `ci/mini-claude-enable` | `/usr/local/bin/mini-claude-enable` | One-liner to enable CI on a repo |

## Server layout

```
/usr/local/bin/mini-claude              # the agent
/usr/local/bin/mini-claude-enable       # enable script
/usr/local/lib/mini-claude/post-receive-hook  # hook (symlinked into repos)
/mnt/projects/git/<repo>.git/hooks/post-receive -> /usr/local/lib/mini-claude/post-receive-hook
/mnt/projects/ci/<repo>/latest.log      # most recent CI output
/mnt/projects/ci/<repo>/YYYYMMDD-HHMMSS.log  # archived runs
/var/lib/mini-claude/sessions/          # session storage for CI runs
/root/.claude/.credentials.json         # OAuth credentials (auto-refreshed)
```

## Enabling CI on a repo

```bash
mini-claude-enable MTD.git
```

Or manually:
```bash
ln -sf /usr/local/lib/mini-claude/post-receive-hook /mnt/projects/git/MTD.git/hooks/post-receive
```

## What Claude reviews

For each push to main/master, Claude receives:
- The commit log (`git log old..new --oneline`)
- Diff summary (`git diff --stat`)
- Full diff (truncated to 20k chars)
- Test instructions if test infrastructure is detected

Claude then:
1. Summarizes what changed
2. Reviews for bugs, security issues, and style problems
3. Flags anything risky
4. Runs tests if a test framework is detected

## Authentication

mini-claude uses Claude Code OAuth credentials (`~/.claude/.credentials.json`). Tokens auto-refresh using the stored refresh token — no manual intervention needed as long as the refresh chain isn't broken. If it does break, run `claude login` locally and copy the credentials to the server:

```bash
scp ~/.claude/.credentials.json root@projects.netlinux.org.uk:/root/.claude/.credentials.json
```

## Resource constraints

The server has ~1GB RAM, so the hook is designed to be lightweight:
- Uses `claude-sonnet-4-6` (cheaper, faster, less context)
- Shallow clones (`--depth 1`, fetch `--depth 50` for diffs)
- Diffs truncated to 20k chars
- Lockfile (`/tmp/mini-claude-ci.lock`) prevents concurrent runs
- Temp directories cleaned up after each run

## Non-interactive mode (added for CI)

mini-claude.sh gained three flags to support headless operation:

```
--prompt "text"       Run a single prompt, then exit. Implies --dangerously-skip-permissions and --new-session.
--new-session         Skip the resume prompt, always start fresh.
--output-file PATH    Write Claude's final text response to a file.
```

The `MINI_CLAUDE_SESSIONS` env var overrides the default session directory (`~/.mini-claude/sessions`).
