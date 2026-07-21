+++
title = "AI 설정"
description = "MCP로 AI 에이전트를 gori에 연결합니다: 클라이언트에 서버 설치, 프로젝트 고정, 그리고 첫 요청 구동."
weight = 30
+++

gori는 하나의 프로젝트와 하나의 엔진 위에 세 가지 진입점을 둡니다. `gori`(TUI, 당신을 위한 것), `gori run`(헤드리스 CLI, 스크립트를 위한 것), 그리고 `gori mcp`([MCP 서버](/ko/guide/mcp/), AI 에이전트를 위한 것)입니다. 이 페이지는 AI 경로를 다룹니다. 에이전트를 gori 프로젝트에 연결하고 첫 요청까지 구동합니다.

TUI 안에는 채팅 창이 없습니다. 모델과 클라이언트는 당신이 직접 가져오고, gori는 프로젝트를 깔끔한 도구 인터페이스로 노출합니다. 그러면 에이전트가 트래픽을 읽고 당신과 동일한 도구를 구동합니다. 전체 도구 목록과 더 깊은 주제(라이브 인터셉트, 설계 근거)는 [MCP 서버 가이드](/ko/guide/mcp/)를 참고하세요.

> **시작하기 전에.** [gori를 설치](/ko/getting-started/installation/)하고 MCP를 지원하는 클라이언트(Claude Code, Claude Desktop, OpenAI Codex, Antigravity, Grok 등)를 준비하세요.

## 1. 클라이언트에 서버 설치하기 {#1-install-the-server-into-your-client}

`gori mcp`는 stdio 위에서 JSON-RPC 2.0으로 통신합니다. AI 클라이언트가 이를 spawn 해 STDIN으로 요청을 보내고 STDOUT으로 결과를 읽습니다(STDERR은 로그를 전달합니다). 클라이언트마다 설정을 손으로 편집하는 대신, gori가 대신 작성하게 하세요.

```bash
gori mcp --install-claude-code   # Claude Code
gori mcp --install-claude        # Claude Desktop
gori mcp --install-codex         # OpenAI Codex
gori mcp --install-agy           # Antigravity CLI
gori mcp --install-grok          # Grok
```

| 플래그 | 클라이언트 | 작성되는 설정 |
|------|--------|----------------|
| `--install-claude` | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) |
| `--install-claude-code` | Claude Code | `~/.claude.json` (`mcpServers.gori`) |
| `--install-codex` | OpenAI Codex | `~/.codex/config.toml` (`[mcp_servers.gori]`) |
| `--install-agy` | Antigravity CLI | `~/.gemini/antigravity-cli/mcp_config.json` |
| `--install-grok` | Grok | `~/.grok/config.toml` (`[mcp_servers.gori]`) |

각 명령은 작성한 파일과 기록한 정확한 실행 명령을 출력합니다. Codex와 Grok은 JSON이 아니라 TOML `[mcp_servers.gori]` 테이블을 사용합니다. 설치 후에는 클라이언트를 재시작하거나 세션을 다시 열어 MCP 서버를 다시 로드하세요.

직접 연결하고 싶다면? 서버는 그저 stdio 위의 `gori mcp` 명령입니다. 추가 인자 없이 이 명령을 MCP 클라이언트에 가리키기만 하면 됩니다.

**체크포인트.** 클라이언트가 gori의 도구들(`list_history`, `send_request`, `project_info` 등)을 나열합니다. 나타나지 않으면 클라이언트를 재시작했는지, 그리고 `gori`가 클라이언트가 사용하는 `PATH`에 있는지 확인하세요.

## 2. 프로젝트 바인딩 (또는 에이전트가 고르게) {#2-pin-the-right-project}

각 gori 프로젝트는 별도의 데이터베이스입니다. 설치 후 `gori mcp`는 항상 연결됩니다.

| 클라이언트가 MCP를 띄우는 방식 | 동작 |
|-------------------------------|------|
| Git 리포지토리 안 | 그 워크스페이스를 자체 gori 프로젝트에 path-bind |
| Git 밖 (Desktop / 전역 에이전트에서 흔함) | **unbound**로 시작 — 핸드셰이크 성공; 에이전트가 트래픽 도구 전에 `list_projects` / `create_project` / `switch_project` 호출 |
| `--project` / `--db`로 설치 | 첫 도구 호출부터 그 프로젝트 제공 |

에이전트가 먼저 `project_info`를 호출하게 하세요. `bound`가 false이면 프로젝트를 나열·생성(unbound일 때 create는 자동 바인딩)하거나 switch 한 뒤, bound일 때 이름·DB 경로·선택 출처를 확인한 다음 데이터를 건드리게 합니다.

설치 시점에 고정 engagement를 박아 두려면:

```bash
gori mcp --project my-engagement --install-codex     # 이름 붙은 프로젝트의 데이터베이스
gori mcp --db /path/to/project.db --install-claude-code   # 특정 데이터베이스 파일
```

전체 선택 규칙은 [프로젝트 선택](/ko/guide/mcp/#choosing-a-project)에 있습니다.

## 3. 읽기 전용으로 안전하게 넘기기 {#3-hand-off-safely-with-read-only}

기본적으로 서버는 실시간 요청을 보내고 이슈를 기록하는 액션 도구도 노출합니다. 에이전트(또는 대상에 대해 완전히 신뢰하지는 않는 동료)에게 읽기 도구만 주려면, 읽기 전용으로 설치하세요.

```bash
gori mcp --read-only --install-claude-code
```

읽기 전용은 `list_history`, `get_flow`, `list_sitemap` 등 검사 도구를 유지하면서 `send_request`, 이슈 쓰기, 인터셉트 변경 도구를 비활성화합니다. `decode`, `jwt_decode` 같은 순수 계산 헬퍼는 네트워크나 데이터를 절대 건드리지 않으므로 그대로 사용할 수 있습니다.

## 4. 첫 요청 구동하기 {#4-drive-your-first-request}

도구가 살아 있으면, 에이전트에게 평범한 말로 지시하세요. 에이전트가 의도를 읽기·액션 도구로 매핑합니다.

> "`/login`에 대한 마지막 POST 20개를 나열하고, 가장 최근 것을 다른 비밀번호로 재전송한 뒤, 상태 코드가 바뀌면 이슈를 열어줘."

유능한 에이전트는 이를 짧은 도구 시퀀스로 바꿉니다.

```text
→ list_history   method:POST path~/login   (최신 20개)
→ get_flow       <가장 최근 플로우>
→ send_request   POST /login  (본문 편집)
→ create_issue   "Auth bypass on /login" severity:high
```

에이전트의 행동은 조용히 지나가지 않습니다. 각 행동은 에이전트에서 온 것으로 표시되어 gori의 알림 센터에 남고 사용자 본인의 행동과 다르게 렌더링되므로, 다른 탭을 보는 동안 코파일럿이 프로젝트에 무엇을 했는지 확인할 수 있습니다.

## 다음 단계 {#next-steps}

- [MCP 서버](/ko/guide/mcp/): 전체 도구 목록, 라이브 인터셉트, 그리고 gori가 MCP 이음새를 쓰는 이유
- [CLI Reference](/ko/reference/cli/): 전체 `gori mcp` 플래그
- [Query Language](/ko/reference/query-language/): 에이전트가 `list_history`에 사용하는 필터 문법
