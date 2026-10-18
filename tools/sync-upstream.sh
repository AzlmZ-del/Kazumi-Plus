#!/usr/bin/env bash
# 把 local/rule-repo 的改动重放到最新的上游 main 上。
#
# 用法:
#   tools/sync-upstream.sh           # 正常重放
#   tools/sync-upstream.sh --check   # 只看状态，不动分支
#   tools/sync-upstream.sh --abort   # 重放出问题，退回重放前的状态
#
# 前置: 工作区干净（先 commit 或 stash）。脚本会自己检查。

set -euo pipefail

BRANCH="local/rule-repo"
UPSTREAM="origin"
BASE_BRANCH="main"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; NC=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s OK %s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s !! %s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s XX %s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

MODE="${1:-run}"

# -- 基本检查 ---------------------------------------------------------

current=$(git branch --show-current)
[ "$current" = "$BRANCH" ] || die "当前在 '$current'，请先切到 $BRANCH"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "工作区有未提交改动，先 commit 或 stash"
fi

say "${DIM}fetch $UPSTREAM...${NC}"
git fetch --prune "$UPSTREAM"

behind=$(git rev-list --count "HEAD..$UPSTREAM/$BASE_BRANCH")
ahead=$(git rev-list --count "$UPSTREAM/$BASE_BRANCH..HEAD")

say ""
say "本地领先上游 $ahead 个提交，落后 $behind 个提交"

case "$MODE" in
  --check)
    if [ "$behind" -eq 0 ]; then
      ok "已是最新，无需重放"
    else
      warn "上游有 $behind 个新提交待重放"
      say ""
      say "上游新增:"
      git log --oneline "HEAD..$UPSTREAM/$BASE_BRANCH" | sed 's/^/  /'
      say ""
      say "你自己的提交:"
      git log --oneline "$UPSTREAM/$BASE_BRANCH..HEAD" | sed 's/^/  /'
    fi
    exit 0
    ;;
  --abort)
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
      git rebase --abort
      ok "已中止重放，回到 $(git rev-parse --short HEAD)"
    else
      warn "当前没有进行中的重放"
    fi
    exit 0
    ;;
  run) ;;
  *) die "未知参数: $MODE（可用 --check / --abort）" ;;
esac

if [ "$behind" -eq 0 ]; then
  ok "已是最新，无需重放"
  exit 0
fi

rollback=$(git rev-parse HEAD)

say ""
say "${DIM}开始重放 $ahead 个提交到 $UPSTREAM/$BASE_BRANCH...${NC}"
say ""

if ! git rebase "$UPSTREAM/$BASE_BRANCH"; then
  say ""
  printf '%s重放暂停。%s\n' "$RED" "$NC"
  say ""
  say "冲突文件:"
  git diff --name-only --diff-filter=U | sed 's/^/  /'
  say ""
  say "处理方式:"
  say "  1. 手动改完冲突文件"
  say "  2. git add <文件>"
  say "  3. git rebase --continue"
  say ""
  say "放弃这次重放:"
  say "  tools/sync-upstream.sh --abort"
  say "  或 git reset --hard $rollback"
  exit 1
fi

say ""
ok "重放完成"

# -- 重放后的验收 -----------------------------------------------------

if [ -f pubspec.yaml ]; then
  # flutter 通常不在 PATH 里，按常见位置兜底找一次。
  FLUTTER=""
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER="flutter"
  else
    for candidate in \
      "${FLUTTER_ROOT:-}/bin/flutter" \
      /d/Tools/dev/flutter/bin/flutter \
      /c/flutter/bin/flutter \
      "$HOME/flutter/bin/flutter"
    do
      if [ -x "$candidate" ]; then
        FLUTTER="$candidate"
        break
      fi
    done
  fi

  if [ -z "$FLUTTER" ]; then
    warn "找不到 flutter，跳过 analyze 与测试"
    say "可用 FLUTTER_ROOT 环境变量指定 SDK 位置"
    say "重放结果: $(git log --oneline -1)"
    exit 0
  fi

  say ""
  say "${DIM}$FLUTTER analyze...${NC}"
  # 上游现有 17 条 info，不应让重放判失败；error / warning 仍然致命。
  if "$FLUTTER" analyze --no-fatal-infos; then
    ok "analyze 通过"
  else
    warn "analyze 有问题 —— 重放后代码需要检查"
    say "回退到重放前: git reset --hard $rollback"
    exit 1
  fi

  if [ -d test ]; then
    say ""
    say "${DIM}$FLUTTER test...${NC}"
    if "$FLUTTER" test; then
      ok "测试通过"
    else
      warn "测试失败 —— 重放后代码需要检查"
      say "回退到重放前: git reset --hard $rollback"
      exit 1
    fi
  fi
fi

say ""
ok "完成。当前 $(git log --oneline -1)"