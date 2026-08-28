+++
title = "스캐닝 & Issues"
description = "Probe 스캐너, Param Miner, 그리고 결과를 Issues로 트리아지하기."
weight = 30

[extra]
group = "핵심"
+++

gori에는 수동 테스트와 나란히 돌아가는 자동 분석 기능이 있습니다. **Probe**는 트래픽에서 이슈를 감시하고, **Param Miner**는 숨은 입력을 발견하며, **Issues**는 결과를 트리아지하는 곳입니다.

## Probe: 스캐너 {#probe-the-scanner}

**Probe**는 보안 이슈를 유형과 심각도로 묶습니다. 패시브 체크는 브라우징하는 동안 실행되며(추가 요청은 전혀 없이) **History** 플로우와 **Repeater** 전송 결과를 검사합니다.

**액티브** 체크는 의도적으로 *light-touch*로 설계되었습니다. 이미 캡처한 트래픽에 대해 안전하고 저용량인 프로브 몇 개를 보낼 뿐입니다. 기본적으로 안전한 메서드(`GET` / `HEAD`)만 프로브하고, 고유한 표면마다 한 번씩만 테스트하며, 액티브 모드를 활성화하기 전에는 아무것도 나가지 않습니다. 흔적을 최소로 남기면서 빠른 직감을 확인하도록(파라미터가 반사되는지, origin이 허용되는지) 만들어졌습니다.

안전하지 않은 메서드(`POST` / `PUT` / `PATCH` / `DELETE`)를 다시 보내면 서버 상태가 변경될 수 있으므로 항상 명시적으로 켜야 합니다. 플로우별 *Run active scan* 팝업에서 **unsafe methods**를 체크해 한 번만 의도적으로 재전송하거나, Probe를 **AGGRESSIVE** 모드로 전환하면 안전하지 않은 메서드도 자동으로 프로브하고 룰별 상한을 높입니다(더 넓은 파라미터 집합, 더 넓은 forbidden-bypass 헤더 집합). 두 경우 모두 프로젝트 스코프 안에서만 동작하므로 스코프를 벗어난 호스트는 절대 건드리지 않습니다.

<figure class="tui-shot">
  <img src="/images/tui/probe.svg" alt="심각도와 범주로 묶인 패시브 이슈를 나열하는 gori Probe 스캐너: 허용적 CORS, 누락된 CSP와 HSTS, 쿠키 플래그 문제, 캐시 가능한 응답, 각각 영향받는 호스트 표시">
  <figcaption><strong>Probe</strong>는 브라우징하는 동안 패시브 이슈(CORS, 쿠키 위생, 누락된 보안 헤더, 정보 노출)를 심각도와 범주로 묶어 드러냅니다.</figcaption>
</figure>

| 범주 | 다루는 내용 |
|----------|----------------|
| `headers` | 보안 헤더(HSTS, CSP·report-only-only, XFO, Permissions-Policy 등), 평문 Basic 인증, 혼합 콘텐츠, 캐시 가능한 API 응답, JWT 취약점(`alg:none`, 비표준 alg, `exp` 없음), `integrity` 없는 크로스 오리진 서브리소스 |
| `cookies` | `Secure` / `HttpOnly` / `SameSite` 및 관련 쿠키 위생 |
| `tech` | 기술 및 프로토콜 핑거프린트(Project 탭에도 표시) |
| `infoleak` | 본문 노출, URL / WS 프레임의 비밀 값, GraphQL introspection, 프로덕션 스크립트에 딸려 나간 소스맵, 디렉터리 리스팅, JWT 페이로드의 민감한 클레임 |
| `cors` | 와일드카드 / null origin / 자격 증명 관련 오설정; 액티브 origin 반사 |
| `client` | 페이지·번들 스크립트의 클라이언트 사이드 의심 지점: DOM 기반 XSS(소스가 싱크로 흐름), DOM 클로버링, 프로토타입 오염, postMessage 취약점. 휴리스틱이므로 확인이 필요한 단서로 다루세요 |
| `active` | light-touch 프로브로 확인됨: 반사되는 파라미터, backslash-powered 주입 지점, 오픈 리다이렉트, CRLF/응답 헤더·호스트 헤더 인젝션, 접근 제어 우회(위조된 클라이언트 IP / 경로 정규화 / URL-rewrite 헤더), NGINX alias·파라미터 경로 탐색, 서버 사이드 템플릿 인젝션(SSTI), Next.js 서버 액션 인가 누락(`Next-Action` 요청을 세션 쿠키/Authorization 제거 후 재전송 — 액션은 POST라 unsafe/AGGRESSIVE 필요). GraphQL introspection도 액티브로 확인됩니다(`infoleak`에 기록) |

