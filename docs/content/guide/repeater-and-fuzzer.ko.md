+++
title = "Repeater & Fuzzer"
description = "요청 워크벤치와 Intruder 스타일 Fuzzer를, TUI와 헤드리스에서 다룹니다."
weight = 20

[extra]
group = "핵심"
+++

흥미로운 플로우를 캡처했다면, **Repeater**와 **Fuzzer**가 그 플로우를 테스트하는 곳입니다.

## Repeater {#repeater}

Repeater는 요청 워크벤치입니다. 플로우를 보내고, 요청의 어느 부분이든 편집한 뒤, 다시 보냅니다. 응답, 소요 시간, 이전 응답과의 diff가 나란히 표시됩니다. 세션은 프로젝트와 함께 유지되므로 나중에 다시 돌아올 수 있습니다.

세션이 수십 개 쌓이면 칩 스트립이 스크롤되기 시작하고, `←`/`→`로 훑어 찾는 건 더 이상 현실적이지 않습니다. 스트립 위 어느 칩에서든 **`f`**를 누르면 전체 세션 목록이 뜹니다. 타이핑하면 이름·메서드·경로·대상 호스트·`#태그`로 걸러지고, `Enter`로 고른 세션으로 점프합니다. 같은 목록이 스트립 왼쪽 끝의 **`⌕`** 뒤에도 있습니다 — 클릭하거나, 첫 칩에서 `←`로 이동하면 됩니다. Fuzzer, Notes, Decoder, JWT, Comparer, Miner, Sequencer 등 모든 워크벤치 스트립에 동일하게 있습니다.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="편집 가능한 HTTP/2 요청 패널, 헤더와 JSON 본문을 보여주는 응답 패널, 그리고 1152ms 만에 재전송된 200 상태 줄을 갖춘 gori Repeater 탭">
  <figcaption><strong>Repeater</strong>: 왼쪽에 편집 가능한 요청, 오른쪽에 실시간 응답과 소요 시간, 이전 전송과의 diff.</figcaption>
</figure>

Repeater는 HTTP/1 이상을 다룹니다.

- **HTTP/2** 요청은 실제 h2 연결로 재전송됩니다.
- **WebSocket** 리피터는 핸드셰이크를 연 뒤 메시지를 **한 번에 하나씩** 재생합니다. 하나를 보내고, 서버의 응답이 잠잠해질 때까지 받아낸 다음에야 그다음 메시지가 나갑니다.
- **gRPC** 리피터는 프레이밍된 메시지를 위해 HTTP/2 엔진을 재사용합니다. 단항(unary) 호출 — 정확히 하나의 프레이밍된 메시지 — 은 `^X`로 페이로드를 헥스 편집할 수 있고, 메시지가 0개이거나 여러 개인 본문은 그대로 재전송됩니다. 메시지 앞의 5바이트 길이 접두사는 요청 카드의 `␣F:FRAME` 토글이 결정합니다. 이 탭에서는 기본값이 **켜짐**이라, 편집한 단항 메시지가 올바른 형식으로 나가고 원본 서버가 호출을 받아들입니다. **끄면** 편집한 페이로드 앞에 캡처된 접두사가 그대로 붙습니다 — 페이로드와 어긋나는 접두사 자체가 표준적인 gRPC 파서 테스트이기 때문입니다. 헤드리스에서는 기본값이 반대입니다. `gori run repeater send`(MCP `send_request`)는 `--reframe-grpc` / `reframe_grpc: true`를 주지 않는 한 접두사를 캡처된 그대로 보냅니다.
- **decode** 모드는 편집된 SAML / GraphQL 페이로드를 전송 시 다시 인코드합니다. (JWT를 디코드하거나 편집하려면 [Decoder](/ko/guide/decoder/) 탭의 `jwt-decode`를 사용하세요.)

WebSocket에서는 이 "하나씩" 순서가 핵심입니다. 소켓은 대화를 실어 나르므로, 세 번째 메시지가 두 번째의 응답에 의존하는 스크립트는 gori가 그 사이에 기다려 줄 때만 충실하게 재생됩니다. 그리고 그때 트랜스크립트는 보낸 것 전부를 받은 것 전부보다 앞에 나열하는 대신 실제 전선 순서대로 읽힙니다. 여기서 세 가지가 따라옵니다.

- **메시지마다 최소한 한 번의 정적 구간이 듭니다**(기본값은 서버 침묵 3초). 아무것도 응답하지 않는 서버를 상대로 한 긴 스크립트가 가장 느린 경우입니다.
- **상대가 멈추면 gori도 멈춥니다.** 서버가 `CLOSE`를 보내거나 연결이 끊기면, 남은 스크립트는 아무도 읽지 않는 소켓에 쓰이지 *않습니다* — RFC 6455도 `CLOSE` 이후의 데이터 프레임을 금지합니다. 결과에는 실제로 몇 개가 나갔는지가 적힙니다.
- **당신이 쓴 `CLOSE`는 멈추지 않습니다.** 자신의 `CLOSE` 뒤에 데이터를 보내는 것은 프로토콜 테스트이고, Repeater는 그것을 실행하게 해 줍니다 — 마스킹하지 않은 프레임, 홀로 있는 continuation, 페이로드와 어긋나는 길이 헤더와 마찬가지로요.

