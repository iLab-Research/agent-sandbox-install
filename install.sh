#!/bin/sh
# install.sh — agent-sandbox 원커맨드 설치 (macOS 네이티브). Docker·brew·Xcode 불요.
#
# 배포 모델: **소스·이미지 private**. 설치 시 GitHub 토큰 하나만 입력하면
#   (1) private 릴리스에서 프리빌트 번들 다운로드, (2) private 이미지 pull
# 둘 다 해결된다. 토큰 없으면 프롬프트로 물어본다(비밀번호처럼 가려서 입력).
#
#   curl -fsSL <install.sh> | sh          → 토큰 프롬프트
#   AGENT_SANDBOX_TOKEN=ghp_... sh install.sh   → 비대화형
#
# 토큰 스코프: `repo`(private 릴리스 다운로드) + `read:packages`(이미지 pull).
#   github.com/settings/tokens/new → classic → 위 둘 체크 (org SSO 면 Authorize)
#
# 환경변수:
#   AGENT_SANDBOX_TOKEN         GitHub 토큰(미지정 시 프롬프트)
#   AGENT_SANDBOX_PREFIX        기본 ~/.agent-sandbox
#   AGENT_SANDBOX_AGENTS        기본 "claude codex"
#   AGENT_SANDBOX_VERSION       릴리스 태그(기본 latest)
#   AGENT_SANDBOX_RELEASE_URL   번들 URL 직접 지정(공개 CDN 쓸 때)
set -eu

PREFIX="${AGENT_SANDBOX_PREFIX:-$HOME/.agent-sandbox}"
AGENTS="${AGENT_SANDBOX_AGENTS:-claude codex}"
SLUG="${AGENT_SANDBOX_REPO:-iLab-Research/agent-sandbox}"
API="https://api.github.com"

[ "$(uname -s)" = "Darwin" ] || { echo "install.sh: macOS 전용." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] && arch=arm64 || arch=amd64

# ---- 레포에서 실행(개발/메인테이너) → 소스 빌드 위임 ----
SRC_ROOT=""
if [ -f "$0" ]; then
  _d=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _d=""
  [ -n "$_d" ] && [ -f "$_d/launcher/go.mod" ] && [ -f "$_d/macos-native/setup.sh" ] && SRC_ROOT="$_d"
fi
if [ -n "$SRC_ROOT" ] && [ "${AGENT_SANDBOX_INSTALL_FROM:-source}" = "source" ]; then
  echo "== install (from source) =="
  exec "$SRC_ROOT/macos-native/setup.sh" --prefix "$PREFIX" --agents "$AGENTS" "$@"
fi

# ---- 토큰: env 없으면 프롬프트(가림). curl|sh 라도 /dev/tty 로 읽는다 ----
TOK="${AGENT_SANDBOX_TOKEN:-}"
if [ -z "$TOK" ]; then
  if [ -r /dev/tty ]; then
    printf 'GitHub 토큰 입력 (repo + read:packages): ' > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    read -r TOK < /dev/tty
    stty echo < /dev/tty 2>/dev/null || true
    printf '\n' > /dev/tty
  fi
fi
[ -n "$TOK" ] || { echo "install.sh: 토큰 필요 (AGENT_SANDBOX_TOKEN 또는 프롬프트)." >&2; exit 1; }

gh_api() { curl -fsSL -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" "$@"; }

# 토큰 소유자 = 레지스트리 username (자동 도출 — 사용자가 안 물어봐도 됨)
GH_USER=$(gh_api "$API/user" 2>/dev/null | tr ',' '\n' | grep '"login"' | head -1 | sed 's/.*"login" *: *"\([^"]*\)".*/\1/')
[ -n "$GH_USER" ] || { echo "install.sh: 토큰이 유효하지 않음(사용자 조회 실패)." >&2; exit 1; }
echo "== install (release) — user=$GH_USER, arch=$arch =="

# ---- 번들 다운로드: private 릴리스 에셋을 토큰으로(API 경유) ----
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
NAME="agent-sandbox-macos-$arch.tar.gz"
if [ -n "${AGENT_SANDBOX_RELEASE_URL:-}" ]; then
  curl -fSL --retry 3 -o "$TMP/b.tgz" "$AGENT_SANDBOX_RELEASE_URL"
else
  VER="${AGENT_SANDBOX_VERSION:-latest}"
  if [ "$VER" = "latest" ]; then REL="$API/repos/$SLUG/releases/latest"; else REL="$API/repos/$SLUG/releases/tags/$VER"; fi
  # 에셋 id 추출 (jq/python 없이). GitHub API 는 pretty JSON → 필드마다 별도 줄이라
  # 한 줄 grep 으론 id·name 을 같이 못 본다. 직전 "id" 를 기억하다 name 일치 시 출력.
  # ("node_id" 는 앞에 '"' 가 없어 /"id":/ 에 안 걸린다. 에셋 객체 순서: url→id→node_id→name)
  ASSET_ID=$(gh_api "$REL" | awk -v n="\"$NAME\"" '
    /"id":/ { t=$0; gsub(/[^0-9]/, "", t); id=t }
    /"name":/ && index($0, n) { print id; exit }')
  [ -n "$ASSET_ID" ] || { echo "install.sh: 릴리스 에셋 못 찾음($NAME @ $VER). 토큰 스코프(repo)·릴리스 확인." >&2; exit 1; }
  echo "  다운로드: asset $ASSET_ID ($NAME)"
  curl -fSL --retry 3 -H "Authorization: Bearer $TOK" -H "Accept: application/octet-stream" \
    -o "$TMP/b.tgz" "$API/repos/$SLUG/releases/assets/$ASSET_ID"
fi

mkdir -p "$PREFIX"
tar -xzf "$TMP/b.tgz" -C "$PREFIX"
chmod +x "$PREFIX"/bin/* 2>/dev/null || true
echo "  설치됨: $PREFIX"

# ---- setup: 같은 토큰으로 private 이미지 pull 인증 ----
AGENT_SANDBOX_REGISTRY_TOKEN="$TOK" AGENT_SANDBOX_REGISTRY_USER="$GH_USER" \
  "$PREFIX/bin/agent-sandbox" setup --agents "$AGENTS" || true

# 런타임에도 이미지 pull 인증이 필요하므로 토큰을 로컬에 보관(0600). 지우려면 이 파일 삭제.
CFG="$PREFIX/registry.env"
umask 077; printf 'AGENT_SANDBOX_REGISTRY_TOKEN=%s\nAGENT_SANDBOX_REGISTRY_USER=%s\n' "$TOK" "$GH_USER" > "$CFG"
echo "  레지스트리 인증 저장: $CFG (0600)"
echo "완료. 실행: $PREFIX/bin/claude-sandbox -p '...'"
