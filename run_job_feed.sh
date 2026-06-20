#!/bin/zsh
# job_feed daily — launchd wrapper. Mirrors run_good_morning.sh.
# Runs the /job_feed skill headless, health-checks the JSON, then commits + pushes
# (plain files, no gzip) so GitHub Pages updates. A silently-empty run is never
# reported as success.
set -uo pipefail

# launchd starts with a low fd soft limit (256); claude (Node) needs more.
ulimit -n 16384 2>/dev/null || ulimit -n 10240 2>/dev/null || ulimit -n 4096 2>/dev/null || true

ROOT="/Users/johyeonseong/playground/job-feed"
DATA="$ROOT/data"
CLAUDE="/Users/johyeonseong/.local/bin/claude"
PY="/usr/bin/python3"
LOG="/tmp/yeoukkori-job-feed.log"
REPO="philocsera/job-feed"

# target_date = yesterday in KST (independent of system TZ / model clock).
TARGET="$(TZ=Asia/Seoul /bin/date -v-1d +%Y-%m-%d 2>/dev/null || TZ=Asia/Seoul date -d 'yesterday' +%Y-%m-%d)"
EXPECT="$DATA/$TARGET.json"

echo "" >> "$LOG"
echo "==================== run $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S %Z') · target=$TARGET ====================" >> "$LOG"

cd "$ROOT" || { echo "[FAIL] cannot cd $ROOT" >> "$LOG"; exit 1; }
echo "[diag] whoami=$(whoami) HOME=${HOME:-UNSET} ulimit_n=$(ulimit -n) claude=$(command -v claude 2>/dev/null) gh=$(command -v gh 2>/dev/null)" >> "$LOG"

# --- Credentials for headless run (launchd has no inherited session auth) ---
[ -f "$HOME/.config/job-feed.env" ] && source "$HOME/.config/job-feed.env"
# Reuse the good_morning token if job-feed has none of its own.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$HOME/.config/good-morning.env" ]; then
  source "$HOME/.config/good-morning.env"
fi
# Last resort: pull the subscription OAuth token from the login Keychain.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  KC_JSON="$(security find-generic-password -w -s 'Claude Code-credentials' -a "$(whoami)" 2>/dev/null)"
  if [ -n "$KC_JSON" ]; then
    TOKEN="$(printf '%s' "$KC_JSON" | "$PY" -c 'import sys,json; print(json.load(sys.stdin).get("claudeAiOauth",{}).get("accessToken",""))' 2>/dev/null)"
    [ -n "$TOKEN" ] && export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"
  fi
fi
echo "[diag] cred source: $([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo OAUTH_TOKEN || ([ -n "${ANTHROPIC_API_KEY:-}" ] && echo API_KEY || echo NONE))" >> "$LOG"

# --- Run the skill headless ---
"$CLAUDE" -p "/job_feed $TARGET" --permission-mode bypassPermissions >> "$LOG" 2>&1

# --- Health check: target json exists & is valid JSON with an items array ---
if [[ -f "$EXPECT" ]] && "$PY" -c "import json,sys; d=json.load(open('$EXPECT')); sys.exit(0 if isinstance(d.get('items'),list) else 1)" 2>/dev/null; then
  N="$("$PY" -c "import json; print(len(json.load(open('$EXPECT'))['items']))" 2>/dev/null || echo '?')"
  echo "[OK] wrote $EXPECT ($N items)" >> "$LOG"

  # --- Publish: commit + push plain files (non-fatal) ---
  git -C "$ROOT" add -A >> "$LOG" 2>&1
  if git -C "$ROOT" diff --cached --quiet; then
    echo "[publish] nothing changed" >> "$LOG"
  else
    git -C "$ROOT" commit -m "feed: $TARGET ($N items)" >> "$LOG" 2>&1
    GH_TOKEN="$(gh auth token 2>/dev/null)"
    if [ -n "$GH_TOKEN" ]; then
      if git -C "$ROOT" push "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" HEAD:main >> "$LOG" 2>&1; then
        echo "[publish] pushed" >> "$LOG"
      else
        echo "[publish] push FAILED (token) — see log" >> "$LOG"
      fi
    else
      git -C "$ROOT" push >> "$LOG" 2>&1 && echo "[publish] pushed (default creds)" >> "$LOG" || echo "[publish] push FAILED (no token)" >> "$LOG"
    fi
  fi
  exit 0
else
  echo "[FAIL] $EXPECT missing or not valid JSON with items[] — see log above" >> "$LOG"
  /usr/bin/osascript -e 'display notification "job_feed 생성 실패 — /tmp/yeoukkori-job-feed.log 확인" with title "Job Feed cron" sound name "Basso"' 2>/dev/null
  exit 1
fi
