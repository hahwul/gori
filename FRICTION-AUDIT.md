# gori 운영 마찰(friction) 인벤토리 — HTTP 전송 · TUI 구간

기준: gori 0.2.0 (`30f8856`) · 비교 대상: Burp Suite / Caido
방법: 8개 축으로 소스 감사 → 각 주장마다 반증 전용 검증 에이전트 1회 → 중복 제거.
원시 50건 중 35 CONFIRMED · 15 PARTIAL(주장은 성립하되 범위 축소). 여기에 빌드한 바이너리로
직접 재현한 5건을 더했다.

**이 문서가 다루는 것은 버그가 아니라 마찰이다.** 기준은 "Burp에서는 키 하나인데 gori에서는 몇
단계인가", "했다고 말해놓고 안 한 게 무엇인가"다. 정확성 결함이라도 조작 비용으로 환산되지 않으면
검증 단계에서 걸러냈다.

DESIGN.md §7에 기록된 결정(P7 operator bytes 무가공, Verb 레지스트리는 TUI 전용, rule-less scope는
absent scope가 아님)은 마찰로 세지 않았다.

> **상태:** 아래 항목 중 **Z1 · Z2 · T2 · H6 · X2 · X3 · O1** 7건은 수정되어 머지됨
> (테마 T-B "하지 않은 일을 했다고 보고한다" + T-C "어느 게이트가 거부했는지 알 수 없다" 일괄).
> 각 항목 제목 옆의 `[FIXED]` 표시를 참고. 나머지는 미착수이며 §2의 우선순위 표가 그대로 로드맵이다.

---

## 1. 횡단 테마 6가지

### T-A. "seam은 이미 있는데 아무도 안 연결했다" — 가장 큰 부류
어려운 절반이 이미 작성되어 있고 **다른 호출자에서 프로덕션으로 돌아가는 중**인데, 정작 필요한
곳에서 호출하지 않는다. `Store#search`의 `before_id`(MCP만 사용), `flags_for`(선언된 seam, 스텁),
`representative_flow_id`(Sitemap→Repeater는 사용), `insert_fuzz_run`/`insert_fuzz_result`(스키마·
컴팩션 정책까지 있는데 **호출자 0개**), `detail_request_bytes` + public `repeater_from_request`,
`Matcher#extract`(config_json으로 왕복하는데 setter 없음), `PlanOptions#processors`(세 서피스 공용
이라고 문서화됐는데 TUI만 빈 배열), `Session.open` 안의 `store.setting` 6줄.
→ 설계 공백이 아니라 배선 작업. 해당: H1, H3, H4, R3, Z3, Z4, Z6, Z7, X1, R1

### T-B. "하지 않은 일을 했다고 보고한다" — 메인테이너가 이미 3번 고친 클래스
`0d59c8a`("three write tools that reported success for work they did not do"), `a0a5bd3`,
`#488/#489`가 같은 클래스다. 아직 남은 인스턴스: 드롭된 QL 항이 필터를 **넓히는데** 바에는 그대로
표시(H2), Tab이 절대 매치 못 하는 `flag:`를 제안(H6), `^A`가 거부하고 "auto-marked 1 position"
토스트(Z1), `y`가 64 KiB에서 자르고 잘린 크기를 복사 크기로 출력(T2), 3200건 전량 거부 후
"no hidden parameters found" + exit 0(X2), Sandbox 켜진 채 마지막 include 삭제하면 "removed scope
rule" 토스트 + 프록시 블랙홀(O1), retention이 조용히 삭제하고 `~/.gori/gori.log`에만 기록(O3).

### T-C. "어느 게이트가 거부했는지 알 수 없다"
`Outbound#sweep_block`이 sandbox와 exclude를 하나의 `"blocked by scope"`로 뭉갠다 — Layer 1을
방금 `--allow-unscoped`로 면제한 조작자가 **같은 문구**를 다시 본다. 반면 `send_block`은
`SANDBOX_ERROR = "blocked by sandbox (out of scope)"`로 구분하고, Layer 1 중단은
`cli/run.cr:356`에서 게이트와 탈출구를 둘 다 말한다 — 모델은 이미 사내에 있다.
해당: X3, Z2, X2, O1, P2, P3

