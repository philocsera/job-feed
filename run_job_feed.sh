#!/bin/zsh
# job_feed daily - Claude Code launchd wrapper.
# Generates data JSON with Claude Code, health-checks it, then commits + pushes.
#
# 2026-08-24: Codex -> Claude Code 로 되돌림. Codex 사용량 한도가 차면
# 매일 00:00 실행이 통째로 실패했고, 실패가 "JSON 없음"으로만 보여 수집기
# 버그처럼 오진되기 쉬웠다. 지침 파일은 Claude 명령어가 원본이다.
set -uo pipefail

ulimit -n 16384 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true

ROOT="/Users/johyeonseong/playground/job-feed"
DATA="$ROOT/data"
CACHE="$ROOT/.cache"
INSTRUCTIONS="/Users/johyeonseong/.claude/commands/job_feed.md"
# 채용(job) 카테고리는 find_goal 의 원티드·랠릿·점핏 컬렉터를 재사용해
# 결정론적으로 만든다. 공모전/대회만 LLM 웹 리서치 몫이다.
FIND_GOAL_DIR="${FIND_GOAL_DIR:-/Users/johyeonseong/Downloads/playground/consulting/find_goal}"
LEDGER="$CACHE/seen-urls.json"
CLAUDE_BIN="${CLAUDE_BIN:-/Users/johyeonseong/.local/bin/claude}"
PY="/usr/bin/python3"
LOG="${JOB_FEED_CLAUDE_LOG:-${JOB_FEED_CODEX_LOG:-/tmp/yeoukkori-job-feed.log}}"
REPO="philocsera/job-feed"
# 웹 리서치가 걸려 멈추면 launchd 잡이 영원히 남는다. 기본 30분에서 끊는다.
TIMEOUT_SECONDS="${JOB_FEED_TIMEOUT:-1800}"
NO_PUBLISH=0
TARGET=""

