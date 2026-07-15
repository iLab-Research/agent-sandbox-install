#!/bin/sh
# install.sh — agent-sandbox CLI 설치 (macOS 네이티브). Docker·brew·Xcode 불요.
#
# 역할 분담: 이 스크립트는 **CLI 만** 깔고 PATH 에 연결한다(몇 초).
# 커널·vminit·offline 이미지 같은 무거운 자산은 `agent-sandbox setup` 이 받는다 —
# 재실행 가능하고, 끊겨도 이어받고, doctor 가 빠졌다 하면 setup 이 채운다.
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
    # echo 를 프롬프트보다 **먼저** 끈다. 반대 순서면 프롬프트~stty 사이 창에 들어온
    # 입력(붙여넣기·타이핑 선행)이 평문으로 찍힌다. Ctrl-C 로 빠져나가도 echo 복구.
    stty -echo < /dev/tty 2>/dev/null || true
    trap 'stty echo < /dev/tty 2>/dev/null || true; exit 130' INT TERM HUP
    printf 'GitHub 토큰 입력 (repo + read:packages): ' > /dev/tty
    read -r TOK < /dev/tty
    stty echo < /dev/tty 2>/dev/null || true
    trap - INT TERM HUP
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
# CLI 만 받는다(수십 MB, 몇 초). 커널·vminit·이미지 같은 무거운 자산은 아래 `setup` 이 받는다 —
# 그래야 중간에 끊겨도 setup 만 다시 돌리면 되고, setup 이 실제로 "설치" 를 하는 물건이 된다.
NAME="agent-sandbox-cli-$arch.tar.gz"
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

# ---- 토큰 보관: setup 의 자산 다운로드와 런타임 이미지 pull 이 같은 토큰을 쓴다(0600) ----
CFG="$PREFIX/registry.env"
umask 077; printf 'AGENT_SANDBOX_REGISTRY_TOKEN=%s\nAGENT_SANDBOX_REGISTRY_USER=%s\n' "$TOK" "$GH_USER" > "$CFG"

# ---- PATH 연결: CLI 를 이름으로 부를 수 있어야 CLI 다 ----
# 우선순위: 쓰기 가능한 PATH 디렉터리에 심링크(dotfile 안 건드림, uninstall 이 깔끔) →
# 안 되면 셸 프로파일에 PATH 추가(표식 주석으로 감싸 uninstall 이 정확히 지운다).
link_dir=""
for d in /usr/local/bin "$HOME/.local/bin"; do
  case ":$PATH:" in *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { link_dir="$d"; break; } ;; esac
done
if [ -z "$link_dir" ] && [ -w "$HOME" ]; then
  # ~/.local/bin 은 관례적 사용자 bin. 없으면 만들고 PATH 에 추가한다.
  mkdir -p "$HOME/.local/bin" 2>/dev/null && link_dir="$HOME/.local/bin"
fi

linked=0
if [ -n "$link_dir" ]; then
  for b in agent-sandbox claude-sandbox codex-sandbox; do
    ln -sf "$PREFIX/bin/$b" "$link_dir/$b" 2>/dev/null && linked=1
  done
fi

path_added=0
if [ "$linked" -eq 1 ]; then
  case ":$PATH:" in
    *":$link_dir:"*) : ;;
    *)  # 심링크는 걸었지만 그 디렉터리가 PATH 에 없다 → 프로파일에 추가
        for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
          [ -e "$rc" ] || continue
          grep -q 'agent-sandbox PATH' "$rc" 2>/dev/null && continue   # 재설치 멱등
          printf '\n# >>> agent-sandbox PATH >>>\nexport PATH="%s:$PATH"\n# <<< agent-sandbox PATH <<<\n' \
            "$link_dir" >> "$rc"
          path_added=1
        done ;;
  esac
fi

echo "  CLI 설치됨: $PREFIX/bin"
if [ "$linked" -eq 1 ]; then
  echo "  PATH 연결: $link_dir/{agent-sandbox,claude-sandbox,codex-sandbox}"
else
  echo "  경고: 쓰기 가능한 PATH 디렉터리를 못 찾음 — 전체 경로로 실행하세요." >&2
fi

# ---- setup: 무거운 자산(커널·vminit·이미지)은 여기서 받는다 ----
echo
# 토큰은 registry.env(0600)에 이미 저장됨 — setup 이 거기서 읽는다. env 로 또 넘기지 않는다
# (자식 프로세스 env 로 토큰이 새지 않게).
if ! "$PREFIX/bin/agent-sandbox" setup --agents "$AGENTS"; then
  echo >&2
  echo "install.sh: CLI 는 설치됐지만 런타임 자산 설치가 실패했습니다." >&2
  echo "  원인을 고친 뒤 재실행하면 이어받습니다:  agent-sandbox setup" >&2
  echo "  (지금 상태로는 에이전트 실행이 안 됩니다 — 자산이 없습니다.)" >&2
  exit 1
fi

echo
if [ "$path_added" -eq 1 ]; then
  echo "완료. 새 터미널을 열거나 \`source ~/.zshrc\` 후:  claude-sandbox -p '...'"
elif [ "$linked" -eq 1 ]; then
  echo "완료. 실행:  claude-sandbox -p '...'"
else
  echo "완료. 실행:  $PREFIX/bin/claude-sandbox -p '...'"
fi