심각도는 `info`, `low`, `medium`, `high`, `critical` 순입니다. 헤드리스 `gori run probe`는 기본적으로 **패시브** 체크를 실행하며, `--active` 플래그를 추가하면 액티브 체크도 함께 수행합니다.

탐지 결과는 체크와 호스트로 묶이므로 한 행이 수십 건의 히트를 대표할 수 있습니다. 행을 열면 **AFFECTED URLS** 목록이 그 근거입니다. `↑`/`↓`로 목록을 이동하고 `Enter`를 누르면 해당 URL이 캡처된 플로우가 History와 같은 상세 화면으로 열립니다. `o`는 그 탐지의 샘플 플로우를 열고, `r`은 Repeater로 보내며, `y`는 선택한 URL(선택이 없으면 전체)을 복사합니다.

분석은 헤드리스로도 실행할 수 있습니다. 기본값은 이미 캡처된 것(History + Repeater 응답)만 읽고 아무것도 보내지 않으며, `--active`를 주면 프로브 요청을 보냅니다.

```bash
gori run probe                       # passive issues
gori run probe --active              # include active checks (sends probe requests)
gori run probe --active --unsafe     # also re-send unsafe methods (may mutate server data)
gori run probe --active --aggressive # wider caps + unsafe methods (authorized targets only)
gori run probe --severity high       # only high-severity
gori run probe --category cors       # a single category
gori run probe -q 'host:example.com' # filter History with QL (Repeater still scanned)
```

## Param Miner {#param-miner}

**Miner**는 서버가 받아들이지만 드러내지 않는 파라미터를 발견합니다. 플로우를 지정하면 쿼리 문자열, 폼 본문, multipart/form-data, JSON(중첩 객체와 배열 루트 포함), 헤더, 쿠키 등 여러 위치에서 후보 이름을 프로브하고, 추측을 효율적으로 버킷으로 묶어 응답을 변화시키는 것들을 보고합니다. multipart도 대상이지만 기본은 꺼져 있습니다(캡처된 파일 파트가 요청마다 다시 전송되기 때문). `--locations multipart` 또는 해당 체크박스로 켜세요.

```bash
gori run mine <flow-id> \
  --locations query,headers \
  --wordlist params.txt \
  --bucket 50
```

마이닝은 CPU가 아니라 지연 시간에 묶여 있습니다. 버킷을 보내고 기다리고, 이분 탐색하고 또 기다리므로 비용의 대부분이 왕복 횟수입니다. 이를 줄이는 장치가 두 가지입니다. 프로브 사이에 연결을 재사용하고(프로브마다가 아니라 워커마다 TCP, https라면 TLS 핸드셰이크를 한 번씩만 치릅니다. 대상이 연결 단위로 동작한다면 **reuse connections** 체크박스나 `--no-keep-alive`, `keep_alive: false`로 끕니다), 모든 location을 하나의 워커 풀에서 함께 처리합니다. 그래서 location 세 개가 하나의 세 배가 되지 않고, 이분 탐색의 끝자락이 혼자 돌지도 않습니다.

> Miner 탭은 기본적으로 숨겨져 있습니다. 필요할 때 커맨드 팔레트(`Ctrl-P`)에서 활성화하세요.

## Discover: 스파이더 & 브루트포스 {#discover-spider-brute-force}

Miner가 숨은 입력값을 찾는다면, **Discover**는 숨은 엔드포인트를 찾습니다. 링크를 따라가며 사이트를 스파이더링하고(직접 눌러보지 않은 링크까지), 링크되지 않은 디렉터리와 경로(`/admin`, `.git/config`, `/api/v2`)를 브루트포스합니다. 새로 생긴 **Target** 탭 아래 Sitemap 옆의 서브탭으로 존재하며, 찾아낸 엔드포인트는 모두 그 Sitemap으로 바로 반영됩니다.

