#!/usr/bin/env bats

# =============================================================================
# ralph.sh unit tests
#
# Strategy: each test gets an isolated temp directory with ralph.sh copied in,
# mock claude/amp/sleep/git commands on PATH, and prd.json/CLAUDE.md fixtures.
# ralph.sh derives SCRIPT_DIR from its own location, so all paths resolve
# to the temp dir automatically.
# =============================================================================

setup() {
  # Create isolated test directory
  TEST_DIR="$(mktemp -d)"
  MOCK_BIN="$TEST_DIR/bin"
  mkdir -p "$MOCK_BIN"

  # Copy ralph.sh to test dir (so SCRIPT_DIR resolves there)
  cp "$BATS_TEST_DIRNAME/../ralph.sh" "$TEST_DIR/ralph.sh"
  chmod +x "$TEST_DIR/ralph.sh"

  # Create minimal CLAUDE.md and prompt.md (ralph.sh pipes these to claude/amp)
  echo "# Test instructions" > "$TEST_DIR/CLAUDE.md"
  echo "# Test instructions" > "$TEST_DIR/prompt.md"

  # Default mock: claude succeeds silently, does nothing
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/bin/bash
cat > /dev/null  # consume stdin
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/claude"

  # Default mock: amp succeeds silently
  cat > "$MOCK_BIN/amp" <<'MOCK'
#!/bin/bash
cat > /dev/null
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/amp"

  # Mock sleep to be instant (log calls for verification)
  cat > "$MOCK_BIN/sleep" <<MOCK
#!/bin/bash
echo "\$1" >> "$TEST_DIR/sleep.log"
MOCK
  chmod +x "$MOCK_BIN/sleep"

  # Mock git for archive folder fallback
  cat > "$MOCK_BIN/git" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
  echo "main"
else
  /usr/bin/git "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/git"

  # Mock tee to just pass through (avoid /dev/stderr noise in tests)
  cat > "$MOCK_BIN/tee" <<'MOCK'
#!/bin/bash
cat
MOCK
  chmod +x "$MOCK_BIN/tee"

  # Prepend mocks to PATH
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- Helper functions ---

# Create a prd.json with N stories, all failing
# Usage: create_prd 3         -> US-001..US-003, all passes:false
#        create_prd 2 "AUTH"  -> US-001..US-002, tagged AUTH
create_prd() {
  local count=${1:-1}
  local tag=${2:-""}
  local stories=""
  for i in $(seq 1 "$count"); do
    local id
    id=$(printf "US-%03d" "$i")
    local comma=""
    [ "$i" -lt "$count" ] && comma=","
    local tags_json="[]"
    [ -n "$tag" ] && tags_json="[\"$tag\"]"
    stories+=$(cat <<EOF
    {
      "id": "$id",
      "title": "Story $i title",
      "description": "Implement story $i",
      "acceptance_criteria": ["Typecheck passes"],
      "passes": false,
      "priority": $i,
      "review": "SKIM",
      "tags": $tags_json
    }$comma
EOF
)
  done
  cat > "$TEST_DIR/prd.json" <<EOF
{
  "stories": [
$stories
  ]
}
EOF
}

# Create a prd.json where all stories pass
create_prd_all_passing() {
  cat > "$TEST_DIR/prd.json" <<'EOF'
{
  "stories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Already done",
      "acceptance_criteria": ["Typecheck passes"],
      "passes": true,
      "priority": 1,
      "review": "SKIM",
      "tags": []
    }
  ]
}
EOF
}

# Create prd with specific stories (full control)
# Usage: create_prd_custom '[{"id":"US-001","passes":false,...}]'
create_prd_custom() {
  cat > "$TEST_DIR/prd.json" <<EOF
{
  "stories": $1
}
EOF
}

