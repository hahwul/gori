+++
title = "MCP 서버"
description = "Model Context Protocol을 통해 AI 에이전트나 스크립트로 gori를 구동합니다."
weight = 85

[extra]
group = "자동화"
+++

gori는 내장 **MCP(Model Context Protocol) 서버**를 제공합니다. TUI에 채팅 창을 넣는 대신, gori는 프로젝트를 깔끔한 도구 인터페이스로 노출합니다. 덕분에 MCP를 지원하는 어떤 에이전트든(Claude, Codex, Grok 등) 트래픽을 읽고 도구를 구동할 수 있습니다.

<figure class="agent-session" aria-label="에이전트 세션 예시: 에이전트가 MCP로 IDOR를 찾아 이슈를 기록한다">
  <div class="agent-session-bar">
    <span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
    <span class="agent-session-title">에이전트 · MCP로 구동하는 gori</span>
  </div>
  <div class="agent-session-body">
    <p class="as-user"><span class="as-who">나</span>users API에서 IDOR를 찾아 기록해줘.</p>
    <p class="as-call"><span class="as-arrow">→</span> <code>list_history</code> <span class="as-args">path~/v1/users status:200</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-args">플로우 14개, customer 및 admin 토큰</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>send_request</code> <span class="as-args">GET /v1/users/2 · customer 토큰</span></p>
    <p class="as-ret"><span class="as-arrow">←</span> <span class="as-warn">200</span> <span class="as-args">{"id":2,"email":"other-tenant@example.com"}, 호출자의 행이 아님</span></p>
    <p class="as-call"><span class="as-arrow">→</span> <code>create_issue</code> <span class="as-args">"IDOR on /v1/users/{id}" severity:high</span></p>
    <p class="as-done"><span class="as-check">✓</span> 이슈 기록됨; 재현을 위해 요청이 Repeater 세션으로 저장됨.</p>
  </div>
</figure>

```bash
gori mcp
```

서버는 stdio 위에서 JSON-RPC 2.0으로 통신합니다. STDOUT은 프로토콜을, STDERR은 로그를 전달합니다. 도구 결과에는 하위 호환용 텍스트가 담기며, 페이로드가 JSON이면 MCP `structuredContent`도 함께 들어갑니다.

## 프로젝트 선택 {#choosing-a-project}

```bash
cd /path/to/my-repository && gori mcp # path-binds this Git workspace to its own gori project
gori mcp --project my-engagement   # serve a named project's database
gori mcp --db /path/to/project.db  # serve a specific database file
gori mcp --use-active-project      # explicitly serve the active TUI/MRU project
gori mcp --no-project              # force unbound even inside a Git workspace
```

명시적 선택자가 없으면, gori는 가장 가까운 Git 루트를 찾아 그 정규 경로를 격리된 프로젝트에 바인딩합니다. 이 바인딩은 디렉터리 이름이 같은 두 리포지토리가 하나의 데이터베이스를 공유하는 것을 막습니다.

**Git 워크스페이스 밖**에서 뜨면(AI 클라이언트가 홈·앱 디렉터리에서 MCP를 띄우는 흔한 경우) 서버는 **unbound**로 시작합니다. MCP 핸드셰이크와 도구 목록은 바로 성공하지만, 트래픽 도구(`list_history`, `send_request` 등)는 에이전트가 `list_projects`, `create_project`(unbound일 때 자동 바인딩), 또는 `switch_project`를 호출하기 전까지 `NO_PROJECT`를 반환합니다. unbound는 활성 TUI/MRU 프로젝트를 슬그머니 열지 않습니다 — 그건 명시적 `--use-active-project` 옵트인(또는 `--project` / `--db` / `GORI_MCP_PROJECT` / `GORI_MCP_DB`)이 필요합니다.

**선택된 프로젝트를 열 수 없으면** — 데이터베이스가 없거나 깨졌거나 읽을 수 없을 때, 프로젝트 이름이 더 이상 존재하지 않을 때 — 서버는 종료하지 않고 핸드셰이크를 마친 뒤 unbound로 시작합니다. 실패 이유는 stderr에 기록되고, 핸드셰이크 `instructions`에 실리며, 모든 `NO_PROJECT` 도구 오류에 함께 반환되고, `project_info`의 `bind_error` 필드로도 보고됩니다. 에이전트는 재시작 없이 `list_projects`와 `switch_project`로 복구할 수 있습니다.

