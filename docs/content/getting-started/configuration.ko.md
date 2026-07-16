+++
title = "설정"
description = "gori가 데이터를 저장하는 위치, 네트워크 설정 방법, 그리고 루트 CA를 다룹니다."
+++

gori는 전역 환경설정을 JSON 설정 파일에 보관하고, 각 프로젝트를 자체 SQLite 데이터베이스로 저장합니다. 이 페이지는 모든 것이 어디에 있고 핵심을 어떻게 바꾸는지 다룹니다.

## gori 홈 디렉터리 {#the-gori-home-directory}

gori가 기록하는 모든 것은 하나의 트리 `GORI_HOME` 아래에 있습니다. 해당 환경 변수가 설정되어 있고 비어 있지 않으면 `$GORI_HOME`으로, 아니면 `~/.gori`로 해석됩니다:

```
~/.gori/
├── settings.json       # Global preferences
├── gori.db             # Default database
├── projects/           # One subdirectory per project, each with its own DB
├── ca/                 # Root CA (root.crt.pem + root.key.pem)
├── themes/             # User themes
├── wordlists/          # Fuzzer / miner wordlists
└── active_project      # Marker for the most-recently-used project
```

한 세션 동안 격리된 홈을 사용하도록 gori를 지정하려면:

```bash
GORI_HOME=/tmp/gori-scratch gori
```

## 전역 설정 {#global-settings}

전역 환경설정은 `settings.json`에 저장됩니다. 경로를 출력하거나 `$EDITOR`에서 열려면:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

지속되는 섹션에는 `network`, `theme`(기본값 `goridark`), `mouse`, `editor`, `tabs`, `layout`, `statusline`, `hostname_overrides`, `env`, `hotkeys`, `decoder`, `mine`이 있습니다. 전체 키 목록은 [설정 레퍼런스](/ko/reference/config/)를 참고하세요.

### Network {#network}

`network` 섹션은 프록시가 어떻게 바인딩되는지, 그리고 트래픽을 업스트림 프록시로 전달할지에 대한 전역 기본값입니다. 자체 네트워크 재정의가 없는 프로젝트는 이 값을 상속합니다:

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| 키 | 기본값 | 설명 |
|-----|---------|-------------|
| `bind_host` | `127.0.0.1` | 전역 기본 수신 주소 |
| `bind_port` | `8070` | 전역 기본 수신 포트 |
| `upstream_proxy` | `""` | 전역 기본 업스트림(`host:port`); 비우면 직접 연결 |

**우선순위**(높은 것부터):

1. **프로젝트별 재정의**(프로젝트 DB의 `net.bind_*`): 설정되어 있으면 해당 프로젝트에 한해 우선합니다.
2. **CLI 플래그**(`--listen` / `--port`): 현재 프로세스에 한해 `settings.json`을 재정의하며 디스크에 기록되지 않습니다.
3. **`settings.json`의 `network`**: 공유되는 기본값(첫 실행 마법사와 Settings: Network가 편집하는 것).
4. **공장 기본값**: 다른 값이 없으면 `127.0.0.1:8070`.

### Theme {#theme}

gori는 21개의 내장 색상 테마(기본값은 `goridark`)를 제공하며 여러분의 JSON 테마도 지원합니다. 커맨드 팔레트(`Ctrl-P` → `settings:theme`)에서 전환하거나 `settings.json`의 `theme`을 설정하세요. [테마 가이드](/ko/guide/themes/)를 참고하세요.

### Hotkeys {#hotkeys}

모든 단축키는 커맨드 팔레트(`Ctrl-P` → `settings:hotkeys`)에서 재지정할 수 있으며 `hotkeys` 키 아래에 지속됩니다. [단축키 가이드](/ko/guide/hotkeys/)를 참고하세요.

### Statusline {#statusline}

TUI 하단에 옵트인으로 추가되는 한 줄입니다(커맨드 팔레트 → **Settings: Statusline**, 또는 `statusline` 키). 활성화하면 gori가 셸 명령을 일정 간격으로 실행하고 그 (ANSI 색상) stdout를 표시합니다. Claude Code의 상태 줄에서 영감을 받은 커스터마이즈 가능한 상태 표시줄입니다. 명령은 실시간 세션의 JSON 스냅샷(프로젝트, 캡처 상태, 플로우 수, 프록시 주소)을 stdin으로 받습니다. 기본적으로 비활성화되어 있으며, 키와 stdin 규약은 [설정 레퍼런스](/ko/reference/config/#statusline)를 참고하세요.

## 프로젝트별 네트워크 재정의 {#per-project-network-overrides}

프로젝트는 전역 파일을 건드리지 않고 자체 바인드 주소, 포트, 업스트림을 고정할 수 있습니다. 이 값들은 프로젝트 데이터베이스(키 `net.bind_host`, `net.bind_port`, `net.upstream_proxy`)에 저장되며 **Project** 탭의 설정 패널에서 편집합니다. 서로 다른 평가에서 서로 다른 포트나 업스트림 프록시가 필요할 때 유용합니다.

필드가 현재 전역 값과 일치하면 gori는 그 재정의를 제거하여 프로젝트가 이후의 전역 변경을 계속 상속하도록 합니다. 따라서 고정을 지우는 것은 "마지막 값을 영원히 얼려 둔다"가 아니라 "다시 Settings / CLI를 따른다"는 의미입니다.

## 루트 CA {#the-root-ca}

HTTPS를 인터셉트하려면 클라이언트가 gori의 루트 인증서를 신뢰해야 합니다. 이 인증서는 `~/.gori/ca`에 `root.crt.pem`과 `root.key.pem`으로 보관됩니다.

```bash
gori ca                       # print the certificate path
gori ca --pem                 # print the PEM to stdout
gori ca --ca-dir /path        # use a custom CA directory
gori ca regenerate --yes      # replace the root CA (scripts/CI; voids prior trust)
```

TUI 커맨드 팔레트(**Regenerate CA certificate**)에서, 또는 대화식으로 `gori ca regenerate`(`regenerate`를 입력해 확인)로 CA를 교체할 수도 있습니다. 두 경로 모두 확인 절차를 거치는데, 교체하면 이전에 발급된 모든 신뢰가 무효화되기 때문입니다. 이미 실행 중인 gori는 재시작 전까지 기존 CA를 유지합니다.

### 자체 CA 사용하기 {#bring-your-own-ca}

CA 하나를 팀이나 여러 머신에서 재사용하려면, 루트를 외부에서 생성한 뒤 가져오세요(인증서 **및** 키: gori는 키로 리프 인증서에 서명하고, 클라이언트는 인증서만 신뢰합니다):

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

같은 동작을 팔레트(**Import CA certificate**)에서도 할 수 있습니다. gori는 가져오기 전에 키가 인증서와 일치하는지, 그리고 그 인증서가 CA인지 확인합니다. 신뢰용으로는 `root.crt.pem`만 배포하고, `root.key.pem`은 비밀로 유지하세요. [`gori ca import`](/ko/reference/cli/#gori-ca-import)를 참고하세요.

팔레트의 **Open browser** 동작은 이미 CA를 신뢰하고 프록시를 경유하는 격리된 프로파일로 설치된 브라우저를 실행합니다([빠른 시작](/ko/getting-started/quick-start/) 참조).

## 전체 레퍼런스 {#full-reference}

모든 설정 키는 [설정 레퍼런스](/ko/reference/config/)를, 모든 명령줄 플래그는 [CLI 레퍼런스](/ko/reference/cli/)를 참고하세요.
