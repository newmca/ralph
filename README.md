# Ralph (newmca fork)

An enhanced autonomous AI agent loop for spec-driven development. Runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) repeatedly until all PRD stories are complete, with Ollama fallback, schema gates, stalemate detection, and test quality enforcement.

Forked from [snarktank/ralph](https://github.com/snarktank/ralph). Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

## What's Different in This Fork

| Feature | snarktank/ralph | newmca/ralph |
|---------|----------------|--------------|
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

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian, `dnf install jq` on Fedora)
- A git repository for your project
- Optional: [Ollama](https://ollama.com) for local model fallback

## Setup

Copy the ralph files into your project:

```bash
mkdir -p scripts/ralph
cp /path/to/ralph/scripts/ralph/ralph.sh scripts/ralph/
cp /path/to/ralph/scripts/ralph/CLAUDE.md scripts/ralph/
chmod +x scripts/ralph/ralph.sh
```

Install the skills for Claude Code:

```bash
cp -r /path/to/ralph/.claude/skills/opsx-to-ralph ~/.claude/skills/
cp -r /path/to/ralph/.claude/skills/review-tests ~/.claude/skills/
```

## Workflow

### With OpenSpec (recommended)

```
/opsx:propose → tasks.md + proposal.md + design.md → /opsx-to-ralph → prd.json → ralph.sh → /review-tests → done
```

1. **Generate OpenSpec proposal** — creates `tasks.md`, `proposal.md`, `design.md`
2. **Convert to prd.json** — `/opsx-to-ralph` parses tasks, enriches from design docs, auto-tags, validates, then writes `prd.json`
3. **Run Ralph** — `./scripts/ralph/ralph.sh` executes stories autonomously
4. **Review tests** — `/review-tests` audits agent-written tests for quality

### Without OpenSpec

1. Write `prd.json` manually or use any PRD-to-JSON conversion
2. Run `./scripts/ralph/ralph.sh`

## PRD Format

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

**Fields:**
- `priority` — lower number = runs first. Schema before backend before UI.
- `passes` — set to `true` by the agent after successful implementation
- `review` — `FULL` | `TARGETED` | `SKIM` | `MINIMAL` — signals human review depth
- `tags` — `SCHEMA`, `AUTH`, `PAYMENTS`, `SECURITY`, `API`, `UI`, `TEST`, `DOCS`, `CONFIG`, `SCAFFOLD`

## Usage

```bash
# Basic run (10 iterations, Claude Code)
./scripts/ralph/ralph.sh

# Custom iteration count
./scripts/ralph/ralph.sh 20

# With Ollama fallback on rate limits
./scripts/ralph/ralph.sh --fallback qwen3-coder:30b

# With delay between iterations (seconds)
./scripts/ralph/ralph.sh --delay 5

# Custom stalemate threshold
./scripts/ralph/ralph.sh --max-retries 5

# Full example
./scripts/ralph/ralph.sh --fallback qwen3-coder:30b --fallback-url http://gpu:11434 --delay 3 --max-retries 5 20
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--tool amp\|claude` | `claude` | AI tool to invoke |
| `--fallback <model>` | *(none)* | Ollama model for rate-limit fallback |
| `--fallback-url <url>` | `http://localhost:11434` | Ollama server URL |
| `--delay <seconds>` | `0` | Sleep between iterations |
| `--max-retries <n>` | `3` | Consecutive no-progress iterations before abort |
| `<number>` | `10` | Max iterations (positional) |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All stories complete |
| `1` | Max iterations reached |
| `2` | Stalemate — needs human intervention |

## How It Works

Each iteration spawns a **fresh Claude Code instance** with clean context. The only memory between iterations is:

- **Git history** — commits from previous iterations
- **progress.txt** — learnings and codebase patterns
- **prd.json** — which stories are done

The loop:

1. Check prd.json — if all stories pass, exit 0
2. Read next story (highest priority, `passes: false`)
3. **Schema gate** — if story is SCHEMA-tagged and another SCHEMA story already committed this run, skip it
4. Invoke Claude Code with CLAUDE.md instructions
5. **Rate-limit check** — if rate-limited and `--fallback` set, retry with Ollama (skip high-risk stories)
6. Check prd.json again — did a story complete?
7. **Stalemate check** — if no progress for N iterations, exit 2
8. Sleep `--delay` seconds, loop

### Ollama Fallback

When Claude hits rate limits, Ralph automatically retries with a local Ollama model:

- Environment variables are set **inline per-invocation** (not exported globally), so the next iteration still tries Claude first
- Stories tagged `SCHEMA`, `AUTH`, `PAYMENTS`, or `SECURITY` are **skipped** in fallback mode — these are too high-risk for a smaller model
- Which model completed each story is tracked in `progress.txt`

### Schema Gate

Only one SCHEMA-tagged story can be committed per Ralph run. This prevents migration conflicts from concurrent schema changes across iterations.

### Stalemate Detection

If the remaining story count doesn't decrease for `--max-retries` consecutive iterations (default 3), Ralph exits with code 2 rather than burning through iterations with no progress.

## Skills

### `/opsx-to-ralph` — OpenSpec to PRD Converter

Converts an OpenSpec change directory (`tasks.md` + `proposal.md` + `design.md`) into validated `prd.json`.

**What it does:**
1. Parses unchecked tasks from `tasks.md`
2. Enriches descriptions from `proposal.md` and acceptance criteria from `design.md`
3. Auto-tags stories (SCHEMA/AUTH/PAYMENTS/API/UI/etc.) and assigns review levels
4. Validates: no vague criteria, size checks, schema gate warnings, dependency ordering
5. Presents validation summary for user approval before writing

**Trigger:** "convert openspec to ralph", "opsx to ralph", "generate prd.json from openspec"

### `/review-tests` — Test Quality Reviewer

Read-only analysis of test quality from a git diff. Identifies weak tests that AI agents commonly produce.

**What it checks:**
- Vacuous tests (would pass with hardcoded return values)
- Mock-only tests (mocking the module under test)
- Happy-path-only coverage (no error/edge case tests)
- Assertion-free test blocks
- Snapshot-only tests
- Untested public API surface
- Uncovered conditional branches

**Trigger:** "review tests", "check test quality", "review ralph tests"

## Agent Instructions (CLAUDE.md)

The `scripts/ralph/CLAUDE.md` file is piped to each Claude Code instance. It includes:

- **10-step process** — read PRD, pick story, implement, test, commit, update, log
- **Test quality rules** — no vacuous tests, no mock-only tests, negative tests required
- **Schema change rules** — idempotent migrations, no silent drops, verify before/after
- **Story tag awareness** — how each tag affects implementation approach
- **Model awareness** — guidance for when running on Ollama fallback

## Debugging

```bash
# See which stories are done
jq '.stories[] | {id, title, passes}' prd.json

# See remaining stories
jq '[.stories[] | select(.passes == false)] | length' prd.json

# See learnings
cat progress.txt

# Check git history
git log --oneline -10
```

## Testing

Ralph's shell script has a BATS test suite:

```bash
bats scripts/ralph/tests/ralph.bats
```

63 tests covering argument parsing, stop conditions, stalemate detection, archive logic, schema gates, rate-limit detection, Ollama fallback, and edge cases.

## Archiving

Ralph automatically archives previous runs when `prd.json` content changes (detected via sha256 hash). Archives are saved to `archive/YYYY-MM-DD-<story-title>/` with the previous `progress.txt`.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/ralph/ralph.sh` | Enhanced agent loop with fallback, gates, stalemate detection |
| `scripts/ralph/CLAUDE.md` | Agent instructions with test quality and schema rules |
| `scripts/ralph/tests/ralph.bats` | BATS unit tests (63 tests) |
| `.claude/skills/opsx-to-ralph/SKILL.md` | OpenSpec → prd.json converter skill |
| `.claude/skills/review-tests/SKILL.md` | Post-run test quality reviewer skill |
| `ralph.sh` | Original snarktank script (reference) |
| `CLAUDE.md` | Original snarktank agent instructions (reference) |

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [snarktank/ralph](https://github.com/snarktank/ralph) — upstream
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Ollama](https://ollama.com) — local model runtime
