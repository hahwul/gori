+++
title = "세션 유지"
description = "한 번 로그인해 토큰을 캡처하고, 이후의 모든 요청을 인증된 사용자로 재전송합니다. 손으로도, 헤드리스로도."
weight = 50

[extra]
group = "수동 루프"
+++

이 플레이북에서는 로그인을 캡처해 회전하는 토큰을 이름에 바인딩하고, 그 이름을 이후의 모든 요청에 써 넣습니다. 이어서 같은 작업을 헤드리스에서 명령 하나로 실행하고, 여러 세션을 함께 다루고, 앱이 일회용 토큰을 내줄 때 요청마다 새 토큰을 가져옵니다. 10분 정도 걸립니다.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내고, 프록시를 거쳐 대상에 로그인할 수 있게 해 두세요. 그래야 인증 응답이 캡처됩니다. 세션은 테스트 권한이 있는 대상에만 재전송하세요. 예시에서는 `api.example.com`을 가상의 대상으로 씁니다.

## 1. 로그인 캡처하기 {#1-capture-a-login}

[Quick Start](/ko/getting-started/quick-start/)에서 다룬 방식대로(**Open browser** 세션이나, `127.0.0.1:8070`을 프록시로 지정한 클라이언트로) gori를 거쳐 대상에 로그인하세요. 찾을 플로우는 응답이 `Set-Cookie: session=…`이나 `{"access_token": …}` 같은 JSON 본문 속 토큰으로 세션을 내주는 플로우입니다. **History**에서 찾으세요:

```bash
gori run history -q 'path:/login status:200'
```

플로우 id를 적어 두세요. 뒤의 헤드리스 단계에서 이 플로우를 재전송합니다.

**체크포인트.** 로그인 응답이 History에 있고, `Set-Cookie` 헤더로든 본문 속 필드로든 토큰을 담고 있습니다.

## 2. 토큰을 변수로 추출하기 {#2-extract-the-token-into-a-variable}

회전하는 토큰은 규칙에 미리 적어 둘 수 없으므로, gori는 토큰을 이름에 바인딩하고 전송 시점에 그 이름을 채웁니다. **Rewriter** 탭의 `extract` 서브탭을 열고, 로그인 응답에서 토큰을 읽어 `$BIND.SESSION`에 바인딩하는 규칙을 추가하세요. **디스크립터**로 값의 위치(쿠키, 응답 헤더, 본문 정규식, JSON 경로, 바이트 범위)를 고릅니다. 여기에 조건(`path:/login AND status:200`)과 선택 사항인 호스트 glob을 붙여, 규칙이 의도한 응답만 읽게 합니다.

```bash
gori run rewriter extract add --name SESSION --kind cookie --selector session \
  --when 'path:/login AND status:200' --host '*.example.com'
```

토큰이 JSON 본문에 있다면 `--kind jsonpath --selector '$.access_token'`을 쓰세요(또는 본문에 캡처 그룹을 둔 `--kind regex`).

**체크포인트.** `gori run rewriter bindings`에 `$BIND.SESSION`이 나옵니다. 추출은 프록시 트래픽과 수동 전송(Repeater 전송)에서 돌고, 스윕에서는 **돌지 않습니다**. 로그인을 한 번 재전송하면 `bindings` 서브탭에 이름이 바인딩되어 있습니다. 값은 메모리에만 있고 `settings.json`이나 프로젝트 데이터베이스에 쓰이지 않습니다.

## 3. 모든 요청에 되써 넣기 {#3-write-it-back-on-every-request}

다음으로 값을 다시 와이어에 올립니다. 방법은 누가 보내느냐에 따라 다릅니다. 프록시를 지나는 트래픽(브라우저나 클라이언트)에는 **Match & Replace** 규칙을 씁니다. **Rewriter** 탭에서 **요청** 쪽에 `Authorization`(또는 `Cookie`)을 `$BIND.SESSION`으로 설정하는 **set header** 규칙을 추가하세요. `$BIND.SESSION`은 각 요청이 나갈 때 해석되므로, 이후 프록시를 지나는 모든 요청은 인증된 채로 나갑니다.

```bash
gori run rewriter add --op set_header --target request \
  --find Authorization --value 'Bearer $BIND.SESSION' --host '*.example.com'
```

Match & Replace 규칙은 프록시를 지나는 트래픽에만 적용됩니다. Repeater나 Fuzzer 전송은 작성한 대로 나가므로, 요청 자체에 이름을 적으세요. Repeater 에디터나 퍼즈 템플릿의 `Authorization: Bearer $BIND.SESSION` 줄도 전송 시점에 똑같이 해석되며, 세션 슬롯(5단계)을 쓰면 요청마다 고치지 않아도 헤더를 더해 줍니다.