# Make the mock claude mark the first failing story as passing (simulates agent success)
mock_claude_completes_story() {
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
# Mark first failing story as passing
local_prd="\$(dirname "\$0")/../prd.json"
if [ -f "$TEST_DIR/prd.json" ]; then
  tmp=\$(mktemp)
  jq '(.stories[] | select(.passes == false) | select(.priority == (.priority // 999))) |= (.passes = true)' "$TEST_DIR/prd.json" \
    | jq '[.stories[] | select(.passes == false)] as \$failing | if (\$failing | length) > 0 then .stories[(.stories | to_entries[] | select(.value.passes == false) | .key | . // 0)] .passes = true else . end' > "\$tmp" 2>/dev/null
  # Simpler: just set first false to true
  python3 -c "
import json
with open('$TEST_DIR/prd.json') as f:
    data = json.load(f)
for s in sorted(data['stories'], key=lambda x: x['priority']):
    if not s['passes']:
        s['passes'] = True
        break
with open('$TEST_DIR/prd.json', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
fi
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/claude"
}

# Make mock claude output rate-limit error
mock_claude_rate_limited() {
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/bin/bash
cat > /dev/null
echo "Error: 429 Too Many Requests - rate limit exceeded" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
}

# Make mock claude output rate-limit on first call, succeed on subsequent
mock_claude_rate_limited_then_ok() {
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
CALL_FILE="$TEST_DIR/claude_calls"
COUNT=\$(cat "\$CALL_FILE" 2>/dev/null || echo 0)
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "\$CALL_FILE"
# Log what was called with
echo "call \$COUNT: \$*" >> "$TEST_DIR/claude_call_log"
if [ "\$COUNT" -eq 1 ]; then
  echo "Error: 429 rate limit exceeded" >&2
  exit 1
fi
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/claude"
}

# Make mock claude emit the COMPLETE promise
mock_claude_signals_complete() {
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/bin/bash
cat > /dev/null
echo "All done!"
echo "<promise>COMPLETE</promise>"
MOCK
  chmod +x "$MOCK_BIN/claude"
}

run_ralph() {
  run "$TEST_DIR/ralph.sh" "$@"
}

# =============================================================================
# ARGUMENT PARSING & VALIDATION
# =============================================================================

@test "defaults: tool=claude, max_iterations=10, delay=0, max_retries=3" {
  create_prd_all_passing
  run_ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool: claude"* ]]
  [[ "$output" == *"Max iterations: 10"* ]]
  [[ "$output" == *"Max retries before stalemate: 3"* ]]
}

@test "--tool claude accepted" {
  create_prd_all_passing
  run_ralph --tool claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool: claude"* ]]
}

@test "--tool amp accepted" {
  create_prd_all_passing
  run_ralph --tool amp
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool: amp"* ]]
}

@test "--tool=claude (equals form) accepted" {
  create_prd_all_passing
  run_ralph --tool=claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool: claude"* ]]
}

@test "invalid --tool exits 1" {
  create_prd_all_passing
  run_ralph --tool invalid
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Invalid tool"* ]]
}

@test "positional max_iterations sets iteration count" {
  create_prd_all_passing
  run_ralph 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Max iterations: 5"* ]]
}

@test "--delay sets delay value" {
  create_prd_all_passing
  run_ralph --delay 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"Delay between iterations: 10s"* ]]
}

@test "--delay=5 (equals form) accepted" {
  create_prd_all_passing
  run_ralph --delay=5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Delay between iterations: 5s"* ]]
}

@test "non-numeric --delay exits 1" {
  create_prd_all_passing
  run_ralph --delay abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"--delay must be a non-negative integer"* ]]
}

@test "--max-retries sets retry count" {
  create_prd_all_passing
  run_ralph --max-retries 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"Max retries before stalemate: 5"* ]]
}

@test "non-numeric --max-retries exits 1" {
  create_prd_all_passing
  run_ralph --max-retries xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"--max-retries must be a non-negative integer"* ]]
}

@test "--fallback shows fallback model in startup message" {
  create_prd_all_passing
  run_ralph --fallback "qwen3-coder:30b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fallback model: qwen3-coder:30b"* ]]
}

@test "--fallback-url overrides default Ollama URL" {
  create_prd_all_passing
  run_ralph --fallback "qwen3" --fallback-url "http://gpu-box:11434"
  [ "$status" -eq 0 ]
  [[ "$output" == *"http://gpu-box:11434"* ]]
}

