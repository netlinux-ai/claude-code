# netlinux-ai-agent Agentic CI

An AI-powered CI/CD system that uses netlinux-ai-agent as a git `post-receive` hook. When you push to main/master, Claude automatically reviews your code changes and reports results.

## Why NetLinux Agentic CI

Existing AI code review tools — [PR-Agent](https://github.com/qodo-ai/pr-agent), [CodeRabbit](https://www.coderabbit.ai/), Claude Code's own [code-review plugin](https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md) — all assume a forge (GitHub, GitLab, Bitbucket) with a PR/MR API to post comments on. They don't work with plain bare git repos served over SSH with gitweb.

This system is different:

- **No forge needed.** Works on any bare git repo with a `post-receive` hook. No GitHub, no GitLab, no PR API — just `git push` and read the log.
- **Agentic, not passive.** Claude doesn't just review a diff — it can run tests, read files, and execute commands in a cloned working copy. If your repo has a Makefile with a `test` target, Claude will run it.
- **Minimal infrastructure.** A single bash script (~800 lines), no Docker, no Node.js, no Python runtime. Runs on a 1GB VPS with bash 4.3, curl, and jq.
- **No API key management.** Piggybacks on Claude Code's OAuth subscription with automatic token refresh — the credential chain sustains itself indefinitely.
- **Opt-in per repo.** A symlink enables it; removing the symlink disables it. No config files, no YAML, no dashboard.

## How it works

1. You push to a repo on `projects.netlinux.org.uk`
2. The `post-receive` hook fires, forks to background (so your push returns immediately)
3. The hook shallow-clones the repo, extracts the commit log and diff
4. It detects test infrastructure (Makefile, pytest, npm, cargo) and adds test instructions
5. It calls `netlinux-ai-agent --prompt` with the diff and review instructions
6. Claude's analysis is written to `/mnt/projects/ci/<repo>/latest.log`
7. Timestamped archives are kept alongside

## Components

| File | Server path | Purpose |
|------|-------------|---------|
| `netlinux-ai-agent.sh` | `/usr/local/bin/netlinux-ai-agent` | The agentic shell with `--prompt` non-interactive mode |
| `ci/post-receive-hook` | `/usr/local/lib/netlinux-ai-agent/post-receive-hook` | Git hook that builds the prompt and invokes netlinux-ai-agent |
| `ci/netlinux-ai-agent-enable` | `/usr/local/bin/netlinux-ai-agent-enable` | One-liner to enable CI on a repo |

## Server layout

```
/usr/local/bin/netlinux-ai-agent              # the agent
/usr/local/bin/netlinux-ai-agent-enable       # enable script
/usr/local/lib/netlinux-ai-agent/post-receive-hook  # hook (symlinked into repos)
/mnt/projects/git/<repo>.git/hooks/post-receive -> /usr/local/lib/netlinux-ai-agent/post-receive-hook
/mnt/projects/ci/<repo>/latest.log      # most recent CI output
/mnt/projects/ci/<repo>/YYYYMMDD-HHMMSS.log  # archived runs
/var/lib/netlinux-ai-agent/sessions/          # session storage for CI runs
/root/.claude/.credentials.json         # OAuth credentials (auto-refreshed)
```

## Enabling CI on a repo

```bash
netlinux-ai-agent-enable MTD.git
```

Or manually:
```bash
ln -sf /usr/local/lib/netlinux-ai-agent/post-receive-hook /mnt/projects/git/MTD.git/hooks/post-receive
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

netlinux-ai-agent uses Claude Code OAuth credentials (`~/.claude/.credentials.json`). Tokens auto-refresh using the stored refresh token — no manual intervention needed as long as the refresh chain isn't broken. If it does break, run `claude login` locally and copy the credentials to the server:

```bash
scp ~/.claude/.credentials.json root@projects.netlinux.org.uk:/root/.claude/.credentials.json
```

## Resource constraints

The server has ~1GB RAM, so the hook is designed to be lightweight:
- Uses `claude-sonnet-4-6` (cheaper, faster, less context)
- Shallow clones (`--depth 1`, fetch `--depth 50` for diffs)
- Diffs truncated to 20k chars
- Lockfile (`/tmp/netlinux-ai-agent-ci.lock`) prevents concurrent runs
- Temp directories cleaned up after each run

## Non-interactive mode (added for CI)

netlinux-ai-agent.sh gained three flags to support headless operation:

```
--prompt "text"       Run a single prompt, then exit. Implies --dangerously-skip-permissions and --new-session.
--new-session         Skip the resume prompt, always start fresh.
--output-file PATH    Write Claude's final text response to a file.
```

The `NETLINUX_AI_AGENT_SESSIONS` env var overrides the default session directory (`~/.netlinux-ai-agent/sessions`).