지금 있는 자리에서 바로 실행하세요. **Sitemap** 노드나 **History** 플로우에서 `Space`를 눌러 **Discover here**를 고르면 됩니다. 작은 팝업에서 탐색 방식(spider, bruteforce, 또는 기본값인 둘 다), 최대 깊이, 크롤 스코프, 동시성을 선택합니다. 실행은 백그라운드에서 진행됩니다. 하단 바에서 상태를 확인하고, Discover 서브탭에서 일시중지하거나 멈추며(`^X` 중지, `p` 일시중지), 완료 알림에서 결과로 바로 이동할 수 있습니다.

실행 결과는 URL 목록만 남지 않습니다. 각 발견 항목은 Discover가 보낸 요청과 서버가 돌려준 응답까지 함께 저장되므로, FINDINGS 표에서 `Enter`(또는 `o`)를 누르면 History와 동일한 상세 화면에서 그 교환을 그대로 볼 수 있습니다. 헤더, 본문, JSON 정렬 보기까지 같고, 거기서 `^R`로 Repeater에 바로 보낼 수도 있습니다. 헤드리스 실행과 MCP 실행도 같은 바이트를 저장하므로 `gori run show`나 `get_flow`로도 열립니다.

Discover는 실제 사이트에서 오탐/미탐을 낮추도록 설계했습니다:

- **대상이 스스로 밝힌 정보를 읽습니다.** 매 실행마다 origin의 알려진 문서를 가져옵니다. `robots.txt`, `sitemap.xml`, `sitemap_index.xml`에 더해 `.well-known/` 레지스트리(`openid-configuration`, `oauth-authorization-server`, `oauth-protected-resource`, `security.txt`, `apple-app-site-association`, `assetlinks.json`, `host-meta`, `change-password`)까지 읽고, 거기에 선언된 엔드포인트를 크롤합니다. OIDC 디스커버리 문서 하나만으로도 authorize, token, userinfo, JWKS, revocation, registration 엔드포인트가 통째로 나옵니다. 이들은 고정 경로에 대한 추측이므로, 워드리스트 히트와 똑같이 soft-404 기준선을 통과해야 인정됩니다.
- **JavaScript를 읽습니다.** 스파이더는 `<script src>`도 다른 링크처럼 따라가는데, 이제 받아온 번들을 파싱합니다. 따옴표로 감싼 루트 상대 경로와 절대 URL이 크롤 대상이 됩니다. SPA에서는 API 라우트가 JS에서만 도달 가능하고 구조상 링크되지 않으므로, 예전에는 스파이더와 브루트포서 양쪽 모두가 통째로 놓치던 표면입니다. 같은 패스가 인라인 `<script>` 블록, JSON 응답, 소스맵에도 적용됩니다.
- **Soft-404 캘리브레이션.** 디렉터리를 브루트포스하기 전에, 존재하지 않는 경로 몇 개를 보내 그 서버가 "없음"에 어떻게 응답하는지 학습합니다. 진짜 `404`에 커스텀 에러 페이지를 주는 서버, 모든 경로에 `200`을 주는 서버, 요청한 경로를 에러 페이지에 그대로 되비추는 서버, 모든 미지의 경로를 `/login`으로 리다이렉트하는 서버를 모두 다루므로, 워드리스트 히트는 그 기준선과 실제로 달라질 때만 인정됩니다. 네 경우 모두 같은 워드리스트에도 다르게 반응하기 때문에, 어느 쪽이었는지도 함께 알려줍니다(`wildcard-200 (echoes path)` 같은 식으로).
- **대상이 태도를 바꾸면 기준선을 다시 잽니다.** 기준선은 디렉터리당 한 번만 측정하는데, 스윕 도중에 rate limiter가 걸리거나 WAF 차단 페이지가 나오거나 서버가 `5xx`로 주저앉으면 남은 프로브가 전부 "발견"처럼 보입니다. 자동 스윕이 똑같은 차단 페이지를 수백 개의 확신에 찬 결과로 쏟아내는 전형적인 경로입니다. Discover는 기준선을 통과하면서 *서로 똑같기까지 한* 응답이 연달아 나오는지 지켜보다가, 그 결과들을 내보내지 않고 붙들어 둔 뒤 해당 디렉터리를 다시 측정합니다. 버린 개수는 실행 요약에 `drift`로 보고하므로, 측정되지 못한 디렉터리가 비어 있던 디렉터리처럼 읽히지 않습니다.
- **폭주하지 않는 크롤.** 두 개의 독립적인 가드가 크롤 폭발을 막습니다. URL 형태 접기가 `/user/1`, `/user/2`, `/user/3`…을 하나의 템플릿으로 모으고, 콘텐츠 지문이 거의 동일한 목록 페이지를 하나의 클러스터로 모읍니다. 깊이 제한, 페이지 제한, 하드 요청 예산이 나머지를 묶어줍니다.
- **기본은 Scope 연동.** 실행은 Scope include 규칙을 설정하지 않은 한 시드 origin에 머물고, 설정했다면 그 규칙을 따릅니다. Scope exclude와 sandbox는 항상 존중됩니다. 호스트가 아닌 경로에서 실행하면 그 하위로 범위를 좁힙니다.
- **연결 재사용.** 브루트포스는 디렉터리마다 워드리스트 항목 수만큼 요청을 보내는데, 예전에는 그 하나하나가 자기 TCP 핸드셰이크(https라면 TLS까지)를 치렀습니다. 이제 origin별로 keep-alive 연결을 유지하므로 워커마다 한 번만 치릅니다. 대상이 연결 단위로 동작한다면(연결 범위 rate limit, 연결로 고정하는 로드 밸런서) **reuse connections** 체크박스, `--no-keep-alive`, `keep_alive: false`로 끕니다.