데이터를 사용하기 전에 `project_info`를 호출하세요. `bound`, 선택된 프로젝트, 데이터베이스 경로, 워크스페이스 루트, 선택 출처를 보고합니다.

## 읽기 전용 모드 {#read-only-mode}

기본적으로 서버는 실시간 요청을 보내고 이슈를 기록하는 액션 도구도 노출합니다. 읽기 도구만 노출하려면(신뢰할 수 없는 에이전트에게 프로젝트를 넘길 때 안전합니다) 읽기 전용으로 시작하세요.

```bash
gori mcp --read-only
```

## 에이전트에 설치하기 {#installing-into-an-agent}

gori는 널리 쓰이는 클라이언트의 MCP 설정을 대신 작성해 줍니다.

| 플래그 | 클라이언트 | 작성되는 설정 |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | 플랫폼별 앱 설정 디렉터리의 `claude_desktop_config.json` (아래 참고) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

Claude Desktop을 뺀 나머지 클라이언트는 macOS·Linux·Windows에서 모두 같은 위치에 설정을 둡니다. Claude Desktop만 Electron의 앱 데이터 디렉터리를 따릅니다. macOS는 `~/Library/Application Support/Claude/`, Windows는 `%APPDATA%\Claude\`, Linux는 `$XDG_CONFIG_HOME/Claude/`(기본값 `~/.config/Claude/`)입니다. gori는 이 변수를 읽으므로 Nix나 home-manager처럼 세션에서 값을 옮겨 둔 환경도 그대로 따라갑니다.

예외는 **Flatpak** Claude Desktop입니다. 이 빌드는 샌드박스 안쪽의 `XDG_CONFIG_HOME`(`~/.var/app/<app-id>/config/Claude/`)을 읽는데, 호스트 셸에서 실행되는 gori는 그 값을 볼 수 없습니다. 이 경우 gori는 `~/.config/Claude/claude_desktop_config.json`에 쓰고 그 경로를 출력하니, 파일을 샌드박스 디렉터리로 직접 복사하세요. 설치 명령은 항상 실제로 쓴 파일을 출력하므로, 그 줄을 사용 중인 빌드가 읽는 위치와 맞춰 보세요.

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
gori mcp --install-claude-code --install-codex  # 한 번에 여러 클라이언트
```

Codex와 Grok은 JSON이 아니라 `[mcp_servers.gori]` 테이블이 있는 TOML을 사용합니다. 설치 후 클라이언트를 재시작하거나 세션을 다시 열어 MCP 서버를 다시 로드하세요. 기존 설정 파일은 제자리에서 갱신됩니다. 다른 서버·테이블·주석은 그대로 두고, 파일 권한도 유지하며, 교체는 원자적이라 설치가 중간에 끊겨도 파일이 잘려 나가지 않습니다.

클라이언트가 리포지토리 디렉터리 밖에서 MCP를 시작해도 서버는 unbound로 연결되며, 에이전트가 도구로 프로젝트를 고르거나 만들 수 있습니다. 설치 시점에 고정 engagement를 박아 두려면 선택자를 넘기세요. 예: `gori mcp --project my-engagement --install-codex`.

`--install-*`과 함께 넘긴 플래그는 모두 설치되는 커맨드에 그대로 기록됩니다. 선택자(`--project`, `--db`, `--no-project`, `--use-active-project`)는 물론 `--read-only`, `--insecure-upstream`, `--config`까지 포함되므로 클라이언트가 띄우는 커맨드가 입력한 그대로가 됩니다. 경로는 절대 경로로 변환됩니다. 클라이언트는 사용자가 고르지 않은 작업 디렉터리에서 서버를 실행하기 때문입니다.

## 도구 {#tools}

**읽기 도구**(항상 사용 가능):

