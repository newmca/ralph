---
name: opsx-to-ralph
description: "Convert OpenSpec change proposals (tasks.md + proposal.md + design.md) into validated prd.json for Ralph autonomous execution. Use when asked to convert openspec to ralph, opsx to ralph, generate prd.json from openspec, or convert tasks.md to prd.json."
user-invocable: true
---

# OpenSpec to Ralph Converter

Converts OpenSpec change proposals into validated `prd.json` for Ralph autonomous execution. Reads `tasks.md`, `proposal.md`, and `design.md` from an OpenSpec change directory and produces a structured, validated PRD.

---

## The Job

Take an OpenSpec change directory containing `tasks.md`, `proposal.md`, and `design.md` and convert it into a validated `prd.json` that Ralph can execute autonomously. This is a 4-phase pipeline: Parse, Enrich, Tag, Validate.

---

## Input

The user provides a path to an OpenSpec change directory (e.g., `openspec/changes/my-feature/`).

That directory contains:
- **`tasks.md`** (required) -- Checkbox list of tasks to implement
- **`proposal.md`** (required) -- Motivation and rationale for the change
- **`design.md`** (required) -- Technical constraints, API contracts, expected behavior
- **`specs/`** (optional) -- Additional specification files for context

---

## Phase 1: Parse tasks.md

Read `tasks.md` and extract every **unchecked** checkbox line.

### Extraction Rules

1. Match lines starting with `- [ ]` or `* [ ]` (unchecked tasks)
2. **Skip** lines starting with `- [x]` or `* [x]` (already completed)
3. **Skip** all tasks nested under a section whose heading-level task is already checked
4. Preserve the numbering hierarchy as priority ordering -- line order equals priority
5. Each unchecked task becomes one user story

### Example tasks.md

```markdown
## 1. Database Schema
- [ ] 1.1 Create user table with Drizzle schema
- [ ] 1.2 Add subscription_tier enum

## 2. Auth Setup
- [x] 2.1 Install Better Auth (already done)
- [ ] 2.2 Configure Google OAuth provider

## 3. Billing Integration
- [ ] 3.1 Add Polar webhook handler
- [ ] 3.2 Create subscription status component
```

This produces 4 stories: 1.1, 1.2, 2.2, 3.1, 3.2 (task 2.1 is skipped because it is checked).

### Checked Parent Rule

If a **section heading** is itself checked (e.g., `- [x] 2. Auth Setup` as a checkbox), skip ALL tasks under that section regardless of their individual check state.

---

## Phase 2: Enrich from proposal.md and design.md

Cross-reference the companion documents to fill in story details.

### From proposal.md

- Extract the **motivation** and **rationale** for each task
- Inject relevant context into the story `description` field
- Match by task numbering, section headings, or keyword overlap

### From design.md

- Extract **technical constraints**, **API contracts**, and **expected behavior**
- Convert these into concrete, testable `acceptance_criteria`
- Every criterion must be something a test, typecheck, or manual verification can confirm
- No vague criteria allowed (see Phase 4 validation)

### From specs/ (if present)

- Scan filenames for additional context (e.g., `auth-flow.md` confirms AUTH tag)
- Read relevant spec files to extract additional acceptance criteria
- If `specs/` does not exist, skip silently with no error

### Unmatched Tasks

If no match is found in `design.md` for a particular task, flag that story with **"criteria TBD"** in the validation report (Phase 4). Do NOT invent criteria -- surface the gap for the user.

### Mandatory Criteria

Every story MUST include:
- `"Typecheck passes"` as a criterion

UI stories (tagged UI) MUST additionally include:
- `"Verify in browser using dev-browser skill"` as a criterion

---

## Phase 3: Auto-tag Stories

Assign a `review` level and `tags` array to each story based on content analysis of the title, description, and acceptance criteria.

### Tagging Rules