각 실행은 FP/FN 수치를 보고합니다. 캘리브레이터가 억제한 프로브 수, 트랩 가드가 잘라낸 탐색량, 그리고 남긴 결과의 신뢰도 분포입니다.

헤드리스로는 `gori run discover`이며, MCP로 에이전트에도 노출됩니다(`discover_start` / `discover_status` / `discover_results` / `discover_stop`):

```bash
gori run discover --target https://target.example \
  --max-depth 3 \
  --extensions php,json,bak \
  --format jsonl
```

Discover는 대상에 실제 요청을 보냅니다. 테스트 권한이 있는 시스템에만 실행하세요.

> Sitemap에서 `Space`는 **Send to Repeater**도 제공합니다. 선택한 엔드포인트의 캡처된 요청을 Repeater 워크벤치에서 엽니다.

## Issues {#issues}

**Issues**는 트리아지 목록입니다. 추적할 가치가 있는 것이라면 무엇이든(Probe, Fuzzer, Miner, 또는 직접 검사한 결과에서) 심각도와 상태를 붙여 이슈로 승격하고, 증거 플로우로 바로 되돌아갈 수 있습니다. 이슈는 리포트용으로 익스포트할 수 있습니다.

```bash
gori run issues --format markdown --export report.md
gori run issues --format sarif --export issues.sarif   # GitHub code scanning / CI 대시보드용
```