### T-D. "CLI ≠ TUI ≠ MCP"
Plan 빌더 작업(#356, #366, #373–#377)이 **조립**은 통일했지만 **각 서피스가 무엇을 보관하고
보고하는가**는 통일하지 않았다. CLI는 `r.error`를 찍고 TUI는 안 찍음(Z2), `--extract`/`extract`는
CLI·MCP만(Z6), processor 파이프라인도 CLI·MCP만(Z7), `keep_bodies`는 CLI에서 `:none` 하드코딩(Z8),
프로젝트별 upstream/timeout은 TUI와 `run capture`만 로드(X1), MCP `send_request`만 History에 기록
(X4), `gori run repeater send`에는 재타겟 플래그가 없음(R7).

### T-E. "도구 밖으로 못 꺼내는 바이트"
gori는 저장소까지 byte-exact(P7)인데 **마지막 15cm** — 화면→클립보드, 화면→diff, 스윕→디스크 —
에서 바이트를 잃거나, 조용히 잃는다. 드래그 선택 불가 + 마우스 기본 on이 터미널 자체 선택을
뺏음(T1), 키보드 대안은 64 KiB에서 잘리고 오보(T2), `^F`가 **라인** 단위라 minified 본문은 히트
1개이고 커서는 0열(T4), Comparer는 캡처 플로우만 받고 라인 단위 diff만(R3), CLI는 응답을 버림(Z8).

### T-F. "작은 케이스에서만 동작하는 어포던스"
전부 소규모에서는 되는데 다음 단계가 없다. 1000건 + 커서 없음(H1), 정렬 없음이라 길이 이상치는
언제나 페이징 없는 5000행 맨 아래(H5, Z5), 100자 넘는 붙여넣기는 붙이기 전 버퍼를 undo 스택에서
밀어냄(T3), 80열 터미널에서 50/50 고정 분할(R6), `^F`는 Repeater에서 되니 반사가 생기는데 다른
5개 탭에서는 조용히 죽음(T5), 세션 중 닿을 수 있는 디스크 레버는 0바이트를 회수(O4).

---

## 2. 우선순위 수정 목록

크기: **S** = 몇 줄, **M** = 파일 하나, **L** = 새 seam/뷰.
"정직하게 말하기(S)"와 "기능 만들기(L)"가 붙어 있는 항목은 반으로 갈라 각각 배치했다 — 이 저장소가
역사적으로 실제 출하해 온 방식이기도 하다.

| 순위 | 항목 | 크기 | 조치 |
|---|---|---|---|
| 1 | Z2 | S | Fuzzer 결과 행에 `r.error` 렌더; `detail_response_lines`가 retention 문구보다 error를 먼저 분기 |
| 2 | X3 | S | `sweep_block`이 sandbox/exclude를 구분된 문자열로 반환; `--allow-unscoped` 도움말 3곳을 repeater 쪽 문구에 맞춤 |
| 3 | O1 | S | scope 룰 write 후 `sandbox? && include_count == 0`이면 기존 `toast_sandbox_state` 줄을 붙임 (CLI stderr·MCP `blocks_all`도 동일) |
| 4 | Z1 | S | `auto_mark`를 멱등으로(clear→derive), 아니면 전후 diff 후 `mark_word`처럼 정직하게 거부 |
| 5 | T2-a | S | 잘림 보고를 `Clipboard`로 올려 5개 경로의 누락을 구조적으로 제거 |
| 6 | H6 | S | `QL_FIELDS`에서 `flag` 제거, `url` 추가, `field_cond`와 spec으로 고정 |
| 7 | X1 | S | `Session.open`의 `store.setting` 6줄을 `Settings.load_project_network(store)`로 승격해 `CLI::Run.open_store`·MCP bind에서도 호출 |
| 8 | Z4 | S | `fuzz.repeater` verb 등록 — `runner/miner.cr:54`의 3줄 복사 |
| 9 | H4 | S | `sitemap.open-flow` 등록 — `representative_flow_id` → `open_detail_id` (`runner/issues.cr:163`과 동형) |
| 10 | X2 | S/M | Miner·Sequencer에 Discover의 `NOTHING_TO_SEND` 백스톱 부여, 첫 에러 문자열 운반 → 기존 `had_error`로 exit 1 |
| 11 | H2 | M | `query_note_for`에서 기존 `QL.analyze` 호출, "ignored: …"를 **필터 바**에 렌더(빈 결과 화면만으로는 부족 — 넓어진 쿼리는 비지 않는다) |
| 12 | H1-a | S | 카운트 칩을 필터 중일 때만이 아니라 항상 렌더(`1000+` 형식은 이미 의도적으로 존재) |
| 13 | H5-a | S | 컬럼 라벨을 `RESP`로 바꾸거나 합계로 통일 + `respsize:`/`reqsize:`를 `FILTER_HINT`에 노출 |
| 14 | Z5 | S/M | Fuzzer·Miner·Sequencer에 `body_scroll` 구현(`history_controller.cr:159` 복사) + `cycle_sort`에 방향 플래그 |
| 15 | O5 | S | `browser.open`에 코드 부여 + 트래픽 생긴 뒤에도 남는 진입점(listen 칩 메뉴) |
| 16 | O3 | S/M | `write_failures` 옆에 `retention_dropped : Atomic`; Runner의 기존 폴링이 알림으로 전환 |
| 17 | T5-a | S | `goto_target`이 nil이면 키를 삼키지 말고 "find is not available in this pane" 토스트 |
| 18 | O4-a | S | `history_clear`가 디스크 크기를 보고하고 compaction을 회수 단계로 명시 |
| 19 | X4-a | S | `gori run repeater`에 `--record` 추가(MCP `record_outbound_request` 재사용) |
| 20 | Z8 | M | `--record=none\|matched\|all`을 `Matcher`+`Config`에 배선, `fuzz_row_fields`에 head/body/request 노출 |
| 21 | Z6 | M | `FuzzAdvancedOverlay`에 `extract`·`m_lines`·`f_lines` 행 + `r.extracted` 컬럼 |
| 22 | Z3-a | S | 5000행 링과 별개로 실제 `sent`/`hit` 카운터 유지 — 테두리·알림·이벤트 피드가 링 크기를 기록하지 않도록 |
| 23 | Z7 | M | Fuzzer CONFIG에 처리 파이프라인 행 → `fuzzer_view.cr:941`에서 `processors:`로 전달 |
| 24 | T3-a | M | 연속 `insert`를 하나의 undo 단위로 합침 — 같은 클래스의 `insert_string`이 이미 패턴 |
| 25 | O2 | M | `gori run project config export\|import` — 4개 테이블 1문서 |
| 26 | T5-b | M | Comparer/Fuzzer/Issues/Decoder/JWT에 `goto_symbol` 오버라이드 + `runner.cr`의 5개 `case @search_target` |
| 27 | R6 | M/L | 분할 비율 영속화 + 방향 플래그 (`half` 계산 지점) |
| 28 | H1-b | M | 마지막 행에서 `before_id` 기반 load-older |
| 29 | T4 | L | 히트를 `{line, col}`로 — 스텝이 occurrence 단위가 되고 캐럿이 매치에 안착, regex/대소문자 토글은 파생 |
| 30 | T1 | L | termisu 포크에서 mode 1002 활성 + motion/release 드롭 중단 (선행 S: press에서 `ev.shift?`를 읽어 anchor 확장) |
| 31 | Z3-b | L | 기존 `fuzz_runs`/`fuzz_results` writer를 컨트롤러에 배선하고 `restore`에서 로드 |
| 32 | H3 | L | `flags_for` seam 뒤에 `flow_annotations` + 행 색/코멘트 컬럼 + QL `colour:`/`comment:` |
| 33 | O4-b | L | capture 정지 → 락 획득 → VACUUM → 재개하는 `project.compact` verb |
| 34 | T3-b | L | 포크에 bracketed paste(붙여넣은 Tab도 해결) + redo 스택 |
| 35 | H5-b | L | `Store#search`를 관통하는 `ORDER BY` 선택 + 헤더/키 정렬 사이클 |
| 36 | R3 | L | 바이트를 담는 Comparer 슬롯 + Repeater/Fuzzer 송신 verb + `Changed` 행 단어 단위 diff |

**정직한 총평:** 상위 19행은 대체로 기계적이고 spec 가능한 작업 일주일치이며, *기만*의 대부분을
제거한다. 하위 1/3은 진짜 새 표면(스토어 테이블, 업스트림 터미널 변경, ORDER BY seam)이고 어떤
정렬로도 싸지지 않는다.

---

## 3. 첫 1시간에 걸리는 세 가지

용량 관련 항목(H1, Z3, Z8)은 트래픽이 쌓인 뒤에야 보이므로 이 자리에서 제외했다.

- **T2 — `y`가 64 KiB를 복사하고 성공이라 말한다.** 응답 본문을 밖으로 꺼내는 건 1분차 제스처인데,
  조작자가 받는 단 하나의 숫자로는 온전한 복사 / 잘린 복사 / 클립보드가 꺼져 있음을 구분할 수 없다.
- **T1 — 마우스 드래그가 아무것도 선택하지 않는데 마우스는 기본 on이다.** 텍스트를 보면 드래그가
  첫 본능인데, gori는 캐럿을 옮기고 anchor를 지우며 답한다 — 터미널 자체 선택은 이미 빼앗은 상태로.
- **T3 — 요청을 붙여넣으면 붙이기 전 상태가 사라지고 `^Z`로 되돌릴 수 없다.** Repeater에 요청을
  붙여넣는 건 이 도구의 정석 첫 수인데, 현실적인 크기의 요청이면 100칸 undo 스택에서 붙이기 전
  버퍼가 밀려난다.

차점: **R6** — 80열 터미널의 하드코딩 50/50 분할은 `Authorization` 헤더가 화면에 뜨는 순간 체감된다.

---

## 4. 전체 인벤토리

`[상태/등급]` — CONFIRMED는 인용이 전부 검증됨, PARTIAL은 메커니즘은 실재하나 범위가 축소됨.

### 4.1 프록시 · 인터셉트

**P1. 이미 열린 h2 커넥션에는 인터셉트/Sandbox/M&R 토글이 먹지 않는다** `[CONFIRMED/high]`
`proxy/tls/tunnel.cr:189`의 `h2_candidate?`가 `sandbox_enabled?`·`intercepts_host?`·`rewriter.active?`
를 읽는 **유일한** 지점이고, 이건 `tunnel.cr:98`에서 CONNECT당 한 번, 클라이언트 핸드셰이크 **전에**
실행된다. `proxy/h2/relay.cr:19`의 Relay 생성자는 interceptor/rewriter/scope를 아예 받지 않고,
`proxy/server.cr:44`에는 커넥션 레지스트리가 없어 토글 시 살아 있는 h2 터널을 회수할 방법이 없다.
`intercept_controller.cr:316`의 토스트는 "intercept ON — held traffic waits"라고만 하고 이게 **새
커넥션에만** 적용된다는 힌트가 없다.
· 지금 비용: 인터셉트를 켜도 브라우저가 이미 h2로 붙어 있으면 아무 일도 안 일어난다. 원인을 모르는
채 브라우저를 껐다 켜야 한다는 걸 알아내야 한다.
· Burp: Intercept 토글은 즉시 유효하고, HTTP/2는 프록시가 항상 프레임 단위로 소유한다.
· 수정: HEADERS 프레임 전달 전에 `h2_candidate?(host)`를 재질의해 false면 GOAWAY로 h1 재협상 유도.
최소한 토글 토스트에 "applies to new connections" 명시.

**P2. HTTPS 경로의 Sandbox 거부는 gori 어디에도 흔적을 남기지 않는다** `[PARTIAL/high]`
`proxy/conn/client_conn.cr:1015`의 CONNECT 게이트는 `write_sandbox_block` 후 반환할 뿐
`record_blocked_request`를 부르지 않는다 — 평문 경로(`client_conn.cr:241`)는 부르고, Aborted 플로우에
`Outbound::SANDBOX_ERROR`를 실어 남긴다. 투명 리스너(`proxy/server.cr:220`)는 그냥 `close_client`.
두 줄 위 `server.cr:210`은 SNI 누락을 로깅하며 그 이유를 "a client that mysteriously fails otherwise
leaves no trace anywhere"라고 적어 뒀다 — 원칙은 이미 서술돼 있고 더 흔한 케이스에 적용만 안 됐다.
· 범위 축소: 요청 단위 sandbox 차단(터널 내부 HTTPS 포함)은 Aborted 플로우를 남긴다. 흔적이 없는 건
**요청이 존재하기 전 호스트 레벨에서 거부되는** CONNECT 게이트와 투명 리스너 SNI 게이트뿐.
· 수정: `FlowSink`에 `on_refused(host, port, reason)` 채널 하나 추가, 두 드롭 지점에서 호출.

**P3. 프록시 거부가 본문 없는 502로 브라우저에 도달해 진단이 화면에 닿지 않는다** `[CONFIRMED/medium]`
`client_conn.cr:1346` `write_gateway_error`는 `HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n`.
정작 필요한 문장은 `client_conn.cr:1093`에 이미 만들어져 있다 — "upstream TLS verification failed:
host:port — origin certificate not trusted; retry with --insecure-upstream or set SSL_CERT_FILE".
그게 `record_error`(History 전용)로만 가고 브라우저는 못 받는다. `write_sandbox_block`도 본문 없이
`X-Gori-Sandbox: blocked` 헤더뿐 — 어떤 브라우저도 안 보여준다. `proxy/conn/self_page.cr`이 이미
브랜디드 HTML을 raw 소켓에 렌더하므로 기계는 있다.
· Burp: 프록시 오류를 브라우저 탭에 설명 페이지로 렌더한다.

**P4. 인터셉트 catch 조건에 확장자/MIME 필드가 없고, 요청·응답이 조건 하나를 공유한다** `[CONFIRMED/medium]`
`intercept_filter.cr:65` `FIELDS = %w(host path method scheme status)`. `:path`는 단순 부분 문자열
(`:47`)이라 `-path:.js` 우회는 `.json`까지 죽인다. `interceptor.cr:206`/`:215`가 **같은** `@filter`를
읽어 요청/응답 조건을 다르게 줄 수 없고, `intercept_filter.cr:50`의 `status:`는 `s.status`가 nil이면
false — 즉 `status:>=500`을 넣는 순간 **모든 요청 보류가 조용히 멈춘다**. 기본값은
`Direction::Both` + `EMPTY`라 켜는 즉시 in-scope 요청·응답 전부를 잡는다.
· Burp: 인터셉트 규칙이 요청/응답 각각 별도 테이블이고 파일 확장자·MIME 타입이 1급 필드다.

**P5. Rewriter 미리보기가 request 쪽으로 고정돼 응답 규칙이 "내 규칙이 안 먹네"로 보인다** `[CONFIRMED/low]`
`rewriter_controller.cr:90`이 `RuleTarget::Request` 리터럴을 넘기고, `rewriter_view.cr:109`는 행마다
REQ/RES 배지를 그린다 — 응답 규칙이 존재함을 화면이 명시하는데 아래 창은 그걸 실행할 수 없다.
완화책: 규칙 편집 오버레이는 `rules.preview`로 "affects N of M recent flows"를 보여준다.

**P6. catch 방향·조건이 세션 한정이고, 조건 바의 Esc는 취소가 아니라 삭제** `[PARTIAL/low]`
`interceptor.cr:81`의 `@direction`/`@filter`는 스토어를 읽지도 쓰지도 않는 평범한 인스턴스 필드다 —
프로젝트는 scope·sandbox·M&R·host override를 이미 영속화하는데. 공들여 만든 조건을 재시작마다
다시 친다. (Esc 동작은 결함이 아님: `intercept_view.cr:279`는 `history_view.cr:694`와 정확히 동일한
`/` 바 관례다.) 부수 효과로 필터가 키 입력마다 라이브 적용돼, 반쯤 친 조건이 실제 트래픽을 지배한다.

**P7. 보류 중인 요청을 Repeater로 보낼 수 없다 — 먼저 origin으로 흘려보내야 한다** `[CONFIRMED/high]`
`verbs/core.cr:169`~`:241`의 Intercept verb 전체(toggle/forward/drop/forward-all/mark-*/direction/
filter)에 send-to-anything이 없다. `interceptor.cr:242` `hold_request`는 `flow_id = nil`이라 보류된
요청은 forward되기 전까지 어떤 플로우 행도 갖지 않는다.
· 지금 비용: forward → History 탭 전환 → QL 필터 해제 → 행 찾기 → Repeater 키. 그리고 보류는 어느
쪽이든 풀린다. (편집 자체는 유실되지 않는다 — `client_conn.cr:347-364`가 forward된 결정 바이트를
캡처하므로 History가 편집된 요청을 그대로 갖는다.)
· Burp: 인터셉트 창에서 Ctrl+R이면 hold를 유지한 채 Repeater 탭이 생긴다.
· 수정: `Verb::Scope::Intercept`에 `intercept.repeater` 추가 → Item의 raw 바이트를 기존 public
`repeater_from_request`(`repeater_controller.cr:1115`)에 전달. 플로우 행 불필요, 바이트는 메모리에 있음.

### 4.2 Repeater

**R1. 마지막 전송 하나만 남는다 — 탭별 요청/응답 이력도, 전송 로그도 없다** `[CONFIRMED/high]`
`repeater_view.cr:80` `@prev_result`는 diff 기준선 용도 하나, 깊이 2이며 **응답만** 담는다 — 그
응답을 만든 요청 텍스트는 어디에도 안 남는다. `store/schema.cr:241` `repeaters` 테이블은 탭당
`request` 컬럼 1개, response_* 1세트. 전송할 때마다 `repeater_controller.cr:797`이 그 한 행을 덮어쓴다.
· 지금 비용: 페이로드 5개를 순서대로 시험하면 1~3번째의 요청과 응답은 존재하지 않는다. 남기려면
매번 서브탭을 복제하거나 밖으로 복사해 둬야 한다는 걸 **미리** 알아야 한다.
· Burp: 탭마다 `<` `>` 화살표로 모든 전송을 왕복하고, 각 전송의 요청과 응답이 짝으로 보존된다.
· 수정: `repeater_sends` 자식 테이블에 append(현재는 overwrite) + 응답 창에 `[`/`]` 스텝.

**R2. Repeater에 follow-redirect가 없다 — Fuzzer와 Discover에는 있다** `[CONFIRMED/medium]`
`fuzz/engine.cr:379`가 3xx를 따라가고(`:387`에 구현), TUI(`fuzz_advanced_overlay.cr:32`)와
CLI(`--follow-redirects`) 양쪽에 노브가 있다. `repeater/engine.cr:36`은 1회 교환 후 반환이고
`src/gori/repeater/` 어디에도 Location 처리가 없다.
· 수정: `Fuzz::Engine#follow_redirects`(원격 선택 Location을 P7대로 검증·거부하는 로직 포함)를
`repeater.follow-redirect` verb 뒤에서 재사용.

**R3. Comparer가 캡처된 플로우만 받고, 줄 단위 diff만 한다** `[CONFIRMED/medium]`
`runner/comparer.cr:9`가 `FlowPicker.new(store.recent_flows(2000), slot)`이고 슬롯 타입은
`Store::FlowDetail`. MCP `compare_flows`와 `gori run compare`도 flow id 2개만 받는다. 붙여넣기 입력도
없다. 그래서 **Repeater 응답이나 fuzz 결과는 영원히 비교 대상이 될 수 없다** — X4에 의해 그 전송들은
History에도 없으므로 우회로도 없다. `repeater/side_by_side.cr:20-40`의 행은 A줄 전체 대 B줄 전체라
줄 안쪽 차이 span이 없다.
· 범위 축소: 한 Repeater 탭의 **연속된 두 전송**은 내장 diff(`d`)로 비교된다. 못 하는 건 임의의 두
응답이다.
· Burp: Comparer에 아무 요청/응답이나 붙여넣을 수 있고 word-level diff를 제공한다.

**R4. TARGET 재타겟 시 Host 동기화가 CLI와 TUI에서 다르게 동작한다** `[PARTIAL/medium]`
`cli/run/repeater.cr:576-586`은 `--target`마다 Host를 다시 쓴다(명시적 `-H Host:`가 없는 한).
TUI의 `@link_host_to_target`은 `repeater_view.cr:1098` — `load_blank`(^N 빈 탭) **한 곳**에서만
armed되고 첫 발화 후 영구 해제된다.
· 범위 축소: 이건 #335에서 기록된 의도적 설계다(캡처되거나 손으로 넣은 Host를 절대 덮어쓰지 않기
위해). 남은 비대칭은 좁다 — `gori run repeater <flow-id> --target=URL`은 Host를 다시 쓰는데,
History에서 ^R로 연 뒤 TARGET을 편집하면 안 쓴다. 같은 재타겟 행위가 서피스에 따라 다른 바이트를
전선에 올린다.