**체크포인트.** 전에 `401`을 돌려주던 보호된 엔드포인트에 프록시를 거쳐 요청을 보내면 이제 `200`이 오고, `Authorization` 줄이 `Bearer $BIND.SESSION`인 Repeater 전송도 마찬가지입니다. 규칙을 건너뛰었다면 이벤트 피드에 그 이름이 아무 값으로도 해석되지 않았다고 나옵니다. 로그인을 다시 캡처해 재바인딩하세요.

## 4. 헤드리스로 하기 {#4-do-it-headless}

`gori run`은 호출마다 프로세스가 하나씩 뜨고, 바인딩은 로그인을 관측한 프로세스의 메모리에만 존재합니다. 새로 뜬 `fuzz`나 `mine`은 `$BIND.SESSION`을 해석할 값이 없어 토큰이 글자 그대로 나갑니다. 스윕도 추출 소스가 아니므로, 공격 페이로드를 그대로 돌려주는 응답이 세션을 재바인딩하지 않습니다. `--bind-from`은 캡처한 플로우 하나(로그인)를 먼저 재전송해, 그 응답으로 같은 프로세스의 남은 실행 동안 쓸 바인딩 테이블을 채웁니다. 템플릿에 토큰 이름이 적혀 있어야 하므로, `Authorization` 줄이 `Bearer $BIND.SESSION`인 요청 파일을 퍼징하세요. 캡처한 플로우의 바이트에는 그 이름이 없으며, 그런 플로우에는 5단계의 `--slot`이 헤더를 더해 줍니다:

```bash
gori run fuzz --request req.http --target https://api.example.com --bind-from 17 --wordlist ids.txt
# bind-from: flow #17 replayed → bound $BIND.SESSION
```

같은 플래그를 `mine`, `sequence`, `discover`에도 쓸 수 있습니다.

**체크포인트.** 실행하면 `bind-from: flow #… replayed → bound $…` 줄이 출력되고, 응답이 `401`이 아니라 인증된 응답으로 돌아옵니다.

## 5. 세션을 여러 개 들고 다니기 {#5-carry-more-than-one-session}

2~4단계는 세션 하나만 다룹니다. 엔게이지먼트에는 보통 여러 세션(관리자, 저권한 사용자, 익명 클라이언트)이 동시에 필요한데, `$BIND.SESSION`은 한 번에 값 하나만 담습니다. **세션 슬롯**은 헤더 오버레이와 바인딩 테이블을 따로 갖는 아이덴티티입니다. 전송은 **활성** 슬롯으로 나갑니다.

슬롯은 [Authorize](/ko/guide/authorize/) 탭의 identities 카드에서 편집하는 것과 같은 행이라, 거기서 구성한 슬롯이 여기에도 보입니다. 헤드리스로는 이렇게 추가합니다:

```bash
gori run session add --name admin    --set 'Authorization: Bearer $BIND.SESSION' --rule SESSION
gori run session add --name low-priv --set 'Authorization: Bearer $BIND.SESSION' --rule SESSION
gori run session list
```

두 슬롯은 같은 `$BIND.SESSION`에서 같은 헤더를 쓰지만 서로 다른 토큰을 담습니다. extract 규칙을 소유한(`--rule SESSION`) 슬롯은 그 규칙이 관찰한 값을 전역 테이블 대신 자기 테이블에 넣습니다. 각 슬롯은 자신이 활성인 동안 재생한 로그인의 토큰을 담습니다.

그다음 전송에 신원을 지정합니다. TUI에서는 `Ctrl-P` → **Session slot**(또는 상단 바의 `session:NAME` 칩)이고, 이후 모든 전송에 어느 슬롯으로 나가는지 표시됩니다. 헤드리스에서는 `--slot`입니다.

```bash
gori run fuzz 42 --slot low-priv --bind-from 17 --wordlist ids.txt
# slot: sending as low-priv
# bind-from: flow #17 replayed → bound $BIND.SESSION
```

`--slot`은 `--bind-from`보다 먼저 적용되므로, 로그인 재생이 활성 슬롯의 테이블을 채우고 스윕은 같은 테이블에서 `$BIND.SESSION`을 해석합니다. 같은 명령을 `--slot admin`과 다른 로그인 플로우로 돌리면, 두 번째 실행은 같은 대상을 두 번째 세션으로 테스트합니다.

오버레이는 헤더 전용이라 `Content-Length`는 바뀌지 않고 본문도 바이트 단위로 같습니다. 그래서 직접 작성하지 않은 바이트(캡처된 재전송, 페이로드가 이미 끼워진 퍼즈 템플릿)에도 슬롯을 안전하게 쓸 수 있습니다.

한계가 둘 있습니다. 활성 슬롯은 **저장되지 않습니다.** 슬롯의 값은 메모리 전용이고 빈 테이블 위의 오버레이는 `$BIND.SESSION`을 글자 그대로 보내게 되므로, 프로젝트를 다시 열면 캡처된 상태에서 시작합니다. 쿠키 저장소(cookie jar)는 없습니다. 슬롯에는 직접 쓴 헤더와 gori가 관찰한 값이 있고, 다시 로그인하려면 `--bind-from`을 씁니다.

