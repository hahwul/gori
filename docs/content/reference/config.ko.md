+++
title = "설정"
description = "settings.json 키와 GORI_HOME 저장소 레이아웃."
weight = 20
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
| `verify_upstream` | bool | `true` | 시스템 CA 트러스트 스토어로 업스트림 TLS 인증서 검증(표준 위치에서 자동 탐색하며 `SSL_CERT_FILE` / `SSL_CERT_DIR` 존중; 스토어를 못 찾으면 HTTPS 검증 실패 — `SSL_CERT_FILE` 지정 또는 끄기). 토글하면 재시작 없이 실행 중인 프록시, 액티브 프로브, Repeater / Fuzzer / Miner 전송기에 즉시 반영됩니다. `--insecure-upstream`은 해당 세션에만 끈 상태로 시작 |
| `serve_landing` | bool | `true` | 내장 안내 / CA 다운로드 페이지 제공. 리슨 주소로 직접 접속한 경우와, 이미 프록시를 설정한 클라이언트가 예약 호스트 `http://gori.proxy/`(또는 `http://gori/`)로 접속한 경우 모두 해당 |
| `connect_timeout_secs` | integer | `30` | 업스트림 연결 타임아웃(초, 최소 `1`) |
| `io_timeout_secs` | integer | `30` | 업스트림 읽기 / 쓰기 유휴 타임아웃(초, 최소 `1`) |
| `capture_max_mib` | integer | `2` | 메시지당 저장하는 본문의 최대 크기(MiB). 더 큰 본문도 바이트 그대로 전달되며, 잘리는 것은 저장본뿐이고 실제 전송 크기는 기록됩니다 |
| `tls_passthrough` | array | `[]` | 복호화하지 않고 그대로 중계할 호스트 목록. 아래 [tls_passthrough](#tls-passthrough)를 참고하세요 |

CLI `--listen` / `--port`는 현재 프로세스에 한해서만 이 값들을 오버라이드합니다(디스크에 기록되지 않음). [프로젝트별 오버라이드](#per-project-overrides)를 참고하세요.

#### tls_passthrough {#tls-passthrough}

호스트가 일치하는 CONNECT는 `200`으로 응답한 뒤 불투명한 바이트 터널로 중계됩니다. 해당 호스트용 인증서를 발급하지 않고, 복호화하지 않으며, 아무것도 캡처하지 않습니다. 클라이언트는 gori가 경로에 없는 것과 똑같이 원 서버의 인증서를 직접 검증합니다.

인증서를 피닝하는 클라이언트(모바일 앱, 자동 업데이터, 데스크톱 에이전트)가 실제 대상과 프록시를 공유할 때 쓰는 탈출구입니다. 이 설정이 없으면 그 트래픽은 깨집니다. 스코프로는 해결되지 않습니다 — 스코프는 무엇을 *기록하고* 개입할지를 결정할 뿐 TLS를 가로챌지는 결정하지 않으므로, 스코프 밖 호스트도 복호화됩니다.

```json
{
  "network": {
    "tls_passthrough": ["updates.example.com", "*.push.apple.com"]
  }
}
```

패턴은 스코프 `host` 룰과 같은 문법입니다. `example.com`은 해당 호스트와 **그 서브도메인**까지 포함하고, `*.push.example.com`은 글롭(서브도메인만, 맨 호스트는 제외)이며, IPv6 리터럴은 대괄호 유무와 무관하게 일치합니다. 대소문자를 구분하지 않습니다. 항목은 호스트만 적습니다 — 스킴, 경로, `:port`가 붙은 항목은 저장 시 거부됩니다(그런 항목은 어떤 것과도 일치할 수 없기 때문입니다).

비어 있으면(기본값) 모두 가로챕니다. 이 설정이 생기기 전 gori의 동작과 같습니다. 평문 HTTP는 영향을 받지 않습니다 — 통과시킬 TLS가 없습니다.

우회된 호스트는 flow를 남기지 않으므로, gori는 호스트별로 처음 중계할 때 로그에 한 줄을 남깁니다. History에서 빠진 호스트의 이유를 추적할 수 있게 하기 위함입니다. 목록은 Preferences → **Network & Tabs** → **Network** → **TLS passthrough**에서 쉼표로 구분해 편집합니다.

### upstream_rules

목적지별 업스트림 라우팅입니다. `network.upstream_proxy`는 *모든* 트래픽에 대한 단일 주소인 반면, 규칙 테이블은 "`*.corp.internal`은 사내 프록시로, 나머지는 직결"을 표현할 수 있고 자격증명을 실을 수 있으며 SOCKS 프록시에 접근할 수 있습니다.

규칙은 **순서가 있고 첫 일치가 이깁니다**. 구체적인 규칙을 위에 두세요. 편집은 `gori settings --edit`.

```json
{
  "upstream_rules": [
    { "host": "intranet.corp.internal", "kind": "direct" },
    {
      "host": "*.corp.internal",
      "kind": "http",
      "addr": "proxy.corp.internal:3128",
      "username": "alice",
      "password_env": "CORP_PROXY_PASS"
    },
    { "host": "*.onion", "kind": "socks5", "addr": "127.0.0.1:9050" }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | 호스트 패턴. 스코프 `host` 룰과 같은 문법 — `corp.internal`은 해당 호스트와 서브도메인, `*.corp.internal`은 글롭, `*`는 catch-all. 대소문자 무관 |
| `kind` | string | `direct`, `http`, `socks5`. 알 수 없는 kind는 규칙을 버립니다(`direct`로 취급하면 의도한 프록시를 조용히 비활성화하게 되므로) |
| `addr` | string | 프록시 `host:port`. 포트 기본값은 `http`가 `8080`, `socks5`가 `1080`. `direct`에는 없어야 합니다 |
| `username` | string | 선택. `http`는 HTTP Basic(RFC 7617), `socks5`는 RFC 1929 교환으로 전송 |
| `password_env` | string | 선택. 비밀번호를 담은 **OS 환경변수의 이름** |

**자격증명은 `settings.json`에 저장되지 않습니다.** 사용자명과 환경변수 *이름*만 기록되고, 비밀번호는 dial 시점에 OS 환경에서 읽습니다. 따라서 `export CORP_PROXY_PASS=…`가 재시작 없이 반영됩니다. gori 자체의 `env` 섹션은 의도적으로 쓰지 않습니다 — 그 변수들은 `settings.json`에 평문으로 저장되므로, 결국 다른 경로로 비밀을 파일에 넣는 셈이고 설정 공유·내보내기([#439](https://github.com/hahwul/gori/issues/439))를 무의미하게 만듭니다. `$`가 포함된 `password_env`는 거부됩니다 — 값이 아니라 변수 이름을 담는 필드입니다.

`socks5`의 경우 호스트명 대상은 `ATYP DOMAIN`으로 전송되어 **프록시가** 이름을 해석합니다(`socks5h` 동작). Tor나 점프호스트 뒤의 도달 불가 네트워크가 이 덕분에 동작하며, gori 자체는 dial 경로에서 이름을 해석하지 않습니다.

우선순위(높은 것부터):

| 우선순위 | 출처 |
|----------|------|
| 1 (최상) | 프로젝트 `net.upstream_proxy` — 명시적 프로젝트 고정으로, 테이블을 통째로 건너뜁니다 |
| 2 | `upstream_rules`의 첫 호스트 일치 |
| 3 | `network.upstream_proxy` — 암묵적 catch-all |
| 4 (최하) | 직접 연결 |

규칙은 [호스트 오버라이드](#hostname_overrides) 적용 **이전의 원래 호스트명**에 대해 매칭됩니다 — 오버라이드는 어느 IP로 접속할지만 바꿉니다.

### outbound_tls

gori가 **거는** 연결의 목적지별 TLS 정책입니다 — 제시할 클라이언트 인증서, 그리고 협상할 프로토콜/암호군 하한. 순서가 있고 첫 일치가 이기며, 호스트 패턴 문법은 동일합니다. 편집은 `gori settings --edit`.

[`upstream_rules`](#upstream_rules)와 의도적으로 분리된 테이블입니다. 둘 다 목적지 호스트로 키를 잡지만 답하는 질문이 다르고, 합치면 가장 흔한 형태를 표현할 수 없게 됩니다 — "전부 사내 프록시 경유 + 한 호스트만 클라이언트 인증서"를 쓰려면 그 호스트 행에 프록시 주소를 중복해야 합니다. 하나의 first-match 테이블은 호스트당 한 행만 적용할 수 있기 때문입니다.

```json
{
  "outbound_tls": [
    {
      "host": "mtls.example.com",
      "client_cert": "/home/you/certs/client.crt.pem",
      "client_key": "/home/you/certs/client.key.pem"
    },
    {
      "host": "legacy-appliance.internal",
      "min_version": "tls1.0",
      "ciphers": "ALL:@SECLEVEL=0",
      "permissive": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `host` | string | 호스트 패턴. `upstream_rules`와 동일하며 `*`는 catch-all |
| `client_cert` | string | 제시할 PEM 인증서 체인 경로(상호 TLS) |
| `client_key` | string | 대응하는 PEM 개인키 경로. 둘 다 있어야 하거나 둘 다 없어야 합니다 |
| `min_version` | string | 협상할 최저 프로토콜: `tls1.0`, `tls1.1`, `tls1.2`, `tls1.3`. 비우면 기본값 |
| `ciphers` | string | TLS 1.2 이하용 OpenSSL 암호군 목록. 비우면 기본값 |
| `permissive` | bool | 망가진/레거시 서버 상대: OpenSSL security level을 0으로 낮추고 재협상을 허용합니다 |

**`min_version`이 필요한 이유.** gori는 기본 상태로 TLS 1.0/1.1만 지원하는 장비에 접근할 수 없고, `verify_upstream: false`로도 해결되지 않습니다 — 그건 인증서 *검증*을 끄는 것이지 프로토콜 협상과 무관합니다. Crystal의 TLS 클라이언트 컨텍스트가 생성자에서 TLS 1.0과 1.1을 비활성화하므로, 여기서 하한을 낮추는 것이 유일한 방법입니다. 레거시 장비는 보통 `permissive: true`도 함께 필요합니다 — 배포판이 OpenSSL을 옛 암호군을 아예 거부하는 security level로 빌드하기 때문입니다.

**인증서는 인라인 값이 아니라 파일 경로입니다.** 개인키는 공유·내보내기 대상인 `settings.json`에 들어갈 것이 아닙니다([#439](https://github.com/hahwul/gori/issues/439)). 패스프레이즈가 걸린 키는 저장 시 거부됩니다 — OpenSSL이 TUI가 점유한 터미널에 패스프레이즈를 물어보므로, gori가 그냥 멈춘 것처럼 보이게 됩니다. `openssl pkey -in key.pem -out plain.pem`으로 먼저 복호화하세요.

정책은 SNI 오버라이드가 아니라 **실제 접속한 호스트**로 조회합니다 — 인증서와 프로토콜 하한은 실제로 대화하는 장비에 속하는 반면, Repeater의 SNI 필드는 도메인 프론팅·vhost 테스트를 위해 의도적으로 이름을 다르게 보내는 기능입니다.

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

### general {#general}

Preferences → **General** → **General**:

```json
{
  "general": {
    "clipboard_osc52": true,
    "confirm_quit": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `clipboard_osc52` | bool | `true` | OSC 52 터미널 이스케이프로 복사. SSH 너머에서도 `y`가 로컬 클립보드에 도달합니다 |
| `confirm_quit` | bool | `false` | 종료 전에 확인 |

### notifications {#notifications}

백그라운드 작업(Miner, Fuzzer, Probe, Discover)이 결과를 알리는 방식입니다. Preferences → **General** → **Notifications**:

```json
{
  "notifications": {
    "bell": false,
    "toast": true,
    "retention": 100
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `bell` | bool | `false` | 백그라운드 작업이 결과를 냈을 때 터미널 벨 울림 |
| `toast` | bool | `true` | 같은 이벤트에 대해 잠깐 나타나는 토스트 표시 |
| `retention` | integer | `100` | 알림 센터가 보관하는 알림 개수 |

### probe {#probe}

```json
{
  "probe": {
    "active_notify": "when-found"
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `active_notify` | string | `"when-found"` | 액티브 스캔의 알림 시점: `"when-found"`, `"always"`, `"off"` |

### discover {#discover}

Discover 실행의 저장된 기본값입니다. discover 옵션을 저장해야 기록되므로 그 전까지는 섹션이 없습니다:

```json
{
  "discover": {
    "containment": "scope-aware",
    "max_depth": 4,
    "concurrency": 20,
    "spider": true,
    "bruteforce": true,
    "extensions": false
  }
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `containment` | string | `"scope-aware"` | 탐색이 벗어날 수 있는 범위: `"same-origin"`, `"scope-aware"`, `"host+subdomains"` |
| `max_depth` | integer | `4` | 스파이더 깊이 상한 |
| `concurrency` | integer | `20` | 동시 요청 수 |
| `spider` | bool | `true` | 응답에서 찾은 링크를 따라감 |
| `bruteforce` | bool | `true` | 워드리스트로 경로 무차별 탐색 |
| `extensions` | bool | `false` | 각 후보의 확장자 변형도 함께 시도 |

### mine {#mine}

Param Miner의 저장된 기본값입니다. mine 옵션을 저장해야 기록됩니다:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `locations` | array | `[]` | 주입 위치: `query`, `form`, `multipart`, `json`, `headers`, `cookies`. 비어 있으면 요청마다 자동 감지 |
| `concurrency` | integer | `10` | 동시 요청 수 |
| `notify` | string | `"when-found"` | `"when-found"`, `"always"`, `"off"` |

### scan_rules {#scan-rules}

직접 만든 Probe 매치 규칙으로, 모든 프로젝트에 걸쳐 전역으로 적용됩니다. 프로젝트 범위 규칙은 대신 프로젝트 데이터베이스에 저장됩니다. Probe → **Rules** → CUSTOM에서 편집합니다:

```json
{
  "scan_rules": [
    {
      "id": "a1b2c3d4",
      "title": "Internal hostname leak",
      "description": "Build-server hostname in a response body",
      "side": "response",
      "region": "body",
      "kind": "regex",
      "pattern": "build-\\d+\\.corp\\.internal",
      "severity": "medium",
      "enabled": true
    }
  ]
}
```

| Key | Type | Description |
|-----|------|-------------|
| `id` | string | 생성 시 부여되는 무작위 hex 토큰 |
| `title` | string | 발견 항목 제목 |
| `description` | string | 발견 상세에 표시 |
| `side` | string | `request` 또는 `response` |
| `region` | string | `whole`, `header`, `body` |
| `kind` | string | `string` 또는 `regex` |
| `pattern` | string | 매칭할 리터럴 또는 정규식 |
| `severity` | string | `info`, `low`, `medium`, `high`, `critical` |
| `enabled` | bool | 규칙 실행 여부 |

파싱은 관대합니다. `id`, `title`, `pattern`이 없는 항목은 버려지고, 허용 범위를 벗어난 `side` / `region` / `kind` / `severity`는 로드를 실패시키는 대신 가장 안전한 값으로 대체됩니다.

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
| `decoder` | 마지막 입력과 체인, 저장된 Decoder 세션과 이름 붙인 체인 |
| `mine` | Param Miner의 저장된 기본값. 위 [mine](#mine) 참고 |
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