**R5. 스페이스 메뉴의 Toggle diff / Hex dump가 응답 창에 포커스가 없으면 조용히 무반응** `[PARTIAL/medium]`
`runner/repeater.cr:95`·`:101`이 `return unless v.focus == :response`를 상태 메시지 없이 수행한다.
verb는 `available: in_repeater`(탭만 확인)로 등록돼 창 포커스와 무관하게 메뉴에 뜬다. 반면 마우스
경로(`repeater_controller.cr:539`)는 `focus_pane(:response)`를 먼저 호출해 어디서든 동작하고, 형제
`repeater_toggle_sni`는 침묵 대신 "SNI override (^S) applies to the TARGET pane — ↹ to it"를 낸다.
· 범위 축소: 도달 경로는 커맨드 팔레트, 그리고 diff에 한해 요청 READ 창의 맨 `d`.

**R6. 요청/응답 분할이 50/50 하드코딩 — 리사이즈·방향 전환·최대화 없음** `[CONFIRMED/medium]`
`repeater_view.cr:2427` `half = {(content.w - 1) // 2, 1}.max`. 상태도 설정도 없이 매 프레임 폭에서
계산된다. `settings/display.cr:58`의 레이아웃 prefs에 비율·방향·최대화 항목이 없고, `layout.cr:57`의
유일한 기하 노브는 `usable?`(폭≥40, 높이≥8)뿐. 좁은 창의 유일한 구제책은 4칸 nudge인 `hscroll_view`.
· Burp: 창 분할을 드래그로 조절하고 수직/수평 전환과 최대화 버튼이 있다.

