# agent-sandbox — 설치

`claude / codex` 를 egress-봉쇄된 대화별 격리 잽 안에서 돌리는 샌드박스. **부트스트랩 스크립트만** 있는
공개 repo 입니다(소스·이미지·바이너리는 private). 실행 시 GitHub 토큰을 입력하면 private 릴리스/이미지에
접근합니다. 공통 모델: **런처만 먼저 받고, 무거운 자산(커널·initrd·rootfs)은 `agent-sandbox setup` 이
릴리스에서 조달**(재실행 가능·이어받기).

## macOS (Apple Silicon) — vz-boot

Docker·brew·Xcode 불요.

```sh
curl -fsSL https://raw.githubusercontent.com/iLab-Research/agent-sandbox-install/main/install.sh | sh
```

## Windows (x64) — hcs-boot

WSL2 distro·Docker Desktop 불요. **PowerShell**에서:

```powershell
irm https://raw.githubusercontent.com/iLab-Research/agent-sandbox-install/main/install.ps1 | iex
```

> 전제: 가상화(Hyper-V/Virtual Machine Platform) 활성. 에이전트 **실행**은 관리자 권한을 요구한다
> (HCS UVM create). 설치·자산 조달 자체는 관리자 불요.

---

## 토큰 스코프

실행하면 GitHub 토큰을 물어봅니다(가려서 입력). 필요한 스코프 2개:

| 용도 | 스코프 |
|---|---|
| 프리빌트 번들 다운로드 | `repo` |
| 런타임 이미지 pull | `read:packages` |

발급: github.com/settings/tokens/new → classic → 위 둘 체크 (org SSO 면 **Authorize** 필수)

## 설치 후 / 제거

```sh
# macOS
~/.agent-sandbox/bin/claude-sandbox -p '...'
~/.agent-sandbox/bin/agent-sandbox uninstall
```
```powershell
# Windows (관리자 PowerShell)
& "$env:USERPROFILE\.agent-sandbox\bin\agent-sandbox.exe" claude -p '...'
```

## 이 repo 에 대해

**부트스트랩 스크립트만**(`install.sh`·`install.ps1`) 있는 공개 repo 입니다. 시크릿이 없습니다 — 토큰은
실행 시점에 사용자가 입력하고 `~/.agent-sandbox/registry.env`(0600)에만 저장됩니다. 소스·이미지·바이너리는
private 이며 토큰 없이는 받아지지 않습니다.

스크립트 원본: `iLab-Research/agent-sandbox` 의 `install.sh`·`install.ps1` (private). 이 사본은 릴리스 시
동기화됩니다.