gori는 `permessage-deflate`를 협상하지 않으며, 캡처 쪽도 프레임 페이로드를 도착한 그대로 저장합니다. 따라서 압축된 연결에서 캡처한 세션은 *압축된* 바이트를 담고 있어 재생할 수 없습니다. 브라우저에서 압축을 끄고 다시 캡처하세요.

명령줄에서 Repeater를 실행하고, 선택적으로 새 대상을 지정할 수 있습니다.

```bash
gori run repeater <flow-id> --target https://staging.example.com --diff
```

## 환경 변수 {#environment-variables}

아웃바운드 요청은 `$KEY` 스타일 치환을 지원합니다. 토큰은 에디터에서 리터럴 텍스트로 남아 있다가, Repeater, Fuzzer, Miner, Intercept 포워드, `gori run`, MCP `send_request`에서 전송 시점에만 확장됩니다.

변수는 두 곳에서 정의합니다(키 충돌 시 프로젝트가 우선).

| 레이어 | 위치 |
|-------|-------|
| **Global** | Preferences(`Ctrl-,`) → **Editor & Keys** → **Env**, `Ctrl-P` → **Settings: Env**, 또는 `settings.json`의 `env` 섹션 |
| **Project** | **Project** 탭 → **ENV** 패널 (`a` 추가, `e` 편집, `d` 삭제) |

기본 접두사는 `$`입니다(ENV space 메뉴의 **Change prefix**나 설정의 `env.prefix`로 변경 가능). 키는 `A-Z a-z _`로 시작해 `A-Z a-z 0-9 _`가 이어집니다.

알 수 없는 토큰은 요청이 *표시*되는 곳에서는 리터럴 텍스트로 그대로 남습니다. 에디터는 입력한 그대로를 유지하고, 하이라이터가 미등록 토큰을 등록된 토큰과 다르게 칠합니다. 다만 전송되지는 않습니다. Repeater, Fuzzer, Miner, Sequencer, Discover는 요청 라인, 헤더, 타깃에 아무것으로도 해석되지 않는 변수가 남아 있으면 그 이름을 대며 실행을 거부합니다. minimize, 편집한 intercept forward, WebSocket 메시지도 마찬가지입니다. 변수를 설정하거나 토큰을 지우세요. 검사 범위는 요청 head뿐입니다. 바디 안의 `$`는 바이트로 취급하므로 바이너리 업로드는 그대로 재전송됩니다. WebSocket **텍스트** 메시지는 head가 없으므로 페이로드 전체를 검사하고, **바이너리** 메시지는 검사하지도 확장하지도 않습니다.

```http
GET /api/me HTTP/1.1
Host: api.example.com
Authorization: Bearer $TOKEN
```

캡처된 트래픽에 나타나는 값은 복사하거나 표시할 때 다시 `$KEY`로 마스킹할 수 있어, 비밀 값이 원시 문자열이 아니라 토큰으로 유지됩니다.

## Fuzzer {#fuzzer}

Fuzzer는 Intruder 스타일 엔진입니다. 요청에서 위치를 표시하고, 페이로드 세트를 붙이고, 응답을 매칭하면서 요청 행렬을 전송합니다.

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="강조된 마커 위치를 보여주는 요청 템플릿, 페이로드 세트 설정 패널, 전송된 요청 결과 테이블, 분포 사이드바를 갖춘 gori Fuzzer 탭">
  <figcaption><strong>Fuzzer</strong>: 템플릿의 <code>§…§</code> 마커, CONFIG의 페이로드 세트와 모드, 실시간 결과 테이블, 상태 / 크기 분포 사이드바.</figcaption>
</figure>

### 공격 모드 {#attack-modes}

| 모드 | 동작 |
|------|----------|
| `sniper` | 한 번에 한 위치씩, 단일 페이로드 세트를 순환 (기본값) |
| `batteringram` | 표시된 모든 위치에 같은 페이로드 |
| `pitchfork` | 병렬 세트: 각 세트의 *n* 번째 페이로드를 함께 |
| `clusterbomb` | 모든 세트에 걸친 모든 조합 |

### 위치와 페이로드 {#positions-and-payloads}

