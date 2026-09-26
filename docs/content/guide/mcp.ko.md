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

**Git 워크스페이스 밖**에서 뜨면(AI 클라이언트가 홈·앱 디렉터리에서 MCP를 띄우는 흔한 경우) 서버는 **unbound**로 시작합니다. MCP 핸드셰이크와 도구 목록은 바로 성공하지만, 트래픽 도구(`list_history`, `send_request` 등)는 에이전트가 `list_projects`, `create_project`(unbound일 때 자동 바인딩), 또는 `switch_project`를 호출하기 전까지 `NO_PROJECT`를 반환합니다. unbound는 활성 TUI/MRU 프로젝트를 슬그머니 열지 않습니다. 그건 명시적 `--use-active-project` 옵트인(또는 `--project` / `--db` / `GORI_MCP_PROJECT` / `GORI_MCP_DB`)이 필요합니다.

프로젝트가 없어도 동작하는 도구 계열이 몇 가지 있습니다. 프로젝트 관리(`project_info`, `list_projects`, `create_project`, `switch_project`, `delete_project`, `export_project`, `import_project`, `diff_projects`), 순수 계산 헬퍼(`decode`, `jwt_*`, `cookie_*`, `sequence_analyze`), 쿼리 언어 레퍼런스(`ql_reference`, `ql_explain`), 그리고 즉석 OAST 리스너(`oast_presets`, `oast_payload`, `oast_start`, `oast_stop`, `oast_poll`)입니다. 그 밖의 도구는 저장된 세션을 다루는 `oast_resume` / `oast_release`까지 포함해, 프로젝트가 바인딩되기 전까지 `NO_PROJECT`를 반환합니다.

**선택된 프로젝트를 열 수 없으면**(데이터베이스가 없거나 깨졌거나 읽을 수 없을 때, 프로젝트 이름이 더 이상 존재하지 않을 때) 서버는 종료하지 않고 핸드셰이크를 마친 뒤 unbound로 시작합니다. 실패 이유는 stderr에 기록되고, 핸드셰이크 `instructions`에 실리며, 모든 `NO_PROJECT` 도구 오류에 함께 반환되고, `project_info`의 `bind_error` 필드로도 보고됩니다. 에이전트는 재시작 없이 `list_projects`와 `switch_project`로 복구할 수 있습니다.

데이터를 사용하기 전에 `project_info`를 호출하세요. `bound`, 선택된 프로젝트, 데이터베이스 경로, 워크스페이스 루트, 선택 출처, 그리고 프로젝트 `description`—`create_project`가 저장하는 "이 프로젝트가 무엇을 위한 것인가"—을 보고합니다. 그 설명을 되읽어 주는 호출은 이것뿐입니다.

**`instructions`에 적힌 프로젝트는 핸드셰이크 시점의 바인딩입니다.** 이 텍스트는 한 번만 전달되고 갱신을 밀어주는 수단이 없어서, `switch_project` 이후에도 그때의 바인딩을 계속 설명합니다. 실제 읽기와 쓰기는 새 프로젝트로 갑니다. 현재 값은 `project_info`가 답합니다. `switch_project`(그리고 자동 바인딩하는 `create_project`)는 같은 정정을 결과에 담아, 직전 바인딩을 `previous_project`로 함께 돌려줍니다.

## 읽기 전용 모드 {#read-only-mode}

기본적으로 서버는 실시간 요청을 보내고 이슈를 기록하는 액션 도구도 노출합니다. 읽기 도구만 노출하려면(신뢰할 수 없는 에이전트에게 프로젝트를 넘길 때 안전합니다) 읽기 전용으로 시작하세요.

```bash
gori mcp --read-only
```

읽기 전용 서버는 라이터도 두지 않습니다. 서빙 중인 프로젝트에 쓰지 않고 백그라운드 인덱싱도 돌리지 않습니다. SQLite는 라이터를 하나만 허용하는데, 두 번째 gori가 자기 뒷정리 작업만을 위해 그 자리를 붙들고 있으면 같은 프로젝트로 캡처 중인 TUI와 경합하게 됩니다. 예외는 예전 gori가 쓴 데이터베이스뿐입니다. 그건 마이그레이션하지 않으면 이 빌드가 읽을 수 없어서 열 때 올려줍니다.

기본(액션 허용) 서버는 라이터를 둡니다. `send_request`와 `create_issue`가 필요하기 때문입니다. 다만 idle FTS 인덱서는 돌리지 않습니다. 전문 검색은 질의 때 백로그를 비우고, 백그라운드에서 인덱스를 따라가는 일은 캡처 중인 TUI의 몫입니다.

알아둘 만한 부수 효과가 하나 있습니다. 전문 검색(`body:`)이 읽는 인덱스는 캡처 커밋과 분리되어 만들어지는데, 읽기 전용 서버는 그 인덱스를 만들 수 없습니다. 아직 인덱싱되지 않은 flow가 남아 있으면 그런 질의는 부분 인덱스로 답하는 대신 `FTS_BACKLOG`로 거부됩니다. gori로 프로젝트를 열거나 `--read-only`를 빼고 실행해서 인덱스를 비우세요.

### Preferences에서 권한 정하기 {#permissions-from-preferences}

`--read-only`는 에이전트에 설치할 때 정해집니다. gori 안에서 바로 바꾸는 스위치는 **Settings → AI → MCP permissions**에 있고, 도구 묶음마다 토글이 하나씩 있으며 기본은 모두 켜져 있습니다:

| 묶음 | 끄면 빠지는 도구 |
|------|------------------|
| **Send traffic** | 대상이나 OAST 서버로 요청을 보내는 모든 도구와, 그 도구가 시작한 작업의 폴러: `send_request`, `send_websocket`, `race_requests`, `timing_requests`, `fuzz_*`, `mine_*`, `discover_*`, `authorize_*`, `sequence_*`(`sequence_analyze` 제외), `run_retest`, `minimize_repeater`, `cache_deception_check`, `scan_js_endpoints`, `grpc_reflect`, `refresh_session_slot`, `oast_*`(`oast_presets` 제외), `list_jobs` / `get_job` / `stop_job`, `active:true`인 `probe_scan`, `active`나 `aggressive`로 올리는 `set_probe_mode` |
| **Intercept control** | `intercept_forward`, `intercept_forward_edit`, `intercept_drop`, `intercept_toggle`, `intercept_set_filter`, `intercept_set_direction` |
| **Edit project data** | 그 밖의 프로젝트 쓰기 전부: 이슈, 노트, repeater, 규칙, scope와 sandbox, env, host override, 세션 슬롯, evidence, 링크, 뷰, probe 스캔과 판정(수동 `probe_scan`도 찾은 결과를 기록합니다), flow·히스토리 삭제 |
| **Manage projects** | `create_project`, `switch_project`, `delete_project`, `import_project`, `export_project` |

캡처를 읽는 것은 묶음이 아닙니다. 읽기 도구와 `operator_messages` / `reply_to_operator`는 항상 제공됩니다. 꺼진 묶음의 도구는 `tools/list`에서 빠지고, 그래도 호출하면 `TOOL_DISABLED`로 거부되며, 핸드셰이크 instructions가 에이전트에게 어떤 묶음이 꺼졌는지 알려줍니다. 이 스위치는 `--read-only`, `--tools`와 함께 적용되어 셋 모두가 허용한 도구만 제공됩니다. `gori mcp` 프로세스가 시작할 때 읽으므로, 이미 떠 있는 에이전트는 서버를 다시 시작할 때까지 받았던 도구를 그대로 씁니다. 그 시점에 설정 파일을 읽지 못하면 모든 묶음을 켜는 대신 끕니다.

묶음은 목적지가 아니라 능력 단위입니다. **Intercept control**이 켜져 있으면 에이전트는 보류된 요청을 고쳐서 forward할 수 있고, **Send traffic**이 꺼져 있어도 그 바이트는 대상에 도달합니다. 에이전트의 바이트가 대상에 닿지 않게 하려면 둘 다 끄세요.

## 노출할 도구 고르기 {#choosing-which-tools-are-exposed}

기본적으로 `gori mcp`는 모든 도구를 노출하므로, 에이전트는 재시작 없이 워크벤치 전체를 쓸 수 있습니다. 대가는 컨텍스트입니다. 클라이언트는 첫 질문 전에 카탈로그 전체를 모델 컨텍스트에 싣고 세션 내내 유지합니다. gori는 시작할 때마다 제공하는 도구 수와 `tools/list` 크기를 로그에 남깁니다. 컨텍스트가 빠듯한 클라이언트라면 프로필에서 시작하세요:

| 시작 방법 | 도구 | `tools/list` | 토큰 | 용도 |
| --- | ---: | ---: | ---: | --- |
| `gori mcp` | 189 | ~227 KB | ~58k | 전부 (기본값) |
| `--read-only` | 62 | ~72 KB | ~18k | 읽기 도구와 순수 연산; 실제 요청 전송 없음 |
| `--tools=@recon` | 37 | ~54 KB | ~14k | 캡처를 읽고 파악, 요청 재전송, 이슈·노트 기록 |
| `--tools=@recon --read-only` | 28 | ~39 KB | ~10k | `--read-only`가 끄는 도구를 뺀 `@recon` |
| `--tools=@minimal` | 17 | ~26 KB | ~7k | History와 flow, 현재 TUI 컨텍스트를 읽고 오퍼레이터와 대화 |

토큰은 바이트 ÷ 4로 잡은 JSON 어림값이며, 실제 값은 클라이언트의 토크나이저가 정합니다.

