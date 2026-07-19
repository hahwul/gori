+++
title = "설정"
description = "settings.json 키와 GORI_HOME 저장소 레이아웃."
+++

gori는 전역 환경설정을 `settings.json`에, 각 프로젝트를 자체 SQLite 데이터베이스로 저장합니다. 전체 흐름은 [설정 가이드](/ko/getting-started/configuration/)를 참고하세요. 이 페이지는 키 단위 레퍼런스입니다.

## 저장소 레이아웃 {#storage-layout}

모든 것은 `GORI_HOME` 아래에 있습니다(`$GORI_HOME`이 설정되어 있고 비어 있지 않으면 그 값, 아니면 `~/.gori`):

| Path | Contents |
|------|----------|
| `settings.json` | 전역 환경설정 |
| `gori.db` | 기본 프로젝트 데이터베이스 |
| `projects/` | 이름이 지정된 프로젝트마다 하나의 하위 디렉터리, 각각 자체 DB 보유 |
| `ca/` | 루트 CA: `root.crt.pem`과 `root.key.pem` |
| `themes/` | 사용자 테마 |
| `wordlists/` | Fuzzer / miner 워드리스트 |
| `active_project` | 가장 최근에 사용한 프로젝트 마커 |

## settings.json {#settingsjson}

`settings.json`은 JSON입니다. `gori settings` / `gori settings --edit`로 찾거나 편집합니다.

### network {#network}

```json
{
  "network": {
    "bind_host": "127.0.0.1",
    "bind_port": 8070,
    "upstream_proxy": ""
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bind_host` | string | `127.0.0.1` | 전역 기본 리스닝 주소 (프로젝트에 `net.bind_host`가 없을 때 사용) |
| `bind_port` | integer | `8070` | 전역 기본 리스닝 포트 (프로젝트에 `net.bind_port`가 없을 때 사용) |
| `upstream_proxy` | string | `""` | 전역 기본 업스트림(`host:port`); 비어 있으면 직접 연결. 설정 시 프로젝트 `net.upstream_proxy`가 우선 |