| 도구 | 용도 |
|------|---------|
| `list_history` | 최신순으로 플로우 나열, 선택적 QL과 페이지네이션 포함 |
| `list_events` | 작업 수명주기와 에이전트 활동을 추가 전용 피드로 전방 커서 조회. 플로우가 여전히 전체 스트림이며, 이 피드는 플로우 행을 중복하지 않음 |
| `get_flow` | 한 플로우의 전체 요청 + 응답 |
| `get_response_body_chunk` | 인라인 64 KiB 상한을 넘는 디코드(또는 원시) 플로우/Repeater 응답을 페이지 단위로 조회 |
| `list_sitemap` / `list_sitemap_tags` | 고유 엔드포인트(host, method, path)와 거기에 달린 태그 |
| `list_issues` / `get_issue` | 트리아지된 이슈 읽기 |
| `probe_scan` | 캡처된 플로우와 Repeater 탭 재스캔. `active:true`가 아니면 패시브(요청 0건)이고, 액티브는 쓰기 권한이 필요하며 스코프 게이트를 거침 |
| `probe_issues` | Probe 탭에 저장된 발견 항목을 트리아지 상태로 조회(기본은 open만) |
| `list_probe_rules` | 모든 스캔 규칙(패시브, 액티브, 커스텀)과 활성화 여부, 프로젝트의 스캔 모드 |
| `list_scope` | 현재 스코프 include/exclude 규칙 |
| `list_links` | 이슈나 노트에서 플로우, Repeater 세션, 잡으로 이어지는 증거 포인터 |
| `compare_flows` | 두 플로우의 요청 또는 응답 줄 단위 diff — 양쪽의 status/size/time과 A→B 델타 포함. `context:N`은 동일 구간을 `{kind:fold,hidden}` 마커로 접음 |
| `intercept_list` / `intercept_get` | 라이브 인터셉트 큐와 홀드된 항목 하나의 전체 내용 조회 |
| `list_projects` | 이 호스트의 모든 gori 프로젝트 |
| `list_notes` / `get_note` | 프로젝트 노트 읽기 |
| `list_rules` | 프로젝트에 적용되는 Match & Replace 규칙을 적용 순서로 나열. 전역 규칙이 먼저, 그다음이 프로젝트 규칙(`scope`로 한쪽만 조회) |
| `list_env` | `$KEY` 치환에 쓰이는 프로젝트 env 토큰(값은 가려짐) |
| `list_host_overrides` | 이 프로젝트에 적용 중인 호스트 → IP 다이얼 맵 |
| `list_oast_providers` | 설정된 OAST 프로바이더와 현재 활성 프로바이더 |
| `decode` | `input`에 대해 인코드/디코드/해시/압축 체인을 실행(순수 변환; 네트워크나 상태 없음) |
| `jwt_decode` / `jwt_encode` / `jwt_attacks` | JWT 디코드, 재서명, 공격 페이로드 생성(순수 계산; `--read-only`에서도 사용 가능) |
| `sequence_analyze` | 붙여넣은 토큰 목록의 무작위성 / 예측 가능성 평가(순수) |
| `oast_presets` / `oast_payload` / `oast_poll` | OAST 프로바이더 나열, 현재 페이로드 조회, 실행 중인 리스너의 콜백 폴링 |
| `discover_status` / `discover_results` | Discover 실행의 진행 상황과 결과 |
| `project_info` | 플로우 / 이슈 개수, 데이터베이스, 워크스페이스 바인딩, 선택 출처 |
| `get_current_context` | 사용자가 지금 TUI에서 보고 있는 것 |
| `get_repeater_context` | Repeater 워크벤치 상태와 저장된 세션 |
| `ql_reference` | 쿼리 언어 레퍼런스 |
| `ql_explain` | 쿼리를 실행하지 않고 진단. 요청을 쓰기 전에 필터를 점검할 때 사용 |

**액션 도구**(`--read-only`로 비활성화됨):

