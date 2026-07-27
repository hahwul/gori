+++
title = "프록시 & History"
description = "트래픽을 캡처하고, 요청을 인터셉트하고, 대상을 스코프로 좁히고, 모든 프로토콜을 살펴봅니다."
weight = 10

[extra]
group = "핵심"
+++

프록시는 클라이언트와 업스트림 서버 사이에 자리 잡아 오가는 요청과 응답을 *플로우*로 기록하고 현재 프로젝트에 저장합니다. **History**는 그 플로우를 되짚어 읽는 곳입니다.

## 트래픽 캡처 {#capturing-traffic}

gori를 실행하고 클라이언트를 `127.0.0.1:8070`으로 향하게 하세요(자세한 내용은 [Quick Start](/ko/getting-started/quick-start/) 참고). `c`로 언제든 캡처를 토글할 수 있습니다. 꺼두면 트래픽이 기록 없이 통과하므로 환경을 설정하는 동안 편리합니다.

클라이언트가 프록시를 바라보고 있다면 `http://gori.proxy/`에서 gori의 안내 페이지와 CA 다운로드를 받을 수 있습니다. gori가 자체적으로 응답하는 예약된 이름이라 네트워크로 나가지 않습니다. 인증서보다 프록시를 먼저 설정하게 되는 휴대폰에서 특히 유용합니다. 프록시를 설정하지 않은 클라이언트는 리슨 주소로 직접 접속하면 같은 페이지를 받습니다.

각 플로우는 요청과 응답 전체를 기록합니다. 시작 줄, 헤더, 본문(저장되는 본문은 2 MiB로 제한되지만, 더 큰 본문도 바이트 단위 그대로 전달되며 실제 크기를 보고합니다)까지 담습니다. gzip, deflate, Brotli, Zstd로 압축된 본문은 화면에 표시할 때 디코드됩니다.

> **HTTPS와 업스트림 검증.** HTTPS의 경우 gori는 오리진 서버 인증서를 시스템 CA 트러스트 스토어로 검증합니다(표준 위치에서 자동 탐색하며 `SSL_CERT_FILE` / `SSL_CERT_DIR`를 존중). 최소 컨테이너 등에서 스토어를 찾지 못하면 검증이 실패해 해당 플로우는 오류로 기록됩니다. 이때는 `SSL_CERT_FILE=/path/to/ca-bundle.crt`를 지정하거나 `--insecure-upstream`으로 실행하세요(설정 → **Network → verify upstream**). 이는 gori가 트래픽을 복호화하기 위해 *클라이언트*에서 gori 루트 CA를 신뢰하는 것과는 별개입니다.

<figure class="tui-shot">
  <img src="/images/tui/response-detail.svg" alt="RESPONSE 서브탭의 gori 플로우 상세 뷰. HTTP/2 200 상태 줄과 구문 강조된 응답 헤더를 보여준다">
  <figcaption><kbd>Enter</kbd>로 아무 플로우나 열어 전체 요청과 응답을 읽습니다. 헤더, HTTP/2 프레임, 원시 바이트를 볼 수 있는 서브탭이 함께 제공됩니다.</figcaption>
</figure>

## 인터셉트 {#intercept}

`i`를 눌러 **Intercept**를 켭니다. 켜져 있으면 매칭되는 요청(그리고 선택적으로 응답)이 붙잡혀, 계속 진행하기 전에 포워드, 드롭, 편집할 수 있습니다. Intercept 탭 상단의 필터 바에서 붙잡을 방향을 고르고 쿼리 언어 표현식으로 붙잡을 대상을 좁힐 수 있어, 관심 있는 트래픽에서만 멈춥니다.

<figure class="tui-shot">
  <img src="/images/tui/intercept.svg" alt="붙잡을 방향과 쿼리 조건을 위한 필터 바, 그리고 catch가 꺼졌을 때의 forward/drop을 설명하는 카드를 갖춘 gori Intercept 탭">
  <figcaption><strong>Intercept</strong> 탭: <kbd>i</kbd>로 catch를 토글하고, 방향을 고르고, 매칭되는 트래픽만 붙잡아 이동 중에 포워드, 드롭, 편집합니다.</figcaption>
</figure>

## 스코프 {#scope}

스코프는 큰 세션을 대상에 집중시킵니다. **Project** 탭에서 호스트, 문자열, 정규식으로 include/exclude 규칙을 정의합니다. `s`로 **scope 렌즈**를 토글하면 뷰가 스코프 내 트래픽으로 좁혀집니다. Intercept와 스캐너가 작동할 대상도 스코프로 제한할 수 있습니다.