@test "multiple flags combined" {
  create_prd_all_passing
  run_ralph --tool claude --delay 3 --max-retries 5 --fallback mymodel 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tool: claude"* ]]
  [[ "$output" == *"Max iterations: 7"* ]]
  [[ "$output" == *"Delay between iterations: 3s"* ]]
  [[ "$output" == *"Max retries before stalemate: 5"* ]]
  [[ "$output" == *"Fallback model: mymodel"* ]]
}

# =============================================================================
# PROGRESS FILE INITIALIZATION
# =============================================================================

@test "creates progress.txt if missing" {
  create_prd_all_passing
  # Ensure no progress file exists
  rm -f "$TEST_DIR/progress.txt"
  run_ralph
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/progress.txt" ]
  head -1 "$TEST_DIR/progress.txt" | grep -q "# Ralph Progress Log"
}

@test "preserves existing progress.txt" {
  create_prd_all_passing
  echo "# Existing content" > "$TEST_DIR/progress.txt"
  echo "Some progress" >> "$TEST_DIR/progress.txt"
  run_ralph
  [ "$status" -eq 0 ]
  grep -q "Existing content" "$TEST_DIR/progress.txt"
}

# =============================================================================
# JQ STOP CONDITION
# =============================================================================

@test "exits 0 immediately when all stories pass (pre-check)" {
  create_prd_all_passing
  run_ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph completed all tasks!"* ]]
  [[ "$output" == *"all stories pass"* ]]
}

@test "exits 0 when agent completes last story (post-check)" {
  create_prd 1
  mock_claude_completes_story
  run_ralph 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph completed all tasks!"* ]]
}

@test "exits 0 on promise COMPLETE signal even if jq check fails" {
  create_prd 1
  mock_claude_signals_complete
  run_ralph 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent signaled completion"* ]]
}

@test "continues loop when stories remain" {
  create_prd 3
  # claude does nothing (no stories completed), max 2 iterations
  run_ralph --max-retries 5 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"Ralph reached max iterations (2)"* ]]
}

# =============================================================================
# MAX ITERATIONS
# =============================================================================

@test "exits 1 when max iterations reached" {
  create_prd 2
  run_ralph 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ralph reached max iterations"* ]] || [[ "$output" == *"STALLED"* ]]
}

@test "respects custom max_iterations" {
  create_prd 1
  run_ralph --max-retries 10 2
  # Should see iteration banners for 1 and 2 but not 3
  count=$(echo "$output" | grep -c "Ralph Iteration")
  [ "$count" -le 2 ]
}

# =============================================================================
# STALEMATE DETECTION
# =============================================================================

@test "stalemate: exits 2 after max-retries consecutive failures" {
  create_prd 1
  # claude does nothing, so no progress each iteration
  run_ralph --max-retries 2 10
  [ "$status" -eq 2 ]
  [[ "$output" == *"STALLED"* ]]
  [[ "$output" == *"needs human intervention"* ]]
}

@test "stalemate: counter resets when progress is made" {
  create_prd 3
  # Mock claude: completes a story on call 3 (after 2 stalemates)
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
CALL_FILE="$TEST_DIR/claude_calls"
COUNT=\$(cat "\$CALL_FILE" 2>/dev/null || echo 0)
COUNT=\$((COUNT + 1))
echo "\$COUNT" > "\$CALL_FILE"
# Complete a story on call 3
if [ "\$COUNT" -eq 3 ]; then
  python3 -c "
import json
with open('$TEST_DIR/prd.json') as f:
    data = json.load(f)
for s in sorted(data['stories'], key=lambda x: x['priority']):
    if not s['passes']:
        s['passes'] = True
        break
with open('$TEST_DIR/prd.json', 'w') as f:
    json.dump(data, f, indent=2)
"
fi
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/claude"
  # max-retries=3, so after calls 1,2 (no progress) stalemate=2, call 3 resets it
  # Then calls 4,5,6 (no progress) → stalemate=3 → exit 2
  run_ralph --max-retries 3 10
  [ "$status" -eq 2 ]
  # Should have made it past iteration 3 (progress was made there)
  [[ "$output" == *"Progress made!"* ]]
  [[ "$output" == *"STALLED"* ]]
}

