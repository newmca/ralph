#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude] [--fallback <model>] [--fallback-url <url>] [--delay <seconds>] [--max-retries <n>] [max_iterations]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_HASH_FILE="$SCRIPT_DIR/.last-prd-hash"

# Defaults
TOOL="claude"
MAX_ITERATIONS=10
FALLBACK_MODEL=""
FALLBACK_URL="http://localhost:11434"
DELAY=0
MAX_RETRIES=3

# High-risk tags that should not run on fallback models
HIGH_RISK_TAGS="SCHEMA AUTH PAYMENTS SECURITY"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --fallback)
      FALLBACK_MODEL="$2"
      shift 2
      ;;
    --fallback=*)
      FALLBACK_MODEL="${1#*=}"
      shift
      ;;
    --fallback-url)
      FALLBACK_URL="$2"
      shift 2
      ;;
    --fallback-url=*)
      FALLBACK_URL="${1#*=}"
      shift
      ;;
    --delay)
      DELAY="$2"
      shift 2
      ;;
    --delay=*)
      DELAY="${1#*=}"
      shift
      ;;
    --max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    --max-retries=*)
      MAX_RETRIES="${1#*=}"
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi

# Validate numeric arguments
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
  echo "Error: --delay must be a non-negative integer."
  exit 1
fi

if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-retries must be a non-negative integer."
  exit 1
fi

