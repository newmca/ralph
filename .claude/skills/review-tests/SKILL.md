---
name: review-tests
description: "Review test quality after a Ralph agent run or any batch of AI-written tests. Analyzes git diffs for vacuous tests, mock-only tests, happy-path-only coverage, assertion-free tests, snapshot-only tests, and untested public API surface. Use when asked to review tests, check test quality, are these tests good, review ralph tests, or audit test coverage from a commit range."
user-invocable: true
---

# Test Quality Reviewer

Analyzes test quality from a git diff range. Produces a markdown report to stdout identifying weak, vacuous, or missing tests. **This skill is strictly read-only and never modifies any files.**

---

## Input Resolution

The skill accepts an optional argument specifying the commit range to analyze:

| Input | Resolved range |
|---|---|
| *(no argument)* | `git diff main..HEAD` — all changes on the current branch vs main |
| A commit range (e.g. `abc123..def456`) | Used as-is |
| `last commit` or `HEAD~1..HEAD` | Changes in the most recent commit only |

If the resolved diff is empty, output:

```
No changes found in the specified range.
```

And stop.

---

## File Classification

Separate files in the diff into two groups:

**Test files** match any of these patterns:
- `*.test.*` (e.g. `auth.test.ts`, `billing.test.js`)
- `*.spec.*` (e.g. `auth.spec.ts`)
- `__tests__/*`
- `test_*.py`
- `*_test.go`
- `*_test.rs`

**Implementation files** are everything else (excluding non-code files like `.md`, `.json`, `.yml`, `.lock`).

If no test files appear in the diff, output:

```
No test files changed in this range.
```

This is informational, not an error. Still proceed to check for untested public API surface in implementation files.

---

## Analysis Pipeline

### Step 1: Gather the diff

Run `git diff <range>` to collect all changes. Parse the diff to identify:
- Which files were added, modified, or deleted
- The content of changed hunks in each file

### Step 2: Detect the test framework

Inspect imports and syntax in test files to determine the framework:

| Framework | Detection signals |
|---|---|
| **Jest** | `import { expect } from '@jest/globals'`, `jest.mock()`, `jest.fn()`, `describe()`/`it()` with `expect()` |
| **Vitest** | `import { expect, vi } from 'vitest'`, `vi.mock()`, `vi.fn()` |
| **pytest** | `assert` statements, `pytest.raises`, `@pytest.fixture`, files named `test_*.py` |
| **Go testing** | `func Test*(t *testing.T)`, `t.Error()`, `t.Fatal()`, `t.Run()` |
| **PHPUnit** | `$this->assert*()`, `extends TestCase`, `@test` annotations |
| **RSpec** | `describe`/`it` blocks, `expect().to`, files named `*_spec.rb` |

Adapt heuristics to the detected framework throughout the analysis.

### Step 3: Per-test-file analysis

For each test file in the diff, evaluate the following categories:

#### Vacuous Tests

A test is vacuous if it could pass even when the implementation returns a hardcoded value (empty array, `null`, `0`, `"success"`, `true`).

Heuristics:
- Single happy-path call with one input, asserting only the return value with no variation
- Test calls a function once and checks `toBeTruthy()` or `not.toThrow()`
- Test asserts only that a function "was called" without checking behavior

Do NOT flag tests that are genuinely integration tests hitting real APIs or databases just because they have simple assertions.

#### Mock-Only Tests

The test mocks the module under test (not just its dependencies) and then asserts on mock return values.

Heuristics:
- `jest.mock('../../lib/foo')` or `vi.mock('../../lib/foo')` where `foo` is also the module being imported and tested
- The test asserts on values that come directly from mock implementations, not from the real code
- All assertions check `.toHaveBeenCalled()` or `.toHaveBeenCalledWith()` on mocks of the unit under test

Mocking *dependencies* of the unit under test is normal and should not be flagged.

#### Happy-Path-Only Coverage

The test file contains zero negative tests — no error cases, invalid input, boundary conditions, or expected throws/rejections.

