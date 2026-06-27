#!/bin/zsh
# job_feed daily - Codex launchd wrapper.
# Generates data JSON with Codex, health-checks it, then commits + pushes.
set -uo pipefail

ulimit -n 16384 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true

ROOT="/Users/johyeonseong/playground/job-feed"
DATA="$ROOT/data"
SKILL_DIR="/Users/johyeonseong/.codex/skills/job-feed"
INSTRUCTIONS="$SKILL_DIR/references/job_feed.md"
CODEX_BIN="${CODEX_BIN:-/Users/johyeonseong/.local/bin/codex}"
PY="/usr/bin/python3"
LOG="${JOB_FEED_CODEX_LOG:-/tmp/yeoukkori-job-feed.log}"
REPO="philocsera/job-feed"
NO_PUBLISH=0
TARGET=""

usage() {
  cat <<'EOF'
Usage:
  run_job_feed.sh [YYYY-MM-DD] [--no-publish]
  run_job_feed.sh --date YYYY-MM-DD [--no-publish]

Defaults:
  target date = yesterday in Asia/Seoul.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --date)
      shift
      if [[ $# -eq 0 ]]; then
        echo "[FAIL] --date requires YYYY-MM-DD" >&2
        exit 2
      fi
      TARGET="$1"
      ;;
    --no-publish)
      NO_PUBLISH=1
      ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      TARGET="$1"
      ;;
    *)
      echo "[FAIL] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$TARGET" ]]; then
  TARGET="$(TZ=Asia/Seoul /bin/date -v-1d +%Y-%m-%d 2>/dev/null || TZ=Asia/Seoul date -d 'yesterday' +%Y-%m-%d)"
fi

if ! [[ "$TARGET" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]]; then
  echo "[FAIL] invalid target date: $TARGET" >&2
  exit 2
fi

EXPECT="$DATA/$TARGET.json"
mkdir -p "$DATA"

{
  echo ""
  echo "==================== codex run $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z') target=$TARGET ===================="
} >> "$LOG"

cd "$ROOT" || { echo "[FAIL] cannot cd $ROOT" >> "$LOG"; exit 1; }

if [[ ! -x "$CODEX_BIN" ]]; then
  echo "[FAIL] codex executable not found or not executable: $CODEX_BIN" >> "$LOG"
  exit 1
fi

if [[ ! -f "$INSTRUCTIONS" ]]; then
  echo "[FAIL] instruction file not found: $INSTRUCTIONS" >> "$LOG"
  exit 1
fi

[ -f "$HOME/.config/job-feed-codex.env" ] && source "$HOME/.config/job-feed-codex.env"

echo "[diag] whoami=$(whoami) HOME=${HOME:-UNSET} ulimit_n=$(ulimit -n) codex=$CODEX_BIN gh=$(command -v gh 2>/dev/null)" >> "$LOG"
echo "[diag] codex auth source: $([ -n "${CODEX_ACCESS_TOKEN:-}" ] && echo CODEX_ACCESS_TOKEN || ([ -n "${CODEX_API_KEY:-}" ] && echo CODEX_API_KEY || echo cached-auth))" >> "$LOG"

PROMPT="$(cat <<EOF
You are running unattended from run_job_feed.sh.

Task:
- Generate the Job Feed JSON for target_date=$TARGET.
- Work in $ROOT.
- Use the Codex skill at $SKILL_DIR.
- Read $SKILL_DIR/SKILL.md first, then read and follow $INSTRUCTIONS as the source of truth.

Automation overrides:
- Do not ask the user for confirmation or input.
- If $EXPECT already exists, overwrite it.
- Write data/$TARGET.json, data/latest.json, and data/index.json exactly as the skill specifies.
- Do not modify index.html.
- Do not run git commands or open a browser; this wrapper handles publishing after the health check.
- Use live web search and direct source checks as needed for current facts.
- At the end, report only a concise status summary including category counts, failed sources, duplicate exclusions, and saved paths.
EOF
)"

CODEX_GLOBAL_ARGS=(--search --ask-for-approval never)
if [[ -n "${JOB_FEED_CODEX_MODEL:-}" ]]; then
  CODEX_GLOBAL_ARGS+=(-m "$JOB_FEED_CODEX_MODEL")
fi

CODEX_EXEC_ARGS=(
  exec
  --sandbox danger-full-access
  --cd "$ROOT"
  --ephemeral
  --color never
)

echo "[codex] starting job-feed generation for $TARGET" >> "$LOG"
"$CODEX_BIN" "${CODEX_GLOBAL_ARGS[@]}" "${CODEX_EXEC_ARGS[@]}" "$PROMPT" >> "$LOG" 2>&1
CODEX_EXIT=$?
echo "[codex] exit=$CODEX_EXIT" >> "$LOG"

if [[ -f "$EXPECT" ]] && "$PY" -c "import json,sys; d=json.load(open('$EXPECT')); sys.exit(0 if isinstance(d.get('items'),list) else 1)" 2>/dev/null; then
  N="$("$PY" -c "import json; print(len(json.load(open('$EXPECT'))['items']))" 2>/dev/null || echo '?')"
  echo "[OK] wrote $EXPECT ($N items)" >> "$LOG"
else
  echo "[FAIL] $EXPECT missing or not valid JSON with items[] after Codex run" >> "$LOG"
  /usr/bin/osascript -e 'display notification "job_feed Codex generation failed - check /tmp/yeoukkori-job-feed.log" with title "Job Feed cron" sound name "Basso"' 2>/dev/null
  exit 1
fi

if [[ "$NO_PUBLISH" -eq 1 ]]; then
  echo "[publish] skipped by --no-publish" >> "$LOG"
  exit 0
fi

git -C "$ROOT" add -A >> "$LOG" 2>&1
if git -C "$ROOT" diff --cached --quiet; then
  echo "[publish] nothing changed" >> "$LOG"
  exit 0
fi

git -C "$ROOT" commit -m "feed: $TARGET ($N items)" >> "$LOG" 2>&1
GH_TOKEN="$(gh auth token 2>/dev/null)"
if [[ -n "$GH_TOKEN" ]]; then
  if git -C "$ROOT" push "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" HEAD:main >> "$LOG" 2>&1; then
    echo "[publish] pushed" >> "$LOG"
    exit 0
  fi
  echo "[publish] push FAILED (token) - see log" >> "$LOG"
  exit 1
fi

if git -C "$ROOT" push >> "$LOG" 2>&1; then
  echo "[publish] pushed (default creds)" >> "$LOG"
  exit 0
fi

echo "[publish] push FAILED (no token)" >> "$LOG"
exit 1
