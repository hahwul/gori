+++
title = "권한 우회 찾기"
description = "캡처한 요청을 다른 사용자로, 또 로그인하지 않은 상태로 다시 보내 서버가 권한 확인을 빠뜨린 곳을 찾습니다."
weight = 55

[extra]
group = "워크벤치"
+++

한 사용자로 앱을 돌아다녀 보니 모든 페이지가 잘 열렸습니다. 사실 이것만으로는 알 수 있는 게 별로 없습니다. 진짜 궁금한 건 *다른* 사람이 같은 걸 요청했을 때입니다. 권한이 더 낮은 사용자, 다른 계정의 사용자, 아예 로그인하지 않은 사람이요. 이 플레이북에서는 이런 사람들을 아이덴티티로 만들어 두고, 캡처한 요청을 각각의 아이덴티티로 다시 보낸 뒤, 달라야 하는데 똑같이 돌아온 요청을 찾습니다. 15분 정도 걸립니다.

> **시작하기 전에.** [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)로 대상 스코프를 잡아 두고, 테스트를 승인한 쪽에서 테스트 계정 두 개를 받아 두세요. 하나는 다른 하나보다 권한이 높아야 합니다. 세션 슬롯은 [세션 유지](/ko/playbooks/carry-a-session/)에서 더 자세히 다루지만, 먼저 읽지 않아도 됩니다. 테스트 권한이 있는 대상만 테스트하세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 권한 높은 사용자로 둘러보기 {#1-browse-as-the-stronger-user}

권한이 높은 계정(관리자, 또는 데이터의 주인)으로 로그인해서 gori를 통해 평소처럼 앱을 써 보세요. 페이지를 열고, 목록을 보고, 레코드 하나를 열어 보고, 설정도 바꿔 보세요. 지금 보내는 요청은 하나하나가 나중에 다른 사람으로 다시 보내 볼 수 있는 요청입니다. 앱을 많이 건드릴수록 테스트할 거리도 많아집니다.

id가 들어 있거나 특정 리소스를 가리키는 요청을 눈여겨보세요. `/orders/1042`, `/api/users/7/profile`, `?account=acme` 같은 것들입니다. 접근 제어 버그는 대개 이런 곳에 있습니다.

**체크포인트.** **History**에 관리자 트래픽이 쌓였고, 그중에 특정 레코드 하나를 가져오는 요청이 몇 개 있습니다.

## 2. 권한 낮은 사용자의 아이덴티티 만들기 {#2-make-an-identity-for-the-weaker-user}

아이덴티티는 요청을 다시 보내기 전에 gori가 적용하는 헤더 변경 묶음입니다. 새 프로젝트에는 이미 두 개가 있습니다. 캡처한 그대로 보내는 **as-captured**, 그리고 `Cookie`와 `Authorization`을 지우는 **anonymous**입니다. 권한 낮은 사용자 하나만 추가하면 됩니다.

가장 빠른 방법은 gori가 로그인 응답을 읽게 하는 것입니다. 다른 브라우저나 시크릿 창에서 gori를 거쳐 권한 낮은 계정으로 로그인하고, History에서 그 로그인을 찾아 슬롯을 만드세요. 이걸 하려고 관리자를 로그아웃하지는 마세요. 대부분의 앱은 로그아웃하면 세션 쿠키를 무효로 만드는데, 캡처한 요청들이 바로 그 쿠키를 달고 있습니다. 그러면 모든 재전송이 죽은 세션으로 나갑니다.

```bash
gori run history -q 'path:/login status:200'
gori run session from-flow <login-flow-id> --name low-priv
```

gori가 로그인 응답에서 쿠키(또는 bearer 토큰)를 꺼내 `low-priv` 아이덴티티로 저장합니다. TUI에서는 손으로 해도 됩니다. **Authorize** 탭을 열고 `i`, 이어서 `a`를 누른 뒤, 이름을 `low-priv`로 하고 그 사용자의 `Cookie:` 줄을 set headers 칸에 붙여 넣으세요.

Authorize 탭은 기본으로는 탭 바에 없습니다. `0`을 누르고 "auth"를 입력하거나, `Ctrl-P` → **Go to Authorize**를 쓰세요.

**체크포인트.** `gori run session list`(또는 Authorize 탭에서 `i`)에 아이덴티티가 세 개 보입니다: `as-captured`, `anonymous`, `low-priv`.

## 3. 요청을 큐에 넣고 실행하기 {#3-queue-the-requests-and-run}

**History**에서 테스트할 만한 요청을 골라 `Space` → `>` → `a`(**Send flow to…** → **Send to Authorize**)를 누르세요. 비공개 정보를 돌려주는 요청을 고르세요. 레코드, 프로필, 설정 페이지, 관리자용 목록 같은 것들입니다. 누구나 보는 공개 페이지로는 알 수 있는 게 없습니다.

**Authorize** 탭에서 `Ctrl-R`을 누르세요. gori가 큐에 든 요청을 아이덴티티마다 한 번씩, 각자 따로 연결을 열어 다시 보내고, 돌아온 응답을 as-captured 응답과 비교합니다.

헤드리스에서는 플로우(또는 쿼리)를 직접 지정합니다:

```bash
gori run authorize 12 13 14
gori run authorize --query 'host:api.example.com method:GET status:200' --limit 20
```

헤드리스는 기본으로 `GET`, `HEAD`, `OPTIONS`만 다시 보냅니다. `POST`나 `DELETE`를 다시 보내면 그 동작이 아이덴티티 수만큼 또 실행되기 때문에, `--unsafe-methods`를 주지 않는 한 건너뜁니다. 이 옵션은 동작이 다시 실행돼도 문제없는 테스트 계정에서만 쓰세요. TUI에서 손으로 큐에 넣은 요청은 메서드와 상관없이 다시 보냅니다. 사람이 직접 고른 요청이니까요.

**체크포인트.** 큐의 모든 행에 판정이 붙었고, `⇥`로 각 아이덴티티가 어떻게 응답받았는지 볼 수 있습니다.

## 4. 결과 읽기 {#4-read-the-results}

각 아이덴티티의 응답을 기준 응답과 상태 코드, 크기, 내용으로 비교합니다:

| 판정 | 뜻 |
|------|-----|
| `same` | 이 아이덴티티가 관리자와 같은 걸 받았습니다. 받으면 안 되는 거라면 그게 버그입니다 |
| `different` | `403`이나 로그인 페이지로의 리다이렉트처럼 다른 종류의 응답입니다. 접근 제어가 제대로 동작했습니다 |
| `review` | 비슷하지만 같지는 않습니다. 직접 확인하세요 |
| `error` | 요청이 실패했습니다. 비교한 게 없습니다 |

어느 아이덴티티든 `same`이 나오면 그 요청 행은 **BYPASS**로 표시됩니다. 아직은 단서일 뿐, 확정된 발견은 아닙니다. `/admin/users`에서 `anonymous`가 `same`이면 진짜 문제입니다. 모든 사용자가 볼 수 있는 페이지에서 `low-priv`가 `same`이면 아무 문제 없습니다. gori는 응답을 비교할 수 있을 뿐이고, 누가 무엇을 봐도 되는지는 여러분만 압니다.

거의 모든 행이 `review`라면 기준 응답부터 확인하세요. 관리자 자신의 재전송이 `401`이나 `403`으로 돌아왔다면 캡처한 세션이 만료된 것이고, 비교할 기준이 없는 상태입니다. 관리자로 다시 로그인해 요청을 새로 캡처하고 다시 돌리세요.

`review`는 꼼꼼히 봐야 합니다. 어떤 앱은 거부한 요청에 "접근 거부" 안내 페이지를 `200`으로 돌려주고, 어떤 페이지는 사용자가 누구든 거의 똑같습니다. 행을 열어 두 본문을 직접 읽어 보세요.

헤드리스 출력은 줄 맨 앞에 `[!] BYPASS`를 붙여 눈에 잘 띄게 합니다:

```
[!] BYPASS    #1     GET    https://api.example.com/admin/users  · 1 of 2 identities matched the baseline
      as-captured         baseline  200  4.1KB    —
      anonymous           different 302  0B       Δ status 200 → 302 · …
      low-priv            same      200  4.1KB    Δ status 200 · size same · …
```

**체크포인트.** `BYPASS`와 `review` 행이 몇 개로 추려졌고, 그중 어느 게 진짜인지 압니다.

## 5. 손으로 한 번 확인하기 {#5-confirm-one-by-hand}

보고서를 쓰기 전에 손으로 한 번 증명해 두세요. 요청을 **Repeater**로 보내고(History에서 `Ctrl-R`), `Ctrl-P` → **Session slot**으로 권한 낮은 아이덴티티를 고른 뒤 보내세요. 헤드리스에서는 이렇게 합니다:

```bash
gori run repeater <flow-id> --slot low-priv
```

응답에 정말 관리자 데이터가 들어 있는지, 빈 껍데기나 캐시된 페이지는 아닌지 확인하세요. 경로에 id가 있다면 다른 사용자의 레코드도 요청해 보세요. A가 자기 주문을 보는 버그보다 A가 B의 주문을 읽는 버그가 훨씬 무겁습니다.

**체크포인트.** `low-priv`로 보낸 Repeater 요청이 그 사용자가 보면 안 되는 데이터를 돌려줍니다.

## 6. 이슈로 남기기 {#6-file-it}

확인한 행을 플로우를 첨부한 이슈로 만들어 두면 증거가 함께 남습니다:

```bash
gori run issues create --title "Low-privilege user can list all users" \
  --severity high --host api.example.com --flow <flow-id>
```

나머지(심각도, 노트, 내보내기)는 [트리아지와 리포트](/ko/playbooks/triage-and-report/)에서 다룹니다.

## 아무것도 안 나올 때 {#when-nothing-comes-back}

결과가 비었다고 꼭 좋은 소식은 아닙니다. gori는 요청을 조용히 덜 보내는 대신, 무엇을 왜 건너뛰었는지 알려 줍니다:

- **no identity changes them**: 어떤 아이덴티티도 바꾸는 헤더가 없어서, 모든 아이덴티티가 같은 바이트를 보내게 됩니다. 그 엔드포인트는 여러분이 다루지 않은 헤더(예: `X-Api-Key`)로 인증하고 있을 가능성이 큽니다. 그 헤더를 설정하거나 지우는 아이덴티티를 추가하세요.
- **not a safe method to repeat**: 3단계를 보세요.
- **outside project scope**: 그 호스트를 스코프에 추가하세요.

모든 전송이 거부되거나 실패했다면, 실행 결과는 아무것도 보내지 않았다고 말합니다. 이걸 "접근 제어가 지켜졌다"고 보고하는 일은 없습니다. 그리고 `enforced`는 여러분이 시도한 아이덴티티와 요청에 대해서만 하는 말입니다. 한 번도 둘러보지 않은 엔드포인트는 안전한 게 아니라 테스트하지 않은 것입니다.

## 다음 단계 {#next-steps}

- [접근 제어 테스트](/ko/guide/authorize/): 판정 규칙 전체, 패시브 재전송, MCP 도구
- [세션 유지](/ko/playbooks/carry-a-session/): 바뀌는 토큰, 오래 도는 실행을 위한 refresh 단계
- [트리아지와 리포트](/ko/playbooks/triage-and-report/): 우회를 보고서로 만들기
