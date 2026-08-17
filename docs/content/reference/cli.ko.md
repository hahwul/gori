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
| `update` | 채널 인식 자체 업데이트 (바이너리 / Homebrew / Snap / AUR / Nix) |

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

비대화형 스위트입니다. 각 서브커맨드는 프로젝트 단위로 동작합니다. `--project`와 `--db`가 모두 없으면 가장 최근에 활성화한 프로젝트를 씁니다. 실제 사용 패턴은 [스크립팅 가이드](/ko/guide/scripting/)를 참고하세요.

```bash
gori run <subcommand> [verb] [options]
```

| Subcommand | Description |
|------------|-------------|
| `capture` | 프록시를 실행하고 캡처한 플로우를 STDOUT으로 스트리밍 |
| `history` (`ls`) | 캡처한 플로우 목록 / 쿼리 |
| `history delete <id>` · `clear` | 플로우 하나를 완전 삭제, 또는 프로젝트 History 전체 비우기 (`--yes`) |
| `show <flow-id>` | 플로우 하나의 요청과 응답 출력 |
| `compare <id-a> <id-b>` | 두 플로우의 요청 또는 응답 diff |
| `intercept` | 캡처 중인 TUI의 라이브 인터셉트 큐 조회 및 조작 |
| `repeater <flow-id>` · `list` · `create` · `send` | 캡처한 플로우 재전송, 또는 Repeater 세션 목록 / 생성 / 실행 (WebSocket 포함) |
| `repeater minimize <id>` | 저장된 요청을 응답이 유지되는 최소 형태로 축약 |
| `repeater h2` | 순서가 있는 HPACK 필드 목록으로 필드 단위 HTTP/2 요청 전송 |
| `fuzz [<flow-id>]` | Intruder 스타일 퍼저 |
| `mine [<flow-id>]` | 숨은 파라미터 탐색 |
| `sequence` (`seq`) `[<flow-id>]` | 토큰 무작위성 평가 (라이브 리플레이, 또는 붙여넣은 목록은 `--tokens`) |
| `authorize [<flow-id>…]` | 캡처된 플로우를 여러 아이덴티티로 재전송하고 각 응답을 기준선과 비교 (접근 제어 결함) |
| `probe [QL]` | 패시브 보안 스캔 (요청 없음) |
| `probe issues` · `dismiss` · `promote` · `delete` | 저장된 Probe 발견 항목 트리아지 |
| `probe rules` · `mode` | 스캔 규칙 목록 / 무장, 스캔 모드 조회 및 설정 |
| `discover` | 엔드포인트를 스파이더링 & 브루트포스하여 Sitemap으로 반영 |
| `import` | HAR / URL 목록 / OpenAPI / Postman / Insomnia / Burp 파일에서 History로 플로우 일괄 임포트 |
| `sitemap [QL]` | 호스트 → 경로 엔드포인트 트리 |
| `sitemap tag` | Sitemap 경로에 자유 텍스트 메모를 고정 / 해제 / 목록 |
| `oast listen` · `presets` | 아웃오브밴드 콜백 리스너 (interactsh 및 유사 서비스) |
| `oast list` · `resume` · `release` | 프로젝트에 저장된 OAST 리스닝 세션 목록 / 재개 / 릴리스 |
| `oast providers` | 저장된 OAST 프로바이더 목록 / 추가 / 수정 / 활성화 / 비활성화 / 삭제 |
| `jwt [<token>]` | JWT 디코드, 재서명, 또는 공격 페이로드 생성 |
| `cookie [<cookie>]` | Flask / Rack / Django 세션 쿠키 디코드, 검증, 브루트포스, 위조 |
| `decoder <chain> [input]` | Decoder 인코드 / 디코드 / 해시 체인 실행 |
| `notes [<n>]` · `create` · `delete` | 프로젝트 노트 읽기, 작성, 삭제 |
| `issues` · `create` · `update` | 이슈 목록 / 내보내기, 또는 이슈 작성 |
| `links` · `add` · `delete` | 이슈나 노트에서 플로우, Repeater 세션, 잡으로 이어지는 증거 포인터 |
| `rewriter` · `add` · `rm` · `enable` · `disable` · `preview` | Match & Replace 규칙 관리 |
| `rewriter extract` · `bindings` | 세션 바인딩 추출 규칙 관리, 그 규칙이 선언한 `$NAME` 목록 |
| `colormarker` · `add` · `rm` · `enable` · `disable` · `move` · `preview` · `color` | History 행 색상 규칙 관리 |
| `project [list]` | 알려진 프로젝트 목록 |
| `project create <name>` | 이름으로 프로젝트 생성 (같은 이름이면 다시 열기) |
| `project delete <name>` | 프로젝트와 그 안에 캡처된 모든 것 삭제 (`--yes`로 확인) |
| `project scope` | 스코프 규칙 목록 / 추가 / 수정 / 삭제 / 활성화 / 비활성화 |
| `project sandbox` | 하드 컨테인먼트 샌드박스 게이트 조회 / 설정 (`status`, `on`, `off`) |
| `project env` | 프로젝트 env 변수 목록 / 설정 / 삭제 (`$KEY` 치환) |
| `project host-override` | 프로젝트 호스트 → IP 다이얼 오버라이드 목록 / 추가 / 수정 / 삭제 |

읽기 서브커맨드에 공통인 플래그: `--project=NAME`, `--db=PATH`, `--format=FMT` (보통 `text` 또는 `json`). 전역 플래그는 **동사 뒤에** 옵니다. `gori run rewriter rm 1 --project=x`는 되지만 `gori run rewriter --project=x rm 1`은 조용히 목록만 찍는 대신 사용법 오류로 거부됩니다.

읽기 서브커맨드는 스토어를 직접 열고 캡처 락을 잡지 않으므로, 라이브 TUI가 캡처 중인 프로젝트를 대상으로 실행해도 안전합니다.

#### 출력 계약 {#output-contract}

STDOUT은 데이터를 나릅니다. 경고, 개수, 내보내기 확인 메시지는 STDERR로 가므로 파이프가 깨끗하게 유지됩니다. 읽는 쪽이 파이프를 먼저 닫아도(`… | head`) 조용히 `0`으로 끝납니다.

실행이 스트리밍되는 곳에서는 `json`과 `jsonl`의 형태가 늘 같지는 않습니다.

| 서브커맨드 | `--format json` | `--format jsonl` |
|-----------|-----------------|------------------|
| `capture`, `history` | 한 줄에 JSON 객체 하나 | `json`의 별칭 — 출력 동일 |
| `fuzz`, `mine`, `discover`, `authorize` | 버퍼링 후 마지막에 JSON 배열 하나 | 결과가 나올 때마다 한 줄씩 |

| 종료 코드 | 의미 |
|-----------|------|
| `0` | 성공 |
| `1` | 오류 — 전송 실패, 열 수 없는 프로젝트, 적용되지 못한 변경 |
| `3` | `run fuzz --fail-if-no-matches`가 완료했지만 매칭이 없음 |

`--fail-if-no-matches` 없이 실행하면, 매칭이 없으면서 *동시에* 모든 전송이 실패한 fuzz는 `1`로 끝납니다. "결과 없음"과 "대상에 닿지도 못함"이 구분됩니다. 플래그를 주면 `3`이 우선합니다.

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
| `--format=FMT` | `text`, `json`, 또는 `har` |

서브커맨드: `history show <id>` (`run show`와 동일), `history delete <id>`, `history clear --yes`.