| 프로필 | 도구 |
| --- | --- |
| `@minimal` | `project_info`, `list_projects`, `switch_project`, `create_project`, `ql_reference`, `ql_explain`, `list_history`, `get_flow`, `get_response_body_chunk`, `get_current_context`, `get_repeater_context`, `get_issue`, `list_sitemap`, `intercept_get`, `intercept_list`, `operator_messages`, `reply_to_operator` |
| `@recon` | `@minimal`에 더해 `list_scope`, `list_params`, `list_js_endpoints`, `scan_js_endpoints`, `compare_flows`, `list_env`, `decode`, `jwt_decode`, `jwt_verify`, `probe_issues`, `probe_promote`, `probe_dismiss`, `list_issues`, `list_notes`, `get_note`, `send_request`, `create_issue`, `update_issue`, `create_note`, `update_note` |

프로필은 글롭이 아니라 고정된 이름 목록이므로, 이후 버전이 `list_*` 도구를 추가해도 `@recon`이 조용히 커지지 않습니다. 둘 다 `switch_project`와 `create_project`를 포함하므로, 프로젝트가 하나도 없는 머신에서 바인딩 없이 시작해도 동작합니다.

`--tools`는 도구 이름, `*` 글롭, `@프로필`을 쉼표로 나열한 것이고 왼쪽부터 적용됩니다. `-`를 앞에 붙인 항목은 빼냅니다:

```bash
gori mcp --tools=@recon                                          # 프로필
gori mcp --tools='@minimal,send_request'                         # 프로필 + 도구 하나
gori mcp --tools='@recon,-send_request'                          # 프로필 - 도구 하나
gori mcp --tools='-fuzz_*,-mine_*,-discover_*,-sequence_*'       # 비동기 워크벤치만 제외
```

도구 이름이 접두어 계열(`list_*`, `intercept_*`, `fuzz_*`, `oast_*`)로 지어져 있으므로 글롭 하나로 그룹을 고를 수 있습니다. 빼기로 시작하는 스펙은 전체에서 출발하므로 이후 버전이 도구를 추가해도 그대로 동작합니다.

도구 설명에 명시된 필수 후속 도구(비동기 작업의 상태·결과·중지, flow 본문 페이지 읽기 등)는 전이적으로 자동 포함됩니다. 나중에 부모 도구는 남기고 필수 동반 도구를 제외하면 시작 시 충돌을 거부합니다. 제외 항목 뒤에 동반 도구를 다시 추가하거나 부모 도구를 빼세요. 조건부 라이브 인터셉트 읽기 도구는 명시적 제외를 따릅니다. `intercept_get`은 숨겼지만 `intercept_list`는 제공한다면 `get_current_context`가 미리보기와 메타데이터를 볼 수 있다고 안내하면서 전체 상세 내용은 제공되지 않는다고 알립니다. 둘 다 숨겼다면 민감한 읽기 도구를 되살리는 대신 보류 항목을 이 서버에서 읽을 수 없다고 알립니다.

스펙을 너무 좁히면 서버가 프로젝트를 *고를* 방법조차 잃을 수 있습니다. Git 워크스페이스 밖이거나 `--no-project`로 시작했거나 지정한 데이터베이스가 열리지 않아 바인딩이 없는데 스펙이 `switch_project`와 `create_project`를 둘 다 남기지 않으면, 에이전트가 무엇을 호출해도 프로젝트를 붙일 수 없습니다. `list_projects`는 여기 포함되지 않습니다 — 목록만 보여줄 뿐 아무것도 바인딩하지 않습니다. gori는 이를 시작 시점에 경고하고, `NO_PROJECT` 오류도 없는 도구를 가리키는 대신 같은 사실을 말합니다. 스펙에 `switch_project`를 남기거나 `--project`/`--db`를 넘기세요.

아무것도 매치하지 않는 패턴이나 프로필은 조용히 좁히는 대신 시작 시 중단하며 후보를 제안합니다(`--tools: "list_hisotry" matches no tool — did you mean list_history?`). 도구가 빠진 서버는 그 기능이 아예 없는 gori와 구분되지 않기 때문입니다. 제외된 도구는 `tools/list`에 나오지 않고, 그래도 호출하면 어떤 플래그가 감췄는지 밝히며 거절합니다. `--tools`는 `--read-only`와 함께 쓸 수 있고, 다른 플래그처럼 `--install-*`과 같이 주면 설치되는 명령에 기록됩니다.

## TUI에서 에이전트 보기 {#seeing-an-agent-from-the-tui}

MCP 서버가 프로젝트에 붙어 있는 동안 gori가 이를 보여줍니다. 프로젝트 선택창에서는 해당 행에 `mcp` 표시가 붙고(둘 이상이면 `mcp×2`), 프로젝트를 열면 상단 바에 클릭 가능한 `mcp:<client>` 칩이 나타납니다. 칩을 클릭하거나 명령 팔레트에서 `app.agents`를 실행하면 붙어 있는 에이전트를 나열하는 카드가 열립니다. 이름·버전·pid·연결 시각·읽기 전용 여부가 표시됩니다. 이름은 클라이언트의 `clientInfo` 핸드셰이크에서 오고, `--read-only`로 시작한 서버는 거기서 읽기 전용으로 표시됩니다. 행은 프로세스가 종료되는 즉시 스스로 사라지므로, 칩과 카드는 항상 지금 붙어 있는 것만 반영합니다.

## 에이전트에 설치하기 {#installing-into-an-agent}

gori는 널리 쓰이는 클라이언트의 MCP 설정을 대신 작성해 줍니다.

| 플래그 | 클라이언트 | 작성되는 설정 |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | 플랫폼별 앱 설정 디렉터리의 `claude_desktop_config.json` (아래 참고) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`), 또는 `$CODEX_HOME` |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |
| `--install-hermes` | Hermes | `~/.hermes/config.yaml` (`mcp_servers.gori`), 또는 `$HERMES_HOME` |
| `--install-pi` | Pi | `~/.pi/agent/mcp.json` (`mcpServers.gori`), 또는 `$PI_CODING_AGENT_DIR` |

Pi는 [pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter) 같은 MCP 어댑터가 필요합니다. `pi install npm:pi-mcp-adapter`로 어댑터를 설치한 다음 Pi를 다시 시작하세요. `--install-pi`는 MCP 서버 설정을 기록합니다.

Claude Desktop과 Hermes를 뺀 나머지 클라이언트는 macOS·Linux·Windows에서 모두 같은 위치에 설정을 둡니다. Hermes는 `$HERMES_HOME`이 설정돼 있으면 그 값을, 없으면 `~/.hermes`(Windows는 `%LOCALAPPDATA%\hermes`)를 읽습니다. Claude Desktop만 Electron의 앱 데이터 디렉터리를 따릅니다. macOS는 `~/Library/Application Support/Claude/`, Windows는 `%APPDATA%\Claude\`, Linux는 `$XDG_CONFIG_HOME/Claude/`(기본값 `~/.config/Claude/`)입니다. gori는 이 변수를 읽으므로 Nix나 home-manager처럼 세션에서 값을 옮겨 둔 환경도 그대로 따라갑니다.

예외는 **Flatpak** Claude Desktop입니다. 이 빌드는 샌드박스 안쪽의 `XDG_CONFIG_HOME`(`~/.var/app/<app-id>/config/Claude/`)을 읽는데, 호스트 셸에서 실행되는 gori는 그 값을 볼 수 없습니다. 이 경우 gori는 `~/.config/Claude/claude_desktop_config.json`에 쓰고 그 경로를 출력하니, 파일을 샌드박스 디렉터리로 직접 복사하세요. 설치 명령은 항상 실제로 쓴 파일을 출력하므로, 그 줄을 사용 중인 빌드가 읽는 위치와 맞춰 보세요.

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
gori mcp --install-hermes
gori mcp --install-pi
gori mcp --install-claude-code --install-codex  # 한 번에 여러 클라이언트
```

Codex와 Grok은 `[mcp_servers.gori]` 테이블이 있는 TOML을, Hermes는 `mcp_servers:` 항목이 있는 YAML을 사용합니다(JSON이 아닙니다). 설치 후 클라이언트를 재시작하거나 세션을 다시 열어 MCP 서버를 다시 로드하세요. 기존 설정 파일은 제자리에서 갱신됩니다. 다른 서버·테이블·주석은 그대로 두고, 파일 권한도 유지하며, 교체는 원자적이라 설치가 중간에 끊겨도 파일이 잘려 나가지 않습니다. gori는 이 파일들을 파싱 트리에서 다시 뽑아내지 않고 텍스트로 편집하므로 설정 주변에 적어 둔 메모가 그대로 남습니다. 안전하게 끼워 넣을 수 없는 설정 파일은 고쳐 쓰지 않고 그 사실을 알립니다.

클라이언트가 리포지토리 디렉터리 밖에서 MCP를 시작해도 서버는 unbound로 연결되며, 에이전트가 도구로 프로젝트를 고르거나 만들 수 있습니다. 설치 시점에 고정 engagement를 박아 두려면 선택자를 넘기세요. 예: `gori mcp --project my-engagement --install-codex`.

`--install-*`과 함께 넘긴 플래그는 모두 설치되는 커맨드에 그대로 기록됩니다. 선택자(`--project`, `--db`, `--no-project`, `--use-active-project`)는 물론 `--read-only`, `--tools`, `--insecure-upstream`, `--config`까지 포함되므로 클라이언트가 띄우는 커맨드가 입력한 그대로가 됩니다. 경로는 절대 경로로 변환됩니다. 클라이언트는 사용자가 고르지 않은 작업 디렉터리에서 서버를 실행하기 때문입니다.

## 도구 {#tools}

**읽기 도구**(`--read-only`에서도 사용 가능. 단, 다음 네 가지 `scan_js_endpoints`, `oast_payload`, `oast_poll`, `reply_to_operator`는 제외):