CLI `--listen` / `--port`는 현재 프로세스에 한해서만 이 값들을 오버라이드합니다(디스크에 기록되지 않음). [프로젝트별 오버라이드](#per-project-overrides)를 참고하세요.

### layout {#layout}

영역별 TUI 레이아웃 환경설정 (커맨드 팔레트 → **Settings: Layout**). 두 값 모두 공장 기본값이면 생략됩니다.

```json
{
  "layout": {
    "history_preview": false,
    "probe_preview": false,
    "issues_preview": false,
    "history_list_order": "newest",
    "sitemap_expand_depth": -1
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `history_preview` | bool | `false` | History 목록 페이지가 선택한 플로우의 하단 Req\|Res 미리보기를 표시 |
| `probe_preview` | bool | `false` | Probe 목록 페이지가 선택한 이슈의 하단 요약을 표시 |
| `issues_preview` | bool | `false` | Issues 목록 페이지가 선택한 이슈의 하단 요약을 표시 |
| `history_list_order` | string | `"newest"` | 목록 정렬: `"newest"`(최신이 위) 또는 `"oldest"`(오래된 것이 위) |
| `sitemap_expand_depth` | integer | `-1` | 재로딩 후 Sitemap 트리가 열리는 깊이: `-1` = 모두 펼침; `0`-`3` = 이 깊이보다 얕은 노드만 펼침 |

### statusline {#statusline}

TUI 맨 아래에 선택적으로 추가되는 행입니다 (Preferences → **General** → **Statusline**). 활성화하면 gori가 일정 간격으로 셸 명령을 실행하고 그 stdout을 해당 행으로 렌더링합니다. Claude Code의 상태 표시줄에서 영감을 받은 커스터마이즈 가능한 상태 바라고 생각하면 됩니다. 기본적으로 비활성화되어 있으며, 변경하기 전까지는 이 섹션이 `settings.json`에서 생략됩니다.

```json
{
  "statusline": {
    "enabled": true,
    "command": "printf 'proj:%s flows:%s' \"$(jq -r .project)\" \"$(jq -r .flows)\"",
    "interval": 3
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | statusline 행 표시 여부 |
| `command` | string | `""` | `/bin/sh -c`로 실행되는 셸 명령. stdout의 첫 줄이 행이 됨 |
| `interval` | integer | `3` | 실행 간격 초 (최소 `1`) |

명령의 stdout은 ANSI/SGR 색상 이스케이프(16색, 256색, truecolor, 그리고 볼드/밑줄 등)를 파싱하므로 색상이 있는 세그먼트를 만들 수 있습니다. 첫 줄만 사용되며, 출력은 터미널 너비로 잘립니다. `interval`초를 초과하는 실행은 종료되고, 실패한 명령은 그냥 행을 비워 둡니다. UI를 절대 막지 않습니다.

각 실행은 라이브 세션을 설명하는 JSON 컨텍스트를 stdin으로 받으므로, 스크립트는 gori를 쿼리하지 않고도 프록시 상태를 표시할 수 있습니다:

```json
{
  "version": 1,
  "project": "acme",
  "capturing": true,
  "flows": 1234,
  "proxy": { "host": "127.0.0.1", "port": 8070, "addr": "127.0.0.1:8070" },
  "upstream": ""
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | 컨텍스트 스키마 버전 (현재 `1`) |
| `project` | string | 활성 프로젝트 이름 |
| `capturing` | bool | 프록시가 현재 캡처 중인지 여부 |
| `flows` | integer | 캡처한 플로우 수 |
| `proxy.host` / `proxy.port` / `proxy.addr` | string / integer / string | 프록시가 실제로 리스닝 중인 주소 |
| `upstream` | string | 업스트림 프록시 `host:port`, 직접 연결이면 비어 있음 |

### display {#display}

메시지 본문과 화면 요소 설정입니다 (커맨드 팔레트 → **Settings: Display**). 모든 값이 기본값이면 섹션이 생략됩니다.

```json
{
  "display": {
    "detail_pane": "request",
    "history_time_format": "absolute",
    "show_gutter": true,
    "preview_body_kib": 64,
    "resource_meter": true,
    "terminal_title": "project"
  }
}
```

| 키 | 타입 | 기본값 | 설명 |
|-----|------|---------|-------------|
| `detail_pane` | string | `"request"` | History 플로우를 열었을 때 먼저 보여줄 페인: `"request"` 또는 `"response"` |
| `history_time_format` | string | `"absolute"` | History 목록의 시간 열: `"absolute"`(MM-DD HH:MM:SS) 또는 `"relative"`(3s/5m/2h) |
| `show_gutter` | bool | `true` | 메시지 본문 뷰의 줄번호 거터 |
| `preview_body_kib` | integer | `64` | History 목록 미리보기가 읽는 본문 바이트 수 (표시 전용이며 캡처 상한과는 별개) |
| `resource_meter` | bool | `true` | 하단 바 맨 오른쪽에 표시되는 gori 자신의 CPU/메모리 |
| `terminal_title` | string | `"project"` | 터미널 창 제목: `"project"` → `Gori - <프로젝트> - <탭>`, `"tab"` → `Gori - <탭>`, `"off"` → gori가 제목을 건드리지 않음 (셸이나 tmux에 맡김) |

### hostname_overrides {#hostname-overrides}

전역 다이얼 맵(충돌 시 프로젝트 레벨 오버라이드가 우선). `/etc/hosts`와 같은 개념입니다:

```json
{
  "hostname_overrides": [
    { "host": "api.prod.internal", "ip": "10.0.0.42" }
  ]
}
```

Preferences → **Network & Tabs** → **Network** → **Hostname overrides**에서, 또는 프로젝트별 항목은 Project 탭에서 편집합니다. [Proxy & History](/ko/guide/proxy/#host-overrides)를 참고하세요.

### env {#env}

`$TOKEN` 같은 토큰은 Repeater, Fuzzer, Miner, Intercept, CLI, MCP에서 전송 시점에 확장됩니다:

```json
{
  "env": {
    "prefix": "$",
    "vars": [
      { "key": "TOKEN", "value": "eyJhbGciOi…" }
    ]
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `prefix` | string | `"$"` | 토큰 접두사 (`$KEY`) |
| `vars` | array | `[]` | 전역 키/값 쌍; 프로젝트 변수(Project 탭 → ENV)가 충돌 시 우선 |

[환경 변수](/ko/guide/repeater-and-fuzzer/#environment-variables)를 참고하세요.

### 그 외 섹션 {#other-sections}

| Section | Description |
|---------|-------------|
| `theme` | 활성 테마 이름 (기본값 `goridark`). [테마 가이드](/ko/guide/themes/) 참고 |
| `mouse` | 마우스 지원 토글 |
| `pretty_bodies` | 상세 뷰에서 JSON/XML 등의 본문을 pretty-print |
| `editor` | 외부 편집기 `command`와 Markdown 처리 |
| `tabs` | 표시/숨김할 TUI 탭 |
| `hostname_overrides` | 전역 host → IP 다이얼 맵. 위의 [hostname_overrides](#hostname_overrides) 참고 |
| `env` | Env 토큰 접두사와 전역 값. 위의 [env](#env) 참고 |
| `hotkeys` | 키바인딩 오버라이드 (`os` 계층 + `bindings`). [단축키 가이드](/ko/guide/hotkeys/) 참고 |
| `decoder` / `mine` | Decoder 도구와 Param Miner의 저장된 기본값 |
| `layout` | History / Probe / Issues 미리보기 + Sitemap 펼침 깊이. 위의 [layout](#layout) 참고 |
| `statusline` | 일정 간격으로 명령을 실행하는 하단 상태 행. 위의 [statusline](#statusline) 참고 |
| `display` | 기본 상세 페인, 목록 시간 형식, 줄번호 거터, 미리보기 본문 상한, `resource_meter`(하단 바 맨 오른쪽 CPU/메모리 표시, 기본 켜짐), 그리고 `terminal_title` |

## 프로젝트별 오버라이드 {#per-project-overrides}

프로젝트는 전역 파일을 수정하지 않고도 자체 네트워크 설정을 고정할 수 있습니다. 이 값들은 프로젝트 데이터베이스에 저장되며(키 `net.bind_host`, `net.bind_port`, `net.upstream_proxy`), **Project** 탭의 설정 패널에서 편집합니다.

열려 있는 프로젝트의 **유효 바인드 / 업스트림**:

| Priority | Source |
|----------|--------|
| 1 (최우선) | 설정되어 있으면 프로젝트 DB `net.bind_host` / `net.bind_port` / `net.upstream_proxy` |
| 2 | CLI `--listen` / `--port` (전역 계층의 프로세스 한정 오버라이드) |
| 3 | `settings.json` `network.*` |
| 4 (최하위) | 공장 기본값 `127.0.0.1:8070` / 직접 연결 |

현재 전역 값과 같은 Project 탭 필드를 저장하면 해당 KV 키가 삭제되므로, 프로젝트는 중복을 고정하는 대신 이후의 전역 변경을 계속 상속합니다.

## 프로젝트와 데이터베이스 {#projects-database}

각 프로젝트는 SQLite 데이터베이스(`crystal-db` / `crystal-sqlite3` 사용)입니다. 여기에는 플로우, WebSocket 메시지, 스코프 규칙, 이슈, match 규칙, HTTP/2 프레임, repeater 및 fuzz 세션, 호스트 오버라이드, sitemap 태그, miner 세션, Probe 이슈가 담기고, 플로우 본문 전체를 훑는 전문 인덱스도 들어 있습니다. 저장하는 요청/응답 본문은 2 MiB로 상한이 걸려 있어, 더 큰 본문은 데이터베이스에서 잘리지만 실제 와이어 크기는 그대로 기록합니다. `--db PATH`로 어떤 프로젝트의 데이터베이스든 직접 지정하거나, `--project NAME`으로 이름이 지정된 프로젝트를 고릅니다.
