+++
title = "플랫폼 지원"
description = "gori가 지원하는 운영체제와 아키텍처, 지원 등급별로 보장하는 것, 그리고 Windows에서 알려진 한계."
weight = 7
+++

gori는 macOS, Linux, Windows용 단일 바이너리로 배포되지만, 모든 플랫폼이 같은 수준으로 보장되지는 않습니다. 플랫폼은 두 등급(tier)으로 나뉩니다. 플랫폼 이름은 릴리스 자산 이름(`linux-arm64`, `osx-x86_64`)처럼 OS와 CPU 아키텍처로 부릅니다. gori는 Crystal로 빌드되므로 각 플랫폼은 컴파일러 자체의 [플랫폼 지원](https://crystal-lang.org/reference/1.21/syntax_and_semantics/platform_support.html) 수준에도 영향을 받습니다.

## Tier 1 {#tier-1}

Tier 1은 "gori 전부가 그대로 동작하는" 플랫폼입니다. 각 플랫폼은 다음을 만족합니다.

- 모든 [GitHub Release](https://github.com/hahwul/gori/releases/latest)에 사전 빌드 바이너리가 올라가고, [curl 설치 스크립트](/ko/getting-started/installation/#quick-install-curl)와 [Homebrew](/ko/getting-started/installation/#homebrew)로 설치할 수 있습니다.
- CI나 릴리스 과정에서 소스로 빌드되고, 릴리스 바이너리는 게시 전에 실제로 실행해 봅니다.
- 매일 쓰입니다. gori는 macOS에서 개발되고, 스펙 스위트는 CI의 Linux x86_64에서 돕니다(PR마다 변경에 대응하는 스펙, `main` 푸시마다 전체 스위트).
- 플랫폼 고유의 알려진 한계가 없습니다.

| 대상 | 릴리스 자산 | 그 밖의 채널 | 검증 방식 |
|------|-------------|--------------|-----------|
| macOS arm64 (Apple Silicon) | `gori-v*-osx-arm64.tar.gz` | Nix | 일상 개발 환경. 릴리스 빌드가 패키징한 tarball에서 `--version` 실행 |
| macOS x86_64 (Intel) | `gori-v*-osx-x86_64.tar.gz` | — | 릴리스 빌드가 패키징한 tarball에서 `--version` 실행 |
| Linux x86_64 | `gori-v*-linux-x86_64` (정적, musl) | AUR, Snap, Nix, Docker | PR마다 변경에 대응하는 스펙, `main` 푸시마다 전체 스펙 스위트. 릴리스 바이너리는 정적 링크 여부 확인 후 실행 |
| Linux arm64 | `gori-v*-linux-arm64` (정적, musl) | Nix, Docker | `main` 푸시마다 Docker 이미지를 네이티브로 빌드. 릴리스 바이너리는 정적 링크 여부 확인 후 실행 |

macOS와 Linux arm64에서는 CI가 스펙 스위트를 돌리지 않습니다. 그래서 이 대상에서만 나타나는 회귀는 CI가 아니라 실사용에서 발견됩니다.

## Tier 2 {#tier-2}

Tier 2는 "동작하지만 알려진 한계가 있는" 플랫폼입니다. 자체 CI에서 빌드되고 통과하며 릴리스 바이너리도 나오지만, 아래와 같은 알려진 한계가 있을 수 있습니다.

| 대상 | 릴리스 자산 | 그 밖의 채널 | 검증 방식 |
|------|-------------|--------------|-----------|
| Windows x86_64 | `gori-v*-windows-x86_64.exe` (정적) | Chocolatey | Crystal 코드를 건드리는 모든 PR마다: 네이티브 빌드, HTTP·HTTPS 요청 하나씩을 프록시한 뒤 프로젝트에서 다시 읽는 스모크 테스트, 실제 Windows 의사 콘솔(ConPTY)에서 TUI 구동, 파일 단위로 나눈 스펙 스위트 |

Windows 릴리스 바이너리는 v0.8.0부터 제공됩니다.

### Windows에서 알려진 한계 {#windows-gaps}

| 영역 | Windows에서는 |
|------|---------------|
| 콘솔 | TUI는 VT 시퀀스를 처리하는 콘솔이 필요합니다. Windows Terminal이나 Windows 10 1809 이상의 콘솔이면 됩니다. |
| 시그널 | POSIX 시그널이 없습니다. Ctrl-C와 Ctrl-Break는 `INT`로, 콘솔 창 닫기·로그오프·종료는 `TERM`으로 처리합니다. 다만 후자는 Windows가 곧바로 프로세스를 끝내므로 정리 작업에 쓸 시간이 거의 없습니다. |
| [`gori run shell`](/ko/reference/cli/#run-shell) | 이 명령이 만드는 CA 번들은 시스템 루트 인증서에서 출발하는데, gori는 그 위치를 Unix 경로에서만 찾습니다. 그래서 Windows에서는 `SSL_CERT_FILE`이 이미 번들을 가리키고 있지 않은 한 gori 루트만 담기고, 그 셸의 도구는 gori가 가로채지 않는 호스트(패스스루 호스트, `NO_PROXY` 대상)에서 TLS 검증에 실패합니다. 전체 번들을 `SSL_CERT_FILE`로 먼저 export해 두면 피할 수 있습니다. 이곳의 기본 `--print` 문법은 PowerShell입니다. |
| 파일 권한 | 루트 CA 키의 `0600` 같은 POSIX 모드가 적용되지 않습니다. `GORI_HOME`(`%USERPROFILE%\.gori`) 아래 파일의 접근 권한은 그 폴더 설정을 따릅니다. |
| `gori update` | Windows는 실행 중인 `.exe`를 덮어쓰지 못하므로, 기존 파일을 옆으로 옮긴 뒤 새 파일을 그 자리에 둡니다. 기존 파일이 아직 실행 중이면 남은 `.gori-update.old.*` 파일은 다음 `gori update`가 지웁니다. Chocolatey로 설치했다면 직접 교체하지 않고 `choco upgrade gori -y`만 출력합니다. gori를 닫고 관리자 셸에서 실행하세요. |
| 설치 스크립트 | curl 설치 스크립트는 macOS와 Linux 전용입니다. [Chocolatey](/ko/getting-started/installation/#chocolatey)나 [직접 다운로드](/ko/getting-started/installation/#windows)를 쓰세요. |
| [gori가 보내는 메시지](/ko/guide/mcp/#messages-from-gori) | Claude Code의 인박스 소켓은 Unix 소켓이라 Windows에서는 찾지 못합니다. 운영자 메시지는 대신 다음 도구 결과나 `operator_messages`로 Claude Code에 전달됩니다. |
| 테스트 범위 | 레거시 스키마 마이그레이션 스펙 파일 두 개(`spec/store/*_autoincrement_migration_spec.cr`)는 Windows에서 한 프로세스로 연달아 돌리면 멈추기 때문에 건너뜁니다. 그 마이그레이션 이전에 만든 프로젝트 데이터베이스의 업그레이드는 POSIX에서만 검증됩니다. |

## 지원하지 않는 플랫폼 {#not-supported}

릴리스 바이너리도, 패키지도, CI도 없습니다. 일부는 [소스에서 빌드](/ko/getting-started/installation/#build-from-source)할 수 있을지 모르지만 그렇다는 걸 확인하는 절차는 없습니다.

| 플랫폼 | 비고 |
|--------|------|
| Windows arm64 | gori 빌드 없음 |
| 32비트 x86·ARM Linux | gori 빌드 없음 |
| 32비트 Windows | gori 빌드 없음 |
| FreeBSD, OpenBSD | 소스 빌드 미검증 |
| 그 밖의 BSD, Android, Solaris | 소스 빌드 미검증 |