| 도구 | 용도 |
|------|---------|
| `list_history` | 최신순으로 플로우 나열, 선택적 QL과 페이지네이션 포함. 각 행에 `source`가 실립니다(클라이언트가 보낸 트래픽은 `proxy`, `send_request`(기본으로 기록됩니다)는 `repeater`, 그 밖에 `discover`·`import` …). 그래서 gori가 만든 플로우가 대상에 대한 증거로 잘못 읽히지 않습니다. `src:`로 필터링합니다. `columns`에 `gori run ls --column`과 같은 `[LABEL=][req\|res:]kind:selector` 스펙을 주면 행마다 추출한 값(헤더, JSON 필드, 정규식 캡처)을 `columns` 객체로 함께 싣습니다. QL로 *거를* 수는 있어도 볼 수는 없던 값을 [보여 주는](/ko/guide/proxy/#columns) 쪽입니다. 행마다 읽기가 한 번 늘어나므로 명시할 때만 동작합니다. `hide_static:true`는 TUI의 정적 파일 숨기기 렌즈(`-static:true`)와 같아서 정적 자산(이미지, 폰트, 오디오/비디오)을 뺍니다. `list_sitemap`과 `list_params`도 같은 인자를 받습니다. `ids`를 주면 정확히 그 집합을 한 번에 가져옵니다 — `get_current_context`가 `selection.ids`로 돌려주는, 사용자가 마크한 행들입니다. 요청한 순서 그대로 오고, `limit`과 두 커서는 적용되지 않으며, 행이 없는 id는 `missing_ids`로, `query`가 뺀 것은 `filtered_out_ids`로 이름을 부릅니다. 답이 짧으면 어느 쪽 때문에 짧은지 항상 말해 줍니다 |
| `list_events` | 작업 수명주기와 에이전트 활동을 추가 전용 피드로 전방 커서 조회. 플로우가 여전히 전체 스트림이며, 이 피드는 플로우 행을 중복하지 않음. 모든 이벤트가 `actor`(행위 표면: `tui` / `cli` / `mcp`)를 담고 있어 에이전트가 자기 쓰기와 운영자의 쓰기를 구분할 수 있으며, 설정 변경은 누가 하든 기록됩니다. 사람은 같은 피드를 **Project → Activity** 패널에서 읽습니다 |
| `operator_messages` | 오퍼레이터가 gori TUI에서 여러분에게 입력한 메시지("Tell the agent…")입니다. 이 세션 또는 붙어 있는 모든 에이전트에게 보낸 것을 전방 커서로 읽습니다. gori는 가능하면 즉시 전달하고(Claude Code의 피어 메시지, Codex의 `codex queue` 전달, 채널 이벤트) 그래도 남은 것은 여러분의 다음 tool result에 실어 보냅니다. 이 도구는 모든 에이전트가 가진 폴백입니다 — 턴을 시작할 때 호출하세요. 반환한 메시지는 전달됨으로 표시되어 오퍼레이터의 알림 링에 "picked up"으로 보입니다 |
| `reply_to_operator` | gori의 오퍼레이터에게 답합니다. `summary`는 알림 링과 Miss Ring 말풍선에 보이는 한 줄, `detail`은 링에서 ↵로 여는 긴 본문, `level`은 색, `in_reply_to`는 답하는 오퍼레이터 메시지 id입니다. 여러분의 터미널이 아니라 gori에 있는 사람에게 답이 닿는 방법입니다 |
| `list_views` | 프로젝트의 History [뷰](/ko/guide/proxy/#views). `list_history{view}`가 렌즈로 적용하는 이름 붙은 QL 쿼리로, `query`를 대체하지 않고 그 위에 AND로 얹힙니다. 기본 뷰 7종(`All`, `History`, `History + Repeater`(기본값), `WebSocket`, `gRPC`, `SSE`, `Errors`) → 글로벌 라이브러리 → 프로젝트 순이며, `active`는 TUI가 보고 있는 뷰를 표시할 뿐 `list_history`에 적용되지 **않습니다**. 그쪽은 넘긴 `view`로만 거릅니다 |
| `get_flow` | 한 플로우의 전체 요청 + 응답. [리댁션 프로파일](/ko/reference/cli/#run-redact)이 기본 적용된 곳에서는 본문이 정제되어 `body_redaction` 객체와 함께 돌아옵니다. `include_sensitive:true`는 헤더 리댁션과 함께 그것도 끕니다 |
| `get_response_body_chunk` | 인라인 64 KiB 상한을 넘는 디코드(또는 원시) 플로우/Repeater 응답을 페이지 단위로 조회 |
| `list_sitemap` / `list_sitemap_tags` | 고유 엔드포인트(host, method, path)와 거기에 달린 태그 |
| `list_js_endpoints` / `scan_js_endpoints` | 캡처된 JavaScript가 참조하지만 요청이 닿지 않은 엔드포인트와, 각각을 읽어 온 플로우, 줄, 문자열. 스캔은 새 JS/HTML 응답을 읽을 뿐 요청은 보내지 않습니다. `list_sitemap`에 `include_unrequested:true`를 주면 `unrequested`로 함께 나옵니다 |
| `list_params` | 엔드포인트별 파라미터 목록: 위치별 입력 이름, 등장 횟수, 샘플 값(자격 증명은 가림), 응답에 값이 반사되는지 여부 |
| `export_openapi` | 캡처된 API를 OpenAPI 3.0.3 문서로 바로 돌려줘요(JSON 객체, `format:"yaml"`이면 YAML). 템플릿 경로, 파라미터, 추론한 요청·응답 스키마, servers, 보안 스킴이 들어가요. 자격 증명 값은 넣지 않고, 예시 값은 `examples:true`일 때만 가려서 넣어요. `max_endpoints`와 `max_bytes`로 크기를 제한하고, 잘리면 `truncated`로 알려줘요. `@recon` 크기 예산을 넘겨서 전체 카탈로그에만 있어요 |
| `list_issues` / `get_issue` | 트리아지된 이슈 읽기 |
| `probe_scan` | 캡처된 플로우와 Repeater 탭 재스캔. `active:true`가 아니면 패시브(요청 0건)이고, 액티브는 쓰기 권한이 필요하며 스코프 게이트를 거침 |
| `probe_issues` | Probe 탭에 저장된 발견 항목을 트리아지 상태로 조회(기본은 open만) |
| `list_probe_rules` | 모든 스캔 규칙(패시브, 액티브, 커스텀)과 활성화 여부, 프로젝트의 스캔 모드 |
| `list_scope` | 현재 스코프 include/exclude 규칙 |
| `list_links` | 이슈나 노트에서 플로우, Repeater 세션, 잡으로 이어지는 증거 포인터 |
| `list_evidence` / `get_evidence` | 동결된 증거 목록(교환의 변경 불가 사본, 출처·연결된 이슈·SHA-256 포함. `issue_id`를 주면 한 이슈의 사본, 생략하면 고아까지 포함한 프로젝트 전체 보관함)과, 사본 하나의 바이트(`include_sensitive`가 아니면 헤드의 자격 증명은 가려지고, 본문은 `get_flow`처럼 상한 적용) |
| `list_retest_steps` / `list_retest_runs` / `get_retest_run` | Issue의 **리테스트**: 결함을 재현하는 Repeater 전송 목록(각 단계를 현재 프로젝트 기준으로 해석하므로 응답에 무엇을 보낼지와 어떤 단계가 상태를 바꾸는지가 이미 담겨 있습니다. Repeater 세션이 삭제된 단계는 `ref_deleted: true`로 표시되고, 새 세션이 그 id를 다시 받아도 실행되지 않습니다), 보존된 실행 기록(최신순), 그리고 한 실행의 결과 표(각 행이 자기 전송의 History flow id를 보관) |
| `get_issue`의 retest 필드 | 리테스트가 있는 이슈는 `links`, `evidence` 옆에 `retest` 객체(단계 수와 마지막 실행 판정)를 함께 싣습니다. 결함을 읽는 것만으로 재현 가능한 검사가 있는지, 지난번에 뭐라고 했는지 알 수 있습니다. 리테스트가 없는 이슈에는 아예 나오지 않습니다 |
| `compare_flows` | 두 플로우의 요청 또는 응답 줄 단위 diff. 양쪽의 status/size/time과 A→B 델타 포함. `context:N`은 동일 구간을 `{kind:fold,hidden}` 마커로 접음 |
| `diff_projects` | 리테스트 diff: **프로젝트 두 개**를 엔드포인트 단위로 비교. 지난 엔게이지먼트 이후 무엇이 새로 생겼고, 사라졌고, 다르게 응답하는지. 엔드포인트 키는 Sitemap의 폴딩된 템플릿을 그대로 쓰고, `removed`(새 캡처가 아예 요청한 적 없음)와 `gone`(요청했고 404/410을 받음)은 별개의 판정 |
| `intercept_list` / `intercept_get` | 라이브 인터셉트 큐와 홀드된 항목 하나의 전체 내용 조회 |
| `list_projects` | 이 호스트에서 프로젝트 **찾기**. 최근 활동순 **한 페이지**를 돌려줍니다. `query`는 표시 이름·디렉터리 슬러그·짧은 id·바인딩된 워크스페이스 경로에 포함되는지로 걸러내고, `limit`/`offset`으로 페이지를 넘깁니다(기본 50, 최대 500). 현재 서빙 중인 프로젝트는 페이지와 별개로 `current_project`에 실리므로 좁힌 목록에서도 "지금 어느 프로젝트인가"에 답할 수 있고, `total` 옆의 `total_projects` 덕분에 매치 0건이 "프로젝트가 하나도 없다"로 읽히지 않습니다 |
| `list_notes` / `get_note` | 프로젝트 노트 읽기 |
| `list_rule_presets` | 응답 수정 [프리셋](/ko/guide/proxy/#rewriter-presets). 평범한 Match & Replace 규칙을 설치하는 이름 붙은 출발점(hidden 필드 드러내기, disabled 컨트롤 활성화, `maxlength` 제거, 클라이언트 검증 제거, CSP / 보안 헤더 제거, SRI 비활성화). 각 행이 설치할 규칙을 밝힙니다 |
| `list_extract_rules` | 프로젝트의 **extract** 규칙. [세션 바인딩](/ko/guide/proxy/#session-bindings)의 읽는 쪽 절반. 각각 응답을 관찰해 `$BIND.NAME` 하나를 메모리에 묶고, Match & Replace 규칙이 그것을 주입합니다 |
| `list_color_rules` / `list_custom_colors` | [Colormarker](/ko/guide/proxy/#colouring-rows-colormarker-tab) 규칙을 우선순위 순으로, 그리고 규칙의 `color`가 참조할 수 있는 전역 커스텀 색상. 표시 전용이며 색상 규칙은 트래픽을 건드리지 않습니다 |
| `preview_color_rule` | 어떤 색상 조건이 최근 플로우 몇 개에 **매칭**되는지, 그리고 앞서 해소되는 규칙들을 셈한 뒤 실제로 몇 개를 **칠하는지**. 전역 후보는 모든 프로젝트 규칙보다 먼저 해석되므로 `scope`를 받습니다 |
| `grpc_schema` | 이 프로젝트가 캡처된 gRPC를 어떤 `.proto` 스키마로 렌더하는지, 각 조각이 어디서 왔는지(디스크립터 셋 파일 또는 리플렉션 페치). 리플렉션 목록에는 프로젝트에 저장된 모든 대상과, 이 서버가 가져왔지만 저장하지 못한 대상이 함께 나옵니다. 아무것도 보내지 않습니다 |
| `list_rules` | 프로젝트에 적용되는 Match & Replace 규칙을 적용 순서로 나열. 전역 규칙이 먼저, 그다음이 프로젝트 규칙(`scope`로 한쪽만 조회) |
| `list_env` | 치환에 쓰이는 프로젝트 env 토큰과 내장 생성기. 결과는 `{syntax, prefix, example, vars, generators}`입니다(env 값은 가려짐). 앞의 세 값은 참조를 어떻게 **적을지** 알려 줍니다. `syntax`는 이 설치의 문법(`namespaced`이면 `$ENV.KEY`, `$BIND.NAME`, `$GEN.UUID`; `bare`이면 생성기 없이 레거시 `$KEY`), `prefix`는 시길, `example`은 앞의 둘을 적용한 예시여서 기본이 아닌 시길도 조립할 필요가 없습니다. `vars`의 각 행은 bare 이름과 `length`, 값이 스킴으로 시작할 때의 `scheme`을 싣고, `generators`의 각 행은 완성된 토큰과 출력 형식을 싣습니다 |
| `list_host_overrides` | 이 프로젝트에 적용 중인 호스트 → IP 다이얼 맵 |
| `list_session_slots` | 프로젝트의 [세션 슬롯](/ko/guide/authorize/#session-slots-one-list-two-readers)(이름 붙은 신원 각각이 헤더 오버레이 하나와 그 값을 묶어 주는 extract 규칙들로 이루어집니다), 그리고 어느 쪽이 ACTIVE인지(헤더 값은 가려짐) |
| `list_oast_providers` | 설정된 OAST 프로바이더와 현재 활성 프로바이더 |
| `list_oast_sessions` | 프로젝트에 저장된 OAST 리스닝 세션. 페이로드 호스트, hit 수, 마지막 폴링 시각. `oast_resume`이 다시 살리는 행 |
| `decode` | `input`에 대해 인코드/디코드/해시/압축 체인을 실행(순수 변환; 네트워크나 상태 없음) |
| `jwt_decode` / `jwt_verify` / `jwt_encode` / `jwt_attacks` | JWT 디코드(JWS 또는 암호화된 JWE의 보호 헤더), 보유한 키로 서명 검증, HMAC이나 PEM 키로 재서명, 공격 페이로드 생성(순수 계산; `--read-only`에서도 사용 가능) |
| `cookie_decode` / `cookie_verify` / `cookie_crack` / `cookie_forge` | [Cookie 워크벤치](/ko/guide/cookie/)를 순수 오프라인 연산으로: Flask / Rack / Django 서명 세션 쿠키 파싱, 후보 시크릿으로 검증, 워드리스트로 시크릿 브루트포스, 편집한 페이로드 재서명. 네트워크를 쓰지 않으므로 네 개 모두 `--read-only`에서도 살아남습니다 |
| `sequence_analyze` | 붙여넣은 토큰 목록의 무작위성 / 예측 가능성 평가(순수) |
| `oast_presets` / `oast_payload` / `oast_poll` | OAST 프로바이더 나열, 세션(`session_id`)의 새 페이로드 URL 발급, 실행 중인 리스너의 콜백 폴링 |
| `project_info` | 플로우 / 이슈 개수, 캡처 구간, 프로젝트 `description`, 데이터베이스, 워크스페이스 바인딩, 선택 출처 |
| `get_current_context` | 사용자가 지금 TUI에서 보고 있는 것, **그리고 무엇을 선택했는지**. `selection.ids`는 History / Issues / Sitemap / Intercept에서 마크한 행이고, 마크가 없으면 커서 행, 디테일이 열려 있으면 거기 고정된 플로우입니다. `target_source`가 셋 중 무엇인지 말해 주므로 에이전트가 규칙을 다시 유도할 필요가 없습니다. Sitemap은 플로우 id가 아니라 `{host, path}` 쌍을 고르며 `kind`가 그걸 알려 줍니다. 배열이 잘렸다는 신호는 `truncated` 하나뿐입니다 — `marked_count`는 마크 집합을 말하는 값이라 드릴인이 그걸 덮어쓴 경우에도 그대로 실립니다. `marks_elsewhere`는 이 selection이 싣지 못한 마크가 어느 탭에 있는지를(`tab`과 개수, 그리고 그 마크에 kind가 있을 때만 `kind`), `tui.live`는 gori TUI 창이 붙어 있는지를 말합니다 — 증거이지 증명은 아닙니다. History 선택은 `list_history{ids}`에 그대로 넘기면 됩니다. 그 선택이 걸러진 History 렌즈(`query`, `view`, `scope_lens`, `hide_static`)도 함께 오므로, 에이전트가 사용자가 보는 목록을 그대로 나열할 수 있습니다 |
| `get_repeater_context` | Repeater 워크벤치 상태와 저장된 세션. 세션마다 id를 **둘 다** 싣습니다(모든 repeater 툴이 받는 `db_id`, 그리고 TUI가 서브탭 칩에 그리는 1-based 번호 `tui_index`(`6:POST /api`)). 그래서 에이전트와 사용자가 같은 탭을 같은 이름으로 부릅니다. `filter`는 TUI의 `/`와 같은 서브탭 문법(`tag:` `name:` `host:` `method:` `status:`, `-`는 부정, 맨 단어는 검색)이고 `query`와 AND로 묶입니다. `include_content`는 요청 헤드와 함께, 자격증명 헤더마다 비밀값 없이 배선만 밝히는 `env_headers` 모양(`Authorization: Bearer $ENV.AUTH`)을 줍니다. `include_response_body`는 저장된 마지막 응답 본문을 인라인합니다 |
| `list_fuzz_runs` / `get_fuzz_run` | 영구 Fuzzer 결과 집합을 나열하고 들여다봅니다. 지표는 `result_index`를 포함해 스칼라 전용 투영을 쓰므로 보관된 BLOB을 읽지 않습니다. `include_content:true`는 SQLite에서 상한이 걸린 접두 바이트로 최대 25행을 돌려줍니다. `max_head_bytes`(기본 16 KiB, 최대 64 KiB)가 헤드를, `max_body_bytes`(기본 2 KiB, 최대 64 KiB)가 디코딩된 본문/원시 표본을 제한합니다. 원본 전체 크기와 헤드/원본/디코딩 절단 플래그가 무엇이 빠졌는지 말해 주며, `include_sensitive:true`는 상한이 걸린 정확한 접두 바이트를 선택하는 것이지 무제한 바이트가 아닙니다. 현재 형식 이전 스냅숏은 실행 메타데이터에 `legacy:true`로 표시되고, `condition_met` 실행은 `stop_on`이 걸린 결과를 `stop_index`로 밝힙니다 — 그대로 `result_index`로 넘기면 됩니다(기록되지 않았으면 null이며, `fuzz_status`도 같은 필드를 실시간으로 보고합니다) |
| `ql_reference` | 쿼리 언어 레퍼런스 |
| `ql_explain` | 쿼리를 실행하지 않고 진단. 요청을 쓰기 전에 필터를 점검할 때 사용 |

**액션 도구**(`--read-only`로 비활성화됨. 단, `switch_project`는 항상 동작하고 `create_project`는 서버가 언바운드일 때 동작합니다). 소켓을 여는 도구(`send_request`, `send_websocket`, `fuzz_*`, `mine_*`, `authorize_*`, `cache_deception_check`, `sequence_*`, `discover_*`, `grpc_reflect`, `minimize_repeater`, `race_requests`, `timing_requests`, `run_retest`, `refresh_session_slot`, 그리고 `active:true`를 준 `probe_scan`)는 모두 스코프 게이트를 지납니다. 설정된 스코프 밖의 대상, 또는 스코프가 없는 대상은 호출에 명시적 예외 선언인 `allow_unscoped:true`를 주지 않는 한 `SCOPE_BLOCKED`로 거부되며, 그때도 샌드박스와 명시적 제외 규칙은 그대로 적용됩니다.

| 도구 | 용도 |
|------|---------|
| `send_request` | HTTP 요청 전송 / 재전송(액티브; 기본적으로 History에 기록, `$ENV.KEY` 환경 토큰과 `$BIND.NAME` 바인딩을 확장, 명시적으로 요청하지 않는 한 민감한 응답 헤더 값을 가림). `reframe_grpc: true`는 실제 전송되는 본문에 맞춰 단항 gRPC 메시지의 5바이트 길이 접두사를 다시 계산합니다. 기본값은 꺼짐이므로 편집된 메시지도 캡처 당시의 접두사 그대로 나갑니다 |
| `send_websocket` | 저장된 WebSocket Repeater 세션을 실행하고 응답을 수집 |
| `race_requests` | 저장된 HTTP Repeater 세션 둘 이상(`repeater_ids`)을 하나의 동기화된 레이스로 발사: HTTP/1.1 last-byte sync, 또는 `http2:true`로 HTTP/2 single-packet 공격. 모든 멤버는 같은 오리진과 전송을 공유해야 하며, 결과에 멤버별 타이밍이 담깁니다 |
| `timing_requests` | 저장된 HTTP Repeater 세션 정확히 두 개(`repeater_ids`)의 차등 타이밍 분석: A/B 쌍을 `count`번 보내(동기화된 single-packet/last-byte 레이스, 또는 `interleaved:true`) 판정(`a_slower` / `b_slower` / `no_difference` / `inconclusive`)과 순서 편향 비율, 이항 p-값, 변형별 사분위수를 돌려줍니다 — 단일 숫자가 아닙니다 |
| `create_repeater` / `update_repeater` / `delete_repeater` | Repeater 세션 하나를 관리. 모든 응답이 `id` 옆에 `tui_index`를 싣고, 삭제는 없앤 탭 번호(`was_tui_index`)를 밝힌 뒤 나머지를 다시 번호 매깁니다. `create_repeater{curl}`은 복사한 curl 명령으로 세션을 만듭니다 |
| `create_repeaters` | 캡처된 flow 여러 개에서 탭을 하나씩 시드합니다. OpenAPI 임포트의 두 번째 단계입니다(아래 참고). 첫 세션을 만들기 전에 모든 flow의 존재를 확인합니다 |
| `delete_repeaters` / `update_repeaters` | 일괄 닫기, 일괄 재라벨(태그와 이름 접사만. 요청 바이트를 쓰는 건 `update_repeater`입니다). 둘 다 필터가 아니라 명시적 id만 받습니다: 먼저 `get_repeater_context{filter}`로 좁혀서, 읽은 집합과 작용한 집합이 같게. 삭제는 `confirm:true`가 필요하고, 모르는 id 하나면 호출 전체를 거절합니다 |
| `move_repeater` | 서브탭 스트립을 재배치합니다. 절대 탭 번호는 `to_index`, 한 칸 이동은 `direction`. 열려 있는 TUI가 알아서 새 순서를 반영합니다 |
| `minimize_repeater` | Repeater 요청을 같은 응답이 재현되는 최소 형태로 줄임 |
| `create_issue` / `update_issue` / `delete_issue` | 이슈 기록, 갱신, 삭제 |
| `add_link` / `remove_link` | 이슈나 노트의 증거 포인터 연결 / 해제 |
| `freeze_evidence` / `link_evidence` / `unlink_evidence` / `delete_evidence` | 플로우나 Repeater 탭의 *현재* 교환을 이슈의 변경 불가 증거로 복사(다음 전송과 보존 정리가 건드리지 못함. 기본값 `link:true`는 live 링크도 같은 트랜잭션에 기록)하고, 스냅샷을 바꾸지 않은 채 이슈 연결을 변경하거나 사본 하나를 삭제. 응답이 취약점을 확인해 줄 때 동결하고 재테스트 뒤에 다시 동결하세요. 저장된 응답이 도착한 뒤 요청이 수정된 탭은 거부됩니다 — 둘은 한 교환이 아니므로 다시 보내거나 `allow_drift:true`로 어긋난 쌍을 그대로 남기세요 |
| `add_retest_step` / `update_retest_step` / `move_retest_step` / `remove_retest_step` | 리테스트 구성: Repeater 세션, 역할(`setup` / `baseline` / `variant` / `control` / `cleanup`), 그리고 기대 결과 하나(`status:2xx`, `json:data.role=admin`, `json-absent:…`, `body:same` / `body:diff`). 세션은 복사되지 않으며, 단계는 실행 시점에 탭이 들고 있는 요청을 그대로 보냅니다 |
| `run_retest` | 프로젝트 스코프와 Sandbox 게이트를 거쳐 실행하고 `pass` / `fail` / `inconclusive` / `blocked` 판정과 단계별 행을 반환합니다(`pass`가 아니면 `isError`). 상태를 바꾸는 메서드가 포함된 배치는 정확한 요청 수와 함께 거부되며 `confirm:true`가 필요합니다. gori가 전송을 거부하면 그 뒤는 모두 건너뛰고 cleanup도 `allow_cleanup:true` 없이는 보내지 않습니다. 모든 전송은 History에 `src:retest`로 기록됩니다 |
| `clear_retest_steps` / `delete_retest_run` | Issue 리테스트의 모든 단계를 지우거나(실행 기록은 유지 — 검사를 다시 짠다고 실행이 없던 일이 되지는 않습니다), 실행 요약과 결과 행 하나를 지웁니다. 단계와 각 전송이 기록한 History 플로우는 그대로 남습니다: `delete_retest_run`이 지우는 것은 보고이지 증거가 아닙니다 |
| `create_note` / `update_note` / `delete_note` | 프로젝트 노트 관리 |
| `create_rule` / `update_rule` / `set_rule_enabled` / `delete_rule` | Match & Replace 규칙 생성, 편집, 토글, 삭제(오가는 요청/응답의 헤드 또는 본문을 그 자리에서 재작성). 각각 `scope`를 받습니다: `project`(기본값) 또는 모든 프로젝트에 적용되는 `global`. `short_circuit` 규칙은 [모킹](/ko/guide/proxy/#mocking) 인자도 받습니다: `dir`/`strip_prefix`/`fallthrough`, `fault`/`hang_ms`, `delay_ms`, 그리고 캡처된 응답으로 초안을 잡는 `from_flow_id` |
| `create_rule_from_preset` | 프리셋(`list_rule_presets` 참고)을 평범한 Match & Replace 규칙으로 설치. 규칙마다 `create_rule`을 한 번씩 부른 것과 같은 결과라, 설치 후에도 보이고 편집·비활성화됩니다. 생성된 id를 반환 |
| `create_extract_rule` / `update_extract_rule` / `set_extract_rule_enabled` / `delete_extract_rule` | 응답에서 `$BIND.NAME`을 묶는 extract 규칙 관리. 이름을 바꾸면 옛 이름에 묶인 값은 라벨만 갈아 끼우는 게 아니라 버려지고, 비활성화하면 이름 자체가 **선언 해제**되어 그것을 주입하던 규칙이 낡은 값을 보내는 대신 다시 거부합니다 |
| `create_color_rule` / `update_color_rule` / `set_color_rule_enabled` / `move_color_rule` / `delete_color_rule` | Colormarker 규칙 관리. `move_color_rule`은 겉모습이 아니라 의미의 편집입니다. 활성화된 첫 매칭이 그 행을 칠합니다. 각각 `scope`를 받습니다(`project` 기본값 또는 `global`) |
| `create_custom_color` / `update_custom_color` / `delete_custom_color` | 기본 6색 위에 피커가 제공하는 전역 커스텀 색상 정의. 하나를 지워도 그것을 이름으로 쓰던 규칙은 삭제가 전파되지 않고 무해하게 남으며, 그 행들은 보이는 기본값으로 떨어집니다 |
| `grpc_reflect` / `grpc_forget` | 대상의 `grpc.reflection.v1`(없으면 `v1alpha`)에 디스크립터를 요청해 프로젝트에 캐시하거나, 캐시된 대상을 버립니다. `grpc_reflect`는 아웃바운드 전송이므로 다른 것들과 똑같이 스코프 게이트를 지납니다. `persisted: false`는 쓰기가 커밋되지 않았다는 뜻입니다(다른 gori가 라이터를 쥐고 있음). 리플렉션으로 가져온 스키마는 이 서버가 끝날 때까지 적용되고, `grpc_schema`에 나오며 `grpc_forget`으로 버릴 수 있습니다. 커밋되지 않은 forget은 이 서버가 그 대상으로 렌더하는 것만 멈추고 저장된 행은 남으므로, `grpc_schema`에는 계속 나옵니다 |
| `create_view` / `update_view` / `delete_view` | 저장된 History [뷰](/ko/guide/proxy/#views) 생성, 편집, 스코프 이동, 삭제. 각각 `scope`를 받습니다: `project`(기본값) 또는 `global`. 쿼리는 들어올 때 검사합니다. 모든 항이 버려질 쿼리는 거절하는데, 아무것도 좁히지 못하면서 모든 표면의 칩은 좁히고 있다고 주장하게 되기 때문입니다 |
| `preview_rule` | 규칙을 만들기 전에, 저장된 플로우 중 몇 개가 바뀌었을지 추정 |
| `import_flows` | HAR / URL 목록 / OpenAPI / Postman / Insomnia / Burp / WSDL 파일, 또는 curl 명령(`kind: "curl"`, 파일이나 `text`로)을 History로 일괄 임포트 |
| `delete_flow` / `clear_history` | 플로우 하나 삭제, 또는 캡처된 History 전체 삭제 |
| `set_sitemap_tag` | Sitemap 경로에 자유 형식 메모 고정 |
| `create_project` / `switch_project` / `delete_project` | 프로젝트 생성 또는 다시 열기, 이 서버를 다른 프로젝트로 전환, 프로젝트 삭제. 삭제는 2단계로, `dry_run` 후 확인 토큰 필요 |
| `export_project` / `import_project` | 프로젝트를 이식 가능한 [`.gori` 아카이브](/ko/guide/proxy/#project-archives)로 쓰거나, 아카이브를 새 프로젝트로 가져옵니다. `gori run project export` / `import`와 같은 엔진을 씁니다. 두 경로 모두 MCP 서버의 파일시스템 기준입니다. 내보내기는 `project`로 다른 프로젝트를 지정하지 않으면 바인딩된 프로젝트를 쓰고, `overwrite:true` 없이는 기존 파일을, gori 홈 디렉터리 안의 경로는 항상 거부하며, 결과에 아카이브가 마스킹되지 않았다고 밝힙니다. 가져오기는 `confirm:true` 전까지 아카이브의 인벤토리, 공개 문구, 이름 사용 가능 여부를 담아 `CONFIRM_REQUIRED`로 답하고, 같은 가져오기 안전 조치(실행형·파일 기반 규칙 비활성화, 프로젝트 라우팅·전역 규칙 오버라이드·Probe 모드·슬롯 자동 갱신 초기화, 2 GiB 상한)를 적용하며, 새 프로젝트로 전환하지는 않습니다 |
| `add_scope_rule` / `update_scope_rule` / `delete_scope_rule` / `set_scope_enabled` | 프로젝트의 include / exclude 규칙 편집과 스코프 렌즈 토글 |
| `set_sandbox` | 하드 컨테인먼트. 켜면 프록시가 스코프가 허용한 것만 전달하고 나머지는 차단 |
| `set_env_var` / `delete_env_var` | 치환이 읽는 프로젝트 env 토큰 관리. 키는 bare로 저장되며, 참조는 `$ENV.KEY`로, `bare` 옵트아웃에서는 `$KEY`로 씁니다. 이 설치가 어느 쪽인지는 `list_env`의 `syntax` / `example`이 말해 줍니다 |
| `create_session_slot` / `update_session_slot` / `delete_session_slot` | 세션 슬롯 관리. Authorize 탭의 identities 카드가 편집하는 바로 그 목록이고, `authorize_start`가 재생하는 집합입니다. `refresh`(Repeater 세션 id, 실행 순서대로)와 `refresh_before`(`off`, `jwt-exp`, `ttl=10m`)로 슬롯에 [갱신 단계](/ko/guide/authorize/#refreshing-a-slot)를 붙입니다 |
| `refresh_session_slot` | 슬롯의 갱신 단계를 지금 실행해 extract 규칙이 슬롯을 다시 바인딩하게 합니다. `ok`, 실패한 단계와 상태 코드, 다시 바인딩된 바인딩 **이름**을 돌려주며 값은 돌려주지 않습니다. 단계는 History(source `refresh`)에 기록됩니다. `send_request`처럼 제한되고(`allow_unscoped`), 단계의 업스트림 TLS 검증도 `send_request`와 같이 합니다(`--insecure-upstream`). 값은 이 서버 프로세스에만 있습니다 |
| `set_active_session_slot` | 모든 아웃바운드 요청이 어느 신원으로 나갈지 선택합니다. 그 슬롯의 헤더 오버레이가 최종 와이어 바이트에 적용되고 `$BIND.NAME`은 그 바인딩 테이블에서 해소됩니다. 이 서버 프로세스만 들고 있고 저장되지 않으므로, 새 연결은 캡처된 그대로 시작합니다 |
| `add_host_override` / `update_host_override` / `delete_host_override` | 호스트 → IP 다이얼 맵 관리(요청은 그대로 두고 접속 IP만 변경) |
| `probe_promote` / `probe_dismiss` / `probe_delete` | Probe 발견 항목을 Issues로 승격, 기각, 또는 삭제. `probe_dismiss`는 `id`(그 항목 하나를 dismissed ⇄ open으로 토글), `code`, `host`(같은 값을 가진 open 항목 모두 기각) 중 정확히 하나를 받습니다. 기각이 반영되지 않으면 `PROJECT_BUSY`로 답하고 항목은 그대로 둡니다 |
| `set_probe_mode` | 스캔 모드 설정: `off`, `passive`, `active`, `aggressive`(허가된 대상 전용) |
| `create_probe_rule` / `update_probe_rule` / `delete_probe_rule` / `set_probe_rule_enabled` | 커스텀 매치 규칙 관리와 스캔 규칙 활성화 / 비활성화 |
| `create_oast_provider` / `update_oast_provider` / `delete_oast_provider` / `set_oast_provider_enabled` | `oast_start`가 사용할 OAST 프로바이더 관리 |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Fuzzer 구동. `save_results:true`는 바이트 상한이 걸린 비동기 기록자를 통해 **모든** 행을 영구 저장하고 데이터베이스 `run_id`를 돌려줍니다. 저장소 백프레셔가 걸리면 나가는 트래픽은 멈추지 않고 저장만 실패로 표시됩니다. 이것은 상한이 걸린 선택적 라이브 잡 캐시나 `record_history`와는 별개입니다. `fuzz_start{fields: ["role"]}`는 단항 요청의 **스키마가 아는 gRPC 필드**를 스윕합니다. 페이로드는 필드 선언을 거쳐 바이트가 되고, 메시지의 나머지 바이트는 캡처에서 그대로 복사되며, 길이 접두사가 따라옵니다. 바이트 위치를 쓰는 gRPC 스윕에서 페이로드가 메시지 길이를 바꾸면 `grpc_stale_prefix`로 보고하며, `fuzz_start{reframe_grpc: true}`는 보고 대신 접두사를 다시 계산합니다. `fuzz_results`는 매치되지 않았어도 런이 관찰한 사실이 있는 행(재전송이나 리트라이된 요청, 잘린 응답, 실패한 전송, 실행되지 못해 페이로드가 변환 없이 나간 `¦chain` 스텝)을 함께 보관하므로 각 행의 `matched`를 읽거나 `matched_only: true`를 넘기세요. `stop_on`은 매처가 N번 맞았을 때(`after_matches`) 또는 별도의 `match` / `filter` 조건이 성립할 때 실행을 일찍 끝내며 상태는 `condition_met`입니다. `keep: "interesting"`은 `save_results` 보관본에 매치된 행과 오류·재전송·잘린 캡처처럼 관찰된 사실이 있는 행만 남깁니다 |
| `delete_fuzz_run` | 영구 퍼즈 실행 하나와 그 결과를 삭제합니다. 살아 있는 기록자가 확인되면 거부합니다. `force_stale:true`는 죽은 프로세스가 남긴 `running`/`saving` 행을 지우며, 다른 gori가 저장 중일 때는 절대 쓰면 안 됩니다 |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Param Miner 구동. `names`로 준 이름은 내장 목록과 워드리스트보다 먼저 시험합니다(예: 같은 호스트의 다른 엔드포인트에서 `list_params`가 본 이름) |
| `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop` | 라이브 리플레이로 토큰을 수집해 평가(결과는 리포트만 반환, 토큰은 반환하지 않음) |
| `authorize_start` / `authorize_status` / `authorize_results` / `authorize_stop` | 캡처된 플로우를 여러 아이덴티티로 재전송하고 각 응답을 기준선과 비교합니다(접근 제어 결함). 결과는 `access_control`(`BYPASS`/`enforced`/`review`/`error`/`nothing_sent`)과 페이징 없는 `bypasses` 목록으로 시작합니다 |
| `cache_deception_check` | 플로우 하나를 웹 캐시 디셉션으로 검사합니다: 캡처된(인증된) 아이덴티티로 재전송하고, 세션 없이 같은 url을 다시 요청한 뒤 캐시 무효화 익명 제어 요청을 보냅니다. 제어 응답이 일치하고 캐시 히트 신호가 없을 때만 `served`로 판정합니다. 제어 응답도 캐시 히트라면 쿼리가 무시됐을 수 있어 `review`이며, 익명 응답은 캐시 히트이고 제어 응답은 다르면 디셉션 가능성(`cached`)이 있습니다. 동기 방식으로 최대 세 번 전송합니다. 각 시도의 `cache`는 해당 응답 상태이고 최상위 `cache`는 익명 응답 상태입니다. 트리거되는 조작된 경로를 찾으려면 Fuzzer의 `cache-delimiters` 페이로드 세트와 함께 쓰세요 |
| `discover_start` / `discover_status` / `discover_results` / `discover_stop` | 엔드포인트 스파이더링 & 브루트포스, 진행 상황 폴링, 결과 조회. 네 개 모두 액션 도구이므로 읽기 전용 서버에는 Discover 표면이 없습니다 |
| `oast_start` / `oast_stop` | OAST 페이로드 등록 후 콜백 폴링: 기본은 공개 interactsh 서버, `provider_id`로 저장된 프로바이더, `persist:true`로 재개 가능한 세션(`oast_poll`로 히트 조회). 재개한 세션에 `oast_stop`을 쓰면 폴링만 멈추고 세션은 다시 재개할 수 있게 남습니다 |
| `oast_resume` / `oast_release` | 저장된 세션을 다시 살려 이전에 심어둔 페이로드가 계속 resolve되게 하고(폴링 결과는 프로젝트에 저장됩니다), 끝난 engagement는 등록 해제합니다. 콜백은 남습니다 |
| `list_jobs` / `get_job` / `stop_job` | 작업 종류를 가로질러 처리: 이번 세션이 시작한 모든 fuzz, mine, discover, sequence, authorize 작업 나열, 또는 id로 하나를 조회하고 중지 |
| `intercept_forward` / `intercept_forward_edit` / `intercept_drop` | 홀드된 메시지를 바이트 그대로 내보내거나, 수정한 와이어 바이트로 내보내거나, 드롭 |
| `intercept_toggle` / `intercept_set_filter` / `intercept_set_direction` | 캐치 활성화 및 해제, 조건 쿼리 설정, 홀드할 방향 선택 |

> 액션 도구는 안전을 위해 상한이 있습니다: fuzz, mine, sequence, discover, authorize 작업은 총 요청 수, 동시성, 저장 결과 수가 제한됩니다. authorize의 상한은 `플로우 × 아이덴티티`를 세며, 상한을 넘는 선택은 잘라서 실행하는 대신 시작 전에 거부됩니다. 잘린 실행은 보내지도 않은 플로우를 "enforced"로 보고하게 되기 때문입니다. `create_rule`로 생성된 규칙은 `gori run`과 새로 열린 TUI에 적용됩니다. 이미 실행 중인 TUI는 규칙을 다시 로드한 뒤에만 적용합니다.

## 스펙에서 Repeater 탭으로 {#from-a-spec-to-repeater-tabs}

`import_flows`는 OpenAPI/Swagger(JSON·YAML)를 읽고 `servers[0].url`을 각 오퍼레이션 경로와 합쳐 줍니다. 베이스 경로를 손으로 붙일 일이 없다는 뜻이고, 스펙에서 탭 한 줄까지는 호출 세 번입니다.

```
import_flows{kind: "oas", path: "openapi.yaml"}
list_history{query: "src:import"}          → flow id들
create_repeaters{flow_ids: [...], name_prefix: "oas: ", tags: "spec"}
```

`create_repeaters`는 첫 세션을 만들기 전에 모든 flow의 존재를 확인하고, `create_repeater{flow_id}` 하나가 쓰는 것과 같은 경로로 각각을 시드한 뒤, 준 순서대로 덧붙입니다. 순서는 `move_repeater`로 바꾸고, 정리는 `delete_repeaters`로 합니다.

## 라이브 인터셉트 {#live-intercept}

에이전트가 나중에 History를 읽는 대신, 인터셉트 루프 안에 나란히 앉을 수 있습니다. 캡처 락을 쥔 TUI 세션이 홀드된 메시지를 에이전트 쪽으로 미러링하고 에이전트가 보낸 명령을 받아 처리하므로, `intercept_list` → `intercept_get` → `intercept_forward_edit`은 직접 손으로 도는 것과 같은 루프입니다.

변경을 일으키는 쪽(`intercept_forward`, `intercept_forward_edit`, `intercept_drop`, `intercept_toggle`, `intercept_set_filter`, `intercept_set_direction`)은 `--read-only`에서 비활성화되며, 라이브 캡처 세션이 락을 쥐고 있지 않으면 모두 거부합니다. 프록시가 실제로 트래픽을 홀드하고 있지 않으면 내보낼 것 자체가 없기 때문입니다.

에이전트의 행동은 조용히 지나가지 않고 드러납니다. 각 행동은 에이전트에서 온 것으로 표시되어 알림 센터에 남고 사용자 본인의 행동과 다르게 렌더링되므로, 다른 탭을 보는 동안 코파일럿이 트래픽에 무엇을 했는지 확인할 수 있습니다.

반대 방향도 마찬가지입니다. `intercept_list`가 `operator_editing: true`로 돌려주는 행은 지금 사용자가 편집 중인, 아직 저장하지 않은 내용이 들어 있는 메시지입니다. 에이전트는 포워드·편집·드롭으로 그 작업을 지워버리는 대신 사용자에게 남겨둘 수 있습니다.

에이전트를 켜둔 채 자리를 뜨기 전에 알아둘 안전 규칙이 하나 있습니다. 홀드된 메시지는 원래 사람의 결정을 무한히 기다립니다. 키보드 앞에 사람만 있을 때는 그게 맞는 동작입니다. 하지만 해당 세션에서 에이전트가 인터셉트 큐에 붙고 나면, gori는 아무도 보고 있지 않은 항목에 대해 30초 자동 포워드를 켭니다. 홀드 도중 죽은 클라이언트가 연결을 영영 막아버리지 못하게 하기 위해서입니다. 에이전트가 붙지 않은 세션은 자동 포워드를 하지 않습니다.

## gori가 보내는 메시지 {#messages-from-gori}

라이브 인터셉트가 에이전트더러 사용자가 일하는 모습을 지켜보게 한다면, 팔레트 verb **"Tell the agent…"**(`app.tell-agent`)는 반대 방향입니다 — 어느 gori 탭에서든 붙어 있는 에이전트 자신의 세션으로 한 줄짜리 메시지를 보냅니다. 프로젝트에 붙은 MCP 클라이언트 중 하나(`mcp:` 칩과 "Attached agents" 카드가 보여주는 것과 같은 목록)를 고르거나 전체를 고르고, 한 줄을 입력하면 gori가 전달합니다. "Attached agents" 카드에서 바로 `t`를 누르면 커서가 놓인 에이전트에게 곧장 메시지를 보냅니다. History 목록에서 행을 마크한 채 보내면 그 flow들이 문맥으로 함께 실려, 에이전트가 여러분이 고른 바로 그 대상에 대해 움직일 수 있습니다.

전달은 다섯 층을 **확인 가능한 순서대로** 시도합니다 — 결과를 되돌려 주는 경로가 그러지 못하는 경로보다 먼저이고, 먼저 답한 층에서 사슬이 끝나므로 한 메시지가 두 번 실려 나가는 일은 없습니다.

1. **Inbox socket** — 대상이 Claude Code라면 `gori mcp`가 그 세션의 inbox socket(`/tmp/cc-socks/<pid>.sock`, 클라이언트 프로세스에서 부모 쪽으로 거슬러 올라가 찾습니다)에 메시지를 씁니다. 이 경로는 GA입니다 — 플래그도, opt-in도 필요 없습니다. 메시지는 다른 세션이 보낸 노트로 프레이밍되어 `[gori] The operator at the gori TUI says:` 접두어를 달고 도착합니다. idle 세션은 그 위에서 turn을 시작하고, 바쁜 세션은 tool call 사이사이에 읽습니다. 받아들일지, 나중으로 보류할지, 아예 거절할지는 Claude Code 자신의 `crossSessionInbound` 설정이 정하며, gori는 어느 쪽이든 socket에 쓸 뿐 셋 중 무엇이 일어났는지는 볼 수 없습니다. 파일은 있는데 연결을 거절하는 소켓은 이미 끝난 세션이 남긴 찌꺼기입니다 — `/tmp/cc-socks/<pid>.sock`은 그것을 만든 프로세스보다 오래 남고 pid는 재사용됩니다 — 그래서 gori는 아무도 없는 문 앞에 멈추는 대신 다음 층으로 넘어갑니다.
2. **Codex queue** — 대상이 Codex라면 `gori mcp`가 그 세션 자신의 thread에 `codex queue --thread <id> --message …`로 한 줄을 건넵니다. 세션은 그 위에서 turn을 돌립니다 — idle이면 즉시, 바쁘면 지금 turn이 끝난 뒤에. Codex는 MCP 서버에게 자기 자신에 대해 아무것도 알려주지 않으므로, gori는 Codex 프로세스가 열어 둔 writer lock(`<CODEX_HOME>/thread-writer-locks/<thread>.lock`)에서 thread를 읽습니다. 이 경로 하나가 thread id와 queue를 넣을 `CODEX_HOME`을 동시에 알려주므로, 자기만의 `CODEX_HOME`으로 띄운 세션에도 닿습니다. GA이고 플래그가 필요 없습니다. 아직 turn을 한 번도 돌리지 않은 thread는 rollout이 없어 `codex queue`가 거절하는데, 그 이유는 delivery 행에 남고 메시지는 4·5번 층으로 계속 읽힙니다.
3. **Channel** — Settings의 `mcp.channels`가 켜져 있고 *위의 두 문이 모두 답하지 않았을 때* `gori mcp`가 `claude/channel` capability를 선언하고 메시지를 channel event로 push합니다. Claude Code는 이를 `← gori: …`로 보여주고, 세션이 idle이 되는 즉시 그 위에서 turn을 시작합니다 — 그래서 모델은 이것을 그냥 지나가는 메모가 아니라 지시로 읽습니다. 이 경로는 Claude Code를 `claude --dangerously-load-development-channels server:gori`로 띄워야 동작하는데, 이는 research-preview 플래그로 클라이언트 쪽에 한 번짜리 확인 대화상자가 뜨고, 이 플래그가 함께 갖고 오는 `--channels` 허용 목록은 gori가 아니라 Anthropic이 정한 것입니다. **기본은 off**이고, 처음이 아니라 **마지막**으로 시도하는 경로입니다. channel을 등록한 적 없는 세션으로의 push는 조용히 버려지고 gori는 그것을 알 방법이 없습니다. 그래서 이 경로가 먼저였을 때는, 플래그 없이 띄운 Claude Code 세션에서 이 설정이 정작 그 세션을 깨우는 유일한 경로인 inbox socket을 빼앗아 갔습니다. 한 메시지가 두 경로를 타는 일은 없습니다 — 먼저 답한 층에서 사슬이 끝납니다. 대신 push가 치르는 비용은 *두 번 읽힐 수 있다*는 것입니다. 확인된 전달이 아니므로 메시지는 4·5번 층에 계속 남습니다. 실제 테스트에서 Opus 5의 세이프가드가 채널로 주입된 메시지를 내용과 무관하게 플래그해 모델 전환 대화상자에서 세션을 멈추는 것도 확인했습니다. 아래 소켓 경로는 걸리지 않습니다. 시험할 때가 아니면 채널은 꺼 두세요.
4. **Tool result** — 클라이언트가 무엇이든, 위 층들이 싣지 못한 메시지가 **에이전트가 다음에 부르는 gori 도구의 결과**에 실려 돌아갑니다. 어떤 도구였든 상관없이, 그 도구 자신의 답 옆에 오퍼레이터의 한 줄이 두 번째 content 블록으로 붙습니다. GA이고 플래그도 없으며, 모델이 무언가를 기억할 필요도 없습니다 — 그게 핵심입니다. 위의 세 층은 각각 특정 벤더의 문입니다(inbox socket은 Claude Code, `codex queue`는 Codex, channel은 Claude Code의 프리뷰). grok·Pi·Hermes·Antigravity·Claude Desktop에는 그런 문이 아예 없으므로, 이 층이 "메시지가 피드에 있다"를 "메시지가 모델 눈앞에 있다"로 바꿔 줍니다. 놀고 있는 에이전트를 깨우지는 못하지만(이 층에서 가능한 일이 아닙니다) 그 에이전트가 gori에게 무엇이든 묻는 순간 답 안에 그 줄이 들어 있습니다. socket과 마찬가지로 확인된 전달이라, 클라이언트가 요청한 결과를 실제로 받아 갔으므로 메시지는 5번 층에서 은퇴합니다. `--read-only` 서버는 이를 기록할 writer가 없으므로, 줄은 보내되 행은 계속 읽히도록 남겨 둡니다.
5. **Poll** — 항상 쓸 수 있는, 위 모든 층의 백스톱입니다. 메시지는 프로젝트 이벤트 피드의 한 행이 되고, MCP 도구 `operator_messages`가 호출한 세션에 남아 있는 메시지를 돌려줍니다. 핸드셰이크 `instructions`가 모델에게 turn을 시작할 때 이를 확인하라고 알려주므로, 자기 instructions를 읽는 에이전트라면 socket도 queue도 channel도 없이 다음 호출에서 메시지를 집어갑니다. 다만 끼어들지는 못합니다 — 자기 프롬프트 앞에 가만히 있는 에이전트는 다음 turn이 시작될 때 비로소 메시지를 봅니다.

전달 시도마다 `agent_delivery` 행이 하나씩 기록되고, 탭을 옮기지 않아도 결과를 볼 수 있습니다. TUI의 알림 링이 `→ claude-code got it (socket)`, `→ codex-mcp-client got it (queued in codex)`, `→ grok-shell-gori got it (on its next tool result)`, `left for antigravity to pick up (operator_messages)`(에이전트가 읽으면 `→ antigravity picked it up`) 같은 문구나 전달이 실패한 이유를 보여주고, Companion(Miss Ring)을 켜 두었다면 같은 알림에 반응합니다. Activity 페인은 이 모두를 새로운 `operator` source 아래 나열하므로, 메시지와 그 전달 결과가 프로젝트에서 일어난 다른 모든 일과 함께 기록에 남습니다 — [Activity](/ko/guide/proxy/#project-tab) 참고.

돌아오는 길은 `reply_to_operator`입니다. 핸드셰이크 instructions가 에이전트에게, 여러분이 그 터미널로 옮겨가지 않고도 봐야 하는 것은 이 도구로 답하라고 알려줍니다. 한 줄 `summary`는 클라이언트 이름과 함께 링(그리고 Miss Ring)에 뜨고, `detail`은 링에서 `↵`로 열립니다 — 발견 사항, diff, 엔드포인트 목록 같은 것. 같은 피드의 행이라 Claude가 아닌 에이전트에서도 동작하고(`--read-only`로 띄운 에이전트는 제외), `agent` 소스로 프로젝트 기록에 남습니다.

의지하기 전에 알아둘 한계가 몇 가지 있습니다.

- **재전송되지 않습니다.** 메시지는 *보내는 그 순간* 붙어 있던 에이전트에게만 전달됩니다. 그 뒤에 붙은 에이전트는 소급해서 받지 않습니다 — `operator_messages`는 언제나 그 세션에 아직 남아 있는 것만 돌려주고, 이미 전달한 것을 두 번 전달하지 않습니다.
- **동의가 아니라 요청입니다.** 어느 층으로 가든, 피어가 프레이밍한 메시지는 모델에게 뭔가를 해 달라고 요청할 뿐 그 자체로 무언가를 승인하지 않으며, 에이전트는 자신이 동의하지 않는 다른 지시와 똑같이 이를 거절할 수 있습니다.
- **Channel 전달은 research preview입니다.** 아직 출시되지 않은 Claude Code 플래그와 Anthropic이 정한 허용 목록에 의존하며, 둘 다 `mcp.channels`가 모르는 사이 바뀔 수 있습니다 — inbox socket과 poll 도구가 따로 존재하는 이유는 그 플래그가 사라지는 날에도 기능이 계속 동작하게 하기 위해서입니다.

## 프로토콜 리비전 {#protocol-revisions}

gori는 한 프로세스에서 MCP의 두 시대를 모두 말하며, 어느 쪽으로 답할지는 요청 자체가 정합니다.

- **`2026-07-28`** — stateless 리비전입니다. 요청이 `_meta`에 프로토콜 버전과 클라이언트 capability, (선택적으로) 클라이언트 이름을 싣고 다니므로 열어야 할 핸드셰이크도, 놓칠 핸드셰이크도 없습니다. 결과에는 `resultType`, `_meta["io.modelcontextprotocol/serverInfo"]`의 서버 신원, 그리고 `tools/list`라면 클라이언트가 캐시 기준으로 삼는 `ttlMs` / `cacheScope` 힌트가 함께 옵니다. `server/discover`는 지원 버전·capability·instructions를 한 번의 호출로 답하며, 가장 먼저 보내도 됩니다.
- **`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`** — 핸드셰이크 리비전입니다. `initialize`는 예전 그대로 세션을 열고, 요청한 리비전으로 답합니다. 그 외에는 — gori가 모르는 버전이든, stateless 리비전이든 — 가장 최신 핸드셰이크 리비전으로 답합니다. `initialize`로 연 세션은 요청별 의미론으로 갈아탈 수 없으므로, stateless 버전을 답하는 것은 gori가 지킬 수 없는 약속이기 때문입니다.

gori가 말하지 않는 버전은 `-32022`와 함께 말할 수 있는 버전 목록으로 거절되므로, 클라이언트는 추측하는 대신 다시 시도할 수 있습니다. 도구 표면은 양쪽이 동일합니다. 시대가 정하는 것은 봉투이지, 도구가 하는 일이 아닙니다.

stateless 리비전에서 따라오는 두 가지는 클라이언트를 만들기 전에 알아둘 만합니다. `subscriptions/listen`은 응답하지만 빈 필터로 ack한 뒤 곧바로 정상 종료합니다 — gori는 푸시할 것이 없으므로 정직한 구독은 빈 구독이고, 대신 함께 받은 `ttlMs`를 쓰면 됩니다. 그리고 `claude/channel` research preview는 핸드셰이크 시대에만 선언합니다. stateless 서버가 stdout에 쓸 수 있는 것은 응답, 진행 중인 요청에 속한 알림, ack된 구독 스트림의 알림뿐인데 channel push는 그 셋 중 어느 것도 아니기 때문입니다. 운영자 메시지는 여전히 모든 클라이언트에 닿습니다 — 소켓, Codex 큐, 다음 tool result, `operator_messages` 모두 프로토콜 스트림을 건드리지 않습니다.

없는 도구 이름은 `isError` 도구 결과가 아니라 JSON-RPC `-32602`로 돌아옵니다. 스펙이 그렇게 정해둔 자리입니다. 호출이 도구에 닿지 못했으므로 모델이 인자를 고쳐 다시 시도할 거리가 없습니다. 반면 **실행되고 실패한** 도구는 지금처럼 `isError: true`와 구조화된 오류로 답합니다. 에이전트에게 돌려줘야 할 것은 그쪽입니다.

## 도구 힌트 {#tool-hints}

`tools/list`의 모든 도구는 `annotations.readOnlyHint`를 함께 싣습니다. 이 프로젝트의 캡처를 읽기만 하는 도구와, 캡처에 쓰거나 대상에 트래픽을 보내는 도구를 클라이언트가 구분할 수 있도록 — 즉 사람 확인 없이 돌려도 되는 호출과 물어봐야 하는 호출을 가르기 위해서입니다. 이 힌트는 [`--read-only`](#read-only-mode)가 강제하는 것과 같은 선언에서 유도되므로 힌트와 게이트가 서로 어긋날 수 없고, 둘이 다른 곳은 그 선언이 그렇게 정한 곳뿐입니다. 워크벤치 폴링 도구(`*_status`, `*_results`, `list_jobs`, `get_job`)와 `preview_rule`은 보고만 하므로 `--read-only`에서는 숨겨지지만 읽기 전용으로 표시됩니다. 반대로 `switch_project`, `create_project`, `probe_scan`(`active:true`면 전송함), `operator_messages`(전달 기록을 씀)는 `--read-only`에서도 남지만 읽기 전용으로 표시되지 않습니다. 읽기 전용 도구는 `openWorldHint: false`도 함께 답합니다. 프로젝트 스토어에서 답할 뿐 바깥으로 다이얼하지 않기 때문입니다.

## 한 번에 한 호출 {#one-call-at-a-time}

도구는 도착한 순서대로 하나씩 실행되고, 응답도 그 순서로 돌아옵니다. 퍼즈나 느린 `send_request`가 다음 호출과 겹치지 않습니다. 다만 두 메시지는 항상 즉시 응답합니다. `ping`은 클라이언트의 생존 확인이 긴 호출 뒤에 밀려 "서버가 죽었다"는 판정을 받지 않도록, `notifications/cancelled`는 더 이상 기다리지 않는 요청의 응답을 보내지 않도록 하기 위해서입니다. 취소는 이미 진행 중인 작업을 중단시키지는 않습니다. 그 요청은 끝까지 실행되고, 응답만 전송되지 않습니다.

## MCP 이음새인 이유 {#why-an-mcp-seam}

gori는 의도적으로 도구 내 AI 챗을 두지 않습니다. 지능은 도구 바깥, 곧 MCP로 접근할 수 있는 곳에 있습니다. 덕분에 모델을 직접 고를 수 있고, 트래픽이 의도치 않은 곳으로 흘러가지 않으며, 동일한 인터페이스가 스크립트와 에이전트 양쪽을 모두 지원합니다. [`gori run`](/ko/guide/scripting/)은 비대화형 경로를, MCP는 대화형 에이전트 경로를 담당합니다.

## 다음 단계 {#next-steps}

- [AI 설정](/ko/getting-started/ai-setup/): 에이전트를 연결하고 첫 요청을 구동하는 단계별 안내
- [Scripting](/ko/guide/scripting/): 또 하나의 자동화 경로. 파이프라인과 CI를 위한 `gori run`
- [CLI Reference](/ko/reference/cli/): 전체 `gori mcp` 플래그
- [Query Language](/ko/reference/query-language/): 에이전트가 필터링에 사용하는 문법