### 샌드박스 {#sandbox}

**샌드박스**는 테스트를 허용된 범위 안으로만 강하게 가두는 차단 게이트입니다. **Project** 탭의 **NETWORK** 패널에서 토글합니다(기본값: off). on인 동안 캡처 프록시는 스코프가 *허용*하는 요청만 전달하고, 나머지는 오리진에 닿기 전에 차단합니다(클라이언트는 `X-Gori-Sandbox: blocked` 헤더가 붙은 `403`을 받습니다). 차단된 시도도 aborted 플로우로 기록되어 History에서 확인할 수 있습니다. 여기서 "허용"이란 스코프를 허용 목록(allowlist)으로 평가한 것으로, include 규칙이 하나 이상 매칭되고 exclude 규칙에는 매칭되지 않아야 합니다.

허용 목록이므로 include 규칙이 하나도 없으면 모든 트래픽이 차단됩니다. 먼저 대상에 대한 include를 추가하세요(스코프가 빈 상태에서 샌드박스를 켜면 바로 이 점을 확인하도록 물어봅니다). 켜져 있는 동안에는 상단 바에 빨간 `sandbox` 칩이 계속 표시되고, NETWORK 행의 토글 옆에 현재 효과가 안내됩니다.

샌드박스는 프록시로 캡처되는 트래픽에만 적용됩니다. Repeater, Fuzzer, Miner, MCP `send_request` 도구는 각자 스코프를 강제합니다(범위를 벗어난 대상은 `SCOPE_BLOCKED`로 거부). HTTPS는 요청 URL을 확인하기 위해 TLS 인터셉트에 의존합니다. 스코프에 들 수 없는 호스트는 `CONNECT` 단계에서 거부되고, 인터셉트 가능한 연결은 매 요청을 개별 검사할 수 있도록 HTTP/1.1로 유지됩니다.

## Sitemap {#sitemap}

**Sitemap** 탭은 History를 중복 제거된 `host → path` 엔드포인트 트리로 접어, 메서드 칩과 스코프 마커를 함께 보여줍니다. 대상의 공격 표면을 한눈에 파악하기 좋습니다. `g`를 누르면 경로 파라미터의 id를 접습니다. `/user/1`과 `/user/2`가 한 노드를 공유하고, `/user/<uuid>`는 `{uuid}` 하나로 모입니다.

<figure class="tui-shot">
  <img src="/images/tui/sitemap.svg" alt="캡처된 호스트들이 경로 트리로 펼쳐지고 메서드 칩과 호스트별 경로 개수가 표시된 gori Sitemap 탭">
  <figcaption><strong>Sitemap</strong>은 History를 메서드 칩이 달린 <code>host → path</code> 트리로 접어, 대상의 표면을 한눈에 보여줍니다.</figcaption>
</figure>

## 프로토콜 지원 {#protocol-support}

gori는 지나가는 프로토콜을 인식합니다.

| 프로토콜 | 지원 |
|----------|---------|
| **HTTP/1.1** | 전체 캡처 및 리피터 |
| **HTTP/2** | ALPN 이후 투명 릴레이, 원시 프레임 로그, HPACK 디코드, stream → flow 조립 |
| **WebSocket** | 실시간 메시지 캡처 및 리피터 (permessage-deflate 미지원) |
| **gRPC** | HTTP/2 위에 프레이밍되고 status 트레일러 포함; protobuf는 원시 바이트로 표시 (`.proto` 스키마 없음) |
| **Server-Sent Events** | 표시 시점에 개별 이벤트로 파싱 |

와이어 프로토콜 위에서, gori는 흔히 쓰이는 페이로드를 인라인으로 디코드합니다.

- **JWT**: `Authorization`, 쿠키, URL, 본문에서 헤더와 페이로드를 디코드합니다(서명은 표시되지만 검증하지 않습니다).
- **SAML**: `SAMLRequest` / `SAMLResponse`에 대해 base64(그리고 리다이렉트 바인딩의 경우 DEFLATE)를 디코드합니다.
- **GraphQL**: POST 본문과 `?query=` 파라미터에서 `query`, `operationName`, `variables`를 파싱합니다.
- **Form 파라미터**: `application/x-www-form-urlencoded` 및 `multipart/form-data` 요청 본문과 URL 쿼리 문자열을 PARAMS 패널에서 단순한 key=value 목록으로 디코드합니다(multipart 파일 파트는 요약됩니다).