**R7. `gori run repeater send`로는 저장된 세션을 읽거나 편집·삭제·재타겟할 수 없다** `[PARTIAL/medium]`
`cli/run/repeater.cr:301-309`의 플래그 전부: `--project --db -k --diff --allow-unscoped --message
--idle-ms --format`. `--target`도 `-H`도 `-b`도 `--sni`도 `--http2`도 없다. 그런데 같은 파일
`:630-637`의 형제 경로(`gori run repeater <flow-id>`)는 그 전부를 파싱한다. `repeater list
--format=json`은 요청 바이트를 의도적으로 빼고, `update`/`delete` 서브커맨드도 없다.
MCP는 전체 `update_repeater`(`mcp/tools/repeater.cr:162-180`)를 갖고 있다.

### 4.3 Fuzzer

**Z1. `^A` auto-mark는 § 하나라도 있으면 조용히 거부하고 성공을 보고한다** `[CONFIRMED/high]` **`[FIXED]`**
`fuzz/template.cr:199` `return text if text.includes?(MARKER)` — 위치가 이미 도출됐는지가 아니라 §
바이트 **존재** 여부로 중단한다. `fuzzer_view.cr:524`의 `auto_mark`는 그 **변하지 않은** 문자열을
set_text하고 `@dirty = true`를 세운 뒤 결과의 마커를 세어 "auto-marked N position(s)"를 낸다.
`fuzzer_controller.cr:941`의 상태줄은 "^A auto-mark · ^K word"를 나란히 광고해 정확히 이 혼합 순서를
유도한다. 형제 `mark_word`(`fuzzer_view.cr:566`)에는 "no word at the cursor" 가드가 있다 — 이웃한 두
마킹 verb가 정직성에서 불일치.
· 수정: `auto_mark`를 멱등으로(clear→derive) 만들거나 전후를 비교해 정직하게 거부.

**Z2. 실패한 전송의 에러 문자열은 계산되지만 어디에도 표시되지 않고, 상세 창은 retention 정책을 탓한다** `[CONFIRMED/high]` **`[FIXED]`**
`fuzz/engine.cr:90`에서 scope/sandbox 거부는 `Repeater::Result`의 `error`에 이유를 싣고 head는 비운다.
`fuzz/matcher.cr:284` `present(head)`가 빈 head에 nil을 반환하므로 **`keep_bodies: :all`로도 이유에
도달할 수 없다**. `fuzzer_view.cr:1845`는 `r.status || (r.error ? "ERR" : "—")`만 그리고, 그 행을 열면
`:2152`가 "(response not retained — only matched results keep the response)"를 출력한다 — 실제로
일어난 전송 실패 대신 retention 정책을 지목한다(그 정책은 TUI가 노출하지도 않는다).
`cli/output.cr:297`은 같은 실행에서 `r.error`를 행마다 붙여 CLI는 자기설명적이다.

**Z3. 스윕 결과는 메모리 전용 — 다음 ^R이 지우고, 5000개에서 잘리고, 그 캡이 실행 크기로 보고된다** `[CONFIRMED/high]`
`fuzzer_view.cr:98` `@results`는 뷰에만 산다. `restore()`(`:226`)는 target/template/config만 재구성
하므로 gori를 끄면 완료된 모든 실행의 모든 행이 사라진다. `:662` `begin_run`이 `@results.clear`를
호출해 두 번째 워드리스트를 시도하는 순간 첫 실행이 제자리에서 파괴된다. `:690` `RESULT_CAP = 5000`
에서 `@results.shift`로 오래된 행이 화면 고지 없이 축출된다. 그리고 `:1810`에서 실행이 끝나면
RESULTS 테두리가 진짜 `p.sent`에서 `"#{result_count} sent"`로 바뀌어 20만짜리 cluster bomb이
"running 200000/200000" → **"5000 sent"**로 스냅된다. 그 잘린 숫자가
`fuzzer_controller.cr:818`을 통해 완료 알림과 **append-only 이벤트 피드**에도 들어가므로 영속 감사
기록까지 틀린다.
· 미배선 seam: `store/fuzz_runs.cr`의 `insert_fuzz_run`/`insert_fuzz_result`/`fuzz_results`가 완전히
구현돼 있고 `store/schema.cr:315`에 `extracted` 컬럼까지 있으며 `store/compact.cr:171`에 retention
정책도 있다. **프로덕션 호출자 0개.**
· Burp: Intruder 공격은 저장·재개 가능하고 결과 테이블은 실행 크기를 정확히 보고한다.

**Z4. fuzz 결과 행에서 Repeater로 보낼 수 없다 — Miner→Repeater도 Repeater→Fuzzer도 있는데** `[CONFIRMED/high]`
`verbs/history.cr:440`에 `repeater.fuzz`("Send to Fuzzer")가 있고 `:554`에 `mine.repeater`가 있다.
Fuzzer 스코프의 verb 전체(run/stop/new/automark/chain/list-paste/pretty/http2/clear-marks/copy/
link-issue/link-note)에는 되돌아가는 핸드오프가 없다. 필요한 조각은 다 있다:
`fuzzer_view.cr:2139` `detail_request_bytes`가 선택된 결과의 정확한 전선 요청을 이미 재구성하고,
`fuzzer_controller.cr:803-805`는 `Fuzz::Result`에서 `Store::RepeaterRecord`를 이미 만든다.
`runner/miner.cr:54`의 구현은 3줄이다.
· 지금 비용: 흥미로운 히트를 손으로 파고들려면 페이로드를 눈으로 읽고 Repeater 탭을 새로 만들어
요청을 다시 조립해야 한다 — 퍼징의 핵심 루프인데.

**Z5. RESULTS가 페이징·점프를 못 하고, 정렬은 전진 사이클·오름차순 전용** `[CONFIRMED/medium]`
`tab_controller.cr:216` `body_scroll`은 기본 false이고 FuzzerController가 오버라이드하지 않아
PageUp/PageDown/Home/End가 무효다 — History(`:159`)·Issues·Sitemap·Probe·Discover는 전부 구현했으므로
Fuzzer만 예외다. `fuzzer_controller.cr:465`는 ↑/↓/j/k/↵/o/m/v만 바인딩(g/G도 half-page도 없음).
`fuzzer_view.cr:1024` `cycle_sort`는 `(i + 1) % 5`로 전진만 하고 방향이 없으며, `:1180`의 모든 분기가
맨 `sort_by`라 **가장 큰 응답·가장 느린 응답·가장 높은 상태 코드가 언제나 목록 맨 아래**에 있다.
· Burp: 결과 테이블 헤더 클릭으로 양방향 정렬, 스크롤·점프 자유.

**Z6. Grep-Extract는 엔진·CLI·MCP에서 동작하는데 TUI에는 노브도 컬럼도 없다** `[CONFIRMED/medium]`
`fuzz/matcher.cr:79` `property extract : Regex?`가 응답마다 평가돼 모든 Result의 `extracted`에 실린다.
CLI `--extract`(`cli/run/fuzz.cr:79`)는 `cli/output.cr:296`에서 `⟦value⟧`로 행마다 찍고, MCP도
노출한다. `fuzz_advanced_overlay.cr:27-42`의 필드 전체 목록에 extract가 없고 `--ml`/`--fl`에 대응하는
match/filter **lines**도 없다. 결정적으로 `fuzzer_view.cr:1391`/`:1421`은 `extract`를 세션 JSON으로
직렬화하고 복원한다 — **설정할 방법을 주지 않는 노브를 성실히 왕복시킨다.**

