+++
title = "AI 타깃 테스트"
description = "캡처에서 LLM·MCP 호출을 찾고, 프롬프트 인젝션을 히트 비율로 판정하고, MCP 세션을 이어 가고, 모델이 신뢰하도록 전달되는 도구 정의를 점검합니다."
weight = 105

[extra]
group = "워크벤치"
+++

이 플레이북은 모델과 대화하는 애플리케이션, 그리고 모델에게 도구를 넘겨주는 MCP 서버를 다른 타깃과 똑같이 다룹니다. History에서 호출을 찾고, 인젝션을 운 좋은 한 번의 응답이 아니라 비율로 읽고, 상태를 가진 MCP 호출을 재전송하고, 도구 목록이 모델에게 무엇을 말하는지 확인합니다. gori는 모델을 직접 호출하지 않습니다. 여기서 나가는 요청은 모두 캡처한 타깃으로 갑니다. 15분 정도 걸립니다.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내고, 애플리케이션 트래픽을 프록시로 캡처하세요. LLM API 호출 하나, 또는 MCP 교환 하나(`initialize`, 그다음 `tools/list`나 `tools/call`)가 필요합니다. 테스트 권한이 있는 타깃에서만 진행하세요. 예시는 `mcp.example.com`을 대역으로 씁니다.

## 1. 호출 찾기 {#1-find-the-calls}

LLM API 호출은 호스트가 아니라 요청 본문(`model`과 함께 있는 `messages` 또는 `input`)으로 인식하므로, 직접 운영하는 게이트웨이도 잡힙니다. MCP 호출은 어느 경로로 POST되든 JSON-RPC입니다.

```bash
gori run history -q 'llm:true'                              # 모든 LLM API 호출
gori run history -q 'llm:claude'                            # 한 모델 계열
gori run history -q 'rpc:tools/call'                        # MCP 도구 호출
gori run history -q 'rpc:tools/call req.body:get_weather'   # 이름으로 도구 하나
```

TUI에서는 같은 쿼리를 History 필터에 넣습니다. 매칭된 flow의 상세에는 **LLM** 또는 **MCP** 페인이 생겨서 메시지와 응답, 또는 각 호출의 method·params·result를 보여 줍니다.

**체크포인트.** 쿼리가 방금 만든 호출을 나열하고, 하나를 열면 대화나 도구 호출이 디코드되어 보입니다.

## 2. 한 번의 응답이 아니라 비율 읽기 {#2-read-a-rate-not-one-answer}

모델은 같은 요청에도 매번 다르게 답할 수 있어서, 한 번 보낸 결과로는 어느 쪽도 증명하기 어렵습니다. 요청을 있는 그대로 N번 보내고 히트를 세세요. 페이로드 세트가 **null** 페이로드뿐인 실행은 `§…§` 위치가 필요 없습니다.

```bash
gori run fuzz <flow-id> --null=20 --mr 'PWNED' --concurrency 2
# done · 20 sent · 7 shown · 0 errors
```

`--mr`에는 인젝션이 모델에게 출력하라고 시킨 표식을 넣습니다. 스트리밍 응답은 재조립한 텍스트로 매칭하므로, 단어가 두 SSE 이벤트에 걸쳐 쪼개져도 잡힙니다. TUI에서는 Fuzzer에 **Null** 세트를 추가하고 RESULTS 헤더의 `7 hit`을 읽습니다. MCP에서는 `payloads: [{"null": 20}]`이고, `fuzz_status`가 `sent` 옆에 `matched`를 돌려줍니다.

인젝션 문구 자체를 바꿔 가며 보려면 프롬프트 텍스트를 마킹하고 워드리스트를 돌리세요. [파라미터 퍼징](/ko/playbooks/fuzz-a-parameter/)과 같습니다.

**체크포인트.** 실행이 전송 수 대비 히트 수를 보고합니다. 20번 중 7번은 숫자가 붙은 발견이고, 20번 중 0번은 1번 중 0번보다 많은 것을 말해 줍니다.

## 3. 보고서용 대화 남기기 {#3-keep-the-conversation-for-the-report}

발견에는 원본 바이트와 함께, 읽는 사람이 따라갈 수 있는 대화가 필요합니다.

```bash
gori run show <flow-id> --format transcript > finding.md
```

요청의 각 메시지를 역할 아래에 쓰고, 이어서 응답과 그 도구 호출을 Markdown으로 씁니다. TUI에서는 해당 flow의 **Copy as… › LLM transcript**입니다.

**체크포인트.** 파일이 대화로 읽힙니다. 시스템 프롬프트가 먼저, 주입한 메시지, 그다음 모델의 답입니다.

## 4. MCP 세션 이어 가기 {#4-carry-an-mcp-session}