## History 필터링 {#filtering-history}

History는 gori의 [쿼리 언어](/ko/reference/query-language/)로 검색할 수 있습니다. 몇 가지 예시입니다.

```text
status:5xx                  flows that errored
host:api.example.com        a single host
method:POST body:password   POST requests mentioning "password"
dur:>500                    responses slower than 500 ms
path~/admin/                path matching a regex
```

History 필터 바에 쿼리를 입력하거나, 헤드리스로 실행하세요.

```bash
gori run history -q 'status:5xx host:api.example.com'
```

## 플로우 표시하기 (다중 선택) {#marking-flows}

`t`를 누르면 커서 위의 플로우를 **표시(mark)** 하고 바로 다음(더 오래된) 플로우로 이동하므로, `t`를 연달아 누르면 정렬 순서와 무관하게 연속된 행이 표시됩니다. `Shift-↑` / `Shift-↓`는 시작한 지점부터 연속 범위를 확장하고, `Shift-T`는 현재 필터에 보이는 전체를 표시하며, `Esc`는 표시를 모두 해제합니다. 표시된 행은 왼쪽 여백에 굵은 막대가 붙고, 필터 줄에 `3 marked` 카운트가 실시간으로 표시됩니다.

표시는 **어떤 동작이 있는지**를 바꾸지 않고, **스페이스 메뉴가 무엇을 대상으로 하는지**만 바꿉니다.

> 실제 대상 = **표시된 것이 있으면 그것들, 없으면 커서 행**

따라서 `/ status:5xx` → `Shift-T` → `Space` → `X`면 모든 오류 플로우를 확인 한 번으로 삭제하고, `Space` → `F`면 그 URL들을 한꺼번에 복사합니다. 메뉴 제목이 `SPACE · 3 MARKED`로 바뀌고 항목 이름도 `Delete 3 flows`, `Mine 3 flows`처럼 바뀌므로, 일괄 처리가 예상 밖에 일어나는 일은 없습니다.

| 동작 | 키 | 표시된 플로우에 대해 |
|------|-----|--------------------|
| 복사 | `y` | URL 목록(한 줄에 하나) |
| 형식 지정 복사 | `Space` `F` | urls / host 목록 / cURL / 원본 요청 / 원본 응답 |
| 삭제 | `Space` `X` | 전체를 확인 한 번으로 |
| 이슈/노트에 연결 | `Space` `k` / `u` | 대상은 한 번만 선택, 전체를 첨부 |
| 이슈 추가 | `Shift-F` | 표시된 전체를 근거로 가진 이슈 하나 |
| Repeater / Fuzzer | `Ctrl-R` / `Shift-I` | 플로우마다 서브탭 하나(최대 20) |
| 파라미터 마이닝 | `Space` `m` | 설정 팝업 한 번, 플로우마다 세션 하나(최대 20) |
| 액티브 스캔 실행 | `Space` `A` | 요청 수 추정치를 전체에 대해 합산 |
| 스코프에 호스트 추가 | `Space` `h` | 호스트 중복 제거 — 2개 호스트의 12개 플로우면 규칙 2개 |
| Comparer로 보내기 | `Space` `c` | 정확히 2개면 A(이전)/B(이후)에 바로 채움 |

표시는 필터 변경, 정렬 변경, 다른 탭에 갔다 오는 것에도 유지됩니다. 카운트 칩이 현재 화면에 없는 개수를 알려줍니다. 트래픽을 보내는 동작은 여전히 먼저 확인을 받고 요청마다 스코프를 검사합니다 — 표시는 요청 수를 바꾸지, 게이트를 바꾸지 않습니다. 플로우 하나에만 의미가 있는 몇 가지(상세 보기 열기, Sequencer)는 단일 대상으로 남으며, 표시가 있는 동안 메뉴 항목에 `(cursor)`가 붙습니다.

## Match & Replace (Rewriter 탭) {#match-replace}

**Rewriter** 탭이 Match & Replace 편집기입니다. 이동 중인 요청/응답을 재작성하는 규칙을 관리합니다. 기본적으로 숨김 상태이므로 탭 바의 `⋯` 메뉴나 커맨드 팔레트(`Ctrl-P` → **Match & Replace** 또는 **Go to Rewriter**)로 엽니다.

각 규칙에는 동작이 있습니다.

