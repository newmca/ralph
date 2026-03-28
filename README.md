# Ralph (newmca fork)

Autonomous AI agent loop for spec-driven development. Runs Claude Code repeatedly — fresh context each iteration — until all PRD stories pass. When Claude rate-limits, falls back to Ollama automatically.

Forked from [snarktank/ralph](https://github.com/snarktank/ralph). Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

## Quickstart

```bash
# In your project repo:
mkdir -p scripts/ralph
cp /path/to/newmca-ralph/scripts/ralph/ralph.sh scripts/ralph/
cp /path/to/newmca-ralph/scripts/ralph/COPY_INTO_YOUR_PROJECT_CLAUDE.md scripts/ralph/CLAUDE.md
chmod +x scripts/ralph/ralph.sh

# Edit scripts/ralph/CLAUDE.md — add your test commands, conventions, stack details

# Write or generate prd.json (see "PRD Format" below)

# Run
./scripts/ralph/ralph.sh --fallback qwen3-coder:30b --delay 90 15
```

That's it. Ralph picks up stories from `prd.json`, implements them, runs your quality gate, commits, and moves on. When Claude rate-limits, it retries on Ollama. When all stories pass or it stalls, it stops.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` (`brew install jq` / `apt install jq` / `dnf install jq`)
- A git repository for your project
- [Ollama](https://ollama.com) with a pulled model (e.g., `ollama pull qwen3-coder:30b`) for rate-limit fallback

### Ollama Setup

Since Ollama v0.15+, you can use `ollama launch claude` to auto-configure environment variables for Claude Code:

```bash
# Easiest method (Ollama v0.15+):
ollama launch claude --model qwen3-coder:30b

# Manual method (any Ollama v0.14+):
export ANTHROPIC_BASE_URL="http://localhost:11434"
export ANTHROPIC_AUTH_TOKEN="ollama"
export ANTHROPIC_API_KEY=""
claude --model qwen3-coder:30b
```

Note: Ralph's `--fallback` flag sets environment variables inline per-invocation (not exported globally), so the next iteration still tries Claude first. The above is only needed if you want to run Claude Code manually against Ollama outside of Ralph.
- Optional: [OpenSpec](https://github.com/Fission-AI/OpenSpec) for spec-driven workflow
- Optional: `bats` to run the test suite (`dnf install bats`)

## How it works

Each iteration spawns a **fresh Claude Code instance** with clean context. No conversation carries over. The only memory between iterations lives in the filesystem:

- **`prd.json`** — which stories are done (`passes: true/false`)
- **`progress.txt`** — learnings and codebase patterns from previous iterations
- **Git history** — commits from previous iterations

The loop, each iteration:

1. Parse `prd.json` with jq. If all stories pass → exit 0.
2. Pick the highest-priority story where `passes: false`.
3. **Schema gate** — if it's SCHEMA-tagged and another SCHEMA story already landed this run, skip it.
4. Pipe `scripts/ralph/CLAUDE.md` to a fresh Claude Code instance.
5. **Rate-limit check** — if Claude is throttled and `--fallback` is set, retry with Ollama (high-risk stories are skipped on fallback).
6. Check `prd.json` again. Did a story complete?
7. **Stalemate check** — if no progress for `--max-retries` consecutive iterations, exit 2.
8. Sleep `--delay` seconds, repeat.

### Key behaviors

**Ollama fallback**: When Claude hits rate limits, Ralph retries with a local Ollama model. Environment variables are set inline per-invocation (not exported), so the next iteration still tries Claude first. Stories tagged `SCHEMA`, `AUTH`, `PAYMENTS`, or `SECURITY` are skipped in fallback mode — too high-risk for a smaller model.

**Schema gate**: Only one SCHEMA-tagged story can land per Ralph run. Prevents migration conflicts from concurrent schema changes across iterations.

**Stalemate detection**: If the remaining story count doesn't decrease for N consecutive iterations (default 3), Ralph exits with code 2 rather than burning through iterations with no progress.

## What to expect

On a typical run against a greenfield project with 15-20 stories:

- **5-8 stories land** — scaffolding, data models, CRUD, test setup. These are well-defined, testable, single-concern stories where agents excel.
- **3-4 fail the quality gate** and queue for retry on the next run.
- **2-3 get blocked** on integration points or ambiguous acceptance criteria and need your input.
- **The hard ones** (auth edge cases, payment webhooks, complex state machines) usually need your interactive attention with Opus.

This is still a massive productivity gain — 5-8 implemented, tested, committed stories while you were doing something else. The playbook is designed around the reality that agents handle ~60% autonomously.

## Usage

```bash
# Basic run (10 iterations, Claude Code)
./scripts/ralph/ralph.sh

# Custom iteration count
./scripts/ralph/ralph.sh 20

# With Ollama fallback on rate limits
./scripts/ralph/ralph.sh --fallback qwen3-coder:30b

# With delay between iterations (90s is good for Pro rate limits)
./scripts/ralph/ralph.sh --delay 90

# Custom stalemate threshold
./scripts/ralph/ralph.sh --max-retries 5

# Full example: fallback + remote Ollama + spacing + 20 iterations
./scripts/ralph/ralph.sh --fallback qwen3-coder:30b --fallback-url http://gpu:11434 --delay 90 --max-retries 5 20
```

### Flags

| Flag | Default | Description |
| --- | --- | --- |
| `--tool amp\|claude` | `claude` | AI tool to invoke |
| `--fallback <model>` | *(none)* | Ollama model for rate-limit fallback |
| `--fallback-url <url>` | `http://localhost:11434` | Ollama server URL |
| `--delay <seconds>` | `0` | Sleep between iterations |
| `--max-retries <n>` | `3` | Consecutive no-progress iterations before abort |
| `<number>` | `10` | Max iterations (positional) |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | All stories complete |
| `1` | Max iterations reached |
| `2` | Stalemate — needs human intervention |
| `3` | Unrecoverable prd.json corruption |

## Security warning

Ralph runs with `--dangerously-skip-permissions` by default — autonomous loops require it. This means the agent has unrestricted access to your filesystem.

**Opus 4.6 will actively seek credentials.** This is documented behavior. It has been observed extracting API keys from Docker configs, using misplaced tokens, and calling services via found OAuth tokens — without being instructed to.

**Non-negotiable mitigations:**

- Don't store production secrets on your dev machine. Use a secrets manager (`op run`, `doppler run`).
- Ralph works on feature branches. Never skip permissions on main.
- Review every commit diff before merging — especially config files and unexpected network calls.
- Scope `.env` to only what the project needs.
- For payment and auth code, always review manually.
- Consider [serpro69/claude-in-docker](https://github.com/serpro69/claude-in-docker) for sandboxed execution.

## Setup details

### The agent prompt (`scripts/ralph/CLAUDE.md`)

`COPY_INTO_YOUR_PROJECT_CLAUDE.md` in this repo is the template. Copy it into your project as `scripts/ralph/CLAUDE.md` and customize it. This file gets piped to every Claude Code instance — it's the agent's primary instruction set.

What to customize:

- Your quality check commands (e.g., `npm run typecheck && npm run lint && npm run test`)
- Codebase conventions (e.g., "use server actions, not API routes")
- Stack-specific gotchas (e.g., "always run `db:push` after schema changes")

The template includes a 10-step agent process, test quality rules, schema change rules, story tag awareness, and model-awareness guidance for Ollama fallback.

### Installing skills (optional)

```bash
cp -r /path/to/newmca-ralph/.claude/skills/opsx-to-ralph ~/.claude/skills/
cp -r /path/to/newmca-ralph/.claude/skills/review-tests ~/.claude/skills/
```

## Workflow with OpenSpec

```
/opsx:propose → tasks.md + proposal.md + design.md → /opsx-to-ralph → prd.json → ralph.sh → /review-tests → done
```

1. **Generate an OpenSpec proposal** — `/opsx:propose 'feature-name'` (basic profile) or `/opsx:new 'feature-name'` then `/opsx:ff` (expanded profile). Both produce `tasks.md`, `proposal.md`, `design.md`.
2. **Convert to prd.json** — `/opsx-to-ralph` parses tasks, enriches from design docs, auto-tags, validates, writes `prd.json`.
3. **Run Ralph** — `./scripts/ralph/ralph.sh` grinds through the stories.
4. **Review tests** — `/review-tests` audits agent-written tests for quality.

Without OpenSpec, write `prd.json` by hand or use any PRD-to-JSON conversion.

## Skills

### `/opsx-to-ralph` — OpenSpec → prd.json

Converts an OpenSpec change directory into validated `prd.json`.

1. Parses unchecked tasks from `tasks.md`
2. Enriches descriptions from `proposal.md` and acceptance criteria from `design.md`
3. Auto-tags stories (SCHEMA/AUTH/PAYMENTS/API/UI/etc.) and assigns review levels
4. Validates: no vague criteria, size checks, schema gate warnings, dependency ordering
5. Presents validation summary for approval before writing

**Trigger:** "convert openspec to ralph", "opsx to ralph", "generate prd.json from openspec"

### `/review-tests` — test quality audit

Read-only analysis of test quality from a git diff. Flags weak tests that agents commonly produce: vacuous tests, mock-only tests, happy-path-only coverage, assertion-free blocks, snapshot-only tests, untested public API surface, uncovered conditional branches.

**Trigger:** "review tests", "check test quality", "review ralph tests"

## PRD format

```json
{
  "stories": [
    {
      "id": "US-001",
      "title": "Add users table",
      "description": "Create the users table with Drizzle ORM",
      "acceptance_criteria": [
        "Users table has id, email, role columns",
        "Migration runs successfully",
        "Typecheck passes"
      ],
      "passes": false,
      "priority": 1,
      "review": "FULL",
      "tags": ["SCHEMA"]
    }
  ]
}
```

| Field | Purpose |
| --- | --- |
| `priority` | Lower = runs first. Schema before backend before UI. |
| `passes` | Set to `true` by the agent after successful implementation. |
| `review` | `FULL` \| `TARGETED` \| `SKIM` \| `MINIMAL` — signals human review depth. |
| `tags` | `SCHEMA`, `AUTH`, `PAYMENTS`, `SECURITY`, `API`, `UI`, `TEST`, `DOCS`, `CONFIG`, `SCAFFOLD` |

## Debugging

```bash
# Which stories are done?
jq '.stories[] | {id, title, passes}' prd.json

# How many remain?
jq '[.stories[] | select(.passes == false)] | length' prd.json

# What happened?
cat progress.txt
git log --oneline -10
```

## Testing

```bash
bats scripts/ralph/tests/ralph.bats
```

63 tests covering argument parsing, stop conditions, stalemate detection, archive logic, schema gates, rate-limit detection, Ollama fallback, and edge cases.

## Archiving

Ralph automatically archives previous runs when `prd.json` content changes (detected via sha256 hash). Archives go to `archive/YYYY-MM-DD-<story-title>/` with the previous `progress.txt`.

## Repo layout

| Path | What it is |
| --- | --- |
| `scripts/ralph/ralph.sh` | **The script you copy into your project.** Enhanced loop with fallback, gates, stalemate detection. |
| `scripts/ralph/COPY_INTO_YOUR_PROJECT_CLAUDE.md` | **The agent prompt template you copy and customize.** |
| `scripts/ralph/tests/ralph.bats` | BATS test suite. |
| `.claude/skills/opsx-to-ralph/SKILL.md` | OpenSpec → prd.json converter skill. |
| `.claude/skills/review-tests/SKILL.md` | Post-run test quality reviewer skill. |
| `ralph.sh` | Original snarktank script (upstream reference, don't use). |
| `CLAUDE.md` | Original snarktank agent prompt (upstream reference, don't use). |

> **Note:** The root-level `ralph.sh` and `CLAUDE.md` are the original snarktank files kept for reference. The files you actually use are in `scripts/ralph/`.

## What's different from snarktank/ralph

| Feature | snarktank/ralph | newmca/ralph |
| --- | --- | --- |
| Stop condition | `<promise>COMPLETE</promise>` grep | jq-based prd.json check (reliable) |
| Rate-limit handling | None | Automatic Ollama fallback (`--fallback`) |
| Schema safety | None | Schema gate: one schema migration per run |
| Stalemate detection | None | Exits after N consecutive no-progress iterations |
| Iteration spacing | Hardcoded 2s sleep | Configurable `--delay` flag |
| PRD format | `userStories` / `acceptanceCriteria` | `stories` / `acceptance_criteria` + `tags` + `review` |
| Story tagging | None | AUTO/SCHEMA/PAYMENTS/AUTH/API/UI/TEST/DOCS/CONFIG |
| High-risk story protection | None | Skips SCHEMA/AUTH/PAYMENTS/SECURITY on fallback model |
| Test quality rules | None | Enforced in CLAUDE.md (no vacuous/mock-only tests) |
| OpenSpec integration | None | `/opsx-to-ralph` skill for tasks.md → prd.json |
| Test review | None | `/review-tests` skill for post-run quality audit |
| Default tool | Amp | Claude Code |

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [snarktank/ralph](https://github.com/snarktank/ralph) — upstream
- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
- [Ollama](https://ollama.com) — local model runtime
- [OpenSpec](https://github.com/Fission-AI/OpenSpec) — spec-driven development