`--format har`은 결과 집합 전체를 하나의 HAR 1.2 log로 STDOUT에 씁니다. 오래된 항목이 먼저 오므로, 쿼리 결과를 동료에게 넘기거나 Burp, Charles, 브라우저 네트워크 패널에 그대로 불러올 수 있습니다. [HAR 내보내기](#har-export)를 참고하세요.

### run show {#run-show}

```bash
gori run show <flow-id> --format raw
```

`--format`은 `text`, `json`, `raw`(정확한 바이트), 또는 `har`(항목 하나짜리 HAR log)입니다. `--request-only` / `--response-only`로 출력을 제한하며, `har`에는 적용되지 않습니다. 디코드된 SAML/JWT/GraphQL/파라미터, WebSocket 메시지, SSE 이벤트가 있으면 함께 포함됩니다.

#### HAR 내보내기 {#har-export}

gori가 쓴 HAR은 다시 gori로 가져와도(`gori run import --har`) 같은 플로우가 되므로 왕복이 보장됩니다. 네 가지를 알아두세요.

- **본문은 와이어 바이트**입니다. chunked만 풀고 압축은 풀지 않으며, 유효한 UTF-8이 아니면 base64로 인코딩합니다. `Content-Encoding` 헤더가 `headers`에 그대로 남아 본문과 헤드가 같은 메시지를 가리킵니다.
- **캡처 상한에 잘린 본문은 표시**되며, 온전한 것처럼 나가지 않습니다. `bodySize`와 `content.size`는 실제 와이어 크기를 유지하고 텍스트에는 캡처된 앞부분만 담기며, `content`/`postData`의 `comment`가 그 사실을 적습니다. 명령은 해당 개수도 STDERR로 보고합니다.
- **WebSocket 플로우는 메시지와 함께 내보내집니다.** 실제 `101` 핸드셰이크에 캡처된 전송 기록이 Chrome DevTools의 `_webSocketMessages` 필드로 나란히 실리며, `gori run import --har`로 다시 복원됩니다. 방향, opcode(제어 프레임 포함), 바이트(유효한 UTF-8이 아니면 base64), 밀리초 단위 타임스탬프가 유지됩니다. 프레임별 형태(`FIN`/`RSV`/마스크 키)는 이 형식에 담을 필드가 없으므로 필요하면 `--format json` 또는 `raw`를 쓰세요.
- **응답이 캡처되지 않은 플로우는 건너뜁니다.** 전송 기록이 비어 있는 소켓도 마찬가지입니다 — 핸드셰이크만으로는 교환이 아니기 때문입니다. 개수와 이유는 STDERR로 나가고 STDOUT은 순수한 HAR 문서로 유지됩니다.

### run compare {#run-compare}

두 플로우의 줄 단위 diff이며, [Comparer 탭](/ko/guide/scanning/)과 동일한 결과를 냅니다.

```bash
gori run compare 41 42 --pane response --changes-only
```

| Option | Description |
|--------|-------------|
| `--pane=PANE` | 비교 대상: `request` 또는 `response` (기본값) |
| `--changes-only` | 변경되지 않은 문맥은 빼고 추가 / 삭제된 줄만 출력 |
| `--context=N` | 변경 지점 주변 N줄만 남기고 나머지 동일 구간은 `@@ N unchanged lines @@` 마커로 접기 (`--changes-only`와 함께 쓸 수 없음) |
| `--format=FMT` | `text` (기본값) 또는 `json` |

diff 위에 양쪽의 `status · size · time`과 A→B 델타가 출력됩니다. 상태 코드가 뒤집혔는지, 크기가 얼마나 달라졌는지를 첫 줄을 읽기 전에 알 수 있습니다. `--format=json`에도 같은 값이 `meta`로 들어가고, 접힌 구간은 빈칸이 아니라 `{"kind":"fold","hidden":N}` 행이 됩니다.

`--changes-only`는 *무엇이* 바뀌었는지는 알려주지만 *어디서* 바뀌었는지는 지웁니다. 400줄 본문에서 한 줄만 다르면 위치 없는 두 줄만 남습니다. `--context`는 변경 지점을 제자리에 두고, 건너뛴 양을 함께 적습니다.

### run intercept {#run-intercept}

캡처 락을 쥔 TUI의 라이브 인터셉트 큐를 조작합니다. 인터셉트는 TUI 전용입니다. 헤드리스 `gori run capture`는 메시지를 붙잡지 않으며, 여기 서브커맨드는 상태를 게시하는 캡처 인스턴스가 없으면 모두 거부합니다.

```bash
gori run intercept                              # 붙잡힌 항목 + 인터셉트 상태
gori run intercept get 3 --format json
gori run intercept forward 3
gori run intercept edit 3 --raw-file edited.txt
gori run intercept direction request
```

| Subcommand | Description |
|------------|-------------|
| `list` (기본값) | 붙잡힌 항목과 캐치 상태, 방향, 필터 |
| `get <item-id>` | 붙잡힌 항목 하나의 전체 상세 |
| `forward <item-id>` | 바이트 그대로 통과 |
| `drop <item-id>` | 폐기. 클라이언트는 정해진 502를 받음 |
| `edit <item-id>` | 편집한 바이트로 통과: `--raw=RAW` 또는 `--raw-file=PATH`. 그대로 전달되며(`$KEY` 확장 없음) `Content-Length`만 다시 맞춤 |
| `enable` / `disable` | 라이브 캐치 켜기 / 끄기 |
| `filter <query>` | 조건부 인터셉트 쿼리 설정. `""`를 넘기면 해제 |
| `direction <both\|request\|response>` | 캐치가 붙잡을 구간 선택 |

`list`와 `get`은 `--include-sensitive`를 주지 않으면 민감한 헤더 값을 가립니다. 쓰기 서브커맨드는 프로젝트 데이터베이스를 거쳐 TUI의 ack를 폴링합니다.

### run repeater {#run-repeater}

캡처한 플로우 하나를 재전송하거나, TUI와 공유되는 Repeater 워크벤치 세션을 관리합니다.

```bash
gori run repeater <flow-id> --target https://staging.example.com --http2 --diff
```

| Option | Description |
|--------|-------------|
| `--target=URL` | 다른 오리진으로 전송. 경로와 쿼리는 유지 |
| `--http2` / `--http1` (`--no-http2`) | 프로토콜 강제. 기본값은 플로우가 캡처된 방식을 따름 |
| `--sni=HOST` | TLS SNI 오버라이드 |
| `-k`, `--insecure-upstream` | 업스트림 TLS 검증 생략 |
| `--timeout=SEC` | 작업당 연결 + 유휴 타임아웃 |
| `-H`, `--header=HEADER` | 요청 헤더 덮어쓰기/추가 (반복 가능). 같은 이름을 반복하면 중복 헤더 줄을 보냅니다. 명시한 `Content-Length`는 그대로 존중되어 CL 불일치 테스트에 쓸 수 있습니다 |
| `--rm-header=NAME` | 해당 이름의 헤더를 모두 삭제 (반복 가능). `Content-Length`를 지우면 자동 재계산이, `Host`를 지우면 `--target` 동기화가 꺼집니다 |
| `-b`, `--body=BODY` | 요청 본문 오버라이드 |
| `--keep-request-line` | 저장된 요청 라인을 그대로 전송. 절대 형식(`GET http://h/p`)을 origin 형식으로 고치지 않습니다 |
| `--diff` | 원본 응답과 비교 |
| `--allow-unscoped` | 프로젝트 스코프 밖으로도 전송. 샌드박스와 명시적 제외 규칙은 매 전송을 여전히 거부합니다 |
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
| `--name=NAME`, `--tags=TAGS` | 사용자 지정 탭 이름, 그리고 TUI 하위 탭 라벨이 되는 자유 텍스트 태그 |
| `--http2` / `--http1` (`--no-http2`) | 프로토콜 선택. `--http1`은 h2로 캡처된 `--flow`를 덮어씁니다 |
| `--no-auto-cl`, `--sni=HOST` | 자동 `Content-Length` 생략, SNI 오버라이드 |
| `--keep-request-line` | `--flow`와 함께: 요청 라인을 캡처된 그대로(절대 형식 포함) 저장 |
| `--ws-keep-key` | WebSocket: 요청 자신의 `Sec-WebSocket-Key`를 전송. 키가 없거나 짧거나 중복이거나 base64가 아닌 경우를 테스트할 수 있습니다 |
| `--ws-http-only` | WebSocket: 이 세션을 평범한 HTTP로 저장. 업그레이드를 일반 요청으로 보내고 `101`을 응답으로 읽습니다 |

**`repeater send <repeater-id>`**: 저장된 세션을 실행합니다. HTTP와 WebSocket 모두 해당됩니다.

```bash
gori run repeater send 3 --diff
gori run repeater send 5 --message '{"op":"subscribe"}' --idle-ms 5000
```

| Option | Description |
|--------|-------------|
| `--diff` | 세션에 마지막으로 저장된 응답과 비교 |
| `--verbatim` | 저장된 바이트를 정확히 그대로 전송: `$VAR` 확장, 단독 LF 승격, `Content-Length` 재계산, HTTP/2→1.1 버전 보정, h2 필드명 소문자화를 모두 하지 않음 |
| `--reframe-grpc` | HTTP/2 전용: 실제로 전송되는 본문에 맞춰 gRPC 5바이트 길이 접두사를 다시 계산합니다(길이가 바뀐 단항 메시지용). 기본값은 꺼짐 — 페이로드와 어긋나는 접두사는 표준적인 파서 테스트이므로 쓴 그대로 나갑니다 |
| `--message=TEXT` | WebSocket: 보낼 텍스트 메시지 (반복 가능; 세션에 저장된 메시지를 대체) |
| `--message-frame=SPEC` | WebSocket: 형태를 명시한 프레임 하나. 쉼표로 구분한 `key=value`: `opcode=text\|bin\|cont\|close\|ping\|pong\|<0-15>`, `fin`, `rsv`, `mask`, `mask_key`, `len`, 그리고 `hex=`/`b64=`/`text=` 중 하나 |
| `--idle-ms=N` | WebSocket: 첫 수신 프레임 이후 서버 침묵 타임아웃 (100–60000, 기본값 3000) |
| `--http` | WebSocket: 이번 전송에 한해 핸드셰이크를 일반 HTTP 요청으로 전송. 바이트를 고치는 게 아니라 엔진을 고르는 것입니다 |
| `--ws-keep-key`, `-k`, `--timeout`, `--allow-unscoped`, `--format` | 위와 동일 |

**`repeater minimize <repeater-id>`**: 응답이 그대로 재현되는 최소 형태까지 요청을 줄입니다. `--apply`는 결과를 세션에 다시 씁니다. `--verbatim`은 저장된 바이트를 그대로 보내며, 이때 본문 파라미터는 프레이밍을 정직하게 유지할 수 없어 후보에서 빠집니다. `-k`/`--insecure`, `--allow-unscoped`, `--format`은 위와 같습니다.

**`repeater h2`**: 순서가 있는 HPACK 필드 목록으로 필드 단위 HTTP/2 요청을 보냅니다. 중복되거나 순서가 뒤바뀐 의사 헤더를 스크립트로 만들 수 있습니다.

```bash
gori run repeater h2 --target https://api.example.com --fields fields.json
```

`--fields=FILE`은 `[[name, value], …]` 배열이거나 `{"fields": [[name, value], …], "body": "…"}` 형태의 JSON 파일입니다(바이너리는 `body_base64`). 목록의 어떤 것도 정규화하지 않습니다 — 앞의 콜론, 앞 공백이 붙은 값, 대문자 이름이 곧 페이로드입니다. `--target`은 다이얼할 오리진을 정하므로, `:authority`와 `:scheme` 필드는 의도적으로 그와 어긋나게 둘 수 있습니다.

### run fuzz {#run-fuzz}

소스: `--flow=ID`, `--request=FILE`, 또는 stdin. 위치: `§…§` 마커, `--auto`, 또는 `--mark=TOKEN`.

| Group | Options |
|-------|---------|
| Transport | `--target=URL` (`--request`/stdin에 필수), `--http2`, `--sni=HOST`, `-k`/`--insecure-upstream` |
| Mode | `--mode=` `sniper` (기본값), `batteringram`, `pitchfork`, `clusterbomb` |
| Payloads | `-w`/`--wordlist`, `--preset=NAME[:FILE]` (내장: `sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`), `--payloads=LIST`, `--numbers=FROM-TO[:STEP]`, `--null=N`, `--brute=CHARSET:MIN-MAX` |
| Processors | `--prefix`, `--suffix`, `--encode` (`url`\|`urlall`\|`base64`\|`hex`), `--case` (`upper`\|`lower`), `--hash` (`md5`\|`sha1`\|`sha256`), `--regex-replace=/pat/rep/` |
| Rate | `--concurrency` (20), `--rate=RPS`, `--throttle=MS`, `--timeout=SEC`, `--retries=N`, `--max-requests=N` (총 요청 상한. 재시도와 리다이렉트 홉도 포함), `--follow-redirects`, `--no-keep-alive` |
| Framing | `--verbatim` — 템플릿의 `Content-Length`를 쓰인 그대로 전송. 페이로드 치환 후에도 재계산하지 않습니다 (CL / CL-TE 디싱크 페이로드용). `--reframe-grpc` — 페이로드가 단항 gRPC 메시지에 삽입된 뒤 5바이트 길이 접두사를 다시 계산합니다(기본값은 꺼짐: 오래된 접두사는 고치지 않고 보고만 합니다) |
| Matchers | `--mc`/`--fc` status, `--mg`/`--fg` `grpc-status` 트레일러의 gRPC 상태 (`7`, `>0`, `1-16`), `--ms`/`--fs` size, `--mw`/`--fw` words, `--ml`/`--fl` lines, `--mr`/`--fr` body regex, `--extract=REGEX`, `--ac` auto-calibrate |
| Session bindings | `--bind-from=FLOW-ID` — 캡처된 그 플로우를 먼저 재생해, 응답이 남은 실행 동안 쓸 `$NAME` 바인딩을 채우게 합니다 |
| Scope | `--allow-unscoped` — 프로젝트 스코프 밖으로도 전송. 샌드박스와 명시적 제외 규칙은 매 전송을 여전히 거부합니다 |
| Output | `--format` (`text`\|`json`\|`jsonl`), `--force`, `--fail-if-no-matches` (매칭이 없으면 종료 코드 `3`) |

### run mine {#run-mine}

```bash
gori run mine <flow-id> --locations query,headers --wordlist params.txt
```

| Option | Description |
|--------|-------------|
| `--flow`, `--request`, `--target`, `--sni`, `--http2`, `-k` | 요청 소스와 트랜스포트 |
| `--locations=LIST` | `query`, `form`, `multipart`, `json`, `headers`, `cookies` (multipart는 기본 꺼짐, 명시해야 켜집니다) |
| `--wordlist`, `--bucket=N` | 후보 이름과 버킷 크기 |
| `--concurrency` (10), `--rate`, `--throttle`, `--timeout`, `--retries` (1), `--max-requests=N` | 속도 제어 |
| `--no-keep-alive` | 연결 재사용 대신 프로브마다 새로 연결 |
| `--bind-from=FLOW-ID` | 캡처된 그 플로우를 먼저 재생해, 응답이 남은 실행 동안 쓸 `$NAME` 세션 바인딩을 채우게 합니다 |
| `--format` | `text`, `json`, 또는 `jsonl` |

기본적으로 연결을 재사용합니다. 마이닝 한 번이 프로브마다가 아니라 워커마다 TCP(https라면 TLS) 핸드셰이크를 한 번씩만 치릅니다. 실행이 끝날 때 나오는 `connections · N dialed · M reused` 줄에서 대상이 이를 지켰는지 확인할 수 있습니다. 대상이 연결 단위로 동작한다면 `--no-keep-alive`로 끕니다.

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
| `--bind-from=FLOW-ID` | 캡처된 그 플로우를 먼저 재생해, 응답이 남은 실행 동안 쓸 `$NAME` 세션 바인딩을 채우게 합니다 |
| `--format` | `text`, `json`, `jsonl`, 또는 `markdown`(TUI의 Export가 쓰는 리포트) |

### run authorize {#run-authorize}

선택한 플로우를 아이덴티티마다 재전송합니다. 아이덴티티는 관리자 세션, 저권한 사용자, 익명 클라이언트를 대신하는 헤더 오버레이이며, 각 응답을 기준선과 비교합니다. 기준선이 받은 것을 그대로 받는 아이덴티티가 있다면 접근 제어 우회일 가능성이 높습니다. [Authorize 탭](/ko/guide/authorize/)의 헤드리스 버전입니다.

```bash
gori run authorize 12 13
gori run authorize --query 'host:acme.test method:GET' --identities identities.json
```

| Option | Description |
|--------|-------------|
| `<flow-id>…`, `--flow=ID` | 재전송할 캡처 플로우(지정한 순서대로, 반복 가능) |
| `-q`, `--query=QL` | QL 쿼리에 매칭되는 플로우도 재전송(id 뒤에 이어 붙습니다) |
| `-n`, `--limit=N` | `--query`가 기여할 수 있는 최대 플로우 수(기본값 50). 한 행이 *아이덴티티 수만큼*의 요청이 됩니다 |
| `--identities=FILE` | 아이덴티티 집합 JSON(`-`=stdin). 기본값은 프로젝트에 저장된 집합 |
| `--unsafe-methods` | `POST`/`PUT`/`PATCH`/`DELETE`도 재전송 — 아이덴티티마다 부수 효과가 다시 실행됩니다 |
| `--allow-unscoped` | 대상이 프로젝트 스코프 밖이어도 전송(샌드박스와 exclude는 그대로 적용) |
| `--timeout=SEC`, `-k`/`--insecure-upstream` | 요청당 연결 + 유휴 타임아웃, 업스트림 TLS 검증 생략 |
| `--project`, `--db` | 읽을 프로젝트 |
| `--format` | `text`(기본), `json`(마지막에 배열 하나), `jsonl`(스트리밍) |

`--identities`로 파일을 지정하지 않으면 아이덴티티는 프로젝트, 즉 TUI Authorize 탭의 목록에서 옵니다.

```json
[{"name": "anonymous", "remove": ["Cookie", "Authorization"]},
 {"name": "low-priv",  "set": [{"name": "Cookie", "value": "session=…"}]}]
```

`set`은 헤더를 upsert하고 `remove`는 제거합니다. 어떤 항목도 `"baseline": true`를 갖지 않으면 캡처된 그대로의 요청이 기준선입니다. 기준선 외에 최소 한 개의 아이덴티티가 필요하며, 그렇지 않으면 비교할 것이 없습니다.

의미 있게 재전송할 수 없는 플로우는 아무것도 보내기 전에 이유와 함께 STDERR에 나열됩니다(`no identity changes them`, `not a safe method to repeat`, `never completed`, `answered by gori`, `outside project scope`, `already queued`). 선택한 플로우가 전부 건너뛰어지면 실행하지 않고 거부합니다. 모든 전송이 소켓을 열기 전에 거부되면 깨끗한 결과를 보고하는 대신 `1`로 종료하며 그 사실을 말합니다. 아무것도 보내지 않은 실행은 접근 제어가 동작한다는 증거가 아니기 때문입니다.

### run probe {#run-probe}

```bash
gori run probe --severity high --category cors
gori run probe -a
```

`--severity`는 `info`\|`low`\|`medium`\|`high`\|`critical` 중 하나입니다. `--category`는 `headers`\|`cookies`\|`tech`\|`infoleak`\|`cors`\|`client`\|`active`입니다. 기본적으로 패시브 검사를 수행하며, `-a`/`--active` 옵션을 사용하여 액티브 프로브 검사를 포함할 수 있습니다. `-q`/`--query`로 QL 필터를 겁니다.

`--active`와 함께: `--unsafe`는 안전하지 않은 메서드(`POST`/`PUT`/`PATCH`/`DELETE`)도 프로브하며, 이 재전송은 서버 데이터를 변경할 수 있습니다. `--aggressive`는 룰별 상한을 높이고 forbidden-bypass 헤더 집합을 넓힙니다(그리고 `--unsafe`를 함의합니다). 둘 다 `--allow-unscoped`를 함께 주지 않는 한 스코프 게이트를 따릅니다. 인가된 대상에만 사용하세요.

`probe`만 쓰면 스캔하고 출력합니다. TUI Probe 탭 뒤에 저장되는 발견 항목은 별개의 표면입니다.

```bash
gori run probe issues --severity high            # 아래 동사들이 받는 id가 함께 나오는 트리아지 목록
gori run probe promote 12                        # 하나를 Issue로 확정
gori run probe dismiss --code missing-hsts       # 룰 코드나 --host로 일괄 무시
gori run probe delete --all --yes
gori run probe rules --kind active               # 스캔 룰 목록과 무장 여부
gori run probe rules enable <rule-id>            # id는 `probe rules`에서
gori run probe mode passive                      # off | passive | active | aggressive
```

| Verb | Options |
|------|---------|
| `issues` | `-a`/`--all`(무시·확정·해결된 항목 포함), `--severity`, `--category`, `--host` |
| `dismiss <id>` | 또는 `--code=CODE` / `--host=HOST`로 일괄 |
| `promote <id>` | 발견 항목을 사람이 확인한 Issue로 승격 |
| `delete <id>` | 또는 `--all --yes` |
| `rules [list\|enable\|disable\|add\|delete]` | `list`는 `--kind=passive\|active\|custom`. `enable`/`disable`/`delete`는 그 목록의 `<rule-id>`를 받습니다. `add`는 `-t`/`--title`, `-p`/`--pattern`, `--description`, `--side`(`request`\|`response`), `--region`(`whole`\|`header`\|`body`), `--regex`, `-s`/`--severity` |
| `mode [off\|passive\|active\|aggressive]` | 프로젝트의 스캔 모드를 출력하거나 설정 |

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
| `--no-keep-alive` | origin별 연결 재사용 대신 프로브마다 새로 연결 |
| `-k`, `--insecure-upstream` | 업스트림 TLS 검증 생략 |
| `--bind-from=FLOW-ID` | 캡처된 그 플로우를 먼저 재생해, 응답이 남은 실행 동안 쓸 `$NAME` 세션 바인딩을 채우게 합니다 |
| `--allow-unscoped` | 대상이 프로젝트 스코프 밖이어도 실행. 사전(Layer 1) 검사만 면제되며 Sandbox 모드와 명시적 exclude 룰은 매 전송마다 그대로 거부합니다. 거부 메시지는 둘 중 어느 게이트가 막았는지 이름을 밝힙니다. |
| `--force` | 무제한 실행 안전 게이트 우회 |
| `--no-store` | 결과를 프로젝트에 기록하지 않음 |
| `--format` | `text`, `json`, 또는 `jsonl` |

기본적으로 origin별로 연결을 재사용합니다. 브루트포스 한 번이 프로브마다가 아니라 워커마다 TCP(https라면 TLS) 핸드셰이크를 한 번씩만 치릅니다. 실행이 끝날 때 나오는 `connections · N dialed · M reused` 줄에서 대상이 이를 지켰는지 확인할 수 있습니다. 대상이 연결 단위로 동작한다면 `--no-keep-alive`로 끕니다.

### 명령줄에서 세션 바인딩 쓰기 {#session-bindings-from-the-command-line}

세션 바인딩(로그인 응답에서 채워지는 `$SESSION` 같은 것 — [세션 바인딩](/ko/guide/proxy/#session-bindings) 참고)은 그것을 관측한 gori 프로세스의 **메모리**에만 존재합니다. `settings.json`에도, 프로젝트 데이터베이스에도 기록되지 않습니다. 복원된 토큰은 이미 낡은 것이고, 다시 추출하는 비용은 요청 한 번이기 때문입니다.

`gori run`은 호출마다 프로세스 하나이며, 스윕은 의도적으로 추출 소스가 **아닙니다**(공격 페이로드를 그대로 되비추는 응답이 세션을 그 값으로 바꿔버릴 수 있기 때문입니다). 그래서 선언된 바인딩을 참조하는 헤드리스 `fuzz` / `mine` / `sequence` / `discover` 템플릿은 그것을 채울 수단이 없어, 전송 전에 거부됩니다.

`--bind-from FLOW-ID`가 그 빠진 단계입니다. 캡처된 플로우 하나 — 로그인 — 를 의도적 전송 경로로 재생해 그 응답이 바인딩 테이블을 채우게 하고, 같은 프로세스 안에서 스윕을 이어 실행합니다.

```bash
gori run fuzz 42 --wordlist ids.txt --bind-from 17
# bind-from: flow #17 replayed → bound $SESS
```

하나의 stdio 세션에서 `gori mcp` 도구를 두 번 호출하는 경우도 원래부터 같은 방식으로 동작합니다.

### run import {#run-import}

프로젝트의 History로 플로우를 일괄 임포트합니다. TUI의 Import 오버레이에 대응하는 CLI입니다([Proxy & History → 임포트](/ko/guide/proxy/#import) 참고). 소스 플래그는 정확히 하나만 지정해야 하며, 트래픽은 전혀 보내지 않습니다.

```bash
gori run import --postman api.postman_collection.json --db ./assessment.db --format json
```

| Option | Description |
|--------|-------------|
| `--har=PATH` | 브라우저/프록시 HAR(HTTP Archive) 익스포트 — 전체 요청/응답 플로우 |
| `--urls=PATH` | 한 줄에 URL 하나씩 담긴 텍스트 파일(`#` 주석과 빈 줄은 무시) |
| `--oas=PATH` | OpenAPI/Swagger 스펙(JSON 또는 YAML) — 오퍼레이션마다 템플릿 하나 |
| `--postman=PATH` | Postman Collection v2 익스포트(JSON) |
| `--insomnia=PATH` | Insomnia v4 익스포트(JSON) |
| `--burp=PATH` | Burp Suite 항목 익스포트(XML) — 요청 **과** 응답, 바이트 단위 그대로 |
| `--project=NAME` | 임포트할 프로젝트(기본값: 가장 최근에 사용한 프로젝트) |
| `--db=PATH` | 임포트할 SQLite db 파일을 직접 지정(없으면 생성) |
| `--format` | `text`(기본) 또는 `json` |

임포트는 플로우를 기록하므로 `discover`와 같은 방식으로 대상을 정합니다. `--db`를 주면 생성하거나 다시 열고, 주지 않으면 기본 프로젝트를 몰래 만들지 않고 기존 프로젝트에 씁니다.

형식이 잘못된 항목은 파일 전체를 중단시키지 않고 건너뛰며, 결과에 양쪽 개수가 모두 담깁니다(`{"count": 12, "skipped": 3}`). 응답까지 가져오는 것은 `--har`와 `--burp`뿐이고, 나머지는 요청 템플릿이라 보내기 전까지 History에서 `Pending`으로 보입니다.

### run sitemap {#run-sitemap}

```bash
gori run sitemap --in-scope --format paths
```

`-q`/`--query=QL`는 history와 같은 QL로 엔드포인트를 거릅니다(위치 인자로도 넘길 수 있습니다). `-n`/`--limit=N`은 스캔할 엔드포인트 수를 제한합니다(기본값 `SITEMAP_MAX`). `--in-scope`는 스코프 내 호스트로 한정하고, `--no-group`은 id 접기를 끕니다. `--format`은 `text`(트리), `json`, `paths` 중에서 고릅니다.

**`sitemap tag`**: 경로 하나에 자유 텍스트 메모를 고정합니다. TUI Sitemap에 보이는 그 메모입니다.

```bash
gori run sitemap tag --host api.example.com --path /v1/users --tag "IDOR candidate"
gori run sitemap tag --host api.example.com --path /v1/users --clear
gori run sitemap tag --list
```

### run oast {#run-oast}

아웃오브밴드 리스너입니다. `listen`은 즉석에서 쓰는 저장소 없는 리스너로 페이로드를 등록하고 출력한 뒤 콜백을 스트리밍합니다. `list` / `resume` / `release`는 프로젝트가 저장한 세션 — TUI의 RESUME LISTENER 피커가 보여주는 것과 같은 행 — 을 다룹니다.

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

**`oast list` / `resume` / `release`**: 프로젝트에 저장된 리스닝 **세션**입니다(아래의 프로바이더는 어디서 듣는지를, 세션은 그 위의 살아 있는 등록 하나를 뜻합니다). 등록은 그것을 만든 프로세스보다 오래 남고, 그래서 어제 심어둔 페이로드를 오늘도 지켜볼 수 있습니다.

```bash
gori run oast list                                       # id, provider, payload host, hits, last poll
gori run oast list --format json
gori run oast resume 7                                   # 세션 #7 재개 후 콜백 스트리밍
gori run oast resume 7 --once --json                     # 한 번만 폴링하고 JSON 라인 출력 후 종료
gori run oast release 7                                  # 서버 측 등록 해제
```

`resume`과 `release`는 세션 **id**(`7`, 또는 `list`가 출력하는 `#7`)를 받습니다. `resume`은 서버 측 상태를 다시 살려 이미 심어둔 페이로드가 계속 resolve되게 한 뒤 폴링합니다. 받은 콜백은 모두 프로젝트에 기록되므로 TUI OAST 탭에서 같은 hit를 보게 되고, `last_poll_at`도 TUI 리스너처럼 갱신됩니다. Ctrl-C는 폴링만 멈추고 등록은 **유지**합니다. 정리는 `release`로 명시적으로 하며, 어느 쪽이든 저장된 콜백은 남습니다. 자동으로 재개되는 것은 없습니다.

| Option | Description |
|--------|-------------|
| `--project=NAME` · `--db=PATH` | 어느 프로젝트의 세션인지(기본값: 가장 최근에 사용한 프로젝트) |
| `--format=FMT` | `list`에서: `text`(기본) 또는 `json` |
| `--interval=SEC` | `resume`에서: 폴링 간격(기본값 5) |
| `--once` | `resume`에서: 한 번만 폴링하고 종료 |
| `--json` | `resume`에서: 페이로드와 각 콜백을 JSON 라인으로 출력 |

**`oast providers`**: 위의 즉석 `listen`과 달리 프로젝트에 저장되는 프로바이더입니다. 동사: `list`(기본), `add`, `update`, `enable`, `disable`, `delete`(`rm`).

```bash
gori run oast providers                                  # 토큰은 [REDACTED]로 출력
gori run oast providers add --name lab --kind custom-http --host https://oast.lab.internal
gori run oast providers enable p_1
```

`enable`, `disable`, `update`, `delete`는 표시 이름이 아니라 프로바이더 **id**(`p_1` 또는 그냥 `1`)를 받습니다. `add`가 부여한 id를 출력하고, `list`에도 나옵니다.

| Option | Description |
|--------|-------------|
| `--name=NAME` | 표시 이름. `add`에서는 필수 |
| `--kind=KIND` | `interactsh`(기본) \| `custom-http` \| `webhook.site` \| `BOAST` \| `postbin` |
| `--host=URL` | 서버 / 베이스 URL(기본값: 해당 종류의 공개 프리셋) |
| `--token=TOK` | 프로바이더 인증 토큰 |
| `--enabled` / `--disabled` | `add` / `update` 시 프로바이더를 켜거나 끔 |
| `--show-tokens` | `list`에서 `[REDACTED]` 대신 토큰을 그대로 출력 |

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

### run cookie {#run-cookie}

서명된 Flask / Rack / Django 세션 쿠키를 디코드, 검증, 브루트포스, 위조합니다. 저장소 없는 계산이며, 쿠키는 `<cookie>` 인자나 stdin에서 받습니다.

```bash
gori run cookie 'eyJ1c2VyIjoi...'                            # 기본은 decode, 형식은 자동 판별
gori run cookie 'eyJ1c2VyIjoi...' --crack --wordlist secrets.txt
gori run cookie --forge --type flask --secret s3cret --payload '{"user":"admin"}'
```

| Option | Description |
|--------|-------------|
| `--decode` | payload / timestamp / signature로 파싱(기본) |
| `--verify` | `--secret`으로 서명 검증 |
| `--crack` | `--secrets` 또는 `--wordlist`로 시크릿 브루트포스 |
| `--forge` | `--payload`(Rack은 `--value`)를 `--secret`으로 재서명 |
| `--type=T` | `flask` \| `rack` \| `django`(기본: 자동 판별) |
| `--secret=S`, `--secrets=LIST`, `--wordlist=PATH` | 서명 시크릿, 쉼표로 구분한 후보 목록, 또는 줄 단위 파일 |
| `--payload=JSON` | 서명할 세션 JSON(Flask / Django `--forge`) |
| `--value=B64` | base64 Marshal 쿠키 값(Rack `--forge`, 불투명) |
| `--salt=SALT` | Flask / Django 서명 솔트 |
| `--algorithm=ALG` | Django HMAC 알고리즘: `sha256`(기본) 또는 `sha1` |
| `--timestamp=UNIX` | `--forge`에 찍을 유닉스 초(기본: 현재) |
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

### run links {#run-links}

이슈나 노트가 가리키는 증거입니다. 캡처된 플로우, Repeater 세션, Fuzz / Miner 실행이 대상이 됩니다. Markdown 이슈 내보내기는 이미 이 포인터를 해석해 넣고, 여기서는 목록 조회와 편집을 합니다.

```bash
gori run links --owner=issue --id=7
gori run links add --owner=issue --id=7 --ref=flow --ref-id=42
gori run links delete --owner=note --id=2 --ref=repeater --ref-id=3
```

| Option | Description |
|--------|-------------|
| `--owner=KIND` | 소유자 종류: `issue` (기본값) 또는 `note` |
| `--id=N` | 소유 이슈 / 노트 id. 필수 |
| `--ref=KIND` | `add` / `delete`의 대상 종류: `flow`, `repeater`, `fuzz`, `miner` |
| `--ref-id=M` | `add` / `delete`의 대상 id |
| `--format=FMT` | `list`에서 `text` (기본값) 또는 `json` |

대상이 정리(prune)된 포인터는 사라지지 않고 `(stale)`로 표시되므로, "증거가 없음"과 "증거가 사라짐"을 구분할 수 있습니다. `add`는 멱등이며, 양쪽 대상이 모두 존재해야 합니다.

### run rewriter {#run-rewriter}

스크립트에서 Match & Replace 규칙을 관리합니다. [Rewriter 탭](/ko/guide/proxy/)이 편집하는 것과 같은 규칙이며, 실시간 프록시 트래픽에 적용됩니다:

```bash
gori run rewriter                                       # 적용 순서대로 규칙 목록
gori run rewriter add --op set_header --target request \
  --find X-Forwarded-For --value 127.0.0.1 --host '*.example.com'
gori run rewriter add --op replace --target response --part body \
  --match regex --find 'secret=(\w+)' --value 'secret=[redacted]'
gori run rewriter add --op remove_header --target response \
  --find Content-Security-Policy --scope global          # 모든 프로젝트에 적용
gori run rewriter preview --op replace --part body --find password --value hunter2
gori run rewriter disable 3
gori run rewriter disable 2 --scope global               # 이 프로젝트에서만 끄기
gori run rewriter disable 2 --scope global --everywhere  # 기본값을 꺼서 모든 곳에 적용
gori run rewriter rm 3
```

| Option | Description |
|--------|-------------|
| `--op=OP` | `replace`(기본값), `add_header`, `set_header`, `remove_header`, `short_circuit` |
| `--target=SIDE` | `request`(기본값) 또는 `response` |
| `--part=PART` | `head`(기본값), `body`, 또는 `ws`(WebSocket 메시지). `replace`에서만 의미가 있음 |
| `--match=MODE` | `literal`(기본값) 또는 `regex`. `replace`와 `short_circuit`에 적용됩니다. 정규식 치환은 `$1`, `$2`를 쓰고 `$$`는 리터럴 `$` |
| `--response-file=PATH` | `short_circuit`: 미리 준비한 응답을 PATH에서 읽음(`-`는 stdin) |
| `--body-file=PATH` | `short_circuit`: PATH를 응답 본문으로 제공하며, 파일이 바뀌면 다시 읽음 |
| `-f`, `--find=FIND` | 필수. 대상이 되는 리터럴, 패턴, 또는 헤더 이름 |
| `-v`, `--value=VALUE` | 치환할 텍스트 또는 헤더 값 |
| `--host=GLOB` | 매칭되는 호스트로 규칙을 한정(부분 문자열, `*` 와일드카드). 생략하면 전체 적용 |
| `--name=NAME` | 규칙 목록에 표시할 라벨 |
| `--disabled` | 규칙을 만들되 활성화하지 않음 |
| `--scope=SCOPE` | `project`(기본값) 또는 `global`. 전역 규칙은 `settings.json`에 저장되어 모든 프로젝트에 적용됨 |
| `--everywhere` | 전역 규칙의 `enable`/`disable`에서, 이 프로젝트의 오버라이드 대신 규칙 자체의 기본값을 변경 |

`preview`는 같은 규칙 플래그를 받아, 규칙을 저장하지 않고 저장된 플로우 중 몇 개가 바뀌었을지 보고합니다. `rm`(`delete`), `enable`, `disable`은 목록의 규칙 id와 함께 `--scope`도 받습니다. 두 저장소가 규칙 번호를 각자 매기므로 id 하나가 서로 다른 두 규칙을 가리키기 때문입니다. 목록은 범위를 `G`/`P` 접두어로 출력하고(`G*`는 이 프로젝트가 해당 전역 규칙의 기본값을 오버라이드했다는 뜻), 프록시가 적용하는 순서 그대로 전역 규칙을 먼저 보여 줍니다. [전역 규칙과 프로젝트 규칙](/ko/guide/proxy/#reusing-a-rule-across-projects)을 참고하세요.

본문 규칙은 필요에 따라 `Content-Length`를 다시 맞추고 청크를 해제하며, 활성화된 규칙은 매칭되는 호스트에서 HTTP/1.1을 강제합니다. 대화형 편집기는 [Proxy & History](/ko/guide/proxy/)를 참고하세요.

**`rewriter extract`**: [세션 바인딩](/ko/guide/proxy/#session-bindings)을 선언하는 규칙입니다. `$NAME`을 어느 응답의 어디에서 읽을지 정합니다. 동사: `list`(기본), `add`, `rm`(`delete`), `enable`, `disable`.

```bash
gori run rewriter extract add --name SESS --kind cookie --selector session --host '*.example.com'
gori run rewriter extract add --name CSRF --kind regex --selector 'name="csrf" value="([^"]+)"'
```

| Option | Description |
|--------|-------------|
| `--name=NAME` | `$`를 뺀 바인딩 이름. 필수 |
| `--kind=KIND` | `cookie`(기본), `header`, `regex`, `position`, `jsonpath` |
| `--selector=SEL` | 쿠키 / 헤더 이름, 정규식, 또는 JSON 경로 |
| `--range=A:B` | `position` 전용: 디코드된 본문의 반열린 바이트 범위 |
| `--when=FILTER` | 어떤 메시지를 읽을지, 인터셉트 필터 문법으로(`''`는 전부) |
| `--host=GLOB` | 호스트 글롭으로 한정(`''`는 전부) |
| `--disabled` | 규칙을 만들되 활성화하지 않음 |

**`rewriter bindings`**: 그 규칙들이 선언한 이름을 나열합니다(`--format text|json`). 값은 여기에 나오지 않으며, 나올 수도 없습니다. 바인딩 값은 실행 중인 gori의 메모리에만 있고 어디에도 기록되지 않으므로 다른 프로세스가 읽을 것이 없기 때문입니다. 살아 있는 값 테이블은 Rewriter 탭의 `bindings` 하위 탭에서 봅니다. 헤드리스 스윕에서는 `--bind-from`이 같은 프로세스 안에서 값을 채웁니다 — [명령줄에서 세션 바인딩 쓰기](#session-bindings-from-the-command-line)를 참고하세요.

### run colormarker {#run-colormarker}

**Colormarker** 규칙을 관리합니다. 캡처된 History의 어떤 행을 어떤 방식으로 칠할지 정하는 규칙이며, 표시 전용입니다. 트래픽을 전혀 수정하지 않으므로 Match & Replace 규칙과 달리 잘못 써도 목록이 오해를 부를 뿐, 메시지가 바뀌지는 않습니다.

```bash
gori run colormarker                                        # 우선순위 순으로 규칙 목록
gori run colormarker add --when 'status:>=500' --color red --style full --name 'prod 5xx'
gori run colormarker add --when 'host:cdn' --color blue --style strip --scope global
gori run colormarker move 2 --up                            # 우선순위 올리기
gori run colormarker preview --when 'method:DELETE'
gori run colormarker disable 1 --scope global               # 이 프로젝트에서만 끄기
gori run colormarker disable 1 --scope global --everywhere  # 모든 프로젝트의 기본값을 끄기
gori run colormarker rm 3
```

| 옵션 | 설명 |
|--------|-------------|
| `-w`, `--when=FILTER` | 필수. 플로우가 만족해야 할 조건 (아래 참고) |
| `--color=NAME` | `red`, `orange`, `yellow`(기본), `green`, `blue`, `purple`. 활성 테마 팔레트로 해석되므로 밝은 테마와 어두운 테마 양쪽에서 제대로 읽힙니다 |
| `--style=STYLE` | `full`(기본)은 행 전체 배경을 칠하고, `strip`은 `TIME` 앞 좁은 컬럼에 색 셀 하나를 칠합니다 |
| `--name=NAME` | 규칙 목록에 표시할 라벨 |
| `--disabled` | 비활성 상태로 생성 |
| `--scope=SCOPE` | `project`(기본) 또는 `global`. 전역 규칙은 `settings.json`에 저장되어 모든 프로젝트에 적용됩니다 |
| `--everywhere` | 전역 규칙의 `enable`/`disable` 시: 이 프로젝트의 오버라이드가 아니라 규칙 자체의 기본값을 변경 |
| `--up` / `--down` | `move` 시: 우선순위를 올리거나 내림 |

**우선순위가 곧 규칙 집합의 의미입니다.** Match & Replace 규칙은 *합성*되어 활성화된 모든 규칙이 순서대로 실행되지만, 색상 규칙은 *해석*됩니다. **첫 번째로 매칭되는 활성 규칙이 행을 칠하고 나머지는 조회조차 되지 않습니다.** `move`가 `rewriter`에는 없고 여기에만 있는 이유입니다. 전역 규칙이 프로젝트 규칙보다 먼저 해석되므로, 상시 정책이 로컬 레이어보다 우선합니다.

`--when`은 조건부 인터셉트 바가 쓰는 것과 같은 불리언 문법입니다. `host:` `path:` `method:` `scheme:` `status:` `proto:`에 `AND` / `OR` / `NOT`, `-부정`, `(그룹)`을 더한 형태이며 캡처된 플로우 행에 대해 평가됩니다. 그냥 두면 조용히 실패할 세 가지가 있어, gori는 거부하거나 경고합니다.

- **`body:`는 여기서 절대 매칭되지 않습니다.** History 행에는 payload가 없습니다. (거부가 아니라 경고 — 문법상 적법한 항이기 때문입니다.)
- **`host:`는 DNS 레이블 글롭이 아니라 부분문자열입니다.** `host:alpha.test`는 `xalpha.test`도 매칭합니다. (경고)
- **`header:` / `size:` / `dur:` / `url:` / `stub:`는 없습니다.** 이들은 쿼리가 필요한 History QL 필드이고, 여기는 렌더 경로에서 평가됩니다. 모르는 필드는 **거부**됩니다. 그냥 두면 조용히 자유 텍스트 검색이 되어 규칙이 영원히 발동하지 않습니다.

모든 플로우에 매칭되는 조건(빈 값이나 입력 중인 `host:`)도 거부됩니다.

`preview`는 조건이 최근 플로우 중 몇 개에 **매칭**되는지와, 실제로 몇 개를 **칠하게** 되는지를 함께 보고합니다. 앞선 활성 규칙이 이미 그 행을 차지했다면 두 숫자가 달라집니다. `rm`(`delete`), `enable`, `disable`, `move`는 목록의 규칙 id와 `--scope`를 받습니다. 두 저장소가 서로 독립적으로 번호를 매기므로 id만으로는 서로 다른 두 규칙을 가리키기 때문입니다. 목록은 스코프를 `G`/`P` 접두사로 출력합니다(`G*`는 이 프로젝트가 해당 전역 규칙의 기본값을 오버라이드했다는 뜻).

탭은 **기본적으로 숨겨져 있습니다.** `settings:tabs`에서 Rewriter 옆에 표시할 수 있습니다. 대화형 편집기는 [프록시 & History](/ko/guide/proxy/)를 참고하세요.

#### colormarker color {#run-colormarker-color}

**사용자 색상 팔레트**입니다. 내장 6색 위에 얹어 모든 프로젝트의 색상 선택기에 함께 제공되는 이름 있는 색상입니다. 내장 색은 활성 테마를 거쳐 해석되므로 밝은 팔레트와 어두운 팔레트 양쪽에서 제대로 읽히지만, 사용자 색상은 절대 hex 값을 그대로 지니며 테마를 따라가지 않습니다. 팔레트가 주지 않는 색조를 얻는 대신 치르는 대가입니다. 색상은 `settings.json`(`colormarker.colors`)에 저장되므로 태생적으로 전역입니다.

```bash
gori run colormarker color list
gori run colormarker color add --name hotpink --hex '#ff69b4'
gori run colormarker color update hotpink --hex '#e0559b'   # 이름은 두고 색만 변경
gori run colormarker color update hotpink --name fuchsia    # 색은 두고 이름만 변경
gori run colormarker color rm fuchsia
gori run colormarker add --when 'method:DELETE' --color hotpink
```

이름이 곧 식별자입니다. 규칙의 `--color`에 저장되는 값이자 선택기에 보이는 값이므로 소문자로 정규화되고, 중복될 수 없으며, 내장 색 이름과 같을 수 없습니다. `update`는 두 옵션 중 하나만 줘도 됩니다.

색상을 지우거나 **이름을 바꿔도** 그 색을 쓰던 규칙은 의도적으로 고쳐 쓰지 않습니다. 규칙은 옛 이름을 그대로 들고 있다가 눈에 띄는 기본색으로 대체되어 그려지므로, 같은 이름으로 색을 다시 추가하면 원래대로 돌아옵니다. 이 명령에서 모든 프로젝트의 데이터베이스에 손을 뻗을 수는 없고, 절반만 적용된 연쇄 수정은 이름 하나가 붕 뜨는 것보다 나쁩니다. 색상 값만 바꾸는 경우는 다릅니다. 규칙은 색을 이름으로 참조하므로 어디서든 새 hex를 그대로 따라갑니다.

### run project {#run-project}

프로젝트 목록/생성/삭제, 또는 프로젝트 스코프 설정(스코프 규칙, env 변수, 호스트 오버라이드) 관리:

```bash
gori run project --format json
gori run project list
```

#### project create {#project-create}

트래픽을 캡처하지 않고 프로젝트를 만듭니다. `gori run capture --project=NAME`도 필요할 때 만들어 주지만, 이 명령은 요청을 보내지 않으므로 프록시를 띄우기 전에 스코프와 env를 미리 구성할 수 있습니다.

```bash
gori run project create "API test"
gori run project create api-test --description="staging sweep"
gori run project create api-test --format json
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<name>` | 표시 이름. 공백이 들어가면 따옴표로 감쌉니다 |
| `--description=TEXT` | 프로젝트 설정에 저장됩니다 |
| `--format=FMT` | `text`(기본) 또는 `json` |

이미 있는 이름은 오류가 아니라 그 프로젝트를 다시 여는 것으로 처리하며, `--format json`은 `"created": false`로 알려 줍니다. 다시 열 때 저장된 표시 이름은 마지막 create의 대소문자로 갱신되고, `--description`을 주면 기존 설명을 덮어씁니다.

#### project delete {#project-delete}

프로젝트 디렉터리와 그 안에 캡처된 모든 것(플로우, 이슈, 노트, 스코프, 규칙)을 삭제합니다. 되돌릴 수 없으므로 두 단계로 동작합니다. `--yes` 없이 실행하면 대상만 출력하고 0이 아닌 코드로 종료합니다.

```bash
gori run project delete api-test              # preview only, nothing is removed
gori run project delete api-test --format json
gori run project rm api-test --yes            # actually delete
```

| Option / subcommand | Description |
|---------------------|-------------|
| `<name>` | 짧은 id, id 접두사, 디렉터리 slug, 표시 이름 중 하나로 지정 |
| `--yes` | 실제로 삭제. 없으면 아무것도 지우지 않습니다 |
| `--format=FMT` | `text`(기본) 또는 `json` |

미리보기는 플로우/이슈 개수, 디스크 사용량, 캡처가 살아 있는지를 함께 보여 줍니다. 다른 gori 인스턴스가 캡처 중인 프로젝트는 삭제를 거부하므로, 그 캡처를 먼저 중지해야 합니다.

표시 이름은 유일하지 않습니다(같은 basename을 쓰는 두 워크스페이스는 이름을 공유합니다). 이름이 여러 프로젝트에 걸리면 삭제를 거부하고 각각의 slug를 보여 줍니다. 잘못 고르면 되돌릴 수 없기 때문입니다. slug와 짧은 id는 유일하므로 언제나 하나로 확정됩니다.

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

#### project sandbox {#run-project-sandbox}

**하드 컨테인먼트** 샌드박스 게이트를 조회하거나 설정합니다. TUI Project NETWORK 토글의 헤드리스 등가물입니다. 켜면 캡처 프록시가 스코프가 허용하는 요청만 전달하고 나머지는 모두 차단합니다. 표시 렌즈일 뿐인 `project scope enable`과는 다릅니다.

```bash
gori run project sandbox                 # show the current state (status is the default)
gori run project sandbox status --format json
gori run project sandbox on              # start blocking out-of-scope traffic
gori run project sandbox off             # stop blocking
```

| Option / subcommand | Description |
|---------------------|-------------|
| (default) / `status` | 게이트 상태 표시; `--format`은 `text` 또는 `json` |
| `on` / `enable` | 스코프가 허용하지 않는 모든 요청 차단 |
| `off` / `disable` | 차단 중지 |

> include 규칙이 없으면 샌드박스를 켤 때 규칙을 추가하기 전까지 **모든** 캡처 트래픽이 차단됩니다(`gori run project scope add …`). 이 명령은 경고 후 진행하므로 CI에서 컨테인먼트를 부트스트랩할 수 있습니다.

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
| `--no-project` | Git 워크스페이스 안에서도 unbound로 시작 (에이전트가 list/create/switch로 선택) |
| `--insecure-upstream` | `send_request`: 업스트림 TLS 검증 생략 |
| `--read-only` | 액션 도구 비활성화 (`send_request`, 이슈 생성/수정, fuzz/mine); `switch_project`(및 unbound 시 `create_project`)는 유지 |
| `--install-claude` | Claude Desktop `mcpServers` 설정 기록 |
| `--install-claude-code` | Claude Code `~/.claude.json` `mcpServers` 항목 기록 |
| `--install-codex` | OpenAI Codex `~/.codex/config.toml` `[mcp_servers.gori]` 기록 |
| `--install-agy` | Antigravity `~/.gemini/antigravity-cli/mcp_config.json` 기록 |
| `--install-grok` | Grok `~/.grok/config.toml` `[mcp_servers.gori]` 기록 |

`--install-*`은 한 번에 여러 개 지정할 수 있습니다. 클라이언트마다 따로 설정하고 따로 보고하며, 하나가 실패해도 나머지는 그대로 진행됩니다. 커맨드라인의 다른 플래그(`--db`, `--project`, `--no-project`, `--use-active-project`, `--read-only`, `--insecure-upstream`, 전역 `--config`)는 모두 설치되는 커맨드에 기록되고, 경로는 절대 경로로 바뀝니다. 기존 설정 파일은 제자리에서 갱신됩니다. 다른 항목·테이블·주석은 유지되고, 권한도 보존되며, 교체는 원자적입니다.

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

동사(verb)를 먼저 쓰고 플래그를 그 뒤에 씁니다 — `gori ca --ca-dir=DIR regenerate`가 아니라 `gori ca regenerate --ca-dir=DIR`입니다. 반대 순서는 사용법 오류로 처리합니다. 그러지 않으면 동사가 버려진 채 CA 경로만 출력되어 작업이 수행된 것처럼 보이기 때문입니다. 세 가지 형태 모두 위치 인자를 받지 않습니다.

`gori ca`는 로드는 되지만 사용할 수 없는 루트 CA — 인증서와 일치하지 않는 개인 키, 또는 gori가 서명에 사용할 수 없는 키 — 도 stderr로 보고합니다. 그렇지 않으면 이 증상은 클라이언트 쪽에서 "unknown CA"나 "bad signature" 핸드셰이크 실패로만 드러나기 때문입니다. 해결책은 `regenerate`와 `import`이며, 두 명령은 쌍 중 한 파일만 남은 경우를 포함해 어떤 상태의 CA 디렉터리에서도 동작합니다.

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

무엇이든 디스크에 기록하기 전에 쌍을 먼저 검증합니다: 키는 인증서와 일치해야 하고, 인증서는 CA여야 하며(`basicConstraints CA:TRUE`), gori가 그 키로 리프 인증서를 서명할 수 있어야 합니다. 마지막 검사 때문에 **Ed25519 · Ed448 루트는 거부됩니다** — gori는 리프를 SHA-256으로 서명하는데 이 키들은 이를 지원하지 않습니다 — 따라서 EC P-256이나 RSA 루트를 사용하세요. 거부된 쌍은 현재 CA를 건드리지 않고 중단합니다. 만료되었거나 아직 유효하지 않은 인증서는 경고만 남기고 그대로 가져옵니다. tty에서 `import`를 입력하여 확인하거나 `--yes`를 전달하세요. 같은 동작을 TUI 팔레트(**Import CA certificate**)에서도 사용할 수 있습니다.

OpenSSL로 루트를 생성한 뒤 가져옵니다:

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

클라이언트에서는 `root.crt.pem`만 신뢰하세요. 개인 키는 절대 배포하지 마세요.

## gori settings {#gori-settings}

```bash
gori settings                      # settings.json 경로 출력
gori settings --edit               # $EDITOR로 열기
gori settings sections             # 최상위 섹션 목록
gori settings export [-o FILE]     # 공유 가능한 프로필 출력(기본 stdout)
gori settings import FILE          # 프로필의 섹션들을 적용
```

### 프로필 {#profiles}

`export`와 `import`는 설정을 다른 머신으로 옮기거나, 팀과 공유하거나, 재현 가능한 실행을 위해 저장소에 커밋할 때 씁니다. 단위는 최상위 섹션이며 목록은 `gori settings sections`로 확인합니다.

```bash
gori settings export --sections network,scan_rules -o team-profile.json
gori settings import team-profile.json --dry-run     # 무엇이 적용될지 미리 보기
gori settings import team-profile.json --sections network
```

`gori settings sections`는 gori가 아는 모든 섹션을 나열하고, 이 설치본에 아직 값이 없는 것을 표시합니다:

```
network
scan_rules  (not set — at its default)
env  (holds secrets — excluded unless named; not set — at its default)
```

*not set*으로 표시된 섹션도 `--sections`에 쓸 수 있는 정상적인 이름입니다. export하면 담을 값이 없을 뿐이고(그 사실을 stderr로 알려줍니다), import하면 그 섹션이 처음으로 기록됩니다.

| 플래그 | 대상 | 설명 |
|------|-----------|-------------|
| `--sections a,b` | 공통 | 쉼표로 구분한 섹션 이름, 최소 하나. export 기본값은 비밀을 담은 섹션을 제외한 전부, import 기본값은 파일에 있는 전부 |
| `-o`, `--out FILE` | export | stdout 대신 파일로 기록 |
| `--dry-run` | import | 적용될 섹션만 출력하고 아무것도 쓰지 않고 종료 |

선택하지 않았거나 프로필에 없는 섹션은 **그대로 남습니다**. `--sections`가 고르는 것이 바로 이 경계입니다. 프로필이 실제로 담고 있는 섹션 안에서는:

- **리스트/테이블 섹션은 통째 교체됩니다**: `upstream_rules`, `outbound_tls`, `listeners`, `scan_rules`, `hostname_overrides`, `tabs` 등. `"upstream_rules": []`를 담은 프로필은 테이블을 비웁니다 — "규칙 없음"을 그렇게 표현합니다.
- **스칼라 오브젝트 섹션은 키 단위로 적용됩니다**: `network`, `editor`, `probe`. 프로필이 생략한 키는 현재 값을 유지하므로, `network.upstream_proxy`만 지정한 팀 프로필이 언급한 적도 없는 `bind_port`까지 기본값으로 되돌리지 않습니다.

`export`는 공장 기본값 상태인 섹션을 아예 쓰지 않으므로, 프로필은 설정 전체의 스냅샷이 아니라 *적용할 값들의 묶음*입니다 — 어떤 값이 기본값인 머신에서 export해도, 그 값이 기본값이 아닌 머신에서 되돌려지지 않습니다. import가 무엇을 건드릴지는 `--dry-run`으로 확인하세요 — 목록에 넣는 쪽으로 넉넉하게 판단하므로, 거기 없는 섹션은 확실히 아무 변화도 없습니다.

import는 TUI와 동일한 저장 경로를 거치므로 원자적 쓰기가 유지되고, 동시에 실행 중인 gori가 건드리지 않은 섹션에 한 편집이나 삭제를 덮어쓰지 않습니다. 파일에 있는 알 수 없는 섹션은 보고하고 무시합니다 — 실행 중인 설정에도, 파일에도 반영되지 않습니다.

gori가 `settings.json`을 읽지 못하는 상태 — 파싱 실패, 권한 문제, `--config`가 열 수 없는 대상을 가리키는 경우 — 라면 `export`와 `import` 모두 진행하지 않고 거부합니다. 그 시점의 gori는 모든 섹션이 공장 기본값이므로, import는 프로필이 언급하지 않은 섹션 전부를 기본값으로 디스크에 박고, export는 그 기본값을 원래 설정인 양 파일로 내보내기 때문입니다. 먼저 파일을 고치거나 지우세요 — 파싱되지 않은 원본은 옆에 `settings.json.corrupt`로 보관됩니다. `--dry-run`은 예외입니다: 아무것도 쓰지 않으므로 그대로 실행되고, 비교 대상이 기본값이라는 사실을 stderr로 알려줍니다.

`env`와 `decoder`는 export에서 기본 제외됩니다 — `env`는 토큰 값을, `decoder`는 마지막 입력과 저장된 세션을 담기 때문입니다. 명시적으로 이름을 적는 것(`--sections env`)이 포함에 대한 동의입니다. `upstream_rules`는 공유해도 안전합니다 — 사용자명과 환경변수 *이름*만 저장하고 비밀번호는 담지 않습니다.

`-o`가 실제 사용 중인 `settings.json`을 가리키면 거부됩니다. export는 스냅샷이 아니라 — 기본값 상태인 섹션은 모두 빠지고, `env`와 `decoder`는 이름을 지정하지 않는 한 빠집니다 — 그것을 원본 파일에 되쓰면 해당 섹션이 갱신되는 게 아니라 삭제됩니다.

export가 실제로 그런 섹션을 담게 되면 `-o FILE`은 `0600`으로 생성되고, gori가 파일에 무엇이 들어 있는지 이름을 대며 알려줍니다. 자격증명을 export하는 데 동의한 것이 그것을 누구나 읽을 수 있게 두는 데 동의한 것은 아닙니다. 일반 export는 `0644`로 남고, env 변수가 하나도 없는 설치에서 `env`를 지정한 export도 일반 export입니다 — 권한은 타이핑한 내용이 아니라 문서에 실제로 담긴 것을 따릅니다.

### `--config PATH` {#config-flag}

`--config`는 이번 실행에 쓸 설정 파일을 지정합니다. 서브커맨드 앞에 옵니다.

```bash
gori --config ./ci-profile.json run capture --target https://api.example.com
gori --config ~/profiles/corp.json          # 다른 설정으로 TUI 실행
```

우선순위는 `--config` → `$GORI_CONFIG` → `$GORI_HOME/settings.json`입니다.

이 플래그는 의도적으로 **`GORI_HOME`과 직교**합니다 — 읽고 쓸 설정 파일만 바꾸고 CA, 프로젝트 DB, 테마, 워드리스트는 그대로 둡니다. 이전에는 설정을 바꾸려면 트리 전체를 옮기는 방법밖에 없었습니다.

## gori wizard {#gori-wizard}

```bash
gori wizard
```

대화형 설정(전역 프록시 바인드 기본값, 테마, 그다음 Miss Ring 마스코트)을 실행합니다. 최초 실행 시에도 자동으로 실행됩니다. 바인드 단계는 공유 `settings.json` 기본값을 기록합니다. 프로젝트는 Project 탭에서 자체 주소를 고정할 수 있으며, `--listen` / `--port`는 이번 실행에 한해서만 오버라이드합니다.

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
| Nix (`/nix/store`) | `nix profile upgrade` / 플레이크 업데이트 안내 출력; 스토어가 읽기 전용이므로 아무것도 내려받지 않음 |

`/usr/bin` 또는 `/bin` 아래 경로는 패키지 소유권(`pacman -Qo`, `dpkg-query -S`, `rpm -qf`)으로 분류됩니다. 관리자가 파일을 소유하면 gori는 절대 덮어쓰지 않습니다. 프로브가 소유자를 찾지 못하면 바이너리 채널이 자체 업데이트합니다. 패키지 도구가 전혀 없으면 `/etc/os-release`(`ID` / `ID_LIKE`)로 Arch 계열 / Debian 계열 / RHEL 계열 안내를 폴백으로 고릅니다.

릴리스 자산 이름은 [설치 가이드](/ko/getting-started/installation/)와 일치합니다(`gori-v*-linux-*` 순수 바이너리, `gori-v*-osx-*.tar.gz` 아카이브). macOS 아카이브 업데이트는 전용 레이아웃(예: curl 설치 프로그램의 `PREFIX/opt/gori`)을 요구하여 번들된 `lib/`가 `/usr/local/lib` 같은 공유 루트 아래에 절대 기록되지 않도록 합니다. 아직 릴리스 자산이 없으면 명령은 릴리스 페이지를 가리키는 명확한 오류로 종료합니다. 조용히 아무 동작도 하지 않는 것이 아닙니다.