# --- Archive logic: detect PRD changes via content hash ---
if [ -f "$PRD_FILE" ]; then
  CURRENT_HASH=$(sha256sum "$PRD_FILE" | awk '{print $1}')
  LAST_HASH=""
  if [ -f "$LAST_HASH_FILE" ]; then
    LAST_HASH=$(cat "$LAST_HASH_FILE" 2>/dev/null || echo "")
  fi

  if [ -n "$LAST_HASH" ] && [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
    # PRD changed -- archive previous run
    DATE=$(date +%Y-%m-%d)

    # Derive folder name: first story title slugified, or current git branch
    FOLDER_NAME=""
    FIRST_TITLE=$(jq -r '.stories[0].title // empty' "$PRD_FILE" 2>/dev/null || echo "")
    if [ -n "$FIRST_TITLE" ]; then
      FOLDER_NAME=$(echo "$FIRST_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    fi
    if [ -z "$FOLDER_NAME" ]; then
      FOLDER_NAME=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
      FOLDER_NAME=$(echo "$FOLDER_NAME" | sed 's|/|-|g')
    fi

    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run (PRD changed)"
    mkdir -p "$ARCHIVE_FOLDER"
    # Archive the old files (PRD may have already been overwritten, but progress is still from old run)
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi

  # Store current hash
  echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
if [ -n "$FALLBACK_MODEL" ]; then
  echo "  Fallback model: $FALLBACK_MODEL @ $FALLBACK_URL"
fi
if [ "$DELAY" -gt 0 ]; then
  echo "  Delay between iterations: ${DELAY}s"
fi
echo "  Max retries before stalemate: $MAX_RETRIES"

# Stalemate tracking
STALEMATE_COUNT=0
PREV_REMAINING=999

# Track schema commits in this run
SCHEMA_COMMITTED_THIS_RUN=""

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # --- jq-based stop condition (pre-check) ---
  REMAINING=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_FILE" 2>/dev/null || echo "999")
  if [ "$REMAINING" -eq 0 ]; then
    echo ""
    echo "Ralph completed all tasks! (all stories pass)"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  # --- prd.json corruption protection ---
  if ! jq empty "$PRD_FILE" 2>/dev/null; then
    echo "ERROR: prd.json is corrupted. Restoring from last git commit."
    git checkout -- "$PRD_FILE" 2>/dev/null
    if ! jq empty "$PRD_FILE" 2>/dev/null; then
      echo "ERROR: Restored prd.json is also corrupted. Unrecoverable."
      exit 3
    fi
    # Re-check remaining after restoration
    REMAINING=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_FILE" 2>/dev/null || echo "999")
    if [ "$REMAINING" -eq 0 ]; then
      echo ""
      echo "Ralph completed all tasks! (all stories pass)"
      echo "Completed at iteration $i of $MAX_ITERATIONS"
      exit 0
    fi
  fi

  echo "  Stories remaining: $REMAINING"

  # --- Schema gate enforcement ---
  NEXT_STORY_TAGS=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | .[0].tags // [] | .[]' "$PRD_FILE" 2>/dev/null || echo "")
  NEXT_STORY_ID=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | .[0].id // empty' "$PRD_FILE" 2>/dev/null || echo "")

  HAS_SCHEMA_TAG=false
  for tag in $NEXT_STORY_TAGS; do
    if [ "$tag" = "SCHEMA" ]; then
      HAS_SCHEMA_TAG=true
      break
    fi
  done

  if [ "$HAS_SCHEMA_TAG" = true ] && [ -n "$SCHEMA_COMMITTED_THIS_RUN" ]; then
    echo "Schema gate: deferring $NEXT_STORY_ID -- another schema story already committed this run"
    echo "$(date '+%Y-%m-%d %H:%M') - Schema gate: deferred $NEXT_STORY_ID" >> "$PROGRESS_FILE"

    # Check stalemate (schema gate counts as no progress)
    if [ "$REMAINING" -ge "$PREV_REMAINING" ]; then
      STALEMATE_COUNT=$((STALEMATE_COUNT + 1))
    fi
    if [ "$STALEMATE_COUNT" -ge "$MAX_RETRIES" ]; then
      echo "STALLED on current stories after $MAX_RETRIES attempts -- needs human intervention"
      exit 2
    fi

    if [ "$DELAY" -gt 0 ]; then
      echo "Waiting ${DELAY}s before next iteration..."
      sleep "$DELAY"
    fi
    continue
  fi

  # --- Run the agent ---
  STDERR_FILE=$(mktemp)
  MODEL_USED="$TOOL"

  if [[ "$TOOL" == "amp" ]]; then
    OUTPUT=$(cat "$SCRIPT_DIR/prompt.md" | amp --dangerously-allow-all 2>"$STDERR_FILE" | tee /dev/stderr) || true
  else
    OUTPUT=$(claude --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>"$STDERR_FILE" | tee /dev/stderr) || true
  fi

  AGENT_EXIT=$?
  STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
  rm -f "$STDERR_FILE"

  # --- Check for rate limiting ---
  RATE_LIMITED=false
  if echo "$STDERR_CONTENT $OUTPUT" | grep -qiE "rate.limit|429|too many requests|quota exceeded|overloaded|capacity|throttled"; then
    RATE_LIMITED=true
  fi

  if [ "$RATE_LIMITED" = true ] && [ -n "$FALLBACK_MODEL" ]; then
    echo ""
    echo "Rate limited -- falling back to Ollama ($FALLBACK_MODEL)"
    echo "$(date '+%Y-%m-%d %H:%M') - Rate limited on $TOOL, falling back to $FALLBACK_MODEL" >> "$PROGRESS_FILE"

    # Check for high-risk tags on current story
    IS_HIGH_RISK=false
    for tag in $NEXT_STORY_TAGS; do
      for hr_tag in $HIGH_RISK_TAGS; do
        if [ "$tag" = "$hr_tag" ]; then
          IS_HIGH_RISK=true
          break 2
        fi
      done
    done

    if [ "$IS_HIGH_RISK" = true ]; then
      echo "Skipping high-risk story -- queued for Claude"
      echo "$(date '+%Y-%m-%d %H:%M') - Skipped high-risk story $NEXT_STORY_ID (tags: $NEXT_STORY_TAGS) -- queued for Claude" >> "$PROGRESS_FILE"
      sleep 60
      continue
    fi

    # Re-run with Ollama via inline env vars
    MODEL_USED="ollama/$FALLBACK_MODEL"
    STDERR_FILE2=$(mktemp)

    OUTPUT=$(ANTHROPIC_BASE_URL="$FALLBACK_URL" \
      ANTHROPIC_AUTH_TOKEN="ollama" \
      ANTHROPIC_API_KEY="ollama" \
      claude --model "$FALLBACK_MODEL" --dangerously-skip-permissions --print < "$SCRIPT_DIR/CLAUDE.md" 2>"$STDERR_FILE2" | tee /dev/stderr) || true

    AGENT_EXIT=$?
    rm -f "$STDERR_FILE2"
  fi

  # --- jq-based stop condition (post-check) ---
  REMAINING=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_FILE" 2>/dev/null || echo "999")
  if [ "$REMAINING" -eq 0 ]; then
    echo ""
    echo "Ralph completed all tasks! (all stories pass)"
    echo "Completed at iteration $i of $MAX_ITERATIONS (model: $MODEL_USED)"
    exit 0
  fi

  # Secondary fallback: check for completion signal in output
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks! (agent signaled completion)"
    echo "Completed at iteration $i of $MAX_ITERATIONS (model: $MODEL_USED)"
    exit 0
  fi

  # --- Track schema commits ---
  if [ "$HAS_SCHEMA_TAG" = true ] && [ -n "$NEXT_STORY_ID" ]; then
    # Check if this story was just committed
    JUST_COMMITTED=$(jq -r --arg id "$NEXT_STORY_ID" '.stories[] | select(.id == $id) | .passes' "$PRD_FILE" 2>/dev/null || echo "false")
    if [ "$JUST_COMMITTED" = "true" ]; then
      SCHEMA_COMMITTED_THIS_RUN="$NEXT_STORY_ID"
    fi
  fi

  # --- Stalemate detection ---
  if [ "$REMAINING" -ge "$PREV_REMAINING" ]; then
    STALEMATE_COUNT=$((STALEMATE_COUNT + 1))
    echo "  No progress detected (stalemate count: $STALEMATE_COUNT/$MAX_RETRIES)"
  else
    STALEMATE_COUNT=0
    echo "  Progress made! Stories remaining: $REMAINING"
  fi
  PREV_REMAINING=$REMAINING

  if [ "$STALEMATE_COUNT" -ge "$MAX_RETRIES" ]; then
    echo ""
    echo "STALLED on current stories after $MAX_RETRIES attempts -- needs human intervention"
    exit 2
  fi

  echo "Iteration $i complete. (model: $MODEL_USED)"

  # --- Delay between iterations ---
  if [ "$DELAY" -gt 0 ]; then
    echo "Waiting ${DELAY}s before next iteration..."
    sleep "$DELAY"
  fi
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