Heuristics:
- No `expect(...).toThrow()`, `expect(...).rejects`, `pytest.raises`, `t.Fatal` with error scenarios
- No test names containing words like "error", "invalid", "fail", "reject", "empty", "missing", "unauthorized", "404", "boundary", "edge"
- All test inputs are valid, well-formed data

#### Assertion-Free Tests

An individual test case (`it()`, `test()`, `def test_*`, `func Test*`) contains zero assertion calls.

Detection per framework:
- **Jest/Vitest**: No `expect()` calls inside `it()` or `test()`
- **pytest**: No `assert` statements inside `def test_*`
- **Go**: No `t.Error()`, `t.Fatal()`, `t.Errorf()`, or assertion library calls inside `func Test*`

#### Snapshot-Only Tests

The test relies exclusively on `.toMatchSnapshot()` or `.toMatchInlineSnapshot()` with no behavioral assertions.

Flag as low-confidence coverage — snapshots catch regressions but do not verify correctness of new code.

### Step 4: Cross-reference implementation and tests

#### Untested Public API Surface

For each new or modified function, method, class, or export in the implementation diff, check whether any test file in the diff covers it.

Detection:
- **JS/TS**: `export function`, `export const`, `export class`, `export default`, `module.exports`
- **Python**: Top-level `def` and `class` in non-underscore-prefixed modules
- **Go**: Capitalized function/method names (exported)
- **PHP**: `public function` methods

Report each exported symbol that has no corresponding test.

#### Uncovered Branches

For each conditional in changed implementation code, check whether tests exercise both branches:
- `if/else`, `if` without `else`
- `switch/case`
- `try/catch`
- Ternary operators (`? :`)
- Optional chaining (`?.`) and nullish coalescing (`??`)

Report these as **suggestions**, not hard flags. Branch analysis from diffs alone is inherently imprecise.

---

## Output Format

The report MUST follow this exact structure. Omit sections that have zero findings (except Summary, which is always present).

```markdown
## Test Quality Review — [commit range]

### Critical (likely to miss real bugs)
- :red_circle: `src/lib/auth.test.ts`: `test("creates session")` — mocks the session creator and asserts on the mock return value. This test will pass even if createSession is completely broken.

### Warning (incomplete coverage)
- :yellow_circle: `src/lib/payments.test.ts`: No negative tests. All 4 tests use valid input. Missing: invalid card, expired subscription, webhook signature mismatch.

### Untested public API
- :green_circle: `src/lib/auth.ts`: `revokeSession()` — exported but no test covers it.

### Uncovered branches
- `src/payments/billing.ts:67` — `if (subscription.status === 'canceled')` branch not tested

### Summary
- Files reviewed: N test files, M source files
- Critical flags: N
- Warnings: N
- Untested exports: N
- Uncovered branches: N
```

Use the following markers:
- :red_circle: for Critical items
- :yellow_circle: for Warning items
- :green_circle: for Untested API items

---

## Execution Model

**Primary mode**: Spawn an Opus sub-agent for the analysis using the Agent tool with the appropriate `subagent_type` for reasoning quality. Pass the diff content and these analysis instructions to the sub-agent.

**Fallback mode**: If sub-agents are unavailable, run the analysis inline. Note reduced analysis depth in the report header:

```markdown
> Note: Analysis performed inline without sub-agent. Depth may be reduced.
```

---

## Constraints

1. **Strictly read-only.** This skill MUST NOT modify, create, or delete any files. It reads git diffs and outputs a report to stdout. Nothing else.
2. **Diff-scoped analysis.** Only files changed in the specified commit range are analyzed. Pre-existing test files that were not modified are out of scope. State this limitation in the report if relevant.
3. **No false positives on integration tests.** Tests that hit real APIs, databases, or services should not be flagged as "vacuous" simply because they have straightforward assertions. Look for real database connections, HTTP calls without mocks, or test fixtures that indicate integration testing.
4. **Framework-aware.** Adapt all heuristics to the detected test framework. Do not apply Jest-specific patterns to pytest files or vice versa.

---

## Trigger Phrases

- "review tests"
- "check test quality"
- "are these tests good"
- "review ralph tests"
- "audit test coverage"