| 동작 | 하는 일 |
|------|---------|
| **Replace** | 헤드나 본문의 텍스트를 리터럴 부분 문자열 또는 정규식으로 찾아 치환 |
| **Add header** | `Name: value` 헤더를 추가 |
| **Set header** | 이름으로 헤더 값을 교체(없으면 추가) |
| **Remove header** | 이름으로 헤더를 제거 |

**Replace** 규칙은 요청이나 응답의 **헤드**(요청/상태 줄 + 헤더) 또는 **본문**(엔티티)을 대상으로 합니다. 리터럴과 정규식 중에서 고르며, 정규식 치환은 `$1`/`$2` 캡처 그룹 삽입을 지원합니다(리터럴 `$`는 `$$`). 헤더 동작은 항상 헤드에 적용되고, 헤더 이름을 대소문자 구분 없이 매칭합니다. 값이 비어 있으면 매칭된 텍스트를 삭제하거나 헤더를 제거합니다.

어떤 규칙이든 **호스트** 글롭으로 범위를 좁혀 매칭되는 트래픽에만 적용할 수 있습니다. 일반 문자열은 부분 문자열로 매칭되고(`example.com`은 `api.example.com`에 매칭), `*`는 와일드카드입니다(`*.example.com`). 비워 두면 모든 호스트에 적용됩니다.

목록은 `a` 추가, `e`/`Enter` 편집, `x` 켜기/끄기, `d` 삭제, `Shift-J`/`Shift-K` 순서 변경(규칙은 위에서 아래로 적용), `space`로 전체 메뉴를 다룹니다. 편집기는 규칙이 최근 몇 개의 플로에 영향을 줄지 실시간 미리보기로 보여 줍니다. 규칙은 프로젝트별이며 저장 즉시 적용되고 재시작은 필요 없습니다.

**본문** 규칙은 메시지를 버퍼링해 재작성하고 `Content-Length`를 자동으로 다시 맞춥니다(청크 본문은 de-chunk 후 재프레이밍됩니다). 헤드 규칙은 본문을 손대지 않고 계속 스트리밍합니다. 압축된(`Content-Encoding: gzip`/`br`/…) 본문은 압축을 풀지 않으므로 리터럴 패턴이 매칭되지 않고, 스트리밍 응답(SSE, close로 구분되는 응답, WebSocket 업그레이드)은 그대로 흘려보냅니다. 규칙을 하나라도 켜면 매칭되는 호스트는 HTTP/1.1로 내려갑니다. HTTP/2 헤드는 재작성 지점에 닿지 않기 때문입니다.

같은 규칙을 헤드리스에서도 다룰 수 있습니다. `gori run rewriter`(list / add / rm / enable / disable / preview)와 MCP의 `create_rule` / `update_rule` / `list_rules` / `preview_rule` 도구입니다.

## 임포트 {#import}

모든 것을 실시간으로 캡처할 필요는 없습니다. 커맨드 팔레트(`Ctrl-P`)에서:

| 동작 | 소스 |
|--------|--------|
| **Import: HAR** | 브라우저 또는 프록시 HAR 익스포트 → 전체 요청/응답 플로우 |
| **Import: URLs** | 한 줄에 URL 하나씩 담긴 텍스트 파일 → 골격 요청 플로우 |
| **Import: OpenAPI** | OpenAPI/Swagger JSON 또는 YAML → 오퍼레이션마다 요청 템플릿 하나 |

형식이 잘못된 항목은 전체 임포트를 중단시키지 않고 건너뜁니다. 임포트된 플로우는 캡처된 트래픽처럼 History에 들어오므로, 똑같이 필터링하고 Repeater로 재전송하거나 퍼징·스캔할 수 있습니다.

## 호스트 오버라이드 {#host-overrides}

호스트 오버라이드는 `/etc/hosts` 스타일 맵입니다. DNS를 바꾸지 않고 호스트명에 대해 특정 IP로 접속합니다. 두 개의 레이어가 있습니다.

| 레이어 | 위치 | 우선순위 |
|-------|-------|------------|
| **Project** | **Project** 탭 → HOST OVERRIDES 패널 (`a` / `e` / `d`) | 충돌 시 우선 |
| **Global** | Preferences(`Ctrl-,`) → **Network & Tabs** → **Network** → **Hostname overrides**, `Ctrl-P` → **Settings: Hostnames**, 또는 `settings.json`의 `hostname_overrides` | 폴백 |

스테이징 호스트, IP 기반 가상 호스트, 또는 `Host` 헤더를 그대로 유지하면서 프로덕션 호스트명을 랩 박스로 향하게 할 때 유용합니다.

