# install.ps1 — agent-sandbox 설치 (Windows x64, HCS 자체부팅). WSL2 distro·Docker Desktop 불요.
#
# install.sh(macOS) 대칭: 이 스크립트는 **런처만** 깐다(agent-sandbox.exe + hcs-boot.exe, 수십 MB).
# 커널·GCS initrd·에이전트 rootfs VHD 같은 무거운 자산은 `agent-sandbox setup` 이 받는다 —
# 재실행 가능하고, 끊겨도 이어받고, doctor 가 빠졌다 하면 setup 이 채운다.
#
# 배포 모델: **소스·이미지 private**. 설치 시 GitHub 토큰 하나로 (1) private 릴리스 런처/자산 다운로드,
# (2) private 이미지 pull 을 모두 해결. 토큰 없으면 가려서 프롬프트.
#
#   irm https://raw.githubusercontent.com/iLab-Research/agent-sandbox-install/main/install.ps1 | iex
#   $env:AGENT_SANDBOX_TOKEN='ghp_...'; irm <install.ps1> | iex        # 비대화형
#
# 토큰 스코프: repo(private 릴리스) + read:packages(이미지 pull).
#   github.com/settings/tokens/new -> classic -> 위 둘 체크 (org SSO 면 Authorize)
#
# 전제: 가상화(Hyper-V/Virtual Machine Platform) 활성. **에이전트 실행은 관리자 권한**을 요구한다
#       (HCS UVM create). 설치·자산 조달 자체는 관리자 불요.
#
# 환경변수: AGENT_SANDBOX_TOKEN / _PREFIX(기본 %USERPROFILE%\.agent-sandbox) / _AGENTS / _VERSION / _REPO
$ErrorActionPreference = 'Stop'

$Slug   = if ($env:AGENT_SANDBOX_REPO)    { $env:AGENT_SANDBOX_REPO }    else { 'iLab-Research/agent-sandbox' }
$Prefix = if ($env:AGENT_SANDBOX_PREFIX)  { $env:AGENT_SANDBOX_PREFIX }  else { "$env:USERPROFILE\.agent-sandbox" }
$Agents = if ($env:AGENT_SANDBOX_AGENTS)  { $env:AGENT_SANDBOX_AGENTS }  else { 'claude codex' }
$Api    = 'https://api.github.com'
$Asset  = 'agent-sandbox-hcs-launcher-amd64.zip'   # release.yml windows 잡 산출(agent-sandbox.exe + hcs-boot.exe)

# ---- 토큰: env 없으면 가려서 프롬프트 ----
$tok = $env:AGENT_SANDBOX_TOKEN
if (-not $tok) {
    $sec = Read-Host -AsSecureString 'GitHub 토큰 입력 (repo + read:packages)'
    $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
if (-not $tok) { throw 'install.ps1: 토큰 필요 (AGENT_SANDBOX_TOKEN 또는 프롬프트).' }
$hdr = @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json' }

# ---- 토큰 소유자 = 레지스트리 username (자동 도출) ----
$ghUser = (Invoke-RestMethod -Headers $hdr "$Api/user").login
if (-not $ghUser) { throw 'install.ps1: 토큰이 유효하지 않음(사용자 조회 실패).' }
Write-Host "== install (Windows) — user=$ghUser, arch=amd64 =="

# ---- 런처 zip 다운로드: private 릴리스 에셋을 토큰으로(API 경유) ----
$ver = if ($env:AGENT_SANDBOX_VERSION) { $env:AGENT_SANDBOX_VERSION } else { 'latest' }
$rel = if ($ver -eq 'latest') { "$Api/repos/$Slug/releases/latest" } else { "$Api/repos/$Slug/releases/tags/$ver" }
$assetObj = (Invoke-RestMethod -Headers $hdr $rel).assets | Where-Object { $_.name -eq $Asset }
if (-not $assetObj) { throw "install.ps1: 릴리스 에셋 못 찾음($Asset @ $ver). 토큰 스코프(repo)·릴리스 확인." }
Write-Host "  다운로드: asset $($assetObj.id) ($Asset)"

New-Item -ItemType Directory -Force "$Prefix\bin" | Out-Null
$zip = "$env:TEMP\agent-sandbox-launcher.zip"
Invoke-WebRequest -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/octet-stream' } `
    -Uri "$Api/repos/$Slug/releases/assets/$($assetObj.id)" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath "$Prefix\bin" -Force
Remove-Item $zip -Force
Write-Host "  설치됨: $Prefix\bin"

# ---- 토큰 보관: setup 의 자산 다운로드·이미지 pull 이 같은 토큰을 쓴다 ----
"AGENT_SANDBOX_REGISTRY_TOKEN=$tok`nAGENT_SANDBOX_REGISTRY_USER=$ghUser" |
    Set-Content "$Prefix\registry.env" -Encoding ascii

# ---- PATH(User) 연결 ----
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$Prefix\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$Prefix\bin;$userPath", 'User')
    Write-Host "  PATH 추가: $Prefix\bin (새 터미널부터 반영)"
}

# ---- setup: 무거운 자산(커널·GCS initrd·rootfs VHD)은 여기서 받는다 ----
Write-Host ""
& "$Prefix\bin\agent-sandbox.exe" setup --agents $Agents
if ($LASTEXITCODE -ne 0) {
    Write-Error "install.ps1: 런처는 설치됐으나 자산 설치 실패. 고친 뒤 재실행: agent-sandbox setup"
    exit 1
}

Write-Host ""
Write-Host "완료. 에이전트 실행은 **관리자 PowerShell**에서:"
Write-Host "  & '$Prefix\bin\agent-sandbox.exe' claude -p '...'"
