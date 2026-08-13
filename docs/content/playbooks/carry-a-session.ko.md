+++
title = "세션 유지"
description = "한 번 로그인해 토큰을 캡처하고, 이후의 모든 요청을 인증된 사용자로 재전송합니다 — 손으로도, 헤드리스로도."
weight = 50

[extra]
group = "수동 루프"
+++

인증된 테스트란 한 번 하는 로그인과 그 뒤로 계속 지니고 다니는 토큰입니다. 이 플레이북은 로그인을 캡처하고, 회전하는 토큰을 이름에 바인딩하고, 그 이름을 이후의 모든 요청에 써 넣은 뒤, 같은 일을 헤드리스에서 명령 하나로 해냅니다. 약 10분 잡으세요.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내고, 프록시를 통해 대상에 로그인할 수 있어 그 인증 응답이 캡처되게 하세요. 테스트 권한이 있는 대상만 상대로 세션을 재전송하세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 로그인 캡처하기 {#1-capture-a-login}

재사용하려면 먼저 인증시켜 주는 응답이 필요합니다. [Quick Start](/ko/getting-started/quick-start/)가 다루는 방식대로 — **Open browser** 세션이나, `127.0.0.1:8070`을 가리키는 자체 클라이언트로 — gori를 통해 대상에 로그인하세요. 노리는 플로우는 응답이 세션을 건네주는 그것입니다: `Set-Cookie: session=…`, 또는 `{"access_token": …}`처럼 JSON 본문 속 토큰. **History**에서 찾으세요:

```bash
gori run history -q 'path:/login status:200'
```

플로우 id를 적어 두세요 — 마지막 헤드리스 단계가 바로 이 플로우를 재전송합니다.

**체크포인트.** 로그인 응답이 History에 있고, `Set-Cookie` 헤더로든 본문 속 필드로든 토큰을 담고 있습니다.

## 2. 토큰을 변수로 추출하기 {#2-extract-the-token-into-a-variable}

회전하는 토큰은 미리 값을 박아 둬야 하는 규칙에는 쓸모가 없으므로, gori는 이를 전송 시점에 채워 넣는 이름에 바인딩합니다. **Rewriter** 탭의 `extract` 서브탭을 열고, 로그인 응답에서 토큰을 읽어 `$SESSION`에 바인딩하는 규칙을 추가하세요. **디스크립터**가 값이 어디에 있는지를 고릅니다 — 쿠키, 응답 헤더, 본문 정규식, JSON 경로, 또는 바이트 범위 — 여기에 조건(`path:/login AND status:200`)과 선택적 호스트 glob이 함께 붙어, 규칙이 의도한 응답만 읽게 합니다.

```bash
gori run rewriter extract add --name SESSION --kind cookie --selector session \
  --when 'path:/login AND status:200' --host '*.example.com'
```

토큰이 JSON 본문에 있다면 대신 `--kind jsonpath --selector '$.access_token'`을 쓰세요(또는 본문에 캡처 그룹을 둔 `--kind regex`).

**체크포인트.** `gori run rewriter bindings`에 `$SESSION`이 나열됩니다. 추출은 프록시 트래픽과 손으로 한 전송(Repeater 전송)에서 돌고, 스윕에서는 **돌지 않습니다** — 그러니 로그인을 한 번 재전송하면 `bindings` 서브탭에 이름이 바인딩된 것이 보입니다. 값은 메모리에만 존재하며, `settings.json`이나 프로젝트 데이터베이스에 절대 쓰이지 않습니다.

## 3. 모든 요청에 되써 넣기 {#3-write-it-back-on-every-request}

이름을 바인딩한 것만으로는 값을 캡처했을 뿐입니다. 그것을 다시 와이어에 올리는 것은 **Match & Replace** 규칙입니다. **Rewriter** 탭에서 **요청** 쪽에 `Authorization`(또는 `Cookie`)을 `$SESSION`으로 설정하는 **set header** 규칙을 추가하세요. `$SESSION`은 규칙을 저장한 때가 아니라 각 요청이 나갈 때 해석되므로, 이후의 모든 Repeater·Fuzzer 전송은 인증된 채로 나갑니다.

```bash
gori run rewriter add --op set_header --target request \
  --find Authorization --value 'Bearer $SESSION' --host '*.example.com'
```

**체크포인트.** 전에 `401`을 돌려주던 보호된 엔드포인트를 Repeater로 재전송하면 이제 `200`을 돌려줍니다. 대신 규칙이 건너뛰어졌다면, 이벤트 피드가 이름이 아무것도 해석하지 못했다고 말합니다 — 로그인을 다시 캡처해 재바인딩하세요.

## 4. 헤드리스로 하기 {#4-do-it-headless}

`gori run`은 호출마다 프로세스 하나이고, 바인딩은 로그인을 관측한 그 프로세스의 메모리에만 존재합니다 — 그래서 새로 뜬 `fuzz`나 `mine`은 `$SESSION`을 해석할 것이 없어 전송 전에 거부됩니다. 스윕은 의도적으로 추출 소스도 아닙니다: 공격 페이로드를 되비추는 응답이 자칫 세션을 페이로드에서 유래한 값으로 재바인딩할 수 있기 때문입니다. `--bind-from`이 그 틈을 메웁니다. 캡처한 플로우 하나 — 로그인 — 를 먼저 재전송해, 그 응답이 같은 프로세스 안에서 이후 실행 동안 바인딩 표를 채웁니다:

```bash
gori run fuzz 42 --bind-from 17 --wordlist ids.txt
# bind-from: flow #17 replayed → bound $SESS
```

같은 플래그가 `mine`, `sequence`, `discover`에도 통합니다.

**체크포인트.** 실행이 `bind-from: flow #… replayed → bound $…` 줄을 찍고, 응답이 `401` 벽 대신 인증된 채로 돌아옵니다.

## 다음 단계 {#next-steps}

- [디코딩과 변환](/ko/playbooks/decode-and-transform/): 세션이 올라타는 인코딩된 값을 읽고 되쓰기
- [Session bindings](/ko/guide/proxy/#session-bindings): extract 규칙과 값이 사는 곳의 전체 레퍼런스
- [Scripting](/ko/guide/scripting/): 헤드리스 스윕 계약, 종료 코드, 그리고 `--bind-from`