상태가 없는 MCP 서버는 재전송한 `tools/call`에 그대로 답합니다. 상태가 있는 서버는 먼저 `initialize` 교환을 요구하고, `Mcp-Session-Id`를 돌려주며, 그 세션이 사라지면 `404`로 답합니다. refresh 스텝 두 개를 가진 [세션 슬롯](/ko/playbooks/carry-a-session/)이 이 핸드셰이크를 대신 해 줍니다.

응답에 실려 오는 세션 id를 바인딩합니다.

```bash
gori run rewriter extract add --name MCPSID --kind header --selector Mcp-Session-Id \
  --when 'header:mcp-session-id'
```

캡처한 flow에서 핸드셰이크 요청 두 개를 Repeater 세션으로 저장합니다.

```bash
gori run repeater create --flow <initialize-flow> --name mcp-init
gori run repeater create --flow <initialized-notification-flow> --name mcp-ready
```

`mcp-ready`를 열어 세션 헤더를 `Mcp-Session-Id: $BIND.MCPSID`로 바꾸세요. refresh 스텝은 슬롯의 헤더 없이 나갑니다. 낡은 세션이 `initialize`에 다시 실리지 않게 하기 위해서이며, 그래서 이 요청 하나는 새 id를 직접 가리켜야 합니다. 보낼 때마다 새로워야 하는 JSON-RPC `id`는 `"id": "$GEN.UUID"`로 쓸 수 있습니다.

이제 슬롯을 만듭니다. 슬롯이 쓰는 헤더, 소유한 규칙, 갱신하는 스텝, 그리고 주기입니다.

```bash
gori run session add --name mcp --set 'Mcp-Session-Id: $BIND.MCPSID' --rule MCPSID \
  --refresh <mcp-init-id>,<mcp-ready-id> --refresh-before ttl=10m
gori run repeater send <tools-call-session> --slot mcp
```

`ttl`은 서버가 유휴 세션을 유지하는 시간보다 짧게 잡으세요. gori는 전송 전에 갱신할 뿐, 응답이 `404`라고 해서 갱신하지는 않습니다. 그래서 서버가 일찍 버린 세션은 다음 갱신 전까지 `404` 행으로 나타납니다. `gori run session refresh mcp`로 스텝을 직접 돌려 확인할 수 있고, 에이전트는 `refresh_session_slot`으로 같은 일을 합니다.

**체크포인트.** 전송이 `slot: sending as mcp`와 도구의 결과를 출력하고, `gori run history -q 'src:refresh'`가 핸드셰이크 요청 두 개를 나열합니다.

## 5. 도구 인자 퍼징하기 {#5-fuzz-a-tools-arguments}

슬롯이 세션을 실어 주면 도구 인자는 평범한 위치입니다. 저장한 `tools/call` 세션에서 인자를 마킹하고 스윕하세요.

```bash
# body: {"jsonrpc":"2.0","id":"$GEN.UUID","method":"tools/call",
#        "params":{"name":"read_file","arguments":{"path":"§notes.txt§"}}}
gori run fuzz --repeater <tools-call-session> --slot mcp --preset traversal --mr 'root:'
```

도구의 실패는 보통 `200`에 결과 안의 `"isError": true`로 돌아오므로, 상태 코드가 아니라 본문으로 매칭하세요.

**체크포인트.** 모든 행이 `404`가 아니라 도구의 답이고, 매칭된 행이 읽어 볼 인자입니다.

## 6. 도구 목록이 모델에게 하는 말 확인하기 {#6-check-what-the-tool-list-tells-the-model}

`tools/list` 결과는 클라이언트의 모델이 신뢰하고 읽는 텍스트입니다. 패시브 규칙 `llm_prompt_injection`은 사용자 몰래 모델에게 말을 거는 설명을 표시합니다.

```bash
gori run probe 'rpc:tools/list'
```

서버는 클라이언트가 승인한 뒤에 정의를 바꿀 수도 있습니다. 서로 다른 시점에, 또는 다른 사용자로 캡처한 목록 두 개를 비교하세요.

```bash
tools() { gori run show "$1" --json | jq -r '.json_rpc.calls[0].reply'; }
diff <(tools 41) <(tools 97)
```

응답이 본문 하나로 왔든 이벤트 스트림으로 왔든 들여쓴 JSON으로 출력되므로, diff에는 바뀐 도구·설명·스키마만 나타납니다.

**체크포인트.** `probe`가 목록에 `llm_prompt_injection`을 보고하거나 조용하고, 정의가 바뀌지 않은 서버라면 diff가 비어 있습니다.

## 다음 단계 {#next-steps}

- [세션 유지](/ko/playbooks/carry-a-session/): 슬롯, extract 규칙, refresh 스텝 전체
- [파라미터 퍼징](/ko/playbooks/fuzz-a-parameter/): 위치, 페이로드 세트, matcher
- [트리아지와 리포트](/ko/playbooks/triage-and-report/): 히트 비율과 대화 기록을 이슈로 만들기
- [쿼리 언어](/ko/reference/query-language/): `llm:`, `rpc:`를 비롯한 필터 문법
