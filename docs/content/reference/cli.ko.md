+++
title = "CLI 레퍼런스"
description = "모든 gori 서브커맨드와 커맨드라인 플래그."
weight = 10
+++

`gori` 커맨드라인 레퍼런스입니다. 서브커맨드 없이 `gori`를 실행하면 TUI가 시작됩니다.

```text
gori [command] [options]
```

| Command | Description |
|---------|-------------|
| `tui` | 프록시와 터미널 UI 시작 (기본값) |
| `run` | 프로젝트 단위 비대화형 스위트 |
| `mcp` | Model Context Protocol stdio 서버 |
| `ca` | 루트 CA 경로 / PEM 출력, 또는 CA 재생성 / 가져오기 |
| `settings` | `settings.json` 표시 또는 편집 |
| `wizard` | 대화형 최초 실행 설정 |
| `tutorial` | 가이드형 TUI 투어 (탐색, 팔레트, 스페이스 메뉴, 편집 모드) |
| `update` | 채널 인식 자체 업데이트 (바이너리 / Homebrew / Snap / AUR) |

전역 플래그: `-v` / `--version`, `-h` / `--help`.

## gori tui {#gori-tui}

인터셉트 프록시와 TUI를 시작합니다. 서브커맨드를 주지 않으면 이것이 기본값입니다.

```bash
gori
gori tui --listen 0.0.0.0 --port 8080
```

| Option | Description |
|--------|-------------|
| `-l`, `--listen=HOST` | 이 프로세스의 전역 바인드 주소 (`settings.json` 기본값, 없으면 `127.0.0.1`). 저장되지 않음. 프로젝트 자체 바인드가 설정되어 있으면 그쪽이 우선 |
| `-p`, `--port=PORT` | 이 프로세스의 전역 바인드 포트, `0`-`65535` (`settings.json` 기본값, 없으면 `8070`). 저장되지 않음. 프로젝트 `net.bind_port`가 설정되어 있으면 그쪽이 우선 |
| `--db=PATH` | SQLite 데이터베이스 경로 |
| `--ca-dir=PATH` | 루트 CA 디렉터리 |
| `--insecure-upstream` | 업스트림 TLS 인증서를 검증하지 않음 |