**Z7. 페이로드 인코딩이 마커 단위뿐 — 위치마다 ^Y 왕복 1회 vs `--encode=url` 한 번** `[CONFIRMED/medium]`
`fuzz/plan.cr:71` `PlanOptions#processors`는 "the processing pipeline applied to EVERY set (all three
surfaces share one list)"라고 문서화됐는데, `fuzzer_view.cr:941`의 TUI `PlanOptions.new`는
`processors:`를 넘기지 않아 **TUI에서는 이 공유 파이프라인이 항상 비어 있다**. CLI는
`--prefix/--suffix/--encode/--case/--hash/--regex-replace`를, MCP는 같은 목록을 배열로 받는다.
TUI의 유일한 등가물은 마커당 `¦chain`이고, 그 편집기는 ^Y로 열려 커서 아래 마커에만 작용하며 이동
전에 두 번째 ^Y로 커밋해야 한다.

**Z8. `gori run fuzz`는 `keep_bodies: :none` 하드코딩이라 헤드리스 스윕이 응답을 절대 못 보여준다** `[CONFIRMED/high]`
`cli/run/fuzz.cr:35`와 `:105` 두 곳에 리터럴로 박혀 있고, 40개 플래그 파서 어디에도 이걸 바꾸는 게
없다(`max_requests`도 마찬가지). TUI는 `:matched`(`fuzzer_view.cr:80`)라 히트의 전체 응답을 보관하고,
MCP는 `record_history: none|matched|all`로 노출한다. `cli/output.cr:102` `fuzz_row_fields`에 head도
body도 rendered request도 없다 — `Fuzz::Result#body`가 항상 nil이므로 찍을 코드 경로 자체가 없다.
· 지금 비용: CI나 스크립트에서 스윕을 돌리면 상태·길이·단어 수만 얻는다. 히트의 본문을 보려면 TUI를
열어 처음부터 다시 돌려야 한다.

### 4.4 History · QL · Sitemap

**H1. 최신 1000건만 보이고 페이징이 없다** `[PARTIAL/high]`
`history_view.cr:29` `PAGE = 1000`, `:281`의 `reload`는 커서 인자 없이 `store.search(combined, PAGE)`
를 호출한다. 정작 `store/reads.cr:40` `Store#search`는 `before_id` 커서를 이미 받는다 —
`grep -rn 'before_id' src/gori/tui/`는 0건이고 유일한 사용처는 `mcp/tools/flows.cr:25`다.
· 범위 축소: 잘림이 무신호는 아니다. 필터가 활성일 때 바 칩이 `1000+`로 표시되고
(`history_view.cr:1908-1912`), 그 주석이 "so the count isn't silently misread as the exact match
total"이라고 의도를 명시한다. 또 `MAX_ROWS = 5000`이라 라이브 캡처는 PAGE 너머로 append된다.
진짜 공백은 좁다: (a) **필터가 없으면 카운트 칩이 아예 안 그려지고**, (b) `1000+` 경고를 봐도
나머지에 도달할 어포던스가 없다 — 탈출구는 다른 터미널의 `gori run history --limit`이나 MCP뿐.

**H2. 컴파일되지 않는 QL 항이 조용히 드롭되어 필터를 넓히는데, 바에는 그대로 남는다** `[CONFIRMED/high]`
`history_view.cr:305-311` `query_note_for`는 두 경우만 보고한다 — 모든 항이 무효일 때, 그리고 정규식이
무효일 때. **부분 드롭은 nil을 반환한다.** `ql.cr:173-180` `QL.analyze`가 항별 applied/ignored/
invalid_regex를 이미 반환하는데 `src/gori/tui`·`src/gori/cli` 어디서도 호출하지 않는다(유일한 호출자
`mcp/tools/ql.cr`). `ql.cr:87-94`의 내장 REFERENCE는 위험을 자기 입으로 적어 뒀다 — 드롭된 항은
결과를 **넓히고**, "use strict:true (or ql_explain) to see exactly which terms were dropped before
relying on results".
· 재현: `host:acme proto:h2 status:>=50O` → `proto:`는 http/ws/websocket/grpc/sse만 파싱하므로
(`proto.cr:28-36`) `h2`는 사라지고, 알파벳 O가 섞인 status 항도 사라진다. acme 트래픽 **전부**가
표시되는데 바는 전체 쿼리를 문법 색으로 되읽어 준다(`:1928-1933`). h2 5xx라고 믿고 목록을 훑는다.
· Burp: 필터가 체크박스와 고정 드롭다운이라 오타로 필터가 넓어질 방법이 없다. Caido는 파싱 안 되는
항을 입력 중에 인라인으로 밑줄 친다.
· 수정: `query_note_for`에서 기존 `QL.analyze`를 돌려 "ignored: proto:h2 …"를 **필터 바에** 렌더.
빈 결과 화면만으로는 부족하다 — 넓어진 쿼리는 결코 비지 않는다.

**H3. 영속 플로우 주석이 없다 — mark는 세션과 함께 죽고 행에는 색도 코멘트도 없다** `[PARTIAL/high]`
`history_view.cr:71` `@marks`는 뷰 로컬 `Set(Int64)`이고 mark API에 스토어 왕복이 없다. 렌더되는 행
(`:1514-1530`)은 TIME/METHOD/PROTO/HOST/PATH/STA/TYPE/SIZE/DUR — 주석 컬럼이 없다.
`store/reads.cr:363` `flags_for`는 빈 배열을 반환하는 스텁("the call site is the seam")이고 QL `flag:`
는 매치할 게 없어 free-text로 떨어진다.
· 범위 축소: 영속 주석이 아예 없진 않다 — Link-to-note / Link-to-issue(`verbs/links.cr:31-36`)가 있고
mark 집합에 대해 배치로 동작한다. 없는 건 **행 색과 인라인 코멘트**이며, 그래서 분류를 마친 플로우가
다음 실행에서 안 한 것과 시각적으로 동일하다.
· Burp: 행 하이라이트 색 6종과 행별 자유 텍스트 코멘트가 기본이고, 둘 다 필터 가능하다.

**H4. Sitemap은 엔드포인트를 보여주지만 그 바이트는 절대 안 보여준다** `[CONFIRMED/medium]`
`verbs/sitemap.cr:6-104`의 verb 전체(이동/토글/전개/접기/query/mark/tag/fold ids/scope lens/discover/
send-to-Repeater)에 플로우를 여는 게 없다. 두 절반이 모두 이미 존재한다:
`store/reads.cr:95` `representative_flow_id(host, method, target)`는 트리 노드를 실제 flow id로 이미
해석하고(`runner/sitemap.cr:59`가 프로덕션 사용 중), `history_view.cr:763` `open_detail_id`는 목록
선택과 무관하게 아무 플로우나 연다(`runner/issues.cr:163`이 이미 그렇게 쓴다). 배선만 없다.
· 지금 비용: 트리에서 흥미로운 엔드포인트를 찾으면 History로 가서 그 경로의 QL 필터를 다시 친다.

**H5. SIZE 컬럼은 응답 전용인데 `size:`는 요청+응답이고, 어떤 컬럼도 정렬되지 않는다** `[PARTIAL/medium]`
`history_view.cr:1458`이 "SIZE" 헤더를 그리고 `:1529`의 셀은 `fmt_size(row.response_size)`. `ql.cr:
264-273`의 `size:`는 `(request_size + COALESCE(response_size, 0))`로 컴파일된다. 같은 바의
FILTER_HINT(`:50`)가 `size:>10000`을 광고한다 — 화면의 숫자와 비교식이 어긋난다.
`store/reads.cr:54`의 모든 목록 쿼리는 `ORDER BY id`로 끝나고 유일한 노브는 newest/oldest다.
· 범위 축소: 컬럼과 일치하는 필드 `respsize:`는 `QL_FIELDS`에 있어 **Tab 완성은 된다**. 문제는
FILTER_HINT가 어긋난 쪽을 광고한다는 것과, 정렬이 없다는 것.

**H6. History 필터의 Tab 완성이 절대 매치될 수 없는 `flag:`를 제안한다** `[CONFIRMED/medium]` **`[FIXED]`**
`history_view.cr:43` `QL_FIELDS`에서 f로 시작하는 유일한 항목이 "flag"이고, `:723-729`의
`query_complete`가 `sugg.first`를 끼워 넣으므로 `f` + Tab은 **결정적으로** `flag:`를 만든다.
`ql.cr:229-237`에는 flag 필드가 없어 토큰 전체가 free-text로 떨어지고, 그 주석은 gori가
"has no flow-flag store yet … rather than advertising an unimplemented filter"라고 적혀 있다 —
`:43`이 바로 그걸 광고하는 동안. 반대로 실제 동작하는 `url:`은 `QL_FIELDS`에 없어 제안되지 않는다.

### 4.5 TUI 조작