토큰 수명보다 오래 걸리는 실행이라면 슬롯에 **갱신 단계**(refresh steps)를 지정하세요. 갱신 단계는 로그인하는 Repeater 세션을 순서대로 나열한 것입니다. `gori run session edit admin --refresh 12,14 --refresh-before jwt-exp`를 실행하면 `--slot admin` 전송은 바인딩된 JWT가 곧 만료될 때마다 먼저 슬롯을 갱신하고, `gori run session refresh admin`은 그 단계를 수동으로 실행해 확인합니다. TUI에서는 Repeater 서브탭에서 `Ctrl-P` → **Use as refresh for slot…**으로 그 서브탭을 슬롯의 단계에 덧붙입니다. 갱신은 전송 전에 동작하며 `401` 뒤에 재시도하지 않습니다. [갱신 단계](/ko/reference/cli/#refresh-steps)를 참고하세요.

**체크포인트.** `gori run session list`에 두 슬롯이 나오고, `--slot low-priv` 실행은 첫 요청 전에 `slot: sending as low-priv`를 출력합니다.

## 6. 요청마다 새 토큰 가져오기 {#6-fetch-a-fresh-token-for-every-request}

페이지를 열 때마다 앱이 내주고 한 번만 받아 주는 폼의 CSRF 토큰이나 nonce처럼, 세션보다 훨씬 먼저 만료되는 값이 있습니다. 갱신 단계는 값이 *만료되기* 전에 새로 받아 오지만, 스윕은 여전히 후보마다 값 하나를 써 버리므로 첫 후보만 `200`을 받고 그 뒤로는 전부 `403`입니다. **요청 시점 매크로**는 각 후보에 앞서 실행되는 저장된 Repeater 세션이라, 2단계의 extract 규칙이 이름을 새 값으로 다시 바인딩합니다.

토큰을 내주는 요청(폼 페이지, 또는 nonce를 돌려주는 API 호출)을 Repeater 세션으로 저장하고, 그 값을 바인딩하는 extract 규칙을 둡니다:

```bash
gori run rewriter extract add --name CSRF --kind regex \
  --selector 'name="csrf" value="([^"]+)"' --when 'path:/profile AND status:200'
```

그다음 스윕할 요청에서 토큰이 들어갈 자리에 `$BIND.CSRF`를 적습니다. 이 요청은 본문이 `csrf=$BIND.CSRF&email=§x§`인 Repeater 세션(여기서는 `12`)입니다. 토큰을 내주는 세션(여기서는 `15`)을 매크로로 지정합니다:

```bash
gori run fuzz --repeater 12 --macro 15 --wordlist emails.txt
```

기본 주기에서는 후보마다 매크로를 실행하므로 스윕은 후보를 하나씩 보냅니다. 앱이 허용한다면 `--macro-every 10`으로 열 개가 값 하나를 나눠 쓰게 할 수 있습니다. 매크로가 실패하면(오류, `4xx`/`5xx`, 또는 다시 바인딩된 값 없음) 낡은 토큰으로 후보를 보내지 않으며, 세 번 연달아 실패하면 실행이 끝납니다. 캡처된 플로우는 캡처한 대로 나가 `$BIND.CSRF`를 담을 수 없으므로, 스윕은 Repeater 세션이나 초안에서 시작하세요. 헤더로 오가는 토큰이라면 활성 슬롯의 오버레이에 실어도 됩니다. TUI에서 매크로는 Fuzzer **ADVANCED** 카드의 행과 Miner 팝업에 있고, MCP에서는 `fuzz_start` / `mine_start`의 `macro_steps`입니다. [매크로로 회전하는 토큰 다루기](/ko/guide/repeater-and-fuzzer/#rotating-tokens-with-a-macro)를 참고하세요.

**체크포인트.** 첫 행 이후의 행도 `403`이 아닌 정상 응답으로 돌아오고, `gori run history -q 'src:macro'`에 매크로의 단계가 나옵니다.

## 다음 단계 {#next-steps}

- [권한 우회 찾기](/ko/playbooks/test-access-control/): 캡처한 요청을 슬롯마다 다시 보내 서버가 확인을 빠뜨린 곳 찾기
- [Authorize](/ko/guide/authorize/): 한 요청을 *모든* 슬롯으로 한꺼번에 재전송해 접근 제어 결함 찾기
- [디코딩과 변환](/ko/playbooks/decode-and-transform/): 세션에 쓰이는 인코딩된 값을 읽고 다시 쓰기
- [Session bindings](/ko/guide/proxy/#session-bindings): extract 규칙과 값의 위치에 관한 전체 레퍼런스
- [Scripting](/ko/guide/scripting/): 헤드리스 스윕 계약, 종료 코드, `--bind-from`
