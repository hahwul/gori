+++
title = "AI 코파일럿 세션 실행"
description = "MCP로 같은 프로젝트에 에이전트를 붙이고 그 모든 동작을 지켜봅니다 — 인텔리전스는 설계상 도구 바깥에 있습니다."
weight = 120

[extra]
group = "마무리"
+++

gori에는 채팅 창이 없고, 이는 의도적입니다. 인텔리전스는 도구 바깥에 살고, MCP로 도달합니다. 당신이 모델과 클라이언트를 가져오면 gori는 프로젝트를 깔끔한 도구 인터페이스로 노출합니다. 그래서 무엇이 돌지 당신이 고르고, 트래픽은 당신이 의도하지 않은 어디로도 실려 가지 않으며, 에이전트의 모든 동작이 이미 당신이 보고 있는 그 TUI에 나타납니다. 이 플레이북은 이미 캡처한 프로젝트에 에이전트를 붙여 일을 시킵니다 — 약 10분이며, 대부분은 한 번뿐인 설치입니다.

> **시작하기 전에.** 캡처된 트래픽이 담긴 기존 프로젝트가 필요합니다 — 앞선 플레이북의 그 프로젝트가 이상적입니다 — 그리고 MCP를 지원하는 클라이언트(Claude Code, Claude Desktop, OpenAI Codex, Antigravity, Grok 등)가 필요합니다. 에이전트는 실제 요청을 보낼 수 있으니, 테스트 권한이 있는 대상으로 프로젝트 스코프를 잡아 두세요.

## 1. MCP 서버 설치 {#1-install-the-mcp-server}

`gori mcp`는 클라이언트가 stdio로 띄우는 JSON-RPC 서버입니다. STDIN으로 요청을 보내고 STDOUT으로 결과를 읽습니다. 각 클라이언트의 설정을 손으로 편집하는 대신, gori가 대신 쓰게 하세요:

```bash
gori mcp --install-claude-code   # Claude Code
```

다른 호스트도 같은 방식으로 설치합니다: `--install-claude`(Claude Desktop), `--install-codex`(OpenAI Codex), `--install-agy`(Antigravity), `--install-grok`(Grok). 각 명령은 쓴 파일과 기록한 정확한 실행 명령을 출력합니다. Codex와 Grok은 JSON이 아니라 TOML `[mcp_servers.gori]` 테이블을 씁니다. 이후 클라이언트를 재시작(또는 세션을 다시 열기)해 MCP 서버를 다시 읽게 하세요.

두 가지 선택이 그 기록된 명령에 함께 실립니다. **읽기 전용 대 전체 접근**: 기본적으로 에이전트는 액티브 도구(`send_request`, 이슈 쓰기, 인터셉트 뮤테이터)도 받습니다. `--read-only`를 더하면 읽기 도구만 노출됩니다. **어느 프로젝트**: 엔게이지먼트의 Git 저장소 안에서 설치를 실행하면 gori가 그 워크스페이스를 자체 프로젝트에 경로-바인딩합니다. 그 밖에서는 서버가 언바운드로 시작하고 에이전트가 도구로 프로젝트를 고릅니다. `--project`나 `--db`로 명시적으로 고정하면, 절대 경로로 기록된 명령에 쓰입니다:

```bash
gori mcp --project my-engagement --install-codex
```

**체크포인트.** 클라이언트가 gori의 도구들을 나열합니다 — `list_history`, `get_flow`, `send_request`, `project_info` 등. 보이지 않으면 클라이언트가 재시작됐는지, 그리고 클라이언트가 쓰는 `PATH`에 `gori`가 있는지 확인하세요.

## 2. 에이전트에게 작업 주기 {#2-give-the-agent-a-task}

도구가 살아 있으면, 에이전트에게 평이한 언어로 지시하세요. 에이전트는 당신의 의도를 당신이 직접 다루는 것과 같은 도구로, 같은 프로젝트 데이터베이스에 대해 — 사본이 아니라 — 매핑합니다:

> "`/login`에 대한 최근 20개의 POST를 나열하고, 가장 최신 것을 다른 비밀번호로 재전송한 뒤, 상태 코드가 바뀌면 이슈를 열어."