| Keywords | Tag | Review Level |
|----------|-----|--------------|
| auth, login, session, oauth, token, jwt, permission | AUTH | FULL |
| payment, billing, stripe, invoice, subscription, webhook (payment context), Polar | PAYMENTS | FULL |
| schema, migration, table, column, database, db, drizzle, index | SCHEMA | FULL |
| api, endpoint, route, handler, REST, graphql | API | TARGETED |
| component, page, layout, UI, form, modal, button, display | UI | SKIM |
| test, spec, fixture, coverage | TEST | MINIMAL |
| docs, readme, changelog, comment, documentation | DOCS | MINIMAL |
| config, env, setup, feature flag | CONFIG | MINIMAL |
| scaffold, boilerplate, init | SCAFFOLD | SKIM |
| (no keyword match) | SCAFFOLD | SKIM |

### Multi-tag Resolution

- A story can have **multiple tags** (e.g., both SCHEMA and AUTH)
- The **highest-risk tag wins** for the `review` field
- Risk hierarchy: `FULL` > `TARGETED` > `SKIM` > `MINIMAL`

---

## Phase 4: Validate

Run these checks on the generated stories **before writing** `prd.json`.

### Validation Checks

1. **No vague criteria.** Reject stories where ALL criteria are subjective. Vague patterns to flag: "works correctly", "handles edge cases", "is well-structured", "good UX", "user can easily". Each story needs at least one criterion that references a specific file, command, behavior, or assertion.

2. **Size check.** Flag stories with description >200 words or mentioning >5 files. Suggest splitting oversized stories into smaller units.

3. **Schema gate.** If multiple stories have the SCHEMA tag, warn the user and suggest sequential non-overlapping priorities. Concurrent schema changes cause migration conflicts.

4. **Dependency ordering.** Verify no story references output from a higher-numbered (later priority) story. Schema before backend, backend before UI.

### Interactive Gate

**Present the validation summary to the user before writing prd.json.**

Display:
- Total stories extracted
- Stories with warnings or issues
- All validation failures with details
- Tag and review level assignments

Prompt the user with options:
- **y** -- Proceed and write prd.json
- **n** -- Abort without writing
- **edit** -- Let the user modify stories before writing

**Do NOT silently fix problems.** The user's review is the last checkpoint before autonomous execution by Ralph.

---

## Output Format

Write `prd.json` with this schema:

```json
{
  "stories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "What to implement, enriched from proposal.md",
      "acceptance_criteria": [
        "Testable criterion from design.md",
        "Another specific criterion",
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

### Schema Rules

- **NO** top-level `project`, `branchName`, or `description` fields
- **NO** per-story `notes` field
- Field name is `acceptance_criteria` (snake_case), NOT `acceptanceCriteria`
- IDs are sequential: US-001, US-002, US-003, etc.
- Priority matches extraction order from tasks.md (line order)
- All stories start with `"passes": false`

---

## Story Sizing

**Each story must be completable in ONE Ralph iteration (one context window).**

### Right-sized stories:
- Add a database table and migration
- Create a single API endpoint
- Add a UI component to an existing page
- Configure an OAuth provider

### Too big (split these):
- "Build the entire auth system" -- split into schema, middleware, login UI, session handling
- "Add payment integration" -- split into webhook handler, subscription model, billing UI
- "Refactor the API layer" -- split into one story per endpoint

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Edge Cases

### All tasks already checked
If every task in `tasks.md` is checked (`[x]`), inform the user:
> "All tasks in tasks.md are already completed."

Do NOT write an empty prd.json.

### No specs/ directory
Skip silently. Do not log a warning or error.

### No design.md match for a task
Flag the story as **"criteria TBD"** in the validation report. Do not invent criteria. The user must supply them at the interactive gate or accept the gap.

### Typecheck criterion
Always include `"Typecheck passes"` as a criterion for every story, regardless of type.

### UI stories
Always include `"Verify in browser using dev-browser skill"` as a criterion for any story tagged UI.

---

## Example

### Input: tasks.md

```markdown
## 1. Database Schema
- [ ] 1.1 Create users table with Drizzle schema
- [ ] 1.2 Add subscription_tier enum (free, pro, team)

## 2. Auth Setup
- [x] 2.1 Install Better Auth (already done)
- [ ] 2.2 Configure Google OAuth provider