**T1. 마우스 드래그가 아무것도 선택하지 않고, 마우스 모드가 기본으로 터미널 선택을 빼앗는다** `[PARTIAL/high]`
`runner.cr:1179` `return unless ev.press? || ev.wheel?` — motion과 release가 버려져 드래그는 최초
press 외에 아무것도 관측되지 않는다. `read_cursor.cr:120` `click_to_cursor`는 `@anchor = nil`로
끝나므로 드래그를 시작하는 press가 **기존 선택을 능동적으로 지운다**. 애초에
`lib/termisu/.../terminal.cr:732-733`의 `enable_mouse`가 mode 1000(press/release)과 1006(SGR)만
요청하고 1002/1003 button-motion tracking을 켜지 않아 터미널이 드래그 이벤트를 보내지도 않는다.
그리고 `settings/display.cr:11` `DEFAULT_MOUSE = true` — 즉 박스에서 꺼내자마자 이 상태다
(`display.cr:56`의 주석 자체가 "off restores native text-selection"이라고 인정한다).
· 앱 쪽 기계는 이미 있다: `ReadCursor`에 anchor/extend/selection_text/highlight_spans가 있고 모든
read 창이 하나씩 소유한다. 없는 건 이벤트 소스와 라우팅뿐.
· 선행 S: press에서 `ev.shift?`를 읽어 anchor를 리셋하는 대신 확장.

**T2. `y`가 최대 64 KiB만 복사하고 잘린 바이트 수를 복사 크기처럼 보고한다** `[CONFIRMED/high]` **`[FIXED]`**
`clipboard.cr:41`이 `MAX_CLIP = 64 * 1024`에서 조용히 자른다. `Clipboard.copy`는 실제 기록 바이트를
반환하며 주석이 "so callers can compare against the source size and report when the copy was
clipped"라고 명시한다 — **그런데 절반의 호출자가 비교하지 않는다.**

| 잘림을 보고함 | 보고하지 않음 |
|---|---|
| `repeater_controller.cr:617` (copy-all) | `repeater_controller.cr:602` (`y` copy) |
| `history_controller.cr:446`, `:460` | `history_controller.cr:541` |
| `issues_controller.cr:456` | `issues_controller.cr:441` |
| `project_controller.cr:413` | `project_controller.cr:398` |
| `decoder_controller.cr:518`, `runner.cr:1698` | `jwt_controller.cr:630` |

같은 파일 안에서 14줄 떨어진 두 경로가 잘림을 언급할 가치가 있는지를 두고 불일치한다.
추가로 `clipboard.cr:36` `return 0 unless Settings.clipboard_osc52?` — 클립보드를 설정에서 꺼 두면
모든 경로가 "copied 0b to clipboard"라고 말한다. **0을 특별 처리하는 호출자는 하나도 없다**
(`grep -rn 'written == 0' src/gori/tui/` → 0건). 즉 하나의 숫자로 온전한 복사 / 잘린 복사 / 꺼진
클립보드를 구분할 수 없다.
· 수정: 잘림 보고를 `Clipboard` 안으로(또는 공통 헬퍼로) 올려 구조적으로 누락이 불가능하게 하고,
비활성 상태를 별도 메시지로 분리.

**T3. 요청을 붙여넣으면 붙이기 전 상태가 파괴된다 — `^Z`로 못 돌리고 redo도 없다** `[CONFIRMED/medium]`
`paste_newline.cr:7`이 "gori enables no bracketed-paste mode"라고 적어 뒀다 — 붙여넣기가 N개의 독립
키 이벤트로 도착해 타이핑과 구분되지 않는다. `text_area.cr:164` `insert(ch)`는 **문자마다**
`push_undo`를 호출하고, `:1008`은 `@undo_stack.shift if @undo_stack.size > 100` — 100자를 넘는 순간
붙이기 전 버퍼가 가장 오래된 항목으로 축출된다. `runner.cr:731`의 `CHAR_DRAIN_CAP`은 **렌더링**만
합치고 각 문자는 이미 자기 `push_undo`를 통과한 뒤다. 그리고 `text_area.cr:1011` `undo`가 유일한 이력
연산 — `redo`는 `src/` 어디에도 없다.
· 수정: 연속 `insert`를 하나의 undo 단위로 합침 — 같은 클래스의 `insert_string`/`insert_pair`가 이미
그 패턴이다. 장기적으로는 포크에 bracketed paste(붙여넣은 Tab 문제도 함께 해결).

**T4. `^F`가 텍스트가 아니라 줄을 찾는다 — minified 본문은 히트 1개, 매치는 화면 밖** `[CONFIRMED/medium]`
`text_area.cr:479` `hits << i if l.includes?(q)` — 매칭되는 **줄**마다 인덱스 하나이므로 한 줄의 세
occurrence가 히트 하나다. `runner.cr:2635` `search_step`은 줄 인덱스를 순회하므로 같은 줄의 두 번째
매치에 영원히 도달할 수 없고, `:2650` `jump_to_match`가 하는 일은 줄 번호로 이동하는 것뿐이다.
`repeater_view.cr:2385` `goto_response_line`은 `@resp_cursor.sync(cy, 0)` — **0열**이며 매치 쪽으로
수평 스크롤을 조정하지 않는다. 쿼리는 항상 `Regex.escape` + IGNORE_CASE라 정규식도 대소문자 토글도
없다.
· 지금 비용: 1줄짜리 4 MB JSON 응답에서 `^F`는 "1 hit"라고 말하고 커서를 0열에 놓는다. 매치는 화면
어딘가 오른쪽에 있고 도달할 방법이 없다.

**T5. `^F`/`^G`가 Comparer·Fuzzer·Issues 노트·Decoder·JWT 탭에서 조용히 아무 일도 안 한다** `[CONFIRMED/medium]`
`tab_controller.cr:553-555`의 기본 `goto_symbol`이 nil을 반환하고, 오버라이드는 repeater·project·
intercept·notes(+위임하는 target) 넷뿐이다. `runner.cr:973`에서 nil 타깃이면 가드가 그냥 통과하고,
`^F`는 keymap이 바인딩을 거부하는 예약 코드(docs "Reserved Keys")이므로 **토스트도 상태줄도 설명도
없이** 아무 일도 일어나지 않는다. Repeater에서 되니 반사가 생기는데 다섯 탭에서 죽는다.
· 최소 조치(S): `goto_target`이 nil이면 키를 삼키는 대신 "find is not available in this pane" 토스트.

### 4.6 크로스 서페이스 · 무음 실패

**X1. 프로젝트별 upstream proxy·타임아웃·capture cap이 TUI에서만 로드된다** `[PARTIAL/high]`
`settings/network.cr:170`은 이 계층을 "a RUNTIME layer set by Session.open from the OPEN project's
DB"라고 선언한다. `session.cr:57-62`가 `PROJECT_CONNECT_TIMEOUT_KEY`/`PROJECT_IO_TIMEOUT_KEY`/
`PROJECT_CAPTURE_MAX_KEY`/`PROJECT_UPSTREAM_KEY`를 읽는 유일한 지점이다.
`cli/run.cr:273-279` `open_store`는 `Env.load_project(store)`만 수화하고, MCP(`mcp/tools.cr:210`)도
마찬가지다. `settings/upstream_rules.cr:104`에서 `project_upstream_proxy`는 **최우선순위**이므로
로드되지 않은 핀은 조용히 규칙 테이블 → 전역 스칼라 → 직접 다이얼로 강등된다.
· 범위 축소: `gori run capture`는 `Session.open`을 쓰므로 로드된다. 못 하는 건
`gori run fuzz/mine/sequence/repeater/discover`와 `gori mcp`.
· 지금 비용: TUI에서 프로젝트에 업스트림 프록시를 핀했는데 헤드리스로 같은 스윕을 돌리면 프록시를
우회해 직접 나간다. 아무 경고도 없다.

**X2. `gori run mine`·`gori run sequence`가 전량 거부돼도 exit 0이고 거부 문자열을 버린다** `[CONFIRMED/high]` **`[FIXED]`**
`miner/engine.cr:185` `@errors += 1 unless raw.error == CAP_ERROR` — 전송별 에러 **문자열**을 세고
버린다. `cli/run/mine.cr:185`의 `exit 1 if had_error`는 오케스트레이션 raise(`Miner::ErrorEvent`)로만
세워지고 실패·차단된 전송으로는 세워지지 않는다. `cli/run/sequence.cr:205`도 동일하고 `:216`은 갖고
있는 에러 카운트조차 출력하지 않는다. `miner/baseline.cr:115`는 캘리브레이션이 전멸해도 "baseline
unreachable" 경고 하나 남기고 워드리스트 전체를 태운다.
· `cli/run/fuzz.cr:212`에는 #410에서 부여된 백스톱(`exit 1 if matched == 0 && errored > 0`)이 있다 —
mine과 sequence는 못 받았다.
· 지금 비용: CI에서 스코프 오타 하나로 3200건 전량 거부돼도 "no hidden parameters found" + exit 0.
파이프라인은 초록이고 결론은 "숨은 파라미터 없음"이다.