## 프록시를 설정할 수 없는 클라이언트 {#clients-without-proxy}

프록시 설정을 아예 무시하는 클라이언트가 있습니다 — 임베디드 장비, 정적 링크된 바이너리, `HTTP_PROXY`를 읽지 않는 모든 것. 이런 경우 **투명 리스너**를 띄우고 방화벽으로 트래픽을 밀어 넣으세요. gori가 평문은 `Host` 헤더에서, HTTPS는 TLS SNI에서 목적지를 유도하므로 클라이언트 쪽 설정이 전혀 필요 없습니다.

`settings.json`의 `listeners`에 추가하고 `iptables` / `pf`를 그쪽으로 향하게 하면 됩니다 — 설정 키와 리다이렉트 규칙은 [`listeners` 레퍼런스](/ko/reference/config/#listeners)를 참고하세요. 캡처되는 플로우, 스코프, 샌드박스, passthrough 목록 모두 일반 프록시 경로와 똑같이 동작합니다.

인증서는 여전히 클라이언트에서 신뢰해야 합니다. 투명 모드가 없애 주는 것은 프록시 *설정*이지 gori CA의 필요성이 아닙니다.

## 피닝된 앱이 방해할 때 {#pinned-app-in-the-way}

gori는 모든 HTTPS 연결을 가로채므로, 인증서를 피닝하는 클라이언트(모바일 앱, 자동 업데이터, 백그라운드 에이전트)는 깨집니다. 휴대폰이나 공용 머신에서는 그런 트래픽이 원하든 원치 않든 함께 들어오고, 다른 것을 테스트하는 동안 계속 실패합니다.

그 호스트들을 **TLS passthrough**에 등록하세요(Preferences → **Network & Tabs** → **Network**, 쉼표로 구분. 또는 `settings.json`의 `network.tls_passthrough`). 등록된 호스트는 불투명한 터널로 중계되어, 클라이언트가 원 서버의 실제 인증서를 보고 정상 동작합니다. 대신 그 호스트는 아무것도 캡처되지 않습니다.

스코프로는 안 됩니다. 스코프는 무엇을 기록하고 개입할지를 결정할 뿐이고, 스코프 밖 호스트도 복호화됩니다. TLS 자체에 손대지 않게 하는 설정은 passthrough뿐입니다. 패턴 문법은 [`tls_passthrough` 레퍼런스](/ko/reference/config/#tls-passthrough)를 참고하세요.

## Project 탭 {#project-tab}

**Project** 홈 탭은 단순한 요약 이상입니다. 포커스 가능한 패널들(`Tab`으로 순환):

<figure class="tui-shot">
  <img src="/images/tui/project.svg" alt="개요, 한눈에 보는 상태 바, 스코프, 호스트 오버라이드, 환경 변수, 설명, 네트워크 패널을 갖춘 gori Project 탭">
  <figcaption><strong>Project</strong> 홈: 개요와 한눈에 보는 상태, 그리고 스코프, 호스트 오버라이드, 환경 변수, 프로젝트별 네트워크 설정 패널.</figcaption>
</figure>

| 패널 | 용도 |
|------|---------|
| **SCOPE** | include/exclude 규칙 (호스트, 문자열, 정규식) |
| **HOST OVERRIDES** | 프로젝트별 접속 맵 |
| **ENV** | 아웃바운드 요청을 위한 프로젝트별 `$KEY` 변수. [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/#environment-variables) 참고 |
| **DESCRIPTION** | 자유 형식 프로젝트 노트 |
| **NETWORK** | scope 렌즈 + **샌드박스** 토글, 그리고 전역 Settings 기본값을 재정의하는 프로젝트별 네트워크 고정(bind / upstream) |

스코프 규칙과 호스트 오버라이드는 스크립트로도 다룰 수 있습니다: `gori run project scope add --kind=include --type=host --pattern=api.example.com`, `gori run project host-override add --host=api.example.com --ip=10.0.0.1`. 전체 플래그는 [CLI Reference](/ko/reference/cli/#run-project)에 있습니다.

## 다음 단계 {#next-steps}

- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 캡처한 플로우를 다룹니다
- [Decoder](/ko/guide/decoder/): TUI를 벗어나지 않고 인코드, 디코드, 해시
- [Scanning & Issues](/ko/guide/scanning/): 자동 및 수동 분석
- [Query Language](/ko/reference/query-language/): 전체 필터 문법