요청에서 `§…§` 마커로 위치를 표시하거나, gori가 자동으로 배치하게 하세요. 페이로드 세트는 내장 프리셋(`sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection` — 파일 없이 바로 시작), 워드리스트, 명시적 목록, 숫자 범위, N개의 빈(null) 페이로드, 또는 무차별 대입 문자 세트가 될 수 있습니다. 프리셋은 추가 파일을 병합(내장 우선, 중복 제거)할 수 있고 다른 세트와 조합됩니다. 프로세서를 사용하면 나가는 각 페이로드를 변환할 수 있습니다: prefix/suffix, URL/base64/hex 인코딩, 대소문자 변환, 해싱, 정규식 치환.

마커 하나에 자체 Decoder 체인을 붙일 수도 있습니다. 커서를 마커 안에 두고 `Ctrl-Y`를 누르면 체인 편집기가 열리고, 보내기 전에 값이 각 단계를 거치는 모습을 미리 보여 줍니다. [Decoder 라이브러리에 저장해 둔 체인](/ko/guide/decoder/#building-a-chain)은 여기서 이름으로 부를 수 있어서, 한 번 만들어 둔 체인이 마커 안에서는 단어 하나가 됩니다: `§admin¦myenc > url-encode§`. Repeater 마커도 동일합니다.

### 매칭 {#matching}

ffuf 스타일 matcher와 filter로 status, size, words, lines, 본문 정규식에 대해 결과를 필터링합니다. 여기에 시끄러운 기준선을 걸러내는 자동 보정까지 더해집니다. 매칭된 응답은 강조되며 캡처 정규식으로 추출할 수 있습니다.

### 스윕의 프레이밍 {#framing-a-sweep}

`Content-Length`는 페이로드가 삽입될 때마다 다시 계산되므로 일반적인 스윕은 항상 일관된 상태를 유지합니다. `--verbatim`(MCP `update_content_length: false`)은 이 계산을 끕니다. 본문과 어긋나는 길이 자체가 CL / CL-TE 디싱크 테스트의 목적이기 때문입니다.

gRPC 템플릿에는 두 번째 길이 선언 — 각 메시지 앞의 5바이트 접두사 — 이 있으며, 기본값은 반대입니다. gori는 페이로드가 남긴 그대로 두고, 실행이 끝날 때 한 번 알려줍니다(`2 of 3 requests left it stale`, MCP `fuzz_status`의 `grpc_stale_prefix`). 의도적으로 잘못된 접두사를 테스트할 때는 이것이 맞는 동작이지만, 평범한 단항 호출을 스윕하는데 모든 요청이 프레이밍 계층에서 거부된다면 원하는 동작이 아닙니다. `--reframe-grpc`(MCP `reframe_grpc: true`, 또는 Fuzzer ADVANCED 카드의 **gRPC reframe (unary)** 토글)는 요청마다 접두사를 다시 계산합니다. 세 표면 모두 기본값은 꺼짐이며, 단일 메시지에만 적용됩니다. 클라이언트 스트리밍 본문, `grpc-web-text` 본문, 그리고 이미 프레이밍이 깨진 시드는 그대로 두고 여전히 보고합니다.

### 연결 재사용 {#connection-reuse}

스윕은 하나의 HTTP/1.1 연결을 여러 요청에 재사용합니다. 요청마다가 아니라 워커마다 TCP 핸드셰이크를(그리고 `https`라면 TLS 핸드셰이크까지) 한 번만 치릅니다. 원격 오리진을 대상으로 할 때 대개 이것이 실행 시간의 가장 큰 비용입니다.

프레이밍이 명확하다고 증명할 수 없는 요청은 설정과 무관하게 소켓을 공유하지 않습니다. 실제 본문 길이와 어긋나는 `Content-Length`, `CL`+`TE`, 난독화된 프레이밍 헤더, `Connection: close`, `Upgrade`는 각각 자기 연결을 받습니다. 스머글링 페이로드가 다음 페이로드의 결과를 오프레이밍할 수 없다는 뜻입니다. 대상의 동작이 연결 단위일 때(연결 범위 rate limit, 연결로 고정하는 로드 밸런서) 또는 keep-alive 처리 자체를 시험할 때는 `--no-keep-alive`(CLI), `keep_alive: false`(MCP), Fuzzer ADVANCED 오버레이의 **Keep-alive** 토글로 재사용을 끕니다.

`gori run fuzz`는 실제로 치른 비용을 함께 출력합니다: `connections · 50 dialed · 2950 reused`.

### 헤드리스 실행 {#running-headless}

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0
```

소스는 캡처된 플로우(`--flow`), 원시 요청 파일(`--request`), 또는 stdin이 될 수 있습니다. 출력은 `text`, `json`, `jsonl`입니다.

## 다음 단계 {#next-steps}

- [Decoder](/ko/guide/decoder/): 로컬 인코드/디코드/해시 체인
- [Scanning & Issues](/ko/guide/scanning/): Probe와 Param Miner
- [CLI Reference](/ko/reference/cli/): 모든 `run` 플래그
- [MCP Server](/ko/guide/mcp/): 에이전트로 퍼징 구동