| 도구 | 용도 |
|------|---------|
| `send_request` | HTTP 요청 전송 / 재전송(액티브; 기본적으로 History에 기록, `$KEY` 환경 토큰을 확장, 명시적으로 요청하지 않는 한 민감한 응답 헤더 값을 가림) |
| `send_websocket` | 저장된 WebSocket Repeater 세션을 실행하고 응답을 수집 |
| `create_repeater` / `update_repeater` / `delete_repeater` | Repeater 세션 관리 |
| `minimize_repeater` | Repeater 요청을 같은 응답이 재현되는 최소 형태로 줄임 |
| `create_issue` / `update_issue` / `delete_issue` | 이슈 기록, 갱신, 삭제 |
| `add_link` / `remove_link` | 이슈나 노트의 증거 포인터 연결 / 해제 |
| `create_note` / `update_note` / `delete_note` | 프로젝트 노트 관리 |
| `create_rule` / `update_rule` / `set_rule_enabled` / `delete_rule` | Match & Replace 규칙 생성, 편집, 토글, 삭제(오가는 요청/응답의 헤드 또는 본문을 그 자리에서 재작성). 각각 `scope`를 받습니다 — `project`(기본값) 또는 모든 프로젝트에 적용되는 `global` |
| `preview_rule` | 규칙을 만들기 전에, 저장된 플로우 중 몇 개가 바뀌었을지 추정 |
| `import_flows` | HAR / URL 목록 / OpenAPI / Postman / Insomnia / Burp 파일을 History로 일괄 임포트 |
| `delete_flow` / `clear_history` | 플로우 하나 삭제, 또는 캡처된 History 전체 삭제 |
| `set_sitemap_tag` | Sitemap 경로에 자유 형식 메모 고정 |
| `create_project` / `switch_project` / `delete_project` | 프로젝트 생성 또는 다시 열기, 이 서버를 다른 프로젝트로 전환, 프로젝트 삭제. 삭제는 2단계로, `dry_run` 후 확인 토큰 필요 |
| `add_scope_rule` / `update_scope_rule` / `delete_scope_rule` / `set_scope_enabled` | 프로젝트의 include / exclude 규칙 편집과 스코프 렌즈 토글 |
| `set_sandbox` | 하드 컨테인먼트. 켜면 프록시가 스코프가 허용한 것만 전달하고 나머지는 차단 |
| `set_env_var` / `delete_env_var` | `$KEY` 치환이 읽는 프로젝트 env 토큰 관리 |
| `add_host_override` / `update_host_override` / `delete_host_override` | 호스트 → IP 다이얼 맵 관리(요청은 그대로 두고 접속 IP만 변경) |
| `probe_promote` / `probe_dismiss` / `probe_delete` | Probe 발견 항목을 Issues로 승격, 기각, 또는 삭제 |
| `set_probe_mode` | 스캔 모드 설정: `off`, `passive`, `active`, `aggressive`(허가된 대상 전용) |
| `create_probe_rule` / `update_probe_rule` / `delete_probe_rule` / `set_probe_rule_enabled` | 커스텀 매치 규칙 관리와 스캔 규칙 활성화 / 비활성화 |
| `create_oast_provider` / `update_oast_provider` / `delete_oast_provider` / `set_oast_provider_enabled` | `oast_start`가 사용할 OAST 프로바이더 관리 |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Fuzzer 구동 |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Param Miner 구동 |
| `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` | 라이브 리플레이로 토큰을 수집해 평가(결과는 리포트만 반환, 토큰은 반환하지 않음) |
| `authorize_start` / `authorize_status` / `authorize_results` / `authorize_stop` | 캡처된 플로우를 여러 아이덴티티로 재전송하고 각 응답을 기준선과 비교 — 접근 제어 결함. 결과는 `access_control`(`BYPASS`/`enforced`/`review`/`nothing_sent`)과 페이징 없는 `bypasses` 목록으로 시작합니다 |
| `discover_start` / `discover_stop` | 엔드포인트 스파이더링 & 브루트포스(`discover_status` / `discover_results`로 폴링) |
| `oast_start` / `oast_stop` | OAST 페이로드 등록 후 콜백 폴링(`oast_poll`로 히트 조회) |
| `list_jobs` / `get_job` / `stop_job` | 작업 종류를 가로질러 처리: 이번 세션이 시작한 모든 fuzz와 mine 작업 나열, 또는 id로 하나를 조회하고 중지 |
| `intercept_forward` / `intercept_forward_edit` / `intercept_drop` | 홀드된 메시지를 바이트 그대로 내보내거나, 수정한 와이어 바이트로 내보내거나, 드롭 |
| `intercept_toggle` / `intercept_set_filter` / `intercept_set_direction` | 캐치 활성화 및 해제, 조건 쿼리 설정, 홀드할 방향 선택 |

