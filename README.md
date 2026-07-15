# agent-sandbox — 설치

macOS(Apple Silicon). Docker·brew·Xcode 불요.

```sh
curl -fsSL https://raw.githubusercontent.com/iLab-Research/agent-sandbox-install/main/install.sh | sh
```

실행하면 GitHub 토큰을 물어봅니다(가려서 입력). 필요한 스코프 2개:

| 용도 | 스코프 |
|---|---|
| 프리빌트 번들 다운로드 | `repo` |
| 런타임 이미지 pull | `read:packages` |

발급: github.com/settings/tokens/new → classic → 위 둘 체크 (org SSO 면 **Authorize** 필수)

설치 후:

```sh
~/.agent-sandbox/bin/claude-sandbox -p '...'
```

제거:

```sh
~/.agent-sandbox/bin/agent-sandbox uninstall
```

## 이 repo 에 대해

**부트스트랩 스크립트만** 있는 공개 repo 입니다. 시크릿이 없습니다 — 토큰은 실행 시점에
사용자가 입력하고 `~/.agent-sandbox/registry.env`(0600)에만 저장됩니다.
소스·이미지·바이너리는 private 이며 토큰 없이는 받아지지 않습니다.

스크립트 원본: `iLab-Research/agent-sandbox` 의 `install.sh` (private). 이 사본은 릴리스 시 동기화됩니다.