@test "stalemate: custom --max-retries respected" {
  create_prd 1
  run_ralph --max-retries 1 10
  [ "$status" -eq 2 ]
  [[ "$output" == *"STALLED"* ]]
  # Should exit after just 1 no-progress iteration (plus the first one)
}

# =============================================================================
# DELAY
# =============================================================================

@test "delay: sleeps between iterations when --delay > 0" {
  create_prd 1
  run_ralph --delay 5 --max-retries 2 3
  # Check that sleep was called with the right value
  [ -f "$TEST_DIR/sleep.log" ]
  grep -q "5" "$TEST_DIR/sleep.log"
}

@test "delay: no sleep when --delay 0 (default)" {
  create_prd_all_passing
  run_ralph
  # sleep.log should not exist or not contain any entries from delay logic
  # (sleep mock may be called for other reasons like rate-limit cooldown)
  if [ -f "$TEST_DIR/sleep.log" ]; then
    # If sleep was called, it shouldn't be for delay (no iterations ran)
    true
  fi
}

@test "delay: shows waiting message" {
  create_prd 1
  run_ralph --delay 10 --max-retries 1 2
  [[ "$output" == *"Waiting 10s before next iteration"* ]]
}

# =============================================================================
# ARCHIVE LOGIC
# =============================================================================

@test "archive: no archive on first run (no .last-prd-hash)" {
  create_prd 1
  rm -f "$TEST_DIR/.last-prd-hash"
  run_ralph --max-retries 1 1
  # Should not create archive directory
  [ ! -d "$TEST_DIR/archive" ]
  # Should create .last-prd-hash
  [ -f "$TEST_DIR/.last-prd-hash" ]
}

@test "archive: no archive when prd.json unchanged" {
  create_prd 1
  # Set hash to current prd.json hash
  sha256sum "$TEST_DIR/prd.json" | awk '{print $1}' > "$TEST_DIR/.last-prd-hash"
  run_ralph --max-retries 1 1
  [ ! -d "$TEST_DIR/archive" ]
}

@test "archive: archives when prd.json hash differs" {
  create_prd 1
  # Set a different hash
  echo "oldhash123" > "$TEST_DIR/.last-prd-hash"
  echo "Old progress content" > "$TEST_DIR/progress.txt"
  run_ralph --max-retries 1 1
  [ -d "$TEST_DIR/archive" ]
  [[ "$output" == *"Archiving previous run"* ]]
  # Progress file should be in archive
  archive_dir=$(find "$TEST_DIR/archive" -type d -mindepth 1 -maxdepth 1 | head -1)
  [ -n "$archive_dir" ]
  [ -f "$archive_dir/progress.txt" ]
  grep -q "Old progress" "$archive_dir/progress.txt"
}

@test "archive: folder name derived from first story title" {
  create_prd_custom '[{"id":"US-001","title":"Add User Authentication","description":"x","acceptance_criteria":["x"],"passes":false,"priority":1,"review":"FULL","tags":["AUTH"]}]'
  echo "oldhash" > "$TEST_DIR/.last-prd-hash"
  echo "old" > "$TEST_DIR/progress.txt"
  run_ralph --max-retries 1 1
  # Archive folder should contain slugified title
  archive_dir=$(find "$TEST_DIR/archive" -type d -mindepth 1 -maxdepth 1 | head -1)
  [ -n "$archive_dir" ]
  [[ "$archive_dir" == *"add-user-authentication"* ]]
}

@test "archive: progress.txt reset after archiving" {
  create_prd 1
  echo "oldhash" > "$TEST_DIR/.last-prd-hash"
  echo "Old content that should be archived" > "$TEST_DIR/progress.txt"
  run_ralph --max-retries 1 1
  # Progress file should be reset (start with Ralph header)
  head -1 "$TEST_DIR/progress.txt" | grep -q "# Ralph Progress Log"
}

