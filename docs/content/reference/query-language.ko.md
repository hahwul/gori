+++
title = "쿼리 언어"
description = "History, Sitemap, Probe, Issues, Intercept, MCP 도구 전반에서 쓰는 필터 문법."
weight = 30
+++

gori에는 플로우를 걸러내는 작은 쿼리 언어(QL)가 있습니다. 같은 문법이 TUI 필터 바, `gori run`(`-q`/`--query` 또는 위치 인자), 그리고 MCP 도구에서 동일하게 동작합니다. 내장 레퍼런스는 `gori run history --help`와 `ql_reference` MCP 도구로도 볼 수 있습니다.

## 필드 {#fields}

`field:value`로 필드를 매칭합니다(필드에 따라 부분 문자열 또는 완전 일치):

| Field | Matches |
|-------|---------|
| `host` | 요청 호스트 |
| `path` | 요청 경로 |
| `url` | 전체 URL |
| `method` | HTTP 메서드 |
| `scheme` | `http` / `https` |
| `proto` | 프로토콜: `http`, `ws`, `grpc`, `sse` |
| `src` | 이 플로우가 어디서 왔는지([아래](#src-provenance)) |
| `status` | 응답 상태 코드 |
| `size` | 요청 + 응답 전체 바이트 |
| `reqsize` / `respsize` | 각 방향의 바이트 수 |
| `dur` | 응답 시간(밀리초) |
| `header` | 헤드(요청 + 응답 헤더) 부분 문자열 |
| `body` | 본문 전문 검색(trigram FTS 인덱스) |
| `scope` | `in` / `out` — 프로젝트 스코프 규칙([아래](#scope-in-scope-out)) |

```text
host:example.com
method:POST
status:404
```

### 한쪽 방향만 보기: `req.` / `resp.`

`header:`와 `body:`는 **요청과 응답을 모두** 뒤집니다. 한쪽만 보려면 `req.` 또는 `resp.`를 앞에 붙입니다.

| 필드 | 뜻 |
| --- | --- |
| `req.body` / `resp.body` | 그 방향의 본문만 |
| `req.header` / `resp.header` | 그 방향의 헤드만 |

```text
resp.body:secrettoken                 응답 본문에만 들어있는 토큰
resp.header:set-cookie                쿠키를 내려주는 응답
-resp.body:abcd                       응답 본문에 abcd가 없는 것
req.body~(?i)password                 요청 본문 정규식(한쪽만)
NOT (req.body:token OR resp.body:token)
```

`res.`는 `resp.`의 동의어이고, `req.size` / `resp.size`는 `reqsize` / `respsize`와 같습니다. 방향이 하나뿐인 필드(`host`, `method`, `status` 등)에는 접두사를 붙이지 않습니다.

## 출처: `src:` {#src-provenance}

`src:`는 **요청을 실제로 보낸 주체**로 플로우를 고릅니다. `src:proxy`는 클라이언트가 gori를
거쳐 보낸 트래픽이고, 나머지 값은 gori 자신이 만든 요청입니다. `src:import`는 다른 도구가
남긴 캡처를 읽어 들인 것입니다.

| 값 | 매칭 대상 |
|-------|---------|
| `proxy` | 캡처 프록시가 중계한 클라이언트의 요청 — 평범한 캡처 트래픽 |
| `repeater` | Repeater 전송(TUI, `gori run repeater send --record-history`, MCP `send_request`) |
| `fuzzer` | `--record-history` / `record_history`로 기록된 퍼즈 결과 |
| `discover` | 크롤러가 가져온 것(Discover는 기본으로 저장합니다) |
| `miner`, `sequencer`, `authorize`, `probe` | 예약됨 — 아직 플로우를 기록하지 않는 도구들 |
| `import` | HAR, Burp export, `--urls`, OpenAPI 문서에서 읽어 들인 것 |
| `gori` | gori가 **보낸** 모든 출처 — 가운데 행들의 합집합이며 `import`는 **포함하지 않습니다** |

```text
src:proxy                             실제로 일어난 트래픽만 History로 읽기
-src:proxy                            gori가 넣은 것 전부
src:gori                              …같은 집합을 긍정형으로
src:repeater status:200               내가 다시 보낸 것 중 200으로 돌아온 것
src:fuzzer resp.body:root:            퍼즈 히트 — 내 페이로드를 발견으로 착각하지 않도록
```

History의 **SRC** 열은 이 값들을 짧은 태그로 찍습니다(`PROXY`, `RPTR`, `FUZZ`, `CRAWL`,
`IMPRT` …). `src:`는 그 태그도 받으므로 `src:rptr`과 `src:repeater`는 같은 쿼리입니다.
`source:`는 `src:`의 긴 철자로 함께 받습니다.

두 가지는 의도된 동작입니다:

- **가져온(import) 플로우는 `src:gori`가 아닙니다.** gori가 그것을 전송한 적이 없고, 다른
  사람이 캡처한 실제 엔드포인트를 설명할 뿐입니다. `-src:proxy`에는 걸리고 `src:gori`에는
  걸리지 않습니다.
- **출처를 기록하기 전에 캡처된 플로우는 양쪽 어디에도 걸리지 않습니다.** 그 행들은 출처를
  전혀 갖고 있지 않습니다 — 컬럼이 생기기 전에도 gori는 이미 Repeater 전송·크롤·import를
  History에 쓰고 있었으므로, 그것들을 `proxy`로 채우는 것은 어떤 캡처도 만들지 않은 사실을
  지어내는 일이 됩니다. SRC 열에는 `—`가 뜨고 `src:proxy`와 `-src:proxy` 양쪽 모두 이 행을
  건너뜁니다. Pending 플로우가 `status:`와 `-status:` 양쪽에서 빠지는 것과 같습니다. 업그레이드
  이후에 캡처된 플로우만 이 값을 가집니다.

## 스코프: `scope:in` / `scope:out` {#scope-in-scope-out}

`scope:in`은 프로젝트 스코프 안쪽의 플로를 고릅니다 — TUI의 `⇧S` 렌즈와
`gori run history --in-scope`가 적용하는 그 include/exclude 경계와 완전히 같은 것입니다.
`scope:out`은 그 바깥을 고릅니다. 보통 항목이므로 부정할 수도, 괄호로 묶을 수도 있습니다:

```text
scope:in status:5xx                   타깃에서 난 서버 에러
scope:out -host:cdn                   스코프 밖으로 새어 나간 트래픽, CDN 제외
(scope:in OR host:staging.example.com) method:POST
```

의도된 성질이 세 가지 있습니다.

- **`⇧S` 렌즈가 켜졌는지와 무관합니다.** 필터 항목은 모드가 아니라 질문이므로 `scope:in`은 어느
  쪽이든 같은 뜻입니다. (렌즈가 켜져 있으면 렌즈가 이미 같은 조건을 AND로 걸기 때문에
  `scope:in`은 중복이 되고, `scope:out`은 아무것도 매치하지 않습니다.)
- **스코프 규칙이 하나도 없으면 두 표기 모두 아무것도 매치하지 않습니다.** 스코프 안에 든 것이
  없으니 질문에 답이 없고, 그래서 묻지 않습니다. 특히 그 상태에서 `scope:out`은 "전체"를 뜻하지
  **않습니다** — 같은 이유로, never-match를 부정한 `-scope:in`은 그 상태에서 `scope:out`과 같지
  않습니다. `ql_explain`은 `scope_rules_configured: false`와 경고를 함께 돌려주고,
  `gori run history delete`는 답할 스코프가 없는 항목 하나로 프로젝트 히스토리를 지우지 않도록
  스코프 쿼리를 아예 거부합니다.
- **`scope:`는 플로 단위입니다.** 그래서 Sitemap에서는 `gori run sitemap --in-scope`와 다릅니다.
  그쪽은 호스트 단위(트래픽 중 하나라도 스코프 안이면 그 호스트를 남김)이므로, `scope:in` 쿼리는
  호스트는 남기면서 그 호스트의 일부 엔드포인트만 떨어뜨릴 수 있습니다.

캡처는 어느 쪽으로도 영향을 받지 않습니다. gori는 언제나 전부 기록하고, 이것은 쿼리가 돌려주는
범위만 좁힙니다.

## 상태 클래스 {#status-classes}

`status:`는 클래스 약어를 받습니다:

```text
status:2xx      status:4xx      status:5xx
```

## 비교 {#comparisons}

숫자 필드(`status`, `size`, `reqsize`, `respsize`, `dur`)는 비교 연산자 `<`, `<=`, `>`, `>=`, `=`를 지원합니다:

```text
status:>=500        서버 오류
size:>100000        큰 교환
dur:>500            500ms보다 느림
dur:<2s             2s보다 빠름 (s / ms 접미사 허용)
```

## 정규 표현식 {#regular-expressions}

`host`, `path`, `url`, `header`, `body`에 정규식 매칭을 하려면 `~`를 씁니다. `~`는 자체적으로 필드/값 구분자 역할을 하므로 앞에 콜론을 붙이지 **마세요**. 매칭은 대소문자를 구분하며, 대소문자를 무시하려면 `(?i)`를 앞에 붙입니다.

```text
path~/admin/
host~^api\.
header~set-cookie
```

## 항목 결합 {#combining-terms}

- 공백으로 구분된 항목들은 **AND**로 결합됩니다. `AND`를 직접 써도 됩니다.
- `OR`는 둘 중 하나를 매칭합니다. `NOT`과 `-` 접두사는 모두 부정입니다.
- 괄호로 묶을 수 있습니다. 우선순위는 `NOT`, `AND`, `OR` 순입니다.
- `field:`가 없는 단순 단어는 method, host, target을 대상으로 하는 자유 텍스트 검색입니다.
- 존재하지 않는 `field:` 이름은 의도한 자유 텍스트가 아닙니다. `gori run history`, `gori run sitemap`, `gori run probe`는 이를 **거절**하고 가장 가까운 실제 필드를 알려준 뒤 0이 아닌 코드로 종료합니다. `--lenient`를 주면 그 토큰을 텍스트로 검색합니다(예전에 모든 표면이 조용히 하던 동작 — `methd:GET`은 아무것도 매칭하지 않아 프로젝트가 비어 보였습니다). TUI 필터 바는 타이핑 중인 이름을 그대로 받습니다.

```text
host:example.com status:5xx           둘 다 매칭되어야 함
host:api AND status:5xx               같은 의미를 풀어 쓴 것
method:POST -status:200               POST이지만 200은 아님
host:a.com OR host:b.com              둘 중 하나의 호스트
(host:a.com OR host:b.com) -path:/js  둘 중 하나의 호스트, /js 제외
NOT (host:cdn OR host:static)         둘 다 아닌 것
login                                 자유 텍스트 검색
```

`AND`, `OR`, `NOT`은 대문자로 쓸 때만 연산자로 인식합니다. 따라서 "and", "or", "not"이라는
단어를 검색하는 것도 그대로 됩니다. 대문자라도 따옴표로 감싸면 리터럴이 됩니다.

큰따옴표는 공백이 포함된 값을 하나의 항목으로 유지합니다:

```text
host:"my host"                        공백까지 포함한 하나의 host 값
"two words"                           구 전체를 자유 텍스트로
"OR"                                  연산자가 아닌 단어 그대로
```

값 안의 괄호는 리터럴로 남으므로 `path:/a(b)`는 이스케이프가 필요 없습니다. `(`는 항목의
맨 앞에서만 그룹을 열고, `)`는 맨 뒤에서만 그룹을 닫습니다.

## 적용 범위 {#where-it-applies}

모든 필터 바가 위 문법(필드, 비교, `~` 정규식, `AND`/`OR`/`NOT`, 괄호, 따옴표)을 공유합니다. 다른 것은 필드 집합뿐이고, 그것도 각 화면이 서로 다른 종류의 행을 거르기 때문입니다.

| 화면 | 필드 |
|------|------|
| History, `gori run history`, MCP | 위 표 전체 |
| Sitemap | 위와 동일, 여기에 노드별 경로 메모용 `tag:` 추가 |
| 컬러 규칙(Colormarker) | 위와 동일 — History 필터 바에 쓰는 그 쿼리를 그대로 받습니다 |
| Intercept 캐치 조건, Extract 규칙 조건 | `host`, `path`, `url`, `method`, `scheme`, `status`, `proto`, `header`, `body` — **`scope:` 없음** |
| Probe | `severity`(`sev`), `status`(`st`), `category`(`cat`), `host`, `code` |
| Issues | `severity`(`sev`), `status`(`st`), `host`, `title` |

`scope:`는 홀드 게이트와 Extract 규칙 조건이 답하지 않고 거부하는 유일한 필드입니다. 두 곳은
흐르는 중인 메시지를 평가하는데, 프로젝트의 스코프 규칙은 메시지의 일부가 아닙니다. 입력하는
자리에서 그렇게 알려주고, `scope:`를 담은 Extract 규칙은 저장되지 않습니다.

Probe와 Issues는 심각도 이름(`info`, `low`, `medium`/`med`, `high`, `critical`/`crit`)과 트리아지 상태(`open`, `confirmed`/`conf`, `false-positive`/`fp`, `resolved`/`done`, 그리고 open이 아닌 모든 상태를 뜻하는 `closed`)를 받습니다. 심각도는 비교를 지원하므로 `sev:>=high`도 동작합니다.

```text
sev:>=high -status:fp                 Issues: high와 critical, 오탐 제외
cat:cors sev:medium                   Probe: medium 등급 CORS 발견
host:api.example.com method:POST      Intercept: 한 호스트의 POST만 홀드
body:secret AND -host:cdn             컬러 규칙: 유출은 칠하고 CDN은 제외
```

Intercept 바와 컬러 규칙 바 모두 입력하는 동안 필드 이름과 알려진 값을 Tab으로 자동 완성합니다.

### 요청·응답 본문 문자열 매칭 {#matching-content}

`header:`와 `body:`는 메시지의 바이트를 뒤집니다. 따라서 어디서 동작하는지는 필터를 물어보는 그 시점에 **어떤 바이트가 존재하는가**로 정해집니다.

- **History, Sitemap, 컬러 규칙**은 이미 캡처된 플로를 봅니다. 그래서 두 필드 모두 요청·응답 양쪽에서 항상 동작합니다.
- **Intercept와 Extract 규칙 조건**은 흐르는 중인 메시지를 봅니다. `header:`는 모든 게이트에서 동작합니다. `body:`는 페이로드가 손에 있는 경우 — 홀드된 **WebSocket 메시지**와 **Extract 규칙** 조건 — 에서 동작하고, HTTP 홀드 게이트에서는 동작하지 않습니다. 그 게이트가 바로 본문을 버퍼링할지 말지를 결정하는 지점이기 때문입니다.

규칙을 쓰기 전에 알아둘, 의도된 차이가 하나 있습니다.

- **쿼리**에서 `body:`는 트라이그램 인덱스를 읽습니다. 빠르지만 각 방향 첫 8 KiB로 제한되고 바이너리·압축 본문은 건너뜁니다. `body~정규식`은 대신 저장된 바이트를 그대로 훑고 제한이 없습니다.
- **컬러 규칙**에서 `body:`는 항상 훑고, 각 방향 첫 64 KiB를 읽습니다. 인덱싱은 캡처 이후에 일어나는데 규칙은 방금 도착한 행을 칠해야 하니 훑는 것 말고는 정답이 없고, 64 KiB 한계는 큰 본문 한 화면이 목록을 멈춰 세우지 않게 하는 장치입니다. 그래서 컬러 규칙은 똑같은 쿼리가 목록에 못 띄우는 행도 칠하지만, 64 KiB를 넘어가는 매치는 칠하지 않습니다.

모든 화면의 `body:`는 **와이어에 흐른 그대로의 바이트**를 읽습니다. 그래서 어느 것도 gzip 본문 안의 문자열은 찾지 못합니다. Extract 규칙 조건도 마찬가지입니다 — 조건은 응답을 디코드하기 *전에* 평가되고, 압축 해제된 텍스트를 보는 것은 그 뒤에 이어지는 추출뿐입니다. 압축된 내용을 걸러야 한다면 그 바깥을 거세요: 헤더, 경로, 또는 응답 크기.

## 예제 {#examples}

```bash
# 한 호스트의 오류
gori run history -q 'host:api.example.com status:5xx'

# 토큰을 언급하는 느린 POST
gori run history -q 'method:POST dur:>1s body:token'

# 정적 자산을 제외한 admin 경로
gori run history -q 'path~/admin/ -path~\.(css|js|png)$'

# 패시브 스캔의 범위 지정
gori run probe -q 'host:example.com'
```