> 액션 도구는 안전을 위해 상한이 있습니다: fuzz, mine, sequence, discover, authorize 작업은 총 요청 수, 동시성, 저장 결과 수가 제한됩니다. authorize의 상한은 `플로우 × 아이덴티티`를 세며, 상한을 넘는 선택은 잘라서 실행하는 대신 시작 전에 거부됩니다. 잘린 실행은 보내지도 않은 플로우를 "enforced"로 보고하게 되기 때문입니다. `create_rule`로 생성된 규칙은 `gori run`과 새로 열린 TUI에 적용됩니다. 이미 실행 중인 TUI는 규칙을 다시 로드한 뒤에만 적용합니다.

## 라이브 인터셉트 {#live-intercept}

에이전트가 나중에 History를 읽는 대신, 인터셉트 루프 안에 나란히 앉을 수 있습니다. 캡처 락을 쥔 TUI 세션이 홀드된 메시지를 에이전트 쪽으로 미러링하고 에이전트가 보낸 명령을 받아 처리하므로, `intercept_list` → `intercept_get` → `intercept_forward_edit`은 직접 손으로 도는 것과 같은 루프입니다.

변경을 일으키는 쪽(`intercept_forward`, `intercept_forward_edit`, `intercept_drop`, `intercept_toggle`, `intercept_set_filter`, `intercept_set_direction`)은 `--read-only`에서 비활성화되며, 라이브 캡처 세션이 락을 쥐고 있지 않으면 모두 거부합니다. 프록시가 실제로 트래픽을 홀드하고 있지 않으면 내보낼 것 자체가 없기 때문입니다.

에이전트의 행동은 조용히 지나가지 않고 드러납니다. 각 행동은 에이전트에서 온 것으로 표시되어 알림 센터에 남고 사용자 본인의 행동과 다르게 렌더링되므로, 다른 탭을 보는 동안 코파일럿이 트래픽에 무엇을 했는지 확인할 수 있습니다.

에이전트를 켜둔 채 자리를 뜨기 전에 알아둘 안전 규칙이 하나 있습니다. 홀드된 메시지는 원래 사람의 결정을 무한히 기다립니다. 키보드 앞에 사람만 있을 때는 그게 맞는 동작입니다. 하지만 해당 세션에서 에이전트가 인터셉트 큐에 붙고 나면, gori는 아무도 보고 있지 않은 항목에 대해 30초 자동 포워드를 켭니다. 홀드 도중 죽은 클라이언트가 연결을 영영 막아버리지 못하게 하기 위해서입니다. 에이전트가 붙지 않은 세션은 자동 포워드를 하지 않습니다.

## 한 번에 한 호출 {#one-call-at-a-time}

도구는 도착한 순서대로 하나씩 실행되고, 응답도 그 순서로 돌아옵니다 — 퍼즈나 느린 `send_request`가 다음 호출과 겹치지 않습니다. 다만 두 메시지는 항상 즉시 응답합니다. `ping`은 클라이언트의 생존 확인이 긴 호출 뒤에 밀려 "서버가 죽었다"는 판정을 받지 않도록, `notifications/cancelled`는 더 이상 기다리지 않는 요청의 응답을 보내지 않도록 하기 위해서입니다. 취소는 이미 진행 중인 작업을 중단시키지는 않습니다 — 그 요청은 끝까지 실행되고, 응답만 전송되지 않습니다.

## MCP 이음새인 이유 {#why-an-mcp-seam}

gori는 의도적으로 도구 내 AI 챗을 두지 않습니다. 지능은 도구 바깥, 곧 MCP로 접근할 수 있는 곳에 있습니다. 덕분에 모델을 직접 고를 수 있고, 트래픽이 의도치 않은 곳으로 흘러가지 않으며, 동일한 인터페이스가 스크립트와 에이전트 양쪽을 모두 지원합니다. [`gori run`](/ko/guide/scripting/)은 비대화형 경로를, MCP는 대화형 에이전트 경로를 담당합니다.

## 다음 단계 {#next-steps}

- [AI 설정](/ko/getting-started/ai-setup/): 에이전트를 연결하고 첫 요청을 구동하는 단계별 안내
- [Scripting](/ko/guide/scripting/): 또 하나의 자동화 경로 — 파이프라인과 CI를 위한 `gori run`
- [CLI Reference](/ko/reference/cli/): 전체 `gori mcp` 플래그
- [Query Language](/ko/reference/query-language/): 에이전트가 필터링에 사용하는 문법