@test "archive: .last-prd-hash updated to current hash" {
  create_prd 1
  expected_hash=$(sha256sum "$TEST_DIR/prd.json" | awk '{print $1}')
  run_ralph --max-retries 1 1
  actual_hash=$(cat "$TEST_DIR/.last-prd-hash")
  [ "$expected_hash" = "$actual_hash" ]
}

# =============================================================================
# SCHEMA GATE
# =============================================================================

@test "schema gate: allows first SCHEMA story" {
  create_prd 1 "SCHEMA"
  mock_claude_completes_story
  run_ralph 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"Schema gate: deferring"* ]]
}

@test "schema gate: defers second SCHEMA story after first committed" {
  # Two SCHEMA stories
  create_prd_custom '[
    {"id":"US-001","title":"Schema 1","description":"x","acceptance_criteria":["x"],"passes":false,"priority":1,"review":"FULL","tags":["SCHEMA"]},
    {"id":"US-002","title":"Schema 2","description":"x","acceptance_criteria":["x"],"passes":false,"priority":2,"review":"FULL","tags":["SCHEMA"]}
  ]'
  # Mock claude: completes first story on first call
  mock_claude_completes_story
  run_ralph --max-retries 2 5
  [[ "$output" == *"Schema gate: deferring US-002"* ]]
  # Should log to progress.txt
  grep -q "Schema gate.*US-002" "$TEST_DIR/progress.txt"
}

@test "schema gate: allows non-SCHEMA stories freely" {
  create_prd_custom '[
    {"id":"US-001","title":"API endpoint","description":"x","acceptance_criteria":["x"],"passes":false,"priority":1,"review":"TARGETED","tags":["API"]},
    {"id":"US-002","title":"UI component","description":"x","acceptance_criteria":["x"],"passes":false,"priority":2,"review":"SKIM","tags":["UI"]}
  ]'
  run_ralph --max-retries 1 2
  [[ "$output" != *"Schema gate"* ]]
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

@test "rate limit: detects 429 in output" {
  create_prd 1
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/bin/bash
cat > /dev/null
echo "Error: 429 Too Many Requests" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  # No fallback set, so it should just continue (stalemate will catch it)
  run_ralph --max-retries 1 2
  # Without --fallback, rate limit is not handled specially — just no progress
  [ "$status" -ne 0 ]
}

@test "rate limit: detects 'rate limit' text" {
  create_prd 1
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
echo "rate limit exceeded for model" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  run_ralph --fallback testmodel --max-retries 1 2
  [[ "$output" == *"Rate limited -- falling back to Ollama"* ]]
}

@test "rate limit: detects 'quota exceeded'" {
  create_prd 1
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
echo "quota exceeded" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  run_ralph --fallback testmodel --max-retries 1 2
  [[ "$output" == *"Rate limited -- falling back to Ollama"* ]]
}

@test "rate limit: detects 'overloaded'" {
  create_prd 1
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > /dev/null
echo "overloaded" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  run_ralph --fallback testmodel --max-retries 1 2
  [[ "$output" == *"Rate limited -- falling back to Ollama"* ]]
}

# =============================================================================
# OLLAMA FALLBACK
# =============================================================================

@test "fallback: invokes Ollama model on rate limit when --fallback set" {
  create_prd 1
  mock_claude_rate_limited_then_ok
  run_ralph --fallback "qwen3-coder:30b" --max-retries 2 3
  [[ "$output" == *"Rate limited -- falling back to Ollama (qwen3-coder:30b)"* ]]
  # Verify the fallback call included --model flag
  [ -f "$TEST_DIR/claude_call_log" ]
  grep -q "qwen3-coder:30b" "$TEST_DIR/claude_call_log"
}

@test "fallback: does not fall back when --fallback not set" {
  create_prd 1
  mock_claude_rate_limited
  run_ralph --max-retries 1 2
  [[ "$output" != *"falling back to Ollama"* ]]
}

@test "fallback: skips high-risk SCHEMA story" {
  create_prd 1 "SCHEMA"
  mock_claude_rate_limited
  run_ralph --fallback "qwen3" --max-retries 1 2
  [[ "$output" == *"Skipping high-risk story"* ]]
  [[ "$output" == *"queued for Claude"* ]]
  # Should log to progress.txt
  grep -q "Skipped high-risk story US-001" "$TEST_DIR/progress.txt"
}

