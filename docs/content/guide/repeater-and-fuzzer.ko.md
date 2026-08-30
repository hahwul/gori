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
- **gRPC** 리피터는 프레이밍된 메시지를 위해 HTTP/2 엔진을 재사용합니다. 단항(unary) 호출 — 정확히 하나의 프레이밍된 메시지 — 은 `^X`로 페이로드를 헥스 편집할 수 있고, 디스크립터 셋이 그 rpc를 선언하고 있다면 `␣E`로 **필드 단위** 편집도 됩니다. 스키마가 아는 필드를 골라 값을 입력하면 그 필드만 다시 인코딩되고 나머지 바이트는 캡처에서 그대로 복사됩니다([`.proto`를 렌즈로](/ko/guide/proxy/#proto-schema)). 메시지가 0개이거나 여러 개인 본문은 그대로 재전송됩니다. 메시지 앞의 5바이트 길이 접두사는 요청 카드의 `␣F:FRAME` 토글이 결정합니다. 이 탭에서는 기본값이 **켜짐**이라, 편집한 단항 메시지가 올바른 형식으로 나가고 원본 서버가 호출을 받아들입니다. **끄면** 편집한 페이로드 앞에 캡처된 접두사가 그대로 붙습니다 — 페이로드와 어긋나는 접두사 자체가 표준적인 gRPC 파서 테스트이기 때문입니다. 헤드리스에서는 기본값이 반대입니다. `gori run repeater send`(MCP `send_request`)는 `--reframe-grpc` / `reframe_grpc: true`를 주지 않는 한 접두사를 캡처된 그대로 보냅니다.
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

gRPC 메시지는 마커가 유용하게 쓰이지 않는 유일한 곳입니다 — 위치가 바이트 범위가 아니라 스키마가 아는 필드인 [gRPC 필드 스윕](#sweeping-a-grpc-field)을 보세요.

### 매칭 {#matching}

ffuf 스타일 matcher와 filter로 status, size, words, lines, 왕복 시간(`--mt`/`--ft`, ms 단위 — 시간 기반 블라인드 페이로드의 유일한 증거가 되는 차원), 본문 정규식에 대해 결과를 필터링합니다. 여기에 시끄러운 기준선을 걸러내는 자동 보정까지 더해집니다. 자동 보정은 스윕 전에 대상을 여러 번 샘플링한 뒤, 각 응답을 모든 샘플 형태와 비교하되 그 샘플들이 스스로 보여 준 흔들림만큼 폭을 넓혀서 비교합니다 — 그래서 요청마다 달라지는 id나 타임스탬프를 품은 페이지는 걸러지고, 샘플이 전부 동일했던 대상은 여전히 정확히 비교됩니다. 매칭된 응답은 강조되며 캡처 정규식으로 추출할 수 있습니다.

### 스윕의 프레이밍 {#framing-a-sweep}

`Content-Length`는 페이로드가 삽입될 때마다 다시 계산되므로 일반적인 스윕은 항상 일관된 상태를 유지합니다. `--verbatim`(MCP `update_content_length: false`)은 이 계산을 끕니다. 본문과 어긋나는 길이 자체가 CL / CL-TE 디싱크 테스트의 목적이기 때문입니다.

gRPC 템플릿에는 두 번째 길이 선언 — 각 메시지 앞의 5바이트 접두사 — 이 있으며, 기본값은 반대입니다. gori는 페이로드가 남긴 그대로 두고, 실행이 끝날 때 한 번 알려줍니다(`2 of 3 requests left it stale`, MCP `fuzz_status`의 `grpc_stale_prefix`). 의도적으로 잘못된 접두사를 테스트할 때는 이것이 맞는 동작이지만, 평범한 단항 호출을 스윕하는데 모든 요청이 프레이밍 계층에서 거부된다면 원하는 동작이 아닙니다. `--reframe-grpc`(MCP `reframe_grpc: true`, 또는 Fuzzer ADVANCED 카드의 **gRPC reframe (unary)** 토글)는 요청마다 접두사를 다시 계산합니다. 세 표면 모두 기본값은 꺼짐이며, 단일 메시지에만 적용됩니다. 클라이언트 스트리밍 본문, `grpc-web-text` 본문, 그리고 이미 프레이밍이 깨진 시드는 그대로 두고 여전히 보고합니다.

### gRPC 필드 스윕 {#sweeping-a-grpc-field}

protobuf 메시지 안의 바이트에 마커를 씌우는 건 실무에서 쓸 수 있는 동작이 아닙니다. `int32`
필드의 값은 varint의 옥텟이고, 그 위에 `§…§`를 두르면 필드가 아니라 와이어 포맷을 테스트하는
셈입니다. 그래서 gRPC 필드 위치는 마킹이 아니라 **이름으로 지정**합니다 — `--field role`, MCP의
`fields` 인자, 또는 Fuzzer ADVANCED 카드의 **gRPC field(s)** 행:

```
gori run fuzz --flow 42 --field role --payloads ROLE_ADMIN,ROLE_USER,99
```

`SPEC`은 필드 이름, 중첩 메시지 경로(`profile.age`), 필드 번호, 또는 반복 필드의 특정
occurrence(`tags[1]`)입니다. 해당 rpc를 해석할 descriptor set이 필요합니다 —
`protoc --descriptor_set_out` 파일이든 `gori run grpc reflect`로 받아온 것이든. 필드 이름은
같은 플로우에서 Repeater의 `␣E:FIELDS` 폼과 History의 protobuf 트리가 이미 보여 주는 그 이름입니다.

스플라이스가 할 수 있는 일에서 두 가지가 따라옵니다. 필드는 **캡처된 메시지에 실제로 있어야**
합니다 — gori는 occurrence를 교체할 뿐 추가하지 않으므로, 기본값으로 남아 와이어에 없는 proto3
필드는 위치가 될 수 없습니다(거부 메시지가 그 메시지에 실제로 있는 필드들을 나열합니다). 그리고
**`bytes`** 필드의 페이로드는 **hex**로 읽습니다(`de ad be ef`). 그 선언의 값은 바이너리이고,
텍스트로 받으면 의도한 옥텟 대신 입력한 문자열의 UTF-8이 조용히 나가기 때문입니다.

페이로드는 **선언을 거쳐** 바이트가 됩니다. 스키마가 필요한 이유가 바로 이것입니다: `-3`은
`int32`에서 부호 확장된 10바이트, `sint32`에서 지그재그 1바이트, `bool`이나 enum에서는 또 다른
옥텟입니다. 퍼징 대상이 아닌 바이트는 재직렬화가 아니라 캡처에서 그대로 복사됩니다 — 선언되지
않은 필드 번호, group, 최소가 아닌 varint, 잘린 캡처의 파싱되지 않은 꼬리까지 — 그리고 5바이트
길이 접두사는 실제로 나가는 메시지에 맞춰 다시 계산됩니다.

필드 위치의 `¦chain`과 `--encode`/`--prefix`/`--hash` 등 프로세서 파이프라인은 선언된 타입이
인코딩하기 **전의 텍스트**를 변환합니다. 그래서 `--field name¦base64-encode`는 페이로드의 base64를
*그 string 필드로* 보내고, 같은 체인을 `int32` 필드에 걸면 base64 텍스트는 정수가 아니므로 미리
거부됩니다. (TUI 행에서는 체인 안 단계 구분에 `|`나 `>`를 쓰세요 — 거기서 쉼표는 필드 구분입니다.)

세 가지는 스윕 도중이 아니라 첫 요청 전에 거부됩니다: 스키마가 선언하지 않은 필드, 선언과 와이어
타입이 충돌하는 필드(둘 다 Repeater 폼이 같은 이유로 read-only로 그리는 것들입니다 — 그 옥텟을
바꾸는 길은 여전히 `^X`입니다), 그리고 선언된 타입이 담을 수 없는 페이로드입니다.

한 가지 조합은 거부가 아니라 **보고**됩니다. `--verbatim`은 `Content-Length`를 캡처 값 그대로
두는데, 재인코딩된 메시지는 크기가 다르므로 모든 요청이 잘못된 본문 길이를 선언하고 gRPC 계층에
닿기도 전에 HTTP 프레이밍 계층에서 거부됩니다. 5바이트 접두사를 다시 계산하는 것과 정확히 같은
논리를 다른 길이 선언에 겨눈 것이지만, CL 디싱크는 실제 테스트이므로 실행은 그 사실을 알리고
진행합니다.

### WebSocket 퍼징 {#fuzzing-a-websocket}

WebSocket 세션도 다른 대상과 똑같이 스윕하지만, 프로토콜에서 비롯된 차이가 하나 있습니다. **페이로드 하나가 세션 하나**입니다. gori는 연결을 열고 RFC 6455 핸드셰이크를 수행한 뒤, 페이로드를 끼워 넣은 프레임 스크립트를 보내고, 오리진의 응답을 모두 읽어낸 다음 소켓을 닫습니다 — 그리고 다음 페이로드에 대해 이 과정을 다시 반복합니다. 소켓은 요청/응답 쌍이 아니라 대화이므로, 다른 방식으로는 어떤 응답이 어떤 페이로드에서 비롯됐는지 짝지을 수 없습니다. 따라서 동시성 N은 동시에 열린 소켓 N개를 뜻합니다.

`§…§` 위치는 **프레임 안에** 표시합니다. WebSocket 애플리케이션의 파라미터가 있는 곳이 바로 거기입니다.

```bash
gori run fuzz --repeater 7 \
  --message '{"op":"login","user":"§admin§"}' \
  --payloads-preset sqli
```

WebSocket 세션에 대한 `--repeater N`은 핸드셰이크와 **세션에 저장된 프레임**을 함께 시드하므로, 캡처된 교환을 기록된 그대로 스윕합니다. `--flow N`도 캡처된 소켓에 대해 같은 일을 합니다. 직접 프레임을 작성하려면 `--message` / `--message-frame`으로 대체하면 됩니다 — `--message-frame`은 `gori run repeater send`와 동일한 `opcode=…,fin=…,rsv=…,mask=…,len=…,hex=|b64=|text=` 문법을 쓰므로 PING, 코드를 지정한 CLOSE, 마스킹하지 않은 클라이언트 프레임, 페이로드와 어긋나는 길이 필드까지 모두 만들 수 있습니다. `--idle-ms`는 세션별 침묵 대기 시간을, `--ws-keep-key`는 템플릿 자체의 `Sec-WebSocket-Key`를 보내도록 해서 키가 없거나 잘못된 경우 자체를 시험할 수 있게 합니다.

**핸드셰이크도 위치 공간입니다.** 업그레이드 요청의 헤더나 쿼리 값에 마커를 달면 프레임과 같은 실행에서 함께 스윕됩니다. 반대 방향은 `--ws-http-only`입니다 — 핸드셰이크를 평범한 요청으로 보내고 101을 응답으로 읽으므로, 업그레이드에 200으로 답하는 오리진을 시험할 때 씁니다.

결과는 다른 스윕과 똑같이 읽힙니다. 수신 프레임이 곧 응답 본문이기 때문입니다 — `--mr`, `--mh`, `--extract`, 크기·단어 매칭이 모두 그대로 동작합니다. 다만 핸드셰이크 상태 코드가 표현할 수 없는 두 가지가 별도 필드로 붙습니다. 업그레이드가 성공하면 오리진이 페이로드를 받아들였든 아니든 모든 행이 `101`이기 때문입니다.

```
#1     bob                       101   30B   1w   1.4ms  ws 1 frame · close 1000
#2     admin'--                  101   31B   5w   1.5ms  ws 1 frame · close 1008
```

`ws_close_code`와 `ws_frames_in`은 `--format json`과 MCP `fuzz_results`에도 같은 방식으로, WebSocket 행에만 나타납니다.

적용되지 않는 옵션이 넷 있습니다. `--race`와 `--http2`는 거부됩니다 — 레이스 그룹은 바이트가 동일한 요청 복사본들이고, gori는 HTTP/1.1 업그레이드로 소켓을 다시 맺기 때문입니다(RFC 8441 확장 CONNECT에는 전송 경로가 없습니다). `--record-history`도 거부됩니다. 프레임 교환은 요청/응답 플로우가 아니어서, 기록하면 전사가 비어 있는 WebSocket인 척하는 History 항목이 남기 때문입니다. `--follow-redirects`, `--timeout`, `--ac`는 여기서 그냥 무의미하며, 실행 시작 시 한 번 그렇게 알려 줍니다. 각 거부 메시지는 원하는 동작을 얻는 방법이 `--ws-http-only`일 때 그 사실을 함께 알려 줍니다 — 그 플래그를 쓰면 평범한 HTTP 스윕이므로 셋 다 동작하며 History 기록도 됩니다. 송신 프레임이 없는 WebSocket 시드 역시 평범한 HTTP로 스윕합니다. 핸드셰이크만 있는 “프레임” 실행은 페이로드마다 소켓을 열어 아무것도 보내지 않을 뿐이기 때문입니다.

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

소스는 캡처된 플로우(`--flow`), 저장된 HTTP 리피터 세션(`--repeater`), 원시 요청 파일(`--request`), 또는 stdin이 될 수 있습니다. 출력은 `text`, `json`, `jsonl`입니다.

**TUI의 Repeater 전송은 History에 기록됩니다.** 손으로 요청을 다루는 테스터야말로 증거가 사라지던 쪽이었고, 플로우를 남기지 않는 전송은 비교도 내보내기도 인계도 할 수 없습니다. 상태줄이 방금 쓴 id를 알려 줍니다(`sent → 200 in 391ms · History #84`). Settings → General → *Record Repeater sends*에서 끌 수 있습니다. WebSocket 전송과 send-group은 기록되지 않으며(소켓의 증거는 프레임 트랜스크립트이고 세션이 이미 갖고 있습니다) 상태줄이 한 번 그렇게 알려 줍니다.

나머지는 그대로 opt-in이고, 헤드리스 표면은 각자의 호출별 인자를 유지하므로 이 설정 때문에 스크립트 동작이 바뀌지 않습니다. `gori run repeater send --record-history`는 전송을 플로우로 기록하고 그 id를 출력하며(기본 off), `gori run fuzz --record-history=none|matched|all`은 전송한 각 요청+응답을 기록하고(`matched`는 매칭된 행만, `all`은 매 전송, 5000개 상한), MCP `send_request`는 `record_history:false`를 넘기지 않는 한 기록합니다.

기록된 플로우는 모두 출처를 말합니다 — History의 **SRC** 열, 그리고 쿼리의 `src:repeater` /
`src:fuzzer` / `src:gori` — 그래서 재전송이 대상 클라이언트가 만든 트래픽으로 잘못 읽히지
않습니다. [이 플로우는 어디서 왔나](/ko/guide/proxy/#flow-source)를 보세요.

두 도구 모두, 기록된 플로우는 **와이어에 나간 그대로의 요청**입니다. 활성 세션 슬롯의 헤더 오버레이와 전송 시점에 치환된 `$NAME` 값이 그 안에 들어 있으므로, 그 플로우를 재전송·비교·스캔하면 조립 전 초안이나 템플릿이 아니라 실제 전송을 재현합니다. (Fuzzer의 결과 *행*은 여전히 렌더된 템플릿을 보여줍니다. "Repeater로 보내기"가 그 바이트로 탭을 시드하고, 슬롯은 전송할 때마다 적용되기 때문입니다.)

## 다음 단계 {#next-steps}

- [Decoder](/ko/guide/decoder/): 로컬 인코드/디코드/해시 체인
- [Scanning & Issues](/ko/guide/scanning/): Probe와 Param Miner
- [CLI Reference](/ko/reference/cli/): 모든 `run` 플래그
- [MCP Server](/ko/guide/mcp/): 에이전트로 퍼징 구동
