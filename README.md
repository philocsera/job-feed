# job-feed

매일 자정(KST) 국내에 새로 올라온 **백엔드 신입·인턴 채용 / 공모전 / 대회·해커톤**을 수집해
카드 뷰어(←/→로 넘김)로 보여주는 정적 사이트. GitHub Pages로 호스팅.

- **라이브**: https://philocsera.github.io/job-feed/
- **수집·생성**: Claude 스킬 `/job_feed` (`~/.claude/commands/job_feed.md`) — 리서치 후 `data/*.json` 만 생성
- **발행**: 래퍼 `run_job_feed.sh` 가 헬스체크 후 `git push` → Pages 자동 갱신

## 상태 (2026-06-20 구축 완료)

- ✅ 라이브 + 실제 데이터 게시됨 (첫 실측 수집 6건: 백엔드 채용 5 + 해커톤 1)
- ✅ launchd `com.yeoukkori.job-feed` **load 완료** → 매일 00:00 자동 실행
- ✅ 헤드리스 토큰은 `~/.config/good-morning.env` 재사용 (별도 설정 불필요)
- ✅ 뷰어 헤드리스 테스트 **62 케이스 통과**: `node test/harness.mjs`

## 구조

```
launchd(00:00 KST)  →  caffeinate run_job_feed.sh
                          ├ KST 어제 날짜 계산
                          ├ claude -p "/job_feed <date>" --permission-mode bypassPermissions
                          │     └ 뷰어용 JSON 생성: data/{date}.json · latest.json · index.json
                          ├ 헬스체크(JSON 유효 + items[])  → 실패 시 알림
                          └ git add/commit/push  → GitHub Pages
```

- `index.html` — 고정 뷰어(스킬이 건드리지 않음). `data/latest.json` 을 fetch.
- `data/latest.json` — 최신(어제) 피드. `data/{date}.json` — 날짜별 아카이브. `data/index.json` — 날짜 목록.

## 최초 1회 설정 (arming)

```sh
# 1) (선택) 전용 헤드리스 토큰 — 없으면 래퍼가 ~/.config/good-morning.env 토큰을 재사용
claude setup-token
mkdir -p ~/.config && printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' '<토큰>' > ~/.config/job-feed.env && chmod 600 ~/.config/job-feed.env

# 2) 수동 테스트 (cron 켜기 전에 한 번 — 권장)
/Users/johyeonseong/playground/job-feed/run_job_feed.sh ; tail -40 /tmp/yeoukkori-job-feed.log

# 3) cron 켜기  (※ 이미 load 완료 — 끄려면 unload, 코드 수정 후 재적용 시 아래 재실행)
launchctl unload ~/Library/LaunchAgents/com.yeoukkori.job-feed.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/com.yeoukkori.job-feed.plist
launchctl list | grep job-feed

# 5) 뷰어 로직 테스트 (브라우저 없이)
node /Users/johyeonseong/playground/job-feed/test/harness.mjs

# 4) 로컬 미리보기 (fetch는 file://에서 안 되므로 로컬 서버 필요)
cd /Users/johyeonseong/playground/job-feed && python3 -m http.server 8765   # → http://localhost:8765
```

## 주의 (하드 제약)

- **워크스페이스를 `~/Downloads`·`~/Documents`·`~/Desktop` 밑으로 옮기지 말 것.** macOS TCC 보호 폴더라 launchd의 `claude` 가 즉사한다. (그래서 `~/playground/job-feed`.)
- 자정 wake: `pmset repeat wake` 슬롯은 하나뿐이라 기존 06:00용(05:59) 설정과 충돌. 자정엔 보통 Mac이 깨어 있어 동작하지만, 절전에서 확실히 깨우려면 별도 조정 필요. 로그(`/tmp/yeoukkori-job-feed.log`)로 발동 확인.
- Pages는 public repo. 공개 취업정보라 민감정보 없음(good_morning과 동일 정책).

## 로그
`/tmp/yeoukkori-job-feed.log` · `/tmp/yeoukkori-job-feed.err`
