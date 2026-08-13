+++
title = "플로우 중 가로채기 및 수정"
description = "요청을 흐름 중간에 붙잡아 바꾸고 계속 흘려보낸 뒤, 그 변경을 규칙으로 고정합니다."
weight = 30

[extra]
group = "수동 루프"
+++

Repeater는 사후에 사본을 편집하지만, 인터셉트는 클라이언트가 기다리는 동안 진짜 요청을 편집합니다. 이 플레이북은 살아 있는 요청을 붙잡아 와이어에서 바꾸고, 흘려보낸 뒤, 그 편집이 지킬 만하다고 판단되면 — 인터셉트를 끈 채 스스로 적용되는 Match & Replace 규칙으로 바꿉니다. 약 10분이 걸립니다.

> **시작하기 전에.** 스코프를 그린 엔게이지먼트를 [준비](/ko/playbooks/set-up-an-engagement/)하고, 캡처를 켜고(`c`), 클라이언트를 프록시로 향하게 하세요. 예시는 `api.example.com`을 씁니다.

## 1. 인터셉트 무장 {#1-arm-intercept}

`i`를 눌러 **Intercept**를 켜거나, **Intercept** 탭을 열어 거기서 catch를 무장합니다. 조건이 비어 있으면 *모든 것*을 붙잡습니다 — 프록시를 지나는 모든 요청이 당신이 결정할 때까지 멈춥니다 — 그러니 풀어놓기 전에 필터 바에서 쿼리 언어 표현식으로 좁히세요:

```text
host:api.example.com method:POST
```

이제 대상으로 가는 POST만 붙잡히고 나머지는 곧장 통과합니다. History 필터가 쓰는 것과 같은 토큰이 여기서도 동작합니다(`host:`, `path:`, `method:`, `scheme:`, `status:`, 그리고 `AND` / `OR` / `NOT`).

<figure class="tui-shot">
  <img src="/images/tui/intercept.svg" alt="catch 방향과 쿼리 조건을 위한 필터 바, 그리고 catch가 꺼졌을 때 forward와 drop을 설명하는 카드가 있는 gori Intercept 탭">
  <figcaption><strong>Intercept</strong> 탭: <kbd>i</kbd>로 catch를 토글하고, 방향을 고르고, 매칭되는 트래픽만 붙잡아 플로우 중에 forward, drop, 또는 편집합니다.</figcaption>
</figure>

> **WebSocket은 예외입니다.** WebSocket 메시지는 catch 조건에 `proto:ws`가 들어 있을 때**만** 붙잡힙니다 — 조건이 비어 있어도, 호스트 필터를 걸어도 무장되지 않습니다. 이것은 HTTP 규칙의 정반대이며 의도된 것입니다. 초당 수십 개의 메시지를 나르는 채팅이나 트레이딩 소켓이 당신이 호스트 필터를 입력했다는 이유로 통째로 얼어붙는 것은, 빼내며 수습할 수 있는 상태가 아닙니다.

**체크포인트.** Intercept 탭에 catch가 켜져 있고, 조건이 필터 바에 놓여 있습니다.

## 2. 요청을 잡아 편집하기 {#2-catch-a-request-and-edit-it}

클라이언트에서 매칭되는 요청을 발생시킵니다 — 브라우저 클릭, `curl`, Repeater 전송 등. 요청은 떠나는 대신 Intercept 큐에 멈춥니다. 그것을 선택해 raw 바이트를 에디터에서 열고(`Space` 메뉴를 통해 Repeater가 쓰는 것과 같은 INS 모드 에디터), 필요한 것을 바꾼 뒤 — 헤더 값, JSON 필드, 경로 등 — `f`로 편집된 요청을 **forward**(전달)합니다. `Esc`는 전송 없이 에디터를 빠져나옵니다.

Headless로는 같은 큐를 실행 중인 TUI에 대해 두 번째 터미널에서 조종할 수 있습니다:

```bash
gori run intercept                       # 붙잡힌 항목 + catch 상태 나열
gori run intercept edit 3 --raw-file edited.txt   # 편집된 바이트로 항목 3 전달
```

편집된 요청은 `Content-Length`가 재동기화되어 전달되고, `$KEY` 확장은 없습니다 — 입력한 그대로 나갑니다.

**체크포인트.** 편집된 요청이 origin에 닿습니다. **History**로 전환해 그 플로우를 읽어 변경과 origin의 응답을 확인하세요.

## 3. Forward, drop, 또는 편집 {#3-forward-drop-or-edit}

붙잡힌 모든 항목은 세 가지 결정 중 하나이고, gori는 그중 무엇도 대신 적용하지 않습니다:

- **Forward** (`f`)는 항목을 바이트 그대로, 또는 2단계의 편집을 담아 풀어 줍니다. 홀드가 쌓였을 때 `Shift-F`는 큐 전체를 한 번에 전달합니다.
- **Drop** (`d`)는 항목을 죽입니다. HTTP/1.1에서는 클라이언트가 정형화된 `502`를 받고, HTTP/2에서는 스트림이 취소됩니다. 요청이 아예 도착하지 않을 때 클라이언트가 어떻게 대처하는지 보려면 쓰세요.
- **편집 후 전달**은 요청을 계속 흘려보내기 전에 바꾸고 싶을 때 — 2단계에서 걸어 본 경우입니다.

Forward와 drop은 마킹된 행이 있으면 그것에, 없으면 커서 행에 작용합니다. 그래서 `t`로 여러 행을 마킹하고 `f` 한 번이면 함께 풀립니다. 각각은 운영자가 결정하며, 자동으로 적용되는 것은 없습니다.

**체크포인트.** 요청 하나는 손대지 않고 전달하고 다른 하나는 drop했으며, History가 둘 다 기록합니다 — drop은 취소된 플로우로.

## 4. Match & Replace로 편집을 영구화하기 {#4-make-an-edit-permanent-with-match-replace}

같은 편집을 손으로 하려고 매 요청을 붙잡는 것은 금세 지칩니다. 상시 편집은 **Rewriter** 탭에 속합니다(Match & Replace 에디터, 탭 바에서 Comparer 오른쪽, 또는 `Ctrl-P` → **Match & Replace**). 연산이 있는 규칙을 추가하고 — 헤드나 본문의 텍스트를 **Replace**, 헤더를 **Add** / **Set** / **Remove**, 또는 origin을 전혀 다이얼하지 않고 규칙에서 요청에 답하는 **Short circuit** — 매칭되는 트래픽에만 발동하도록 host glob으로 스코프를 겁니다:

```bash
gori run rewriter add --op set_header --target request \
  --find X-Forwarded-For --value 127.0.0.1 --host '*.example.com'
```

규칙이 어디에 살지 고르세요. **project** 규칙은 이 엔게이지먼트의 데이터베이스에, **global** 규칙은 `settings.json`에 담겨 모든 프로젝트에 적용됩니다. 에디터의 `scope:` 행에서 정하거나, headless로 `--scope=global`을 씁니다. 규칙은 저장하는 순간 재시작 없이 발효됩니다 — 그러니 인터셉트를 **끄면** 이제 편집은 매칭되는 모든 요청에 스스로 일어납니다.

**체크포인트.** 인터셉트가 꺼진 채로 매칭되는 트래픽이 변경을 자동으로 실어 나르고, 에디터의 실시간 미리보기가 그 규칙이 최근 플로우 몇 개를 건드릴지 보여 줍니다.

## 다음 단계 {#next-steps}

- [파라미터 퍼징](/ko/playbooks/fuzz-a-parameter/): 이 요청 중 하나를 가져와 값을 워드리스트로 훑습니다
- [Proxy & History](/ko/guide/proxy/#intercept): Intercept 전체 레퍼런스, HTTP/2와 WebSocket 규칙
- [Match & Replace](/ko/guide/proxy/): 모든 rewrite 연산, short-circuit 스텁, global 대 project 스코프
