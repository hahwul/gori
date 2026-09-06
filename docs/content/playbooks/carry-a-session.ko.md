+++
title = "세션 유지"
description = "한 번 로그인해 토큰을 캡처하고, 이후의 모든 요청을 인증된 사용자로 재전송합니다. 손으로도, 헤드리스로도."
weight = 50

[extra]
group = "수동 루프"
+++

인증된 테스트란 한 번 하는 로그인과 그 뒤로 계속 지니고 다니는 토큰입니다. 이 플레이북은 로그인을 캡처하고, 회전하는 토큰을 이름에 바인딩하고, 그 이름을 이후의 모든 요청에 써 넣은 뒤, 같은 일을 헤드리스에서 명령 하나로 해냅니다. 약 10분 잡으세요.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내고, 프록시를 통해 대상에 로그인할 수 있어 그 인증 응답이 캡처되게 하세요. 테스트 권한이 있는 대상만 상대로 세션을 재전송하세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 로그인 캡처하기 {#1-capture-a-login}

재사용하려면 먼저 인증시켜 주는 응답이 필요합니다. [Quick Start](/ko/getting-started/quick-start/)가 다루는 방식대로(**Open browser** 세션이나, `127.0.0.1:8070`을 가리키는 자체 클라이언트로) gori를 통해 대상에 로그인하세요. 노리는 플로우는 응답이 세션을 건네주는 그것입니다: `Set-Cookie: session=…`, 또는 `{"access_token": …}`처럼 JSON 본문 속 토큰. **History**에서 찾으세요:

```bash
gori run history -q 'path:/login status:200'
```

플로우 id를 적어 두세요. 마지막 헤드리스 단계가 바로 이 플로우를 재전송합니다.

**체크포인트.** 로그인 응답이 History에 있고, `Set-Cookie` 헤더로든 본문 속 필드로든 토큰을 담고 있습니다.

## 2. 토큰을 변수로 추출하기 {#2-extract-the-token-into-a-variable}

회전하는 토큰은 미리 값을 박아 둬야 하는 규칙에는 쓸모가 없으므로, gori는 이를 전송 시점에 채워 넣는 이름에 바인딩합니다. **Rewriter** 탭의 `extract` 서브탭을 열고, 로그인 응답에서 토큰을 읽어 `$SESSION`에 바인딩하는 규칙을 추가하세요. **디스크립터**가 값이 어디에 있는지를 고릅니다(쿠키, 응답 헤더, 본문 정규식, JSON 경로, 또는 바이트 범위). 여기에 조건(`path:/login AND status:200`)과 선택적 호스트 glob이 함께 붙어, 규칙이 의도한 응답만 읽게 합니다.

```bash
gori run rewriter extract add --name SESSION --kind cookie --selector session \
  --when 'path:/login AND status:200' --host '*.example.com'
```

토큰이 JSON 본문에 있다면 대신 `--kind jsonpath --selector '$.access_token'`을 쓰세요(또는 본문에 캡처 그룹을 둔 `--kind regex`).

**체크포인트.** `gori run rewriter bindings`에 `$SESSION`이 나열됩니다. 추출은 프록시 트래픽과 손으로 한 전송(Repeater 전송)에서 돌고, 스윕에서는 **돌지 않습니다**. 그러니 로그인을 한 번 재전송하면 `bindings` 서브탭에 이름이 바인딩된 것이 보입니다. 값은 메모리에만 존재하며, `settings.json`이나 프로젝트 데이터베이스에 절대 쓰이지 않습니다.

## 3. 모든 요청에 되써 넣기 {#3-write-it-back-on-every-request}

이름을 바인딩한 것만으로는 값을 캡처했을 뿐입니다. 그것을 다시 와이어에 올리는 것은 **Match & Replace** 규칙입니다. **Rewriter** 탭에서 **요청** 쪽에 `Authorization`(또는 `Cookie`)을 `$SESSION`으로 설정하는 **set header** 규칙을 추가하세요. `$SESSION`은 규칙을 저장한 때가 아니라 각 요청이 나갈 때 해석되므로, 이후의 모든 Repeater·Fuzzer 전송은 인증된 채로 나갑니다.

```bash
gori run rewriter add --op set_header --target request \
  --find Authorization --value 'Bearer $SESSION' --host '*.example.com'
```

**체크포인트.** 전에 `401`을 돌려주던 보호된 엔드포인트를 Repeater로 재전송하면 이제 `200`을 돌려줍니다. 대신 규칙이 건너뛰어졌다면, 이벤트 피드가 이름이 아무것도 해석하지 못했다고 말합니다. 로그인을 다시 캡처해 재바인딩하세요.

## 4. 헤드리스로 하기 {#4-do-it-headless}

`gori run`은 호출마다 프로세스 하나이고, 바인딩은 로그인을 관측한 그 프로세스의 메모리에만 존재합니다. 그래서 새로 뜬 `fuzz`나 `mine`은 `$SESSION`을 해석할 것이 없어 전송 전에 거부됩니다. 스윕은 의도적으로 추출 소스도 아닙니다: 공격 페이로드를 되비추는 응답이 자칫 세션을 페이로드에서 유래한 값으로 재바인딩할 수 있기 때문입니다. `--bind-from`이 그 틈을 메웁니다. 캡처한 플로우 하나(로그인)를 먼저 재전송해, 그 응답이 같은 프로세스 안에서 이후 실행 동안 바인딩 표를 채웁니다:

```bash
gori run fuzz 42 --bind-from 17 --wordlist ids.txt
# bind-from: flow #17 replayed → bound $SESS
```

같은 플래그가 `mine`, `sequence`, `discover`에도 통합니다.

**체크포인트.** 실행이 `bind-from: flow #… replayed → bound $…` 줄을 찍고, 응답이 `401` 벽 대신 인증된 채로 돌아옵니다.

## 5. 세션을 여러 개 들고 다니기 {#carry-more-than-one-session}

2~4단계는 세션 *하나*를 들고 다닙니다. 실제 엔게이지먼트는 보통 여러 개(관리자, 저권한 사용자, 익명 클라이언트)를 동시에 필요로 하는데, `$SESSION`은 한 번에 하나만 뜻할 수 있습니다. **세션 슬롯**이 그 이름입니다. 자기 헤더 오버레이와 자기 바인딩 테이블을 가진 아이덴티티이고, **활성** 인 슬롯이 곧 전송이 나가는 신원입니다.

슬롯은 [Authorize](/ko/guide/authorize/) 탭의 identities 카드가 편집하는 바로 그 행이라, 거기서 이미 구성해 둔 집합이 여기에도 그대로 있습니다. 헤드리스로 추가하려면:

```bash
gori run session add --name admin    --set 'Authorization: Bearer $SESSION' --rule SESSION
gori run session add --name low-priv --set 'Authorization: Bearer $SESSION' --rule SESSION
gori run session list
```

두 슬롯이 같은 `$SESSION`에서 같은 헤더를 쓰는데도 서로 다른 토큰을 뜻합니다. extract 규칙의 소유권을 **주장한**(`--rule SESSION`) 슬롯은 그 규칙이 관찰한 값을 전역 테이블이 아니라 자기 테이블로 가져가기 때문입니다. 각자 어떤 토큰을 들게 되는지는 그 슬롯이 활성인 동안 어떤 로그인을 재생했는지가 결정합니다.

그다음 전송에 신원을 지정합니다. TUI에서는 `Ctrl-P` → **Session slot**(또는 상단 바의 `session:NAME` 칩)이고, 이후 모든 전송이 누구로 나가는지 밝힙니다. 헤드리스에서는 `--slot`입니다.

```bash
gori run fuzz 42 --slot low-priv --bind-from 17 --wordlist ids.txt
# slot: sending as low-priv
# bind-from: flow #17 replayed → bound $SESSION
```

`--slot`은 `--bind-from` **보다 먼저** 적용되므로, 로그인 재생이 활성 슬롯의 테이블을 채우고 스윕은 같은 테이블에서 `$SESSION`을 해소합니다. 똑같은 명령을 `--slot admin`과 다른 로그인 플로우로 돌리면, 두 실행은 같은 대상의 두 세션이 됩니다.

오버레이는 헤더 전용이라 `Content-Length`는 움직이지 않고 본문은 바이트 그대로입니다. 그래서 직접 작성하지 않은 바이트(캡처된 재전송, 페이로드가 이미 끼워진 퍼즈 템플릿) 위에서도 슬롯은 안전합니다.

기대기 전에 알아 둘 한계가 둘 있습니다. 활성 슬롯은 **절대 저장되지 않습니다.** 프로젝트를 다시 열면 캡처된 그대로에서 시작하는데, 슬롯의 값이 메모리 전용이라 포인터만 비어 있는 테이블 위로 복원하면 `$SESSION`이 리터럴인 오버레이를 보내게 되기 때문입니다. 그리고 쿠키 항아리도 자동 로그인 매크로도 없습니다. 슬롯은 직접 쓴 헤더와 gori가 관찰한 값을 들고 있고, `--bind-from`이 "다시 로그인한다"의 명시적인 버전입니다.

**체크포인트.** `gori run session list`가 두 슬롯을 보여 주고, `--slot low-priv` 실행은 첫 요청 전에 `slot: sending as low-priv`를 찍습니다.

## 다음 단계 {#next-steps}

- [디코딩과 변환](/ko/playbooks/decode-and-transform/): 세션이 올라타는 인코딩된 값을 읽고 되쓰기
- [Session bindings](/ko/guide/proxy/#session-bindings): extract 규칙과 값이 사는 곳의 전체 레퍼런스
- [Scripting](/ko/guide/scripting/): 헤드리스 스윕 계약, 종료 코드, 그리고 `--bind-from`