## 3. Dashboard
- [ ] 3.1 Create subscription status card component
```

### Input: proposal.md (excerpt)

```markdown
## Motivation
Users need to authenticate via Google and manage their subscription tier.
The subscription status should be visible on the dashboard at all times.
```

### Input: design.md (excerpt)

```markdown
## Users Table
- id: uuid, primary key
- email: text, unique, not null
- subscription_tier: enum('free', 'pro', 'team'), default 'free'

## Google OAuth
- Use Better Auth Google provider plugin
- Redirect URI: /api/auth/callback/google
- Store provider account ID in auth_accounts table

## Dashboard
- Subscription card shows current tier, upgrade CTA for free users
```

### Output: prd.json

```json
{
  "stories": [
    {
      "id": "US-001",
      "title": "Create users table with Drizzle schema",
      "description": "Create the users table using Drizzle ORM. Users need to authenticate and manage their subscription tier.",
      "acceptance_criteria": [
        "Users table has id (uuid, primary key), email (text, unique, not null), subscription_tier (enum free/pro/team, default free)",
        "Drizzle migration generates and runs successfully",
        "Typecheck passes"
      ],
      "passes": false,
      "priority": 1,
      "review": "FULL",
      "tags": ["SCHEMA"]
    },
    {
      "id": "US-002",
      "title": "Add subscription_tier enum",
      "description": "Define the subscription_tier enum type with values free, pro, and team for use in the users table.",
      "acceptance_criteria": [
        "Enum type subscription_tier exists with values: free, pro, team",
        "Enum is referenced by users.subscription_tier column",
        "Typecheck passes"
      ],
      "passes": false,
      "priority": 2,
      "review": "FULL",
      "tags": ["SCHEMA"]
    },
    {
      "id": "US-003",
      "title": "Configure Google OAuth provider",
      "description": "Set up Google OAuth via Better Auth Google provider plugin so users can sign in with their Google account.",
      "acceptance_criteria": [
        "Better Auth Google provider plugin is configured",
        "Redirect URI set to /api/auth/callback/google",
        "Provider account ID stored in auth_accounts table",
        "Typecheck passes"
      ],
      "passes": false,
      "priority": 3,
      "review": "FULL",
      "tags": ["AUTH"]
    },
    {
      "id": "US-004",
      "title": "Create subscription status card component",
      "description": "Add a dashboard component showing the user's current subscription tier with an upgrade CTA for free-tier users.",
      "acceptance_criteria": [
        "Component displays current subscription tier",
        "Free-tier users see an upgrade CTA",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "passes": false,
      "priority": 4,
      "review": "SKIM",
      "tags": ["UI"]
    }
  ]
}
```

### Validation Summary (shown to user)

```
OpenSpec to Ralph Conversion Summary
=====================================
Source: openspec/changes/my-feature/
Stories extracted: 4 (1 task skipped - already complete)

Story Assignments:
  US-001  SCHEMA  FULL      Create users table with Drizzle schema
  US-002  SCHEMA  FULL      Add subscription_tier enum
  US-003  AUTH    FULL      Configure Google OAuth provider
  US-004  UI      SKIM      Create subscription status card component

Warnings:
  [SCHEMA GATE] US-001 and US-002 both have SCHEMA tag.
  Recommend sequential priorities with non-overlapping migrations.

Issues: 0

Proceed? (y/n/edit)
```

---

## Checklist Before Writing prd.json

Before writing the output file, verify:

- [ ] All unchecked tasks from tasks.md are represented as stories
- [ ] Checked tasks and tasks under checked parents are excluded
- [ ] Descriptions are enriched from proposal.md
- [ ] Acceptance criteria are derived from design.md (not invented)
- [ ] Stories with no design.md match are flagged as "criteria TBD"
- [ ] Every story has "Typecheck passes" as a criterion
- [ ] UI stories have "Verify in browser using dev-browser skill" as a criterion
- [ ] Tags and review levels are assigned per the keyword table
- [ ] Multi-tag stories use the highest-risk review level
- [ ] No vague criteria remain unaddressed
- [ ] Oversized stories are flagged for splitting
- [ ] Schema stories have sequential non-overlapping priorities
- [ ] No story depends on a later-priority story
- [ ] User has reviewed and approved the validation summary