**X3. `--allow-unscoped`를 두 번째 게이트가 뒤집는데 메시지 전체가 "blocked by scope"다** `[CONFIRMED/medium]` **`[FIXED]`**
`outbound.cr:200-205` `sweep_block`이 `sandbox_blocks?`와 `excluded?`를 구분 불가능한 하나의 판정으로
뭉개고 `SCOPE_ERROR = "blocked by scope"`(`:35`)를 반환한다 — 조작자가 방금 `--allow-unscoped`로
면제한 Layer 1과 **같은 문구**다. 형제 `send_block`(`:212-217`)은
`SANDBOX_ERROR = "blocked by sandbox (out of scope)"`로 구분하니 사내 모델이 있다.
도움말도 어긋난다: `cli/run/fuzz.cr:83`·`mine.cr:49`·`sequence.cr:60`은 "Send even if the target is
outside the project scope"라고만 하고, `repeater.cr:305`만 "(Sandbox/exclude still apply)"를 붙인다.
Layer 1 중단(`cli/run.cr:356`)은 게이트와 탈출구를 둘 다 말한다 — "add a scope include rule or pass
--allow-unscoped".
· 실측: Layer 1 거부 메시지는 실제로 훌륭하다(§5 참조). 문제는 Layer 2다.

**X4. TUI/CLI의 Repeater·Fuzzer 전송은 History에 흔적을 남기지 않는다 — MCP는 남긴다** `[PARTIAL/medium]`
`grep -rn insert_flow src/gori`의 결과는 프록시 `proxy/sink.cr:34-36`과 MCP 두 곳
(`mcp/tools/send.cr:207`, `mcp/tools/fuzz.cr:106`)뿐이다. `repeater_controller.cr:1382-1389`의 주석이
직접 말한다 — Repeater의 ^R/send-group/WS/minimize는 "dial Repeater::Engine/H2Engine/WsEngine
straight from the TUI, bypassing ClientConn's per-request gate entirely", 즉 History를 쓰는
`Proxy::Sink`를 우회한다.
· 범위 축소: MCP도 `send_request`만 기본 기록이고 `fuzz_start`의 `record_history`는 기본 `none`이다.
그리고 History 밖에는 부분 흔적이 있다(Repeater 탭의 마지막 응답 슬롯).
· 지금 비용: 교전 후 "내가 정확히 뭘 보냈나"를 재구성할 수 없다. Repeater 전송은 감사 대상 트래픽인데
감사 기록이 없다.

### 4.7 온보딩 · 프로젝트 상태

**O1. Sandbox가 켜진 상태에서 마지막 scope INCLUDE를 지우면 프록시가 블랙홀이 되는데, 모든 서피스가 평범한 성공을 보고한다** `[CONFIRMED/high]` **`[FIXED]`**
위험 확인 대화는 **켜는 엣지에서만** 뜬다 — `runner.cr:3988` `if !@scope.sandbox? && @scope.
include_count == 0`. 이미 켜진 scope는 다시 검사되지 않는다.
`project_controller.cr:459` `scope_delete_rule`은 "removed scope rule: <pattern>"만 토스트하고
`include_count`도 `sandbox?`도 보지 않는다 — 55줄 아래 `:519` `toast_sandbox_state`는 보는데.
`cli/run/project.cr:525`도 "Scope rule #N deleted successfully."뿐이고 같은 파일 `:650`은 sandbox
활성화 엣지에서 크게 경고한다. MCP `delete_scope_rule`은 `{id, deleted:true}`를 반환하고 `set_sandbox`
는 동일한 결과 상태에 대해 전용 `blocks_all` 필드를 낸다.
결정타: `project_view.cr:1360`의 실시간 "⚠ no scope → ALL blocked" 표시는 PROJECT SETTINGS 창에
있는데 `:878`의 render는 한 번에 카드 하나만 그린다 — **SCOPE 창에서 룰을 편집하는 동안 그 경고는
화면 밖이다.**
· 지금 비용: 규칙 정리를 하다가 마지막 include를 지운다. "removed scope rule"을 본다. 그때부터
브라우저의 모든 요청이 조용히 죽는다. 프록시가 고장 났다고 결론 내리기까지의 시간 전부가 비용이다.
· 참고: fail-closed 자체는 Burp의 "빈 스코프 = 전부 허용"보다 **더 나은 기본값**이고 DESIGN.md §7에
기록된 결정이다("a rule-less scope is not an absent one"). 고칠 건 정책이 아니라 write 경로의 침묵이다.

**O2. 프로젝트 설정(scope·M&R·env·host override)을 내보내거나 두 번째 프로젝트로 복사할 수 없다** `[PARTIAL/high]`
`cli/run.cr:171-177`의 `gori run project` 표면 전체는 list/create/delete/scope/sandbox/env/
host-override — export도 import도 없다. `settings.cr:303`의 설정 프로파일 seam은 명시적으로 "a
settings subset", 즉 전역 settings.json의 섹션들이지 프로젝트 DB가 아니다. `session.cr:68-70`의
`Rules.load`/`Scope.load`/`HostOverrides.load`는 전부 프로젝트별 스토어를 읽으므로 프로파일이 나를 수
있는 파일 안에 없다. `project_picker.cr:45-50`의 액션 메뉴는 Open/Rename/Compress/Delete — duplicate도
clone도 copy-config도 없다.
· 범위 축소: 오늘도 스크립트로는 된다 — `gori run project scope|env|host-override --format=json`과
`gori run rewriter --format=json`이 네 테이블을 덤프하고 대응하는 add 명령이 있다. 없는 건 단일 문서
왕복과 클론 액션.
· Burp: 프로젝트 옵션을 JSON으로 내보내고 다른 프로젝트에 불러온다. 팀 표준 설정을 공유하는 기본 경로다.

**O3. retention이 오래된 캡처를 조용히 지우고, 유일한 흔적은 `~/.gori/gori.log`의 한 줄** `[CONFIRMED/medium]`
`store.cr:166` `RETENTION_DEFAULT = 100_000`이 캡처를 소유하는 모든 open에 기본 적용된다.
`store.cr:590` `log_retention_drop(dropped) if dropped > 0`이 스윕의 **유일한** 출력이고 —
이벤트 채널에 아무것도 발행하지 않고 카운터도 올리지 않는다 — `:598`에서 `::Log.info`로 나가
`app.cr:67`이 지정한 `<GORI_HOME>/gori.log`에 쌓인다. TUI는 그 파일을 읽지도 표시하지도 않는다.
· 선례가 바로 옆에 있다: `store.cr:235` `write_failures`는 스토어가 서피스를 모른 채 노출하는
`Atomic(Int32)`이고, `runner.cr:435`의 렌더 루프가 매 틱 폴링해 빨간 상단 바 칩을 띄운다.
· 수정: `retention_dropped : Atomic(Int64)`를 옆에 두고 `prune`에서 증가 — `store/`의 서피스 무지
(§2.1)를 지키면서 기존 폴링이 알림으로 바꿔 준다.

**O4. 디스크 회수에 세션 종료가 필요하고, 세션 중 "Clear history"는 모든 플로우를 지우고 0바이트를 회수한다** `[CONFIRMED/medium]`
`store/compact.cr:15-18`의 문서: compaction은 "runs against a project that is NOT open in this
process — the ProjectPicker triggers it before any Store/session exists"이고 그동안 capture lock을
잡는다. `:113` `return nil unless lock`이라 열린 세션(`session.cr:100`이 그 락을 쥠)에서는 `Store.
compact`가 아예 거부한다. `project_picker.cr:597` `start_compress`는 피커의 SPACE_ENTRIES에서만 닿고
verb 레지스트리·`cli/run/`·`mcp/tools/` 어디에도 compact 진입점이 없다.
`store/reads.cr:193-208` `clear_flows`는 DELETE와 FTS delete-all만 하고 VACUUM을 안 하므로 SQLite가
해제된 페이지를 파일에 그대로 둔다. `history_controller.cr:521`의 피드백은 "history cleared" 한 줄 —
디스크 크기가 그대로라는 말은 없다.
· 지금 비용: 디스크가 찬다. History를 비운다. "cleared"를 본다. 파일 크기는 그대로다. 실제 회수는
gori를 끄고 프로젝트 피커에서 Compress를 골라야 한다는 걸 알아내야 한다.