TUI에서는 `⇧E`가 형식을 먼저, 저장 경로를 그 다음에 묻습니다. SARIF result가 무엇을 담는지는 [리포트 내보내기](/ko/playbooks/triage-and-report/#5-export-the-report)를 참고하세요.

### 이슈 표시하기 (다중 선택) {#marking-issues-multi-select}

History와 같은 방식으로 표시합니다. `t`를 누르면 커서의 이슈를 **표시(mark)**하고 아래로 한 칸 이동하므로, `t`를 연달아 누르면 연속된 행이 표시됩니다. `Shift-↑` / `Shift-↓`는 시작점에서 연속 범위를 확장하고, `Shift-T`는 현재 필터가 보여주는 전부를 표시하며, `Esc`는 표시를 모두 해제합니다. 표시된 행은 거터 막대가 굵어지고, 필터 줄에 `3 marked` 카운트가 실시간으로 표시됩니다.

`Shift`에서 손을 떼면 범위 선택이 끝납니다. 그냥 `↑` / `↓`(또는 `PgUp` / `PgDn`, 다른 행 클릭)를 누르면 GUI 목록이 하이라이트를 접듯 범위를 되돌려 줍니다. `t`나 `Shift-T`로 직접 찍은 표시는 남으므로, 떨어진 항목들을 골라 담는 것도 가능합니다. 마우스 휠은 스크롤만 하므로 표시를 지우지 않습니다.

표시는 **space 메뉴가 무엇에 작용하는지**를 바꿀 뿐, 동작 목록 자체를 바꾸지 않습니다.

> 실제 대상은 **표시가 있으면 표시된 항목 전부, 없으면 커서 행**입니다.

그래서 `/ status:open severity:low` → `Shift-T` → `Space` → `c` → **False positive**로 한 번에 전체를 재분류할 수 있습니다. 메뉴 제목은 `SPACE · 3 MARKED`로 바뀌고 항목 이름도 함께 바뀌므로(`Delete 3 issues`), 일괄 작업이 예상 밖으로 일어나지 않습니다.

| 동작 | 키 | 표시된 항목에 대해 |
|--------|-----|-----------|
| 심각도 설정 | `Space` `s` | 한 번 고르면 표시된 모든 이슈에 기록 |
| 상태 설정 | `Space` `c` | 한 번 고르면 끝 — false positive / resolved 일괄 처리 |
| 삭제 | `Space` `d` | 전체 집합에 확인 창 하나 |

표시는 필터 변경, 재정렬(직접 바꾼 심각도로 인한 재정렬 포함), 탭을 떠났다 돌아오는 동안에도 유지됩니다. 카운트 칩이 지금 화면 밖에 몇 개가 있는지 알려줍니다. 이슈를 열면 동작은 그 이슈 하나에 고정됩니다 — 표시는 목록 차원의 개념입니다. 익스포트는 항상 **전체** 리포트를 쓰므로, 표시가 있을 때 메뉴 항목에 `(all)`이 붙습니다.

## Notes & Comparer {#notes-comparer}

분석을 거드는 도구가 두 가지 더 있습니다.

- **Notes**: 자유 형식의 프로젝트별 마크다운 문서(프로젝트당 여러 노트). Notes 탭에서 노트를 생성, 편집, 닫을 수 있고, `gori run notes` / `gori run notes --all`로 헤드리스에서 목록을 보거나 덤프할 수 있습니다. 에이전트는 MCP(`list_notes`, `get_note`, `create_note`, …)로 노트를 관리할 수 있습니다.
- **Comparer**: 두 메시지를 슬롯 A와 B에 불러와 나란히 diff합니다. 요청 간 응답이 어떻게 바뀌었는지 파악하는 데 유용합니다.

  슬롯은 요청과 응답을 쥔 곳이면 어디서든 채울 수 있습니다. History, Sitemap, Repeater 탭(마지막 전송), Fuzzer 결과 행에서 `Space` → **Send to Comparer**, 또는 Comparer 탭에서 `a` / `b`로 캡처된 플로우를 직접 고르면 됩니다. 이 피커는 History·Sitemap과 마찬가지로 활성 Scope 렌즈를 따르므로, 스코프 밖 플로우를 고르려면 렌즈를 꺼야 합니다. Repeater 전송과 퍼즈 결과는 캡처를 남기지 않으므로, 그 둘이 diff로 들어올 수 있는 경로는 이것뿐입니다.

  각 열 헤더에 그쪽의 `status · size · time`이 붙고, 가운데 구분선에 A→B 델타가 표시됩니다. `403 → 200` 하나가 본문을 읽기 전에 답인 경우가 대부분입니다.

  diff 안에서 쓰는 키:

  | 키 | 동작 |
  |-----|--------|
  | `←` / `→` | 요청끼리 / 응답끼리 비교 전환 |
  | `n` / `⇧N` | 다음 / 이전 **변경** 행으로 점프 (순환하며, 푸터에 `3/8` 표시) |
  | `f` | 동일 구간을 `⋯ N unchanged lines ⋯`로 접기 (변경 지점 주변 3줄은 유지) |
  | `↑` / `↓`, `⇧↑` / `⇧↓` | 행 커서 이동 · 행 단위 선택 확장 |
  | `y` | 선택 영역 — 없으면 diff 전체 — 을 unified 텍스트로 복사 |
  | `⇧←` / `⇧→` | 두 열을 함께 가로 스크롤 |
  | `s` | A ⇄ B 교환 |

  변경된 행에서는 실제로 다른 부분만 빨강/초록으로 강조되고 양쪽이 공유하는 부분은 흐리게 표시됩니다. 재서명된 토큰이나 JSON 값 하나가 바뀐 경우를 줄 전체를 읽지 않고도 찾을 수 있습니다.

## Diff: 지난번 대비 뭐가 바뀌었나 {#diff-retest}

Comparer는 **메시지 두 개**를 비교합니다. 리테스트는 같은 질문을 한 단계 위에서 던집니다 — *지난 엔게이지먼트 이후 뭐가 바뀌었나* — 그리고 그게 **Target** 아래 **Diff** 서브탭입니다. 폴딩을 그대로 빌려 쓰는 Sitemap 바로 옆에 있습니다.

슬롯에는 플로우가 아니라 **프로젝트**가 들어갑니다. `a`로 기준(이전 엔게이지먼트)을 고르고, `b`는 지금 열어 둔 프로젝트가 기본값이며, `s`로 교환하고 `r`로 다시 읽습니다. 아무것도 보내지 않습니다 — 양쪽 모두 캡처된 트래픽입니다. 행은 엔드포인트이고, `↵`(또는 `o`)를 누르면 선택한 엔드포인트의 **양쪽** 캡처가 Comparer로 넘어가 바이트 단위 답을 보여줍니다.

**엔드포인트 동일성 판정이 전부입니다.** 엔게이지먼트 두 번이 같은 식별자를 캡처하는 일은 없으므로, 리터럴 경로로 키를 잡으면 모든 행이 removed 한 번 added 한 번으로 두 번 보고되고 아무 말도 하지 못합니다. 그래서 Sitemap이 그리는 폴딩 템플릿을 그대로 키로 씁니다 — `/users/{uuid}`, `/items/{n}`, 쿼리 변형이 접힌 `/search`. 폴딩은 양쪽의 합집합에 대해 한 번만 돌기 때문에, 한쪽에서만 임계치를 넘긴 라우트도 반대쪽과 매칭됩니다.

판정은 다섯 가지이고, 마지막 두 개의 구분이 핵심입니다:

| 판정 | 의미 |
|------|------|
| `added` | B에는 캡처됐고 A에는 없음 |
| `gone` | 양쪽 모두 캡처됨 — 그런데 A는 도달 가능했던 반면 B가 받은 응답은 전부 `404`/`410` |
| `changed` | 양쪽 모두 캡처됨. 상태 클래스, 인증, content type, 크기 중 하나가 허용 범위를 넘어 움직임 |
| `same` | 양쪽 모두 캡처됐고 동등함 |
| `not seen` | A에는 있는데 B는 그 엔드포인트로 **요청을 아예 안 함** — 커버리지 공백이지 삭제의 근거가 아님 |

리테스트가 얕으면 방문한 엔드포인트도 적어집니다. "안 가봤다"를 "사라졌다"로 뭉뚱그리면 짧은 오후 작업이 대규모 수정처럼 보고되므로, 둘은 서로 다른 판정이고 그 단서는 스크롤로 사라지지 않는 헤더에 붙어 있습니다. 양쪽의 플로우·엔드포인트·호스트 수가 숫자 옆에 함께 나오는 것도 같은 이유입니다.

`changed` 판정은 바이트 동일성이 아니라 허용 밴드로 내립니다 — Repeater의 minimize와 Miner가 쓰는 바로 그 캘리브레이션입니다. 그래서 캡처 사이에 길이가 흔들리는 페이지는 변화 없음으로 읽힙니다. 상태 코드는 **클래스**로 비교하므로 `200` → `201`은 발견이 아니고 `200` → `403`은 발견이며, 후자는 별도의 `auth` 축으로 보고됩니다.

`v`는 판정 렌즈를 순환시킵니다. 렌즈가 무엇을 보여주든 개수는 항상 다섯 판정 전부를 덮습니다. 헤드리스로는 [`gori run diff`](/ko/reference/cli/#run-diff)이고 — `--format md`면 산출물에 그대로 붙여 넣을 섹션이 나옵니다 — MCP로는 `diff_projects`입니다.

**행은 탭 밖으로 나가라고 있는 것입니다.** 리테스트의 산출물은 발견 목록이고 이 탭은 그 입력을 만드는 곳이므로, `⇧F`는 선택한 엔드포인트를 **Issue**로 기록하고 `n`은 **Note**로 기록합니다 — 같은 텍스트, 한쪽은 폼 없이, 둘 다 목록에서 커서를 옮기지 않습니다. 양쪽 모두 이 탭만 아는 것을 싣습니다: 어느 두 프로젝트를 비교했고 그 DB가 어디인지, 양쪽이 실제로 무엇으로 답했는지, 어느 축이 움직였는지. 열려 있는 프로젝트 쪽 캡처는 복사가 아니라 증거로 **링크**되고, 반대쪽 플로우는 자기 DB 경로와 함께 이름으로 남습니다 — `entity_links`는 프로젝트 경계를 넘지 못하기 때문입니다. `not seen` 행은 `info`로 열리고, 새 캡처가 그 엔드포인트에 요청을 보낸 적이 없다는 사실을 자기 문장으로 적습니다. 관측하지 않은 삭제를 주장하지 않습니다. 같은 문장이 `--format json`의 모든 행에도 실리므로, 행마다 이슈를 만드는 에이전트도 이 구분을 잃지 않습니다.

이슈, 노트, 리피터, 퍼즈/마이너 세션은 서로 링크할 수 있어, 이슈에서 증거 플로우나 그것을 만든 세션으로 바로 점프할 수 있습니다. 이슈는 선택적으로 CVSS 벡터나 점수를 기록할 수 있고, Severity는 거기서 따라옵니다 — 목록에도, `cvss:>=7` 필터에도, 모든 리포트에도 반영됩니다. 이슈에서 `Space` → **Set CVSS**(또는 이슈 폼의 `cvss` 행에서 `↵`)를 누르면 계산기가 열립니다. `vector:` 행에 벡터를 직접 입력하거나 붙여넣어도 되고 `8.8` 같은 점수만 적어도 되며, 아래 기본 메트릭을 `←/→`로 골라 만들어도 됩니다. 양쪽은 서로 맞춰 갱신됩니다. `version:` 행에서 **3.1**과 **4.0**을 고를 수 있고, 두 버전은 각자의 선택을 따로 기억합니다 — v4.0은 Attack Requirements가 추가되고 영향이 Vulnerable/Subsequent 시스템으로 갈리는, 서로 변환되지 않는 다른 평가이기 때문입니다. 붙여넣은 벡터는 자기 버전으로 열리며, 파서가 아는 버전이면(v2 포함) 빌더가 3.1·4.0만 쓰더라도 입력한 그대로 저장·채점됩니다. History, Repeater, Fuzzer, Miner 어디서든 `Space` → **Link…** 를 누르면 프로젝트의 모든 이슈와 노트가 한 카드에 뜨고, 그 위에 `+ New issue…` / `+ New note…`가 고정되어 있습니다. 즉 지금 보고 있는 것에 대해 새 이슈를 만들면서 바로 연결하는 일이, 기존 이슈에 붙이는 것과 똑같은 키 수로 끝납니다. 제목·호스트·상태는 물론 `issue` / `note` 라는 단어로도 필터할 수 있고, 필터에 입력한 문자열은 생성 행을 고를 때 새 이슈의 제목으로 그대로 들어갑니다.

## 다음 단계 {#next-steps}

- [MCP Server](/ko/guide/mcp/): 에이전트가 스캔을 실행하고 이슈를 읽게 합니다
- [CLI Reference](/ko/reference/cli/): `probe`, `mine`, `issues`, `notes` 플래그
- [Query Language](/ko/reference/query-language/): 스캔 범위를 좁힙니다
