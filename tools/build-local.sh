#!/usr/bin/env bash
# Build Kazumi locally with the credentials CI would normally inject.
#
# The official builds get KAZUMI_APPID / KAZUMI_KEY (and the DanDanPlay pair)
# from GitHub secrets via --dart-define. Without them the Bangumi mirror
# rejects search and comment requests with 401, and danmaku search fails too.
# Putting them in tools/local-credentials.json lets every local build sign
# correctly without retyping long flags.
#
# That file is gitignored on purpose: it holds secrets extracted from a
# published APK. Keep it local.
#
# Usage:
#   tools/build-local.sh apk                 # release APK
#   tools/build-local.sh windows             # Windows desktop release
#   tools/build-local.sh apk --debug         # extra args pass through
#   tools/build-local.sh --print-defines     # just show the dart-defines

set -euo pipefail

# When invoked from PowerShell the inherited PATH is Windows-shaped, which
# hides sed/cut. Make sure the POSIX tools that ship with Git are reachable.
case ":${PATH}:" in
  *:/usr/bin:*) ;;
  *) PATH="/usr/bin:/bin:${PATH}" ;;
esac
export PATH

cd "${0%/*}/.."

CREDS_FILE="tools/local-credentials.json"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# Locate the Flutter SDK. FLUTTER_ROOT wins, then the usual suspects.
find_flutter() {
  local candidates=(
    "${FLUTTER_ROOT:-}/bin/flutter"
    "/d/Tools/dev/flutter/bin/flutter"
    "/c/flutter/bin/flutter"
    "$HOME/flutter/bin/flutter"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  command -v flutter 2>/dev/null || die "找不到 flutter，请设置 FLUTTER_ROOT"
}

# Pull a string value out of the credentials JSON without needing jq.
read_credential() {
  local key="$1"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$CREDS_FILE"
}

[ -f "$CREDS_FILE" ] || die "缺少 $CREDS_FILE（内含本地构建凭据，不应提交）"

APPID="$(read_credential KAZUMI_APPID)"
KEY="$(read_credential KAZUMI_KEY)"
DANDAN_ID="$(read_credential DANDANAPI_APPID)"
DANDAN_KEY="$(read_credential DANDANAPI_KEY)"

[ -n "$APPID" ] || die "$CREDS_FILE 里 KAZUMI_APPID 为空"
[ -n "$KEY" ] || die "$CREDS_FILE 里 KAZUMI_KEY 为空"

DEFINES=(
  "--dart-define=KAZUMI_APPID=$APPID"
  "--dart-define=KAZUMI_KEY=$KEY"
)
if [ -n "$DANDAN_ID" ] && [ -n "$DANDAN_KEY" ]; then
  DEFINES+=(
    "--dart-define=DANDANAPI_APPID=$DANDAN_ID"
    "--dart-define=DANDANAPI_KEY=$DANDAN_KEY"
  )
fi

if [ "${1:-}" = "--print-defines" ]; then
  printf '%s\n' "${DEFINES[@]}"
  exit 0
fi

TARGET="${1:-apk}"
[ $# -gt 0 ] && shift

BUILD_ARGS=()
case "$TARGET" in
  apk)
    BUILD_ARGS+=(build apk --release --no-pub)
    ;;
  windows)
    BUILD_ARGS+=(build windows --release --no-pub)
    ;;
  *)
    die "未知目标 '$TARGET'（支持 apk / windows）"
    ;;
esac

FLUTTER="$(find_flutter)"

printf '==> flutter %s\n' "$TARGET"
printf '    credentials: %s… / %s…\n' \
  "$(printf '%s' "$APPID" | cut -c1-12)" \
  "$(printf '%s' "$KEY" | cut -c1-8)"

exec "$FLUTTER" "${BUILD_ARGS[@]}" "${DEFINES[@]}" "$@"