**O5. "Open browser"에 키 바인딩이 없고, 언급 자체가 첫 플로우 뒤 사라진다** `[CONFIRMED/medium]`
`verbs/core.cr:70-74`의 주석이 "Palette-only (no chord — used rarely)"라고 적혀 있고 `Verb::Chord`
없이 등록된다 — 팔레트를 열어 검색해야만 닿는다. 그런데
`traffic_empty_state.cr:426` `draw_palette_hint`는 "Open browser" 라벨 옆에 ` ^P ` 칩을 그려 **팔레트
코드를 마치 브라우저 코드인 양** 광고한다. 그 카드는 `history_view.cr:1466-1482`에서 `@rows.empty?`
+ 쿼리 없음 + scope 렌즈 비활성일 때만 그려지므로 **플로우 하나가 도착하는 순간 사라진다**.
Project 탭의 "first run — … ^P: Open browser · Export CA certificate" 표지판도
`project_view.cr:901-905`에서 `@flow_count == 0`에 걸려 있다.
· 그리고 첫 실행 마법사(`setup_wizard.cr:30-34`)의 단계는 Bind / Appearance(테마) / Review뿐 —
**CA도, 미리 신뢰된 브라우저도 언급하지 않는다.** (실측 §5.2에서 확인)
· Burp: "Open browser"가 항상 있는 1급 버튼이고, 그 Chromium은 CA를 이미 신뢰한다. 신선한 설치에서
첫 HTTPS 요청까지 인증서 작업이 0이다.

---

## 5. 빌드한 바이너리로 직접 재현한 것

`shards install && shards build` → `bin/gori`. 격리된 `GORI_HOME`, :18099 raw-echo origin,
:18100의 4.3 MB JSON, tmux 180x46(120/100/80으로 리사이즈).

**E1. `gori tui`에 `--project NAME`이 없다 — `--db PATH`뿐.**
`gori tui --help`의 플래그: `-l/--listen`, `-p/--port`, `--db=PATH`, `--ca-dir`,
`--insecure-upstream`. 반면 모든 `gori run <sub>`은 `--project NAME`을 받는다. 셸에서 이름 붙은
프로젝트로 TUI를 열려면 먼저 `gori run project list`로 sqlite 경로를 알아내야 한다. gori는 이름 있는
프로젝트 레지스트리를 갖고 있는데 두 서피스 중 하나만 그걸 쓸 수 있다.

**E2. `--db`와 `--port`를 명시해도 첫 실행 마법사가 뜬다.**
신선한 `GORI_HOME`에서 `gori tui --db <path> --port 8071`을 띄우면 2단계 마법사(bind IP/port → 테마)가
먼저 열린다. 마법사가 묻는 두 가지를 방금 커맨드라인으로 줬는데도. 같은 `GORI_HOME`으로 `gori run`을
아무리 써도 설정 완료로 표시되지 않는다.

**E3. 마법사의 키 힌트가 "next"를 중의적으로 쓴다.**
푸터는 `↵ next · ↑/↓ field · esc skip`. 1단계(Bind IP / Bind Port)에서 첫 필드에 `↵`를 누르면 힌트가
`↑/↓`에 귀속시킨 동작인 **두 번째 필드**로 간다. 2단계에 가려면 `↵`를 한 번 더 눌러야 한다.
"next"가 커서 위치에 따라 필드도 되고 단계도 되는데 힌트는 그 말을 안 한다.

**E4. 마법사는 CA 신뢰를 전혀 다루지 않는다 — 첫 HTTPS 캡처를 막는 유일한 단계인데.**
단계: (1) bind IP/port, (2) 테마, 그리고 가이드 투어를 제안하는 리뷰 카드. 루트 CA 신뢰는 Project 탭
배너(`^P: Open browser · Export CA certificate`)와 `gori.proxy` 자체 페이지에 맡겨진다 — 그 배너는
O5대로 첫 플로우와 함께 사라진다.

**E5. 폭 때문에 잘린 탭은 `⋯ N` 카운트에 잡히지 않는다.**
`chrome.cr:147-151` `more_label`은 `⋯ #{hidden_count}`를 렌더하고 그 카운트는
`hidden_tabs`/`split_tabs`(`:128-146`)에서 온다 — **settings:tabs prefs로 숨긴 탭만** 센다.
200 → 120 → 100 → 80열로 리사이즈하는 동안 배지는 매 폭에서 `⋯ 4`로 고정인데 보이는 탭은 13개에서
7개로 줄었다. 폭에 밀려난 탭은 `‹` 오버플로 셀(`:160`)로만 표시되고 어디에도 집계되지 않는다.
80열에서는 조작자가 숫자 단서를 못 받는 탭이 6개다.
· `more_label`의 버그가 아니다 — 문서대로 동작한다. 마찰은 "이 탭이 안 보인다"의 서로 다른 두 종류가
하나의 어포던스와 하나의 카운트를 공유한다는 점이다.

---

## 6. 보정 — 이미 잘 되어 있는 것

불평 목록만 있으면 눈금이 어긋나므로, 실측으로 확인한 강점을 함께 남긴다.

**엔진 속도는 문제가 아니다.** 4.3 MB JSON 본문에 대한 `gori run repeater send`가 프로세스 시작 · DB
open · 전송 · JSON 직렬화를 전부 포함해 **111 ms**.

**byte-exactness가 지켜진다.** `X-Test: 1`과 CRLF 프레이밍이 있는 raw 요청 파일이 raw-echo origin에
바이트 동일하게 도달했다. `store/models.cr`은 head/body를 전선 옥텟으로 보관하고 파싱된 컬럼을 투영
으로 둔다. Burp라면 정규화했을 요청이 그대로 살아남는다.

**Layer 1 거부 문구가 훌륭하다.** `127.0.0.1 is out of the project scope — add a scope include rule
or pass --allow-unscoped` — 호스트와 탈출구를 둘 다 말한다. X3이 고쳐야 할 건 이 모델을 Layer 2에도
적용하는 것뿐이다.

**exit code가 정확하다.** scope 차단 = 1, 없는 flow = 1, 없는 프로젝트 = 1 (파이프 없이 검증;
`| head`는 `$?`를 가린다). #410/#415/#416 클래스는 실제로 닫혔다. 남은 건 X2의 mine/sequence뿐.

**서피스 간 상태가 실제로 이어진다.** `gori run repeater create`로 만든 세션이 TUI Repeater 서브탭
스트립에 응답까지 붙은 채 나타난다.

**컨텍스트 푸터.** 포커스 티어마다 하단 힌트가 바뀐다
(`TABS ←/→ switch tab …` → `BODY i/↵ edit · ⇧arrows select · y copy · space cmds · ^S SNI · ^R send`).

**빈 상태가 다음 행동을 들고 있다.** Repeater 카드는 `^R repeater from History` / `^N new blank
repeater tab`을 제시한다.

**공백 가시화.** Repeater 편집기가 공백을 `·`, 줄 끝을 `␍␊`로 렌더한다.

**Intruder 4종이 전부 있다.** `fuzz/types.cr:11-16` — Sniper / BatteringRam / Pitchfork /
ClusterBomb, `generator.cr`가 교차곱을 실체화하지 않는 지연 블록 기반.

**에이전트 표면은 곁다리가 아니다.** ~130개 MCP 도구가 TUI와 같은 영역을 덮고, 그중 `ql_explain`은
TUI가 못 하는 드롭된 QL 항 보고를 하며(H2), `intercept_forward_edit`는 byte-exact이고, history
페이징은 커서 기반이다(H1). Burp에 등가물이 없다.

**구조적으로 서피스가 어긋날 자리가 Burp보다 적다.** Plan 빌더 리팩터(#356, #366, #373–#377)가
Fuzzer/Miner/Sequencer/Discover/Repeater에 세 서피스 공용 조립 경로를 하나씩 주었고,
`src/gori/outbound.cr`이 도구별 검사 대신 단일 scope 초크포인트다. 이 문서의 파리티 항목들이 전부
"조립"이 아니라 "각 서피스가 무엇을 보관하고 보고하는가"에 몰려 있는 건 그 리팩터가 실제로 작동했다는
증거다.

**단일 정적 바이너리.** JRE 없음, 프로젝트 파일 포맷 없음, 라이선스 체크 없음, `gori run`은 선언된
TUI 파리티(#352).

**fail-closed sandbox는 더 나은 기본값이다.** O1이 문제 삼는 건 정책이 아니라 write 경로의 침묵이다.
Burp의 "빈 스코프 = 전부 허용"보다 이쪽이 옳고, DESIGN.md §7에 이유가 기록돼 있다.