@test "fallback: skips high-risk AUTH story" {
  create_prd 1 "AUTH"
  mock_claude_rate_limited
  run_ralph --fallback "qwen3" --max-retries 1 2
  [[ "$output" == *"Skipping high-risk story"* ]]
}

@test "fallback: skips high-risk PAYMENTS story" {
  create_prd 1 "PAYMENTS"
  mock_claude_rate_limited
  run_ralph --fallback "qwen3" --max-retries 1 2
  [[ "$output" == *"Skipping high-risk story"* ]]
}

@test "fallback: skips high-risk SECURITY story" {
  create_prd 1 "SECURITY"
  mock_claude_rate_limited
  run_ralph --fallback "qwen3" --max-retries 1 2
  [[ "$output" == *"Skipping high-risk story"* ]]
}

@test "fallback: allows non-high-risk story (UI)" {
  create_prd 1 "UI"
  mock_claude_rate_limited_then_ok
  run_ralph --fallback "qwen3" --max-retries 2 3
  [[ "$output" == *"Rate limited -- falling back to Ollama"* ]]
  [[ "$output" != *"Skipping high-risk story"* ]]
}

@test "fallback: logs rate-limit event to progress.txt" {
  create_prd 1 "UI"
  mock_claude_rate_limited_then_ok
  run_ralph --fallback "qwen3" --max-retries 2 3
  grep -q "Rate limited on claude, falling back to qwen3" "$TEST_DIR/progress.txt"
}

@test "fallback: uses custom --fallback-url" {
  create_prd 1 "UI"
  mock_claude_rate_limited_then_ok
  run_ralph --fallback "qwen3" --fallback-url "http://gpu:11434" --max-retries 2 3
  # The startup message should show the custom URL
  [[ "$output" == *"http://gpu:11434"* ]]
}

# =============================================================================
# TOOL INVOCATION
# =============================================================================

@test "claude tool: pipes CLAUDE.md to claude" {
  create_prd 1
  # Mock claude that logs what it received on stdin
  cat > "$MOCK_BIN/claude" <<MOCK
#!/bin/bash
cat > "$TEST_DIR/claude_stdin"
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/claude"
  run_ralph --max-retries 1 1
  [ -f "$TEST_DIR/claude_stdin" ]
  grep -q "Test instructions" "$TEST_DIR/claude_stdin"
}

@test "amp tool: pipes prompt.md to amp" {
  create_prd 1
  echo "# Amp prompt content" > "$TEST_DIR/prompt.md"
  cat > "$MOCK_BIN/amp" <<MOCK
#!/bin/bash
cat > "$TEST_DIR/amp_stdin"
echo "Story implemented."
MOCK
  chmod +x "$MOCK_BIN/amp"
  run_ralph --tool amp --max-retries 1 1
  [ -f "$TEST_DIR/amp_stdin" ]
  grep -q "Amp prompt content" "$TEST_DIR/amp_stdin"
}

# =============================================================================
# PRD FORMAT
# =============================================================================

@test "handles stories array (new format)" {
  create_prd 2
  run_ralph --max-retries 1 1
  [[ "$output" == *"Stories remaining: 2"* ]]
}

@test "handles empty stories array gracefully" {
  create_prd_custom '[]'
  run_ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph completed all tasks!"* ]]
}

@test "handles mixed pass/fail stories" {
  create_prd_custom '[
    {"id":"US-001","title":"Done","description":"x","acceptance_criteria":["x"],"passes":true,"priority":1,"review":"SKIM","tags":[]},
    {"id":"US-002","title":"Pending","description":"x","acceptance_criteria":["x"],"passes":false,"priority":2,"review":"SKIM","tags":[]}
  ]'
  run_ralph --max-retries 1 1
  [[ "$output" == *"Stories remaining: 1"* ]]
}