usage() {
  cat <<'EOF'
Usage:
  run_job_feed.sh [YYYY-MM-DD] [--no-publish]
  run_job_feed.sh --date YYYY-MM-DD [--no-publish]

Defaults:
  target date = yesterday in Asia/Seoul.

Environment:
  CLAUDE_BIN          claude 실행 파일 경로.
  JOB_FEED_MODEL      모델 오버라이드 (미설정 시 claude 기본값).
  JOB_FEED_TIMEOUT    생성 단계 제한 시간(초). 기본 1800.
  JOB_FEED_CLAUDE_LOG 로그 경로. 기본 /tmp/yeoukkori-job-feed.log
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
COLLECTED="$CACHE/jobs-$TARGET.json"
mkdir -p "$DATA" "$CACHE"

{
  echo ""
  echo "==================== claude run $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z') target=$TARGET ===================="
} >> "$LOG"

cd "$ROOT" || { echo "[FAIL] cannot cd $ROOT" >> "$LOG"; exit 1; }

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "[FAIL] claude executable not found or not executable: $CLAUDE_BIN" >> "$LOG"
  exit 1
fi

if [[ ! -f "$INSTRUCTIONS" ]]; then
  echo "[FAIL] instruction file not found: $INSTRUCTIONS" >> "$LOG"
  exit 1
fi

[ -f "$HOME/.config/job-feed-claude.env" ] && source "$HOME/.config/job-feed-claude.env"

echo "[diag] whoami=$(whoami) HOME=${HOME:-UNSET} ulimit_n=$(ulimit -n) claude=$CLAUDE_BIN gh=$(command -v gh 2>/dev/null)" >> "$LOG"
echo "[diag] claude auth source: $([ -n "${ANTHROPIC_API_KEY:-}" ] && echo ANTHROPIC_API_KEY || echo cached-auth)" >> "$LOG"

# --- 1단계: 채용 공고 결정론적 수집 -------------------------------------
# 국내 리스팅을 LLM 이 훑던 방식은 사람인·로켓펀치 차단과 게시일 미노출로
# 신규 판정이 불가능했다. find_goal 이 이미 세 곳의 API 를 직접 호출하므로
# 그 컬렉터를 재사용한다. find_goal 이 없으면 이 단계만 건너뛴다.
JOBS_READY=0
if [[ -d "$FIND_GOAL_DIR" && -f "$FIND_GOAL_DIR/scripts/export-job-feed.ts" ]]; then
  echo "[collect] reusing find_goal collectors (wanted/rallit/jumpit)" >> "$LOG"
  if (
    cd "$FIND_GOAL_DIR" &&
    FIND_GOAL_WANTED_LIMIT="${FIND_GOAL_WANTED_LIMIT:-50}" \
    FIND_GOAL_RALLIT_LIMIT="${FIND_GOAL_RALLIT_LIMIT:-50}" \
    FIND_GOAL_JUMPIT_PAGES="${FIND_GOAL_JUMPIT_PAGES:-3}" \
    npx tsx scripts/export-job-feed.ts \
      --date "$TARGET" --out "$COLLECTED" --ledger "$LEDGER"
  ) >> "$LOG" 2>&1; then
    JOBS_READY=1
  else
    echo "[collect] WARN: exporter failed; Claude will research jobs on its own" >> "$LOG"
  fi
else
  echo "[collect] WARN: find_goal not found at $FIND_GOAL_DIR; Claude will research jobs on its own" >> "$LOG"
fi

if [[ "$JOBS_READY" -eq 1 ]]; then
  JOB_SOURCE_NOTE="$(cat <<EOF
Job postings are ALREADY COLLECTED. Do not research 채용 공고 yourself.
- Read $COLLECTED. Its \`items\` are finished cards for category "job": the
  three Korean sources (Wanted, Rallit, Jumpit) were fetched through their APIs,
  filtered to 신입/인턴 backend roles, deduplicated against a seen-URL ledger,
  and already screened against the permanently excluded axes.
- Copy those items into your output verbatim. Do not re-filter, re-rank, or
  rewrite their url / posted_date / deadline fields. You may tighten a summary
  that reads badly, but never invent facts.
- If that file has "seeding": true, its items list is intentionally empty
  (first run builds the ledger baseline). That is not an error.
- Your remaining job is ONLY the contest and competition categories.
EOF
)"
else
  JOB_SOURCE_NOTE="The job collector was unavailable, so research all three categories yourself as the instructions describe."
fi

PROMPT="$(cat <<EOF
You are running unattended from run_job_feed.sh. There is no human to answer questions.

Task:
- Generate the Job Feed JSON for target_date=$TARGET.
- Work in $ROOT.
- Read $INSTRUCTIONS in full first and follow it as the source of truth.

$JOB_SOURCE_NOTE

Automation overrides:
- Do not ask for confirmation or input. Never stop to propose a plan.
- target_date is already resolved to $TARGET. Do not recompute it.
- If $EXPECT already exists, overwrite it.
- Write data/$TARGET.json, data/latest.json, and data/index.json exactly as the instructions specify.
- Do not modify index.html.
- Do not run git commands or open a browser; this wrapper handles publishing after the health check.
- Use live WebSearch and WebFetch as needed for current facts.
- Zero qualifying items is a valid result: write items: [] rather than inventing entries.
- At the end, report only a concise status summary including category counts, failed sources, duplicate exclusions, and saved paths.
EOF
)"

CLAUDE_ARGS=(
  -p "$PROMPT"
  --output-format text
  --dangerously-skip-permissions
)
if [[ -n "${JOB_FEED_MODEL:-}" ]]; then
  CLAUDE_ARGS+=(--model "$JOB_FEED_MODEL")
fi

echo "[claude] starting job-feed generation for $TARGET (timeout ${TIMEOUT_SECONDS}s)" >> "$LOG"

# 워치독: claude 를 백그라운드로 띄우고 제한 시간이 지나면 트리를 정리한다.
"$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" >> "$LOG" 2>&1 &
CLAUDE_PID=$!
(
  sleep "$TIMEOUT_SECONDS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    echo "[claude] timeout after ${TIMEOUT_SECONDS}s; terminating" >> "$LOG"
    pkill -TERM -P "$CLAUDE_PID" 2>/dev/null
    kill -TERM "$CLAUDE_PID" 2>/dev/null
    sleep 5
    pkill -KILL -P "$CLAUDE_PID" 2>/dev/null
    kill -KILL "$CLAUDE_PID" 2>/dev/null
  fi
) &
WATCHDOG_PID=$!

wait "$CLAUDE_PID"
CLAUDE_EXIT=$?
kill "$WATCHDOG_PID" 2>/dev/null
echo "[claude] exit=$CLAUDE_EXIT" >> "$LOG"

if [[ -f "$EXPECT" ]] && "$PY" -c "import json,sys; d=json.load(open('$EXPECT')); sys.exit(0 if isinstance(d.get('items'),list) else 1)" 2>/dev/null; then
  N="$("$PY" -c "import json; print(len(json.load(open('$EXPECT'))['items']))" 2>/dev/null || echo '?')"
  echo "[OK] wrote $EXPECT ($N items)" >> "$LOG"
else
  echo "[FAIL] $EXPECT missing or not valid JSON with items[] after Claude run" >> "$LOG"
  /usr/bin/osascript -e 'display notification "job_feed Claude generation failed - check /tmp/yeoukkori-job-feed.log" with title "Job Feed cron" sound name "Basso"' 2>/dev/null
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
