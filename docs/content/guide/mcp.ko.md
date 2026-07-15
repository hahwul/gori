+++
title = "MCP 서버"
description = "Model Context Protocol을 통해 AI 에이전트나 스크립트로 gori를 구동합니다."
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
```

명시적 선택자가 없으면, gori는 가장 가까운 Git 루트를 찾아 그 정규 경로를 격리된 프로젝트에 바인딩합니다. 이 바인딩은 디렉터리 이름이 같은 두 리포지토리가 하나의 데이터베이스를 공유하는 것을 막습니다. 프로세스가 Git 워크스페이스 밖에 있으면, gori는 무관한 활성 프로젝트를 슬그머니 제공하지 않고 오류를 내며 멈춥니다. `--project`, `--db`, `GORI_MCP_PROJECT`, `GORI_MCP_DB`, 또는 명시적 옵트인인 `--use-active-project`를 전달하세요.

데이터를 사용하기 전에 `project_info`를 호출하세요. 선택된 프로젝트, 데이터베이스 경로, 워크스페이스 루트, 선택 출처를 보고합니다.

## 읽기 전용 모드 {#read-only-mode}

기본적으로 서버는 실시간 요청을 보내고 이슈를 기록하는 액션 도구도 노출합니다. 읽기 도구만 노출하려면(신뢰할 수 없는 에이전트에게 프로젝트를 넘길 때 안전합니다) 읽기 전용으로 시작하세요.

```bash
gori mcp --read-only
```

## 에이전트에 설치하기 {#installing-into-an-agent}

gori는 널리 쓰이는 클라이언트의 MCP 설정을 대신 작성해 줍니다.

| 플래그 | 클라이언트 | 작성되는 설정 |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

```bash
gori mcp --install-claude-code
gori mcp --install-codex
gori mcp --install-grok
```

Codex와 Grok은 JSON이 아니라 `[mcp_servers.gori]` 테이블이 있는 TOML을 사용합니다. 설치 후 클라이언트를 재시작하거나 세션을 다시 열어 MCP 서버를 다시 로드하세요.

클라이언트가 리포지토리 디렉터리 밖에서 MCP를 시작한다면, 설치를 프로젝트에 고정하세요. 예: `gori mcp --project my-engagement --install-codex`.

## 도구 {#tools}

**읽기 도구**(항상 사용 가능):

| 도구 | 용도 |
|------|---------|
| `list_history` | 최신순으로 플로우 나열, 선택적 QL과 페이지네이션 포함 |
| `get_flow` | 한 플로우의 전체 요청 + 응답 |
| `get_response_body_chunk` | 인라인 64 KiB 상한을 넘는 디코드(또는 원시) 플로우/Repeater 응답을 페이지 단위로 조회 |
| `list_sitemap` | 고유 엔드포인트(host, method, path) |
| `list_issues` / `get_issue` | 트리아지된 이슈 읽기 |
| `list_scope` | 현재 스코프 include/exclude 규칙 |
| `list_notes` / `get_note` | 프로젝트 노트 읽기 |
| `list_rules` | 프로젝트의 Match & Replace 규칙을 적용 순서로 나열 |
| `decode` | `input`에 대해 인코드/디코드/해시/압축 체인을 실행(순수 변환; 네트워크나 상태 없음) |
| `project_info` | 플로우 / 이슈 개수, 데이터베이스, 워크스페이스 바인딩, 선택 출처 |
| `get_current_context` | 사용자가 지금 TUI에서 보고 있는 것 |
| `get_repeater_context` | Repeater 워크벤치 상태와 저장된 세션 |
| `ql_reference` | 쿼리 언어 레퍼런스 |

**액션 도구**(`--read-only`로 비활성화됨):

| 도구 | 용도 |
|------|---------|
| `send_request` | HTTP 요청 전송 / 재전송(액티브; 기본적으로 History에 기록, `$KEY` 환경 토큰을 확장, 명시적으로 요청하지 않는 한 민감한 응답 헤더 값을 가림) |
| `create_repeater` / `update_repeater` / `delete_repeater` | Repeater 세션 관리 |
| `create_issue` / `update_issue` | 이슈 기록 및 갱신 |
| `create_note` / `update_note` / `delete_note` | 프로젝트 노트 관리 |
| `create_rule` / `set_rule_enabled` / `delete_rule` | Match & Replace 규칙 생성, 토글, 삭제(이동 중인 요청/응답 헤드 또는 본문에 대한 리터럴 재작성) |
| `fuzz_start` / `fuzz_status` / `fuzz_results` / `fuzz_stop` | Fuzzer 구동 |
| `mine_start` / `mine_status` / `mine_results` / `mine_stop` | Param Miner 구동 |

> 액션 도구는 안전을 위해 상한이 있습니다: fuzz와 mine 작업은 총 요청 수, 동시성, 저장 결과 수가 제한됩니다. `create_rule`로 생성된 규칙은 `gori run`과 새로 열린 TUI에 적용됩니다. 이미 실행 중인 TUI는 규칙을 다시 로드한 뒤에만 적용합니다.

## MCP 이음새인 이유 {#why-an-mcp-seam}

gori는 의도적으로 도구 내 AI 챗을 두지 않습니다. 지능은 도구 바깥, 곧 MCP로 접근할 수 있는 곳에 있습니다. 덕분에 모델을 직접 고를 수 있고, 트래픽이 의도치 않은 곳으로 흘러가지 않으며, 동일한 인터페이스가 스크립트와 에이전트 양쪽을 모두 지원합니다. `gori run`은 비대화형 경로를, MCP는 대화형 에이전트 경로를 담당합니다.

## 다음 단계 {#next-steps}

- [CLI Reference](/ko/reference/cli/): 전체 `gori mcp` 플래그
- [Query Language](/ko/reference/query-language/): 에이전트가 필터링에 사용하는 문법