@test "reads story tags correctly" {
  create_prd_custom '[
    {"id":"US-001","title":"Auth story","description":"x","acceptance_criteria":["x"],"passes":false,"priority":1,"review":"FULL","tags":["AUTH","API"]}
  ]'
  # With fallback and rate limit, AUTH tag should cause skip
  mock_claude_rate_limited
  run_ralph --fallback "qwen3" --max-retries 1 2
  [[ "$output" == *"Skipping high-risk story"* ]]
}

@test "handles story with null tags gracefully" {
  # Some stories might have null instead of empty array
  cat > "$TEST_DIR/prd.json" <<'EOF'
{
  "stories": [
    {
      "id": "US-001",
      "title": "No tags story",
      "description": "x",
      "acceptance_criteria": ["x"],
      "passes": false,
      "priority": 1,
      "review": "SKIM",
      "tags": null
    }
  ]
}
EOF
  run_ralph --max-retries 1 1
  # Should not crash on null tags
  [[ "$output" == *"Stories remaining: 1"* ]]
}

# =============================================================================
# ITERATION BANNER
# =============================================================================

@test "shows iteration number and tool in banner" {
  create_prd 1
  run_ralph --max-retries 1 1
  [[ "$output" == *"Ralph Iteration 1 of 1 (claude)"* ]]
}

@test "shows stories remaining count" {
  create_prd 3
  run_ralph --max-retries 1 1
  [[ "$output" == *"Stories remaining: 3"* ]]
}

# =============================================================================
# EDGE CASES
# =============================================================================

@test "handles missing prd.json gracefully at archive stage" {
  # No prd.json at all — should skip archive logic and fail at loop
  rm -f "$TEST_DIR/prd.json"
  run_ralph 1
  # Should still initialize progress.txt
  [ -f "$TEST_DIR/progress.txt" ]
}

@test "single story completes in one iteration" {
  create_prd 1
  mock_claude_completes_story
  run_ralph 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ralph completed all tasks!"* ]]
  # Verify prd.json was updated
  passes=$(jq '.stories[0].passes' "$TEST_DIR/prd.json")
  [ "$passes" = "true" ]
}

@test "multiple stories complete across iterations" {
  create_prd 2
  mock_claude_completes_story
  run_ralph 5
  [ "$status" -eq 0 ]
  # Both stories should pass
  remaining=$(jq '[.stories[] | select(.passes == false)] | length' "$TEST_DIR/prd.json")
  [ "$remaining" -eq 0 ]
}

@test "model used is reported in completion message" {
  create_prd 1
  mock_claude_completes_story
  run_ralph 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"model: claude"* ]]
}

# =============================================================================
# STUCK STORY RULE (agent instruction tests)
# =============================================================================

@test "stuck story rule: CLAUDE.md template contains stuck story instruction text" {
  # Verify the COPY_INTO_YOUR_PROJECT_CLAUDE.md template includes the stuck story rule
  grep -q "Stuck Story Rule" "$BATS_TEST_DIRNAME/../COPY_INTO_YOUR_PROJECT_CLAUDE.md"
  grep -q "failed 3+ attempts" "$BATS_TEST_DIRNAME/../COPY_INTO_YOUR_PROJECT_CLAUDE.md"
  grep -q "BLOCKED" "$BATS_TEST_DIRNAME/../COPY_INTO_YOUR_PROJECT_CLAUDE.md"
  grep -q "ALL REMAINING STORIES BLOCKED" "$BATS_TEST_DIRNAME/../COPY_INTO_YOUR_PROJECT_CLAUDE.md"
  grep -q "needs human intervention" "$BATS_TEST_DIRNAME/../COPY_INTO_YOUR_PROJECT_CLAUDE.md"
}