유능한 에이전트는 이것을 짧고 순서 있는 도구 시퀀스로 바꿉니다:

```text
→ list_history   method:POST path~/login   (newest 20)
→ get_flow       <the newest flow>
→ send_request   POST /login  (edited body)
→ create_issue   "Auth bypass on /login" severity:high
```

도구는 도착 순서대로 한 번에 하나씩 실행되므로, 느린 `send_request`가 다음 호출과 겹치지 않고 결과는 순서대로 돌아옵니다.

**체크포인트.** 에이전트의 `send_request`에서 나온 새 플로우가 당신의 **History**에 나타나고, 에이전트가 파일링한 이슈가 있다면 **Issues** 탭에 보입니다.

## 3. 무엇을 하는지 지켜보기 {#3-watch-what-it-does}

에이전트를 맹목적으로 믿을 필요는 없습니다. 어떤 동작도 조용하지 않기 때문입니다. 모든 동작이 gori의 **알림 센터**에 에이전트에서 온 것으로 태그되어, 당신 자신의 동작과 다르게 렌더링됩니다. 그래서 다른 탭을 읽는 동안에도 힐끗 보면 코파일럿이 무엇을 바꿨는지 — 보낸 요청, 파일링한 이슈, 작성한 규칙 — 알 수 있습니다.

인터셉트 루프 안에서도 마찬가지입니다. 에이전트가 당신 옆에서 큐에 앉을 수 있고, 그것이 하는 각 `intercept_forward_edit`는 그 자신의 것으로 표시됩니다. 라이브 핸드오프의 안전 참고 하나 — 에이전트가 인터셉트 큐에 붙는 순간, gori는 아무도 지켜보지 않는 보류 항목에 대해 30초 자동 포워드를 무장합니다. 그래서 보류 중에 죽은 클라이언트가 연결을 무한정 막을 수 없습니다.

**체크포인트.** 커맨드 팔레트(`Ctrl-P` → notifications)에서 알림 센터를 열면 에이전트의 동작이 당신 것과 눈에 띄게 구분되어 태그된 채 거기 있습니다.

## 4. 안전하게 넘기기 {#4-hand-off-safely}

대상에 대해 완전히 믿지는 않는 에이전트 — 또는 동료 — 에게 프로젝트를 넘기려면, 읽기 전용으로 설치하세요:

```bash
gori mcp --read-only --install-claude-code
```

읽기 전용은 모든 검사 도구(`list_history`, `get_flow`, `list_sitemap`, `compare_flows`)와 순수 계산 헬퍼(`decode`, `jwt_decode`)를 유지하면서 `send_request`, 이슈 쓰기, 인터셉트 뮤테이터를 비활성화합니다. 에이전트는 엔게이지먼트 전체를 읽고 추론할 수 있지만, 대상을 건드리거나 당신의 기록을 바꿀 수는 없습니다.

스코프는 두 번째 가드레일이며, 액티브 도구가 켜져 있어도 유지됩니다. 프로젝트 스코프 밖의 — 또는 스코프가 없는 — 호스트를 겨눈 액티브 도구는 샌드박스가 켜져 있든 아니든 `SCOPE_BLOCKED` 오류로 거부됩니다. 그래서 전체 접근 에이전트조차 당신이 스코프를 잡지 않은 호스트로 빗나간 요청을 보낼 수 없습니다. Repeater와 Fuzzer가 확인하는 것과 같은 가드레일을 물려받습니다.

**체크포인트.** 읽기 전용 에이전트는 history를 나열하고 플로우를 분석할 수 있지만, `send_request`는 비활성화되어 돌아옵니다 — 그리고 액티브 도구가 켜진 상태에서도, 스코프 밖 호스트로의 요청은 `SCOPE_BLOCKED`를 반환합니다.

## 다음 단계 {#next-steps}

- [플레이북](/ko/playbooks/): 전체 워크플로우 목록으로 돌아가기
- [MCP Server](/ko/guide/mcp/): 전체 도구 카탈로그, 라이브 인터셉트, 그리고 gori가 MCP 심을 쓰는 이유
- [AI Setup](/ko/getting-started/ai-setup/): 단계별 연결·구동 워크스루