> `GORI_HOME`은 플래그가 아니라 환경 변수입니다. TUI에서는 프로젝트 피커로 프로젝트를 고릅니다. 바인드 플래그는 이번 실행에 한해 전역 계층만 설정합니다. [설정](/ko/getting-started/configuration/#network)을 참고하세요. 루트 CA 경로는 [`gori ca`](#gori-ca)를 사용하세요.

## gori run {#gori-run}

비대화형 스위트입니다. 각 서브커맨드는 프로젝트 단위로 동작합니다. `--project`와 `--db`가 모두 없으면 가장 최근에 활성화한 프로젝트를 씁니다.

```bash
gori run <subcommand> [options]
```

| Subcommand | Description |
|------------|-------------|
| `capture` | 프록시를 실행하고 캡처한 플로우를 STDOUT으로 스트리밍 |
| `history` (`ls`) | 캡처한 플로우 목록 / 쿼리 |
| `show <flow-id>` | 플로우 하나의 요청과 응답 출력 |
| `repeater <flow-id>` · `list` · `create` | 캡처한 플로우 재전송, 또는 Repeater 워크벤치 세션 목록 / 생성 |
| `fuzz [<flow-id>]` | Intruder 스타일 퍼저 |
| `mine [<flow-id>]` | 숨은 파라미터 탐색 |
| `sequence` (`seq`) `[<flow-id>]` | 토큰 무작위성 평가 (라이브 리플레이, 또는 붙여넣은 목록은 `--tokens`) |
| `probe [QL]` | 패시브 보안 스캔 (요청 없음) |
| `discover` | 엔드포인트를 스파이더링 & 브루트포스하여 Sitemap으로 반영 |
| `sitemap [QL]` | 호스트 → 경로 엔드포인트 트리 |
| `oast listen` · `presets` | 아웃오브밴드 콜백 리스너 (interactsh 및 유사 서비스) |
| `jwt [<token>]` | JWT 디코드, 재서명, 또는 공격 페이로드 생성 |
| `convert <chain> [input]` | Decoder 인코드 / 디코드 / 해시 체인 실행 |
| `notes [<n>]` · `create` · `delete` | 프로젝트 노트 읽기, 작성, 삭제 |
| `issues` · `create` · `update` | 이슈 목록 / 내보내기, 또는 이슈 작성 |
| `rewriter` · `add` · `rm` · `enable` · `disable` · `preview` | Match & Replace 규칙 관리 |
| `project [list]` | 알려진 프로젝트 목록 |
| `project scope` | 스코프 규칙 목록 / 추가 / 삭제 / 활성화 / 비활성화 |
| `project env` | 프로젝트 env 변수 목록 / 설정 / 삭제 (`$KEY` 치환) |

읽기 서브커맨드에 공통인 플래그: `--project=NAME`, `--db=PATH`, `--format=FMT` (보통 `text` 또는 `json`).

### run capture {#run-capture}

```bash
gori run capture --port 8070 --format json --for 5m
```

| Option | Description |
|--------|-------------|
| `-l`, `--listen`; `-p`, `--port` | 이 프로세스의 전역 바인드 (설정 기본값; 프로젝트 오버라이드가 여전히 우선) |
| `--project=NAME` | 기록할 프로젝트 (기본값 `default`) |
| `--db=PATH` | 데이터베이스 경로 |
| `-k`, `--insecure-upstream` | 업스트림 TLS 검증 생략 |
| `--format=FMT` | `text` 또는 `json` (JSON Lines) |
| `--for=DURATION` | 예: `30s`, `5m`, `1h` 이후 중지 |
| `--max=N` | 플로우 N개 이후 중지 |

### run history / ls {#run-history-ls}

```bash
gori run history -q 'status:5xx' --limit 100 --format json
```

| Option | Description |
|--------|-------------|
| `-q`, `--query=QL` | 쿼리 언어 필터 (위치 인자로도 허용) |
| `-n`, `--limit=N` | 최대 행 수 (기본값 50) |
| `--format=FMT` | `text` 또는 `json` |

### run show {#run-show}

```bash
gori run show <flow-id> --format raw
```

`--format`은 `text`, `json`, 또는 `raw`(정확한 바이트)입니다. `--request-only` / `--response-only`로 출력을 제한합니다. 디코드된 SAML/JWT/GraphQL/파라미터, WebSocket 메시지, SSE 이벤트가 있으면 함께 포함됩니다.

### run repeater {#run-repeater}

캡처한 플로우 하나를 재전송하거나, TUI와 공유되는 Repeater 워크벤치 세션을 관리합니다.

```bash
gori run repeater <flow-id> --target https://staging.example.com --http2 --diff
```

| Option | Description |
|--------|-------------|
| `--target=URL` | 다른 URL로 전송 |
| `--http2` | HTTP/2 사용 |
| `--sni=HOST` | TLS SNI 오버라이드 |
| `-k`, `--insecure-upstream` | 업스트림 TLS 검증 생략 |
| `-H`, `--header=HEADER` | 요청 헤더 덮어쓰기/추가 (반복 가능) |
| `-b`, `--body=BODY` | 요청 본문 오버라이드 |
| `--diff` | 원본 응답과 비교 |
| `--format=FMT` | `text` (기본값) 또는 `json` |

**`repeater list`**: 저장된 Repeater 세션 목록 (`--format text|json`).

**`repeater create`**: Repeater 세션 생성:

```bash
gori run repeater create --target https://api.example.com --request-file req.txt --name "login probe"
gori run repeater create --flow 42 --name "clone of 42"
```

| Option | Description |
|--------|-------------|
| `-t`, `--target=URL` | 대상 URL (`--flow`로 복제하는 경우가 아니면 필수) |
| `-f`, `--request-file=FILE` | FILE에서 원시 HTTP 요청을 읽음 |
| `-r`, `--request-raw=RAW` | 원시 HTTP 요청 문자열 그대로 |
| `--flow=ID` | 캡처한 플로우에서 요청 / 대상 / HTTP/2 복제 |
| `--name=NAME` | 사용자 지정 탭 이름 |
| `--http2`, `--no-auto-cl`, `--sni=HOST` | HTTP/2, 자동 `Content-Length` 생략, SNI 오버라이드 |

### run fuzz {#run-fuzz}

소스: `--flow=ID`, `--request=FILE`, 또는 stdin. 위치: `§…§` 마커, `--auto`, 또는 `--mark=TOKEN`.

| Group | Options |
|-------|---------|
| Transport | `--target=URL` (`--request`/stdin에 필수), `--http2`, `--sni=HOST`, `-k`/`--insecure-upstream` |
| Mode | `--mode=` `sniper` (기본값), `batteringram`, `pitchfork`, `clusterbomb` |
| Payloads | `-w`/`--wordlist`, `--payloads=LIST`, `--numbers=FROM-TO[:STEP]`, `--null=N`, `--brute=CHARSET:MIN-MAX` |
| Processors | `--prefix`, `--suffix`, `--encode` (`url`\|`urlall`\|`base64`\|`hex`), `--case` (`upper`\|`lower`), `--hash` (`md5`\|`sha1`\|`sha256`), `--regex-replace=/pat/rep/` |
| Rate | `--concurrency` (20), `--rate=RPS`, `--throttle=MS`, `--timeout=SEC`, `--retries=N`, `--follow-redirects` |
| Matchers | `--mc`/`--fc` status, `--ms`/`--fs` size, `--mw`/`--fw` words, `--ml`/`--fl` lines, `--mr`/`--fr` body regex, `--extract=REGEX`, `--ac` auto-calibrate |
| Output | `--format` (`text`\|`json`\|`jsonl`), `--force`, `--fail-if-no-matches` |

### run mine {#run-mine}

```bash
gori run mine <flow-id> --locations query,headers --wordlist params.txt
```

| Option | Description |
|--------|-------------|
| `--flow`, `--request`, `--target`, `--sni`, `--http2`, `-k` | 요청 소스와 트랜스포트 |
| `--locations=LIST` | `query`, `form`, `json`, `headers`, `cookies` |
| `--wordlist`, `--bucket=N` | 후보 이름과 버킷 크기 |
| `--concurrency` (10), `--rate`, `--throttle`, `--timeout`, `--retries` (1), `--max-requests=N` | 속도 제어 |
| `--format` | `text`, `json`, 또는 `jsonl` |

### run sequence {#run-sequence}

토큰의 무작위성을 평가합니다. **라이브**: 요청을 리플레이하며 각 응답에서 토큰을 추출합니다. **수동**: `--tokens`로 붙여넣은 목록을 분석합니다(네트워크 없음). 별칭 `seq`.

```bash
gori run sequence 42 --cookie SESSIONID --count 500
gori run sequence --tokens tokens.txt          # '-' reads stdin
```

| Option | Description |
|--------|-------------|
| `--flow=ID`, `--request=FILE`, stdin | 라이브 리플레이의 요청 소스(또는 맨 앞의 `<flow-id>`) |
| `--tokens=FILE` | 붙여넣은 토큰 목록 분석(한 줄에 하나, `-`=stdin), 네트워크 없음 |
| 토큰 위치(하나만 선택) | `--cookie=NAME`, `--header=NAME`, `--regex=RE`, `--position=A:B`, `--jsonpath=EXPR` |
| `--count=N` | 목표 토큰 개수(기본값 500) |
| `--target`, `--http2`, `--sni`, `-k` | 트랜스포트(`--request`/stdin에는 target 필요) |
| `--concurrency` (1), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | 속도 제어(상태 기반 토큰을 위해 concurrency는 1 유지) |
| `--format` | `text`, `json`, 또는 `jsonl` |

### run probe {#run-probe}

```bash
gori run probe --severity high --category cors
```

`--severity`는 `info`\|`low`\|`medium`\|`high`\|`critical` 중 하나입니다. `--category`는 `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors`이며, 여기서는 패시브 검사만 다룹니다. `active` 프로브는 TUI에서 실행합니다. `-q`/`--query`로 QL 필터를 겁니다.

### run discover {#run-discover}

대상을 스파이더링하고 링크되지 않은 경로를 브루트포스합니다. `--no-store`가 아니면 결과는 Sitemap으로 반영됩니다. 실제 요청을 무단으로 보내므로 권한이 있는 대상에만 실행하세요.

```bash
gori run discover --target https://target.example --max-depth 3 --extensions php,json,bak --format jsonl
```

| Option | Description |
|--------|-------------|
| `--target=URL` | 탐색할 시드 origin 또는 경로 하위 트리(필수) |
| `--max-depth=N` | 시드로부터의 스파이더 깊이(기본값 4) |
| `--no-spider` / `--no-bruteforce` | 링크 크롤링 / 디렉터리 브루트포스 비활성화 |
| `--wordlist=PATH` | 내장 목록과 병합할 추가 경로 워드리스트 |
| `--extensions=LIST` | 이 확장자도 프로브(예: `php,json,bak`) |
| `-H`, `--header=HEADER` | 모든 프로브에 붙일 커스텀 헤더(반복 가능) |
| `--containment=MODE` | `same-origin` \| `scope-aware`(기본) \| `host+subdomains` |
| `--concurrency` (20), `--rate`, `--throttle`, `--timeout`, `--retries`, `--max-requests=N` | 속도 제어 |
| `-k`, `--insecure-upstream` | 업스트림 TLS 검증 생략 |
| `--allow-unscoped` | 대상이 프로젝트 스코프 밖이어도 실행 |
| `--force` | 무제한 실행 안전 게이트 우회 |
| `--no-store` | 결과를 프로젝트에 기록하지 않음 |
| `--format` | `text`, `json`, 또는 `jsonl` |

### run sitemap {#run-sitemap}

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL`는 history와 같은 QL로 엔드포인트를 거릅니다(위치 인자로도 넘길 수 있습니다). `-n`/`--limit=N`은 스캔할 엔드포인트 수를 제한합니다(기본값 `SITEMAP_MAX`). `--in-scope`는 스코프 내 호스트로 한정하고, `--no-group`은 id 접기를 끕니다. `--format`은 `text`(트리), `json`, `paths` 중에서 고릅니다.

### run oast {#run-oast}

즉석에서 쓰는, 저장소 없는 아웃오브밴드 리스너입니다. 페이로드를 등록하고 출력한 뒤 콜백을 스트리밍합니다.

```bash
gori run oast presets                          # list built-in public providers
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site --once --json
```

`presets`는 공개 프로바이더를 나열합니다. `listen` 옵션:

| Option | Description |
|--------|-------------|
| `--provider=KIND` | `interactsh`(기본) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--server=URL` | 프로바이더 서버 / 베이스 URL(기본값: 프로바이더의 공개 프리셋) |
| `--token=TOK` | 선택적 프로바이더 인증 토큰 |
| `--interval=SEC` | 폴링 간격(기본값 5) |
| `--once` | 한 번만 폴링하고 종료 |
| `--json` | 각 콜백을 JSON 라인으로 출력(MCP와 동일한 형태) |

### run jwt {#run-jwt}

JWT를 디코드, 재서명, 또는 공격 페이로드를 생성합니다. 저장소 없는 계산이며, 토큰은 `<token>` 인자나 stdin에서 받습니다.

```bash
gori run jwt eyJhbGci...                        # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --attacks
```

| Option | Description |
|--------|-------------|
| `--decode` | header / payload / signature 디코드(기본) |
| `--encode` | `--alg` / `--secret`로 토큰 클레임 재서명 |
| `--attacks` | 테스트 페이로드 생성(alg:none, weak-secret, header injection) |
| `--alg=ALG` | `--encode`용 서명 alg: `HS256`(기본) \| `HS384` \| `HS512` \| `none` |
| `--secret=SECRET` | HS 알고리즘 `--encode`용 HMAC 시크릿 |
| `--format` | `text`(기본) 또는 `json` |

### run decoder {#run-decoder}

값에 대해 [Decoder](/ko/guide/decoder/) 체인을 실행합니다. 단계는 `|`, `>`, `,`로 구분합니다.

```bash
gori run decoder 'base64-decode | jwt-decode' "$TOKEN"
echo -n secret | gori run decoder 'sha256 | hex-encode'
gori run decoder list                           # every converter (name, category, direction)
```

| Option | Description |
|--------|-------------|
| `--input=STR` | 변환할 값(없으면 두 번째 위치 인자, 그것도 없으면 stdin) |
| `-o`, `--output=MODE` | 최종 바이트 렌더링: `auto`(기본) \| `text` \| `base64` \| `hex` |
| `--format` | `text`(기본) 또는 `json`(단계별 상세) |

### run issues / notes {#run-issues-notes}

```bash
gori run issues --format markdown --export report.md
gori run notes --all
```

스크립트에서 `create` / `update`로 이슈를 작성합니다:

```bash
gori run issues create --title "Reflected XSS on /search" --severity high --host app.example.com --flow 42
gori run issues update 7 --status confirmed --notes "Verified on staging" --severity critical
```

| Option | Description |
|--------|-------------|
| `create` | `-t`/`--title` (필수), `-s`/`--severity` (`info`\|`low`\|`medium`\|`high`\|`critical`), `--host`, `--flow=ID` |
| `update <id>` | `-t`/`--title`, `-s`/`--severity`, `-n`/`--notes`, `--status` (`open`\|`confirmed`\|`false-positive`\|`resolved`) |

노트도 읽고 쓸 수 있습니다. 인자 없이 `notes`를 실행하면 목록을 보여주고(`*`가 활성 노트), `notes <n>`은 인덱스로 하나를 출력합니다:

```bash
gori run notes                                  # 목록
gori run notes 2                                # 2번 노트 출력
gori run notes create --text "SSRF candidate on /fetch"
echo "pasted from a scratchpad" | gori run notes create
gori run notes delete 2
```

| Option | Description |
|--------|-------------|
| `list` | `--all`은 요약 한 줄 대신 모든 노트를 전문으로 출력 |
| `create` | `--text=TEXT`, 위치 인자, 또는 STDIN |
| `delete <n>` (`rm`) | 인덱스 `n`의 노트 삭제 |

### run rewriter {#run-rewriter}

스크립트에서 Match & Replace 규칙을 관리합니다. [Rewriter 탭](/guide/proxy/)이 편집하는 것과 같은 규칙이며, 실시간 프록시 트래픽에 적용됩니다:

```bash
gori run rewriter                                       # 적용 순서대로 규칙 목록
gori run rewriter add --op set_header --target request \
  --find X-Forwarded-For --value 127.0.0.1 --host '*.example.com'
gori run rewriter add --op replace --target response --part body \
  --match regex --find 'secret=(\w+)' --value 'secret=[redacted]'
gori run rewriter preview --op replace --part body --find password --value hunter2
gori run rewriter disable 3
gori run rewriter rm 3
```

| Option | Description |
|--------|-------------|
| `--op=OP` | `replace`(기본값), `add_header`, `set_header`, `remove_header` |
| `--target=SIDE` | `request`(기본값) 또는 `response` |
| `--part=PART` | `head`(기본값) 또는 `body`. `replace`에서만 의미가 있음 |
| `--match=MODE` | `literal`(기본값) 또는 `regex`, `replace` 전용. 정규식 치환은 `$1`, `$2`를 쓰고 `$$`는 리터럴 `$` |
| `-f`, `--find=FIND` | 필수. 대상이 되는 리터럴, 패턴, 또는 헤더 이름 |
| `-v`, `--value=VALUE` | 치환할 텍스트 또는 헤더 값 |
| `--host=GLOB` | 매칭되는 호스트로 규칙을 한정(부분 문자열, `*` 와일드카드). 생략하면 전체 적용 |
| `--name=NAME` | 규칙 목록에 표시할 라벨 |
| `--disabled` | 규칙을 만들되 활성화하지 않음 |

`preview`는 같은 규칙 플래그를 받아, 규칙을 저장하지 않고 저장된 플로우 중 몇 개가 바뀌었을지 보고합니다. `rm`(`delete`), `enable`, `disable`은 목록의 규칙 id를 받습니다.

본문 규칙은 필요에 따라 `Content-Length`를 다시 맞추고 청크를 해제하며, 활성화된 규칙은 매칭되는 호스트에서 HTTP/1.1을 강제합니다. 대화형 편집기는 [Proxy & History](/guide/proxy/)를 참고하세요.

### run project {#run-project}

알려진 프로젝트 목록, 또는 프로젝트 스코프 설정(스코프 규칙, env 변수, 호스트 오버라이드) 관리:

```bash
gori run project --format json
gori run project list
```

#### project scope {#run-project-scope}

프로젝트의 include/exclude 스코프 규칙을 스크립트에서 관리합니다:

```bash
gori run project scope                                          # list rules + enabled state
gori run project scope --format json
gori run project scope add --kind=include --type=host --pattern=api.example.com
gori run project scope add --kind=exclude --type=regex --pattern='.*\.(css|js)$'
gori run project scope delete 3
gori run project scope enable
gori run project scope disable
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | 규칙 목록; `--format`은 `text` 또는 `json` |
| `add` | `--kind=include\|exclude`, `--type=host\|string\|regex`, `--pattern=…` |
| `delete <rule-id>` | id로 규칙 제거 |
| `enable` / `disable` | 스코프 필터링 적용 여부 토글 |

#### project env {#run-project-env}

아웃바운드 요청의 `$KEY` 치환에 쓰이는 **프로젝트** env 변수를 관리합니다. 전역 변수는 `settings.json` / TUI Settings에 있고, 이 명령은 프로젝트 레이어만 다룹니다.

```bash
gori run project env                              # list KEY=value
gori run project env --format json
gori run project env set TOKEN=secret
gori run project env set HOST api.example.com
gori run project env delete TOKEN
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | 프로젝트 변수 목록; `--format`은 `text` 또는 `json` |
| `set KEY=value` · `set KEY value` | 프로젝트 변수 upsert (KEY는 `[A-Za-z_][A-Za-z0-9_]*`) |
| `delete KEY` | 프로젝트 변수 제거 |

#### project host-override {#run-project-host-override}

**프로젝트** 호스트 오버라이드를 관리합니다. `/etc/hosts`처럼 호스트명에 대해 dial할 IP만 바꾸고, SNI·인증서 호스트·`Host` 헤더는 원래 이름을 유지합니다. 충돌 시 프로젝트 항목이 전역 호스트네임 오버라이드보다 우선합니다. 별칭: `host-overrides`.

```bash
gori run project host-override                              # list
gori run project host-override --format json
gori run project host-override add --host=api.example.com --ip=10.0.0.1
gori run project host-override add 10.0.0.1 api.example.com   # /etc/hosts 순서
gori run project host-override update 1 --host=api.example.com --ip=10.0.0.9
gori run project host-override delete 1
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) | 오버라이드 목록; `--format`은 `text` 또는 `json` |
| `add` | `--host=…` + `--ip=…`, 또는 positional `IP HOST` |
| `update <id>` | `--host=…` + `--ip=…` (둘 다 필수) |
| `delete <id>` | id로 오버라이드 제거 |

## gori mcp {#gori-mcp}

MCP stdio 서버입니다. 도구 세부사항은 [MCP 가이드](/ko/guide/mcp/)를 참고하세요.

| Option | Description |
|--------|-------------|
| `--db=PATH` | 이 데이터베이스를 제공 (`--project`보다 우선) |
| `--project=NAME` | 이름이 지정된 프로젝트의 데이터베이스 제공 |
| `--use-active-project` | Git 워크스페이스 선택을 무시하고 활성 TUI/MRU 프로젝트를 명시적으로 제공 |
| `--insecure-upstream` | `send_request`: 업스트림 TLS 검증 생략 |
| `--read-only` | 액션 도구 비활성화 (`send_request`, 이슈 생성/수정, fuzz/mine) |
| `--install-claude` | Claude Desktop `mcpServers` 설정 기록 |
| `--install-claude-code` | Claude Code `~/.claude.json` `mcpServers` 항목 기록 |
| `--install-codex` | OpenAI Codex `~/.codex/config.toml` `[mcp_servers.gori]` 기록 |
| `--install-agy` | Antigravity `~/.gemini/antigravity-cli/mcp_config.json` 기록 |
| `--install-grok` | Grok `~/.grok/config.toml` `[mcp_servers.gori]` 기록 |

## gori ca {#gori-ca}

```bash
gori ca
gori ca --pem
gori ca --ca-dir=DIR
gori ca regenerate
gori ca regenerate --yes
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

gori 루트 CA 인증서의 경로를 출력합니다(최초 사용 시 생성). 브라우저나 시스템 저장소에서 CA를 신뢰시킬 때, 또는 클라이언트에 `--cacert`를 지정할 때 사용하세요.

| Option | Description |
|--------|-------------|
| `--ca-dir=DIR` | CA 디렉터리 (기본값 `~/.gori/ca`, 또는 `$GORI_HOME/ca`) |
| `--pem` | 경로 대신 인증서 PEM을 stdout으로 출력 |

### gori ca regenerate {#gori-ca-regenerate}

디스크의 루트 CA를 새로 발급한 것으로 교체합니다. **파괴적**: 이전 CA를 신뢰하던 모든 클라이언트는 새 인증서를 다시 신뢰해야 합니다. 이미 실행 중인 gori 프로세스는 재시작 전까지 이전 CA를 메모리에 유지합니다.

| Option | Description |
|--------|-------------|
| `--yes`, `-y` | 대화형 확인 생략 (stdin이 tty가 아닐 때 필수) |
| `--ca-dir=DIR` | 재생성할 CA 디렉터리 |

`--yes` 없이는 tty에서 프롬프트가 뜨며 `regenerate`를 입력하도록 요구합니다(TUI 확인과 같은 단어). 스크립트와 CI는 `--yes`를 전달해야 합니다. 성공하면 새 인증서 경로가 stdout으로 출력됩니다.

### gori ca import {#gori-ca-import}

외부에서 생성한 루트 CA(인증서 + 일치하는 개인 키, 둘 다 PEM)를 gori 자체 CA 대신 채택합니다. 팀이나 여러 머신에서 하나의 CA를 공유하거나, 조직 CA를 재사용하기 위해서입니다. gori는 호스트별 리프 인증서를 즉석에서 서명하므로 두 파일이 모두 필요합니다. 클라이언트는 인증서만 신뢰합니다. `regenerate`처럼 **파괴적**이며, 디스크의 루트를 교체하고 기존 신뢰를 무효화합니다.

| Option | Description |
|--------|-------------|
| `--cert FILE` | 채택할 루트 CA 인증서 PEM (필수) |
| `--key FILE` | 일치하는 개인 키 PEM (필수) |
| `--yes`, `-y` | 대화형 확인 생략 (stdin이 tty가 아닐 때 필수) |
| `--ca-dir=DIR` | 설치할 CA 디렉터리 |

무엇이든 디스크에 기록하기 전에 쌍을 먼저 검증합니다: 키는 인증서와 일치해야 하고 인증서는 CA여야 합니다(`basicConstraints CA:TRUE`). 쌍이 맞지 않으면 현재 CA를 건드리지 않고 중단합니다. 만료되었거나 아직 유효하지 않은 인증서는 경고만 남기고 그대로 가져옵니다. tty에서 `import`를 입력하여 확인하거나 `--yes`를 전달하세요. 같은 동작을 TUI 팔레트(**Import CA certificate**)에서도 사용할 수 있습니다.

OpenSSL로 루트를 생성한 뒤 가져옵니다:

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

클라이언트에서는 `root.crt.pem`만 신뢰하세요. 개인 키는 절대 배포하지 마세요.

## gori settings {#gori-settings}

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in $EDITOR
```

## gori wizard {#gori-wizard}

```bash
gori wizard
```

대화형 설정(전역 프록시 바인드 기본값, 그다음 테마)을 실행합니다. 최초 실행 시에도 자동으로 실행됩니다. 바인드 단계는 공유 `settings.json` 기본값을 기록합니다. 프로젝트는 Project 탭에서 자체 주소를 고정할 수 있으며, `--listen` / `--port`는 이번 실행에 한해서만 오버라이드합니다.

## gori tutorial {#gori-tutorial}

```bash
gori tutorial
```

목업 UI에서 TUI를 대화형으로 둘러봅니다: 탭/패널 탐색, 커맨드 팔레트(`Ctrl-P`), 스페이스 메뉴(`Space`), READ/INS 편집 모드. 각 레슨은 동작을 시연하고 키를 직접 눌러 보도록 안내하며, 마지막 연습 단계는 완료 전에 네 가지를 모두 요구한 뒤 첫 실제 세션으로 안내합니다. `gori wizard` 끝에서 제공되며, 실제 프록시 세션 없이도 언제든 안전하게 다시 실행할 수 있습니다. [빠른 시작](/ko/getting-started/quick-start/)을 참고하세요.

## gori update {#gori-update}

```bash
gori update
gori update --exec   # Homebrew/Snap: run the package-manager command
```

이 `gori` 바이너리가 어떻게 설치되었는지 감지하여 그에 맞게 업데이트합니다:

| Install channel | Behavior |
|-----------------|----------|
| 독립 실행 바이너리 (curl 설치, 수동 다운로드, 워크스페이스 빌드, 또는 어떤 패키지 관리자도 소유하지 않은 `/usr/bin`으로의 수동 복사) | 이 OS/arch에 맞는 최신 GitHub 릴리스 자산을 내려받아 바이너리를 교체 (macOS는 전용 디렉터리의 형제 `lib/`도 갱신) |
| Homebrew | `brew upgrade gori` 출력 (`--exec`로 실행; brew 관리 경로는 절대 덮어쓰지 않음) |
| Snap | `snap refresh gori` 출력 (`--exec`로 실행) |
| pacman / AUR | `yay` / `paru` / `pacman` 안내 출력 |
| deb (dpkg) | `apt` 업그레이드 안내 출력 |
| rpm | `dnf` / `yum` / `zypper` 안내 출력 |

`/usr/bin` 또는 `/bin` 아래 경로는 패키지 소유권(`pacman -Qo`, `dpkg-query -S`, `rpm -qf`)으로 분류됩니다. 관리자가 파일을 소유하면 gori는 절대 덮어쓰지 않습니다. 프로브가 소유자를 찾지 못하면 바이너리 채널이 자체 업데이트합니다. 패키지 도구가 전혀 없으면 `/etc/os-release`(`ID` / `ID_LIKE`)로 Arch 계열 / Debian 계열 / RHEL 계열 안내를 폴백으로 고릅니다.

릴리스 자산 이름은 [설치 가이드](/ko/getting-started/installation/)와 일치합니다(`gori-v*-linux-*` 순수 바이너리, `gori-v*-osx-*.tar.gz` 아카이브). macOS 아카이브 업데이트는 전용 레이아웃(예: curl 설치 프로그램의 `PREFIX/opt/gori`)을 요구하여 번들된 `lib/`가 `/usr/local/lib` 같은 공유 루트 아래에 절대 기록되지 않도록 합니다. 아직 릴리스 자산이 없으면 명령은 릴리스 페이지를 가리키는 명확한 오류로 종료합니다. 조용히 아무 동작도 하지 않는 것이 아닙니다.