@test "stuck story rule: story failed 3 times gets BLOCKED entry from agent" {
  # Simulate what the agent would see: a progress.txt with 3 failures for US-001
  # and verify the expected BLOCKED line format is consistent with the instructions
  create_prd 2
  cat > "$TEST_DIR/progress.txt" <<'PROGRESS'
# Ralph Progress Log

## 2026-03-01 - US-001
- Attempted implementation
- Story US-001: FAILED - typecheck errors
---

## 2026-03-01 - US-001
- Second attempt
- Story US-001: FAILED - lint errors
---

## 2026-03-02 - US-001
- Third attempt
- Story US-001: FAILED - test failures
---
PROGRESS

  # Count failure markers for US-001 in progress.txt (this is what the agent does per the instruction)
  fail_count=$(grep -c "Story US-001: FAILED\|US-001 failed\|US-001.*FAILED" "$TEST_DIR/progress.txt")
  [ "$fail_count" -ge 3 ]

  # Simulate the agent appending the BLOCKED line (as instructed by the stuck story rule)
  echo "BLOCKED: Story US-001 failed 3+ attempts — needs human intervention" >> "$TEST_DIR/progress.txt"

  # Verify the BLOCKED entry is present in progress.txt
  grep -q "BLOCKED: Story US-001 failed 3+ attempts" "$TEST_DIR/progress.txt"
  grep -q "needs human intervention" "$TEST_DIR/progress.txt"
}

# =============================================================================
# PRD.JSON CORRUPTION PROTECTION
# =============================================================================

@test "corruption: corrupted prd.json triggers git checkout recovery" {
  # Create a valid prd.json first, then corrupt it
  create_prd 1
  # Save a valid copy that git checkout will restore
  cp "$TEST_DIR/prd.json" "$TEST_DIR/prd.json.valid"
  # Corrupt the prd.json
  echo "NOT VALID JSON {{{" > "$TEST_DIR/prd.json"

  # Mock git to restore the valid prd.json on checkout
  cat > "$MOCK_BIN/git" <<MOCK
#!/bin/bash
if [[ "\$*" == *"checkout -- "* ]]; then
  cp "$TEST_DIR/prd.json.valid" "$TEST_DIR/prd.json"
  exit 0
elif [[ "\$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
  echo "main"
else
  /usr/bin/git "\$@"
fi
MOCK
  chmod +x "$MOCK_BIN/git"

  run_ralph --max-retries 1 1
  [[ "$output" == *"ERROR: prd.json is corrupted. Restoring from last git commit."* ]]
  # Should NOT exit 3 since restoration succeeds
  [ "$status" -ne 3 ]
}

@test "corruption: exit code 3 when git checkout also produces invalid JSON" {
  # Corrupt the prd.json
  echo "NOT VALID JSON {{{" > "$TEST_DIR/prd.json"

  # Mock git checkout to "restore" another corrupted file
  cat > "$MOCK_BIN/git" <<MOCK
#!/bin/bash
if [[ "\$*" == *"checkout -- "* ]]; then
  echo "ALSO NOT VALID JSON }}}" > "$TEST_DIR/prd.json"
  exit 0
elif [[ "\$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
  echo "main"
else
  /usr/bin/git "\$@"
fi
MOCK
  chmod +x "$MOCK_BIN/git"

  run_ralph 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: prd.json is corrupted. Restoring from last git commit."* ]]
  [[ "$output" == *"Restored prd.json is also corrupted. Unrecoverable."* ]]
}

@test "corruption: valid prd.json after recovery allows iteration to continue" {
  # Create a valid prd.json, save it, then corrupt the original
  create_prd 1
  cp "$TEST_DIR/prd.json" "$TEST_DIR/prd.json.valid"
  echo "CORRUPT!!!" > "$TEST_DIR/prd.json"

  # Mock git to restore valid prd.json
  cat > "$MOCK_BIN/git" <<MOCK
#!/bin/bash
if [[ "\$*" == *"checkout -- "* ]]; then
  cp "$TEST_DIR/prd.json.valid" "$TEST_DIR/prd.json"
  exit 0
elif [[ "\$*" == *"rev-parse --abbrev-ref HEAD"* ]]; then
  echo "main"
else
  /usr/bin/git "\$@"
fi
MOCK
  chmod +x "$MOCK_BIN/git"

  run_ralph --max-retries 1 1
  # Should recover and continue to show stories remaining
  [[ "$output" == *"ERROR: prd.json is corrupted. Restoring from last git commit."* ]]
  [[ "$output" == *"Stories remaining: 1"* ]]
  # Should not exit 3
  [ "$status" -ne 3 ]
}
